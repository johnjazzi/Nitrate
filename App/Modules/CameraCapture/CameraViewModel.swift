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
    /// Injected by the app root. Fail closed until distribution/entitlement
    /// state is ready; existing queued footage and recovery are not gated.
    @ObservationIgnored var recordingAccessAllowed: @MainActor () -> Bool = { false }

    init() {
        activeLens = session.activeLens
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
    /// Auto-exposure target bias in EV (live value; polled with the exposure
    /// readout). Only drives the scene while the device meters automatically.
    var liveExposureBias: Float = 0
    /// Live metered exposure offset from the device target, in EV (positive =
    /// over). Drives the under/over indicator. `hasExposureMeter` is false until
    /// the device is configured, so the indicator can fall back cleanly.
    var liveExposureTargetOffset: Float = 0
    var hasExposureMeter = false
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
    private var stabilizationSnapshotRequestGeneration: UInt64 = 0
    private var cameraLensSwitchGeneration: UInt64 = 0
    private var pendingLensSwitchCount = 0
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
#endif

    // MARK: - Actions

    func onAppear() {
        // Request the camera first (it's the critical path). The microphone is
        // requested after the session is configured, to avoid stacking two
        // system permission dialogs at launch (which can leave the app stuck
        // on the launch screen).
        activateCameraIfNeeded()
    }

    func onSceneActive() {
        activateCameraIfNeeded()
    }

    func onSceneInactive() {
        endSlowZoom()
        guard lifecycleGate.isActive else { return }
        lifecycleGate.deactivate()
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
        guard let generation = lifecycleGate.activate() else { return }
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
        guard lifecycleGate.accepts(generation), !configurationInFlight, !cameraConfigured else { return }
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
            self.startSession()
        }
    }

    /// Runs on the main queue once the session has been configured.
    private func startSession() {
        session.onCameraOperationError { [weak self] error, sourceLens in
            guard let self,
                  !self.isSwitchingCameraLens,
                  sourceLens == self.activeLens else { return }
            self.errorMessage = error.localizedDescription
        }
        session.onFinish { [weak self] result in
            Task { @MainActor in
                await self?.handleRecordingFinished(result)
            }
        }
        session.start()
#if DEBUG
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
        if isManualExposure {
            session.lockManualExposure(iso: manualISO) { [weak self] error in
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
        guard lifecycleGate.isActive, let snapshot = zoomSnapshot, !isSwitchingCameraLens else { return }
        session.setDisplayZoom(factor, revision: snapshot.cameraRevision)
    }

    func beginSlowZoom(_ direction: CameraZoomDirection) {
        guard lifecycleGate.isActive, let snapshot = zoomSnapshot, !isSwitchingCameraLens else { return }
        session.beginSlowZoom(direction, revision: snapshot.cameraRevision)
    }

    func endSlowZoom(revision: UInt64? = nil) {
        guard let revision = revision ?? zoomSnapshot?.cameraRevision else { return }
        session.endSlowZoom(revision: revision)
    }

    func startRecording() {
        guard recordingAccessAllowed() else {
            errorMessage = "Recording access is unavailable. Open Settings to check your trial or restore a purchase."
            return
        }
        guard !isStartingRecording, !isRecording else { return }
        guard lifecycleGate.isActive, cameraConfigured else {
            errorMessage = "Camera is not ready to record."
            return
        }
        guard !isSpaceCritical else {
            errorMessage = "Not enough free space. Please free up at least 500MB."
            return
        }

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
            captureJournal.markPending(outputURL)
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
    func selectLens(_ lens: CameraLens, completion: @escaping (Error?) -> Void) {
        endSlowZoom()
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
            }
            self.pendingLensSwitchCount = max(0, self.pendingLensSwitchCount - 1)
            self.isSwitchingCameraLens = self.pendingLensSwitchCount > 0

            if self.pendingLensSwitchCount == 0 {
                if self.lifecycleGate.isActive {
                    self.restoreExposureAfterLensSwitch()
                    self.refreshExposure()
                } else {
                    self.invalidateApertureUIState()
                }
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
        exposure.toggleISOLock(currentISO: currentISO)
    }

    // MARK: - Manual Exposure

    func setManualISO(_ iso: Float) {
        // The session refuses exposure changes during a take
        // (`exposureChangeDuringRecording`), so an optimistic write here would
        // display an ISO the hardware never took. Refuse before mutating, matching
        // the silent gating the other transition-limited controls use.
        guard CameraManualExposureSelectionPolicy.canChangeISO(
            isStartingRecording: isStartingRecording, isRecording: isRecording,
            isStoppingRecording: isStoppingRecording) else { return }
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

    func setLensAperture(_ aperture: Float?) {
        guard canSelectAperture else { return }
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
            && lifecycleGate.isActive && cameraConfigured && !isSwitchingCameraLens
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
        let range = session.exposureBiasRange
        let clamped = min(max(bias, range.lowerBound), range.upperBound)
        liveExposureBias = clamped
        session.setExposureBiasEV(clamped)
    }

    func toggleManualExposure() {
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
        refreshRecordingStabilization()
        liveISO = session.currentISO
        liveShutterSeconds = session.currentShutterSeconds
        liveExposureTargetOffset = session.currentExposureTargetOffset
        hasExposureMeter = session.hasExposureMeter
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
