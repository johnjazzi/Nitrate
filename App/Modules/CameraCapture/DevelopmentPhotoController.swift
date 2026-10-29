#if DEBUG
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
    private var pendingCapture: (@MainActor @Sendable (Result<URL, Swift.Error>) -> Void)?
    /// Identifies the deferred capture a watchdog was armed for, so a consumed
    /// or superseded capture cannot be failed by a stale deadline.
    private var captureToken: UInt64 = 0
    private var stopWaiters: [@Sendable () -> Void] = []
    private var isoLocked = false
    private var shutterLocked = false
    private var ev: Float = 0
    private var generation: UInt64 = 0
    private var setterInFlight = false
    private var biasSettersInFlight = 0
    private var intentNeedsApply = false
    private var adjustmentGeneration: UInt64 = 0
    private var targetLimited = false
    private var apertureIntent: Float?
    private var apertureDirty = false
    private var pinnedISO: Float?
    private var pinnedDuration: CMTime?
    private var traceSequence: UInt64 = 0
    private var wake: DispatchWorkItem?
    private var nextHardwareWrite: TimeInterval = 0
    private var intentDeadline: TimeInterval = 0
    private var lastMeteringAction: TimeInterval = 0

    private func trace(_ event: String) {
        guard CommandLine.arguments.contains("--trace-photo-exposure") else { return }
        traceSequence &+= 1
        let line = "Photo exposure trace: n=\(traceSequence) t=\(ProcessInfo.processInfo.systemUptime) event=\(event) zoom=\(device.videoZoomFactor) generation=\(generation) ISO=\(device.iso) duration=\(device.exposureDuration.seconds) mode=\(device.exposureMode.rawValue) bias=\(device.exposureTargetBias) offset=\(device.exposureTargetOffset) adjusting=\(device.isAdjustingExposure) isoLocked=\(isoLocked) shutterLocked=\(shutterLocked) EV=\(ev) pending=\(setterInFlight) limited=\(targetLimited) stopped=\(stopped) biasPending=\(biasSettersInFlight) intentPending=\(intentNeedsApply) capturePending=\(pendingCapture != nil) capturing=\(capturing)"
        print(line)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("photo-exposure-trace.txt")
        if let data = (line + "\n").data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let file = try? FileHandle(forWritingTo: url) {
                defer { try? file.close() }
                _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
            }
        }
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
        shutterLocked = intent.duration != nil
        pinnedDuration = intent.duration.map {
            CMTime(seconds: min(max($0, shutterRange.lowerBound), shutterRange.upperBound), preferredTimescale: 1_000_000_000)
        }
        ev = min(max(intent.ev, exposureBiasRange.lowerBound), exposureBiasRange.upperBound)
        apertureIntent = intent.aperture
        apertureDirty = intent.aperture != nil
        try submitCurrentIntent()
    }

    func setISO(_ value: Float) throws {
        dispatchPrecondition(condition: .onQueue(queue)); try ensureMutable()
        guard value.isFinite, isoRange.contains(value) else { throw Error.invalidValue }
        isoLocked = true; pinnedISO = value
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
        try submitCurrentIntent()
    }

    func setShutterLocked(_ locked: Bool) throws {
        dispatchPrecondition(condition: .onQueue(queue)); try ensureMutable()
        shutterLocked = locked
        pinnedDuration = locked ? device.exposureDuration : nil
        try submitCurrentIntent()
    }

    func setAperture(_ aperture: Float?) throws {
        try ensureMutable()
        guard aperture.map({ $0.isFinite && $0 > 0 }) ?? true else { throw Error.invalidValue }
        apertureIntent = aperture
        apertureDirty = true
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

    func capture(completion: @escaping @MainActor @Sendable (Result<URL, Swift.Error>) -> Void) throws {
        try capture(completion: completion, force: false)
    }

    /// `force` takes the photo under whatever the device has installed right now,
    /// skipping the wait for the operator's unwritten intent. Used once that wait
    /// has already been spent (`armCaptureImpatience`), so the exposure loop can
    /// never push a tap behind another correction.
    private func capture(completion: @escaping @MainActor @Sendable (Result<URL, Swift.Error>) -> Void,
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
            pendingCapture = completion
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
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let helper = try CameraPhotoCapture(output: output, pixelFormat: pixelFormat,
                dimensions: dimensions, directory: folder, queue: queue) { [weak self] result in
                    guard let self else { return }
                    self.trace("capture-terminal \(result.failure ?? "success")")
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
            captureHelper = nil; capturing = false; publish(); throw error
        }
    }

    func stop(whenSettled: @escaping @Sendable () -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true; adjustmentGeneration &+= 1; generation &+= 1
        wake?.cancel(); wake = nil
        if let completion = pendingCapture {
            pendingCapture = nil
            DispatchQueue.main.async { completion(.failure(CaptureFailure("Photo capture interrupted"))) }
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
    var shutterRange: ClosedRange<Double> { device.activeFormat.minExposureDuration.seconds...device.activeFormat.maxExposureDuration.seconds }
    private var exposureBiasRange: ClosedRange<Float> { max(device.minExposureTargetBias, -3)...min(device.maxExposureTargetBias, 3) }
    private var bothAuto: Bool { !isoLocked && !shutterLocked }
    private var settling: Bool {
        if bothAuto { return device.isAdjustingExposure }
        return !(isoLocked && shutterLocked)
            && abs(ev - device.exposureTargetOffset) > PhotoExposurePolicy.settlingToleranceEV
    }

    private func applyCurrentIntent() throws {
        let iso = isoLocked ? (pinnedISO ?? device.iso) : device.iso
        let duration = shutterLocked ? (pinnedDuration ?? device.exposureDuration) : device.exposureDuration
        try applyIntent(iso: iso, duration: duration)
    }

    private func submitCurrentIntent() throws {
        intentNeedsApply = true
        intentDeadline = ProcessInfo.processInfo.systemUptime + PhotoExposureCadence.gestureDelay
        scheduleAdjustment()
        publish()
    }

    private func applyIntent(iso: Float, duration: CMTime) throws {
        guard iso.isFinite, duration.seconds.isFinite, isoRange.contains(iso), shutterRange.contains(duration.seconds) else { throw Error.invalidValue }
        if !apertureDirty, !bothAuto, device.exposureMode == .custom,
           !PhotoExposureCadence.needsWrite(iso: iso, duration: duration.seconds,
               actualISO: device.iso, actualDuration: device.exposureDuration.seconds) { return }
        generation &+= 1; let request = generation
        try device.lockForConfiguration()
        if bothAuto && !apertureDirty && apertureIntent == nil {
            guard device.isExposureModeSupported(.continuousAutoExposure) else { device.unlockForConfiguration(); throw Error.unsupportedMode }
            device.exposureMode = .continuousAutoExposure
            if abs(device.exposureTargetBias - ev) > 0.001 { setBias(ev) }
            device.unlockForConfiguration(); publish(); return
        }
        guard device.isExposureModeSupported(.custom) else { device.unlockForConfiguration(); throw Error.unsupportedMode }
        if abs(device.exposureTargetBias) > 0.001 { setBias(0) }
        setterInFlight = true
        armSetterWatchdog(request)
        trace("setter-start requestedISO=\(iso) requestedDuration=\(duration.seconds)")
        let completion: @Sendable (CMTime) -> Void = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard request == self.generation else {
                    self.trace("stale-setter-completed request=\(request)")
                    self.setterInFlight = false
                    self.publish()
                    self.finishStopIfNeeded()
                    return
                }
                self.setterInFlight = false
                self.nextHardwareWrite = ProcessInfo.processInfo.systemUptime + PhotoExposureCadence.commandInterval
                // A waiting capture outranks everything else: the exposure this
                // write installed is exactly the one the operator's tap asked for,
                // so nothing else may be queued in front of it.
                if let completion = self.pendingCapture, !self.stopped, self.biasSettersInFlight == 0 {
                    self.pendingCapture = nil
                    self.captureToken &+= 1
                    self.intentNeedsApply = false
                    do { try self.capture(completion: completion) }
                    catch { DispatchQueue.main.async { completion(.failure(error)) } }
                    return
                }
                if self.intentNeedsApply && !self.stopped {
                    self.intentNeedsApply = true
                    self.scheduleAdjustment()
                    return
                }
                self.trace("setter-completed request=\(request)")
                self.nextHardwareWrite = ProcessInfo.processInfo.systemUptime + PhotoExposureCadence.commandInterval
                self.publish(); self.scheduleAdjustment()
                self.finishStopIfNeeded()
            }
        }
        if #available(iOS 27.0, *), apertureDirty || apertureIntent != nil {
            let aperture = apertureIntent ?? AVCaptureDevice.currentLensAperture
            guard device.activeFormat.supportsExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso) else {
                setterInFlight = false
                device.unlockForConfiguration()
                throw Error.unsupportedMode
            }
            apertureDirty = false
            device.setExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso, completionHandler: completion)
        } else {
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: completion)
        }
        device.unlockForConfiguration(); publish()
    }

    /// Drop an in-flight setter whose acknowledgement never arrived.
    ///
    /// `applyIntent` already ignores a late acknowledgement through its
    /// generation check, so clearing the flag only lets the next cycle re-read
    /// the device — the only source of truth for the value actually installed.
    /// Without this a dropped acknowledgement left the shutter unresponsive for
    /// the rest of the session.
    private func armSetterWatchdog(_ request: UInt64) {
        queue.asyncAfter(deadline: .now() + PhotoExposureCadence.setterTimeout) { [weak self] in
            guard let self, self.setterInFlight, self.generation == request, !self.stopped else { return }
            self.trace("setter-watchdog")
            self.setterInFlight = false
            self.publish()
            self.scheduleAdjustment()
        }
    }

    /// The same for a bias write: a missing acknowledgement must not block the
    /// shutter, and the installed bias is readable from the device anyway.
    private func armBiasWatchdog() {
        queue.asyncAfter(deadline: .now() + PhotoExposureCadence.setterTimeout) { [weak self] in
            guard let self, self.biasSettersInFlight > 0, !self.stopped else { return }
            self.trace("bias-watchdog")
            self.biasSettersInFlight = 0
            self.publish()
            self.scheduleAdjustment()
        }
    }

    /// A tap that cannot start within the capture timeout fails with a reason, so
    /// the shutter is usable again instead of waiting on the exposure forever.
    private func armCaptureDeadline(_ token: UInt64) {
        queue.asyncAfter(deadline: .now() + PhotoExposureCadence.captureTimeout) { [weak self] in
            guard let self, self.captureToken == token, let completion = self.pendingCapture else { return }
            self.trace("capture-timeout")
            self.pendingCapture = nil
            self.captureToken &+= 1
            self.publish()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(.failure(CaptureFailure("The camera did not settle in time. Tap the shutter to try again.")))
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
            guard let self, self.captureToken == token, let completion = self.pendingCapture,
                  !self.stopped, !self.capturing else { return }
            self.trace("capture-impatient setter=\(self.setterInFlight) intent=\(self.intentNeedsApply)")
            self.pendingCapture = nil
            self.captureToken &+= 1
            // The requested value lost the race with the tap. Drop it so the loop
            // cannot re-arm it behind this capture.
            self.intentNeedsApply = false
            do { try self.capture(completion: completion, force: true) }
            catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    private func scheduleAdjustment() {
        guard started, !stopped, !capturing else { return }
        wake?.cancel(); wake = nil
        guard !setterInFlight, biasSettersInFlight == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // An operator's intent waits only for its own debounce, never for the
        // metering cadence: `nextHardwareWrite` throttles *sensor corrections*, and
        // folding it in here delayed the value the operator just set behind a
        // write they did not ask for. The setter acknowledgement already serialises
        // the device, so a drag can no longer outrun the hardware.
        let due = intentNeedsApply ? intentDeadline
                                   : now + PhotoExposureCadence.commandInterval
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, !self.capturing else { return }
            self.wake = nil
            if !self.setterInFlight && self.biasSettersInFlight == 0 {
                do {
                    if self.intentNeedsApply {
                        self.intentNeedsApply = false
                        try self.applyCurrentIntent()
                    } else if let completion = self.pendingCapture {
                        self.pendingCapture = nil
                        self.captureToken &+= 1
                        try self.capture(completion: completion)
                        return
                    } else if self.pendingCapture == nil,
                              (!self.bothAuto || self.apertureIntent != nil) && !(self.isoLocked && self.shutterLocked),
                              ProcessInfo.processInfo.systemUptime - self.lastMeteringAction
                                  >= PhotoExposureCadence.measurementInterval(duration: self.device.exposureDuration.seconds) {
                        self.lastMeteringAction = ProcessInfo.processInfo.systemUptime
                        let decision = try PhotoExposurePolicy.decide(snapshot: self.snapshot(),
                            request: .init(ev: self.ev, measuredEV: self.device.exposureTargetOffset, maxCorrectionEV: 0.25))
                        self.targetLimited = decision.targetLimited
                        if decision.isSettling {
                            if self.bothAuto, self.apertureIntent != nil {
                                let gain = pow(2, Double(min(max(self.ev - self.device.exposureTargetOffset, -0.25), 0.25)))
                                let adjusted = min(max(Float(Double(self.device.iso) * gain), self.isoRange.lowerBound), self.isoRange.upperBound)
                                try self.applyIntent(iso: adjusted, duration: self.device.exposureDuration)
                            } else if let iso = decision.iso { try self.applyIntent(iso: iso, duration: self.device.exposureDuration) }
                            else if let duration = decision.durationSeconds {
                                try self.applyIntent(iso: self.device.iso, duration: CMTime(seconds: duration, preferredTimescale: 1_000_000_000))
                            }
                        }
                    }
                } catch { self.onFailure("Photo exposure update failed: \(error)") }
            }
            self.publish()
            self.nextHardwareWrite = max(self.nextHardwareWrite,
                ProcessInfo.processInfo.systemUptime + PhotoExposureCadence.commandInterval)
            self.scheduleAdjustment()
        }
        wake = item
        queue.asyncAfter(deadline: .now() + max(0.02, due - now), execute: item)
    }

    private func snapshot() -> PhotoExposureSnapshot {
        PhotoExposureSnapshot(iso: device.iso, durationSeconds: device.exposureDuration.seconds,
            isoRange: isoRange, shutterRange: shutterRange, isoLocked: isoLocked,
            shutterLocked: shutterLocked, ev: ev, meteringOffset: device.exposureTargetOffset,
            isSettling: (settling && !targetLimited) || setterInFlight,
            canCapture: PhotoExposurePolicy.captureAvailable(started: started, stopped: stopped,
                                                            capturing: capturing || pendingCapture != nil),
            targetLimited: targetLimited, photoWidth: Int(dimensions.width), photoHeight: Int(dimensions.height))
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
        guard abs(device.exposureTargetBias - value) > 0.001 else { return }
        trace("bias-start value=\(value)")
        biasSettersInFlight += 1
        armBiasWatchdog()
        device.setExposureTargetBias(value) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.biasSettersInFlight -= 1
                self.trace("bias-completed")
                self.publish()
                if !self.stopped { self.scheduleAdjustment() }
                self.finishStopIfNeeded()
            }
        }
    }

    private func finishStopIfNeeded() {
        guard stopped, !capturing, !setterInFlight, biasSettersInFlight == 0 else { return }
        let callbacks = stopWaiters; stopWaiters.removeAll(); callbacks.forEach { $0() }
    }

    private enum Error: Swift.Error { case stopped, invalidDeviceRange, invalidValue, unsupportedMode, notReady }
    private struct CaptureFailure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
#endif
