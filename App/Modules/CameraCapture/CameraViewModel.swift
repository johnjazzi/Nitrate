import AVFoundation
import Observation
import UIKit

/// AD-1: @Observable ViewModel for the camera screen.
/// Manages exposure mode, record control, free space display, and clip limits.
@MainActor
@Observable
final class CameraViewModel {
    let session = CameraSession()
    let exposure = ExposureManager()
    private var sharedIdleRecoveryAttempted = false

    init() {
        activeLens = session.activeLens
        focalEngine = CameraFocalZoomEngine(activeTier: Self.focalTier(for: session.activeLens))
        availableLensTiers = session.availableLenses.map { Self.focalTier(for: $0) }
        isVideoCaptureProfileActive = !usesSharedIdlePreview
#if DEBUG
        if usesSharedIdlePreview {
            isChangingCaptureProfile = true
            session.enableSharedIdlePreview(onUpdate: { [weak self] snapshot in
                guard let self, self.lifecycleGate.isActive else { return }
                self.trace("snapshot-published iso=\(snapshot.iso)")
                self.photoExposureSnapshot = snapshot
                if self.isDevelopmentPhotoMode { self.presentPhotoExposure(snapshot) }
                self.refreshPhotoAperture()
            }, onProfile: { [weak self] video, busy, configured in
                guard let self else { return }
                self.isVideoCaptureProfileActive = video
                self.isChangingCaptureProfile = busy
                if busy { self.armCaptureProfileWatchdog() } else { self.captureProfileWatchdog?.cancel(); self.captureProfileWatchdog = nil }
                if !busy {
                    self.cameraConfigured = configured
                    if configured { self.sharedIdleRecoveryAttempted = false }
                }
                if video { self.refreshExposure() }
            })
        }
#endif
        session.observeZoom { [weak self] snapshot in
            guard let self else { return }
            if let snapshot, let current = self.zoomSnapshot {
                self.zoomSnapshot = current.accepting(snapshot)
            } else {
                self.zoomSnapshot = snapshot
            }
        }
    }

    // MARK: - Observable State

    var isRecording = false
    var recordingDuration: TimeInterval = 0
    var freeSpaceBytes: Int64 = 0
    var totalSpaceBytes: Int64 = 0
    var hasStorageSnapshot = false
    var isSpaceLow = false
    var isSpaceCritical = false
    var errorMessage: String? {
        didSet {
#if DEBUG
            let apertureError = CameraError.apertureExposureUnsupported.localizedDescription
            if let errorMessage, errorMessage.contains(apertureError) {
                let stack = Thread.callStackSymbols.prefix(12).joined(separator: " <- ")
                print("Aperture error state: lens=\(activeLens.rawValue), switching=\(isSwitchingCameraLens), " +
                      "variable=\(apertureIsVariable), message=\(errorMessage), stack=\(stack)")
            }
#endif
        }
    }
    var recordingWarning: String?
    private(set) var lastRecordedURL: URL?
    /// Set when a take finished with a readable original that failed validation.
    /// The screen saves it to Photos unchanged; it is never rendered.
    private(set) var retainedOriginal: RetainedOriginal?

    // MARK: - Daylight 60 fps (session-only)

    /// Live capture frame rate. Session-only: it resets to `.standard24` at every
    /// foreground-session boundary (background, disappear, cold launch) and is
    /// never persisted.
    private(set) var sessionFrameRate: CameraFrameRate = .standard24
    /// Whether the active device/format advertises a 4K Apple Log 2 10-bit 60 fps
    /// range. Refreshed after configuration and lens switches; drives the
    /// control's unavailable state. It never silently disarms the mode.
    private(set) var supportsDaylight60 = false
    /// True while an arm/disarm is in flight. Record, lens and exposure actions
    /// are held until the transition settles, mirroring the stabilizer gate.
    private(set) var isChangingFrameRate = false
    /// Guards frame-rate callbacks against lifecycle/generation changes, so a
    /// transition that was in flight when the app backgrounded can never restore
    /// 60 fps on the following foreground session.
    private var frameRateGeneration: UInt64 = 0
    /// Capture policies keyed by the completed source URL. The screen and the
    /// queue read the policy from here, never from the live mode, so a boundary
    /// reset cannot mislabel a queued job.
    private var capturePolicies = DaylightCapturePolicyLedger()

    // Exposure (live from the device, polled every 0.5s)
    var liveISO: Float = 0
    var liveShutterSeconds: Double = 0
    var liveAperture: Float?
    var apertureStops: [Float] = []
    var apertureIsVariable = false
    var selectedLensAperture: Float?
    private(set) var recordingStabilization = CameraStabilizationSnapshot(
        preferred: CameraStabilizationMode(
            persistedValue: UserDefaults.standard.string(forKey: CameraStabilizationPolicy.preferenceKey)),
        capability: .unavailable, activeRawValue: nil, cameraRevision: 0, changesAllowed: false)
    private(set) var activeLens: CameraLens
    private(set) var zoomSnapshot: CameraZoomSnapshot?
    private(set) var isSwitchingCameraLens = false
    var isManualExposure = false
    var manualISO: Float = 400
    /// Capture intent, never a proxy for the device's currently committed graph.
    private(set) var isDevelopmentPhotoMode = false
    /// Observable renderer selection (this model uses @Observable, not Combine).
    private(set) var isVideoCaptureProfileActive = false
    private(set) var isChangingCaptureProfile = false
    private var captureProfileWatchdog: Task<Void, Never>?
    var usesSharedIdlePreview: Bool {
#if DEBUG
        DevelopmentPhotoFeature.isAvailable(isDebugBuild: true, bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
#else
        false
#endif
    }
    var usesNativeIdlePreview: Bool { usesSharedIdlePreview && !isVideoCaptureProfileActive }
    private(set) var photoExposureSnapshot: PhotoExposureSnapshot?
    /// The exposure control's own presentation state while Photo owns the graph:
    /// the operator's ISO survives the device snapshots that acknowledge it
    /// asynchronously (see `PhotoExposureIntentPresentation`).
    private var photoExposureIntent: PhotoExposureIntentPresentation?
    private(set) var isPhotoCaptureBusy = false
    private(set) var photoCaptureStatus: String?
    /// The banner this mode's shutter raised for a refused tap, so a later
    /// successful capture clears only its own message. Readable by the photo
    /// status strip: a refusal the operator cannot see is a dead shutter.
    private(set) var photoShutterNotice: String?
    /// Clears the transient notice after it has been read.
    @ObservationIgnored private var photoShutterNoticeTask: Task<Void, Never>?
    /// Releases the shutter if a capture never reports back. Nothing may leave the
    /// control permanently busy with no explanation.
    @ObservationIgnored private var photoCaptureWatchdog: Task<Void, Never>?
    var developmentPhotoStockID: String = "kodak5207"
    var developmentPhotoGauge: PrintGauge = .neutral
    var photoCropZoom: Double = 1
    private var photoGeneration: UInt64 = 0
    private var videoExposureBeforePhoto: (Bool, Float, Float)?
    private var photoPreviousIdleTimerDisabled: Bool?
    private var idleZoomTimer: Timer?

    /// Auto-exposure target bias in EV (live value; polled with the exposure
    /// readout). Only drives the scene while the device meters automatically.
    ///
    /// Unlike the session-only 60 fps mode this is a persisted preference: it
    /// starts from `CameraExposureBiasPreference` (a house default of -1.2 EV for
    /// anyone who has never moved the control) and every user change is saved, so
    /// it survives camera sessions and app launches. It is deliberately NOT reset
    /// at the foreground-session boundary.
    var liveExposureBias: Float = CameraExposureBiasPreference.load()
    /// Live metered exposure offset from the device target, in EV (positive =
    /// over). Drives the under/over indicator. `hasExposureMeter` is false until
    /// the device is configured, so the indicator can fall back cleanly.
    var liveExposureTargetOffset: Float = 0
    var hasExposureMeter = false
    // Stock-selector hint. The scene's Gray-World neutral estimate is refreshed
    // with the exposure poll and is nil whenever it is unavailable, so a hint can
    // never ride a stale reading. `hintTick` advances on every poll so the hint's
    // active-use clock still runs while an estimate happens to be unavailable.
    private(set) var neutralSceneKelvin: Float?
    private(set) var neutralSceneCapturedAt: Date?
    private(set) var hintTick: UInt64 = 0
    /// Normalised (0–1) preview point where exposure is metered: the frame
    /// centre by default, the tapped point after a tap-to-focus. Anchors the
    /// exposure box on the preview.
    var meteringPoint = CGPoint(x: 0.5, y: 0.5)

    // AD-8: Max clip duration
    static let maxClipDuration: TimeInterval = 300 // 5 minutes
    static let lowSpaceThreshold: Int64 = 1_000_000_000 // 1GB
    static let criticalSpaceThreshold: Int64 = 500_000_000 // 500MB

    private var recordingTimer: Timer?
    private var spacePollingTimer: Timer?
    private var storageSnapshotRequestGeneration: UInt64 = 0
    private var exposurePollingTimer: Timer?
    private var shutterPriorityTimer: Timer?
    private var recordingTimerGeneration = RecordingTimerGeneration()
    /// True from the record tap until the session reports the take started (or
    /// the start fails). Drives the button's immediate pressed affordance, so
    /// the control does not look dead while capture spins up.
    private(set) var isStartingRecording = false
    /// True from the stop tap until the recorder finishes finalising. Stopping a
    /// take is not instant, so the control has to acknowledge the press itself.
    private(set) var isStoppingRecording = false
    /// When the counter counts from, and when stop was requested. The origin is
    /// set at the tap plus the modelled capture delay, so the display is
    /// continuous from the press and matches the file, instead of appearing only
    /// once capture confirms — which can be two seconds later.
    private(set) var recordingTimerOrigin: Date?
    private(set) var recordingStoppedAt: Date?
    /// Bumped when a take never started, so the screen can flash its failure
    /// treatment once per failure.
    private(set) var recordingFailureToken = 0
    /// Concrete reason for the most recent failure, shown under the headline.
    private(set) var recordingFailureDetail: String?
    private var captureGeneration: UInt64 = 0
    private var exposureCommandGeneration: UInt64 = 0
    private var apertureSnapshotRequestGeneration: UInt64 = 0
    private var apertureCameraRevision: UInt64 = 0
    private var neutralSceneRequestGeneration: UInt64 = 0
    private var stabilizationSnapshotRequestGeneration: UInt64 = 0
    private var cameraLensSwitchGeneration: UInt64 = 0
    private var pendingLensSwitchCount = 0
    /// Focal-length pinch engine. Coalesces pinch updates across a physical lens
    /// switch and keeps the gesture continuous in absolute focal length.
    private var focalEngine = CameraFocalZoomEngine(activeTier: .wide)
    /// True only while a lens switch the pinch engine itself requested is in
    /// flight, so its queued target survives the switch while a manual lens
    /// switch is never commandeered.
    private var focalSwitchInFlight = false
    /// Rear/front lenses the device reports, cached for the engine's fallbacks.
    private var availableLensTiers: [CameraFocalZoomLensTier] = []
    private var apertureCommandGeneration: UInt64 = 0
    private let originalStorage = CameraOriginalStorage()
    /// Marks a take before capture and is acknowledged once the render queue has
    /// durably accepted it. If the app dies in between, the file is reconciled at
    /// next launch as an original-only rescue rather than being lost.
    private let captureJournal = CaptureJournal()
    private var lifecycleGate = CameraLifecycleGate()
    private var configurationInFlight = false
    private var cameraConfigured = false
#if DEBUG
    private var didStartDebugSmokeCapture = false
    private var debugPhotoExperimentInFlight = false
#endif

    // MARK: - Diagnostics

    /// Opt-in lifecycle trace (`--trace-photo-exposure`). Shares the capture
    /// trace file so one pull explains a stalled mode or a dead camera.
    private func trace(_ event: String) {
        guard CommandLine.arguments.contains("--trace-photo-exposure") else { return }
        let line = "Photo VM trace: t=\(ProcessInfo.processInfo.systemUptime) event=\(event) "
            + "mode=\(isDevelopmentPhotoMode) configured=\(cameraConfigured) gate=\(lifecycleGate.isActive) "
            + "profile=\(isChangingCaptureProfile) busy=\(isPhotoCaptureBusy) snapshot=\(photoExposureSnapshot != nil)"
        print(line)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("photo-exposure-trace.txt")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd(); try? file.write(contentsOf: (line + "\n").data(using: .utf8)!)
        }
    }

    // MARK: - Actions

    func onAppear() {
        // Request the camera first (it's the critical path). The microphone is
        // requested after the session is configured, to avoid stacking two
        // system permission dialogs at launch (which can leave the app stuck
        // on the launch screen).
        activateCameraIfNeeded()
    }

    func onSceneActive() {
        trace("scene-active-enter")
        activateCameraIfNeeded()
    }

    func onSceneInactive() {
        trace("scene-inactive-enter")
        endSlowZoom()
        guard lifecycleGate.isActive else { return }
        lifecycleGate.deactivate()
#if DEBUG
        photoGeneration &+= 1
        isPhotoCaptureBusy = false
        photoExposureSnapshot = nil
        if usesSharedIdlePreview { isChangingCaptureProfile = true }
#endif
        // A foreground-session boundary resets the session-only frame rate to
        // 24 fps (daylight branch) and drops any in-flight focal gesture (mood
        // branch). Both are independent device-config concerns; neither may be
        // dropped in favor of the other.
        resetFrameRateForSessionBoundary()
        focalEngine.invalidate()
        focalSwitchInFlight = false
        exposureCommandGeneration &+= 1
        cameraLensSwitchGeneration &+= 1
        apertureCommandGeneration &+= 1
        isSwitchingCameraLens = pendingLensSwitchCount > 0
        invalidateApertureUIState()
        invalidateStabilizationUIState()
        if isStartingRecording {
            captureGeneration &+= 1
            isStartingRecording = false
            session.stopRecording()
        } else if isRecording {
            session.stopRecording()
        }
        invalidateRecordingTimers()
        cameraConfigured = false
        session.stop()
        session.disableShutterPriority()
        stopPolling()
        storageSnapshotRequestGeneration &+= 1
        stopExposurePolling()
        stopShutterPriorityLoop()
    }

    private func activateCameraIfNeeded() {
        guard let generation = lifecycleGate.activate() else { trace("activate-rejected"); return }
        requestCameraAccess(generation: generation)
    }

    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            // Idempotent. This also covers a mic that was denied at launch and
            // then enabled in Settings: without re-attaching, the session would
            // record silent video and report it as a clean success.
            session.addMicrophoneInput()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self, granted else { return }
                Task { @MainActor in
                    self.session.addMicrophoneInput()
                }
            }
        case .denied, .restricted:
            break // record video-only
        @unknown default:
            break
        }
    }

    private func requestCameraAccess(generation: UInt64) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if errorMessage == "Camera access denied. Enable it in Settings."
                || errorMessage == "Camera access is required to record video." {
                errorMessage = nil
            }
            configureAndStart(generation: generation)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    guard self.lifecycleGate.accepts(generation) else { return }
                    if granted {
                        self.configureAndStart(generation: generation)
                    } else {
                        self.errorMessage = "Camera access is required to record video."
                    }
                }
            }
        case .denied, .restricted:
            errorMessage = "Camera access denied. Enable it in Settings."
        @unknown default:
            errorMessage = "Unknown camera authorization status."
        }
    }

    private func configureAndStart(generation: UInt64) {
        guard lifecycleGate.accepts(generation), !configurationInFlight, !cameraConfigured else {
            trace("configure-skipped gate=\(lifecycleGate.accepts(generation)) inflight=\(configurationInFlight) configured=\(cameraConfigured)")
            return
        }
        configurationInFlight = true
        // Configure asynchronously: session setup touches camera hardware and
        // used to block the main thread, which froze launch until the run loop
        // was allowed to spin ("app doesn't load until I hit stop").
        session.configure { [weak self] error in
            guard let self else { return }
            self.configurationInFlight = false
            guard self.lifecycleGate.accepts(generation) else {
                if self.lifecycleGate.isActive {
                    self.configureAndStart(generation: self.lifecycleGate.generation)
                }
                return
            }
            if let error {
                self.errorMessage = error.localizedDescription
                return
            }
            self.cameraConfigured = true
            self.refreshDaylight60Eligibility()
            self.startSession()
        }
    }

    /// Runs on the main queue once the session has been configured.
    private func startSession() {
        if usesSharedIdlePreview { isChangingCaptureProfile = true }
#if DEBUG
        if debugPhotoExperimentInFlight {
            isChangingFrameRate = true
            session.start()
            return
        }
#endif
        session.onCameraOperationError { [weak self] error, sourceLens in
            guard let self,
                  !self.isSwitchingCameraLens,
                  sourceLens == self.activeLens else { return }
            self.errorMessage = error.localizedDescription
            self.recoverCaptureConfigurationIfNeeded(after: error)
        }
        session.onFinish { [weak self] result in
            Task { @MainActor in
                await self?.handleRecordingFinished(result)
            }
        }
        session.start()
#if DEBUG
        CameraRangeDump.dumpIfRequested()
        if !didStartDebugSmokeCapture, CommandLine.arguments.contains("--smoke-photo-transitions") {
            didStartDebugSmokeCapture = true
            UIApplication.shared.isIdleTimerDisabled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: .seconds(2))
                    @MainActor func mode(_ enabled: Bool) async throws {
                        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                            self.setDevelopmentPhotoMode(enabled) { c.resume(with: $0) }
                        }
                    }
                    try await mode(true)
                    if CommandLine.arguments.contains("--smoke-photo-cadence") {
                        self.session.setDevelopmentPhotoDuration(0.5)
                        for index in 0..<60 {
                            self.session.setDevelopmentPhotoISO(Float(200 + index * 5))
                        }
                        try await Task.sleep(for: .seconds(6))
                        self.session.setDevelopmentPhotoISOLocked(false)
                        try await Task.sleep(for: .seconds(8))
                        let dng: URL = try await withCheckedThrowingContinuation { c in
                            self.session.captureDevelopmentPhoto { c.resume(with: $0) }
                        }
                        print("Photo cadence: slow capture passed \(dng.lastPathComponent)")
                        try await mode(false)
                        self.session.startDebugSmokeCapture()
                        return
                    }
                    for value: Float in [200, 400, 800, 400] {
                        self.session.setDevelopmentPhotoISO(value)
                        self.session.setDevelopmentPhotoISOLocked(false)
                        self.session.setDevelopmentPhotoISOLocked(true)
                    }
                    try await Task.sleep(for: .seconds(3))
                    for lens in self.session.availableLenses where lens != .front {
                        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                            self.selectLens(lens) { error in
                                if let error { c.resume(throwing: error) } else { c.resume() }
                            }
                        }
                        print("Photo transitions: lens=\(lens.rawValue) passed")
                        self.setFocalLengthZoom(Double(lens.focalLengthMM) * 1.2)
                        try await Task.sleep(for: .milliseconds(300))
                        let dng: URL = try await withCheckedThrowingContinuation { c in
                            self.session.captureDevelopmentPhoto { c.resume(with: $0) }
                        }
                        let evidenceURL = dng.deletingLastPathComponent().appendingPathComponent("capture.json")
                        let evidence = try JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL)) as? [String: String]
                        guard evidence?["dngReadable"] == "true", evidence?["status"] == "complete" else {
                            throw CameraError.writerUnavailable("Selected lens did not capture a validated DNG")
                        }
                        print("Photo transitions: RAW lens=\(lens.rawValue) passed")
                    }
                    if let maximumISO = self.photoExposureSnapshot?.isoRange.upperBound {
                        self.session.setDevelopmentPhotoISO(maximumISO)
                        try await Task.sleep(for: .seconds(1))
                    }
                    try await mode(false)
                    try await mode(true)
                    self.onSceneInactive()
                    try await Task.sleep(for: .seconds(2))
                    self.onSceneActive()
                    for _ in 0..<150 {
                        if self.isDevelopmentPhotoMode && !self.isChangingFrameRate && self.photoExposureSnapshot?.canCapture == true { break }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    guard self.isDevelopmentPhotoMode, self.photoExposureSnapshot?.canCapture == true else {
                        throw CameraError.writerUnavailable("Photo foreground did not recover")
                    }
                    print("Photo transitions: foreground recovered")
                    try await mode(false)
                    print("Photo transitions: passed; starting restored Video proof")
                    self.session.startDebugSmokeCapture()
                } catch { print("Photo transitions: FAILED \(error)") }
            }
            return
        }
        if !didStartDebugSmokeCapture, CommandLine.arguments.contains("--smoke-photo-delivery") {
            didStartDebugSmokeCapture = true
            UIApplication.shared.isIdleTimerDisabled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                if CommandLine.arguments.contains("--photo-stock-5219") { self.developmentPhotoStockID = "kodak5219" }
                try? await Task.sleep(for: .seconds(2))
                self.setDevelopmentPhotoMode(true) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            for _ in 0..<100 {
                                if self.photoExposureSnapshot?.canCapture == true { break }
                                try? await Task.sleep(for: .milliseconds(200))
                            }
                            self.takeDevelopmentPhoto()
                        }
                    case .failure(let error): print("Photo delivery smoke failed: \(error)")
                    }
                }
            }
            return
        }
        if !didStartDebugSmokeCapture, CommandLine.arguments.contains("--smoke-photo-exposure-p0b") {
            didStartDebugSmokeCapture = true
            debugPhotoExperimentInFlight = true
            isChangingFrameRate = true
            UIApplication.shared.isIdleTimerDisabled = true
            stopExposurePolling()
            stopShutterPriorityLoop()
            session.startDebugPhotoExposureSmoke { [weak self] result in
                guard let self else { return }
                self.debugPhotoExperimentInFlight = false
                self.isChangingFrameRate = false
                switch result {
                case .success(let directory):
                    print("Photo exposure P0b passed: \(directory.path)")
                    if self.lifecycleGate.isActive {
                        self.startSession()
                        if CommandLine.arguments.contains("--keep-hevc-log2-smoke") { self.session.startDebugSmokeCapture() }
                    }
                case .failure(let error):
                    print("Photo exposure P0b failed: \(error)")
                    self.cameraConfigured = false
                    self.errorMessage = "Photo exposure check failed: \(error.localizedDescription)"
                }
            }
            return
        }
        if !didStartDebugSmokeCapture, CommandLine.arguments.contains("--smoke-photo-raw-p0") {
            didStartDebugSmokeCapture = true
            debugPhotoExperimentInFlight = true
            isChangingFrameRate = true
            UIApplication.shared.isIdleTimerDisabled = true
            stopExposurePolling()
            stopShutterPriorityLoop()
            session.startDebugPhotoRawCapture { [weak self] result in
                guard let self else { return }
                self.debugPhotoExperimentInFlight = false
                self.isChangingFrameRate = false
                switch result {
                case .success:
                    guard self.lifecycleGate.isActive else { return }
                    self.startSession()
                    if CommandLine.arguments.contains("--keep-hevc-log2-smoke") {
                        self.session.startDebugSmokeCapture()
                    }
                case .failure(let error):
                    self.cameraConfigured = false
                    if self.lifecycleGate.isActive {
                        self.errorMessage = "Photo RAW P0 failed: \(error.localizedDescription)"
                    }
                }
            }
            return
        }
        if !didStartDebugSmokeCapture,
           CommandLine.arguments.contains("--smoke-hevc-log2-capture") {
            didStartDebugSmokeCapture = true
            // Automated capture matrices must not become lock-screen failures
            // while the console connection is still collecting evidence.
            UIApplication.shared.isIdleTimerDisabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.session.startDebugSmokeCapture()
            }
        }
#endif

        // Mic is added by configure() when already authorized; request it
        // here (after start) only for the first-launch grant case.
        requestMicrophoneAccess()
        startExposurePolling()
        startSpacePolling()
        refreshExposure()
        // Apply the persisted compensation to the freshly configured session
        // before shutter priority pins, so the first metered frame already
        // carries it. Queued ahead of `enableShutterPriority` on the same serial
        // session queue, so the pin reads the new value.
        session.setExposureBiasEV(videoExposureBeforePhoto?.2 ?? liveExposureBias)
        let recordingManual = videoExposureBeforePhoto?.0 ?? isManualExposure
        let recordingISO = videoExposureBeforePhoto?.1 ?? manualISO
        if recordingManual {
            session.lockManualExposure(iso: recordingISO) { [weak self] error in
                guard let self else { return }
                if let error { self.errorMessage = "Failed to restore manual ISO: \(error.localizedDescription)" }
            }
        } else {
            // Default to 180° shutter priority: shutter locked to 1/48s, ISO auto-meters.
            session.enableShutterPriority()
            startShutterPriorityLoop()
        }
    }

    func onDisappear() {
        onSceneInactive()
    }

    func setDisplayZoom(_ factor: Double) {
        guard !isPhotoCaptureBusy, !isChangingCaptureProfile, !isStartingRecording, !isStoppingRecording else { return }
        if usesNativeIdlePreview {
            guard factor.isFinite, !isSwitchingCameraLens, !isChangingFrameRate else { return }
            photoCropZoom = min(max(factor / (zoomSnapshot?.displayMultiplier ?? 1), 1), 4)
            return
        }
        guard lifecycleGate.isActive, let snapshot = zoomSnapshot,
              !isSwitchingCameraLens, !isChangingFrameRate else { return }
        session.setDisplayZoom(factor, revision: snapshot.cameraRevision)
    }

    func beginSlowZoom(_ direction: CameraZoomDirection) {
        if usesNativeIdlePreview {
            guard !isPhotoCaptureBusy, !isChangingCaptureProfile, !isStartingRecording,
                  !isRecording, !isStoppingRecording, lifecycleGate.isActive,
                  !isSwitchingCameraLens, !isChangingFrameRate else { return }
            idleZoomTimer?.invalidate()
            idleZoomTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.usesNativeIdlePreview, !self.isChangingCaptureProfile,
                          !self.isStartingRecording, !self.isPhotoCaptureBusy else { return }
                    self.photoCropZoom = min(max(self.photoCropZoom + (direction == .in ? 0.01 : -0.01), 1), 4)
                }
            }
            return
        }
        guard lifecycleGate.isActive, let snapshot = zoomSnapshot,
              !isSwitchingCameraLens, !isChangingFrameRate else { return }
        session.beginSlowZoom(direction, revision: snapshot.cameraRevision)
    }

    func endSlowZoom(revision: UInt64? = nil) {
        idleZoomTimer?.invalidate()
        idleZoomTimer = nil
        guard let revision = revision ?? zoomSnapshot?.cameraRevision else { return }
        session.endSlowZoom(revision: revision)
    }

    /// One bounded display-zoom step, clamped to the published window. Shared by
    /// the manual panel's hold controls and the in-frame zoom arrows so both
    /// move the zoom by exactly one increment per tap or VoiceOver activation.
    func stepDisplayZoom(_ direction: CameraZoomDirection) {
        guard lifecycleGate.isActive, !isPhotoCaptureBusy, !isChangingCaptureProfile,
              !isStartingRecording, !isStoppingRecording, !isSwitchingCameraLens else { return }
        if usesNativeIdlePreview {
            photoCropZoom = min(max(photoCropZoom + (direction == .in ? 0.1 : -0.1), 1), 4)
            return
        }
        guard let snapshot = zoomSnapshot else { return }
        let delta = direction == .in ? 0.1 : -0.1
        setDisplayZoom(min(max(snapshot.displayFactor + delta,
                               snapshot.minimumDisplayFactor), snapshot.maximumDisplayFactor))
    }

    // MARK: - Focal-Length Pinch Zoom

    /// Absolute, 35 mm-equivalent focal length the preview is rendering right
    /// now. Derived from the session's published display factor and the active
    /// device's real display multiplier, anchored on the active lens's native
    /// base focal length.
    var currentFocalLengthMM: Double {
        if usesNativeIdlePreview { return Double(activeLens.focalLengthMM) * photoCropZoom }
        guard let snapshot = zoomSnapshot,
              let millimeters = CameraFocalZoomPolicy.focalLengthMM(
                  displayFactor: snapshot.displayFactor,
                  multiplier: snapshot.displayMultiplier,
                  tier: Self.focalTier(for: activeLens)) else {
            return Double(activeLens.focalLengthMM)
        }
        return millimeters
    }

    /// The focal-length window the active lens can actually render, converted
    /// from the session's published display-factor bounds with the same
    /// tier/multiplier converter `currentFocalLengthMM` uses, so the ruler and
    /// the live readout can never disagree. Nil with no snapshot; the in-frame
    /// ruler then falls back to a bounded neighbourhood of the current value
    /// rather than the old fixed 13…150 rail.
    var focalLengthRulerRange: ClosedRange<Double>? {
        if usesNativeIdlePreview {
            let base = Double(activeLens.focalLengthMM)
            return base...(base * 4)
        }
        guard let snapshot = zoomSnapshot else { return nil }
        return CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: snapshot.minimumDisplayFactor,
            maximumDisplayFactor: snapshot.maximumDisplayFactor,
            multiplier: snapshot.displayMultiplier,
            tier: Self.focalTier(for: activeLens))
    }

    /// The focal length the UI should show for a raw pinch target — the honest,
    /// hardware-clamped readout and haptic value, not the value handed to the
    /// engine. Returns nil for non-finite input or when no rear lens exists.
    ///
    /// The UI calls this BEFORE `setFocalLengthZoom` for its readout and tick
    /// haptics, so neither can announce a focal length the hardware will not
    /// reach: requesting 13 mm without an ultrawide stays at the wide lens's
    /// floor, and a target past the wide device's ceiling is clamped to the
    /// ceiling rather than shown past the rail. `setFocalLengthZoom` separately
    /// receives the raw intent, and the engine and this normalizer share the
    /// hysteresis-aware `tier(forFocalLength:currentlyOn:)` so they never
    /// disagree about whether a switch is warranted.
    func normalizedFocalLengthZoom(_ millimeters: Double) -> Double? {
        guard let requested = CameraFocalZoomPolicy.clampedTarget(millimeters) else { return nil }
        let activeTier = Self.focalTier(for: activeLens)

        // The front camera never switches away; it only clamps within its own
        // published window.
        if activeTier == .front {
            return clampToActiveZoomWindow(requested, tier: .front) ?? requested
        }

        // Switch decision is hysteresis-aware and shares the engine's policy:
        // while the pinch sits inside the deadband around a boundary the active
        // lens is held, so the readout agrees with the lens that will actually
        // render. A target that clears the band still resolves to its preference
        // (and may jump straight across the wide span).
        let desired = CameraFocalZoomPolicy.tier(forFocalLength: requested, currentlyOn: activeTier)
        guard let resolved = CameraFocalZoomPolicy.resolvedTier(desired, available: availableLensTiers) else {
            return nil
        }
        // Already on that lens: clamp to the device's real achievable window,
        // converted with its own multiplier.
        if resolved == activeTier {
            return clampToActiveZoomWindow(requested, tier: activeTier) ?? requested
        }
        // A switch is required: the new device's ceiling is unknown until it is
        // installed, so pin the floor to its native base focal length.
        return max(requested, CameraFocalZoomPolicy.baseFocalLengthMM(for: resolved))
    }

    /// Clamp `requested` into the active device's real achievable focal-length
    /// window. Nil when there is no snapshot to convert.
    private func clampToActiveZoomWindow(_ requested: Double, tier: CameraFocalZoomLensTier) -> Double? {
        if usesNativeIdlePreview {
            let base = CameraFocalZoomPolicy.baseFocalLengthMM(for: tier)
            return min(max(requested, base), base * 4)
        }
        guard let snapshot = zoomSnapshot,
              let minimum = CameraFocalZoomPolicy.focalLengthMM(
                  displayFactor: snapshot.minimumDisplayFactor,
                  multiplier: snapshot.displayMultiplier, tier: tier),
              let maximum = CameraFocalZoomPolicy.focalLengthMM(
                  displayFactor: snapshot.maximumDisplayFactor,
                  multiplier: snapshot.displayMultiplier, tier: tier),
              minimum <= maximum else { return nil }
        return min(max(requested, minimum), maximum)
    }

    /// Drive the zoom to an absolute focal length. Targets below 24 mm ask for
    /// the ultrawide, 24–96 mm the wide and above 96 mm the telephoto; a lens is
    /// switched only when the capture is idle, and the gesture stays continuous
    /// in absolute focal length across that switch. Non-finite input is ignored.
    func setFocalLengthZoom(_ millimeters: Double) {
        // Pinching must not race a take: no engine command while starting,
        // recording or stopping, and none once the session is torn down.
        // A frame-rate transition owns the device configuration, so a pinch
        // must not start or continue while the format is being reconfigured.
        guard lifecycleGate.isActive, cameraConfigured, !isChangingFrameRate, !isChangingCaptureProfile, !isPhotoCaptureBusy,
              !isStartingRecording, !isRecording, !isStoppingRecording,
              let snapshot = zoomSnapshot,
              let target = CameraFocalZoomPolicy.clampedTarget(millimeters) else { return }
        // The engine decides on the RAW gesture intent, only clamped to the
        // valid 13...400 mm range. It must not be pre-clamped to the active
        // lens's device window: during an in-flight switch that window still
        // belongs to the *old* lens, so a clamp there would corrupt the
        // coalesced target (e.g. a 96.5 mm dither pinching onto a wide device
        // whose ceiling is far below 96 mm) and re-issue a reverse switch. The
        // visible readout/haptics are clamped independently by
        // `normalizedFocalLengthZoom`, and the session clamps the factor to the
        // active device's real achievable window in `setDisplayZoom`.
        if isSwitchingCameraLens {
            // Only the pinch engine's own queued switch keeps collecting updates;
            // a manual switch owns the device and must not be commandeered.
            guard focalSwitchInFlight else { return }
            _ = focalEngine.request(targetMM: target, available: availableLensTiers)
            return
        }
        focalEngine.syncActiveTier(Self.focalTier(for: activeLens))
        let decision = focalEngine.request(targetMM: target, available: availableLensTiers)
        performFocal(decision, revision: snapshot.cameraRevision, multiplier: snapshot.displayMultiplier)
    }

    /// Drive a decision to the session. `targetMM` is the raw pinch intent from
    /// the engine (clamped only to 13...400 mm); `multiplier` is the active
    /// device's real display multiplier, so the display factor is converted on
    /// the tier's own native base and the session clamps it to the device's
    /// achievable window in `setDisplayZoom`.
    private func performFocal(_ decision: CameraFocalZoomEngine.Decision,
                              revision: UInt64, multiplier: Double) {
        switch decision {
        case .ignore:
            break
        case .adjust(let tier, let targetMM):
            guard let factor = CameraFocalZoomPolicy.displayFactor(
                forFocalLengthMM: targetMM, multiplier: multiplier, tier: tier) else { return }
            if usesNativeIdlePreview {
                photoCropZoom = min(max(targetMM / Double(activeLens.focalLengthMM), 1), 4)
            } else {
                session.setDisplayZoom(factor, revision: revision)
            }
        case .switchLens(let tier, _):
            beginFocalLensSwitch(to: tier)
        }
    }

    private func beginFocalLensSwitch(to tier: CameraFocalZoomLensTier) {
        // Never open a switch while a frame-rate transition owns the device: the
        // lens switch would race the format change and its completion would be
        // dropped, stranding `focalSwitchInFlight`.
        guard !focalSwitchInFlight, !isChangingFrameRate else { return }
        focalSwitchInFlight = true
        let requestGeneration = cameraLensSwitchGeneration &+ 1
        selectLens(Self.cameraLens(for: tier), preservingFocalZoom: true) { [weak self] error in
            guard let self, self.cameraLensSwitchGeneration == requestGeneration else { return }
            self.focalSwitchInFlight = false
            if error != nil {
                // The switch rolled back: drop the gesture instead of replaying
                // it against the lens that is actually installed.
                self.focalEngine.invalidate()
                self.focalEngine.syncActiveTier(Self.focalTier(for: self.activeLens))
                return
            }
            self.applyFocalAfterSwitch()
        }
    }

    /// Apply the coalesced target once the physical switch has committed, using
    /// the fresh camera revision the switch published.
    private func applyFocalAfterSwitch() {
        // A frame-rate transition that began while the switch was in flight
        // invalidates the gesture instead of replaying it on the new format.
        guard lifecycleGate.isActive, cameraConfigured, !isChangingFrameRate,
              !isStartingRecording, !isRecording, !isStoppingRecording,
              let snapshot = zoomSnapshot else {
            focalEngine.invalidate()
            return
        }
        let decision = focalEngine.switchCommitted(to: Self.focalTier(for: activeLens),
                                                   available: availableLensTiers)
        performFocal(decision, revision: snapshot.cameraRevision, multiplier: snapshot.displayMultiplier)
    }

    private static func focalTier(for lens: CameraLens) -> CameraFocalZoomLensTier {
        switch lens {
        case .ultraWide: return .ultraWide
        case .wide: return .wide
        case .telephoto: return .telephoto
        case .front: return .front
        }
    }

    private static func cameraLens(for tier: CameraFocalZoomLensTier) -> CameraLens {
        switch tier {
        case .ultraWide: return .ultraWide
        case .wide: return .wide
        case .telephoto: return .telephoto
        case .front: return .front
        }
    }

    func startRecording() {
        // A frame-rate transition owns the device configuration and exposure;
        // do not start a take on a rate that is still changing.
        guard !isStartingRecording, !isRecording, !isStoppingRecording,
              !isSwitchingCameraLens, !isChangingFrameRate, !isChangingCaptureProfile,
              !isDevelopmentPhotoMode, !isPhotoCaptureBusy else { return }
        guard lifecycleGate.isActive, cameraConfigured else {
            errorMessage = "Camera is not ready to record."
            return
        }
        // Any pending lens switch must settle first: starting a take while the
        // session reconfigures the input would race the switch. This blocks the
        // engine's own queued switch (`focalSwitchInFlight`) and a manual lens
        // switch (`isSwitchingCameraLens`) alike, not only the pinch case.
        guard !focalSwitchInFlight, !isSwitchingCameraLens else {
            errorMessage = "Wait for the lens to finish switching before recording."
            return
        }
        guard !isSpaceCritical else {
            errorMessage = "Not enough free space. Please free up at least 500MB."
            return
        }

        // A take owns the device; drop any pinch gesture so it cannot replay
        // against the hardware afterwards.
        focalEngine.invalidate()
        endSlowZoom()
        invalidateRecordingTimers()
        exposureCommandGeneration &+= 1
        isStartingRecording = true
        recordingWarning = nil
        captureGeneration &+= 1
        let generation = captureGeneration
        // The counter starts at the tap: capture begins about 0.2 s later, and the
        // writer may not confirm that for another two seconds.
        recordingTimerOrigin = RecordButtonTimingPolicy.timerOrigin(tapAt: Date())
        recordingStoppedAt = nil
        do {
            let outputURL = try originalStorage.makeDestination()
            // Bind policy to the actual destination before any async work.
            // Cancellation advances captureGeneration, and a foreground reset
            // changes sessionFrameRate; neither can relabel this take's URL.
            capturePolicies.record(sourceURL: outputURL, mode: sessionFrameRate)
            captureJournal.markPending(outputURL)
#if DEBUG
            if usesSharedIdlePreview { session.setVideoRecordingZoomIntent(photoCropZoom) }
#endif
            session.startRecording(to: outputURL) { [weak self] error in
                guard let self else { return }
                // A stale callback must not touch the session: captureGeneration
                // advances both when the user cancels a pending start and when a
                // new take begins, so calling stopRecording() here would stop
                // whichever take is now live.
                guard self.captureGeneration == generation else { return }
                guard self.lifecycleGate.isActive else {
                    if error == nil { self.session.stopRecording() }
                    return
                }
                self.isStartingRecording = false
                self.refreshRecordingStabilization()
                if let error {
                    self.isRecording = false
                    self.invalidateRecordingTimers()
                    self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
                    self.failRecordingProminently(error)
                    self.recoverCaptureConfigurationIfNeeded(after: error)
                    return
                }
                self.isRecording = true
                self.recordingDuration = 0
                self.recordingStoppedAt = nil
                self.isStoppingRecording = false
                self.startRecordingTimer()
                self.startSpacePolling()
            }
        } catch {
            isStartingRecording = false
            errorMessage = "Failed to prepare recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        // The take owns the device; any queued pinch gesture is now stale.
        focalEngine.invalidate()
        let wasStarting = isStartingRecording
        if wasStarting { captureGeneration &+= 1 }
        isStartingRecording = false
        if wasStarting, !isRecording {
            // Cancelling a pending start. The take never began, so the recorder
            // produces no file and never reports a finish — this is the only place
            // that can clear the counter, and without it the counter would keep
            // running with nothing behind it.
            recordingTimerOrigin = nil
            recordingStoppedAt = nil
            isStoppingRecording = false
        } else if isRecording {
            // Acknowledge the stop on the tap. The recorder still has to drain and
            // finalise, which can take seconds; without this the control keeps its
            // running look and the press appears to have been ignored.
            isStoppingRecording = true
            recordingStoppedAt = Date()
        }
        invalidateStabilizationUIState()
        session.stopRecording()
        refreshRecordingStabilization()
        invalidateRecordingTimers()
    }

    func handleFocusTap(at point: CGPoint, in previewLayer: AVCaptureVideoPreviewLayer) {
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        session.setFocusAndExposurePoint(devicePoint)
    }

#if DEBUG
    /// Debug-only: capture one frame from the live camera for the debug
    /// single-frame sheet. `completion` runs on the main thread (mirrors the
    /// plain completion `selectLens` uses).
    func captureDebugFrame(completion: @escaping (CVPixelBuffer?) -> Void) {
        let completionBox = UncheckedSendableBox(completion)
        session.captureDebugFrame { buffer in
            let payload = SendablePixelBuffer(buffer: buffer)
            DispatchQueue.main.async { completionBox.value(payload.buffer) }
        }
    }
#endif

    /// Record where the exposure box should sit, in normalised preview
    /// coordinates. Called from the preview's tap handler alongside the focus
    /// tap, so the box follows the metering point.
    func setMeteringPoint(_ point: CGPoint) {
        meteringPoint = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    /// Switch the active lens and refresh tap-to-focus for the new device.
    /// Completion runs on the main queue; `nil` error means the swap succeeded.
    func selectLens(_ lens: CameraLens, preservingFocalZoom: Bool = false, completion: @escaping (Error?) -> Void) {
        // Photo lens changes span asynchronous graph teardown and restoration.
        // Do not admit a second chain while the first owns that graph.
        if usesNativeIdlePreview && isSwitchingCameraLens {
            completion(CameraError.frameRateTransitionInProgress)
            return
        }
        // A manual lens switch supersedes any in-flight pinch gesture; the
        // engine's own switch keeps its queued target instead.
        if !preservingFocalZoom {
            focalEngine.invalidate()
            focalSwitchInFlight = false
        }
        endSlowZoom()
        // A frame-rate transition owns the device configuration; a lens switch
        // must wait for it to settle rather than race it.
        guard !isChangingFrameRate, !isChangingCaptureProfile, !isPhotoCaptureBusy else {
            completion(CameraError.frameRateTransitionInProgress)
            return
        }
        exposureCommandGeneration &+= 1
        cameraLensSwitchGeneration &+= 1
        pendingLensSwitchCount += 1
        apertureCommandGeneration &+= 1
        isSwitchingCameraLens = true
        clearStaleApertureError()
        invalidateApertureUIState()
        invalidateStabilizationUIState()
        session.selectCamera(lens) { [weak self] error in
            guard let self else { return }
            if error == nil {
                // Session switches are serialized. Record each successful
                // commit even when a later request is still pending, so a
                // subsequent failure leaves the UI on the actual camera.
                self.activeLens = lens
                self.photoCropZoom = 1
            }
            self.pendingLensSwitchCount = max(0, self.pendingLensSwitchCount - 1)
            self.isSwitchingCameraLens = self.pendingLensSwitchCount > 0

            // Track the lens the session actually installed for the focal
            // engine; a manual switch drops its gesture, the engine's own switch
            // drains its coalesced target after this completion.
            if !self.focalSwitchInFlight {
                self.focalEngine.syncActiveTier(Self.focalTier(for: self.activeLens))
            }

            if self.pendingLensSwitchCount == 0 {
                if self.lifecycleGate.isActive {
                    if !self.usesNativeIdlePreview {
                        self.restoreExposureAfterLensSwitch()
                        self.refreshExposure()
                    }
                } else {
                    self.invalidateApertureUIState()
                }
                // A lens switch can change 60 fps eligibility. Refresh it, but
                // never silently disarm an armed mode on a failed switch.
                self.refreshDaylight60Eligibility()
            }
            // Resolve every caller. ContentView commits each successful lens;
            // failures remain visible while they never replace the committed
            // selection.
            completion(error)
        }
    }

    private func restoreExposureAfterLensSwitch() {
        if isManualExposure {
            let generation = exposureCommandGeneration
            session.lockManualExposure(iso: manualISO) { [weak self] error in
                guard let self, self.exposureCommandGeneration == generation,
                      !self.isSwitchingCameraLens else { return }
                if let error { self.errorMessage = error.localizedDescription }
                self.refreshExposure()
            }
        } else {
            session.enableShutterPriority()
        }
    }

    func toggleShutterLock(currentShutter: Float64) {
        exposure.toggleShutterLock(currentShutter: currentShutter)
    }

    func toggleISOLock(currentISO: Float) {
#if DEBUG
        if isDevelopmentPhotoMode {
            guard !isPhotoCaptureBusy, !isChangingFrameRate, !isChangingCaptureProfile, let state = photoExposureSnapshot else { return }
            session.setDevelopmentPhotoISOLocked(!state.isoLocked)
            return
        }
#endif
        exposure.toggleISOLock(currentISO: currentISO)
    }

    /// A failed rollback/reset invalidates the runtime configuration. Reconnect
    /// once, rather than leaving the UI marked ready until another scene boundary.
    private func recoverCaptureConfigurationIfNeeded(after error: Error) {
        guard let cameraError = error as? CameraError,
              case .captureRecoveryRequired = cameraError else { return }
        cameraConfigured = false
        if usesSharedIdlePreview {
            // A persistent idle-install fault must surface, not reconnect forever.
            guard !sharedIdleRecoveryAttempted else { return }
            sharedIdleRecoveryAttempted = true
        }
        guard lifecycleGate.isActive else { return }
        configureAndStart(generation: lifecycleGate.generation)
    }

    // MARK: - Daylight 60 fps (session-only)

    /// True when the session-only frame-rate switch can run: the camera is live,
    /// no lens/mode transition is in flight, and no take is pending, active or
    /// draining. Mirrors the recording-stabilization gate.
    var canChangeSessionFrameRate: Bool {
        // A focal lens switch owns the device configuration just as a manual
        // lens switch does, so the frame-rate transition cannot race it.
        lifecycleGate.isActive && cameraConfigured && !isSwitchingCameraLens && !isChangingFrameRate && !isChangingCaptureProfile
            && !focalSwitchInFlight
            && CameraFrameRatePolicy.canChange(recording: isRecording, starting: isStartingRecording,
                                               finishing: isStoppingRecording)
    }

    /// Arm or disarm the break-glass daylight 60 fps mode. Refused while a take
    /// is pending/active/draining, during a transition, or when the device is
    /// ineligible (the control disables itself in that case). Never persisted.
    func setDaylight60Enabled(_ enabled: Bool) {
        guard !isDevelopmentPhotoMode, !isPhotoCaptureBusy else { return }
        let target: CameraFrameRate = enabled ? .daylight60 : .standard24
        guard target != sessionFrameRate, canChangeSessionFrameRate else { return }
        guard target == .standard24 || supportsDaylight60 else { return }
        // The transition claims the device configuration; any idle pinch
        // accumulation and its queued switch are stale once the format changes.
        focalEngine.invalidate()
        focalSwitchInFlight = false
        isChangingFrameRate = true
        frameRateGeneration &+= 1
        let generation = frameRateGeneration
        session.setFrameRate(target) { [weak self] error in
            guard let self, self.frameRateGeneration == generation,
                  self.lifecycleGate.isActive else { return }
            self.isChangingFrameRate = false
            if let error {
                // The previous mode is preserved; never a silent downgrade.
                self.errorMessage = "Failed to set the capture frame rate: \(error.localizedDescription)"
                self.recoverCaptureConfigurationIfNeeded(after: error)
                return
            }
            self.sessionFrameRate = target
        }
    }

    /// The capture policy snapshotted for a completed take. The screen reads this
    /// instead of the live mode, so a session-boundary reset cannot mislabel it.
    func capturePolicy(for sourceURL: URL) -> RenderCapturePolicy? {
        capturePolicies.policy(for: sourceURL)
    }

    /// Refresh the daylight-60 eligibility from the active device. Called after
    /// the camera configures and after a lens switch settles. It never silently
    /// disarms an armed mode.
    private func refreshDaylight60Eligibility() {
        guard lifecycleGate.isActive, cameraConfigured, !isSwitchingCameraLens else {
            supportsDaylight60 = false
            return
        }
        let generation = frameRateGeneration
        session.supportsDaylight60 { [weak self] supported in
            guard let self, self.frameRateGeneration == generation,
                  self.lifecycleGate.isActive, self.cameraConfigured else { return }
            self.supportsDaylight60 = supported
        }
    }

    /// A foreground-session boundary always resets the session-only mode. The
    /// runtime owns the device reset and defers it through any draining take; the
    /// UI resets immediately, which is safe because the enqueued job reads the
    /// policy captured at take start, not the live mode.
    private func resetFrameRateForSessionBoundary() {
        // Invalidate any in-flight transition: a backgrounded mode change must
        // not restore 60 fps on the next foreground session.
        frameRateGeneration &+= 1
        isChangingFrameRate = false
        sessionFrameRate = .standard24
        supportsDaylight60 = false
        // Per-URL take policies survive this reset until the queue snapshots them.
        session.resetFrameRateForNextSession()
    }

    /// The mode row's single source of truth: whether a change is accepted *and*
    /// the reason when it is not. Ten independent states dim the same letters, so
    /// the reason has to come from the same place as the decision.
    var shootingModeGate: CameraShootingModeGate {
        CameraShootingModeGate(isLifecycleActive: lifecycleGate.isActive,
                               isCameraConfigured: cameraConfigured,
                               isConfigurationInFlight: configurationInFlight,
                               isChangingFrameRate: isChangingFrameRate,
                               isChangingCaptureProfile: isChangingCaptureProfile,
                               isSwitchingCameraLens: isSwitchingCameraLens,
                               isPhotoCaptureBusy: isPhotoCaptureBusy,
                               isStartingRecording: isStartingRecording,
                               isRecording: isRecording,
                               isStoppingRecording: isStoppingRecording)
    }

    var canChangeShootingMode: Bool { shootingModeGate.isAllowed }

    /// The reason shown with the greyed row, or nil while it accepts changes.
    var shootingModeBlockedReason: String? { shootingModeGate.reason }

    func setDevelopmentPhotoMode(_ enabled: Bool,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        guard usesSharedIdlePreview, canChangeShootingMode, photoExposureSnapshot != nil else {
            trace("photo-mode-refused enabled=\(enabled) canChange=\(canChangeShootingMode) snapshot=\(photoExposureSnapshot != nil)")
            completion(.failure(CameraError.writerUnavailable("Shared idle camera is not ready")))
            return
        }
        guard enabled != isDevelopmentPhotoMode else { completion(.success(())); return }
        if enabled {
            videoExposureBeforePhoto = (isManualExposure, manualISO, liveExposureBias)
            photoPreviousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        isDevelopmentPhotoMode = enabled
#if DEBUG
        if enabled, CommandLine.arguments.contains("--ui-slow-photo") {
            session.setDevelopmentPhotoISO(400)
            session.setDevelopmentPhotoDuration(1)
        }
#endif
        photoCaptureStatus = enabled ? "Ready · experimental photo color" : nil
        if enabled, let photoExposureSnapshot { presentPhotoExposure(photoExposureSnapshot) }
        else {
            restoreVideoExposurePresentation()
            restoreIdleGraphVideoExposureContract()
        }
        completion(.success(()))
    }

    /// Leaving Photo hands the shared idle graph back to the video contract: a
    /// 180° shutter at the mode's frame rate — 1/48, or 1/120 at 60 fps — with
    /// ISO auto-metering unless the operator holds a manual ISO.
    ///
    /// The idle graph is the same camera in both modes, so without this the Photo
    /// rail's shutter stayed pinned on the device and Video idled (and metered)
    /// at the photo value instead of its own.
    private func restoreIdleGraphVideoExposureContract() {
#if DEBUG
        guard usesSharedIdlePreview else { return }
        // Photo's ISO band is wider than video's, so a held ISO has to be
        // re-clamped here or Video would idle above what its take can take.
        let contract = VideoExposureContract.idle(frameRate: sessionFrameRate,
            isManualExposure: isManualExposure, manualISO: clampedVideoISO(manualISO),
            bias: liveExposureBias)
        session.applyDevelopmentPhotoIntent(iso: contract.lockedISO,
            duration: contract.durationSeconds, ev: contract.exposureBias)
#endif
    }

    private func presentPhotoExposure(_ snapshot: PhotoExposureSnapshot) {
        if photoExposureIntent == nil {
            photoExposureIntent = PhotoExposureIntentPresentation(snapshot: snapshot)
        }
        photoExposureIntent?.reconcile(snapshot)
        let presented = photoExposureIntent
        // The presented ISO is the operator's until the device reports it back.
        // Writing the snapshot straight into `manualISO` pulled the ruler out from
        // under the finger on every publish, so each new drag delta was measured
        // from a position the operator never chose: the slider stuttered and felt
        // seconds behind the touch.
        liveISO = presented?.iso ?? snapshot.iso
        manualISO = presented?.iso ?? snapshot.iso
        isManualExposure = snapshot.isoLocked
        liveShutterSeconds = presented?.duration ?? snapshot.durationSeconds
        liveExposureBias = snapshot.ev
        liveExposureTargetOffset = snapshot.meteringOffset
        hasExposureMeter = true
    }

    private func restoreVideoExposurePresentation() {
        photoExposureIntent = nil
        if let saved = videoExposureBeforePhoto {
            isManualExposure = saved.0
            manualISO = saved.1
            liveExposureBias = saved.2
            videoExposureBeforePhoto = nil
        }
        if let previous = photoPreviousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previous
            photoPreviousIdleTimerDisabled = nil
        }
        guard lifecycleGate.isActive else { return }
        startExposurePolling()
        if !isManualExposure && !usesSharedIdlePreview { startShutterPriorityLoop() }
        refreshExposure()
    }

    func setPhotoShutterDuration(_ seconds: Double) {
#if DEBUG
        guard isDevelopmentPhotoMode, !isPhotoCaptureBusy, !isChangingFrameRate, !isChangingCaptureProfile else { return }
        session.setDevelopmentPhotoDuration(seconds)
#endif
    }

    func togglePhotoShutterLock() {
        guard let state = photoExposureSnapshot else { return }
        setPhotoShutterLocked(!state.shutterLocked)
    }

    /// Accept an explicit selection so rapid taps do not toggle a stale sensor echo.
    func setPhotoShutterLocked(_ locked: Bool) {
#if DEBUG
        guard isDevelopmentPhotoMode, !isPhotoCaptureBusy, !isChangingFrameRate, !isChangingCaptureProfile else { return }
        session.setDevelopmentPhotoShutterLocked(locked)
#endif
    }

    /// The app root accepts this capture only after the shared queue persists it.
    @ObservationIgnored var onPhotoCaptured: (@MainActor (URL, String, PrintGauge, UInt32, Double) -> UUID?)?
    private(set) var photoRenderJobID: UUID?

    /// What a shutter tap would do right now. The button reads this to explain
    /// itself; it never disables the control.
    var photoShutterReadiness: PhotoShutterReadiness {
        PhotoShutterReadinessPolicy.readiness(
            isPhotoMode: isDevelopmentPhotoMode, isChangingFrameRate: isChangingFrameRate,
            isChangingCaptureProfile: isChangingCaptureProfile, isCaptureBusy: isPhotoCaptureBusy,
            canCapture: photoExposureSnapshot?.canCapture == true)
    }

    /// Always attempt. The shutter is never disabled, so every tap reaches here
    /// and either starts a capture or says why it could not — an unresponsive
    /// control with no explanation is the one outcome that is not allowed.
    func takeDevelopmentPhoto() {
#if DEBUG
        trace("photo-tap enter")
        // The mode toggle can show Photo before the camera has engaged it, and an
        // enter that failed leaves it unengaged. A tap in either window used to
        // return here in silence, which is the one outcome the shutter may not
        // produce: the operator cannot see a reason that was never recorded.
        guard isDevelopmentPhotoMode else {
            trace("photo-tap refused not-engaged")
            let reason = "The photo camera is still starting up. Try again in a moment."
            recordPhotoShutterNotice(reason)
            errorMessage = reason
            return
        }
        let readiness = photoShutterReadiness
        trace("photo-tap readiness=\(readiness)")
        switch readiness {
        case .ready:
            break
        case .capturing:
            trace("photo-tap refused capturing")
            // A second tap must not queue a second capture, but it still has to be
            // answered.
            recordPhotoShutterNotice("A photo is already being captured.")
            return
        case .changingMode:
            trace("photo-tap refused changing-mode")
            let reason = readiness.blockedReason ?? "Wait for the camera to finish changing."
            recordPhotoShutterNotice(reason)
            return
        case .cameraNotReady:
            trace("photo-tap refused not-ready")
            let reason = "The photo camera is not ready yet. Try again in a moment."
            recordPhotoShutterNotice(reason)
            errorMessage = reason
            return
        }
        // This tap is starting a capture, so the refusal it may have shown before
        // is stale. Only this mode's own banner is cleared.
        if errorMessage == photoShutterNotice { errorMessage = nil }
        photoShutterNotice = nil
        let generation = photoGeneration
        isPhotoCaptureBusy = true
        armPhotoCaptureWatchdog(generation)
        let stockID = developmentPhotoStockID
        let gauge = developmentPhotoGauge
        let grainSeed = UInt32.random(in: .min ... .max)
        let cropZoom = photoCropZoom

        photoCaptureStatus = "Capturing RAW…"
        session.captureDevelopmentPhoto { [weak self] result in
            guard let self else { return }
            // Released before the generation check: a capture that belongs to a
            // mode the operator has left must not leave the shutter busy.
            self.photoCaptureWatchdog?.cancel()
            self.photoCaptureWatchdog = nil
            guard self.photoGeneration == generation else {
                self.trace("photo-capture-completion stale")
                return
            }
            switch result {
            case .success(let url):
                // Camera ownership ends at durable RAW capture, not GPU/Photos delivery.
                self.isPhotoCaptureBusy = false
                if let jobID = self.onPhotoCaptured?(url, stockID, gauge, grainSeed, cropZoom) {
                    self.photoRenderJobID = jobID
                    self.photoCaptureStatus = "Photo queued for development"
                } else {
                    self.photoCaptureStatus = "Original kept locally · queue unavailable"
                    self.errorMessage = "Photo could not enter the render queue. The original DNG remains in the app."
                }
            case .failure(let error):
                self.isPhotoCaptureBusy = false
                self.photoCaptureStatus = "RAW capture failed"
                self.errorMessage = error.localizedDescription
            }
        }
#endif
    }

    /// Refusals and stalls are reported where the operator can read them: the
    /// notice is transient because it reports a moment, not a state to dismiss.
    private func recordPhotoShutterNotice(_ text: String) {
        photoShutterNotice = text
        photoShutterNoticeTask?.cancel()
        photoShutterNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            if self.photoShutterNotice == text { self.photoShutterNotice = nil }
        }
    }

    /// A profile transition whose completion never lands must not leave the mode
    /// row greyed out with nothing said.
    ///
    /// `isChangingCaptureProfile` is a UI gate fed by the session's profile
    /// callback. Observed on device: a dropped update (the same class of loss as a
    /// dropped setter or capture terminal) left the row dimmed and the V/P
    /// letters disabled for the rest of the session, and a disabled control cannot
    /// even report a refusal. The deadline is generous — a real rebuild is a
    /// second or two — and clearing the gate is self-healing: if the transition
    /// really is still running, its next update sets the flag again.
    private func armCaptureProfileWatchdog() {
        guard captureProfileWatchdog == nil else { return }
        captureProfileWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, self.isChangingCaptureProfile else { return }
            self.trace("capture-profile-watchdog")
            self.isChangingCaptureProfile = false
            self.captureProfileWatchdog = nil
        }
    }

    /// A capture whose completion never arrives must not leave the shutter busy
    /// with nothing said. The deadline is the controller's own capture timeout
    /// plus slack for the round trip through the session queue.
    private func armPhotoCaptureWatchdog(_ generation: UInt64) {
        photoCaptureWatchdog?.cancel()
        photoCaptureWatchdog = Task { @MainActor [weak self] in
            // Backstop only: the session's own capture transaction deadline fires
            // first and closes the transaction, which lets this completion arrive.
            try? await Task.sleep(for: .seconds(PhotoExposureCadence.captureTransactionTimeout + 2))
            guard let self, !Task.isCancelled, self.photoGeneration == generation,
                  self.isPhotoCaptureBusy else { return }
            self.trace("photo-capture-watchdog")
            self.isPhotoCaptureBusy = false
            self.photoCaptureStatus = "RAW capture did not report back"
            self.recordPhotoShutterNotice("The camera never reported the photo. Tap the shutter to try again.")
        }
    }

    // MARK: - Manual Exposure

    func setManualISO(_ iso: Float) {
#if DEBUG
        if isDevelopmentPhotoMode {
            guard !isPhotoCaptureBusy, !isChangingFrameRate, !isChangingCaptureProfile else { return }
            let value = clampedISO(iso)
            photoExposureIntent?.selectISO(value)
            manualISO = value
            liveISO = value
            session.setDevelopmentPhotoISO(value)
            return
        }
#endif
        // The session refuses exposure changes during a take
        // (`exposureChangeDuringRecording`), so an optimistic write here would
        // display an ISO the hardware never took. Refuse before mutating, matching
        // the silent gating the other transition-limited controls use.
        // A frame-rate transition owns the exposure path; hold ISO changes too.
        guard !isChangingFrameRate, !isChangingCaptureProfile else { return }
        guard CameraManualExposureSelectionPolicy.canChangeISO(
            isStartingRecording: isStartingRecording, isRecording: isRecording,
            isStoppingRecording: isStoppingRecording) else { return }
        let iso = clampedISO(iso)
        let previousISO = manualISO
        manualISO = iso
        exposureCommandGeneration &+= 1
        let generation = exposureCommandGeneration
        session.lockManualExposure(iso: iso) { [weak self] error in
            guard let self else { return }
            guard self.exposureCommandGeneration == generation,
                  self.lifecycleGate.isActive else { return }
            if let error {
                // Reconcile the rejected selection back to the last accepted
                // value instead of leaving a value the device never applied.
                self.manualISO = CameraManualExposureSelectionPolicy.reconciledISO(
                    previous: previousISO, requested: iso, accepted: false)
                self.errorMessage = "Failed to set ISO: \(error.localizedDescription)"
                return
            }
            // A newer take owns the device now; do not flip the exposure mode
            // underneath it.
            guard !self.isRecording, !self.isStartingRecording else { return }
            isManualExposure = true
            refreshExposure()
        }
    }

    /// The ISO band the current shooting mode can honour: Photo keeps the still
    /// format's range, video the Apple Log 2 format's (see
    /// `CameraSession.videoISORange` — the tops differ per camera).
    func isoBandForCurrentMode() -> ClosedRange<Float> {
        isDevelopmentPhotoMode ? session.isoRange : session.videoISORange
    }

    /// Clamp a requested ISO to the current mode's band, so the ruler, the
    /// readout and the intent all agree on a value the take can take.
    func clampedISO(_ iso: Float) -> Float {
        let band = isoBandForCurrentMode()
        return min(max(iso, band.lowerBound), band.upperBound)
    }

    /// The video band's clamp, for paths that hand the idle graph back to Video
    /// while Photo's wider still range is still the current mode's.
    func clampedVideoISO(_ iso: Float) -> Float {
        let band = session.videoISORange
        return min(max(iso, band.lowerBound), band.upperBound)
    }

    func setLensAperture(_ aperture: Float?) {
        guard canSelectAperture, !isChangingFrameRate, !isChangingCaptureProfile,
              !isPhotoCaptureBusy, !isStartingRecording, !isRecording, !isStoppingRecording else { return }
#if DEBUG
        if usesSharedIdlePreview, !isDevelopmentPhotoMode {
            selectedLensAperture = aperture
            session.setVideoRecordingApertureIntent(aperture)
            return
        }
#endif
        apertureCommandGeneration &+= 1
        let commandGeneration = apertureCommandGeneration
        let switchGeneration = cameraLensSwitchGeneration
        session.setLensAperture(aperture) { [weak self] error in
            guard let self else { return }
            guard self.apertureCommandGeneration == commandGeneration,
                  self.cameraLensSwitchGeneration == switchGeneration,
                  !self.isSwitchingCameraLens, self.activeLens == .wide else { return }
            if let error {
                self.errorMessage = "Failed to set aperture: \(error.localizedDescription)"
            } else {
                self.clearStaleApertureError()
            }
            self.refreshExposure()
        }
    }

    private func clearStaleApertureError() {
        guard let errorMessage else { return }
        let apertureErrors = [
            CameraError.apertureExposureUnsupported.localizedDescription,
            CameraError.apertureUnavailable.localizedDescription
        ]
        if errorMessage.hasPrefix("Failed to set aperture:") || apertureErrors.contains(errorMessage) {
            self.errorMessage = nil
        }
    }

    /// Aperture adjustment is intentionally limited to the physical rear main
    /// camera. The state is also suppressed while its active format is changing.
    var canSelectAperture: Bool {
        activeLens == .wide && activeLens.position == .back
            && lifecycleGate.isActive && cameraConfigured && !isSwitchingCameraLens && !isChangingCaptureProfile
            && apertureIsVariable && !apertureStops.isEmpty
    }

    // MARK: - Recording stabilization

    var canSetRecordingStabilization: Bool {
        lifecycleGate.isActive && cameraConfigured && !isSwitchingCameraLens
            && !isStartingRecording && !isRecording && recordingStabilization.changesAllowed
    }

    func setRecordingStabilization(_ mode: CameraStabilizationMode) {
        guard canSetRecordingStabilization,
              recordingStabilization.capability.availableModes.contains(mode) else { return }
        stabilizationSnapshotRequestGeneration &+= 1
        let requestGeneration = stabilizationSnapshotRequestGeneration
        let switchGeneration = cameraLensSwitchGeneration
        session.setRecordingStabilization(mode) { [weak self] snapshot in
            guard let self, self.lifecycleGate.isActive, self.cameraConfigured,
                  !self.isSwitchingCameraLens, self.cameraLensSwitchGeneration == switchGeneration,
                  self.stabilizationSnapshotRequestGeneration == requestGeneration,
                  snapshot.cameraRevision >= self.recordingStabilization.cameraRevision else { return }
            self.recordingStabilization = snapshot
        }
    }

    private func refreshRecordingStabilization() {
        guard lifecycleGate.isActive, cameraConfigured, !isSwitchingCameraLens else { return }
        stabilizationSnapshotRequestGeneration &+= 1
        let requestGeneration = stabilizationSnapshotRequestGeneration
        let switchGeneration = cameraLensSwitchGeneration
        session.readStabilizationSnapshot { [weak self] snapshot in
            guard let self, self.lifecycleGate.isActive, self.cameraConfigured,
                  !self.isSwitchingCameraLens, self.cameraLensSwitchGeneration == switchGeneration,
                  self.stabilizationSnapshotRequestGeneration == requestGeneration,
                  snapshot.cameraRevision >= self.recordingStabilization.cameraRevision else { return }
            self.recordingStabilization = snapshot
        }
    }

    private func invalidateStabilizationUIState() {
        stabilizationSnapshotRequestGeneration &+= 1
        recordingStabilization = CameraStabilizationSnapshot(
            preferred: recordingStabilization.preferred, capability: .unavailable, activeRawValue: nil,
            cameraRevision: recordingStabilization.cameraRevision, changesAllowed: false)
    }

    // MARK: - Auto-Exposure Bias

    /// EV compensation range supported by the active device.
    var exposureBiasRange: ClosedRange<Float> {
        session.exposureBiasRange
    }

    /// True when the device reports a usable (non-degenerate) EV range.
    var isExposureBiasAvailable: Bool {
        let range = session.exposureBiasRange
        return range.upperBound > range.lowerBound
    }

    /// Set EV compensation (stops). Clamped to the device range and applied on
    /// the session queue; manual ISO mode is unaffected.
    ///
    /// `liveExposureBias` is authoritative and optimistic so the ruler tracks
    /// the finger. It is deliberately NOT re-read from the device: the shutter
    /// lock uses custom exposure mode, where the device's own bias is always 0,
    /// and the shutter-priority re-meter resets it regardless.
    func setExposureBias(_ bias: Float) {
#if DEBUG
        if isDevelopmentPhotoMode {
            guard !isPhotoCaptureBusy, !isChangingFrameRate, !isChangingCaptureProfile else { return }
            session.setDevelopmentPhotoEV(bias)
            return
        }
#endif
        guard !isChangingFrameRate, !isChangingCaptureProfile else { return }
        let range = session.exposureBiasRange
        let clamped = min(max(bias, range.lowerBound), range.upperBound)
        liveExposureBias = clamped
        // Persist what the user actually holds, after clamping, so the value
        // survives the session and the next launch.
        CameraExposureBiasPreference.save(clamped)
        session.setExposureBiasEV(clamped)
    }

    func toggleManualExposure() {
#if DEBUG
        if isDevelopmentPhotoMode {
            guard !isPhotoCaptureBusy, !isChangingFrameRate, !isChangingCaptureProfile, let state = photoExposureSnapshot else { return }
            session.setDevelopmentPhotoISOLocked(!state.isoLocked)
            return
        }
#endif
        // A frame-rate transition owns the exposure path; hold the toggle too.
        guard !isChangingFrameRate, !isChangingCaptureProfile else { return }
        if isManualExposure {
            exposureCommandGeneration &+= 1
            let generation = exposureCommandGeneration
            session.setAutoExposure { [weak self] error in
                guard let self else { return }
                guard self.exposureCommandGeneration == generation,
                      self.lifecycleGate.isActive, !self.isRecording else { return }
                if let error {
                    self.errorMessage = "Failed to unlock exposure: \(error.localizedDescription)"
                    return
                }
                isManualExposure = false
                session.enableShutterPriority()
                refreshExposure()
            }
        } else {
            // Enter manual mode at the current metered ISO (no exposure jump).
            setManualISO(liveISO > 0 ? liveISO : manualISO)
        }
    }

    private func refreshExposure() {
        if usesNativeIdlePreview, isDevelopmentPhotoMode, let photoExposureSnapshot {
            presentPhotoExposure(photoExposureSnapshot)
            refreshPhotoAperture()
            return
        }
        refreshRecordingStabilization()
        liveISO = session.currentISO
        liveShutterSeconds = session.currentShutterSeconds
        liveExposureTargetOffset = session.currentExposureTargetOffset
        hasExposureMeter = session.hasExposureMeter
        hintTick &+= 1
        neutralSceneRequestGeneration &+= 1
        let neutralGeneration = neutralSceneRequestGeneration
        let neutralLensGeneration = cameraLensSwitchGeneration
        let neutralFrameRateGeneration = frameRateGeneration
        session.readNeutralSceneEstimate { [weak self] estimate in
            guard let self, self.neutralSceneRequestGeneration == neutralGeneration,
                  self.cameraLensSwitchGeneration == neutralLensGeneration,
                  self.frameRateGeneration == neutralFrameRateGeneration else { return }
            // Reject an older device revision, and preserve the actual read time
            // so a delayed callback cannot make an old scene estimate fresh again.
            let current = estimate.flatMap { $0.cameraRevision >= self.apertureCameraRevision ? $0 : nil }
            self.neutralSceneKelvin = current?.kelvin
            self.neutralSceneCapturedAt = current?.capturedAt
        }
        apertureSnapshotRequestGeneration &+= 1
        let requestGeneration = apertureSnapshotRequestGeneration
        session.readApertureSnapshot { [weak self] snapshot in
            guard let self,
                  self.apertureSnapshotRequestGeneration == requestGeneration,
                  snapshot.cameraRevision >= self.apertureCameraRevision else { return }
            self.apertureCameraRevision = snapshot.cameraRevision
            self.liveAperture = snapshot.measured
            self.apertureStops = snapshot.capability.stops
            self.apertureIsVariable = snapshot.capability.isVariable
            self.selectedLensAperture = snapshot.selected
        }
        // NOTE: liveExposureBias is intentionally NOT refreshed here. It is our
        // own compensation value, not the device's (which reads 0 in custom
        // exposure mode and is reset by every shutter-priority re-meter).
    }

    private var photoApertureReadPending = false

    private func refreshPhotoAperture() {
        guard !photoApertureReadPending else { return }
        photoApertureReadPending = true
        session.readApertureSnapshot { [weak self] snapshot in
            guard let self else { return }
            self.photoApertureReadPending = false
            guard self.usesNativeIdlePreview, !self.isSwitchingCameraLens else { return }
            self.apertureCameraRevision = snapshot.cameraRevision
            self.liveAperture = snapshot.measured
            self.apertureStops = snapshot.capability.stops
            self.apertureIsVariable = snapshot.capability.isVariable
            self.selectedLensAperture = snapshot.selected
        }
    }

    private func invalidateApertureUIState() {
        apertureSnapshotRequestGeneration &+= 1
        liveAperture = nil
        apertureStops = []
        apertureIsVariable = false
        selectedLensAperture = nil
    }

    private func startExposurePolling() {
        stopExposurePolling()
        exposurePollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshExposure() }
        }
    }

    private func stopExposurePolling() {
        exposurePollingTimer?.invalidate()
        exposurePollingTimer = nil
    }

    private func startShutterPriorityLoop() {
        stopShutterPriorityLoop()
        guard !usesSharedIdlePreview else { return }
        shutterPriorityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.session.refreshShutterPriority() }
        }
    }

    private func stopShutterPriorityLoop() {
        shutterPriorityTimer?.invalidate()
        shutterPriorityTimer = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Free Space

    func updateFreeSpace() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        storageSnapshotRequestGeneration &+= 1
        let requestGeneration = storageSnapshotRequestGeneration

        // Volume capacity lookup may touch the filesystem. Keep it off the main
        // actor so launch and resume remain responsive while the first estimate
        // is being populated.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let values = try? url.resourceValues(forKeys: [
                .volumeAvailableCapacityKey,
                .volumeTotalCapacityKey
            ]),
                  let available = values.volumeAvailableCapacity,
                  let total = values.volumeTotalCapacity,
                  available >= 0,
                  total > 0 else { return }
            let freeBytes = Int64(available)
            let totalBytes = Int64(total)

            Task { @MainActor [weak self] in
                guard let self,
                      self.storageSnapshotRequestGeneration == requestGeneration else { return }
                // Keep the previous coherent snapshot if either capacity value
                // cannot be read, rather than presenting unavailable as zero.
                self.freeSpaceBytes = freeBytes
                self.totalSpaceBytes = totalBytes
                self.hasStorageSnapshot = true
                self.isSpaceLow = freeBytes < Self.lowSpaceThreshold
                self.isSpaceCritical = freeBytes < Self.criticalSpaceThreshold
            }
        }
    }

    // MARK: - Private

    private func handleRecordingFinished(_ result: Result<RecordingCompletion, Error>) async {
        let generation = captureGeneration
        isRecording = false
        isStoppingRecording = false
        refreshRecordingStabilization()
        invalidateRecordingTimers()
        // Snapshot and clear this take's timer state BEFORE any await. A duration
        // load that resolves after a new take has already started must not clear
        // the new take's timer origin nor replace its warning (L11).
        let snapshot = CameraRecordingTakeFence.snapshotAndClear(
            origin: &recordingTimerOrigin, stoppedAt: &recordingStoppedAt, generation: generation)
        switch result {
        case .success(let completion):
            switch RecordingFinishPresentationPolicy.plan(for: completion) {
            case .render(let url):
                // The destination's immutable policy was bound before capture;
                // publishing this URL never consults the live/reset frame rate.
                lastRecordedURL = url
                if let warning = completion.warning {
                    let warningMessage = warning.localizedDescription
                    recordingWarning = warningMessage
                    errorMessage = "Recording saved, but ended with a warning: \(warningMessage)"
                }
                await checkRecordedDuration(of: url, snapshot: snapshot)

            case .saveOriginalUnchanged(let url, let reason):
                // Deliberately not assigned to lastRecordedURL: that assignment is
                // what triggers the auto-render. The kept file goes to Photos
                // unchanged, and the take is never reported as a clean success.
                retainedOriginal = RetainedOriginal(url: url, reason: reason)
                recordingWarning = reason
                errorMessage = "Recording kept, but it did not pass validation: \(reason). "
                    + "Saving the original to Photos unchanged."
            }

        case .failure(let error):
            errorMessage = "Recording failed: \(error.localizedDescription)"
            failRecordingProminently(error)
        }
    }

    /// A take that never started is not a normal error banner: the user pressed
    /// record and got nothing, so it gets the loud treatment.
    private func failRecordingProminently(_ error: Error) {
        recordingTimerOrigin = nil
        recordingStoppedAt = nil
        recordingFailureDetail = error.localizedDescription
        recordingFailureToken &+= 1
    }

    /// The counter is a model of when the take started, so compare it with the
    /// file that was actually written. A mismatch past the log threshold means
    /// the model is wrong; only a large shortfall is surfaced, because that is
    /// what changes what the user expects to have recorded.
    ///
    /// `snapshot` is this take's timer state, captured and cleared before the
    /// await. A suspended duration load that resolves after a new take began is
    /// fenced out by take generation so it cannot touch the new take's state (L11).
    private func checkRecordedDuration(of url: URL,
                                       snapshot: CameraRecordingTakeFence.Snapshot?) async {
        guard let snapshot else { return }
        let displayed = (snapshot.stoppedAt ?? Date()).timeIntervalSince(snapshot.origin)
        guard let duration = try? await AVURLAsset(url: url).load(.duration),
              duration.isNumeric else { return }
        guard CameraRecordingTakeFence.accepts(
            snapshot: snapshot, currentGeneration: captureGeneration,
            isRecording: isRecording, isStartingRecording: isStartingRecording) else { return }
        let verdict = RecordingDurationDiscrepancyPolicy.verdict(displayed: displayed,
                                                                actual: duration.seconds)
#if DEBUG
        if verdict != .withinTolerance {
            print("Recording duration check: counter=\(String(format: "%.3f", displayed))s "
                  + "file=\(String(format: "%.3f", duration.seconds))s "
                  + "measuredStartOffset=\(String(format: "%.3f", session.recordingHeadOffset()))s "
                  + "verdict=\(verdict)")
        }
#endif
        guard case .contentMissing(let shortfall) = verdict else { return }
        recordingWarning = "The recording is shorter than the counter showed."
        errorMessage = "Recording ended early: the file is "
            + "\(String(format: "%.2f", shortfall)) s shorter than the counter showed."
    }

    /// Clears the pending retained original once it has been handed off.
    func clearRetainedOriginal() {
        retainedOriginal = nil
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        let generation = recordingTimerGeneration.begin()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingTimerTick(generation: generation)
            }
        }
    }

    private func recordingTimerTick(generation: UInt64) {
        guard recordingTimerGeneration.accepts(generation), isRecording else { return }
        // Count the clock the counter shows, so the five-minute limit and the
        // displayed time cannot disagree about how long the take has run.
        recordingDuration = recordingTimerOrigin.map { Date().timeIntervalSince($0) }
            ?? (recordingDuration + 0.1)
        // AD-8: auto-stop at 5 minutes
        if recordingDuration >= Self.maxClipDuration {
            stopRecording()
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func startSpacePolling() {
        spacePollingTimer?.invalidate()
        updateFreeSpace()
        // AD-8: poll every 5 seconds
        spacePollingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFreeSpace()
            }
        }
    }

    private func invalidateRecordingTimers() {
        recordingTimerGeneration.end()
        stopRecordingTimer()
        stopPolling()
    }

    private func stopPolling() {
        spacePollingTimer?.invalidate()
        spacePollingTimer = nil
    }
}
