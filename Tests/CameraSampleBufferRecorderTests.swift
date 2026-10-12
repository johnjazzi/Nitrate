import AVFoundation
import CoreVideo
import Testing

@Suite("Sample-buffer recorder lifecycle")
struct CameraSampleBufferRecorderTests {
    @Test func stopBeforeVideoCompletesBothCallbacksAndAllowsAnotherClip() async throws {
        let recorder = CameraSampleBufferRecorder(queue: DispatchQueue(label: "test.sample-buffer-recorder"))
        let events = RecorderEventQueue()

        let firstURL = try begin(recorder, events: events)
        recorder.stop()
        recorder.stop()
        #expect(await events.nextStarted()?.contains("stopped before a valid video frame") == true)
        #expect(await events.nextFinished()?.contains("stopped before a valid video frame") == true)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))

        let secondURL = try begin(recorder, events: events)
        recorder.stop()
        #expect(await events.nextStarted()?.contains("stopped before a valid video frame") == true)
        #expect(await events.nextFinished()?.contains("stopped before a valid video frame") == true)
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func injectedWriterStartAppendAndReadinessFailuresCleanupExactlyOnce() async throws {
        for behavior in [FakeWriterBehavior(startSucceeds: false),
                         FakeWriterBehavior(appendSucceeds: false),
                         FakeWriterBehavior(videoReady: false)] {
            let rig = makeRig(behavior)
            let url = try begin(rig.recorder, events: rig.events)
            rig.recorder.submitVideoSampleForTesting(try Self.log2Sample())
            #expect(await rig.events.nextStarted() != nil)
            #expect(await rig.events.nextFinished() != nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(rig.events.startedCount == 1)
            #expect(rig.events.finishedCount == 1)
        }
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func injectedSettingRejectionReportsStartAndTerminalFailure() async throws {
        let events = RecorderEventQueue()
        let queue = DispatchQueue(label: "test.writer-settings")
        let recorder = CameraSampleBufferRecorder(queue: queue, writerFactory: { _, _, _, _, _ in
            throw CameraSampleBufferRecorderError.unsupportedWriterSettings("test Main10")
        }, outputValidator: { _, _, _ in })
        let url = try begin(recorder, events: events)
        recorder.submitVideoSampleForTesting(try Self.log2Sample())
        #expect(await events.nextStarted()?.contains("writer rejected") == true)
        #expect(await events.nextFinished()?.contains("writer rejected") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func delayedOldFinalizationCannotCompleteOrDeleteReusedRecorderClip() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let firstURL = try begin(rig.recorder, events: rig.events)
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 1))
        #expect(await rig.events.nextStarted() == nil)
        let oldWriter = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.waitForFinishToBeRequested(on: oldWriter)
        rig.recorder.cancel()
        #expect(await rig.events.nextFinished() != nil)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))

        let secondURL = try begin(rig.recorder, events: rig.events)
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 2))
        #expect(await rig.events.nextStarted() == nil)
        let newWriter = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.waitForFinishToBeRequested(on: newWriter)
        oldWriter.completeFinalization(success: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.events.finishedCount == 1)
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        newWriter.completeFinalization(success: true)
        #expect(await rig.events.nextFinished() == nil)
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        try? FileManager.default.removeItem(at: secondURL)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func actualRecorderIgnoresIdleAndFinishingDropsAndFailsOnBoundedBurst() async throws {
        let idleRig = makeRig(FakeWriterBehavior())
        idleRig.recorder.submitDropForTesting()
        idleRig.recorder.submitDropForTesting()
        let url = try begin(idleRig.recorder, events: idleRig.events)
        idleRig.recorder.submitVideoSampleForTesting(try Self.log2Sample())
        #expect(await idleRig.events.nextStarted() == nil)
        idleRig.recorder.stop()
        let writer = try #require(idleRig.control.current)
        idleRig.recorder.submitDropForTesting()
        idleRig.recorder.submitDropForTesting()
        await idleRig.waitForFinishToBeRequested(on: writer)
        writer.completeFinalization(success: true)
        #expect(await idleRig.events.nextFinished() == nil)
        try? FileManager.default.removeItem(at: url)

        let sparseRig = makeRig(FakeWriterBehavior())
        let sparseURL = try begin(sparseRig.recorder, events: sparseRig.events)
        sparseRig.recorder.submitDropForTesting(at: 100)
        sparseRig.recorder.submitDropForTesting(at: 101.9)
        sparseRig.recorder.submitDropForTesting(at: 103.8)
        sparseRig.recorder.submitVideoSampleForTesting(try Self.log2Sample())
        #expect(await sparseRig.events.nextStarted() == nil)
        sparseRig.recorder.stop()
        let sparseWriter = try #require(sparseRig.control.current)
        await sparseRig.waitForFinishToBeRequested(on: sparseWriter)
        sparseWriter.completeFinalization(success: true)
        #expect(await sparseRig.events.nextFinished() == nil)
        try? FileManager.default.removeItem(at: sparseURL)

        let burstRig = makeRig(FakeWriterBehavior())
        let burstURL = try begin(burstRig.recorder, events: burstRig.events)
        burstRig.recorder.submitDropForTesting(at: 200)
        burstRig.recorder.submitDropForTesting(at: 201)
        burstRig.recorder.submitDropForTesting(at: 201.5)
        #expect(await burstRig.events.nextStarted()?.contains("dropped 3 frames") == true)
        #expect(await burstRig.events.nextFinished()?.contains("dropped 3 frames") == true)
        #expect(!FileManager.default.fileExists(atPath: burstURL.path))
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func writerFinalizationFailureCompletesOnceAndRemovesPartial() async throws {
        let rig = makeRig(FakeWriterBehavior(finalizationSucceeds: false, delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events)
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample())
        #expect(await rig.events.nextStarted() == nil)
        rig.recorder.stop()
        let writer = try #require(rig.control.current)
        await rig.waitForFinishToBeRequested(on: writer)
        writer.completeFinalization(success: false)
        #expect(await rig.events.nextFinished() != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await rig.events.finishedCount == 1)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func audioPrerollAndNonIncreasingAudioAreHandledByRecorder() async throws {
        let rig = makeRig(FakeWriterBehavior())
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 1))
        #expect(await rig.events.nextStarted() == nil)
        rig.recorder.submitAudioSampleForTesting(try Self.log2Sample(pts: 0.99))
        rig.recorder.submitAudioSampleForTesting(try Self.log2Sample(pts: 1.1))
        rig.recorder.submitAudioSampleForTesting(try Self.log2Sample(pts: 1.05))
        #expect(await rig.events.nextFinished()?.contains("timestamps are not increasing") == true)
        let backend = try #require(rig.control.current)
        #expect(backend.appendedAudioCount == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func injectedAudioReadinessAndAppendFailuresCompleteAndDeletePartial() async throws {
        for behavior in [FakeWriterBehavior(audioReady: false),
                         FakeWriterBehavior(audioAppendSucceeds: false)] {
            let rig = makeRig(behavior)
            let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
            rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 1))
            #expect(await rig.events.nextStarted() == nil)
            rig.recorder.submitAudioSampleForTesting(try Self.log2Sample(pts: 1.1))
            #expect(await rig.events.nextFinished() != nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @available(macOS 14.2, iOS 17.2, *)
    private static func log2Sample(pts: Double = 1) throws -> CMSampleBuffer {
        var optionalBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 3840, 2160,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attributes, &optionalBuffer)
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw RecorderTestError.pixelBuffer(status)
        }
        CVBufferSetAttachment(buffer, kCVImageBufferLogTransferFunctionKey,
            CameraSampleValidationPolicy.appleLog2Identifier as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        var description: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &description
        )
        guard formatStatus == noErr, let description else { throw RecorderTestError.formatDescription(formatStatus) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else { throw RecorderTestError.sampleBuffer(sampleStatus) }
        return sample
    }

    private func begin(_ recorder: CameraSampleBufferRecorder, events: RecorderEventQueue,
                       audioSettings: [String: Any]? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString).mov")
        recorder.begin(to: url, videoSettings: ["codec": "hevc"], audioSettings: audioSettings,
            acceptedPixelFormats: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange], metadata: [],
            transform: CameraSampleValidationPolicy.portraitTrackTransform(codedWidth: 3840, codedHeight: 2160),
            onStarted: { error in events.recordStarted(error?.localizedDescription) },
            onFinished: { result in
                let error: String?
                if case .failure(let failure) = result { error = failure.localizedDescription } else { error = nil }
                events.recordFinished(error)
            })
        return url
    }

    private func makeRig(_ behavior: FakeWriterBehavior) -> RecorderRig {
        let events = RecorderEventQueue()
        let control = FakeWriterControl()
        let recorder = CameraSampleBufferRecorder(queue: DispatchQueue(label: "test.sample-buffer-recorder"),
            writerFactory: { url, _, _, _, _ in
                let writer = FakeCameraSampleBufferWriter(url: url, behavior: behavior)
                control.install(writer)
                return writer
            }, outputValidator: { _, _, _ in })
        return RecorderRig(recorder: recorder, events: events, control: control)
    }
}

private struct RecorderRig {
    let recorder: CameraSampleBufferRecorder
    let events: RecorderEventQueue
    let control: FakeWriterControl

    func waitForFinishToBeRequested(on writer: FakeCameraSampleBufferWriter) async {
        for _ in 0..<200 {
            if writer.finishWasRequested { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct FakeWriterBehavior {
    var startSucceeds = true
    var appendSucceeds = true
    var audioAppendSucceeds = true
    var videoReady = true
    var audioReady = true
    var finalizationSucceeds = true
    var delayedFinish = false
}

private final class FakeWriterControl: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: FakeCameraSampleBufferWriter?
    var current: FakeCameraSampleBufferWriter? {
        lock.lock(); defer { lock.unlock() }
        return writer
    }
    func install(_ writer: FakeCameraSampleBufferWriter) {
        lock.lock(); defer { lock.unlock() }
        self.writer = writer
    }
}

private final class FakeCameraSampleBufferWriter: CameraSampleBufferWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let behavior: FakeWriterBehavior
    private var currentStatus: AVAssetWriter.Status = .unknown
    private var finishHandler: (() -> Void)?
    private var requestedFinish = false
    private var audioAppendCount = 0
    var status: AVAssetWriter.Status { lock.lock(); defer { lock.unlock() }; return currentStatus }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return currentStatus == .failed ? RecorderTestError.injected : nil }
    var finishWasRequested: Bool { lock.lock(); defer { lock.unlock() }; return requestedFinish }
    var appendedAudioCount: Int { lock.lock(); defer { lock.unlock() }; return audioAppendCount }

    init(url: URL, behavior: FakeWriterBehavior) {
        self.url = url
        self.behavior = behavior
    }

    func start(at time: CMTime) -> Bool {
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        lock.lock(); defer { lock.unlock() }
        currentStatus = behavior.startSucceeds ? .writing : .failed
        return behavior.startSucceeds
    }

    func isReady(for mediaType: AVMediaType) -> Bool {
        mediaType == .video ? behavior.videoReady : behavior.audioReady
    }

    func append(_ sampleBuffer: CMSampleBuffer, for mediaType: AVMediaType) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if mediaType == .audio { audioAppendCount += 1 }
        let succeeds = mediaType == .audio ? behavior.audioAppendSucceeds : behavior.appendSucceeds
        if !succeeds { currentStatus = .failed }
        return succeeds
    }

    func markInputsAsFinished() {}

    func finishWriting(completion: @escaping () -> Void) {
        lock.lock()
        requestedFinish = true
        finishHandler = completion
        let immediate = !behavior.delayedFinish
        lock.unlock()
        if immediate { completeFinalization(success: behavior.finalizationSucceeds) }
    }

    func completeFinalization(success: Bool) {
        lock.lock()
        currentStatus = success ? .completed : .failed
        let completion = finishHandler
        finishHandler = nil
        lock.unlock()
        completion?()
    }

    func cancelWriting() {
        lock.lock(); defer { lock.unlock() }
        currentStatus = .cancelled
    }
}

private final class RecorderEventQueue: @unchecked Sendable {
    private enum Event { case started(String?), finished(String?) }
    private let lock = NSLock()
    private var events: [Event] = []
    private var waiters: [CheckedContinuation<Event, Never>] = []
    private var starts = 0
    private var finishes = 0
    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var finishedCount: Int { lock.lock(); defer { lock.unlock() }; return finishes }

    func recordStarted(_ error: String?) { enqueue(.started(error), start: true) }
    func recordFinished(_ error: String?) { enqueue(.finished(error), finish: true) }
    func nextStarted() async -> String? {
        switch await next() { case .started(let value): return value; case .finished: return await nextStarted() }
    }
    func nextFinished() async -> String? {
        switch await next() { case .finished(let value): return value; case .started: return await nextFinished() }
    }
    private func next() async -> Event {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !events.isEmpty {
                let event = events.removeFirst()
                lock.unlock()
                continuation.resume(returning: event)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
    private func enqueue(_ event: Event, start: Bool = false, finish: Bool = false) {
        lock.lock()
        if start { starts += 1 }
        if finish { finishes += 1 }
        let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
        if waiter == nil { events.append(event) }
        lock.unlock()
        waiter?.resume(returning: event)
    }
}

private enum RecorderTestError: LocalizedError {
    case pixelBuffer(CVReturn), formatDescription(OSStatus), sampleBuffer(OSStatus), injected
    var errorDescription: String? {
        switch self {
        case .pixelBuffer(let status): return "pixel buffer \(status)"
        case .formatDescription(let status): return "format description \(status)"
        case .sampleBuffer(let status): return "sample buffer \(status)"
        case .injected: return "injected writer failure"
        }
    }
}
