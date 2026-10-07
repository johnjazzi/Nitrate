import AVFoundation

/// AD-3: Manages the AVCaptureSession — Apple Log, HEVC H.265, 4K, 24fps, clean preview.
/// Runs on a dedicated serial queue. Never posts to main thread directly.
final class CameraSession: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var isConfigured = false

    private var onRecordingFinished: ((Result<URL, Error>) -> Void)?

    // MARK: - Setup

    func configure() throws {
        // Idempotent: if already configured, skip to avoid duplicate input/output errors.
        guard !isConfigured else { return }
        // Perform all configuration on the session queue to avoid races with stop/start.
        var configError: Error?
        sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.sessionPreset = .hd4K3840x2160

            // Select back camera (wide-angle)
            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ) else {
                configError = CameraError.noCameraAvailable
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    configError = CameraError.cannotAddInput
                    return
                }
                session.addInput(input)
                videoDeviceInput = input

                // Configure video output
                guard session.canAddOutput(movieOutput) else {
                    configError = CameraError.cannotAddOutput
                    return
                }
                session.addOutput(movieOutput)

                // AD-3: Apple Log color space, HEVC H.265, 4K, 36 Mbps, 24fps
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                // Set Apple Log color space
                if device.activeFormat.supportedColorSpaces.contains(.appleLog) {
                    device.activeColorSpace = .appleLog
                }

                // AD-3: 24fps lock
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 24)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 24)

                // Configure movie output encoding
                if let connection = movieOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .standard
                    }
                }

                // AD-3: HEVC H.265 at 4K with ~36 Mbps target bitrate
                let compressionSettings: [String: Any] = [
                    AVVideoAverageBitRateKey: 36_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 48, // 2-second GOP at 24fps
                    AVVideoProfileLevelKey: "HEVC_Main_AutoLevel"
                ]

                movieOutput.movieFragmentInterval = .invalid // single fragment
                movieOutput.setOutputSettings(
                    [AVVideoCodecKey: AVVideoCodecType.hevc,
                     AVVideoCompressionPropertiesKey: compressionSettings],
                    for: movieOutput.connection(with: .video)!
                )

                isConfigured = true
            } catch {
                configError = error
            }
        }

        if let error = configError { throw error }
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
            return "No rear camera available."
        case .cannotAddInput:
            return "Failed to add camera input to capture session."
        case .cannotAddOutput:
            return "Failed to add movie output to capture session."
        case .appleLogNotSupported:
            return "Apple Log color space is not supported on this device."
        }
    }
}