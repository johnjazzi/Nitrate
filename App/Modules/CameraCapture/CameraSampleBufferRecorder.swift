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
    /// Physical device orientation held at recording start. Drives the delivery
    /// transform; unknown/flat holds stay portrait.
    private var deliveryOrientation: CameraSampleValidationPolicy.DeliveryOrientation = .unknown
    private var captureRotationAngle: CGFloat?
    private var codedDimensions: CameraCaptureCodedDimensions?
    private var started: (@Sendable (Error?) -> Void)?
    private var finished: (@Sendable (Result<URL, Error>) -> Void)?
    private var sessionStartTime: CMTime?
    private var lastVideoTime: CMTime?
    private var lastAudioTime: CMTime?
    private var lastVideoEndTime: CMTime?
    private var lastAudioEndTime: CMTime?
    /// Stabilization can delay video even before begin (exposure settling).
    /// Retain only recent audio, never idle capture-pool video buffers.
    private var audioPreroll: [CMSampleBuffer] = []
    private var stopAudioEndTime: CMTime?
    /// Audio callbacks must not wait behind HEVC creation/preroll flushing.
    /// Limit the cross-queue handoff as well as the recorder's five-second ring.
    private let audioHandoffLock = NSLock()
    private(set) var pendingAudioHandoffs = 0
    private var audioHandoffEpoch: UInt64 = 0
    private var audioOverflowEpoch: UInt64?
    /// A source-audio or output quality problem detected while the clip is
    /// still live. Latched so the take is finished and its readable original
    /// retained instead of being cancelled and deleted.
    private var latchedQualityError: Error?
    private let scheduleDrainTimeout: (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private var appendedVideoFrames = 0
    /// Presentation time at which the recording exposure took effect; video
    /// frames older than this are dropped. Invalid means "do not filter".
    private var startAfter: CMTime = .invalid
    private var appendedAudioSamples = 0
    private var recentDropTimes: [Double] = []
    private var clipGeneration: UInt64 = 0
    private let writerFactory: CameraSampleBufferWriterFactory
    private let outputValidator: (URL, CameraCaptureCodedDimensions, CGAffineTransform, Int) throws -> Void
#if DEBUG
    private var preservationProbeEnabled = false
    private var sourceProbe: CameraYUVProbe?
    private var requiresAudioEvidence = false
    private var firstAudioTimeForDiagnostics: CMTime?
    private var audioDurationForDiagnostics: Double = 0
    private var maximumAudioGapForDiagnostics: Double = 0
#endif

    init(queue: DispatchQueue,
         writerFactory: @escaping CameraSampleBufferWriterFactory = AVCameraSampleBufferWriter.make,
         outputValidator: @escaping (URL, CameraCaptureCodedDimensions, CGAffineTransform, Int) throws -> Void = CameraSampleBufferRecorder.validateOutput,
         scheduleDrainTimeout: ((TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil) {
        self.queue = queue
        self.writerFactory = writerFactory
        self.outputValidator = outputValidator
        self.scheduleDrainTimeout = scheduleDrainTimeout ?? { delay, action in
            queue.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    func begin(
        to url: URL,
        videoSettings: [String: Any],
        audioSettings: [String: Any]?,
        acceptedPixelFormats: Set<UInt32>,
        metadata: [AVMetadataItem],
        deliveryOrientation: CameraSampleValidationPolicy.DeliveryOrientation = .unknown,
        captureRotationAngle: CGFloat? = nil,
        preservationProbeEnabled: Bool = false,
        requiresAudioEvidence: Bool = false,
        startAfter: CMTime = .invalid,
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
            self.audioHandoffLock.lock()
            self.audioHandoffEpoch = self.clipGeneration
            // Start the handoff bookkeeping clean: a new clip must not inherit
            // the previous clip's in-flight count or overflow latch. Stale
            // handoffs from the previous clip are fenced by their captured
            // epoch, so their deferred decrements are skipped, not applied.
            self.pendingAudioHandoffs = 0
            self.audioOverflowEpoch = nil
            self.audioHandoffLock.unlock()
            self.recentDropTimes.removeAll()
            self.videoSettings = videoSettings
            self.audioSettings = audioSettings
            if audioSettings == nil { self.audioPreroll.removeAll() }
            self.acceptedPixelFormats = acceptedPixelFormats
            self.metadata = metadata
            self.transform = .identity
            self.deliveryOrientation = deliveryOrientation
            self.captureRotationAngle = captureRotationAngle
            self.codedDimensions = nil
            self.startAfter = startAfter
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
        queue.async { [weak self] in
            guard let self else { return }
            self.audioPreroll.removeAll()
            self.fail(CameraSampleBufferRecorderError.cancelled)
        }
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

    /// Called on the independent, serial audio delegate queue. Copy PCM bytes
    /// before returning so neither the handoff nor preroll holds capture-pool data.
    func receiveCapturedAudio(_ sampleBuffer: CMSampleBuffer) {
        audioHandoffLock.lock()
        let generation = audioHandoffEpoch
        guard pendingAudioHandoffs < 64 else {
            let reportOverflow = audioOverflowEpoch != generation
            audioOverflowEpoch = generation
            audioHandoffLock.unlock()
            if reportOverflow {
                queue.async { [weak self] in
                    guard let self else { return }
                    defer {
                        self.audioHandoffLock.lock()
                        if self.audioOverflowEpoch == generation { self.audioOverflowEpoch = nil }
                        self.audioHandoffLock.unlock()
                    }
                    // Only a live clip can be failed by its own overflow: an
                    // error that arrives after stop must not touch the take.
                    guard self.isClipLive, self.clipGeneration == generation else { return }
                    self.fail(CameraSampleBufferRecorderError.backpressure("audio capture handoff"))
                }
            }
            return
        }
        pendingAudioHandoffs += 1
        audioHandoffLock.unlock()
        do {
            let ownedSample = try Self.copyCapturedPCM(sampleBuffer)
            queue.async { [weak self] in
                guard let self else { return }
                defer { self.releaseAudioHandoff(generation) }
                // Fence on the clip generation so a stale handoff from clip N
                // cannot land in clip N+1 and evict its valid preroll audio.
                guard self.clipGeneration == generation else { return }
                self.appendAudio(ownedSample)
            }
        } catch {
            queue.async { [weak self] in
                guard let self else { return }
                defer { self.releaseAudioHandoff(generation) }
                // A source-audio defect detected while the clip is live latches
                // and finishes the material already captured; it must never
                // cancel and delete a readable take, nor touch a later clip.
                guard self.isClipLive, self.clipGeneration == generation else { return }
                self.latchQualityErrorAndFinish(error)
            }
        }
    }

    /// The clip is still accepting source media (before stop / finalize).
    private var isClipLive: Bool { state == .awaitingVideo || state == .recording }

    /// Latch a source-quality error and finalize whatever has been captured.
    /// The finalized original is retained on disk and reported as a failure.
    private func latchQualityErrorAndFinish(_ error: Error) {
        if latchedQualityError == nil { latchedQualityError = error }
        switch state {
        case .recording: finalizeOnQueue()
        case .awaitingVideo: fail(error)
        default: break
        }
    }

    private func releaseAudioHandoff(_ generation: UInt64) {
        audioHandoffLock.lock()
        // Only the current clip's handoffs may move the shared counter. A stale
        // decrement is dropped, so the per-clip reset in begin/clearClipState
        // cannot be driven negative by the previous clip's still-queued work.
        if audioHandoffEpoch == generation { pendingAudioHandoffs -= 1 }
        audioHandoffLock.unlock()
    }

    private static func copyCapturedPCM(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let data = CMSampleBufferGetDataBuffer(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("missing PCM data or format")
        }
        // Validate timing, format and size before allocating or copying so a
        // malformed packet returns a typed error instead of trapping or
        // allocating an unbounded buffer.
        let byteCount = try validatedPCMByteCount(
            sample, description: description, availableBytes: CMBlockBufferGetDataLength(data))
        var ownedData: CMBlockBuffer?
        let copyStatus = CMBlockBufferCreateContiguous(allocator: kCFAllocatorDefault, sourceBuffer: data,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAlwaysCopyDataFlag,
            blockBufferOut: &ownedData)
        guard copyStatus == noErr, let ownedData else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("PCM copy status \(copyStatus)")
        }
        var ownedSample: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: ownedData, formatDescription: description, sampleCount: CMSampleBufferGetNumSamples(sample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), packetDescriptions: nil,
            sampleBufferOut: &ownedSample)
        guard sampleStatus == noErr, let ownedSample else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("PCM sample status \(sampleStatus)")
        }
        return ownedSample
    }

    /// Strict PCM packet gate. Rejects non-finite timing, non-positive or
    /// inconsistent packet duration, an unusable AudioStreamBasicDescription,
    /// and a byte count that would overflow or exceed the packet's data.
    /// Returns the exact packet byte length to allocate and copy.
    private static func validatedPCMByteCount(_ sample: CMSampleBuffer,
                                              description: CMFormatDescription,
                                              availableBytes: Int) throws -> Int {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        guard presentationTime.isValid, presentationTime.isNumeric,
              presentationTime.seconds.isFinite else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("non-finite presentation timestamp")
        }
        let duration = CMSampleBufferGetDuration(sample)
        guard duration.isValid, duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("missing or non-positive packet duration")
        }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("missing PCM stream description")
        }
        let sampleRate = asbd.mSampleRate
        let channels = asbd.mChannelsPerFrame
        let bytesPerFrame = asbd.mBytesPerFrame
        let framesPerPacket = asbd.mFramesPerPacket
        let bitsPerChannel = asbd.mBitsPerChannel
        guard sampleRate.isFinite, sampleRate > 0, channels > 0,
              bytesPerFrame > 0, framesPerPacket > 0, bitsPerChannel > 0 else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("unusable PCM format description")
        }
        let expectedBytesPerFrame = UInt32((bitsPerChannel + 7) / 8) * channels
        guard bytesPerFrame == expectedBytesPerFrame else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("inconsistent PCM byte geometry")
        }
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        guard sampleCount > 0 else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("empty PCM packet")
        }
        let expectedDuration = Double(sampleCount) * Double(framesPerPacket) / sampleRate
        guard abs(duration.seconds - expectedDuration) <= 1.0 / sampleRate else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("packet duration does not match sample count and rate")
        }
        let (expectedBytes, overflow) = sampleCount.multipliedReportingOverflow(by: Int(bytesPerFrame))
        guard !overflow, expectedBytes > 0 else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("unbounded PCM packet allocation")
        }
        guard availableBytes >= expectedBytes else {
            throw CameraSampleBufferRecorderError.invalidAudioSample("PCM packet is truncated")
        }
        return expectedBytes
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            receiveCapturedAudio(sampleBuffer)
        } else if output is AVCaptureVideoDataOutput {
            appendVideo(sampleBuffer)
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard state == .awaitingVideo || state == .recording else { return }
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
            let geometry = CameraSampleValidationPolicy.deliveryGeometry(
                for: deliveryOrientation, coded: sampleDimensions, captureRotationAngle: captureRotationAngle)
            transform = geometry.transform
            videoSettings[AVVideoWidthKey] = NSNumber(value: sampleDimensions.width)
            videoSettings[AVVideoHeightKey] = NSNumber(value: sampleDimensions.height)
        }
#if DEBUG
        var firstFrameProbe: CameraYUVProbe?
#endif

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Frames the sensor produced before the recording exposure actually took
        // effect still carry the previous exposure, which shows up as the first
        // frames of the clip looking exposed differently from the rest. The
        // exposure call reports when it lands, so drop anything older.
        if startAfter.isValid, startAfter.isNumeric, presentationTime < startAfter {
            return
        }
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
        lastVideoEndTime = Self.sampleEnd(sampleBuffer, fallbackDuration: CMTime(value: 1, timescale: 24))
        appendedVideoFrames += 1
#if DEBUG
        if sourceProbe == nil { sourceProbe = firstFrameProbe }
#endif
        if state == .awaitingVideo {
            _ = move(to: .firstVideoAppend)
            let preroll = audioPreroll
            audioPreroll.removeAll()
            for audio in preroll {
                appendAudio(audio)
                guard state == .recording else { return }
            }
            let callback = started
            started = nil
            callback?(nil)
        }
        if let stopAudioEndTime, let lastVideoEndTime, lastVideoEndTime >= stopAudioEndTime {
            finalizeOnQueue()
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
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid, time.isNumeric else { return }
        if state == .idle || (state == .awaitingVideo && audioSettings != nil) {
            audioPreroll.append(sampleBuffer)
            let cutoff = CMTimeSubtract(time, CMTime(value: 5, timescale: 1))
            audioPreroll.removeAll { CMSampleBufferGetPresentationTimeStamp($0) < cutoff }
            if audioPreroll.count > 512 { audioPreroll.removeFirst(audioPreroll.count - 512) }
            return
        }
        guard state == .recording, stopAudioEndTime == nil, audioSettings != nil,
              let writer, let sessionStartTime else { return }
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
        // Interior continuity: a missing or overlapping packet inside the take
        // is a source defect. Use the existing 0.12-second bound, latch, and
        // finalize the material already captured without retiming or padding.
        if let previousEnd = lastAudioEndTime {
            let delta = CMTimeSubtract(time, previousEnd).seconds
            if delta.isFinite, abs(delta) > CameraCapturePreservationProbe.synchronizationTolerance {
                latchQualityErrorAndFinish(CameraSampleBufferRecorderError.discontinuousSourceAudio(delta))
                return
            }
        }
        guard writer.isReady(for: .audio) else {
            fail(CameraSampleBufferRecorderError.backpressure("audio"))
            return
        }
        guard writer.status == .writing, writer.append(sampleBuffer, for: .audio) else {
            fail(writer.error ?? CameraSampleBufferRecorderError.appendFailed("audio"))
            return
        }
#if DEBUG
        if firstAudioTimeForDiagnostics == nil { firstAudioTimeForDiagnostics = time }
        audioDurationForDiagnostics += CMSampleBufferGetDuration(sampleBuffer).seconds
        if let previousEnd = lastAudioEndTime {
            let gap = CMTimeSubtract(time, previousEnd).seconds
            maximumAudioGapForDiagnostics = max(maximumAudioGapForDiagnostics, gap)
            if gap > 0.01 {
                print("Capture audio discontinuity: seconds=\(gap), offset=\(CMTimeSubtract(time, sessionStartTime).seconds)")
            }
        }
#endif
        lastAudioTime = time
        lastAudioEndTime = Self.sampleEnd(sampleBuffer, fallbackDuration: .zero)
        appendedAudioSamples += 1
    }

    /// CMSampleBufferGetDuration already returns the entire PCM packet duration.
    private static func sampleEnd(_ sample: CMSampleBuffer, fallbackDuration: CMTime) -> CMTime {
        let duration = CMSampleBufferGetDuration(sample)
        let validDuration = duration.isValid && duration.isNumeric && duration > .zero
        return CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), validDuration ? duration : fallbackDuration)
    }

    private func finishOnQueue() {
        guard state == .awaitingVideo || state == .recording, stopAudioEndTime == nil else { return }
        guard state == .recording else {
            fail(CameraSampleBufferRecorderError.noVideoFrames)
            return
        }
        guard let audioEnd = lastAudioEndTime, let videoEnd = lastVideoEndTime, videoEnd < audioEnd else {
            finalizeOnQueue()
            return
        }
        // Freeze the accepted audio endpoint once. Continue only source video;
        // retiming audio or padding silence would hide, not fix, missing content.
        stopAudioEndTime = audioEnd
        recentDropTimes.removeAll()
        let generation = clipGeneration
        guard let writer else { return }
        let writerIdentity = ObjectIdentifier(writer)
        scheduleDrainTimeout(5) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.state == .recording, self.stopAudioEndTime != nil,
                      self.clipGeneration == generation,
                      self.writer.map(ObjectIdentifier.init) == writerIdentity else { return }
                // A latched source-audio defect finalizes the material already
                // captured and retains it; otherwise the drain timeout keeps
                // its existing cancel-and-delete behaviour for an unfinalized take.
                if self.latchedQualityError != nil {
                    self.finalizeOnQueue()
                } else {
                    self.fail(CameraSampleBufferRecorderError.stopDrainTimedOut)
                }
            }
        }
    }

    private func finalizeOnQueue() {
        guard state == .recording, appendedVideoFrames > 0,
              let writer, let destination else {
            fail(CameraSampleBufferRecorderError.noVideoFrames)
            return
        }
#if DEBUG
        print("Capture source timing: origin=\(sessionStartTime?.seconds ?? -1), " +
              "videoPTS=\(lastVideoTime?.seconds ?? -1), videoEnd=\(lastVideoEndTime?.seconds ?? -1), " +
              "audioPTS=\(lastAudioTime?.seconds ?? -1), audioEnd=\(lastAudioEndTime?.seconds ?? -1), " +
              "target=\(stopAudioEndTime?.seconds ?? -1), frames=\(appendedVideoFrames), " +
              "audio-first=\(firstAudioTimeForDiagnostics?.seconds ?? -1), audioDuration=\(audioDurationForDiagnostics), " +
              "maxAudioGap=\(maximumAudioGapForDiagnostics), audioPackets=\(appendedAudioSamples)")
#endif
        guard move(to: .stop) else { return }
        recentDropTimes.removeAll()
        guard writer.status == .writing else {
            fail(writer.error ?? CameraSampleBufferRecorderError.finalizationFailed)
            return
        }
        writer.markInputsAsFinished()
        let generation = clipGeneration
        let writerIdentity = ObjectIdentifier(writer)
        // Bounded finishWriting timeout, fenced on this clip generation and
        // writer identity so a stale deadline can never touch a later take.
        scheduleDrainTimeout(5) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.state == .finishing, self.clipGeneration == generation,
                      let activeWriter = self.writer,
                      ObjectIdentifier(activeWriter) == writerIdentity else { return }
                // A writer that already produced a readable file is retained;
                // one that never reached completed status is unplayable.
                if activeWriter.status == .completed,
                   let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                   ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 {
                    self.complete(.failure(CameraRetainedRecordingError(
                        originalURL: destination,
                        reason: CameraSampleBufferRecorderError.finishWritingTimedOut)))
                } else {
                    self.fail(CameraSampleBufferRecorderError.finishWritingTimedOut)
                }
            }
        }
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
                    // The original finalized readably; a validation failure
                    // must retain it rather than delete the take.
                    self.complete(.failure(CameraRetainedRecordingError(originalURL: destination, reason: error)))
                    return
                }
                // A source-audio defect latched while recording is reported
                // against the readable, retained original.
                if let latched = self.latchedQualityError {
                    self.complete(.failure(CameraRetainedRecordingError(originalURL: destination, reason: latched)))
                    return
                }
#if DEBUG
                // A configured microphone that produced no audio is not a clean
                // success, but the video-only original is still retained.
                if self.requiresAudioEvidence, self.audioSettings != nil, self.appendedAudioSamples == 0 {
                    self.complete(.failure(CameraRetainedRecordingError(
                        originalURL: destination,
                        reason: CameraSampleBufferRecorderError.configuredMicrophoneProducedNoAudio)))
                    return
                }
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
                    let deliveryTransform = self.transform
                    Task.detached(priority: .utility) {
                        do {
                            let evidence = try await CameraCapturePreservationProbe.inspect(
                                url: destination, source: source, expectedDimensions: dimensions,
                                expectedTransform: deliveryTransform, requiresAudio: requiresAudio
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
        // Delete only a failure that carries no retained original. A readable
        // finalized file wrapped in a CameraRetainedRecordingError stays.
        if case .failure(let error) = result,
           CameraRetainedRecordingError.retainedURL(from: error) == nil,
           let destination {
            try? FileManager.default.removeItem(at: destination)
        }
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
        deliveryOrientation = .unknown
        captureRotationAngle = nil
        codedDimensions = nil
        started = nil
        finished = nil
        sessionStartTime = nil
        lastVideoTime = nil
        lastAudioTime = nil
        lastVideoEndTime = nil
        lastAudioEndTime = nil
        stopAudioEndTime = nil
        audioPreroll.removeAll()
        // Handoff bookkeeping is per-clip: reset the in-flight count, epoch and
        // overflow latch so the next take starts clean. releaseAudioHandoff is
        // epoch-fenced, so a previous clip's late decrement cannot go negative.
        audioHandoffLock.lock()
        pendingAudioHandoffs = 0
        audioHandoffEpoch = 0
        audioOverflowEpoch = nil
        audioHandoffLock.unlock()
        latchedQualityError = nil
        appendedVideoFrames = 0
        appendedAudioSamples = 0
        recentDropTimes = []
#if DEBUG
        preservationProbeEnabled = false
        sourceProbe = nil
        requiresAudioEvidence = false
        firstAudioTimeForDiagnostics = nil
        audioDurationForDiagnostics = 0
        maximumAudioGapForDiagnostics = 0
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
        let expectedDisplay = CameraSampleValidationPolicy.displayDimensions(
            codedWidth: Int(dimensions.width), codedHeight: Int(dimensions.height), transform: transform
        )
        let displaySize = CameraSampleValidationPolicy.displayDimensions(
            codedWidth: Int(dimensions.width), codedHeight: Int(dimensions.height), transform: track.preferredTransform
        )
        guard displaySize.0 == expectedDisplay.0, displaySize.1 == expectedDisplay.1 else {
            throw CameraSampleBufferRecorderError.invalidFinalMovie(
                "track displays as \(displaySize.0)x\(displaySize.1), " +
                "expected \(expectedDisplay.0)x\(expectedDisplay.1) for the chosen delivery orientation")
        }
        if appendedAudioSamples > 0 {
            guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
                throw CameraSampleBufferRecorderError.invalidFinalMovie("audio samples were appended without an audio track")
            }
            let skew = CameraCapturePreservationProbe.audioStartSkew(
                firstAudioPTS: audioTrack.timeRange.start, firstVideoPTS: track.timeRange.start,
                segments: audioTrack.segments)
            let endDifference = abs(CMTimeSubtract(CMTimeRangeGetEnd(track.timeRange),
                                                   CMTimeRangeGetEnd(audioTrack.timeRange)).seconds)
            do {
                try CameraCapturePreservationProbe.validateSynchronization(skew: skew, endDifference: endDifference)
            } catch {
                throw CameraSampleBufferRecorderError.invalidFinalMovie(error.localizedDescription)
            }
        }
        #if DEBUG
        print("HEVC Log2 output validation: codec=hvc1, size=\(expectedDimensions.width)x\(expectedDimensions.height), bits=10, log=\(String(describing: logTransfer)), matrix=\(String(describing: matrix)), display=\(expectedDisplay.0)x\(expectedDisplay.1), audioSamples=\(appendedAudioSamples), transform=\(track.preferredTransform)")
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
    case invalidAudioSample(String)
    case nonMonotonicTimestamp(String)
    case appendFailed(String)
    case backpressure(String)
    case sustainedFrameDrops(Int)
    case noVideoFrames
    case cancelled
    case stopDrainTimedOut
    case finishWritingTimedOut
    case configuredMicrophoneProducedNoAudio
    case discontinuousSourceAudio(Double)
    case finalizationFailed
    case invalidFinalMovie(String)

    var errorDescription: String? {
        switch self {
        case .alreadyActive: return "A sample-buffer recording is already active."
        case .log2WriterUnavailable: return "Apple Log 2 HEVC writing requires iOS 27 or later."
        case .unsupportedWriterSettings(let detail): return "The writer rejected \(detail) settings."
        case .writerStartFailed: return "The HEVC writer could not start."
        case .invalidVideoSample(let detail): return "The camera returned an invalid Apple Log 2 frame: \(detail)."
        case .invalidAudioSample(let detail): return "The camera returned invalid PCM audio: \(detail)."
        case .nonMonotonicTimestamp(let track): return "The \(track) capture timestamps are not increasing."
        case .appendFailed(let track): return "The \(track) sample could not be encoded."
        case .backpressure(let track): return "The \(track) writer could not keep up with capture."
        case .sustainedFrameDrops(let count): return "Capture dropped \(count) frames within two seconds."
        case .noVideoFrames: return "Recording stopped before a valid video frame was written."
        case .cancelled: return "Recording was cancelled before its first frame was written."
        case .stopDrainTimedOut: return "Recording timed out waiting for delayed video to reach the audio endpoint."
        case .finishWritingTimedOut: return "Recording timed out while finalizing; the take was not reported."
        case .configuredMicrophoneProducedNoAudio: return "The configured microphone delivered no audio for this take."
        case .discontinuousSourceAudio(let seconds):
            return "Capture audio has a \(String(format: "%.3f", seconds))-second discontinuity inside the take."
        case .finalizationFailed: return "The HEVC recording could not be finalized."
        case .invalidFinalMovie(let detail): return "The finalized movie failed Apple Log 2 validation: \(detail)."
        }
    }
}
