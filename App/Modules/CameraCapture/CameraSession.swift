import AVFoundation

/// AD-3: Manages the AVCaptureSession — Apple Log, HEVC H.265, 4K, 24fps, clean preview.
/// Runs on a dedicated serial queue. Never posts to main thread directly.
final class CameraSession: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var isConfigured = false

    /// Currently active camera position
    private(set) var activePosition: AVCaptureDevice.Position = .back
    /// Current device (accessible for view model queries)
    private(set) var activeDevice: AVCaptureDevice?

    private var onRecordingFinished: ((Result<URL, Error>) -> Void)?

    // MARK: - Setup

    func configure() throws {
        guard !isConfigured else { return }
        var configError: Error?
        sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.sessionPreset = .hd4K3840x2160

            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: activePosition
            ) else {
                configError = CameraError.noCameraAvailable
                return
            }

            do {
                try addDevice(device)
                try configureDevice(device)
                configureMovieOutput()
                isConfigured = true
            } catch {
                configError = error
            }
        }

        if let error = configError { throw error }
    }

    private func addDevice(_ device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }

        // Remove existing input if present
        if let existing = videoDeviceInput {
            session.removeInput(existing)
        }

        session.addInput(input)
        videoDeviceInput = input

        // Remove and re-add movie output (needed after input swap for connection refresh)
        session.removeOutput(movieOutput)
        guard session.canAddOutput(movieOutput) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(movieOutput)
    }

    private func configureDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // Apple Log color space
        if device.activeFormat.supportedColorSpaces.contains(.appleLog) {
            device.activeColorSpace = .appleLog
        }

        // 24fps lock
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 24)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 24)

        // Locked white balance for consistent LUT application
        lockWhiteBalance(device)

        // Default to continuous auto exposure
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        activeDevice = device
    }

    /// Lock white balance to a consistent value so LUTs apply predictably.
    /// Uses the current device white balance gains (locks to ambient light).
    private func lockWhiteBalance(_ device: AVCaptureDevice) {
        if device.isWhiteBalanceModeSupported(.locked) {
            // Lock at current WB gains — captures the ambient light temperature
            device.whiteBalanceMode = .locked
        }
    }

    private func configureMovieOutput() {
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .standard
            }
        }

        let compressionSettings: [String: Any] = [
            AVVideoAverageBitRateKey: 36_000_000,
            AVVideoMaxKeyFrameIntervalKey: 48,
            AVVideoProfileLevelKey: "HEVC_Main_AutoLevel"
        ]

        movieOutput.movieFragmentInterval = .invalid
        movieOutput.setOutputSettings(
            [AVVideoCodecKey: AVVideoCodecType.hevc,
             AVVideoCompressionPropertiesKey: compressionSettings],
            for: movieOutput.connection(with: .video)!
        )
    }

    // MARK: - Camera Switching

    /// Switch between .back and .front cameras.
    func switchCamera(to position: AVCaptureDevice.Position) throws {
        guard activePosition != position else { return }

        var switchError: Error?
        sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: position
            ) else {
                switchError = CameraError.noCameraAvailable
                return
            }

            do {
                try addDevice(device)
                try configureDevice(device)
                activePosition = position
            } catch {
                switchError = error
            }
        }

        if let error = switchError { throw error }
    }

    // MARK: - Zoom

    /// Set zoom factor (1.0–5.0). Clamped to device capabilities.
    func setZoom(_ factor: CGFloat) throws {
        guard let device = activeDevice else { return }
        try device.lockForConfiguration()
        device.videoZoomFactor = min(max(factor, 1.0), device.activeFormat.videoMaxZoomFactor)
        device.unlockForConfiguration()
    }

    /// Ramp zoom smoothly.
    func rampZoom(to factor: CGFloat, rate: Float = 2.0) throws {
        guard let device = activeDevice else { return }
        try device.lockForConfiguration()
        device.ramp(toVideoZoomFactor: min(max(factor, 1.0), device.activeFormat.videoMaxZoomFactor),
                    withRate: rate)
        device.unlockForConfiguration()
    }

    var currentZoomFactor: CGFloat {
        activeDevice?.videoZoomFactor ?? 1.0
    }

    // MARK: - Exposure Controls

    /// Lock exposure at a specific ISO and shutter duration.
    func setExposure(iso: Float, shutter: CMTime) throws {
        guard let device = activeDevice else { return }
        try device.lockForConfiguration()

        let clampedISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
        let clampedShutter = min(max(shutter,
                                     device.activeFormat.minExposureDuration),
                                device.activeFormat.maxExposureDuration)

        device.setExposureModeCustom(duration: clampedShutter, iso: clampedISO) { _ in }
        device.unlockForConfiguration()
    }

    /// Switch to continuous auto exposure (default).
    func setAutoExposure() throws {
        guard let device = activeDevice,
              device.isExposureModeSupported(.continuousAutoExposure) else { return }
        try device.lockForConfiguration()
        device.exposureMode = .continuousAutoExposure
        device.unlockForConfiguration()
    }

    /// Lock the current auto-exposure values (AE lock).
    func lockCurrentExposure() throws {
        guard let device = activeDevice,
              device.isExposureModeSupported(.autoExpose) else { return }
        try device.lockForConfiguration()
        device.exposureMode = .autoExpose
        device.unlockForConfiguration()
    }

    /// Set exposure point of interest (normalized 0-1 coordinates on the preview).
    func setExposurePoint(_ point: CGPoint) throws {
        guard let device = activeDevice,
              device.isExposurePointOfInterestSupported else { return }
        try device.lockForConfiguration()
        device.exposurePointOfInterest = point
        device.unlockForConfiguration()
    }

    // MARK: - Recording

    func startRecording(to url: URL) throws {
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording() {
        movieOutput.stopRecording()
    }

    var isRecording: Bool {
        movieOutput.isRecording
    }

    func onFinish(_ handler: @escaping (Result<URL, Error>) -> Void) {
        onRecordingFinished = handler
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        if let error {
            onRecordingFinished?(.failure(error))
        } else {
            onRecordingFinished?(.success(outputFileURL))
        }
    }

    // MARK: - Session lifecycle

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
}

enum CameraError: LocalizedError {
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput
    case appleLogNotSupported

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:
            return "No camera available."
        case .cannotAddInput:
            return "Failed to add camera input to capture session."
        case .cannotAddOutput:
            return "Failed to add movie output to capture session."
        case .appleLogNotSupported:
            return "Apple Log color space is not supported on this device."
        }
    }
}