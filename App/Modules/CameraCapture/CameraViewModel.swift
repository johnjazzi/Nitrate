import AVFoundation
import Observation

/// AD-1: @Observable ViewModel for the camera screen.
/// Manages exposure mode, record control, free space display, and clip limits.
@MainActor
@Observable
final class CameraViewModel {
    let session = CameraSession()
    let exposure = ExposureManager()
    private var focusManager: FocusManager?

    // MARK: - Observable State

    var isRecording = false
    var recordingDuration: TimeInterval = 0
    var freeSpaceBytes: Int64 = 0
    var freeSpacePercent: Double = 1.0
    var isSpaceLow = false
    var isSpaceCritical = false
    var errorMessage: String?
    private(set) var lastRecordedURL: URL?

    // Exposure (live from the device, polled every 0.5s)
    var liveISO: Float = 0
    var liveShutterSeconds: Double = 0
    var isManualExposure = false
    var manualISO: Float = 400

    // AD-8: Max clip duration
    static let maxClipDuration: TimeInterval = 300 // 5 minutes
    static let lowSpaceThreshold: Int64 = 1_000_000_000 // 1GB
    static let criticalSpaceThreshold: Int64 = 500_000_000 // 500MB

    private var recordingTimer: Timer?
    private var spacePollingTimer: Timer?
    private var exposurePollingTimer: Timer?

    // MARK: - Actions

    func onAppear() {
        // Request the camera first (it's the critical path). The microphone is
        // requested after the session is configured, to avoid stacking two
        // system permission dialogs at launch (which can leave the app stuck
        // on the launch screen).
        requestCameraAccess()
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

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    if granted {
                        self.configureAndStart()
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

    private func configureAndStart() {
        do {
            try session.configure()
            session.start()

            // Mic is added by configure() when already authorized; request it
            // here (after start) only for the first-launch grant case.
            requestMicrophoneAccess()
            startExposurePolling()
            refreshExposure()

            if let device = session.activeDevice {
                focusManager = FocusManager(device: device)
            }

            session.onFinish { [weak self] result in
                Task { @MainActor in
                    await self?.handleRecordingFinished(result)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func onDisappear() {
        session.stop()
        stopPolling()
        stopExposurePolling()
    }

    func startRecording() {
        guard !isSpaceCritical else {
            errorMessage = "Not enough free space. Please free up at least 500MB."
            return
        }

        let outputURL = tempFileURL()
        do {
            try session.startRecording(to: outputURL)
            isRecording = true
            recordingDuration = 0
            startRecordingTimer()
            startSpacePolling()
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        session.stopRecording()
        stopRecordingTimer()
        stopPolling()
    }

    func handleFocusTap(at point: CGPoint, in previewLayer: AVCaptureVideoPreviewLayer) {
        focusManager?.focus(at: point, in: previewLayer)
    }

    /// Switch the active lens and refresh tap-to-focus for the new device.
    func selectLens(_ lens: CameraLens) throws {
        try session.selectCamera(lens)
        if let device = session.activeDevice {
            focusManager = FocusManager(device: device)
        }
        // configureDevice resets to auto exposure on the device swap; re-apply
        // manual exposure so the 180° shutter + ISO lock survives lens changes.
        if isManualExposure {
            try session.lockManualExposure(iso: manualISO)
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
        do {
            try session.lockManualExposure(iso: iso)
            isManualExposure = true
            refreshExposure()
        } catch {
            errorMessage = "Failed to set ISO: \(error.localizedDescription)"
        }
    }

    func toggleManualExposure() {
        if isManualExposure {
            do {
                try session.setAutoExposure()
                isManualExposure = false
                refreshExposure()
            } catch {
                errorMessage = "Failed to unlock exposure: \(error.localizedDescription)"
            }
        } else {
            // Enter manual mode at the current metered ISO (no exposure jump).
            setManualISO(liveISO > 0 ? liveISO : manualISO)
        }
    }

    private func refreshExposure() {
        liveISO = session.currentISO
        liveShutterSeconds = session.currentShutterSeconds
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

    private func tempFileURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        let name = "clip_\(Int(Date().timeIntervalSince1970)).mov"
        return dir.appendingPathComponent(name)
    }

    private func handleRecordingFinished(_ result: Result<URL, Error>) async {
        isRecording = false
        switch result {
        case .success(let url):
            lastRecordedURL = url

        case .failure(let error):
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingTimerTick()
            }
        }
    }

    private func recordingTimerTick() {
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
        updateFreeSpace()
        // AD-8: poll every 5 seconds
        spacePollingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFreeSpace()
            }
        }
    }

    private func stopPolling() {
        spacePollingTimer?.invalidate()
        spacePollingTimer = nil
    }
}