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
    @Test func recorderUsesPortraitSampleDimensionsAndIdentityTrackTransform() async throws {
        let rig = makeRig(FakeWriterBehavior())
        let url = try begin(rig.recorder, events: rig.events)
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(width: 2160, height: 3840))
        #expect(await rig.events.nextStarted() == nil)
        let writer = try #require(rig.control.current)
        #expect((rig.control.settings?[AVVideoWidthKey] as? NSNumber)?.intValue == 2160)
        #expect((rig.control.settings?[AVVideoHeightKey] as? NSNumber)?.intValue == 3840)
        #expect(rig.control.transform == .identity)
        rig.recorder.stop()
        await rig.waitForFinishToBeRequested(on: writer)
        writer.completeFinalization(success: true)
        #expect(await rig.events.nextFinished() == nil)
        try? FileManager.default.removeItem(at: url)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func framesOlderThanTheExposureSyncTimeAreNotAppended() async throws {
        let rig = makeRig(FakeWriterBehavior())
        let url = try begin(rig.recorder, events: rig.events,
                            startAfter: CMTime(seconds: 10, preferredTimescale: 600))
        // Produced before the recording exposure took effect: still the old
        // exposure, so it must not open the clip.
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 9))
        // The first frame at or after the sync time opens the clip.
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 11))
        #expect(await rig.events.nextStarted() == nil)
        #expect(rig.control.current?.appendedVideoCount == 1)
        rig.recorder.stop()
        let writer = try #require(rig.control.current)
        await rig.waitForFinishToBeRequested(on: writer)
        writer.completeFinalization(success: true)
        #expect(await rig.events.nextFinished() == nil)
        try? FileManager.default.removeItem(at: url)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func recorderRejectsDimensionChangesWithinClipBeforeAppendingChangedFrame() async throws {
        let rig = makeRig(FakeWriterBehavior())
        let url = try begin(rig.recorder, events: rig.events)
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 1))
        #expect(await rig.events.nextStarted() == nil)
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(width: 2160, height: 3840, pts: 2))
        #expect(await rig.events.nextFinished()?.contains("coded dimensions changed") == true)
        #expect(rig.control.current?.appendedVideoCount == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func injectedSettingRejectionReportsStartAndTerminalFailure() async throws {
        let events = RecorderEventQueue()
        let queue = DispatchQueue(label: "test.writer-settings")
        let recorder = CameraSampleBufferRecorder(queue: queue, writerFactory: { _, _, _, _, _ in
            throw CameraSampleBufferRecorderError.unsupportedWriterSettings("test Main10")
        }, outputValidator: { _, _, _, _ in })
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
    @Test func audioCaptureHandoffReturnsWithoutEnteringBlockedWriterQueue() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            rig.queue.async {
                continuation.resume()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        defer { release.signal() }
        let audio = try Self.pcmSample(pts: 10.1)
        rig.recorder.receiveCapturedAudio(audio)
        #expect(writer.audioTimings.isEmpty, "The audio delegate must hand off without touching queue-confined writer state")
        release.signal()
        await rig.drainSubmittedWork()
        #expect(writer.audioTimings == [RecordedSampleTiming(audio)])
        rig.recorder.cancel()
        await rig.drainSubmittedWork()
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func audioHandoffOwnsPcmBytesBeforeReturningToCapture() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            rig.queue.async {
                continuation.resume()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        defer { release.signal() }
        let audio = try Self.pcmSample(pts: 10.1)
        let original = RecordedSampleTiming(audio)
        rig.recorder.receiveCapturedAudio(audio)
        let sourceBytes = try #require(CMSampleBufferGetDataBuffer(audio))
        #expect(CMBlockBufferFillDataBytes(with: 0, blockBuffer: sourceBytes,
            offsetIntoDestination: 0, dataLength: CMBlockBufferGetDataLength(sourceBytes)) == noErr)
        release.signal()
        await rig.drainSubmittedWork()
        #expect(writer.audioTimings == [original], "The retained handoff must own PCM data, not alias capture-pool memory")
        rig.recorder.cancel()
        await rig.drainSubmittedWork()
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func audioHandoffOverflowFailsInsteadOfGrowingAnUnboundedQueue() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            rig.queue.async {
                continuation.resume()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        defer { release.signal() }
        let audio = try Self.pcmSample(pts: 10)
        for index in 0..<70 {
            rig.recorder.receiveCapturedAudio(try Self.retimed(audio, pts: 10 + Double(index) * 0.1))
        }
        release.signal()
        await rig.drainSubmittedWork()
        #expect(writer.appendedAudioCount == 64)
        try #require(rig.events.finishedCount == 1)
        #expect(await rig.events.nextFinished()?.contains("audio capture handoff") == true)
        #expect(!writer.finishWasRequested)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test(arguments: [false, true])
    func staleAudioHandoffFailureCannotCancelNextClip(overflow: Bool) async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let firstURL = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        let video = try Self.log2Sample(pts: 10)
        rig.recorder.submitVideoSampleForTesting(video)
        await rig.drainSubmittedWork()
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            rig.queue.async {
                continuation.resume()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        defer { release.signal() }
        // These controls are already queued, but an old capture callback can
        // still run on the separate audio queue before they reach the writer.
        rig.recorder.cancel()
        let secondURL = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        if overflow {
            let audio = try Self.pcmSample(pts: 10)
            for _ in 0..<70 { rig.recorder.receiveCapturedAudio(audio) }
        } else {
            // Invalid PCM follows the copy-failure handoff rather than overflow.
            rig.recorder.receiveCapturedAudio(video)
        }
        rig.recorder.submitVideoSampleForTesting(try Self.retimed(video, pts: 20))
        release.signal()
        await rig.drainSubmittedWork()
        #expect(rig.events.startedCount == 2)
        #expect(rig.events.finishedCount == 1, "Only canceled clip A may fail; its queued audio error must not fail clip B")
        #expect(rig.control.current?.sessionStart == CMTime(seconds: 20, preferredTimescale: 600))
        #expect(rig.control.current?.status == .writing)
        rig.recorder.cancel()
        await rig.drainSubmittedWork()
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func audioDeliveredBeforeDelayedFirstVideoIsWrittenWithOriginalTiming() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try Self.log2Sample(pts: 10)
        let firstAudio = try Self.pcmSample(pts: 10.5)
        let secondAudio = try Self.pcmSample(pts: 10.6)

        // Stabilized video arrives late on the delegate queue despite its older
        // source PTS. Neither eligible audio packet may be discarded or retimed.
        rig.recorder.submitAudioSampleForTesting(firstAudio)
        rig.recorder.submitAudioSampleForTesting(secondAudio)
        await rig.drainSubmittedWork()
        #expect(rig.control.current == nil)
        #expect(rig.events.startedCount == 0)
        rig.recorder.submitVideoSampleForTesting(video)
        await rig.drainSubmittedWork()

        let writer = try #require(rig.control.current)
        #expect(rig.events.startedCount == 1)
        #expect(rig.events.finishedCount == 0)
        #expect(writer.sessionStart == CMSampleBufferGetPresentationTimeStamp(video))
        #expect(writer.videoTimings == [RecordedSampleTiming(video)])
        #expect(writer.audioTimings == [RecordedSampleTiming(firstAudio), RecordedSampleTiming(secondAudio)],
                "Audio delivered before delayed video must reach the writer unchanged once video establishes the origin")
        // Cancellation avoids coupling this startup regression to stop draining.
        rig.recorder.cancel()
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 1)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func stopDrainsDelayedVideoToFrozenAudioEndpointWithoutAcceptingLaterAudio() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try Self.log2Sample(pts: 10)
        let acceptedAudio = try Self.pcmSample(pts: 10.6)
        rig.recorder.submitVideoSampleForTesting(video)
        rig.recorder.submitAudioSampleForTesting(acceptedAudio)
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        #expect(writer.audioTimings == [RecordedSampleTiming(acceptedAudio)])
        #expect(CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(acceptedAudio),
                         CMSampleBufferGetDuration(acceptedAudio)) == CMTime(value: 107, timescale: 10))

        rig.recorder.stop()
        await rig.drainSubmittedWork()
        #expect(!writer.finishWasRequested, "Stop must wait for delayed video to catch the accepted audio endpoint")
        #expect(writer.inputsFinishedCount == 0)
        #expect(rig.events.finishedCount == 0)

        // New audio must not extend the 10.7-second cutoff, and repeated stop
        // must neither close the tracks early nor move that frozen cutoff.
        rig.recorder.submitAudioSampleForTesting(try Self.pcmSample(pts: 10.8))
        rig.recorder.stop()
        let almostCaughtUp = try Self.retimed(video, pts: 10.65)
        rig.recorder.submitVideoSampleForTesting(almostCaughtUp)
        await rig.drainSubmittedWork()
        #expect(writer.audioTimings == [RecordedSampleTiming(acceptedAudio)])
        #expect(writer.videoTimings == [RecordedSampleTiming(video), RecordedSampleTiming(almostCaughtUp)])
        #expect(!writer.finishWasRequested, "Passing the last audio PTS is insufficient: its packet ends at 10.7")
        #expect(writer.inputsFinishedCount == 0)

        let caughtUp = try Self.retimed(video, pts: 10.7)
        rig.recorder.submitVideoSampleForTesting(caughtUp)
        await rig.drainSubmittedWork()
        #expect(writer.videoTimings == [RecordedSampleTiming(video), RecordedSampleTiming(almostCaughtUp),
                                       RecordedSampleTiming(caughtUp)])
        #expect(writer.finishWasRequested)
        #expect(writer.inputsFinishedCount == 1)
        #expect(writer.finishRequestCount == 1)
        #expect(rig.events.finishedCount == 0)
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        #expect(writer.finishRequestCount == 1)
        writer.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        try #require(rig.events.finishedCount == 1)
        #expect(await rig.events.nextFinished() == nil)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func aDropBurstAfterStopCannotFailOrDeleteTheTake() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try Self.log2Sample(pts: 10)
        rig.recorder.submitVideoSampleForTesting(video)
        rig.recorder.submitAudioSampleForTesting(try Self.pcmSample(pts: 10.6))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)

        // Stop freezes the accepted audio endpoint past the video, so the take is
        // still live — and still receiving drop callbacks — while it drains.
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        #expect(!writer.finishWasRequested)

        // A burst that would fail a live take must not abort one the user has
        // already ended: everything up to the stop is captured, and discarding it
        // would lose a completed recording.
        rig.recorder.submitDropForTesting(at: 200)
        rig.recorder.submitDropForTesting(at: 200.5)
        rig.recorder.submitDropForTesting(at: 201)
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 0,
                "A drop burst after stop must not finish the take, let alone fail it")

        // It still finalises normally once video reaches the frozen endpoint.
        rig.recorder.submitVideoSampleForTesting(try Self.retimed(video, pts: 10.7))
        await rig.drainSubmittedWork()
        #expect(writer.finishWasRequested)
        writer.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        try #require(rig.events.finishedCount == 1)
        #expect(await rig.events.nextFinished() == nil)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test(arguments: [false, true])
    func stopWithoutAcceptedAudioRequestsFinishImmediately(audioConfigured: Bool) async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events,
                            audioSettings: audioConfigured ? ["codec": "aac"] : nil)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        #expect(writer.audioTimings.isEmpty)
        #expect(writer.finishWasRequested, "A clip with no accepted audio has no delayed-video tail to drain")
        #expect(writer.inputsFinishedCount == 1)
        #expect(writer.finishRequestCount == 1)
        writer.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        try #require(rig.events.finishedCount == 1)
        #expect(await rig.events.nextFinished() == nil)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func idleAudioPrerollSurvivesBeginAndDropsPacketsBeforeVideoOrigin() async throws {
        let rig = makeRig(FakeWriterBehavior())
        let oldAudio = try Self.pcmSample(pts: 9.9)
        let eligibleAudio = try Self.pcmSample(pts: 10.1)
        rig.recorder.submitAudioSampleForTesting(oldAudio)
        rig.recorder.submitAudioSampleForTesting(eligibleAudio)
        // Idle video must not create a writer or latch dimensions/timestamps.
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 100))
        await rig.drainSubmittedWork()
        #expect(rig.control.current == nil)
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        #expect(writer.audioTimings == [RecordedSampleTiming(eligibleAudio)])
        #expect(await rig.events.nextStarted() == nil)
        rig.recorder.cancel()
        await rig.drainSubmittedWork()
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test(arguments: [false, true])
    func audioPrerollIsBoundedBySourceTimeAndPacketCount(densePackets: Bool) async throws {
        let rig = makeRig(FakeWriterBehavior())
        let count = densePackets ? 600 : 70
        var expected: [RecordedSampleTiming] = []
        for index in 0..<count {
            let pts = Double(index) * (densePackets ? 0.001 : 0.1)
            let sample = try Self.pcmSample(pts: pts)
            rig.recorder.submitAudioSampleForTesting(sample)
            if densePackets ? index >= count - 512 : index >= count - 51 {
                expected.append(RecordedSampleTiming(sample))
            }
        }
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 0))
        await rig.drainSubmittedWork()
        #expect(rig.control.current?.audioTimings == expected)
        rig.recorder.cancel()
        await rig.drainSubmittedWork()
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func disabledAudioIgnoresPrerollAndLivePackets() async throws {
        let rig = makeRig(FakeWriterBehavior(audioReady: false))
        rig.recorder.submitAudioSampleForTesting(try Self.pcmSample(pts: 10.1))
        let url = try begin(rig.recorder, events: rig.events)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitAudioSampleForTesting(try Self.pcmSample(pts: 10.2))
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        rig.recorder.submitAudioSampleForTesting(try Self.pcmSample(pts: 10.3))
        await rig.drainSubmittedWork()
        #expect(rig.events.startedCount == 1)
        #expect(rig.events.finishedCount == 0)
        #expect(rig.control.current?.audioTimings.isEmpty == true)
        rig.recorder.cancel()
        await rig.drainSubmittedWork()
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func idleCancellationClearsRetainedPreroll() async throws {
        let rig = makeRig(FakeWriterBehavior())
        rig.recorder.submitAudioSampleForTesting(try Self.pcmSample(pts: 10.1))
        rig.recorder.cancel()
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        #expect(rig.control.current?.audioTimings.isEmpty == true)
        #expect(rig.events.finishedCount == 0)
        rig.recorder.cancel()
        await rig.drainSubmittedWork()
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func stopWithVideoAlreadyCoveringAudioEndFinishesImmediately() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try Self.log2Sample(pts: 10)
        rig.recorder.submitVideoSampleForTesting(video)
        rig.recorder.submitAudioSampleForTesting(try Self.pcmSample(pts: 10))
        // The packet ends at 10.1; this video's END (not PTS) covers it.
        rig.recorder.submitVideoSampleForTesting(try Self.retimed(video, pts: 10.075))
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        #expect(writer.finishWasRequested)
        writer.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 1)
        #expect(await rig.events.nextFinished() == nil)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func prerollFlushFailureNeverReportsSuccessfulStart() async throws {
        let rig = makeRig(FakeWriterBehavior(audioReady: false))
        rig.recorder.submitAudioSampleForTesting(try Self.pcmSample(pts: 10.1))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        #expect(rig.events.startedCount == 1)
        #expect(rig.events.finishedCount == 1)
        #expect(await rig.events.nextStarted()?.contains("could not keep up") == true)
        #expect(await rig.events.nextFinished()?.contains("could not keep up") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func drainTimeoutFailsWithoutFinalizingAndCannotAffectNextClip() async throws {
        let deadlines = RecorderDrainDeadlines()
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true), deadlines: deadlines)
        let firstURL = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        rig.recorder.submitAudioSampleForTesting(try Self.pcmSample(pts: 11))
        rig.recorder.stop()
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        let oldWriter = try #require(rig.control.current)
        #expect(deadlines.count == 1)
        deadlines.fireAll()
        await rig.drainSubmittedWork()
        #expect(!oldWriter.finishWasRequested)
        #expect(oldWriter.status == .cancelled)
        #expect(rig.events.finishedCount == 1)
        #expect(await rig.events.nextFinished()?.contains("timed out") == true)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))

        let secondURL = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: secondURL) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 20))
        rig.recorder.submitAudioSampleForTesting(try Self.pcmSample(pts: 20.5))
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        // Replay the stale deadline while another clip is also draining.
        deadlines.fireFirst()
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 1)
        let newWriter = try #require(rig.control.current)
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 20.6))
        await rig.drainSubmittedWork()
        #expect(newWriter.finishWasRequested)
        newWriter.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 2)
        #expect(await rig.events.nextFinished() == nil)
        deadlines.fireAll()
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 2)
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
    @Test func landscapeHoldWritesIdentityTransformAndPortraitHoldRotatesTheLandscapeBuffer() async throws {
        // Landscape hold: the sensor's native landscape buffer is delivered as-is.
        let landscapeRig = makeRig(FakeWriterBehavior())
        let landscapeURL = try begin(landscapeRig.recorder, events: landscapeRig.events,
                                     deliveryOrientation: .landscapeLeft)
        landscapeRig.recorder.submitVideoSampleForTesting(try Self.log2Sample(width: 3840, height: 2160))
        #expect(await landscapeRig.events.nextStarted() == nil)
        #expect(landscapeRig.control.transform == .identity)
        #expect((landscapeRig.control.settings?[AVVideoWidthKey] as? NSNumber)?.intValue == 3840)
        #expect((landscapeRig.control.settings?[AVVideoHeightKey] as? NSNumber)?.intValue == 2160)
        let landscapeWriter = try #require(landscapeRig.control.current)
        landscapeRig.recorder.stop()
        await landscapeRig.waitForFinishToBeRequested(on: landscapeWriter)
        landscapeWriter.completeFinalization(success: true)
        #expect(await landscapeRig.events.nextFinished() == nil)
        try? FileManager.default.removeItem(at: landscapeURL)

        // Portrait hold: the same buffer is rotated 90° to display portrait.
        let portraitRig = makeRig(FakeWriterBehavior())
        let portraitURL = try begin(portraitRig.recorder, events: portraitRig.events,
                                    deliveryOrientation: .portrait)
        portraitRig.recorder.submitVideoSampleForTesting(try Self.log2Sample(width: 3840, height: 2160))
        #expect(await portraitRig.events.nextStarted() == nil)
        #expect(portraitRig.control.transform == CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0))
        let portraitWriter = try #require(portraitRig.control.current)
        portraitRig.recorder.stop()
        await portraitRig.waitForFinishToBeRequested(on: portraitWriter)
        portraitWriter.completeFinalization(success: true)
        #expect(await portraitRig.events.nextFinished() == nil)
        try? FileManager.default.removeItem(at: portraitURL)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test(arguments: [CameraSampleValidationPolicy.DeliveryOrientation.portrait, .portraitUpsideDown,
                      .landscapeLeft, .landscapeRight],
          [CameraSampleValidationPolicy.CodedDimensions.landscape4K, .portrait4K])
    func recorderUsesExactMatrixAndKeepsSensorCodedSettings(
        orientation: CameraSampleValidationPolicy.DeliveryOrientation,
        coded: CameraSampleValidationPolicy.CodedDimensions
    ) async throws {
        let rig = makeRig(FakeWriterBehavior())
        let url = try begin(rig.recorder, events: rig.events, deliveryOrientation: orientation)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(width: coded.width, height: coded.height))
        #expect(await rig.events.nextStarted() == nil)
        let expected = CameraSampleValidationPolicy.deliveryGeometry(for: orientation, coded: coded)
        #expect(rig.control.transform == expected.transform)
        #expect((rig.control.settings?[AVVideoWidthKey] as? NSNumber)?.intValue == coded.width)
        #expect((rig.control.settings?[AVVideoHeightKey] as? NSNumber)?.intValue == coded.height)
        let writer = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.waitForFinishToBeRequested(on: writer)
        writer.completeFinalization(success: true)
        #expect(await rig.events.nextFinished() == nil)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func cameraSpecificCaptureAngleIsFrozenAcrossFrames() async throws {
        let rig = makeRig(FakeWriterBehavior())
        let url = try begin(rig.recorder, events: rig.events,
                            deliveryOrientation: .landscapeLeft, captureRotationAngle: 180)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 1))
        #expect(await rig.events.nextStarted() == nil)
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 2))
        let writer = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.waitForFinishToBeRequested(on: writer)
        #expect(rig.control.transform == CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 3840, ty: 2160))
        writer.completeFinalization(success: true)
        #expect(await rig.events.nextFinished() == nil)
    }

    // MARK: - Audio/finish hardening (BUG A/B/C and media safety)

    @available(macOS 14.2, iOS 17.2, *)
    @Test(arguments: [false, true])
    func postStopAudioHandoffErrorCannotFailOrDeleteTheTake(overflow: Bool) async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try Self.log2Sample(pts: 10)
        rig.recorder.submitVideoSampleForTesting(video)
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        #expect(writer.finishWasRequested)
        if overflow {
            let audio = try Self.pcmSample(pts: 10)
            for _ in 0..<70 { rig.recorder.receiveCapturedAudio(audio) }
        } else {
            // A non-PCM sample drives the copy-failure handoff branch.
            rig.recorder.receiveCapturedAudio(video)
        }
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 0, "A post-stop audio error must not fail the take")
        #expect(writer.status == .writing)
        writer.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        try #require(rig.events.finishedCount == 1)
        #expect(await rig.events.nextFinished() == nil, "The finalized take must still report success")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func staleAudioHandoffCannotContaminateTheNextTakePreroll() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let firstURL = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        #expect(rig.control.current != nil)
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            rig.queue.async {
                continuation.resume()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        defer { release.signal() }
        // End take A and queue take B while holding the queue, so a late
        // A-stamped handoff can still be enqueued after B has begun.
        rig.recorder.cancel()
        let secondURL = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        rig.recorder.receiveCapturedAudio(try Self.pcmSample(pts: 20.5))
        release.signal()
        await rig.drainSubmittedWork()
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 20))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        #expect(writer.audioTimings.isEmpty,
                "A stale handoff from the previous take must not enter this take")
        rig.recorder.cancel()
        await rig.drainSubmittedWork()
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func handoffBookkeepingStartsCleanForTheNextTake() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        _ = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            rig.queue.async {
                continuation.resume()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        defer { release.signal() }
        rig.recorder.cancel()
        let secondURL = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: secondURL) }
        let observed = RecorderIntBox()
        // Sample the shared counter once take B has begun, before the previous
        // take's still-queued handoffs have drained.
        rig.queue.async { observed.value = rig.recorder.pendingAudioHandoffs }
        for index in 0..<40 {
            rig.recorder.receiveCapturedAudio(try Self.pcmSample(pts: 10 + Double(index) * 0.1))
        }
        release.signal()
        await rig.drainSubmittedWork()
        #expect(observed.value == 0,
                "The next take must not inherit a previous take's in-flight handoff count")
        rig.recorder.cancel()
        await rig.drainSubmittedWork()
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test(arguments: ["nonFinitePTS", "zeroDuration", "durationMismatch", "inconsistentFormat", "truncatedBytes"])
    func malformedPcmHandoffIsRejectedAndTheReadableTakeIsRetained(kind: String) async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        rig.recorder.receiveCapturedAudio(try Self.malformedPcmSample(kind))
        await rig.drainSubmittedWork()
        #expect(writer.finishWasRequested,
                "A malformed PCM packet must latch a quality error and finish the take")
        writer.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        try #require(rig.events.finishedCount == 1)
        #expect(FileManager.default.fileExists(atPath: url.path),
                "A readable original must never be deleted for a packet defect")
        #expect(await rig.events.nextFinished()?.contains("PCM") == true)
        let error = try #require(rig.events.finishedErrors.first)
        #expect(CameraRetainedRecordingError.retainedURL(from: error) == url)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test(arguments: ["gap", "overlap", "withinBound"])
    func sourceAudioInteriorContinuityUsesTheExistingOneHundredTwentyMillisecondBound(kind: String) async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10.5))
        let first = try Self.pcmPacket(pts: 10.0, frames: kind == "overlap" ? 24_000 : 4_800)
        let second: CMSampleBuffer
        switch kind {
        case "gap": second = try Self.pcmPacket(pts: 10.4)          // 0.30 s interior gap
        case "overlap": second = try Self.pcmPacket(pts: 10.3)      // 0.20 s overlap
        default: second = try Self.pcmPacket(pts: 10.15)            // 0.05 s gap, within bound
        }
        rig.recorder.submitAudioSampleForTesting(first)
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        #expect(writer.appendedAudioCount == 1)
        rig.recorder.submitAudioSampleForTesting(second)
        await rig.drainSubmittedWork()
        if kind == "withinBound" {
            #expect(!writer.finishWasRequested, "A discontinuity inside the bound must not fail the take")
            #expect(writer.appendedAudioCount == 2)
            rig.recorder.cancel()
            await rig.drainSubmittedWork()
        } else {
            #expect(writer.finishWasRequested, "An interior discontinuity must be detected and latched")
            writer.completeFinalization(success: true)
            await rig.drainSubmittedWork()
            try #require(rig.events.finishedCount == 1)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let error = try #require(rig.events.finishedErrors.first)
            #expect(CameraRetainedRecordingError.retainedURL(from: error) == url)
        }
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func configuredMicrophoneWithNoAudioIsNotReportedAsCleanSuccess() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"],
                            requiresAudioEvidence: true)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        writer.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        try #require(rig.events.finishedCount == 1)
        let error = try #require(rig.events.finishedErrors.first)
        #expect(CameraRetainedRecordingError.retainedURL(from: error) == url)
        #expect(error.localizedDescription.contains("audio"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func deliberatelyVideoOnlyTakeWithoutAudioConfigurationStillSucceeds() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        writer.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        try #require(rig.events.finishedCount == 1)
        #expect(await rig.events.nextFinished() == nil, "A deliberate video-only take must stay a clean success")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func finishWritingTimeoutRetainsACompletedButUnreportedOriginal() async throws {
        let deadlines = RecorderDrainDeadlines()
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true), deadlines: deadlines)
        let url = try begin(rig.recorder, events: rig.events)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        #expect(writer.finishWasRequested)
        // The file finalized, but its AVAssetWriter completion never arrives.
        writer.completeFinalizationWithoutCallback(success: true)
        deadlines.fireAll()
        await rig.drainSubmittedWork()
        try #require(rig.events.finishedCount == 1)
        #expect(FileManager.default.fileExists(atPath: url.path),
                "A finalized original must survive a lost completion callback")
        #expect(await rig.events.nextFinished()?.contains("timed out") == true)
        let error = try #require(rig.events.finishedErrors.first)
        #expect(CameraRetainedRecordingError.retainedURL(from: error) == url)
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func finishWritingTimeoutWithoutACompletedWriterDeletesTheUnplayableTail() async throws {
        let deadlines = RecorderDrainDeadlines()
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true), deadlines: deadlines)
        let url = try begin(rig.recorder, events: rig.events)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        deadlines.fireAll()
        await rig.drainSubmittedWork()
        try #require(rig.events.finishedCount == 1)
        #expect(await rig.events.nextFinished()?.contains("timed out") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "A writer that never reached completed status is unplayable and must be removed")
        writer.completeFinalization(success: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(rig.events.finishedCount == 1, "A late completion must not double-report")
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func staleFinishTimeoutCannotAffectTheNextTake() async throws {
        let deadlines = RecorderDrainDeadlines()
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true), deadlines: deadlines)
        let firstURL = try begin(rig.recorder, events: rig.events)
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 10))
        await rig.drainSubmittedWork()
        let oldWriter = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        oldWriter.completeFinalizationWithoutCallback(success: false)
        deadlines.fireFirst()
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))

        let secondURL = try begin(rig.recorder, events: rig.events)
        defer { try? FileManager.default.removeItem(at: secondURL) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 20))
        await rig.drainSubmittedWork()
        let newWriter = try #require(rig.control.current)
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        // Replay the stale deadline while another take is finishing.
        deadlines.fireFirst()
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 1)
        newWriter.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 2)
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        deadlines.fireAll()
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 2, "A stale finish timeout must never double-report")
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func longDeterministicAudioTimelineWithinTheBoundIsFullyWritten() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 0))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        let packetCount = 2_400
        var pts = 0.0
        for index in 0..<packetCount {
            // Deterministic jitter and drift, always inside the 0.12 s bound.
            let step = index % 7 == 0 ? 0.15 : (index % 5 == 0 ? 0.13 : 0.1)
            pts += step
            rig.recorder.submitAudioSampleForTesting(try Self.pcmPacket(pts: pts))
        }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: pts + 0.5))
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 0)
        #expect(writer.appendedAudioCount == packetCount)
        rig.recorder.stop()
        await rig.drainSubmittedWork()
        writer.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        try #require(rig.events.finishedCount == 1)
        #expect(await rig.events.nextFinished() == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func longTimelineWithALateInteriorGapLatchesAndRetainsTheTake() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
        defer { try? FileManager.default.removeItem(at: url) }
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: 0))
        await rig.drainSubmittedWork()
        let writer = try #require(rig.control.current)
        var pts = 0.0
        for _ in 0..<2_000 {
            pts += 0.1
            rig.recorder.submitAudioSampleForTesting(try Self.pcmPacket(pts: pts))
        }
        await rig.drainSubmittedWork()
        #expect(rig.events.finishedCount == 0)
        // A 0.35 s hole opens deep in the take.
        pts += 0.45
        rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: pts + 0.5))
        rig.recorder.submitAudioSampleForTesting(try Self.pcmPacket(pts: pts))
        await rig.drainSubmittedWork()
        #expect(writer.finishWasRequested, "A late interior gap must be detected and latched")
        writer.completeFinalization(success: true)
        await rig.drainSubmittedWork()
        try #require(rig.events.finishedCount == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @available(macOS 14.2, iOS 17.2, *)
    @Test func alternatingStopCancelAndNextClipCallbacksCompleteExactlyOnce() async throws {
        let rig = makeRig(FakeWriterBehavior(delayedFinish: true))
        let modes = ["stop", "cancel", "stop", "cancel"]
        var activeURLs: [URL] = []
        for (index, mode) in modes.enumerated() {
            let url = try begin(rig.recorder, events: rig.events, audioSettings: ["codec": "aac"])
            activeURLs.append(url)
            rig.recorder.submitVideoSampleForTesting(try Self.log2Sample(pts: Double(index) * 10 + 10))
            rig.recorder.submitAudioSampleForTesting(try Self.pcmSample(pts: Double(index) * 10 + 10.2))
            await rig.drainSubmittedWork()
            let writer = try #require(rig.control.current)
            if mode == "stop" {
                // The accepted audio ends at 10.2 + 0.1; a later frame covers it.
                rig.recorder.submitVideoSampleForTesting(
                    try Self.log2Sample(pts: Double(index) * 10 + 10.3))
                rig.recorder.stop()
                await rig.drainSubmittedWork()
                #expect(writer.finishWasRequested)
                writer.completeFinalization(success: true)
                await rig.drainSubmittedWork()
                #expect(FileManager.default.fileExists(atPath: url.path))
            } else {
                rig.recorder.cancel()
                await rig.drainSubmittedWork()
                #expect(!FileManager.default.fileExists(atPath: url.path))
            }
        }
        #expect(rig.events.finishedCount == modes.count)
        #expect(await rig.events.nextFinished() == nil)
        for url in activeURLs { try? FileManager.default.removeItem(at: url) }
    }

    @available(macOS 14.2, iOS 17.2, *)
    private static func log2Sample(width: Int = 3840, height: Int = 2160,
                                   pts: Double = 1) throws -> CMSampleBuffer {
        var optionalBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
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

    /// Retime a sample to `pts` while preserving its per-sample duration. The
    /// single timing entry describes one sample, so a multi-frame PCM packet
    /// must keep its original per-frame duration or its declared total
    /// duration would become inconsistent with its frame count.
    private static func retimed(_ sample: CMSampleBuffer, pts: Double) throws -> CMSampleBuffer {
        var existing = CMSampleTimingInfo()
        let perSampleDuration: CMTime
        if CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &existing) == noErr,
           existing.duration.isValid, existing.duration.isNumeric {
            perSampleDuration = existing.duration
        } else {
            let count = max(1, CMSampleBufferGetNumSamples(sample))
            perSampleDuration = CMTimeMultiplyByRatio(CMSampleBufferGetDuration(sample),
                                                      multiplier: 1, divisor: Int32(count))
        }
        var timing = CMSampleTimingInfo(duration: perSampleDuration,
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
            sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw RecorderTestError.sampleBuffer(status) }
        return copy
    }

    /// A real mono PCM packet containing 4,800 frames (0.1 seconds), rather
    /// than a video sample passed through the recorder's audio entry point.
    private static func pcmSample(pts: Double) throws -> CMSampleBuffer {
        try pcmPacket(pts: pts)
    }

    /// A real mono float PCM packet. The single timing entry carries one frame's
    /// duration, which `CMSampleBufferCreate` expands across every frame, so the
    /// declared packet duration is `frames / sampleRate` unless overridden.
    private static func pcmPacket(
        pts: Double = 0,
        frames: Int = 4_800,
        sampleRate: Double = 48_000,
        sampleRateInFormat: Double? = nil,
        declaredDuration: CMTime? = nil,
        blockByteLength: Int? = nil,
        bytesPerFrameInFormat: UInt32 = 4,
        bitsPerChannelInFormat: UInt32 = 32,
        channelsInFormat: UInt32 = 1,
        formatID: AudioFormatID = kAudioFormatLinearPCM
    ) throws -> CMSampleBuffer {
        let formatRate = sampleRateInFormat ?? sampleRate
        var asbd = AudioStreamBasicDescription(mSampleRate: formatRate, mFormatID: formatID,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrameInFormat, mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrameInFormat, mChannelsPerFrame: channelsInFormat,
            mBitsPerChannel: bitsPerChannelInFormat, mReserved: 0)
        var description: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description)
        guard formatStatus == noErr, let description else { throw RecorderTestError.formatDescription(formatStatus) }
        let fullByteCount = frames * Int(bytesPerFrameInFormat)
        let byteCount = blockByteLength ?? fullByteCount
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard blockStatus == kCMBlockBufferNoErr, let block else { throw RecorderTestError.sampleBuffer(blockStatus) }
        let fillBytes = min(byteCount, fullByteCount)
        if fillBytes >= MemoryLayout<Float>.size {
            let fillCount = fillBytes / MemoryLayout<Float>.size
            let pcm = [Float](repeating: 0.25, count: fillCount)
            let replaceStatus = pcm.withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: fillCount * MemoryLayout<Float>.size)
            }
            guard replaceStatus == kCMBlockBufferNoErr else { throw RecorderTestError.sampleBuffer(replaceStatus) }
        }
        let perFrame = declaredDuration ?? CMTime(value: 1, timescale: CMTimeScale(sampleRate))
        var timing = CMSampleTimingInfo(duration: perFrame,
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw RecorderTestError.sampleBuffer(status) }
        return sample
    }

    /// Deliberately malformed PCM packets for the strict timing/allocation gate.
    private static func malformedPcmSample(_ kind: String) throws -> CMSampleBuffer {
        switch kind {
        case "nonFinitePTS":
            return try pcmPacket(pts: .infinity)
        case "zeroDuration":
            return try pcmPacket(declaredDuration: .zero)
        case "durationMismatch":
            return try pcmPacket(declaredDuration: CMTime(value: 1, timescale: 480))
        case "inconsistentFormat":
            // ASBD byte geometry contradicts channels × bits per channel.
            return try pcmPacket(bytesPerFrameInFormat: 2, bitsPerChannelInFormat: 32, channelsInFormat: 1)
        case "truncatedBytes":
            return try pcmPacket(blockByteLength: 8)
        default:
            throw RecorderTestError.injected
        }
    }

    private func begin(_ recorder: CameraSampleBufferRecorder, events: RecorderEventQueue,
                       audioSettings: [String: Any]? = nil,
                       startAfter: CMTime = .invalid,
                       requiresAudioEvidence: Bool = false,
                       deliveryOrientation: CameraSampleValidationPolicy.DeliveryOrientation = .unknown,
                       captureRotationAngle: CGFloat? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString).mov")
        recorder.begin(to: url, videoSettings: ["codec": "hevc"], audioSettings: audioSettings,
            acceptedPixelFormats: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange], metadata: [],
            deliveryOrientation: deliveryOrientation,
            captureRotationAngle: captureRotationAngle,
            preservationProbeEnabled: false,
            requiresAudioEvidence: requiresAudioEvidence,
            startAfter: startAfter,
            onStarted: { error in events.recordStarted(error?.localizedDescription) },
            onFinished: { result in
                switch result {
                case .success:
                    events.recordFinished(nil)
                case .failure(let failure):
                    events.recordFinished(failure.localizedDescription, raw: failure)
                }
            })
        return url
    }

    private func makeRig(_ behavior: FakeWriterBehavior, deadlines: RecorderDrainDeadlines? = nil) -> RecorderRig {
        let events = RecorderEventQueue()
        let control = FakeWriterControl()
        let queue = DispatchQueue(label: "test.sample-buffer-recorder")
        let recorder = CameraSampleBufferRecorder(queue: queue,
            writerFactory: { url, settings, _, _, transform in
                let writer = FakeCameraSampleBufferWriter(url: url, behavior: behavior)
                control.install(writer, settings: settings, transform: transform)
                return writer
            }, outputValidator: { _, _, _, _ in }, scheduleDrainTimeout: deadlines.map { deadlines in
                { delay, action in deadlines.schedule(after: delay, action: action) }
            })
        return RecorderRig(recorder: recorder, events: events, control: control, queue: queue)
    }
}

private final class RecorderDrainDeadlines: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@Sendable () -> Void] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return actions.count }

    func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        #expect(delay == 5)
        lock.lock(); defer { lock.unlock() }
        actions.append(action)
    }

    func fireFirst() {
        lock.lock()
        let action = actions.first
        lock.unlock()
        action?()
    }

    func fireAll() {
        lock.lock()
        let pending = actions
        lock.unlock()
        pending.forEach { $0() }
    }
}

private final class RecorderIntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    var value: Int? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private struct RecorderRig {
    let recorder: CameraSampleBufferRecorder
    let events: RecorderEventQueue
    let control: FakeWriterControl
    let queue: DispatchQueue

    /// FIFO barrier: assertions run only after every preceding submitted sample
    /// and lifecycle action has been processed, without polling writer counts.
    func drainSubmittedWork() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

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
    private var appliedSettings: [String: Any]?
    private var appliedTransform = CGAffineTransform.identity
    var settings: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return appliedSettings
    }
    var transform: CGAffineTransform {
        lock.lock(); defer { lock.unlock() }
        return appliedTransform
    }
    var current: FakeCameraSampleBufferWriter? {
        lock.lock(); defer { lock.unlock() }
        return writer
    }
    func install(_ writer: FakeCameraSampleBufferWriter, settings: [String: Any], transform: CGAffineTransform) {
        lock.lock(); defer { lock.unlock() }
        self.writer = writer
        appliedSettings = settings
        appliedTransform = transform
    }
}

/// Copy scalar evidence only; the fake must not retain capture-pool buffers.
private struct RecordedSampleTiming: Equatable {
    let presentationTime: CMTime
    let duration: CMTime
    let sampleCount: Int
    let mediaType: CMMediaType
    let firstDataWord: UInt32?

    init(_ sample: CMSampleBuffer) {
        presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        duration = CMSampleBufferGetDuration(sample)
        sampleCount = CMSampleBufferGetNumSamples(sample)
        mediaType = CMSampleBufferGetFormatDescription(sample).map(CMFormatDescriptionGetMediaType) ?? 0
        if let block = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(block) >= 4 {
            var word: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &word) { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: bytes.baseAddress!)
            }
            firstDataWord = status == noErr ? word : nil
        } else {
            firstDataWord = nil
        }
    }
}

private final class FakeCameraSampleBufferWriter: CameraSampleBufferWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let behavior: FakeWriterBehavior
    private var currentStatus: AVAssetWriter.Status = .unknown
    private var finishHandler: (@Sendable () -> Void)?
    private var requestedFinish = false
    private var audioAppendCount = 0
    private var videoAppendCount = 0
    private var recordedSessionStart: CMTime?
    private var recordedAudioTimings: [RecordedSampleTiming] = []
    private var recordedVideoTimings: [RecordedSampleTiming] = []
    private var markedInputsFinishedCount = 0
    private var requestedFinishCount = 0
    var status: AVAssetWriter.Status { lock.lock(); defer { lock.unlock() }; return currentStatus }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return currentStatus == .failed ? RecorderTestError.injected : nil }
    var finishWasRequested: Bool { lock.lock(); defer { lock.unlock() }; return requestedFinish }
    var appendedAudioCount: Int { lock.lock(); defer { lock.unlock() }; return audioAppendCount }
    var appendedVideoCount: Int { lock.lock(); defer { lock.unlock() }; return videoAppendCount }
    var sessionStart: CMTime? { lock.lock(); defer { lock.unlock() }; return recordedSessionStart }
    var audioTimings: [RecordedSampleTiming] { lock.lock(); defer { lock.unlock() }; return recordedAudioTimings }
    var videoTimings: [RecordedSampleTiming] { lock.lock(); defer { lock.unlock() }; return recordedVideoTimings }
    var inputsFinishedCount: Int { lock.lock(); defer { lock.unlock() }; return markedInputsFinishedCount }
    var finishRequestCount: Int { lock.lock(); defer { lock.unlock() }; return requestedFinishCount }

    init(url: URL, behavior: FakeWriterBehavior) {
        self.url = url
        self.behavior = behavior
    }

    func start(at time: CMTime) -> Bool {
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        lock.lock(); defer { lock.unlock() }
        currentStatus = behavior.startSucceeds ? .writing : .failed
        recordedSessionStart = time
        return behavior.startSucceeds
    }

    func isReady(for mediaType: AVMediaType) -> Bool {
        mediaType == .video ? behavior.videoReady : behavior.audioReady
    }

    func append(_ sampleBuffer: CMSampleBuffer, for mediaType: AVMediaType) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if mediaType == .audio { audioAppendCount += 1 } else { videoAppendCount += 1 }
        let timing = RecordedSampleTiming(sampleBuffer)
        if mediaType == .audio { recordedAudioTimings.append(timing) } else { recordedVideoTimings.append(timing) }
        let succeeds = mediaType == .audio ? behavior.audioAppendSucceeds : behavior.appendSucceeds
        if !succeeds { currentStatus = .failed }
        return succeeds
    }

    func markInputsAsFinished() {
        lock.lock(); defer { lock.unlock() }
        markedInputsFinishedCount += 1
    }

    func finishWriting(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        requestedFinish = true
        requestedFinishCount += 1
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

    /// Finalize the file but drop the completion callback, simulating a lost
    /// AVAssetWriter completion that the finish timeout must recover from.
    func completeFinalizationWithoutCallback(success: Bool) {
        lock.lock()
        currentStatus = success ? .completed : .failed
        lock.unlock()
    }

    func cancelWriting() {
        lock.lock(); defer { lock.unlock() }
        currentStatus = .cancelled
    }
}

private final class RecorderEventQueue: @unchecked Sendable {
    private enum Event { case started(String?); case finished(String?, Error?) }
    private let lock = NSLock()
    private var events: [Event] = []
    private var waiters: [CheckedContinuation<Event, Never>] = []
    private var starts = 0
    private var finishes = 0
    private var rawFinishedErrors: [Error] = []
    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var finishedCount: Int { lock.lock(); defer { lock.unlock() }; return finishes }
    var finishedErrors: [Error] { lock.lock(); defer { lock.unlock() }; return rawFinishedErrors }

    func recordStarted(_ error: String?) { enqueue(.started(error), start: true) }
    func recordFinished(_ error: String?, raw: Error? = nil) {
        lock.lock()
        if let raw { rawFinishedErrors.append(raw) }
        lock.unlock()
        enqueue(.finished(error, raw), finish: true)
    }
    func nextStarted() async -> String? {
        switch await next() { case .started(let value): return value; case .finished: return await nextStarted() }
    }
    func nextFinished() async -> String? {
        switch await next() { case .finished(let value, _): return value; case .started: return await nextFinished() }
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
