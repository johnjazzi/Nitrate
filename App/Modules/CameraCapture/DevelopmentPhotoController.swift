import AVFoundation
import CoreMedia
import Foundation

final class DevelopmentPhotoController: @unchecked Sendable {
    private let device: AVCaptureDevice
    private let output: AVCapturePhotoOutput
    private let pixelFormat: OSType
    private let dimensions: CMVideoDimensions
    private let directory: URL
    private let queue: DispatchQueue
    private let onUpdate: @MainActor @Sendable (PhotoExposureSnapshot) -> Void
    private let onFailure: @Sendable (String) -> Void

    private var started = false
    private var stopped = false
    private var capturing = false
    private var captureHelper: CameraPhotoCapture?
    private var pendingCapture: PendingPhotoCaptureRequest?
    /// Identifies the deferred capture a watchdog was armed for, so a consumed
    /// or superseded capture cannot be failed by a stale deadline.
    private var captureToken: UInt64 = 0
    private var stopWaiters: [@Sendable () -> Void] = []
    private var isoLocked = false
    private var shutterLocked = false
    private var ev: Float = 0
    private var generation: UInt64 = 0
    private var operations = PhotoExposureOperationOwnership()
    private var setterInFlight: Bool { operations.customPending }
    private var biasSettersInFlight: Int { operations.biasPendingCount }
    private let sourceID = UUID()
    private var intentNeedsApply = false
    private var adjustmentGeneration: UInt64 = 0
    private var targetLimited = false
    private var apertureIntent: Float?
    private var apertureDirty = false
    /// The metered exposure the held aperture is resolved against: the ISO the
    /// device itself metered, at the iris it metered it at, under the EV target
    /// installed at that moment. Captured once, before the first custom write,
    /// so a later aperture or EV change is measured from the scene rather than
    /// from a value this controller already corrected.
    private var apertureBaseline: PhotoApertureBaseline?
    private var pinnedISO: Float?
    private var pinnedDuration: CMTime?
    private var traceSequence: UInt64 = 0
    private var wake: DispatchWorkItem?
    private var intentDeadline: TimeInterval = 0
    /// The still's lamp. Built from this controller's device, so there is one
    /// handle on the LED per photo graph and no shared torch state.
    private lazy var torch = FlashTorchController(device: device)

    /// A lamp level the hardware refused. The photo is still taken; the operator
    /// is told why the scene is not lit.
    var onFlashRefused: (@Sendable (String) -> Void)?

    private func trace(_ event: String) {
        guard CommandLine.arguments.contains("--trace-photo-exposure") else { return }
        traceSequence &+= 1
        let line = "Photo exposure trace: n=\(traceSequence) t=\(ProcessInfo.processInfo.systemUptime) event=\(event) zoom=\(device.videoZoomFactor) generation=\(generation) ISO=\(device.iso) duration=\(device.exposureDuration.seconds) mode=\(device.exposureMode.rawValue) bias=\(device.exposureTargetBias) offset=\(device.exposureTargetOffset) adjusting=\(device.isAdjustingExposure) isoLocked=\(isoLocked) shutterLocked=\(shutterLocked) EV=\(ev) pending=\(setterInFlight) limited=\(targetLimited) stopped=\(stopped) biasPending=\(biasSettersInFlight) intentPending=\(intentNeedsApply) capturePending=\(pendingCapture != nil) capturing=\(capturing)"
        print(line)
        CaptureTraceFile.write(line)
    }

    var isCapturing: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return capturing
    }

    init(device: AVCaptureDevice, output: AVCapturePhotoOutput, pixelFormat: OSType,
         dimensions: CMVideoDimensions, directory: URL, queue: DispatchQueue,
         onUpdate: @escaping @MainActor @Sendable (PhotoExposureSnapshot) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.device = device; self.output = output; self.pixelFormat = pixelFormat
        self.dimensions = dimensions; self.directory = directory; self.queue = queue
        self.onUpdate = onUpdate; self.onFailure = onFailure
    }

    func start() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { throw Error.stopped }
        guard !started else { return }
        started = true
        trace("start")
        guard validRanges else { started = false; throw Error.invalidDeviceRange }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if !device.isExposureModeSupported(.continuousAutoExposure) { started = false; throw Error.unsupportedMode }
        device.exposureMode = .continuousAutoExposure
        operations.noteApplied(now: ProcessInfo.processInfo.systemUptime)
        setBias(0)
        publish()
        scheduleAdjustment()
    }

    struct Intent: Sendable {
        let iso: Float?
        let duration: Double?
        let ev: Float
        let aperture: Float?
    }

    var intentSnapshot: Intent {
        dispatchPrecondition(condition: .onQueue(queue))
        return Intent(iso: isoLocked ? pinnedISO : nil,
                      duration: shutterLocked ? pinnedDuration?.seconds : nil,
                      ev: ev, aperture: apertureIntent)
    }

    func restoreIntent(_ intent: Intent) throws {
        dispatchPrecondition(condition: .onQueue(queue)); try ensureMutable()
        isoLocked = intent.iso != nil
        pinnedISO = intent.iso.map { min(max($0, isoRange.lowerBound), isoRange.upperBound) }
        // A duration is only honoured alongside a held ISO: the shutter control is
        // part of that control group, and a lone duration pins custom exposure with
        // no way back to auto.
        shutterLocked = intent.iso != nil && intent.duration != nil
        pinnedDuration = (intent.iso != nil ? intent.duration : nil).map {
            CMTime(seconds: min(max($0, shutterRange.lowerBound), shutterRange.upperBound), preferredTimescale: 1_000_000_000)
        }
        ev = min(max(intent.ev, exposureBiasRange.lowerBound), exposureBiasRange.upperBound)
        // The intent travels between lenses, but a stop is the lens's own fact:
        // an f/4.0 chosen on the wide lens is not a stop the telephoto reports,
        // and holding it anyway failed the first write after the switch with
        // `unsupportedMode` — reported as a recording error on a take that was
        // fine. Hold what this lens can do; Auto when it cannot vary at all.
        apertureIntent = heldAperture(intent.aperture)
        apertureDirty = apertureIntent != nil
        // A restored intent starts a new metering context; the next aperture
        // write re-seeds the baseline from the device as it stands then.
        apertureBaseline = nil
        targetLimited = false
        try submitCurrentIntent()
    }

    func setISO(_ value: Float) throws {
        dispatchPrecondition(condition: .onQueue(queue)); try ensureMutable()
        guard value.isFinite, isoRange.contains(value) else { throw Error.invalidValue }
        isoLocked = true; pinnedISO = value
        // The operator now holds the gain: there is nothing left to resolve
        // from the old metering, and the target is whatever they set by hand.
        apertureBaseline = nil
        targetLimited = false
        try submitCurrentIntent()
    }

    func setDuration(_ seconds: Double) throws {
        dispatchPrecondition(condition: .onQueue(queue)); try ensureMutable()
        guard seconds.isFinite, shutterRange.contains(seconds) else { throw Error.invalidValue }
        shutterLocked = true; pinnedDuration = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        try submitCurrentIntent()
    }

    /// Pin the operator's ISO — and nothing else.
    ///
    /// The ISO is the operator's *sensitivity* choice; the shutter stays a
    /// separate decision. Holding one does not hold the other, so a pinned ISO
    /// leaves the shutter free to float and reach the compensation exactly as the
    /// device's own auto exposure would (an operator who wants a held shutter
    /// locks the shutter on its own rail).
    func setISOLocked(_ locked: Bool) throws {
        dispatchPrecondition(condition: .onQueue(queue)); try ensureMutable()
        isoLocked = locked
        pinnedISO = locked ? device.iso : nil
        // Releasing the ISO releases the shutter with it. The shutter control is
        // only on screen while the ISO is held, so a shutter lock that outlives
        // the ISO hold leaves custom exposure installed with no control to undo it
        // and the camera never returns to metering.
        if !locked { shutterLocked = false; pinnedDuration = nil }
        // A released ISO floats again, so the baseline is re-taken from the
        // exposure the operator is looking at now — the next resolution starts
        // there instead of from a reading several moves old.
        apertureBaseline = nil
        targetLimited = false
        try submitCurrentIntent()
    }

    func setShutterLocked(_ locked: Bool) throws {
        dispatchPrecondition(condition: .onQueue(queue)); try ensureMutable()
        shutterLocked = locked
        pinnedDuration = locked ? device.exposureDuration : nil
        try submitCurrentIntent()
    }

    func setAperture(_ aperture: Float?) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        try ensureMutable()
        guard aperture.map({ $0.isFinite && $0 > 0 }) ?? true else { throw Error.invalidValue }
        apertureIntent = heldAperture(aperture)
        apertureDirty = true
        // Handing the iris back to the camera returns to native auto exposure,
        // where there is no resolved gain to keep and no limit to report.
        if aperture == nil { apertureBaseline = nil; targetLimited = false }
        try submitCurrentIntent()
    }

    func setEV(_ value: Float) throws {
        dispatchPrecondition(condition: .onQueue(queue)); try ensureMutable()
        guard value.isFinite, exposureBiasRange.contains(value) else { throw Error.invalidValue }
        ev = value
        trace("EV-request")
        targetLimited = false
        try submitCurrentIntent()
    }

    /// `rotationAngle` is the quarter-turn frozen at the shutter tap. It is held
    /// with a waiting tap and handed to the photo request unchanged.
    func capture(rotationAngle: CGFloat? = nil, flash: FlashSettings = .standard,
                 completion: @escaping @MainActor @Sendable (Result<URL, Swift.Error>) -> Void) throws {
        try capture(rotationAngle: rotationAngle, flash: flash, completion: completion, force: false)
    }

    /// `force` takes the photo under whatever the device has installed right now,
    /// skipping the wait for the operator's unwritten intent. Used once that wait
    /// has already been spent (`armCaptureImpatience`), so the exposure loop can
    /// never push a tap behind another correction.
    private func capture(rotationAngle: CGFloat?,
                         flash: FlashSettings,
                         completion: @escaping @MainActor @Sendable (Result<URL, Swift.Error>) -> Void,
                         force: Bool) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        trace("capture-request")
        guard started, !stopped else { trace("capture-refused not-running"); throw Error.notReady }
        guard !capturing, pendingCapture == nil else {
            trace("capture-refused busy capturing=\(capturing) pending=\(pendingCapture != nil)")
            throw Error.notReady
        }
        // Wait only for the operator's own latest intent (one debounced write) or
        // for a write the device has not acknowledged yet. Metering corrections are
        // never allowed to hold a capture: the photo is taken under the exposure
        // that is installed, which is the exposure the operator was looking at.
        if !force, setterInFlight || biasSettersInFlight > 0 || intentNeedsApply {
            pendingCapture = PendingPhotoCaptureRequest(rotationAngle: rotationAngle, flash: flash,
                                                       completion: completion)
            captureToken &+= 1
            armCaptureDeadline(captureToken)
            armCaptureImpatience(captureToken)
            trace("capture-wait setter=\(setterInFlight) bias=\(biasSettersInFlight) intent=\(intentNeedsApply)")
            adjustmentGeneration &+= 1
            publish()
            return
        }
        guard device.videoZoomFactor == 1 else {
            trace("capture-refused zoom=\(device.videoZoomFactor)")
            throw CaptureFailure("RAW capture needs the selected camera at native magnification. Tap again to reset the zoom.")
        }
        capturing = true; adjustmentGeneration &+= 1; wake?.cancel(); wake = nil; publish()
        // Native photo flash owns the LED. Never leave continuous torch running
        // into a photo request, and never substitute a software-timed pulse.
        extinguishFlash()
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let helper = try CameraPhotoCapture(output: output, pixelFormat: pixelFormat,
                dimensions: dimensions, directory: folder, queue: queue,
                rotationAngle: rotationAngle, flashRequested: flash.isPhotoLampOn) { [weak self] result in
                    guard let self else { return }
                    self.trace("capture-terminal \(result.failure ?? "success")")
                    self.extinguishFlash()
                    if let reason = FlashRecord.decode(result.evidence)?.refusalReason {
                        self.onFlashRefused?(reason)
                    }
                    self.captureHelper = nil; self.capturing = false
                    if !self.stopped { self.scheduleAdjustment() }
                    if let failure = result.failure { self.onFailure(failure) }
                    self.publish()
                    let outcome: Result<URL, Swift.Error> = result.dngURL.map { .success($0) }
                        ?? .failure(CaptureFailure(result.failure ?? "capture ended without a validated DNG"))
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
                    self.finishStopIfNeeded()
                }
            captureHelper = helper
            trace("capture-submit")
            try helper.start()
        } catch {
            // The request never reached the hardware; the lamp must not stay on.
            extinguishFlash()
            captureHelper = nil; capturing = false; publish(); throw error
        }
    }

    func stop(whenSettled: @escaping @Sendable () -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true; adjustmentGeneration &+= 1; generation &+= 1
        // Leaving Photo mode must not leave the lamp burning behind it.
        extinguishFlash()
        operations.stop()
        wake?.cancel(); wake = nil
        if let pending = pendingCapture {
            pendingCapture = nil
            DispatchQueue.main.async { pending.completion(.failure(CaptureFailure("Photo capture interrupted"))) }
        }
        trace("stop-request")
        stopWaiters.append(whenSettled)
        finishStopIfNeeded()
    }

    private func ensureMutable() throws {
        guard started, !stopped else { throw Error.stopped }
        guard !capturing else { throw Error.notReady }
    }

    private var validRanges: Bool { isoRange.lowerBound > 0 && isoRange.upperBound >= isoRange.lowerBound && shutterRange.lowerBound > 0 && shutterRange.upperBound >= shutterRange.lowerBound }
    private var isoRange: ClosedRange<Float> { device.activeFormat.minISO...device.activeFormat.maxISO }
    /// The device's own range, capped at the slowest exposure the hardware still
    /// acknowledges. Offering 1/2s and slower produced an exposure write that never
    /// returned, which read as EV and shutter controls failing outright.
    var shutterRange: ClosedRange<Double> {
        let lower = device.activeFormat.minExposureDuration.seconds
        let upper = min(device.activeFormat.maxExposureDuration.seconds, PhotoShutterFloatPolicy.floorSeconds)
        return lower...max(lower, upper)
    }
    private var exposureBiasRange: ClosedRange<Float> { max(device.minExposureTargetBias, -3)...min(device.maxExposureTargetBias, 3) }

    /// The stop this controller can hold on the device it was built for: the
    /// nearest stop the active format reports, or Auto when its iris cannot vary.
    private func heldAperture(_ requested: Float?) -> Float? {
        guard let requested else { return nil }
        guard #available(iOS 27.0, *) else { return requested }
        return CameraAperturePolicy.heldAperture(requested,
            capability: CameraAperturePolicy.capability(for: device))
    }

    private var usesNativeAutoExposure: Bool {
        PhotoExposurePolicy.usesNativeAutoExposure(isoLocked: isoLocked,
            shutterLocked: shutterLocked, apertureHeld: apertureIntent != nil)
    }
    private var neutralMeteringOffset: Float {
        PhotoExposureSnapshot.neutralMeteringOffset(rawOffset: device.exposureTargetOffset,
                                                   installedBias: device.exposureTargetBias)
    }
    private var settling: Bool {
        if usesNativeAutoExposure { return device.isAdjustingExposure }
        return !(isoLocked && shutterLocked)
            && abs(ev - neutralMeteringOffset) > PhotoExposurePolicy.settlingToleranceEV
    }

    private func applyCurrentIntent() throws {
        let duration = shutterLocked ? (pinnedDuration ?? device.exposureDuration) : device.exposureDuration
        // The ISO floats while an aperture is held. Re-resolve it from the
        // metered baseline: re-writing the ISO read before the iris moved pins
        // the gain the old aperture needed and leaves the meter at the aperture
        // delta for good — the reported "f/4.0 reads -3.4 EV and never comes
        // back".
        if !isoLocked, let aperture = apertureIntent, let iso = resolvedISO(for: aperture) {
            try applyIntent(iso: iso, duration: duration)
            return
        }
        let iso = isoLocked ? (pinnedISO ?? device.iso) : device.iso
        try applyIntent(iso: iso, duration: duration)
    }

    /// ISO that puts the held aperture back on the operator's EV target.
    ///
    /// The baseline is the device's own last metered reading, taken before the
    /// first custom write. Everything after that is arithmetic from it, so the
    /// resolution is one-shot and idempotent: re-running the intent — after a
    /// lost acknowledgement, say — asks for the same value.
    ///
    /// Returns nil when the device has no usable reading to resolve from (it is
    /// still settling). That is a transient state, not a fault, so the caller
    /// keeps the value it has instead of refusing the write.
    private func resolvedISO(for aperture: Float) -> Float? {
        if apertureBaseline == nil { apertureBaseline = meteredBaseline(fallbackAperture: aperture) }
        guard let baseline = apertureBaseline,
              let resolution = PhotoApertureExposurePolicy.resolveISO(
                baseline: baseline, aperture: aperture, ev: ev, isoRange: isoRange)
        else {
            trace("aperture-resolve-unavailable aperture=\(aperture) iso=\(device.iso)")
            return nil
        }
        targetLimited = resolution.targetLimited
        trace("aperture-resolve aperture=\(aperture) baselineISO=\(baseline.iso) " +
              "baselineAperture=\(baseline.aperture) baselineEV=\(baseline.ev) " +
              "ISO=\(resolution.iso) achievedEV=\(resolution.achievedEV) limited=\(resolution.targetLimited)")
        return resolution.iso
    }

    /// The device's own metering is the scene's truth, and it is only valid
    /// before this controller starts writing. `lensAperture` reads 0 while the
    /// device is still settling, so the requested stop is the fallback.
    private func meteredBaseline(fallbackAperture: Float) -> PhotoApertureBaseline? {
        guard device.iso.isFinite, device.iso > 0 else { return nil }
        let installed = device.lensAperture
        let meteredAt = installed.isFinite && installed > 0 ? installed : fallbackAperture
        return PhotoApertureBaseline(iso: device.iso, aperture: meteredAt, ev: ev)
    }

    private func submitCurrentIntent() throws {
        intentNeedsApply = true
        intentDeadline = ProcessInfo.processInfo.systemUptime + PhotoExposureCadence.gestureDelay
        scheduleAdjustment()
        publish()
    }

    private func applyIntent(iso: Float, duration: CMTime) throws {
        guard !stopped else { throw Error.stopped }
        guard iso.isFinite, duration.seconds.isFinite, isoRange.contains(iso), shutterRange.contains(duration.seconds) else { throw Error.invalidValue }
        if !apertureDirty, !usesNativeAutoExposure, device.exposureMode == .custom,
           !PhotoExposureCadence.needsWrite(iso: iso, duration: duration.seconds,
               actualISO: device.iso, actualDuration: device.exposureDuration.seconds) { return }
        generation &+= 1
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        // Clearing aperture is a mode reconciliation, not a custom setter that
        // must complete before a later gesture happens to re-enable native AE.
        if usesNativeAutoExposure {
            guard device.isExposureModeSupported(.continuousAutoExposure) else { throw Error.unsupportedMode }
            device.exposureMode = .continuousAutoExposure
            apertureDirty = false
            operations.noteApplied(now: ProcessInfo.processInfo.systemUptime)
            setBias(ev)
            publish()
            return
        }
        guard device.isExposureModeSupported(.custom) else { throw Error.unsupportedMode }
        if #available(iOS 27.0, *), apertureDirty || apertureIntent != nil {
            let aperture = apertureIntent ?? AVCaptureDevice.currentLensAperture
            guard device.activeFormat.supportsExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso) else {
                throw Error.unsupportedMode
            }
        }
        guard let token = operations.begin(.custom, now: ProcessInfo.processInfo.systemUptime) else { throw Error.notReady }
        setBias(0)
        lastRequested = (iso, duration.seconds)
        armSetterWatchdog(token)
        trace("setter-start token=\(token.id) requestedISO=\(iso) requestedDuration=\(duration.seconds)")
        let completion: @Sendable (CMTime) -> Void = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.operations.acknowledge(token, now: ProcessInfo.processInfo.systemUptime) else {
                    self.trace("stale-setter-completed token=\(token.id)")
                    return
                }
                self.trace("setter-completed token=\(token.id)")
                // A waiting capture outranks autonomous corrections, but its RAW
                // terminal remains owned independently of these setter leases.
                if let pending = self.pendingCapture, !self.stopped, self.biasSettersInFlight == 0 {
                    self.pendingCapture = nil
                    self.captureToken &+= 1
                    self.intentNeedsApply = false
                    do { try self.capture(rotationAngle: pending.rotationAngle, flash: pending.flash,
                                          completion: pending.completion) }
                    catch { DispatchQueue.main.async { pending.completion(.failure(error)) } }
                    return
                }
                self.publish()
                self.scheduleAdjustment()
                self.finishStopIfNeeded()
            }
        }
        if #available(iOS 27.0, *), apertureDirty || apertureIntent != nil {
            let aperture = apertureIntent ?? AVCaptureDevice.currentLensAperture
            apertureDirty = false
            device.setExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso, completionHandler: completion)
        } else {
            apertureDirty = false
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: completion)
        }
        publish()
    }

    /// A deadline survives stop and fences only its own callback. It fails closed
    /// until the session enters a real stop/reconfigure boundary. This never
    /// invents a RAW terminal or changes `capturing`.
    /// What the in-flight custom setter asked the device for. A lost ACK is not
    /// evidence the write was rejected: at slow shutters the setter legitimately
    /// outlives any fixed deadline, so expiry first reconciles this against the
    /// device before it may declare recovery.
    private var lastRequested: (iso: Float, duration: Double)?

    private func armSetterWatchdog(_ token: PhotoExposureOperationOwnership.Token) {
        let deadline = PhotoExposureCadence.setterDeadline(forRequestedDuration: lastRequested?.duration ?? 0)
        queue.asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard let self else { return }
            guard self.operations.expire(token, now: ProcessInfo.processInfo.systemUptime) else { return }
            // The acknowledgement was lost. That is not a broken camera: forget the
            // lease and ask for the desired value again on the next tick. The write
            // is idempotent, so a value already installed costs one no-op.
            self.trace("setter-watchdog token=\(token.id) reasserting")
            self.intentNeedsApply = true
            self.publish()
            self.scheduleAdjustment()
            self.finishStopIfNeeded()
        }
    }

    /// A tap that cannot start within the capture timeout fails with a reason, so
    /// the shutter is usable again instead of waiting on the exposure forever.
    private func armCaptureDeadline(_ token: UInt64) {
        queue.asyncAfter(deadline: .now() + PhotoExposureCadence.captureTimeout) { [weak self] in
            guard let self, self.captureToken == token, let pending = self.pendingCapture else { return }
            self.trace("capture-timeout")
            self.pendingCapture = nil
            self.captureToken &+= 1
            self.publish()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    pending.completion(.failure(
                        CaptureFailure("The camera did not settle in time. Tap the shutter to try again.")))
                }
            }
            self.scheduleAdjustment()
        }
    }

    /// A waiting capture is forced after `captureImpatience`.
    ///
    /// The exposure loop writes corrections on its own schedule, and a tap that
    /// queued behind that loop read as a dead shutter. A photo is a snapshot of
    /// the exposure the operator is looking at: if their own gesture has not
    /// reached the device in time, the photo they asked for still gets taken.
    private func armCaptureImpatience(_ token: UInt64) {
        queue.asyncAfter(deadline: .now() + PhotoExposureCadence.captureImpatience) { [weak self] in
            guard let self, self.captureToken == token, let pending = self.pendingCapture,
                  !self.stopped, !self.capturing else { return }
            self.trace("capture-impatient setter=\(self.setterInFlight) intent=\(self.intentNeedsApply)")
            self.pendingCapture = nil
            self.captureToken &+= 1
            // The requested value lost the race with the tap. Drop it so the loop
            // cannot re-arm it behind this capture.
            self.intentNeedsApply = false
            do { try self.capture(rotationAngle: pending.rotationAngle, flash: pending.flash,
                                  completion: pending.completion, force: true) }
            catch { DispatchQueue.main.async { pending.completion(.failure(error)) } }
        }
    }

    /// One write per operator intent, then a read-only tick that refreshes the
    /// readout. There is no autonomous correction: holding the ISO pins the
    /// sensitivity and the shutter with it, and the device keeps metering while
    /// nothing is held, so a loop here only fought the hardware at the limits and
    /// refused work it could not finish.
    private func scheduleAdjustment() {
        guard started, !stopped, !capturing else { return }
        wake?.cancel(); wake = nil
        guard !setterInFlight, biasSettersInFlight == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let due = intentNeedsApply ? intentDeadline : now + PhotoExposureCadence.commandInterval
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, !self.capturing else { return }
            self.wake = nil
            if !self.setterInFlight && self.biasSettersInFlight == 0 {
                do {
                    if self.intentNeedsApply {
                        self.intentNeedsApply = false
                        try self.applyCurrentIntent()
                    } else if let pending = self.pendingCapture {
                        self.pendingCapture = nil
                        self.captureToken &+= 1
                        try self.capture(rotationAngle: pending.rotationAngle, flash: pending.flash,
                                         completion: pending.completion)
                        return
                    }
                } catch {
                    self.onFailure((error as? Error)?.reason ?? error.localizedDescription)
                }
            }
            self.publish()
            self.scheduleAdjustment()
        }
        wake = item
        queue.asyncAfter(deadline: .now() + max(0.02, due - now), execute: item)
    }

    private func snapshot() -> PhotoExposureSnapshot {
        PhotoExposureSnapshot(iso: device.iso, durationSeconds: device.exposureDuration.seconds,
            isoRange: isoRange, shutterRange: shutterRange, isoLocked: isoLocked,
            shutterLocked: shutterLocked, ev: ev, meteringOffset: neutralMeteringOffset,
            isSettling: (settling && !targetLimited) || setterInFlight,
            canCapture: PhotoExposurePolicy.captureAvailable(started: started, stopped: stopped,
                                                            capturing: capturing || pendingCapture != nil),
            targetLimited: targetLimited, photoWidth: Int(dimensions.width), photoHeight: Int(dimensions.height),
            sourceID: sourceID)
    }

    private func publish() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard started else { return }
        let value = snapshot(); DispatchQueue.main.async { MainActor.assumeIsolated { self.onUpdate(value) } }
    }

    private func setBias(_ value: Float) {
        // A no-op bias write can remain unacknowledged after a profile rebuild.
        // The installed value already satisfies the request; do not create a
        // fictitious in-flight operation that blocks the next shutter forever.
        guard !stopped, abs(device.exposureTargetBias - value) > 0.001,
              let token = operations.begin(.bias, now: ProcessInfo.processInfo.systemUptime) else { return }
        trace("bias-start token=\(token.id) value=\(value)")
        armSetterWatchdog(token)
        device.setExposureTargetBias(value) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.operations.acknowledge(token, now: ProcessInfo.processInfo.systemUptime) else {
                    self.trace("stale-bias-completed token=\(token.id)")
                    return
                }
                self.trace("bias-completed token=\(token.id)")
                self.publish()
                if !self.stopped { self.scheduleAdjustment() }
                self.finishStopIfNeeded()
            }
        }
    }

    private func finishStopIfNeeded() {
        guard operations.canDrain(capturing: capturing) else { return }
        let callbacks = stopWaiters; stopWaiters.removeAll(); callbacks.forEach { $0() }
    }

    // MARK: - Lamp

    /// Teardown only: stills never arm or set a continuous torch level.
    private func extinguishFlash() {
        torch.turnOff()
    }

    deinit {
        // A lamp left on by a controller that has gone away is a dead battery.
        torch.turnOff()
    }

    private enum Error: Swift.Error {
        case stopped, invalidDeviceRange, invalidValue, unsupportedMode, notReady

        /// Why the write was refused, in the operator's terms. The raw case name
        /// ("unsupportedMode") is not something to put in front of a photographer.
        var reason: String {
            switch self {
            case .stopped: return "the photo camera stopped"
            case .invalidDeviceRange: return "the lens reported no usable exposure range"
            case .invalidValue: return "the request was outside the lens's range"
            case .unsupportedMode: return "this lens does not support that exposure"
            case .notReady: return "the previous exposure was still settling"
            }
        }
    }
    private struct CaptureFailure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
