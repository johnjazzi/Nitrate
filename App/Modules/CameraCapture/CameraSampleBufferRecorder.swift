import AVFoundation
import CoreMedia

protocol CameraSampleBufferWriting: AnyObject {
    var status: AVAssetWriter.Status { get }
    var error: Error? { get }
    func start(at time: CMTime) -> Bool
    func isReady(for mediaType: AVMediaType) -> Bool
    func append(_ sampleBuffer: CMSampleBuffer, for mediaType: AVMediaType) -> Bool
    func markInputsAsFinished()
    func finishWriting(completion: @escaping @Sendable () -> Void)
    func cancelWriting()
    /// Why the most recent append was refused, when the writer can tell a
    /// backpressure refusal apart from an encode failure. The real-time
    /// receiver used by the production writer refuses a sample rather than
    /// reporting readiness, so the recorder asks after a refused append.
    var lastAppendRefusal: Error? { get }
}

extension CameraSampleBufferWriting {
    /// Writers that report readiness before the append have nothing to add.
    var lastAppendRefusal: Error? { nil }
}

typealias CameraSampleBufferWriterFactory = (
    _ url: URL, _ videoSettings: [String: Any], _ audioSettings: [String: Any]?, _ metadata: [AVMetadataItem],
    _ transform: CGAffineTransform
) throws -> CameraSampleBufferWriting
typealias CameraCaptureCodedDimensions = CameraSampleValidationPolicy.CodedDimensions

/// Output settings and metadata handed from the caller to the recorder's serial
/// queue. `[String: Any]` and `[AVMetadataItem]` cannot conform to `Sendable`
/// (the marker protocol cannot be used in a conditional cast either, so the
/// values cannot be re-typed at the boundary). This is a one-way hand-off
/// rather than a share, which is what makes the transfer safe: the dictionary
/// is a copy-on-write value whose snapshot the recorder takes on the caller's
/// thread, the caller only ever rebinds its own variables afterwards, and the
/// metadata items are built fresh for this take, handed to the writer as-is and
/// never mutated again. Nothing writes to either after the transfer.
private struct CameraRecorderStartSnapshot: @unchecked Sendable {
    let videoSettings: [String: Any]
    let audioSettings: [String: Any]?
    let metadata: [AVMetadataItem]
}

/// A capture sample in transit.
///
/// `CMSampleBuffer` is a non-`Sendable` class reference, so neither a queue
/// hand-off nor `CMReadySampleBuffer.init(unsafeBuffer:)` accepts one directly:
/// the initializer takes a `sending` buffer, and the compiler cannot prove that
/// a buffer arriving from an AVFoundation callback or from the writer's append
/// is unreferenced elsewhere. This box states the hand-off the recorder
/// performs — the producing side stops using the buffer once it is boxed (the
/// audio path copies the PCM into the recorder's own block buffer first,
/// precisely so the hand-off never holds capture-pool memory), and one consumer
/// at a time reads it. The buffer itself is immutable; only the reference moves.
private struct TransferredSampleBuffer: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
}

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
    /// Production: true when the microphone was actually configured for this
    /// take, so a zero-audio result must be reported as a failure rather than a
    /// clean success. Not debug-only — a Release build that configured a
    /// microphone owes the user the same audio-integrity evidence.
    private var requiresAudioEvidence = false
#if DEBUG
    private var preservationProbeEnabled = false
    private var sourceProbe: CameraYUVProbe?
    private var firstAudioTimeForDiagnostics: CMTime?
    private var audioDurationForDiagnostics: Double = 0
    private var maximumAudioGapForDiagnostics: Double = 0
#endif

    init(queue: DispatchQueue,
         writerFactory: @escaping CameraSampleBufferWriterFactory = CameraSampleBufferRecorder.defaultWriterFactory,
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
        let snapshot = CameraRecorderStartSnapshot(videoSettings: videoSettings,
                                                   audioSettings: audioSettings, metadata: metadata)
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
            self.videoSettings = snapshot.videoSettings
            self.audioSettings = snapshot.audioSettings
            if snapshot.audioSettings == nil { self.audioPreroll.removeAll() }
            self.acceptedPixelFormats = acceptedPixelFormats
            self.metadata = snapshot.metadata
            self.transform = .identity
            self.deliveryOrientation = deliveryOrientation
            self.captureRotationAngle = captureRotationAngle
            self.codedDimensions = nil
            self.startAfter = startAfter
            self.requiresAudioEvidence = requiresAudioEvidence
#if DEBUG
            self.preservationProbeEnabled = preservationProbeEnabled
            self.sourceProbe = nil
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
        let transferred = TransferredSampleBuffer(sampleBuffer: sampleBuffer)
        queue.async { [weak self] in self?.appendVideo(transferred.sampleBuffer) }
    }

    func submitAudioSampleForTesting(_ sampleBuffer: CMSampleBuffer) {
        let transferred = TransferredSampleBuffer(sampleBuffer: sampleBuffer)
        queue.async { [weak self] in self?.appendAudio(transferred.sampleBuffer) }
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
        // Once stop has been requested the take is finalising rather than running:
        // its frames are already in the writer, so a drop burst here must not abort
        // and discard a recording the user has finished. The drain timeout still
        // bounds a tail that never arrives.
        guard state == .awaitingVideo || state == .recording, stopAudioEndTime == nil else { return }
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
            // The copy is the recorder's own buffer, never capture-pool data,
            // and this hand-off is the only remaining reference to it.
            let ownedSample = TransferredSampleBuffer(sampleBuffer: try Self.copyCapturedPCM(sampleBuffer))
            queue.async { [weak self] in
                guard let self else { return }
                defer { self.releaseAudioHandoff(generation) }
                // Fence on the clip generation so a stale handoff from clip N
                // cannot land in clip N+1 and evict its valid preroll audio.
                guard self.clipGeneration == generation else { return }
                self.appendAudio(ownedSample.sampleBuffer)
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
            fail(writer.error ?? writer.lastAppendRefusal
                 ?? CameraSampleBufferRecorderError.appendFailed("video"))
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
            fail(writer.error ?? writer.lastAppendRefusal
                 ?? CameraSampleBufferRecorderError.appendFailed("audio"))
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
                guard activeWriter.status == .completed,
                      let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                      ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
                    self.complete(.failure(activeWriter.error ?? CameraSampleBufferRecorderError.finalizationFailed))
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
                // A configured microphone that produced no audio is not a clean
                // success, but the video-only original is still retained. This is
                // production behaviour, not a debug-only guard: a Release build
                // that configured a microphone must not hand a silent take back
                // as a clean success.
                if CameraAudioEvidencePolicy.missingConfiguredAudio(
                    requiresAudioEvidence: self.requiresAudioEvidence,
                    hasAudioSettings: self.audioSettings != nil,
                    appendedAudioSamples: self.appendedAudioSamples) {
                    self.complete(.failure(CameraRetainedRecordingError(
                        originalURL: destination,
                        reason: CameraSampleBufferRecorderError.configuredMicrophoneProducedNoAudio)))
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
        requiresAudioEvidence = false
#if DEBUG
        preservationProbeEnabled = false
        sourceProbe = nil
        firstAudioTimeForDiagnostics = nil
        audioDurationForDiagnostics = 0
        maximumAudioGapForDiagnostics = 0
#endif
    }

    private func isCurrentClip(_ generation: UInt64, writerIdentity: ObjectIdentifier) -> Bool {
        state == .finishing && clipGeneration == generation
            && writer.map(ObjectIdentifier.init) == writerIdentity
    }

    /// AVAsset's value accessors are asynchronous, and finalization is
    /// synchronous on the serial capture queue whose ordering the completion
    /// callbacks and error propagation depend on. The loads are therefore driven
    /// to completion here instead of re-ordering the finalization path around a
    /// task hop.
    private static func validateOutput(_ url: URL, expectedDimensions: CameraCaptureCodedDimensions,
                                       transform: CGAffineTransform, appendedAudioSamples: Int) throws {
        let outcome = CameraSampleValidationOutcome()
        let finished = DispatchSemaphore(value: 0)
        Task {
            do {
                try await validateLoadedOutput(url, expectedDimensions: expectedDimensions,
                                               transform: transform,
                                               appendedAudioSamples: appendedAudioSamples)
                outcome.succeed()
            } catch {
                outcome.fail(error)
            }
            finished.signal()
        }
        finished.wait()
        try outcome.result.get()
    }

    /// The validation itself, reading the finalized file through the
    /// asynchronous accessors. A load failure is mapped to the value the
    /// synchronous accessor used to return for the same condition, so a guard
    /// below still reports the same error it reported before.
    private static func validateLoadedOutput(_ url: URL, expectedDimensions: CameraCaptureCodedDimensions,
                                             transform: CGAffineTransform,
                                             appendedAudioSamples: Int) async throws {
        let asset = AVURLAsset(url: url)
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard let track = videoTracks.first else {
            throw CameraSampleBufferRecorderError.invalidFinalMovie("missing video track")
        }
        let videoFormats = (try? await track.load(.formatDescriptions)) ?? []
        guard let rawFormat = videoFormats.first else {
            throw CameraSampleBufferRecorderError.invalidFinalMovie("missing video track")
        }
        // The asynchronous accessor vends typed format descriptions; the media
        // type is still validated before the video-specific fields are read.
        let format = rawFormat
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
        // Loaded once: the finalized asset is immutable, so this is the same
        // value the property read used to return at every use below.
        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        let timeRange = (try? await track.load(.timeRange)) ?? .invalid
        guard codec == 0x68766331,
              dimensions.width == expectedDimensions.width, dimensions.height == expectedDimensions.height,
              bitDepth == 10, isMain10_420,
              CameraSampleValidationPolicy.isAppleLog2(logTransfer), matrix == "ITU_R_2020",
              primaries == nil, transfer == nil,
              preferredTransform == transform,
              timeRange.duration.isValid, timeRange.duration.seconds > 0 else {
            let codecText = String(codec, radix: 16)
            let sizeText = "\(dimensions.width)x\(dimensions.height)"
            let bitsText = bitDepth.map(String.init) ?? "missing"
            let logText = logTransfer ?? "missing"
            let matrixText = matrix ?? "missing"
            let primariesText = primaries ?? "missing"
            let transferText = transfer ?? "missing"
            let transformText = String(describing: preferredTransform)
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
            codedWidth: Int(dimensions.width), codedHeight: Int(dimensions.height), transform: preferredTransform
        )
        guard displaySize.0 == expectedDisplay.0, displaySize.1 == expectedDisplay.1 else {
            throw CameraSampleBufferRecorderError.invalidFinalMovie(
                "track displays as \(displaySize.0)x\(displaySize.1), " +
                "expected \(expectedDisplay.0)x\(expectedDisplay.1) for the chosen delivery orientation")
        }
        if appendedAudioSamples > 0 {
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            guard let audioTrack = audioTracks.first else {
                throw CameraSampleBufferRecorderError.invalidFinalMovie("audio samples were appended without an audio track")
            }
            let audioTimeRange = (try? await audioTrack.load(.timeRange)) ?? .invalid
            let audioSegments = (try? await audioTrack.load(.segments)) ?? []
            let skew = CameraCapturePreservationProbe.audioStartSkew(
                firstAudioPTS: audioTimeRange.start, firstVideoPTS: timeRange.start,
                segments: audioSegments)
            let endDifference = abs(CMTimeSubtract(CMTimeRangeGetEnd(timeRange),
                                                   CMTimeRangeGetEnd(audioTimeRange)).seconds)
            do {
                try CameraCapturePreservationProbe.validateSynchronization(skew: skew, endDifference: endDifference)
            } catch {
                throw CameraSampleBufferRecorderError.invalidFinalMovie(error.localizedDescription)
            }
        }
        #if DEBUG
        print("HEVC Log2 output validation: codec=hvc1, size=\(expectedDimensions.width)x\(expectedDimensions.height), bits=10, log=\(String(describing: logTransfer)), matrix=\(String(describing: matrix)), display=\(expectedDisplay.0)x\(expectedDisplay.1), audioSamples=\(appendedAudioSamples), transform=\(preferredTransform)")
        #endif
    }

    private static func hevcConfiguration(_ value: Any?) -> Data? {
        if let atoms = value as? NSDictionary { return atoms.object(forKey: "hvcC") as? Data }
        if let atoms = value as? [String: Data] { return atoms["hvcC"] }
        return nil
    }

    /// The production writer needs the receiver API added in iOS/macOS 26, and
    /// `make` itself still reports `log2WriterUnavailable` below iOS/macOS 27.
    /// The default argument has to type-check on every supported deployment
    /// target, so this wrapper keeps the reference reachable everywhere and
    /// preserves that same failure on systems where the writer is unavailable.
    private static func defaultWriterFactory(url: URL, videoSettings: [String: Any],
                                             audioSettings: [String: Any]?,
                                             metadata: [AVMetadataItem],
                                             transform: CGAffineTransform) throws -> CameraSampleBufferWriting {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw CameraSampleBufferRecorderError.log2WriterUnavailable
        }
        return try AVCameraSampleBufferWriter.make(url: url, videoSettings: videoSettings,
                                                   audioSettings: audioSettings, metadata: metadata,
                                                   transform: transform)
    }

}

/// Carries the asynchronous validation's outcome back to the synchronous
/// finalization path. The single stored result is guarded by one lock, so the
/// task that performs the loads and the queue that waits for it never touch it
/// concurrently.
private final class CameraSampleValidationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Void, Error> = .success(())

    var result: Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func succeed() {
        lock.lock()
        stored = .success(())
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        stored = .failure(error)
        lock.unlock()
    }
}

/// The production writer. The `AVAssetWriter` receiver API and the
/// `CMReadySampleBuffer` payload it appends are available from iOS 26/macOS 26,
/// so the type is declared for those systems and is only ever constructed by
/// `CameraSampleBufferRecorder.defaultWriterFactory`, which can report the same
/// `log2WriterUnavailable` failure older systems already got from `make`.
@available(iOS 26.0, macOS 26.0, *)
private final class AVCameraSampleBufferWriter: CameraSampleBufferWriting {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let videoReceiver: AVAssetWriterInput.SampleBufferReceiver
    private let audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
    /// Set when a real-time receiver refuses a sample it cannot take right now,
    /// which is the condition the input's readiness query used to report before
    /// the append was attempted.
    private var refusedAppend: Error?

    var status: AVAssetWriter.Status { writer.status }
    var error: Error? { writer.error }
    var lastAppendRefusal: Error? { refusedAppend }

    private init(writer: AVAssetWriter, videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput?,
                 videoReceiver: AVAssetWriterInput.SampleBufferReceiver,
                 audioReceiver: AVAssetWriterInput.SampleBufferReceiver?) {
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.videoReceiver = videoReceiver
        self.audioReceiver = audioReceiver
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
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw CameraSampleBufferRecorderError.unsupportedWriterSettings("HEVC Main10 Apple Log 2")
        }
        let audioInput: AVAssetWriterInput?
        if let audioSettings {
            let candidate = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            guard writer.canAdd(candidate) else {
                throw CameraSampleBufferRecorderError.unsupportedWriterSettings("AAC audio")
            }
            audioInput = candidate
        } else {
            audioInput = nil
        }
        // `inputReceiver(for:)` replaces `add(_:)`: it attaches the input to the
        // writer and returns the real-time receiver for it in one step.
        let videoReceiver = writer.inputReceiver(for: videoInput)
        let audioReceiver = audioInput.map { writer.inputReceiver(for: $0) }
        return AVCameraSampleBufferWriter(writer: writer, videoInput: videoInput, audioInput: audioInput,
                                          videoReceiver: videoReceiver, audioReceiver: audioReceiver)
    }

    func start(at time: CMTime) -> Bool {
        do {
            try writer.start()
        } catch {
            // `error` still reports the underlying failure, exactly as the
            // boolean start result did.
            return false
        }
        writer.startSession(atSourceTime: time)
        return true
    }

    /// A real-time receiver has no readiness query: `appendImmediately` is the
    /// gate and refuses a sample it cannot take, which is recorded as
    /// `lastAppendRefusal`. Reporting ready therefore defers the decision to the
    /// append instead of pre-empting it, while still reporting "no audio input"
    /// for a video-only take.
    func isReady(for mediaType: AVMediaType) -> Bool {
        switch mediaType {
        case .video: return true
        case .audio: return audioReceiver != nil
        default: return false
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, for mediaType: AVMediaType) -> Bool {
        switch mediaType {
        case .video:
            return appendImmediately(sampleBuffer, to: videoReceiver, labelled: "video")
        case .audio:
            guard let audioReceiver else { return false }
            return appendImmediately(sampleBuffer, to: audioReceiver, labelled: "audio")
        default:
            return false
        }
    }

    /// Appends synchronously, the real-time path: a refusal is remembered so the
    /// recorder can still attribute it to backpressure rather than to an encode
    /// failure.
    private func appendImmediately(_ sampleBuffer: CMSampleBuffer,
                                   to receiver: AVAssetWriterInput.SampleBufferReceiver,
                                   labelled label: String) -> Bool {
        // The receiver consumes the sample as a ready buffer, the transferable
        // form of the same sample. `TransferredSampleBuffer` states the hand-off
        // for a buffer the compiler cannot see as unreferenced here.
        let ready = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(
            unsafeBuffer: TransferredSampleBuffer(sampleBuffer: sampleBuffer).sampleBuffer)
        guard (try? receiver.appendImmediately(ready)) == true else {
            refusedAppend = CameraSampleBufferRecorderError.backpressure(label)
            return false
        }
        return true
    }

    func markInputsAsFinished() {
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
    }

    func finishWriting(completion: @escaping @Sendable () -> Void) {
        writer.finishWriting(completionHandler: completion)
    }
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

// MARK: - Prelaunch camera state policies
//
// Pure decision seams for the prelaunch camera fixes (L02, L09, L10, L11). They
// live here — rather than inline in the session/view model — so the contracts can
// be exercised by the RenderCLI test target without constructing an
// AVCaptureSession or a running camera.

/// Production (not debug-only) audio-evidence contract for a finished take.
///
/// A take whose microphone was configured but which appended zero audio packets
/// is not a clean success: the readable video-only original is still retained,
/// but the take is reported as a failure. A deliberately video-only take (no
/// audio settings at all) stays a success.
enum CameraAudioEvidencePolicy {
    static func missingConfiguredAudio(requiresAudioEvidence: Bool,
                                       hasAudioSettings: Bool,
                                       appendedAudioSamples: Int) -> Bool {
        requiresAudioEvidence && hasAudioSettings && appendedAudioSamples == 0
    }
}

/// Audio is only reported as configured when its data output actually attaches
/// to the session.
///
/// Attaching the microphone input without the audio output would let the
/// recorder demand audio evidence for a take that can never deliver PCM,
/// turning a healthy video-only capture into a false "configured microphone
/// produced no audio" failure. When the output cannot attach, the input is
/// rolled back so the session is left cleanly video-only.
enum CameraMicrophoneAttachmentPolicy {
    enum Plan: Equatable, Sendable {
        /// Keep the input and attach the output; audio is configured.
        case configureAudio
        /// Roll the input back and leave audio unconfigured.
        case rollbackInput
    }

    static func plan(audioOutputCanAttach: Bool) -> Plan {
        audioOutputCanAttach ? .configureAudio : .rollbackInput
    }
}

/// Manual-focus hardware/UI reconciliation (L09).
enum CameraManualFocusPolicy {
    /// A preview tap may switch the device to autofocus only when no manual
    /// focus is committed; otherwise the MF selection would stay lit while the
    /// lens silently auto-focused.
    static func allowsAutofocusOnTap(committedLensPosition: Float?) -> Bool {
        committedLensPosition == nil
    }

    /// After a committed lens switch, reapply the locked focus to the new device
    /// when it supports custom lens positions; otherwise drop it so the readback
    /// can reset the UI to autofocus.
    static func lensPositionAfterLensChange(committed: Float?,
                                            newDeviceSupportsLock: Bool) -> Float? {
        guard let committed, newDeviceSupportsLock else { return nil }
        return min(max(committed, 0), 1)
    }
}

/// Manual ISO may not move ahead of the hardware while the session refuses
/// exposure changes during a recording transition (L10).
enum CameraManualExposureSelectionPolicy {
    static func canChangeISO(isStartingRecording: Bool, isRecording: Bool,
                             isStoppingRecording: Bool) -> Bool {
        !isStartingRecording && !isRecording && !isStoppingRecording
    }

    static func reconciledISO(previous: Float, requested: Float, accepted: Bool) -> Float {
        accepted ? requested : previous
    }
}

/// Fences an async per-take result (the recorded-duration check) against a later
/// take that began while it was suspended (L11).
enum CameraRecordingTakeFence {
    struct Snapshot: Equatable, Sendable {
        let generation: UInt64
        let origin: Date
        let stoppedAt: Date?
    }

    /// Snapshot and clear the finishing take's shared timer state before an
    /// await, so a later take cannot lose its own timer origin when the old load
    /// resolves. Returns nil when the take never set an origin.
    static func snapshotAndClear(origin: inout Date?, stoppedAt: inout Date?,
                                 generation: UInt64) -> Snapshot? {
        guard let currentOrigin = origin else { return nil }
        let snapshot = Snapshot(generation: generation, origin: currentOrigin, stoppedAt: stoppedAt)
        origin = nil
        stoppedAt = nil
        return snapshot
    }

    /// A verdict may only touch shared state while the same take still owns the
    /// capture generation and no newer take is starting or running.
    static func accepts(snapshot: Snapshot, currentGeneration: UInt64,
                        isRecording: Bool, isStartingRecording: Bool) -> Bool {
        snapshot.generation == currentGeneration && !isRecording && !isStartingRecording
    }
}

/// Manual-focus hardware state for the view. `lensPosition` is the committed
/// locked position (nil = autofocus); `isSupported` reflects the active device.
/// The revision lets the UI discard snapshots queued before a lens change.
struct CameraManualFocusSnapshot: Sendable, Equatable {
    let lensPosition: Float?
    let isSupported: Bool
    let cameraRevision: UInt64
}
