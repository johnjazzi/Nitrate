import AVFoundation

protocol CameraSampleBufferWriting: AnyObject {
    var status: AVAssetWriter.Status { get }
    var error: Error? { get }
    func start(at time: CMTime) -> Bool
    func isReady(for mediaType: AVMediaType) -> Bool
    func append(_ sampleBuffer: CMSampleBuffer, for mediaType: AVMediaType) -> Bool
    func markInputsAsFinished()
    func finishWriting(completion: @escaping () -> Void)
    func cancelWriting()
}

typealias CameraSampleBufferWriterFactory = (
    _ url: URL, _ videoSettings: [String: Any], _ audioSettings: [String: Any]?, _ metadata: [AVMetadataItem],
    _ transform: CGAffineTransform
) throws -> CameraSampleBufferWriting
typealias CameraCaptureCodedDimensions = CameraSampleValidationPolicy.CodedDimensions

/// A bounded sample-buffer writer. Each clip owns a distinct writer; recorder
/// state is confined to the shared serial capture delegate queue.
final class CameraSampleBufferRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    private var state: CameraSampleBufferRecorderState = .idle
    private var writer: CameraSampleBufferWriting?
    private var destination: URL?
    private var videoSettings: [String: Any] = [:]
    private var audioSettings: [String: Any]?
    private var acceptedPixelFormats: Set<UInt32> = []
    private var metadata: [AVMetadataItem] = []
    private var transform = CGAffineTransform.identity
    private var codedDimensions: CameraCaptureCodedDimensions?
    private var started: (@Sendable (Error?) -> Void)?
    private var finished: (@Sendable (Result<URL, Error>) -> Void)?
    private var sessionStartTime: CMTime?
    private var lastVideoTime: CMTime?
    private var lastAudioTime: CMTime?
    private var appendedVideoFrames = 0
    private var appendedAudioSamples = 0
    private var recentDropTimes: [Double] = []
    private var clipGeneration: UInt64 = 0
    private let writerFactory: CameraSampleBufferWriterFactory
    private let outputValidator: (URL, CameraCaptureCodedDimensions, CGAffineTransform, Int) throws -> Void
#if DEBUG
    private var preservationProbeEnabled = false
    private var sourceProbe: CameraYUVProbe?
    private var requiresAudioEvidence = false
#endif

    init(queue: DispatchQueue,
         writerFactory: @escaping CameraSampleBufferWriterFactory = AVCameraSampleBufferWriter.make,
         outputValidator: @escaping (URL, CameraCaptureCodedDimensions, CGAffineTransform, Int) throws -> Void = CameraSampleBufferRecorder.validateOutput) {
        self.queue = queue
        self.writerFactory = writerFactory
        self.outputValidator = outputValidator
    }

    func begin(
        to url: URL,
        videoSettings: [String: Any],
        audioSettings: [String: Any]?,
        acceptedPixelFormats: Set<UInt32>,
        metadata: [AVMetadataItem],
        preservationProbeEnabled: Bool = false,
        requiresAudioEvidence: Bool = false,
        onStarted: @escaping @Sendable (Error?) -> Void,
        onFinished: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.move(to: .begin) else {
                onStarted(CameraSampleBufferRecorderError.alreadyActive)
                return
            }
            self.destination = url
            self.clipGeneration &+= 1
            self.recentDropTimes.removeAll()
            self.videoSettings = videoSettings
            self.audioSettings = audioSettings
            self.acceptedPixelFormats = acceptedPixelFormats
            self.metadata = metadata
            self.transform = .identity
            self.codedDimensions = nil
#if DEBUG
            self.preservationProbeEnabled = preservationProbeEnabled
            self.sourceProbe = nil
            self.requiresAudioEvidence = requiresAudioEvidence
#endif
            self.started = onStarted
            self.finished = onFinished
        }
    }

    func stop() {
        queue.async { [weak self] in self?.finishOnQueue() }
    }

    func cancel() {
        queue.async { [weak self] in self?.fail(CameraSampleBufferRecorderError.cancelled) }
    }

    func submitVideoSampleForTesting(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in self?.appendVideo(sampleBuffer) }
    }

    func submitAudioSampleForTesting(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in self?.appendAudio(sampleBuffer) }
    }

    func submitDropForTesting(at monotonicTime: Double = ProcessInfo.processInfo.systemUptime) {
        queue.async { [weak self] in self?.recordVideoDrop(at: monotonicTime) }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output is AVCaptureVideoDataOutput else { return }
        recordVideoDrop(at: ProcessInfo.processInfo.systemUptime)
    }

    private func recordVideoDrop(at now: Double) {
        guard state == .awaitingVideo || state == .recording else { return }
        recentDropTimes = CameraSampleValidationPolicy.dropTimesWithinWindow(recentDropTimes, now: now)
        if CameraSampleValidationPolicy.shouldFailForFrameDrops(recentDropCount: recentDropTimes.count) {
            fail(CameraSampleBufferRecorderError.sustainedFrameDrops(recentDropTimes.count))
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard state == .awaitingVideo || state == .recording else { return }
        if output is AVCaptureVideoDataOutput {
            appendVideo(sampleBuffer)
        } else if output is AVCaptureAudioDataOutput {
            appendAudio(sampleBuffer)
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            fail(CameraSampleBufferRecorderError.invalidVideoSample("missing image buffer"))
            return
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            fail(CameraSampleBufferRecorderError.invalidVideoSample("missing format description"))
            return
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let pixelBufferWidth = CVPixelBufferGetWidth(imageBuffer)
        let pixelBufferHeight = CVPixelBufferGetHeight(imageBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let logTransfer: CFTypeRef?
        if #available(iOS 17.2, macOS 14.2, *) {
            logTransfer = CVBufferCopyAttachment(imageBuffer, kCVImageBufferLogTransferFunctionKey, nil)
        } else {
            logTransfer = nil
        }
        let matrix = CVBufferCopyAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, nil)
        let primaries = CVBufferCopyAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, nil)
        let transfer = CVBufferCopyAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, nil)
        var validationRejections = CameraSampleValidationPolicy.rejectionReasons(
            width: Int(dimensions.width), height: Int(dimensions.height), pixelFormat: pixelFormat,
            acceptedPixelFormats: acceptedPixelFormats,
            logTransfer: logTransfer as? String, matrix: matrix as? String,
            primaries: primaries as? String, transfer: transfer as? String
        )
        if Int(dimensions.width) != pixelBufferWidth || Int(dimensions.height) != pixelBufferHeight {
            validationRejections.append("format description is \(dimensions.width)x\(dimensions.height), " +
                                        "but pixel buffer is \(pixelBufferWidth)x\(pixelBufferHeight)")
        }
#if DEBUG
        if appendedVideoFrames == 0 {
            print("HEVC Log2 source: format=\(dimensions.width)x\(dimensions.height), " +
                  "buffer=\(pixelBufferWidth)x\(pixelBufferHeight), " +
                  "pixel=\(CameraSampleValidationPolicy.fourCCDescription(pixelFormat)), " +
                  "planes=\(CVPixelBufferGetPlaneCount(imageBuffer)), " +
                  "accepted=\(CameraSampleValidationPolicy.fourCCListDescription(acceptedPixelFormats.sorted())), " +
                  "Log=\(String(describing: logTransfer)), matrix=\(String(describing: matrix)), " +
                  "primaries=\(String(describing: primaries)), transfer=\(String(describing: transfer)), " +
                  "rejections=\(validationRejections.isEmpty ? "none" : validationRejections.joined(separator: "; ")), " +
                  "pts=\(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)")
        }
#endif
        guard validationRejections.isEmpty else {
            fail(CameraSampleBufferRecorderError.invalidVideoSample(
                "\(dimensions.width)x\(dimensions.height) format description, " +
                "\(pixelBufferWidth)x\(pixelBufferHeight) pixel buffer, " +
                "pixel format \(CameraSampleValidationPolicy.fourCCDescription(pixelFormat)) " +
                "(\(CVPixelBufferGetPlaneCount(imageBuffer)) planes), " +
                "accepted formats \(CameraSampleValidationPolicy.fourCCListDescription(acceptedPixelFormats.sorted())); " +
                "Log=\(String(describing: logTransfer)), matrix=\(String(describing: matrix)), " +
                "primaries=\(String(describing: primaries)), transfer=\(String(describing: transfer)); " +
                "rejected: \(validationRejections.joined(separator: "; "))"
            ))
            return
        }
        guard let sampleDimensions = CameraCaptureCodedDimensions(
            width: Int(dimensions.width), height: Int(dimensions.height)
        ) else {
            fail(CameraSampleBufferRecorderError.invalidVideoSample("unsupported coded dimensions"))
            return
        }
        if let codedDimensions {
            guard codedDimensions == sampleDimensions else {
                fail(CameraSampleBufferRecorderError.invalidVideoSample(
                    "coded dimensions changed from \(codedDimensions.width)x\(codedDimensions.height) " +
                    "to \(sampleDimensions.width)x\(sampleDimensions.height) during the clip"
                ))
                return
            }
        } else {
            codedDimensions = sampleDimensions
            transform = sampleDimensions.portraitDeliveryTransform
            videoSettings[AVVideoWidthKey] = NSNumber(value: sampleDimensions.width)
            videoSettings[AVVideoHeightKey] = NSNumber(value: sampleDimensions.height)
        }
#if DEBUG
        var firstFrameProbe: CameraYUVProbe?
#endif

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CameraSampleValidationPolicy.timestampIsIncreasing(
            current: presentationTime.seconds, previous: lastVideoTime?.seconds
        ), presentationTime.isValid, presentationTime.isNumeric else {
            fail(CameraSampleBufferRecorderError.nonMonotonicTimestamp("video"))
            return
        }
        if state == .awaitingVideo, !startWriter(at: presentationTime) { return }
        guard let writer else { return }
        guard writer.isReady(for: .video) else {
            fail(CameraSampleBufferRecorderError.backpressure("video"))
            return
        }
        guard writer.status == .writing, writer.append(sampleBuffer, for: .video) else {
            fail(writer.error ?? CameraSampleBufferRecorderError.appendFailed("video"))
            return
        }
#if DEBUG
        if preservationProbeEnabled, appendedVideoFrames == 0 {
            do {
                firstFrameProbe = try CameraYUVProbe.sample(imageBuffer)
            } catch {
                fail(CameraSampleBufferRecorderError.invalidVideoSample("could not sample bounded smoke probe: \(error.localizedDescription)"))
                return
            }
        }
#endif
        lastVideoTime = presentationTime
        appendedVideoFrames += 1
#if DEBUG
        if sourceProbe == nil { sourceProbe = firstFrameProbe }
#endif
        if state == .awaitingVideo {
            _ = move(to: .firstVideoAppend)
            let callback = started
            started = nil
            callback?(nil)
        }
    }

    private func startWriter(at time: CMTime) -> Bool {
        guard let destination else { return false }
        do {
            let backend = try writerFactory(destination, videoSettings, audioSettings, metadata, transform)
            self.writer = backend
            guard backend.start(at: time) else {
                fail(backend.error ?? CameraSampleBufferRecorderError.writerStartFailed)
                return false
            }
            self.sessionStartTime = time
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording, let writer,
              let sessionStartTime else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid, time.isNumeric,
              CameraSampleValidationPolicy.audioIsAfterSessionStart(
                sampleTime: time.seconds, sessionStart: sessionStartTime.seconds
              ) else { return }
        guard CameraSampleValidationPolicy.timestampIsIncreasing(
            current: time.seconds, previous: lastAudioTime?.seconds
        ) else {
            fail(CameraSampleBufferRecorderError.nonMonotonicTimestamp("audio"))
            return
        }
        guard writer.isReady(for: .audio) else {
            fail(CameraSampleBufferRecorderError.backpressure("audio"))
            return
        }
        guard writer.status == .writing, writer.append(sampleBuffer, for: .audio) else {
            fail(writer.error ?? CameraSampleBufferRecorderError.appendFailed("audio"))
            return
        }
        lastAudioTime = time
        appendedAudioSamples += 1
    }

    private func finishOnQueue() {
        guard state == .awaitingVideo || state == .recording else { return }
        guard state == .recording, appendedVideoFrames > 0,
              let writer, let destination else {
            fail(CameraSampleBufferRecorderError.noVideoFrames)
            return
        }
        guard move(to: .stop) else { return }
        recentDropTimes.removeAll()
        guard writer.status == .writing else {
            fail(writer.error ?? CameraSampleBufferRecorderError.finalizationFailed)
            return
        }
        writer.markInputsAsFinished()
        let generation = clipGeneration
        let writerIdentity = ObjectIdentifier(writer)
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.state == .finishing, self.clipGeneration == generation,
                      let activeWriter = self.writer, ObjectIdentifier(activeWriter) == writerIdentity else { return }
                guard writer.status == .completed,
                      let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                      ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
                    self.complete(.failure(writer.error ?? CameraSampleBufferRecorderError.finalizationFailed))
                    return
                }
                do {
                    guard let dimensions = self.codedDimensions else {
                        throw CameraSampleBufferRecorderError.invalidFinalMovie("missing latched coded dimensions")
                    }
                    try self.outputValidator(destination, dimensions, self.transform, self.appendedAudioSamples)
                } catch {
                    self.complete(.failure(error))
                    return
                }
#if DEBUG
                if self.preservationProbeEnabled {
                    guard let source = self.sourceProbe else {
                        self.complete(.failure(CameraSampleBufferRecorderError.invalidFinalMovie("missing captured YUV smoke probe")))
                        return
                    }
                    guard let dimensions = self.codedDimensions else {
                        self.complete(.failure(CameraSampleBufferRecorderError.invalidFinalMovie(
                            "missing latched coded dimensions for preservation probe")))
                        return
                    }
                    let requiresAudio = self.requiresAudioEvidence
                    Task.detached(priority: .utility) {
                        do {
                            let evidence = try await CameraCapturePreservationProbe.inspect(
                                url: destination, source: source, expectedDimensions: dimensions,
                                requiresAudio: requiresAudio
                            )
                            self.queue.async {
                                guard self.isCurrentClip(generation, writerIdentity: writerIdentity) else { return }
                                print("HEVC Log2 smoke preservation: \(evidence)")
                                self.complete(.success(destination))
                            }
                        } catch {
                            self.queue.async {
                                guard self.isCurrentClip(generation, writerIdentity: writerIdentity) else { return }
                                self.complete(.failure(error))
                            }
                        }
                    }
                    return
                }
#endif
                self.complete(.success(destination))
            }
        }
    }

    private func fail(_ error: Error) {
        guard move(to: .failure) else { return }
        if let writer {
            if writer.status == .writing {
                writer.cancelWriting()
            }
        }
#if DEBUG
        print("Capture failed: appendedVideoFrames=\(appendedVideoFrames), " +
              "recentDrops=\(recentDropTimes.count), writerStatus=\(writer?.status.rawValue ?? -1), " +
              "writerError=\(writer?.error?.localizedDescription ?? "none"), " +
              "reason=\(error.localizedDescription)")
#endif
        complete(.failure(error))
    }

    private func complete(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            guard move(to: .finishSuccess) else { return }
        case .failure:
            if state != .failed, !move(to: .failure) { return }
        }
        let startCallback = started
        started = nil
        let callback = finished
        finished = nil
        if case .failure = result, let destination { try? FileManager.default.removeItem(at: destination) }
        clearClipState()
        if case .failure(let error) = result { startCallback?(error) }
        callback?(result)
    }

    private func move(to event: CameraSampleBufferRecorderEvent) -> Bool {
        guard let next = CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: event) else {
            return false
        }
        state = next
        return true
    }

    private func clearClipState() {
        _ = move(to: .reset)
        writer = nil
        destination = nil
        videoSettings = [:]
        audioSettings = nil
        acceptedPixelFormats = []
        metadata = []
        transform = .identity
        codedDimensions = nil
        started = nil
        finished = nil
        sessionStartTime = nil
        lastVideoTime = nil
        lastAudioTime = nil
        appendedVideoFrames = 0
        appendedAudioSamples = 0
        recentDropTimes = []
#if DEBUG
        preservationProbeEnabled = false
        sourceProbe = nil
        requiresAudioEvidence = false
#endif
    }

    private func isCurrentClip(_ generation: UInt64, writerIdentity: ObjectIdentifier) -> Bool {
        state == .finishing && clipGeneration == generation
            && writer.map(ObjectIdentifier.init) == writerIdentity
    }

    private static func validateOutput(_ url: URL, expectedDimensions: CameraCaptureCodedDimensions,
                                       transform: CGAffineTransform, appendedAudioSamples: Int) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let rawFormat = track.formatDescriptions.first else {
            throw CameraSampleBufferRecorderError.invalidFinalMovie("missing video track")
        }
        // AVAssetTrack bridges its untyped Objective-C format-description array as [Any].
        // A video track stores CMFormatDescription values; validate the bridged media type
        // immediately before reading the video-specific fields below.
        let format = rawFormat as! CMFormatDescription
        guard CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video else {
            throw CameraSampleBufferRecorderError.invalidFinalMovie("video track has a non-video format description")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard let extensions = CMFormatDescriptionGetExtensions(format) else {
            throw CameraSampleBufferRecorderError.invalidFinalMovie("missing format description extensions")
        }
        let extensionDictionary = extensions as NSDictionary
        let extensionValue = { (key: CFString) -> Any? in extensionDictionary.object(forKey: key) }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let bitDepth = (extensionValue(kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue
        let hvcC = Self.hevcConfiguration(extensionValue(kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms))
        let isMain10_420 = hvcC.map(CameraHEVCProfilePolicy.isMain10_420) == true
        let logTransfer: String?
        if #available(iOS 17.2, macOS 14.2, *) {
            logTransfer = extensionValue(kCMFormatDescriptionExtension_LogTransferFunction) as? String
        } else {
            logTransfer = nil
        }
        let matrix = extensionValue(kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        let primaries = extensionValue(kCMFormatDescriptionExtension_ColorPrimaries) as? String
        let transfer = extensionValue(kCMFormatDescriptionExtension_TransferFunction) as? String
        guard codec == 0x68766331,
              dimensions.width == expectedDimensions.width, dimensions.height == expectedDimensions.height,
              bitDepth == 10, isMain10_420,
              CameraSampleValidationPolicy.isAppleLog2(logTransfer), matrix == "ITU_R_2020",
              primaries == nil, transfer == nil,
              track.preferredTransform == transform,
              track.timeRange.duration.isValid, track.timeRange.duration.seconds > 0 else {
            let codecText = String(codec, radix: 16)
            let sizeText = "\(dimensions.width)x\(dimensions.height)"
            let bitsText = bitDepth.map(String.init) ?? "missing"
            let logText = logTransfer ?? "missing"
            let matrixText = matrix ?? "missing"
            let primariesText = primaries ?? "missing"
            let transferText = transfer ?? "missing"
            let transformText = String(describing: track.preferredTransform)
            let detail = ["codec=\(codecText)", "size=\(sizeText)", "main10_420=\(isMain10_420)",
                          "bits=\(bitsText)", "log=\(logText)", "matrix=\(matrixText)",
                          "primaries=\(primariesText)", "transfer=\(transferText)",
                          "transform=\(transformText)"].joined(separator: ", ")
            throw CameraSampleBufferRecorderError.invalidFinalMovie(detail)
        }
        let displaySize = CameraSampleValidationPolicy.displayDimensions(
            codedWidth: Int(dimensions.width), codedHeight: Int(dimensions.height), transform: track.preferredTransform
        )
        guard displaySize.0 == 2160, displaySize.1 == 3840 else {
            throw CameraSampleBufferRecorderError.invalidFinalMovie("track does not display as portrait 2160x3840")
        }
        if appendedAudioSamples > 0, asset.tracks(withMediaType: .audio).isEmpty {
            throw CameraSampleBufferRecorderError.invalidFinalMovie("audio samples were appended without an audio track")
        }
        #if DEBUG
        print("HEVC Log2 output validation: codec=hvc1, size=\(expectedDimensions.width)x\(expectedDimensions.height), bits=10, log=\(String(describing: logTransfer)), matrix=\(String(describing: matrix)), display=2160x3840, audioSamples=\(appendedAudioSamples), transform=\(track.preferredTransform)")
        #endif
    }

    private static func hevcConfiguration(_ value: Any?) -> Data? {
        if let atoms = value as? NSDictionary { return atoms.object(forKey: "hvcC") as? Data }
        if let atoms = value as? [String: Data] { return atoms["hvcC"] }
        return nil
    }

}

private final class AVCameraSampleBufferWriter: CameraSampleBufferWriting {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?

    var status: AVAssetWriter.Status { writer.status }
    var error: Error? { writer.error }

    private init(writer: AVAssetWriter, videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput?) {
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
    }

    static func make(url: URL, videoSettings: [String: Any], audioSettings: [String: Any]?,
                     metadata: [AVMetadataItem], transform: CGAffineTransform) throws -> CameraSampleBufferWriting {
        guard #available(iOS 27.0, macOS 27.0, *) else {
            throw CameraSampleBufferRecorderError.log2WriterUnavailable
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw CameraSampleBufferRecorderError.unsupportedWriterSettings("HEVC Main10 Apple Log 2")
        }
        if let audioSettings, !writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
            throw CameraSampleBufferRecorderError.unsupportedWriterSettings("AAC audio")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw CameraSampleBufferRecorderError.unsupportedWriterSettings("HEVC Main10 Apple Log 2")
        }
        let audioInput: AVAssetWriterInput?
        if let audioSettings {
            let candidate = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            candidate.expectsMediaDataInRealTime = true
            guard writer.canAdd(candidate) else {
                throw CameraSampleBufferRecorderError.unsupportedWriterSettings("AAC audio")
            }
            audioInput = candidate
        } else {
            audioInput = nil
        }
        writer.add(videoInput)
        if let audioInput { writer.add(audioInput) }
        return AVCameraSampleBufferWriter(writer: writer, videoInput: videoInput, audioInput: audioInput)
    }

    func start(at time: CMTime) -> Bool {
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: time)
        return true
    }

    func isReady(for mediaType: AVMediaType) -> Bool {
        switch mediaType {
        case .video: return videoInput.isReadyForMoreMediaData
        case .audio: return audioInput?.isReadyForMoreMediaData ?? false
        default: return false
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, for mediaType: AVMediaType) -> Bool {
        switch mediaType {
        case .video: return videoInput.append(sampleBuffer)
        case .audio: return audioInput?.append(sampleBuffer) ?? false
        default: return false
        }
    }

    func markInputsAsFinished() {
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
    }

    func finishWriting(completion: @escaping () -> Void) { writer.finishWriting(completionHandler: completion) }
    func cancelWriting() { writer.cancelWriting() }
}

enum CameraSampleBufferRecorderError: LocalizedError {
    case alreadyActive
    case log2WriterUnavailable
    case unsupportedWriterSettings(String)
    case writerStartFailed
    case invalidVideoSample(String)
    case nonMonotonicTimestamp(String)
    case appendFailed(String)
    case backpressure(String)
    case sustainedFrameDrops(Int)
    case noVideoFrames
    case cancelled
    case finalizationFailed
    case invalidFinalMovie(String)

    var errorDescription: String? {
        switch self {
        case .alreadyActive: return "A sample-buffer recording is already active."
        case .log2WriterUnavailable: return "Apple Log 2 HEVC writing requires iOS 27 or later."
        case .unsupportedWriterSettings(let detail): return "The writer rejected \(detail) settings."
        case .writerStartFailed: return "The HEVC writer could not start."
        case .invalidVideoSample(let detail): return "The camera returned an invalid Apple Log 2 frame: \(detail)."
        case .nonMonotonicTimestamp(let track): return "The \(track) capture timestamps are not increasing."
        case .appendFailed(let track): return "The \(track) sample could not be encoded."
        case .backpressure(let track): return "The \(track) writer could not keep up with capture."
        case .sustainedFrameDrops(let count): return "Capture dropped \(count) frames within two seconds."
        case .noVideoFrames: return "Recording stopped before a valid video frame was written."
        case .cancelled: return "Recording was cancelled before its first frame was written."
        case .finalizationFailed: return "The HEVC recording could not be finalized."
        case .invalidFinalMovie(let detail): return "The finalized movie failed Apple Log 2 validation: \(detail)."
        }
    }
}
