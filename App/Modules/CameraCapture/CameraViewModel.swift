import AVFoundation
import Observation

/// AD-1: @Observable ViewModel for the camera screen.
/// Manages exposure mode, record control, free space display, and clip limits.
@MainActor
@Observable
final class CameraViewModel {
    let session = CameraSession()
    let exposure = ExposureManager()

    // MARK: - Observable State

    var isRecording = false
    var recordingDuration: TimeInterval = 0
    var freeSpaceBytes: Int64 = 0
    var freeSpacePercent: Double = 1.0
    var isSpaceLow = false
    var isSpaceCritical = false
    var errorMessage: String?
    var recordingWarning: String?
    private(set) var lastRecordedURL: URL?

    // Exposure (live from the device, polled every 0.5s)
    var liveISO: Float = 0
    var liveShutterSeconds: Double = 0
    var isManualExposure = false
    var manualISO: Float = 400
    /// Auto-exposure target bias in EV (live value; polled with the exposure
    /// readout). Only drives the scene while the device meters automatically.
    var liveExposureBias: Float = 0

    // AD-8: Max clip duration
    static let maxClipDuration: TimeInterval = 300 // 5 minutes
    static let lowSpaceThreshold: Int64 = 1_000_000_000 // 1GB
    static let criticalSpaceThreshold: Int64 = 500_000_000 // 500MB

    private var recordingTimer: Timer?
    private var spacePollingTimer: Timer?
    private var exposurePollingTimer: Timer?
    private var shutterPriorityTimer: Timer?
    private var recordingTimerGeneration = RecordingTimerGeneration()
    private var isStartingRecording = false
    private var captureGeneration: UInt64 = 0
    private var exposureCommandGeneration: UInt64 = 0
    private let originalStorage = CameraOriginalStorage()
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
        guard lifecycleGate.isActive else { return }
        lifecycleGate.deactivate()
        exposureCommandGeneration &+= 1
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
            // configure() already adds the mic via addMicrophoneInputLocked().
            break
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
        session.onCameraOperationError { [weak self] error in
            self?.errorMessage = error.localizedDescription
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.session.startDebugSmokeCapture()
            }
        }
#endif

        // Mic is added by configure() when already authorized; request it
        // here (after start) only for the first-launch grant case.
        requestMicrophoneAccess()
        startExposurePolling()
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

    func startRecording() {
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
        do {
            let outputURL = try originalStorage.makeDestination()
            session.startRecording(to: outputURL) { [weak self] error in
                guard let self else { return }
                guard self.captureGeneration == generation, self.lifecycleGate.isActive else {
                    if error == nil { self.session.stopRecording() }
                    return
                }
                self.isStartingRecording = false
                if let error {
                    self.isRecording = false
                    self.invalidateRecordingTimers()
                    self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
                    return
                }
                self.isRecording = true
                self.recordingDuration = 0
                self.startRecordingTimer()
                self.startSpacePolling()
            }
        } catch {
            isStartingRecording = false
            errorMessage = "Failed to prepare recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        if isStartingRecording { captureGeneration &+= 1 }
        isStartingRecording = false
        session.stopRecording()
        invalidateRecordingTimers()
    }

    func handleFocusTap(at point: CGPoint, in previewLayer: AVCaptureVideoPreviewLayer) {
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        session.setFocusAndExposurePoint(devicePoint)
    }

    /// Switch the active lens and refresh tap-to-focus for the new device.
    /// Completion runs on the main queue; `nil` error means the swap succeeded.
    func selectLens(_ lens: CameraLens, completion: @escaping (Error?) -> Void) {
        exposureCommandGeneration &+= 1
        session.selectCamera(lens) { [weak self] error in
            guard let self else { return }
            if let error {
                completion(error)
                return
            }
            // configureDevice resets to auto exposure on the device swap; re-apply
            // manual exposure or shutter priority so the 180° shutter survives lens changes.
            if self.isManualExposure {
                self.session.lockManualExposure(iso: self.manualISO) { [weak self] error in
                    if let error { self?.errorMessage = error.localizedDescription }
                }
            } else {
                self.session.enableShutterPriority()
            }
            completion(nil)
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
        manualISO = iso
        exposureCommandGeneration &+= 1
        let generation = exposureCommandGeneration
        session.lockManualExposure(iso: iso) { [weak self] error in
            guard let self else { return }
            guard self.exposureCommandGeneration == generation,
                  self.lifecycleGate.isActive, !self.isRecording else { return }
            if let error {
                self.errorMessage = "Failed to set ISO: \(error.localizedDescription)"
                return
            }
            isManualExposure = true
            refreshExposure()
        }
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
        liveISO = session.currentISO
        liveShutterSeconds = session.currentShutterSeconds
        // NOTE: liveExposureBias is intentionally NOT refreshed here. It is our
        // own compensation value, not the device's (which reads 0 in custom
        // exposure mode and is reset by every shutter-priority re-meter).
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
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]) {
            freeSpaceBytes = Int64(values.volumeAvailableCapacity ?? 0)
            let totalBytes: Int64 = 64_000_000_000 // approximate for display
            freeSpacePercent = totalBytes > 0 ? Double(freeSpaceBytes) / Double(totalBytes) : 0
            isSpaceLow = freeSpaceBytes < Self.lowSpaceThreshold
            isSpaceCritical = freeSpaceBytes < Self.criticalSpaceThreshold
        }
    }

    // MARK: - Private

    private func handleRecordingFinished(_ result: Result<RecordingCompletion, Error>) async {
        isRecording = false
        invalidateRecordingTimers()
        switch result {
        case .success(let completion):
            lastRecordedURL = completion.url
            if let warning = completion.warning {
                let warningMessage = warning.localizedDescription
                recordingWarning = warningMessage
                errorMessage = "Recording saved, but ended with a warning: \(warningMessage)"
            }

        case .failure(let error):
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
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
        recordingDuration += 0.1
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
