import AVFoundation

/// Selectable capture lenses. Maps a UI-facing name to an AVCaptureDevice type
/// + position. "Normal" is the rear wide (1x) camera.
enum CameraLens: String, CaseIterable, Identifiable {
    case ultraWide = "Ultrawide"
    case wide = "Normal"
    case telephoto = "Tele"
    case front = "Front"

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide, .front: return .builtInWideAngleCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }

    var position: AVCaptureDevice.Position {
        self == .front ? .front : .back
    }

    var systemImage: String {
        switch self {
        case .ultraWide: return "camera.viewfinder"
        case .wide: return "camera.fill"
        case .telephoto: return "camera.circle"
        case .front: return "camera.rotate"
        }
    }
}

/// AD-3: Manages the AVCaptureSession — Apple Log, HEVC H.265, 4K, 24fps, clean preview.
/// Runs on a dedicated serial queue. Never posts to main thread directly.
final class CameraSession: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var microphoneInput: AVCaptureDeviceInput?
    private var microphoneAdded = false
    private var isConfigured = false
    /// Fixed white-balance temperature (Kelvin) requested by the selected stock.
    /// Applied on the next configureDevice or immediately via setWhiteBalance.
    private var whiteBalanceTemperature: Float?

    /// Currently selected lens (rear wide/ultrawide/tele, or front).
    private(set) var activeLens: CameraLens = .wide
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
                activeLens.deviceType,
                for: .video,
                position: activeLens.position
            ) else {
                configError = CameraError.noCameraAvailable
                return
            }

            do {
                addMicrophoneInputLocked()
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

    /// Add the microphone input from any thread (idempotent). Audio is optional:
    /// a denied/missing microphone just records video-only. Re-adds the movie
    /// output so it creates the audio connection (mirrors `addDevice`).
    /// Async so the caller (main thread) never blocks on camera/audio hardware;
    /// runs after any pending configure()/start() on sessionQueue.
    func addMicrophoneInput() {
        sessionQueue.async { [weak self] in
            guard let self, !self.microphoneAdded else { return }
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            self.addMicrophoneInputLocked()
            // Refresh the movie output only if the video connection already
            // exists (session already running). On first launch addDevice adds
            // the movie output later, creating both video + audio connections.
            if self.microphoneAdded, self.movieOutput.connection(with: .video) != nil {
                self.session.removeOutput(self.movieOutput)
                if self.session.canAddOutput(self.movieOutput) {
                    self.session.addOutput(self.movieOutput)
                }
                self.configureMovieOutput()
            }
        }
    }

    /// Add the microphone input within an active session configuration.
    private func addMicrophoneInputLocked() {
        guard !microphoneAdded,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let mic = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInput(input)
        microphoneInput = input
        microphoneAdded = true
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

        // The bundled transform LUTs are authored for Apple Log 2. Prefer that
        // contract when this device/format supports it; use Apple Log as a
        // compatibility fallback on older hardware.
        if #available(iOS 26.0, *),
           device.activeFormat.supportedColorSpaces.contains(.appleLog2) {
            device.activeColorSpace = .appleLog2
        } else if device.activeFormat.supportedColorSpaces.contains(.appleLog) {
            device.activeColorSpace = .appleLog
        }

        // 24fps lock
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 24)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 24)

        // Apply the selected film stock's fixed white balance (daylight 5600K /
        // tungsten 3200K). If no stock temperature has been set yet, leave the
        // device's default white balance untouched.
        applyWhiteBalanceLock(device)

        // Default to continuous auto exposure
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        activeDevice = device
    }

    /// Set the fixed white-balance temperature (Kelvin) for the selected film
    /// stock. Daylight stocks use 5600K; tungsten stocks use 3200K. Locking the
    /// sensor to a fixed temperature (instead of continuous auto WB) keeps the
    /// Apple Log → LUT transform on a consistent white point per stock.
    func setWhiteBalance(temperatureKelvin: Float) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.whiteBalanceTemperature = temperatureKelvin
            guard let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                self.applyWhiteBalanceLock(device)
                device.unlockForConfiguration()
            } catch {
                // Non-fatal: leave current white balance if the lock fails.
            }
        }
    }

    /// Lock the device to `whiteBalanceTemperature` if one is set. Caller must
    /// hold the device configuration lock (configureDevice or setWhiteBalance).
    private func applyWhiteBalanceLock(_ device: AVCaptureDevice) {
        guard let kelvin = whiteBalanceTemperature,
              device.isWhiteBalanceModeSupported(.locked) else { return }
        let tint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: kelvin, tint: 0)
        let gains = device.deviceWhiteBalanceGains(for: tint)
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
    }

    private func configureMovieOutput() {
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .standard
            }
        }

        let compressionSettings: [String: Any] = [
            AVVideoAverageBitRateKey: DeliverySettings.averageBitRate,
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

    /// Lenses available on this device (queryable before session configuration).
    var availableLenses: [CameraLens] {
        var lenses: [CameraLens] = []
        if Self.deviceAvailable(.builtInWideAngleCamera, .back) { lenses.append(.wide) }
        if Self.deviceAvailable(.builtInUltraWideCamera, .back) { lenses.append(.ultraWide) }
        if Self.deviceAvailable(.builtInTelephotoCamera, .back) { lenses.append(.telephoto) }
        if Self.deviceAvailable(.builtInWideAngleCamera, .front) { lenses.append(.front) }
        return lenses
    }

    private static func deviceAvailable(
        _ type: AVCaptureDevice.DeviceType,
        _ position: AVCaptureDevice.Position
    ) -> Bool {
        AVCaptureDevice.default(type, for: .video, position: position) != nil
    }

    /// Switch to a specific lens (rear wide/ultrawide/tele, or front).
    func selectCamera(_ lens: CameraLens) throws {
        guard activeLens != lens else { return }

        var switchError: Error?
        sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            guard let device = AVCaptureDevice.default(
                lens.deviceType,
                for: .video,
                position: lens.position
            ) else {
                switchError = CameraError.noCameraAvailable
                return
            }

            do {
                try addDevice(device)
                try configureDevice(device)
                activeLens = lens
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

    /// Current sensor ISO (0 if no active device). Read from any thread for display.
    var currentISO: Float {
        activeDevice?.iso ?? 0
    }

    /// Current shutter duration in seconds (0 if no active device).
    var currentShutterSeconds: Double {
        activeDevice?.exposureDuration.seconds ?? 0
    }

    /// Device's supported ISO range (fallback 100–3200 before the device is ready).
    var isoRange: ClosedRange<Float> {
        guard let device = activeDevice else { return 100...3200 }
        return device.activeFormat.minISO...device.activeFormat.maxISO
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

    /// 180° shutter angle at 24fps = 1/48s.
    static let filmShutterDuration = CMTime(value: 1, timescale: 48)

    /// Lock exposure to the film standard: 180° shutter (1/48s) at a fixed ISO.
    func lockManualExposure(iso: Float) throws {
        try setExposure(iso: iso, shutter: Self.filmShutterDuration)
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
