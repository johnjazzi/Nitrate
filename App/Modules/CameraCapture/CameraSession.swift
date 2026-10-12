import AVFoundation
import VideoToolbox

/// Selectable capture lenses. Maps a UI-facing name to an AVCaptureDevice type
/// + position. "Normal" is the rear wide (1x) camera.
enum CameraLens: String, CaseIterable, Identifiable, Sendable {
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
final class CameraSession: NSObject {
    let session = AVCaptureSession()
    fileprivate let sessionQueue = DispatchQueue(label: "camera.session")
    private let sampleBufferQueue = DispatchQueue(label: "camera.sample-buffer-writer")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
#if DEBUG
    /// Debug single-frame tap: an independent second video output with its own
    /// delegate, so the recorder's `videoOutput` and delegate stay untouched. Its
    /// connection is disabled except while a debug frame is requested, so the
    /// recording path is unaffected in steady state.
    private let debugFrameOutput = AVCaptureVideoDataOutput()
    private let debugFrameQueue = DispatchQueue(label: "camera.debug-frame")
    private let debugFrameTap = CameraDebugFrameTap()
#endif
    private lazy var sampleBufferRecorder = CameraSampleBufferRecorder(queue: sampleBufferQueue)
    private var acceptedPixelFormats: Set<UInt32> = []
    private var acceptedVideoSettings: [String: Any] = [:]
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var microphoneInput: AVCaptureDeviceInput?
    private var microphoneAdded = false
    private var isConfigured = false
    private var recordingActive = false
    private var recordingFinishing = false
    /// Fixed white-balance temperature (Kelvin) requested by the selected stock.
    /// Applied on the next configureDevice or immediately via setWhiteBalance.
    private var whiteBalanceTemperature: Float?

    /// True while 180° shutter priority is active (shutter locked to 1/48s,
    /// ISO auto-meters). Cleared by manual exposure, which pins both.
    private(set) var isShutterPriority = false
    /// Nil means "hold the current iris value". An explicit stop is the only
    /// thing that moves the aperture; the metering paths never auto-drive it.
    /// Access is serialized on sessionQueue; UI reads are refreshed by
    /// CameraViewModel after each aperture operation.
    private var selectedLensAperture: Float?
    private var manualExposureISO: Float = 400
    private var recordingAperturePin: CameraAperturePolicy.RecordingPin?
    private var apertureCameraRevision: UInt64 = 0

    /// Currently selected lens (rear wide/ultrawide/tele, or front).
    private(set) var activeLens: CameraLens = {
#if DEBUG
        if CommandLine.arguments.contains("--smoke-front-hevc-log2-capture") {
            return .front
        }
#endif
        return .wide
    }()
    /// Current device (accessible for view model queries)
    private(set) var activeDevice: AVCaptureDevice?

    private var onRecordingFinished: (@MainActor @Sendable (Result<RecordingCompletion, Error>) -> Void)?
    private var onCameraError: (@MainActor @Sendable (Error, CameraLens) -> Void)?
    private var meterGeneration = CameraMeteringGeneration()
    /// The exposure currently pinned by the shutter-priority path, used to
    /// decide whether a re-meter is worth taking at all. Cleared whenever the
    /// pin is released (manual ISO, auto exposure, lens switch, session stop).
    private var pinnedExposure: ExposureStabilizer.Pin?
    private var recordingStartPending = false
    private var recordingGeneration: UInt64 = 0
    private var recorderCompletionBridge = CameraRecorderCompletionBridge()
    private var pendingStartCompletion: (@MainActor @Sendable (Error?) -> Void)?
    private let recordingStateLock = NSLock()
    private var publicRecordingState = false
#if DEBUG
    private var debugSmokeURL: URL?
    private var debugSmokeTimedOut = false
#endif

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
            if let error {
                print("Camera session configuration failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
    }

    /// Shared synchronous configure body. MUST be called on `sessionQueue`.
    private func performConfigure() -> Error? {
        guard !isConfigured else { return nil }
        var configError: Error?

        session.beginConfiguration()

        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(
            activeLens.deviceType,
            for: .video,
            position: activeLens.position
        ) else {
            session.commitConfiguration()
            return CameraError.noCameraAvailable
        }

        do {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(sampleBufferRecorder, queue: sampleBufferQueue)
            audioOutput.setSampleBufferDelegate(sampleBufferRecorder, queue: sampleBufferQueue)
            addMicrophoneInputLocked()
            try addDevice(device)
        } catch { configError = error }
        session.commitConfiguration()
        guard configError == nil else { return configError }
        do {
            try configureDevice(device)
            isConfigured = true
            logApertureCapability(for: device, lens: activeLens)
        } catch { return error }

        return nil
    }

    /// Add the microphone input from any thread (idempotent). Audio is optional:
    /// a denied/missing microphone just records video-only. Re-adds the movie
    /// output so it creates the audio connection (mirrors `addDevice`).
    /// Async so the caller (main thread) never blocks on camera/audio hardware;
    /// runs after any pending configure()/start() on sessionQueue.
    func addMicrophoneInput() {
        sessionQueue.async { [weak self] in
            guard let self, !self.microphoneAdded else { return }
            guard !self.isRecordingOrPending else {
                self.reportCameraError(CameraError.exposureChangeDuringRecording)
                return
            }
            self.session.beginConfiguration()
            self.addMicrophoneInputLocked()
            if self.microphoneAdded, self.videoOutput.connection(with: .video) != nil {
                self.session.commitConfiguration()
                do {
                    if let device = self.activeDevice {
                        try self.configureDevice(device, applyDefaultExposure: false)
                    }
                }
                catch {
                    self.isConfigured = false
                    self.reportCameraError(error)
                }
            } else {
                self.session.commitConfiguration()
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
        audioOutput.setSampleBufferDelegate(sampleBufferRecorder, queue: sampleBufferQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
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

        // Re-add the video data output after input swaps to refresh the connection.
        session.removeOutput(videoOutput)
        guard session.canAddOutput(videoOutput) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(videoOutput)
    }

    /// Samples remain sensor-coded at 3840x2160; the MOV track matrix rotates
    /// display to portrait. Front-camera movies are intentionally unmirrored.
    private func configureRawLandscapeRecordingConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        if #available(iOS 17.0, *) {
            let supportsRawLandscapeAngle = connection.isVideoRotationAngleSupported(0)
            if supportsRawLandscapeAngle { connection.videoRotationAngle = 0 }
#if DEBUG
            print("Camera data-output orientation: requested=0°, supported=\(supportsRawLandscapeAngle), " +
                  "applied=\(connection.videoRotationAngle)°")
#endif
        }
    }

    private func configureDevice(_ device: AVCaptureDevice, applyDefaultExposure: Bool = true) throws {
        acceptedPixelFormats = []
        acceptedVideoSettings = [:]
        guard #available(iOS 26.0, *) else { throw CameraError.appleLog2NotSupported }
        let orderedFormats = Self.appleLog2CaptureFormats(in: device.formats)
        guard !orderedFormats.isEmpty else { throw CameraError.appleLog2NotSupported }

        var failures: [String] = []
        for format in orderedFormats {
            do {
                try applyCaptureFormat(format, to: device)
            } catch {
                failures.append("\(Self.captureFormatSubtypeDescription(format)): \(error.localizedDescription)")
                continue
            }

            if let rejection = configureDataOutputForActiveFormat(activeFormat: format) {
                failures.append("\(Self.captureFormatSubtypeDescription(format)): \(rejection)")
                print("Camera capture candidate rejected: \(Self.captureFormatSubtypeDescription(format)): \(rejection)")
            } else {
                break
            }
        }
        guard !acceptedPixelFormats.isEmpty, !acceptedVideoSettings.isEmpty else {
            let detail = failures.isEmpty ? "no eligible formats" : failures.joined(separator: "; ")
            throw CameraError.writerUnavailable(detail)
        }

        try device.lockForConfiguration()
        do {
            defer { device.unlockForConfiguration() }
            applyWhiteBalanceLock(device)
            if applyDefaultExposure, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }
        activeDevice = device
        apertureCameraRevision &+= 1
        if #available(iOS 27.0, *), selectedLensAperture != nil {
            let capability = Self.apertureCapability(for: device)
            selectedLensAperture = capability.isVariable
                ? CameraAperturePolicy.reconcile(selectedLensAperture, with: capability) : nil
            if selectedLensAperture != nil {
                try applySelectedAperture(on: device, mode: isShutterPriority ? .shutterPriority : .manual)
            }
        }
        configureRawLandscapeRecordingConnection()
    }

    private func applyCaptureFormat(_ format: AVCaptureDevice.Format, to device: AVCaptureDevice) throws {
        guard #available(iOS 26.0, *) else { throw CameraError.appleLog2NotSupported }
        guard format.supportedColorSpaces.contains(.appleLog2) else {
            throw CameraError.appleLog2NotSupported
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        device.activeColorSpace = .appleLog2
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 24)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 24)
    }

    private static func appleLog2CaptureFormats(in formats: [AVCaptureDevice.Format]) -> [AVCaptureDevice.Format] {
        guard #available(iOS 26.0, *) else { return [] }
        let candidates = formats.map { format in
            guard CMFormatDescriptionGetMediaType(format.formatDescription) == kCMMediaType_Video else {
                return CameraCaptureFormatPolicy.Candidate(width: 0, height: 0,
                    supportsAppleLog2: false, supports24FPS: false)
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let supports24FPS = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 24 && $0.maxFrameRate >= 24
            }
            return CameraCaptureFormatPolicy.Candidate(
                width: dimensions.width, height: dimensions.height,
                supportsAppleLog2: format.supportedColorSpaces.contains(.appleLog2),
                supports24FPS: supports24FPS,
                isTenBitBiPlanar420: {
                    let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                    return subtype == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                        || subtype == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                }(),
                isTenBitBiPlanar422: {
                    let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                    return subtype == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
                        || subtype == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
                }()
            )
        }
        return CameraCaptureFormatPolicy.appleLog2CandidateIndexes(in: candidates).map { formats[$0] }
    }

    private static func appleLog2CaptureFormat(in formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        appleLog2CaptureFormats(in: formats).first
    }

    private static func captureFormatSubtypeDescription(_ format: AVCaptureDevice.Format?) -> String {
        guard let format else { return "no active video format" }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let chars: [UInt8] = [
            UInt8((subtype >> 24) & 0xff), UInt8((subtype >> 16) & 0xff),
            UInt8((subtype >> 8) & 0xff), UInt8(subtype & 0xff)
        ]
        let printable = chars.allSatisfy { (32...126).contains($0) }
            ? String(bytes: chars, encoding: .ascii) ?? String(format: "0x%08X", subtype)
            : String(format: "0x%08X", subtype)
        return "\(dimensions.width)x\(dimensions.height), subtype \(printable)"
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

    private func configureDataOutputForActiveFormat(activeFormat: AVCaptureDevice.Format) -> String? {
        let supportedPixelFormats = videoOutput.availableVideoPixelFormatTypes.map {
            UInt32(truncating: $0 as NSNumber)
        }
        let candidates = CameraSampleValidationPolicy.preferredTenBitPixelFormats(from: supportedPixelFormats)
        let pixelFormatList = CameraSampleValidationPolicy.fourCCListDescription(supportedPixelFormats)
        print("Camera output negotiation: active format \(Self.captureFormatSubtypeDescription(activeFormat)); " +
              "advertised pixel formats: \(pixelFormatList); ten-bit candidates: " +
              "\(CameraSampleValidationPolicy.fourCCListDescription(candidates))")
        guard !candidates.isEmpty else {
            return "no advertised ten-bit bi-planar YUV pixel format (output advertises: \(pixelFormatList))"
        }
        var candidateFailures: [String] = []
        let selectedPixelFormat = CameraSampleValidationPolicy.firstUsableTenBitPixelFormat(
            from: supportedPixelFormats
        ) { pixelFormat in
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat)]
            if let rejection = configureWriterForDataOutput(pixelFormat: pixelFormat,
                                                            candidates: candidates) {
                candidateFailures.append("\(CameraSampleValidationPolicy.fourCCDescription(pixelFormat)): \(rejection)")
                return false
            } else {
                return true
            }
        }
        guard selectedPixelFormat == nil else { return nil }
        return "no advertised ten-bit format could negotiate HEVC Main10 (output advertises: \(pixelFormatList); " +
            "attempts: \(candidateFailures.joined(separator: "; ")))"
    }

    private func configureWriterForDataOutput(pixelFormat: UInt32,
                                              candidates: [UInt32]) -> String? {
        let codecs = videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
        let codecNames = codecs.map(\.rawValue)
        let codecList = codecNames.isEmpty ? "none" : codecNames.joined(separator: ", ")
        guard #available(iOS 27.0, *) else {
            return "Apple Log 2 writer color tags require iOS 27 (running version is older)"
        }
        let profile = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        let colorProperties = [
            AVVideoLogTransferFunctionKey: AVVideoLogTransferFunction_AppleLog2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        ]
        let dimensions = [CameraSampleValidationPolicy.CodedDimensions.landscape4K,
                          CameraSampleValidationPolicy.CodedDimensions.portrait4K]
        var landscapeSettings: [String: Any]?
        for codedSize in dimensions {
            let settings = CameraSampleValidationPolicy.explicitHEVCMain10Settings(
                width: codedSize.width, height: codedSize.height,
                profile: profile, averageBitRate: DeliverySettings.averageBitRate,
                colorProperties: colorProperties
            )
            let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
            guard CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
                codec: settings[AVVideoCodecKey] as? AVVideoCodecType,
                width: (settings[AVVideoWidthKey] as? NSNumber)?.intValue,
                height: (settings[AVVideoHeightKey] as? NSNumber)?.intValue,
                profile: compression[AVVideoProfileLevelKey] as? String,
                expectedProfile: profile
            ) else {
                return "constructed settings are not HEVC Main10 at \(codedSize.width)x\(codedSize.height)"
            }
            let probeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("hevc-main10-capability-\(UUID().uuidString).mov")
            let writer: AVAssetWriter
            do {
                writer = try AVAssetWriter(outputURL: probeURL, fileType: .mov)
            } catch {
                return "could not create a temporary AVAssetWriter capability probe: \(error.localizedDescription)"
            }
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                return "AVAssetWriter.canApply rejected HEVC Main10 \(codedSize.width)x\(codedSize.height) " +
                    "(profile: \(profile), input pixel format: " +
                    "\(CameraSampleValidationPolicy.fourCCDescription(pixelFormat)); " +
                    "capture-output MOV codecs (diagnostic only): \(codecList))"
            }
            if codedSize == .landscape4K { landscapeSettings = settings }
        }
        guard let settings = landscapeSettings else {
            return "landscape HEVC Main10 writer settings were not constructed"
        }
        acceptedPixelFormats = [pixelFormat]
        acceptedVideoSettings = settings
        print("Capture writer capability: hvc1 Main10 3840x2160 and 2160x3840; selected pixel format " +
              "\(CameraSampleValidationPolicy.fourCCDescription(pixelFormat)); " +
              "advertised ten-bit formats: \(CameraSampleValidationPolicy.fourCCListDescription(candidates)); " +
              "capture-output MOV codecs (diagnostic only): \(codecList)")
        return nil
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
            if self.activeLens == lens, self.isConfigured {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
                return
            }
            guard !self.isRecordingOrPending else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(CameraError.exposureChangeDuringRecording) } }
                return
            }
            self.invalidateMetering()
            var switchError: Error?
            let previousDevice = self.activeDevice
            let previousFormat = previousDevice?.activeFormat
            let previousColorSpace = previousDevice?.activeColorSpace
            let previousMinFrameDuration = previousDevice?.activeVideoMinFrameDuration
            let previousMaxFrameDuration = previousDevice?.activeVideoMaxFrameDuration
            self.session.beginConfiguration()
            var configurationOpen = true

            guard let device = AVCaptureDevice.default(
                lens.deviceType,
                for: .video,
                position: lens.position
            ) else {
                let error = CameraError.noCameraAvailable
                self.session.commitConfiguration()
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
                return
            }

            guard #available(iOS 26.0, *), Self.appleLog2CaptureFormat(in: device.formats) != nil else {
                let error = CameraError.appleLog2NotSupported
                self.session.commitConfiguration()
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
                return
            }

            do {
                try self.addDevice(device)
                self.session.commitConfiguration()
                configurationOpen = false
                try self.configureDevice(device)
                self.activeLens = lens
                self.isConfigured = true
                self.logApertureCapability(for: device, lens: lens)
            } catch {
                let originalError = error
                switchError = originalError
                if configurationOpen {
                    self.session.commitConfiguration()
                    configurationOpen = false
                }
                // Re-adding an input resets its frame durations, so restore
                // the prior capture configuration before committing rollback.
                if let previousDevice {
                    self.session.beginConfiguration()
                    var rollbackError: Error?
                    var previousDeviceRestored = false
                    do {
                        try self.addDevice(previousDevice)
                        if let previousFormat, let previousColorSpace,
                           let previousMinFrameDuration, let previousMaxFrameDuration {
                            do {
                                try previousDevice.lockForConfiguration()
                                defer { previousDevice.unlockForConfiguration() }
                                previousDevice.activeFormat = previousFormat
                                previousDevice.activeColorSpace = previousColorSpace
                                previousDevice.activeVideoMinFrameDuration = previousMinFrameDuration
                                previousDevice.activeVideoMaxFrameDuration = previousMaxFrameDuration
                            }
                        }
                        previousDeviceRestored = true
                    } catch {
                        rollbackError = error
                    }
                    self.session.commitConfiguration()
                    self.activeDevice = previousDeviceRestored ? previousDevice : nil
                    do { try self.configureDevice(previousDevice, applyDefaultExposure: false) }
                    catch { if rollbackError == nil { rollbackError = error } }
                    if let rollbackError {
                        self.isConfigured = false
                        switchError = CameraError.lensRollbackFailed(original: originalError, rollback: rollbackError)
                    } else {
                        self.isConfigured = true
                        self.logApertureCapability(for: previousDevice, lens: self.activeLens)
                    }
                } else {
                    self.activeDevice = nil
                    self.isConfigured = false
                }
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

    /// Metered exposure level's offset from the device's target exposure, in EV
    /// (positive = over). This is the live meter the under/over indicator shows
    /// and the shutter-priority stabiliser gates on; it is updated continuously
    /// by the device, including while custom exposure is held.
    var currentExposureTargetOffset: Float {
        activeDevice?.exposureTargetOffset ?? 0
    }

    /// Whether the metered offset is readable (an active device is configured).
    var hasExposureMeter: Bool {
        guard let device = activeDevice else { return false }
        return device.exposureTargetOffset.isFinite
    }

    /// Read all aperture UI state on the serialized camera queue. The revision
    /// lets the view model discard snapshots queued before a lens/config change.
    func readApertureSnapshot(completion: @escaping @MainActor @Sendable (CameraApertureSnapshot) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let capability: CameraAperturePolicy.Capability
            let measured: Float?
            if #available(iOS 27.0, *), let device = self.activeDevice {
                capability = Self.apertureCapability(for: device)
                let aperture = device.lensAperture
                measured = aperture.isFinite && aperture > 0 ? aperture : nil
            } else {
                capability = .unavailable
                measured = nil
            }
            let snapshot = CameraApertureSnapshot(
                capability: capability,
                measured: measured,
                selected: self.selectedLensAperture,
                cameraRevision: self.apertureCameraRevision
            )
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(snapshot) } }
        }
    }

    @available(iOS 27.0, *)
    private static func apertureCapability(for device: AVCaptureDevice) -> CameraAperturePolicy.Capability {
        let format = device.activeFormat
        return CameraAperturePolicy.capability(
            recommended: format.recommendedLensApertureStops,
            minimum: format.minLensAperture,
            maximum: format.maxLensAperture
        )
    }

    private func logApertureCapability(for device: AVCaptureDevice, lens: CameraLens) {
#if DEBUG
        guard #available(iOS 27.0, *) else {
            print("Camera aperture: lens=\(lens.rawValue), capability=unavailable (iOS < 27)")
            return
        }
        let format = device.activeFormat
        let capability = Self.apertureCapability(for: device)
        let stops = capability.stops.map { String(format: "f/%.1f", $0) }.joined(separator: ",")
        let measured = String(format: "f/%.1f", device.lensAperture)
        print("Camera aperture: lens=\(lens.rawValue), capability=\(capability.isVariable ? "variable" : (stops.isEmpty ? "unavailable" : "fixed")), stops=[\(stops)], range=f/\(String(format: "%.1f", format.minLensAperture))...f/\(String(format: "%.1f", format.maxLensAperture)), measured=\(measured)")
#endif
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
    private func setExposureLocked(iso: Float, shutter: CMTime, on device: AVCaptureDevice,
                                   mode: CameraAperturePolicy.ExposureMode? = nil) throws {
        let exposureMode = mode ?? (isShutterPriority ? .shutterPriority : .manual)
        let clampedISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
        let clampedShutter = min(max(shutter, device.activeFormat.minExposureDuration),
                                 device.activeFormat.maxExposureDuration)
        if #available(iOS 27.0, *), Self.apertureCapability(for: device).isVariable {
            try applyCustomExposureHoldingAperture(on: device, mode: exposureMode,
                                                   duration: clampedShutter, iso: clampedISO)
            return
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setExposureModeCustom(duration: clampedShutter, iso: clampedISO) { _ in }
    }

    /// Apply a custom exposure without ever changing the lens aperture. A
    /// variable-iris format is asked for the held/selected aperture; if the
    /// format rejects it, fall back to the aperture-agnostic overload so the
    /// metering path can never raise `apertureExposureUnsupported`.
    @available(iOS 27.0, *)
    private func applyCustomExposureHoldingAperture(on device: AVCaptureDevice,
                                                    mode: CameraAperturePolicy.ExposureMode,
                                                    duration: CMTime, iso: Float) throws {
        if let parameters = try? apertureParameters(for: device, mode: mode,
                                                    duration: duration, manualISO: iso) {
            let applied = try CameraAperturePolicy.performIfSupported(parameters, supports: {
                device.activeFormat.supportsExposureModeCustom(
                    lensAperture: $0.aperture, duration: $0.duration, iso: $0.iso)
            }) {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setExposureModeCustom(lensAperture: parameters.aperture,
                                             duration: parameters.duration, iso: parameters.iso) { _ in }
            }
            if applied { return }
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setExposureModeCustom(duration: duration, iso: iso) { _ in }
    }

    @available(iOS 27.0, *)
    private func apertureParameters(for device: AVCaptureDevice,
                                    mode: CameraAperturePolicy.ExposureMode,
                                    duration: CMTime,
                                    manualISO: Float) throws -> CameraAperturePolicy.ExposureParameters {
        let capability = Self.apertureCapability(for: device)
        guard !capability.stops.isEmpty else { throw CameraError.apertureUnavailable }
        // Aperture is never auto-driven: without an explicit user choice the
        // current iris value is held. The auto sentinel is never requested
        // because custom exposure rejects it on this hardware.
        let heldAperture = CameraAperturePolicy.reconcile(device.lensAperture, with: capability)
            ?? capability.stops[0]
        let autoISO = AVCaptureDevice.autoISO
        let parameters = CameraAperturePolicy.exposureParameters(
            selectedAperture: selectedLensAperture,
            heldAperture: heldAperture,
            mode: mode,
            manualISO: manualISO,
            autoISO: autoISO,
            minISO: device.activeFormat.minISO,
            maxISO: device.activeFormat.maxISO,
            duration: duration
        )
        guard let parameters else { throw CameraError.apertureExposureUnsupported }
        return parameters
    }

    @available(iOS 27.0, *)
    private func applySelectedAperture(on device: AVCaptureDevice,
                                      mode: CameraAperturePolicy.ExposureMode) throws {
        let duration = min(max(Self.filmShutterDuration, device.activeFormat.minExposureDuration),
                           device.activeFormat.maxExposureDuration)
        let parameters = try apertureParameters(for: device, mode: mode,
                                                duration: duration, manualISO: manualExposureISO)
        let applied = try CameraAperturePolicy.performIfSupported(parameters, supports: {
            device.activeFormat.supportsExposureModeCustom(
                lensAperture: $0.aperture, duration: $0.duration, iso: $0.iso)
        }) {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setExposureModeCustom(lensAperture: parameters.aperture,
                                         duration: parameters.duration, iso: parameters.iso) { _ in }
        }
        guard applied else { throw CameraError.apertureExposureUnsupported }
    }

    /// Apply a supported aperture or Auto request to the currently negotiated
    /// active format. Every capability read and write runs on sessionQueue.
    func setLensAperture(_ aperture: Float?, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            var operationError: Error?
            if self.isRecordingOrPending {
                operationError = CameraError.exposureChangeDuringRecording
            } else if #available(iOS 27.0, *), let device = self.activeDevice {
                let capability = Self.apertureCapability(for: device)
                guard capability.isVariable,
                      aperture.map({ capability.stops.contains($0) }) ?? true else {
                    operationError = CameraError.apertureUnavailable
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
                    return
                }
                let previous = self.selectedLensAperture
                self.selectedLensAperture = aperture
                do {
                    let mode: CameraAperturePolicy.ExposureMode = self.isShutterPriority ? .shutterPriority : .manual
                    let clampedDuration = min(max(Self.filmShutterDuration, device.activeFormat.minExposureDuration),
                                              device.activeFormat.maxExposureDuration)
                    let parameters = try self.apertureParameters(
                        for: device, mode: mode, duration: clampedDuration,
                        manualISO: self.manualExposureISO)
                    let applied = try CameraAperturePolicy.performIfSupported(parameters, supports: {
                        device.activeFormat.supportsExposureModeCustom(
                            lensAperture: $0.aperture, duration: $0.duration, iso: $0.iso)
                    }) {
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        device.setExposureModeCustom(lensAperture: parameters.aperture,
                                                     duration: parameters.duration, iso: parameters.iso) { _ in }
                    }
                    guard applied else { throw CameraError.apertureExposureUnsupported }
                } catch {
                    self.selectedLensAperture = previous
                    operationError = error
                }
            } else {
                operationError = CameraError.apertureUnavailable
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
        }
    }

    /// 180° shutter angle at 24fps = 1/48s.
    static let filmShutterDuration = CMTime(value: 1, timescale: 48)

    /// Lock exposure to the film standard: 180° shutter (1/48s) at a fixed ISO.
    func lockManualExposure(iso: Float, completion: (@MainActor @Sendable (Error?) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateMetering()
            var operationError: Error?
            if self.isRecordingOrPending {
                operationError = CameraError.exposureChangeDuringRecording
            } else if let device = self.activeDevice {
                do {
                    try self.setExposureLocked(iso: iso, shutter: Self.filmShutterDuration,
                                               on: device, mode: .manual)
                    self.manualExposureISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
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
            if self.isRecordingOrPending {
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
            if self.isRecordingOrPending {
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
            guard self.isShutterPriority, !self.isRecordingOrPending else { return }
            // An explicit EV change is a user action: re-pin immediately rather
            // than waiting for the deadband gate to open.
            self.pinShutterToFilm(force: true)
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
            guard !self.isRecordingOrPending else { return }
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
            guard let self, self.isShutterPriority, !self.isRecordingOrPending else { return }
            self.pinShutterToFilm()
        }
    }

    func onCameraOperationError(_ handler: @escaping @MainActor @Sendable (Error, CameraLens) -> Void) {
        sessionQueue.async { [weak self] in self?.onCameraError = handler }
    }

    private func pinShutterToFilm(force: Bool = false) {
        guard let device = activeDevice else { return }
        let duration = min(max(Self.filmShutterDuration, device.activeFormat.minExposureDuration),
                           device.activeFormat.maxExposureDuration)
        let ev = exposureBiasEV
        // Deadband gate. Without it every 1.5 s tick dropped the device back
        // into auto exposure — a visible exposure step — and re-pinned at a
        // half-converged sample, so the pin chased its own metering. While the
        // held exposure is still within the deadband there is nothing to do.
        guard force || ExposureStabilizer.shouldRemeasure(
            meteredOffsetEV: device.exposureTargetOffset,
            targetEV: ev,
            hasPin: pinnedExposure != nil
        ) else { return }
        if #available(iOS 27.0, *), Self.apertureCapability(for: device).isVariable {
            do {
                try applyCustomExposureHoldingAperture(on: device, mode: .shutterPriority,
                                                       duration: duration, iso: manualExposureISO)
            } catch {
                reportCameraError(error)
                return
            }
        } else {
            // Fixed/unavailable iris formats keep their previous auto-meter path.
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                guard device.isExposureModeSupported(.continuousAutoExposure) else { return }
                device.exposureMode = .continuousAutoExposure
            } catch {
                reportCameraError(error)
                return
            }
        }

        // Pin at the measured ISO after the meter settles. EV remains a software
        // compensation so custom exposure mode does not reset it; explicit iris
        // stays fixed because variable formats never enter full continuous AE.
        let generation = meterGeneration.issue()
        sessionQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.meterGeneration.accepts(generation), self.isShutterPriority,
                  !self.isRecordingOrPending,
                  let device = self.activeDevice else { return }
            let iso: Float
            switch ExposureStabilizer.decide(
                meteredISO: device.iso, ev: ev, current: self.pinnedExposure,
                minimum: device.activeFormat.minISO, maximum: device.activeFormat.maxISO
            ) {
            case .apply(let target):
                iso = target
            case .hold:
                // Re-freeze the previous pin instead of leaving the device in
                // the auto-exposure state the re-meter briefly entered.
                let held = self.pinnedExposure?.iso ?? device.iso
                guard held.isFinite, held > 0 else {
                    self.reportCameraError(CameraError.exposureMeterUnavailable)
                    return
                }
                iso = held
            }
            do {
                try self.setExposureLocked(iso: iso, shutter: duration,
                                           on: device, mode: .manual)
            } catch {
                self.reportCameraError(error)
                return
            }
            self.pinnedExposure = ExposureStabilizer.Pin(iso: iso, ev: ev, meteredISO: device.iso)
        }
    }

    private func invalidateMetering() {
        meterGeneration.invalidate()
        pinnedExposure = nil
    }

    private func reportCameraError(_ error: Error) {
        guard let handler = onCameraError else { return }
        // Attribute queued callbacks to the camera that produced them. A
        // metering failure can already be enqueued on main when a lens switch
        // invalidates its generation, so the receiver must reject old-lens
        // results as well as callbacks that have not fired yet.
        let sourceLens = activeLens
#if DEBUG
        if error.localizedDescription == CameraError.apertureExposureUnsupported.localizedDescription {
            let device = activeDevice
            let format = device?.activeFormat
            let apertureCapability: String
            if #available(iOS 27.0, *), let device {
                let capability = Self.apertureCapability(for: device)
                apertureCapability = capability.isVariable ? "variable" : "fixed/unavailable"
            } else {
                apertureCapability = "unavailable"
            }
            let callStack = Thread.callStackSymbols.prefix(10).joined(separator: " <- ")
            print("Aperture error provenance: path=reportCameraError, lens=\(sourceLens.rawValue), " +
                  "device=\(device?.deviceType.rawValue ?? "nil"), position=\(device.map { String(describing: $0.position) } ?? "nil"), " +
                  "format=\(format.map { String(describing: ObjectIdentifier($0)) } ?? "nil"), " +
                  "capability=\(apertureCapability), selected=\(selectedLensAperture.map { String(describing: $0) } ?? "Auto"), " +
                  "iso=\(device?.iso.description ?? "nil"), shutter=\(device?.exposureDuration.seconds.description ?? "nil"), " +
                  "stack=\(callStack)")
        }
#endif
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(error, sourceLens) } }
    }

    // MARK: - Recording

    func startRecording(to url: URL, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateMetering()
            guard !self.isRecordingOrPending else {
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
            guard #available(iOS 26.0, *),
                  device.activeColorSpace == .appleLog2,
                  Self.appleLog2CaptureFormat(in: [device.activeFormat]) != nil else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(CameraError.appleLog2NotSupported) } }
                return
            }
            guard !self.acceptedVideoSettings.isEmpty, !self.acceptedPixelFormats.isEmpty else {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    completion(CameraError.writerUnavailable("the active format has not been negotiated"))
                } }
                return
            }
            self.recordingStartPending = true
            self.pendingStartCompletion = completion
            self.recordingGeneration &+= 1
            let generation = self.recordingGeneration
            do {
                let iso = min(max(device.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                let shutter = min(max(Self.filmShutterDuration, device.activeFormat.minExposureDuration),
                                  device.activeFormat.maxExposureDuration)
                let completionHandler: (CMTime) -> Void = { [weak self] _ in
                    self?.sessionQueue.async {
                        guard let self, self.recordingGeneration == generation,
                              self.recordingStartPending else { return }
                        self.beginSampleBufferRecording(to: url, generation: generation)
                    }
                }
                if #available(iOS 27.0, *), Self.apertureCapability(for: device).isVariable {
                    let measuredAperture = device.lensAperture
                    guard let pin = CameraAperturePolicy.recordingPin(
                        selectedAperture: self.selectedLensAperture, measuredAperture: measuredAperture
                    ) else { throw CameraError.apertureExposureUnsupported }
                    let parameters = CameraAperturePolicy.ExposureParameters(
                        aperture: pin.aperture, duration: shutter, iso: iso)
                    let applied = try CameraAperturePolicy.performIfSupported(parameters, supports: {
                        device.activeFormat.supportsExposureModeCustom(
                            lensAperture: $0.aperture, duration: $0.duration, iso: $0.iso)
                    }) {
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        device.setExposureModeCustom(lensAperture: pin.aperture,
                                                     duration: shutter, iso: iso,
                                                     completionHandler: completionHandler)
                    }
                    guard applied else { throw CameraError.apertureExposureUnsupported }
                    self.recordingAperturePin = pin
                } else {
                    try device.lockForConfiguration()
                    do {
                        defer { device.unlockForConfiguration() }
                        device.setExposureModeCustom(duration: shutter, iso: iso,
                                                     completionHandler: completionHandler)
                    }
                }
            } catch {
                self.recordingStartPending = false
                self.pendingStartCompletion = nil
                self.recordingAperturePin = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
            }
        }
    }

    private func beginSampleBufferRecording(to url: URL, generation: UInt64) {
        guard let device = activeDevice,
              #available(iOS 26.0, *),
              device.activeColorSpace == .appleLog2,
              Self.appleLog2CaptureFormat(in: [device.activeFormat]) != nil else {
            recordingStartPending = false
            failPendingStart(CameraError.appleLog2NotSupported)
            return
        }
        guard !acceptedVideoSettings.isEmpty, !acceptedPixelFormats.isEmpty else {
            failPendingStart(CameraError.writerUnavailable("the active format has not been negotiated"))
            return
        }
        // The device can recommend uncompressed `lpcm` for the built-in mic; the
        // original is contracted to AAC, so request it explicitly.
        let audioSettings: [String: Any]? = microphoneAdded
            ? CameraSampleValidationPolicy.aacAudioSettings(
                sampleRate: CameraSampleValidationPolicy.normalizedAACSampleRate(
                    AVAudioSession.sharedInstance().sampleRate),
                averageBitRate: DeliverySettings.aacAverageBitRate)
            : nil
#if DEBUG
        if let audioSettings {
            print("HEVC Log2 audio settings: \(String(describing: audioSettings)); " +
                  "recommended=\(String(describing: audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)))")
        }
#endif
        guard recorderCompletionBridge.begin(epoch: generation) else {
            failPendingStart(CameraError.recordingInProgress)
            return
        }
        let callbackContext = CameraSessionRecorderCallbackContext(session: self, queue: sessionQueue)
#if DEBUG
        let preservationProbeEnabled = debugSmokeURL == url
#else
        let preservationProbeEnabled = false
#endif
        sampleBufferRecorder.begin(
            to: url,
            videoSettings: acceptedVideoSettings,
            audioSettings: audioSettings,
            acceptedPixelFormats: acceptedPixelFormats,
            metadata: captureMetadataItems(),
            preservationProbeEnabled: preservationProbeEnabled,
            requiresAudioEvidence: microphoneAdded,
            onStarted: { [callbackContext] error in
                callbackContext.enqueueStarted(CameraRecorderErrorBox(error), generation: generation)
            },
            onFinished: { [callbackContext] result in
                callbackContext.enqueueFinished(CameraRecorderResultBox(result), generation: generation)
            }
        )
    }

    fileprivate func recorderStartedOnSessionQueue(_ error: Error?, generation: UInt64) {
        guard recordingGeneration == generation, recordingStartPending,
              recorderCompletionBridge.acceptsStarted(epoch: generation) else { return }
        recordingStartPending = false
        let completion = pendingStartCompletion
        pendingStartCompletion = nil
        recordingActive = error == nil
        refreshPublicRecordingState()
        if let completion {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
    }

    fileprivate func recorderFinishedOnSessionQueue(_ result: Result<URL, Error>, generation: UInt64) {
        guard let shouldNotifyForEpoch = recorderCompletionBridge.consumeTerminal(epoch: generation) else { return }
        let hadStarted = recordingActive
        let shouldNotifyFinish = shouldNotifyForEpoch && hadStarted && recordingGeneration == generation
        recordingActive = false
        recordingFinishing = false
        recordingStartPending = false
        restoreAutomaticApertureAfterRecording()
        refreshPublicRecordingState()
        let completion: Result<RecordingCompletion, Error>
        switch result {
        case .success(let outputURL):
            completion = .success(RecordingCompletion(url: outputURL, warning: nil))
        case .failure(let error):
            completion = .failure(error)
        }
        let handler = onRecordingFinished
#if DEBUG
        if let smokeURL = debugSmokeURL {
            debugSmokeURL = nil
            let timedOut = debugSmokeTimedOut
            debugSmokeTimedOut = false
            DispatchQueue.main.async {
                if timedOut {
                    print("HEVC Log2 smoke failed: capture exceeded its timeout")
                } else if case .success(let completion) = completion {
                    print("HEVC Log2 smoke passed: \(completion.url.lastPathComponent)")
                } else if case .failure(let error) = completion {
                    print("HEVC Log2 smoke failed: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: smokeURL)
            }
            return
        }
#endif
        guard shouldNotifyFinish else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?(completion) } }
    }

    private func failPendingStart(_ error: Error) {
        recordingStartPending = false
        restoreAutomaticApertureAfterRecording()
        let completion = pendingStartCompletion
        pendingStartCompletion = nil
        if let completion {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
    }

    /// Recording pins the measured iris when the user's choice is Auto, then
    /// restores Auto after the writer reaches a terminal state.
    private func restoreAutomaticApertureAfterRecording() {
        guard let pin = recordingAperturePin else { return }
        recordingAperturePin = nil
        guard CameraAperturePolicy.selectedApertureAfterRecording(pin: pin) == nil else { return }
        guard #available(iOS 27.0, *), let device = activeDevice,
              Self.apertureCapability(for: device).isVariable else { return }
        do {
            let mode: CameraAperturePolicy.ExposureMode = isShutterPriority ? .shutterPriority : .manual
            let duration = min(max(Self.filmShutterDuration, device.activeFormat.minExposureDuration),
                               device.activeFormat.maxExposureDuration)
            let parameters = try apertureParameters(for: device, mode: mode,
                                                    duration: duration, manualISO: manualExposureISO)
            let applied = try CameraAperturePolicy.performIfSupported(parameters, supports: {
                device.activeFormat.supportsExposureModeCustom(
                    lensAperture: $0.aperture, duration: $0.duration, iso: $0.iso)
            }) {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setExposureModeCustom(lensAperture: parameters.aperture,
                                             duration: parameters.duration, iso: parameters.iso) { _ in }
            }
            guard applied else { throw CameraError.apertureExposureUnsupported }
        } catch { reportCameraError(error) }
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
            Self.captureItem("capture-iso", "\(Int(device.iso))"),
            Self.captureItem("capture-color-space", Self.captureColorSpaceLabel(device)),
            Self.captureItem("capture-format", Self.captureFormatLabel(device)),
            Self.captureItem("capture-codec", acceptedVideoSettings[AVVideoCodecKey] as? String ?? "unknown")
        ]
    }

    private static func captureColorSpaceLabel(_ device: AVCaptureDevice) -> String {
        if #available(iOS 26.0, *), device.activeColorSpace == .appleLog2 { return "Apple Log 2" }
        return String(describing: device.activeColorSpace)
    }

    private static func captureFormatLabel(_ device: AVCaptureDevice) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let frameRate = device.activeVideoMinFrameDuration.seconds > 0
            ? Int((1 / device.activeVideoMinFrameDuration.seconds).rounded()) : 0
        return "\(dimensions.width)x\(dimensions.height)@\(frameRate)fps"
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
                self.failPendingStart(CameraSampleBufferRecorderError.noVideoFrames)
                if let epoch = self.recorderCompletionBridge.activeEpoch {
                    self.recorderCompletionBridge.cancelUserStart(epoch: epoch)
                    self.recordingFinishing = true
                    self.refreshPublicRecordingState()
                    self.sampleBufferRecorder.cancel()
                }
            } else if self.recordingActive {
                self.recordingFinishing = true
                self.refreshPublicRecordingState()
                self.sampleBufferRecorder.stop()
            }
        }
    }

#if DEBUG
    /// Debug-only: grab a single frame from the live camera as a `CVPixelBuffer`
    /// in the same RGBA-half layout the offline renderer decodes, so the debug
    /// single-frame render can feed it straight to pass1.
    ///
    /// Uses a dedicated second video output whose connection stays disabled
    /// except while a frame is requested, so the recorder's `videoOutput` and
    /// delegate are never touched. Only runs when the session is not recording,
    /// and reconfigures nothing but its own output. `completion` runs on
    /// `sessionQueue`.
    func captureDebugFrame(completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.session.isRunning,
                  !self.isRecordingOrPending,
                  let pixelFormat = self.acceptedPixelFormats.first,
                  self.attachDebugFrameOutput(pixelFormat: pixelFormat),
                  let connection = self.debugFrameOutput.connection(with: .video) else {
                completion(nil)
                return
            }
            let request = CameraDebugFrameRequest()
            connection.isEnabled = true
            self.debugFrameTap.request { [weak self] buffer in
                guard let self else { return }
                self.sessionQueue.async {
                    guard request.finish() else { return }
                    connection.isEnabled = false
                    completion(DebugFrameConverter.rgbaHalfBuffer(from: buffer))
                }
            }
            self.sessionQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard request.finish() else { return }
                self?.debugFrameOutput.connection(with: .video)?.isEnabled = false
                completion(nil)
            }
        }
    }

    /// Add (once) or refresh the debug tap's output. Returns false if the session
    /// refuses the output, leaving the recording path untouched either way.
    private func attachDebugFrameOutput(pixelFormat: UInt32) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat)]
        if session.outputs.contains(where: { $0 === debugFrameOutput }) {
            debugFrameOutput.videoSettings = settings
            return true
        }
        guard session.canAddOutput(debugFrameOutput) else { return false }
        debugFrameOutput.alwaysDiscardsLateVideoFrames = true
        debugFrameOutput.videoSettings = settings
        debugFrameOutput.setSampleBufferDelegate(debugFrameTap, queue: debugFrameQueue)
        session.addOutput(debugFrameOutput)
        debugFrameOutput.connection(with: .video)?.isEnabled = false
        return true
    }

    func startDebugSmokeCapture() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.session.isRunning, !self.isRecordingOrPending else {
                print("HEVC Log2 smoke failed: camera session is unavailable or busy")
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hevc-log2-smoke-\(UUID().uuidString).mov")
            self.debugSmokeURL = url
            self.debugSmokeTimedOut = false
            let smokeContext = CameraSessionSmokeCallbackContext(session: self, queue: self.sessionQueue, url: url)
            self.startRecording(to: url) { [smokeContext] error in
                smokeContext.recordingStarted(errorDescription: error?.localizedDescription)
            }
            smokeContext.scheduleTimeout()
        }
    }

    fileprivate func debugSmokeStartFailed(_ message: String, url: URL) {
        guard debugSmokeURL == url else { return }
        debugSmokeURL = nil
        debugSmokeTimedOut = false
        print("HEVC Log2 smoke failed to start: \(message)")
        try? FileManager.default.removeItem(at: url)
    }

    fileprivate func debugSmokeStop(url: URL, timedOut: Bool) {
        guard debugSmokeURL == url else { return }
        debugSmokeTimedOut = timedOut
        guard timedOut else {
            stopRecording()
            return
        }
        recordingGeneration &+= 1
        if recordingStartPending {
            recordingStartPending = false
            failPendingStart(CameraSampleBufferRecorderError.cancelled)
        }
        if let epoch = recorderCompletionBridge.activeEpoch {
            recorderCompletionBridge.cancelUserStart(epoch: epoch)
            recordingFinishing = true
            refreshPublicRecordingState()
            sampleBufferRecorder.cancel()
        } else {
            finishDebugSmokeTimeoutWithoutRecorder(url: url)
        }
    }

    private func finishDebugSmokeTimeoutWithoutRecorder(url: URL) {
        guard debugSmokeURL == url else { return }
        debugSmokeURL = nil
        debugSmokeTimedOut = false
        recordingActive = false
        recordingFinishing = false
        recordingStartPending = false
        refreshPublicRecordingState()
        print("HEVC Log2 smoke failed: capture exceeded its timeout before the recorder started")
        try? FileManager.default.removeItem(at: url)
    }
#endif

    var isRecording: Bool {
        recordingStateLock.lock()
        defer { recordingStateLock.unlock() }
        return publicRecordingState
    }

    private var isRecordingOrPending: Bool { recordingActive || recordingFinishing || recordingStartPending }

    private func refreshPublicRecordingState() {
        recordingStateLock.lock()
        publicRecordingState = recordingActive || recordingFinishing
        recordingStateLock.unlock()
    }

    func onFinish(_ handler: @escaping @MainActor @Sendable (Result<RecordingCompletion, Error>) -> Void) {
        sessionQueue.async { [weak self] in self?.onRecordingFinished = handler }
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
            if self.recordingStartPending {
                self.recordingStartPending = false
                self.recordingGeneration &+= 1
                self.failPendingStart(CameraSampleBufferRecorderError.cancelled)
                if let epoch = self.recorderCompletionBridge.activeEpoch {
                    self.recorderCompletionBridge.cancelUserStart(epoch: epoch)
                    self.recordingFinishing = true
                    self.refreshPublicRecordingState()
                    self.sampleBufferRecorder.cancel()
                }
            } else if self.recordingActive {
                self.recordingFinishing = true
                self.refreshPublicRecordingState()
                self.sampleBufferRecorder.stop()
            }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
}

/// Sendable bridge for the writer queue. It only retains a weak session and
/// hops recorder results to sessionQueue before touching camera state.
private final class CameraSessionRecorderCallbackContext: @unchecked Sendable {
    private weak var session: CameraSession?
    private let queue: DispatchQueue

    init(session: CameraSession, queue: DispatchQueue) {
        self.session = session
        self.queue = queue
    }

    func enqueueStarted(_ error: CameraRecorderErrorBox, generation: UInt64) {
        queue.async { [self] in session?.recorderStartedOnSessionQueue(error.value, generation: generation) }
    }

    func enqueueFinished(_ result: CameraRecorderResultBox, generation: UInt64) {
        queue.async { [self] in session?.recorderFinishedOnSessionQueue(result.result, generation: generation) }
    }
}

#if DEBUG
/// The launch smoke's delayed callbacks carry only immutable URL/configuration
/// and enqueue all mutable session access onto sessionQueue.
private final class CameraSessionSmokeCallbackContext: @unchecked Sendable {
    private weak var session: CameraSession?
    private let queue: DispatchQueue
    private let url: URL

    init(session: CameraSession, queue: DispatchQueue, url: URL) {
        self.session = session
        self.queue = queue
        self.url = url
    }

    func recordingStarted(errorDescription: String?) {
        if let errorDescription {
            queue.async { [self] in session?.debugSmokeStartFailed(errorDescription, url: url) }
        } else {
            queue.asyncAfter(deadline: .now() + 3) { [self] in session?.debugSmokeStop(url: url, timedOut: false) }
        }
    }

    func scheduleTimeout() {
        queue.asyncAfter(deadline: .now() + 15) { [self] in session?.debugSmokeStop(url: url, timedOut: true) }
    }
}
#endif

private struct CameraRecorderErrorBox: @unchecked Sendable {
    let value: Error?
    init(_ value: Error?) { self.value = value }
}

private struct CameraRecorderResultBox: @unchecked Sendable {
    let result: Result<URL, Error>
    init(_ result: Result<URL, Error>) { self.result = result }
}

enum CameraError: LocalizedError {
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput
    case writerUnavailable(String)
    case appleLogNotSupported
    case appleLog2NotSupported
    case recordingInProgress
    case destinationAlreadyExists
    case recordingFailed
    case exposureChangeDuringRecording
    case apertureUnavailable
    case apertureExposureUnsupported
    case exposureMeterUnavailable
    case lensRollbackFailed(original: Error, rollback: Error)

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:
            return "No camera available."
        case .cannotAddInput:
            return "Failed to add camera input to capture session."
        case .cannotAddOutput:
            return "Failed to add a sample-buffer output to the capture session."
        case .writerUnavailable(let detail):
            return "Apple Log 2 HEVC Main10 recording is unavailable. \(detail)"
        case .appleLogNotSupported:
            return "Apple Log color space is not supported on this device."
        case .appleLog2NotSupported:
            return "Apple Log 2 recording requires a supported 4K, 24 fps camera format on this device."
        case .recordingInProgress:
            return "A recording is already in progress."
        case .destinationAlreadyExists:
            return "The recording destination already exists."
        case .recordingFailed:
            return "The recording could not be finalized."
        case .exposureChangeDuringRecording:
            return "Exposure cannot be changed during a recording."
        case .apertureUnavailable:
            return "Aperture control is unavailable for the active camera format."
        case .apertureExposureUnsupported:
            return "The active camera format does not support that aperture with the current exposure settings."
        case .exposureMeterUnavailable:
            return "The camera could not provide a valid ISO reading for shutter-priority exposure."
        case .lensRollbackFailed(let original, let rollback):
            return "Camera switch failed (\(original.localizedDescription)); restoring the previous camera also failed (\(rollback.localizedDescription))."
        }
    }
}

struct RecordingCompletion: @unchecked Sendable {
    let url: URL
    let warning: Error?
}
