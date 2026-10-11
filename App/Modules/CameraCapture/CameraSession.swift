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

    /// Compact x-factor shown on the lens pills in the control bar.
    var zoomLabel: String {
        switch self {
        case .ultraWide: return ".5x"
        case .wide: return "1x"
        case .telephoto: return "4x"
        case .front: return "Front"
        }
    }

    /// Equivalent full-frame focal length for the zoom label (display only).
    var focalLengthMM: Int {
        switch self {
        case .ultraWide: return 13
        case .wide: return 24
        case .telephoto: return 96
        case .front: return 24
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

    /// True while 180° shutter priority is active (shutter locked to 1/48s,
    /// ISO auto-meters). Cleared by manual exposure, which pins both.
    private(set) var isShutterPriority = false

    /// Currently selected lens (rear wide/ultrawide/tele, or front).
    private(set) var activeLens: CameraLens = .wide
    /// Current device (accessible for view model queries)
    private(set) var activeDevice: AVCaptureDevice?

    private var onRecordingFinished: (@MainActor @Sendable (Result<RecordingCompletion, Error>) -> Void)?
    private var onCameraError: (@MainActor @Sendable (Error) -> Void)?
    private var meterGeneration = CameraMeteringGeneration()
    private var recordingStartPending = false
    private var recordingGeneration: UInt64 = 0

    // MARK: - Setup

    /// Configure the session without blocking the caller's thread.
    ///
    /// Session configuration touches camera hardware and can take hundreds of
    /// milliseconds (longer on first launch or after the app resumes). Calling
    /// this from the main thread with `sessionQueue.sync` froze app launch and
    /// lens switching until the run loop was allowed to spin. `completion` runs
    /// on the main queue with `nil` on success, or the failure to report.
    func configure(completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            let error = self?.performConfigure()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
    }

    /// Shared synchronous configure body. MUST be called on `sessionQueue`.
    private func performConfigure() -> Error? {
        guard !isConfigured else { return nil }
        var configError: Error?

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd4K3840x2160

        guard let device = AVCaptureDevice.default(
            activeLens.deviceType,
            for: .video,
            position: activeLens.position
        ) else {
            return CameraError.noCameraAvailable
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

        return configError
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
        // Remove the existing video input FIRST. A session (with a movie output
        // attached) can't accept a second video input, so canAddInput() would
        // fail on every lens switch while the old input is still present.
        if let existing = videoDeviceInput {
            session.removeInput(existing)
            videoDeviceInput = nil
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
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
        // No video connection yet (e.g. output just re-added before the input
        // settled) — settings can be applied once it exists; skip rather than
        // crash on the force-unwrap.
        guard let connection = movieOutput.connection(with: .video) else { return }

        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .standard
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
            for: connection
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
    ///
    /// Async for the same reason as `configure(completion:)`: swapping the video
    /// input reconfigures capture hardware and must not block the main thread.
    /// `completion` runs on the main queue with `nil` on success.
    func selectCamera(_ lens: CameraLens, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.activeLens != lens else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
                return
            }
            self.invalidateMetering()
            var switchError: Error?

            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            guard let device = AVCaptureDevice.default(
                lens.deviceType,
                for: .video,
                position: lens.position
            ) else {
                let error = CameraError.noCameraAvailable
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
                return
            }

            do {
                try self.addDevice(device)
                try self.configureDevice(device)
                // addDevice dropped movieOutput's settings; re-apply them.
                self.configureMovieOutput()
                self.activeLens = lens
            } catch {
                switchError = error
            }

            DispatchQueue.main.async { MainActor.assumeIsolated { completion(switchError) } }
        }
    }

    // MARK: - Zoom

    /// Set zoom factor (1.0–5.0). Clamped to device capabilities.
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.videoZoomFactor = min(max(factor, 1.0), device.activeFormat.videoMaxZoomFactor)
            } catch { self.reportCameraError(error) }
        }
    }

    /// Ramp zoom smoothly.
    func rampZoom(to factor: CGFloat, rate: Float = 2.0) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.ramp(toVideoZoomFactor: min(max(factor, 1.0), device.activeFormat.videoMaxZoomFactor),
                            withRate: rate)
            } catch { self.reportCameraError(error) }
        }
    }

    var currentZoomFactor: CGFloat {
        activeDevice?.videoZoomFactor ?? 1.0
    }

    /// Focus the active lens at a normalized device point (0–1).
    func setFocusAndExposurePoint(_ point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                }
            } catch { self.reportCameraError(error) }
        }
    }

    func setPortraitMode(isEnabled: Bool, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            var operationError: Error?
            if let device = self?.activeDevice, !device.activeFormat.supportedDepthDataFormats.isEmpty {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    device.activeDepthDataFormat = isEnabled
                        ? device.activeFormat.supportedDepthDataFormats.first
                        : nil
                } catch { operationError = error }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
        }
    }

    /// Manual focus: lock the lens at a specific raw lens position (0–1).
    func setManualFocusPosition(_ lensPosition: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice,
                  device.isLockingFocusWithCustomLensPositionSupported else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1), completionHandler: nil)
            } catch { self.reportCameraError(error) }
        }
    }

    /// Return the lens to continuous auto-focus.
    func resetAutoFocus() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice,
                  device.isFocusModeSupported(.continuousAutoFocus) else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.focusMode = .continuousAutoFocus
            } catch { self.reportCameraError(error) }
        }
    }

    var isManualFocusSupported: Bool {
        activeDevice?.isLockingFocusWithCustomLensPositionSupported ?? false
    }

    var maxZoomFactor: CGFloat {
        activeDevice?.activeFormat.videoMaxZoomFactor ?? 5.0
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
    private func setExposureLocked(iso: Float, shutter: CMTime, on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let clampedISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
        let clampedShutter = min(max(shutter, device.activeFormat.minExposureDuration),
                                 device.activeFormat.maxExposureDuration)
        device.setExposureModeCustom(duration: clampedShutter, iso: clampedISO) { _ in }
    }

    /// 180° shutter angle at 24fps = 1/48s.
    static let filmShutterDuration = CMTime(value: 1, timescale: 48)

    /// Lock exposure to the film standard: 180° shutter (1/48s) at a fixed ISO.
    func lockManualExposure(iso: Float, completion: (@MainActor @Sendable (Error?) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateMetering()
            var operationError: Error?
            if self.movieOutput.isRecording || self.recordingStartPending {
                operationError = CameraError.exposureChangeDuringRecording
            } else if let device = self.activeDevice {
                do {
                    try self.setExposureLocked(iso: iso, shutter: Self.filmShutterDuration, on: device)
                    self.isShutterPriority = false
                }
                catch { operationError = error }
            }
            if let completion {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
            } else if let operationError {
                self.reportCameraError(operationError)
            }
        }
    }

    /// Switch to continuous auto exposure (default).
    func setAutoExposure(completion: (@MainActor @Sendable (Error?) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateMetering()
            var operationError: Error?
            if self.movieOutput.isRecording || self.recordingStartPending {
                operationError = CameraError.exposureChangeDuringRecording
            } else if let device = self.activeDevice, device.isExposureModeSupported(.continuousAutoExposure) {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    device.exposureMode = .continuousAutoExposure
                } catch { operationError = error }
            }
            if let completion {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
            } else if let operationError {
                self.reportCameraError(operationError)
            }
        }
    }

    /// Lock the current auto-exposure values (AE lock).
    func lockCurrentExposure(completion: (@MainActor @Sendable (Error?) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            var operationError: Error?
            if self.movieOutput.isRecording || self.recordingStartPending {
                operationError = CameraError.exposureChangeDuringRecording
            } else if let device = self.activeDevice, device.isExposureModeSupported(.autoExpose) {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    device.exposureMode = .autoExpose
                } catch { operationError = error }
            }
            if let completion {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
            } else if let operationError {
                self.reportCameraError(operationError)
            }
        }
    }

    /// EV compensation applied to the auto-exposure target, in stops.
    ///
    /// Deliberately OUR value, not `AVCaptureDevice.exposureTargetBias`. The 180°
    /// shutter lock drives the device in custom (manual) exposure mode, where the
    /// device's own bias has no effect; worse, every re-meter switches exposure
    /// mode and Apple resets that bias to 0, so reading it back made the control
    /// appear to revert. Compensation is applied by scaling the metered ISO
    /// instead, which survives the shutter-priority re-meter.
    private(set) var exposureBiasEV: Float = 0

    /// Supported EV compensation range, bounded to a film-useful ±3 EV span
    /// (fallback ±3 EV before the device is ready).
    var exposureBiasRange: ClosedRange<Float> {
        guard let device = activeDevice else { return -3...3 }
        return max(device.minExposureTargetBias, -3)...min(device.maxExposureTargetBias, 3)
    }

    /// Set EV compensation and re-pin the shutter-priority exposure so the change
    /// is visible immediately. No-op in manual ISO mode, where the ISO chooser
    /// drives exposure directly.
    func setExposureBiasEV(_ ev: Float) {
        let range = exposureBiasRange
        let clamped = min(max(ev, range.lowerBound), range.upperBound)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.exposureBiasEV = clamped
            guard self.isShutterPriority, !self.movieOutput.isRecording,
                  !self.recordingStartPending else { return }
            self.pinShutterToFilm()
        }
    }

    // MARK: - Shutter Priority (180° film shutter)

    /// Lock the shutter to 180° (1/48s at 24fps) and let ISO auto-meter.
    /// AVFoundation has no native shutter-priority mode, so we meter briefly in
    /// continuous-auto, then hold the fixed shutter at the freshly metered ISO.
    /// Call `refreshShutterPriority()` periodically to keep ISO tracking the scene.
    func enableShutterPriority() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.movieOutput.isRecording, !self.recordingStartPending else { return }
            self.isShutterPriority = true
            self.invalidateMetering()
            self.pinShutterToFilm()
        }
    }

    func disableShutterPriority() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isShutterPriority = false
            self.invalidateMetering()
        }
    }

    /// Re-meter and re-pin the 180° shutter (no-op when shutter priority is off
    /// or while recording — exposure is frozen during a take).
    func refreshShutterPriority() {
        sessionQueue.async { [weak self] in
            guard let self, self.isShutterPriority, !self.movieOutput.isRecording,
                  !self.recordingStartPending else { return }
            self.pinShutterToFilm()
        }
    }

    func onCameraOperationError(_ handler: @escaping @MainActor @Sendable (Error) -> Void) {
        sessionQueue.async { [weak self] in self?.onCameraError = handler }
    }

    private func pinShutterToFilm() {
        guard let device = activeDevice else { return }
        // Brief auto-meter so the device evaluates scene brightness.
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            guard device.isExposureModeSupported(.continuousAutoExposure) else { return }
            device.exposureMode = .continuousAutoExposure
        } catch {
            reportCameraError(error)
            return
        }

        // Hold the fixed shutter at the freshly metered ISO after the meter
        // settles, scaled by the EV compensation (2^EV stops). `setExposure`
        // clamps the result to the device's ISO range.
        let generation = meterGeneration.issue()
        sessionQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.meterGeneration.accepts(generation), self.isShutterPriority,
                  !self.movieOutput.isRecording, !self.recordingStartPending,
                  let device = self.activeDevice else { return }
            let compensated = device.iso * powf(2.0, self.exposureBiasEV)
            do { try self.setExposureLocked(iso: compensated, shutter: Self.filmShutterDuration, on: device) }
            catch { self.reportCameraError(error) }
        }
    }

    private func invalidateMetering() {
        meterGeneration.invalidate()
    }

    private func reportCameraError(_ error: Error) {
        guard let handler = onCameraError else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(error) } }
    }

    // MARK: - Recording

    func startRecording(to url: URL, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateMetering()
            guard !self.recordingStartPending, !self.movieOutput.isRecording else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(CameraError.recordingInProgress) } }
                return
            }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(CameraError.destinationAlreadyExists) } }
                return
            }
            guard let device = self.activeDevice else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(CameraError.noCameraAvailable) } }
                return
            }
            self.recordingStartPending = true
            self.recordingGeneration &+= 1
            let generation = self.recordingGeneration
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let iso = min(max(device.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                let shutter = min(max(Self.filmShutterDuration, device.activeFormat.minExposureDuration),
                                  device.activeFormat.maxExposureDuration)
                device.setExposureModeCustom(duration: shutter, iso: iso) { [weak self] _ in
                    self?.sessionQueue.async {
                        guard let self, self.recordingGeneration == generation,
                              self.recordingStartPending else { return }
                        self.startMovieOutput(to: url, completion: completion)
                    }
                }
            } catch {
                self.recordingStartPending = false
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
            }
        }
    }

    private func startMovieOutput(to url: URL,
                                  completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        // Exposure has completed before metadata is sampled and output starts.
        movieOutput.metadata = captureMetadataItems()
        movieOutput.startRecording(to: url, recordingDelegate: self)
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
    }

    /// Shutter speed/angle + ISO at the moment recording starts. The shutter is
    /// locked to 180° (1/48s at 24fps) in manual exposure; auto mode reports its
    /// actual metered value so the metadata stays honest.
    private func captureMetadataItems() -> [AVMetadataItem] {
        guard let device = activeDevice else { return [] }
        let shutterSeconds = device.exposureDuration.seconds
        let angle = Int((shutterSeconds * 24.0 * 360.0).rounded())
        let speed = shutterSeconds > 0 ? Self.fractionString(seconds: shutterSeconds) : "auto"
        return [
            Self.captureItem("shutter-speed", speed),
            Self.captureItem("shutter-angle", "\(angle)"),
            Self.captureItem("capture-iso", "\(Int(device.iso))")
        ]
    }

    private static func captureItem(_ key: String, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.filmemulation.\(key)" as NSString
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func fractionString(seconds: Double) -> String {
        let reciprocal = (1.0 / seconds).rounded()
        return reciprocal >= 2 ? "1/\(Int(reciprocal))" : String(format: "%.4fs", seconds)
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateMetering()
            if self.recordingStartPending {
                self.recordingStartPending = false
                self.recordingGeneration &+= 1
            }
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
        }
    }

    var isRecording: Bool {
        movieOutput.isRecording
    }

    func onFinish(_ handler: @escaping @MainActor @Sendable (Result<RecordingCompletion, Error>) -> Void) {
        sessionQueue.async { [weak self] in self?.onRecordingFinished = handler }
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate

    /// Bridges a value that is safe to use but not statically `Sendable` — an
    /// `Error` existential and a `URL` — across the session queue to MainActor.
    /// Matches the existing `AudioCopyResultBox`/`FrameCounterBox` pattern in
    /// this codebase; `Error` cannot be marked `Sendable` by the caller.
    struct RecordingCompletionResult: @unchecked Sendable {
        let result: Result<RecordingCompletion, Error>
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        let playableFlag = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? NSNumber
        let result: Result<RecordingCompletion, Error>
        if RecordingCompletionPolicy.shouldPublish(errorExists: error != nil,
                                                   finishedPlayable: playableFlag?.boolValue) {
            result = .success(RecordingCompletion(url: outputFileURL, warning: error))
        } else {
            result = .failure(error ?? CameraError.recordingFailed)
        }
        // `result` straddles isolation boundaries: it carries a URL and an Error
        // (which cannot be statically Sendable). Wrap it so the send to the main
        // actor is explicit rather than inferred.
        let payload = RecordingCompletionResult(result: result)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.recordingStartPending = false
            let handler = self.onRecordingFinished
            let completion = payload.result
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler?(completion) }
            }
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
            guard let self else { return }
            self.invalidateMetering()
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
}

enum CameraError: LocalizedError {
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput
    case appleLogNotSupported
    case recordingInProgress
    case destinationAlreadyExists
    case recordingFailed
    case exposureChangeDuringRecording

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
        case .recordingInProgress:
            return "A recording is already in progress."
        case .destinationAlreadyExists:
            return "The recording destination already exists."
        case .recordingFailed:
            return "The recording could not be finalized."
        case .exposureChangeDuringRecording:
            return "Exposure cannot be changed during a recording."
        }
    }
}

struct RecordingCompletion: @unchecked Sendable {
    let url: URL
    let warning: Error?
}
