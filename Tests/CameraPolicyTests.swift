import Foundation
import AVFoundation
import CoreVideo
import Testing

@Suite("Camera lifecycle and recording policies")
struct CameraPolicyTests {
    @Test func captureFormatSearchFindsLog2AlternativeAndRejectsUnsupportedLens() {
        let unsupported: [CameraCaptureFormatPolicy.Candidate] = [
            .init(width: 3840, height: 2160, supportsAppleLog2: false, supports24FPS: true),
            .init(width: 1920, height: 1080, supportsAppleLog2: true, supports24FPS: true),
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: false,
                  isTenBitBiPlanar420: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2Index(in: unsupported) == nil)
        let candidates = unsupported + [
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar422: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2Index(in: candidates) == 3)
        let eightBit = CameraCaptureFormatPolicy.Candidate(
            width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true)
        #expect(CameraCaptureFormatPolicy.appleLog2CandidateIndexes(in: [eightBit]).isEmpty)
    }

    @Test func preferredTenBitLog2FormatIsFirstAndAllEligibleCandidatesRemainAvailable() {
        let formats: [CameraCaptureFormatPolicy.Candidate] = [
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar422: true),
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2CandidateIndexes(in: formats) == [1, 0])
        #expect(CameraCaptureFormatPolicy.appleLog2Index(in: [formats[0]]) == 0)
    }

    @Test func outputPixelNegotiationKeepsAdvertisedTenBitFallbacksAndReportsFourCCs() {
        let x420: UInt32 = 0x78343230
        let xf20: UInt32 = 0x78663230
        let x422: UInt32 = 0x78343232
        let result = CameraSampleValidationPolicy.preferredTenBitPixelFormats(
            from: [0x42475241, x422, 0x3231564e, xf20, x420]
        )
        #expect(result == [xf20, x420, x422])
        #expect(CameraSampleValidationPolicy.preferredTenBitPixelFormats(from: [0x42475241]).isEmpty)
        #expect(CameraSampleValidationPolicy.fourCCListDescription([xf20, x420, x422]) == "xf20, x420, x422")
        #expect(CameraSampleValidationPolicy.fourCCListDescription([]) == "none")
        var attempted: [UInt32] = []
        let selected = CameraSampleValidationPolicy.firstUsableTenBitPixelFormat(
            from: [x422, xf20, x420]
        ) { pixelFormat in
            attempted.append(pixelFormat)
            return pixelFormat == x422
        }
        #expect(attempted == [xf20, x420, x422])
        #expect(selected == x422)
        #expect(CameraSampleValidationPolicy.hasHEVCEncoder(["apcs", "apcn"]) == false)
        #expect(CameraSampleValidationPolicy.hasHEVCEncoder(["hvc1"]))
        let profile = "Main10_AutoLevel"
        #expect(CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
            codec: "hvc1", width: 3840, height: 2160, profile: profile, expectedProfile: profile
        ))
        #expect(!CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
            codec: "apcs", width: 3840, height: 2160, profile: profile, expectedProfile: profile
        ))
        #expect(!CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
            codec: "hvc1", width: 1920, height: 1080, profile: profile, expectedProfile: profile
        ))
        #expect(!CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
            codec: "hvc1", width: 3840, height: 2160, profile: "Main_AutoLevel", expectedProfile: profile
        ))
    }

    @Test func sampleValidationRejectsWrongColorDomainPixelFormatAndGeometry() {
        let x420: UInt32 = 0x78343230
        let accepted: Set<UInt32> = [x420]
        func valid(width: Int = 3840, pixel: UInt32 = x420,
                   log: String? = CameraSampleValidationPolicy.appleLog2Identifier,
                   matrix: String? = "ITU_R_2020", primaries: String? = nil,
                   transfer: String? = nil) -> Bool {
            CameraSampleValidationPolicy.accepts(width: width, height: 2160, pixelFormat: pixel,
                acceptedPixelFormats: accepted, logTransfer: log, matrix: matrix,
                primaries: primaries, transfer: transfer)
        }
        #expect(valid())
        #expect(!valid(pixel: 0x42475241))
        #expect(!valid(log: "AppleLog2"))
        #expect(CameraSampleValidationPolicy.isAppleLog2(CameraSampleValidationPolicy.appleLog2Identifier))
        #expect(!valid(matrix: "ITU_R_709_2"))
        #expect(!valid(width: 1920))
        #expect(!valid(primaries: "ITU_R_2020"))
        #expect(!valid(transfer: "ITU_R_2020"))
    }

    @Test func sampleClockRejectsPrerollAndNonIncreasingTimestamps() {
        #expect(!CameraSampleValidationPolicy.audioIsAfterSessionStart(sampleTime: 0.99, sessionStart: 1))
        #expect(CameraSampleValidationPolicy.audioIsAfterSessionStart(sampleTime: 1, sessionStart: 1))
        #expect(CameraSampleValidationPolicy.timestampIsIncreasing(current: 1, previous: nil))
        #expect(CameraSampleValidationPolicy.timestampIsIncreasing(current: 2, previous: 1))
        #expect(!CameraSampleValidationPolicy.timestampIsIncreasing(current: 1, previous: 1))
        #expect(!CameraSampleValidationPolicy.timestampIsIncreasing(current: .infinity, previous: nil))
        #expect(!CameraSampleValidationPolicy.shouldFailForFrameDrops(recentDropCount: 2))
        #expect(CameraSampleValidationPolicy.shouldFailForFrameDrops(recentDropCount: 3))
        #expect(CameraSampleValidationPolicy.dropTimesWithinWindow([0, 1.9], now: 3.8) == [1.9, 3.8])
    }

    @Test func cancelledStartRetainsRecorderEpochUntilItsTerminalCallback() throws {
        var bridge = CameraRecorderCompletionBridge()
        let firstStarted = bridge.begin(epoch: 41)
        #expect(firstStarted)
        bridge.cancelUserStart(epoch: 41)
        #expect(!bridge.acceptsStarted(epoch: 41))
        let firstTerminal: Bool? = bridge.consumeTerminal(epoch: 41)
        let userWasNotified = try #require(firstTerminal)
        #expect(!userWasNotified)
        #expect(bridge.activeEpoch == nil)

        let secondStarted = bridge.begin(epoch: 42)
        #expect(secondStarted)
        let staleTerminal: Bool? = bridge.consumeTerminal(epoch: 41)
        #expect(staleTerminal == nil)
        #expect(bridge.activeEpoch == 42)
        #expect(bridge.acceptsStarted(epoch: 42))
    }

    @Test func portraitTrackMatrixKeepsCodedLandscapeAndDisplaysPortrait() {
        let transform = CameraSampleValidationPolicy.portraitTrackTransform(codedWidth: 3840, codedHeight: 2160)
        #expect(CameraSampleValidationPolicy.displayDimensions(
            codedWidth: 3840, codedHeight: 2160, transform: transform
        ).0 == 2160)
        #expect(CameraSampleValidationPolicy.displayDimensions(
            codedWidth: 3840, codedHeight: 2160, transform: transform
        ).1 == 3840)
        #expect(transform.a == 0 && transform.b == 1 && transform.c == -1 && transform.d == 0)
        #expect(transform.tx == 2160 && transform.ty == 0)
    }

    @Test func portraitTrackMatrixRoundTripsThroughAVAssetWriter() async throws {
        let width = 64
        let height = 32
        let transform = CameraSampleValidationPolicy.portraitTrackTransform(codedWidth: width, codedHeight: height)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("track-transform-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        #expect(writer.canApply(outputSettings: settings, forMediaType: .video))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        #expect(writer.canAdd(input))
        writer.add(input)

        var optionalBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        let pixelStatus = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes, &optionalBuffer)
        let buffer = try #require(pixelStatus == kCVReturnSuccess ? optionalBuffer : nil)
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format
        )
        let videoFormat = try #require(formatStatus == noErr ? format : nil)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: videoFormat,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        let videoSample = try #require(sampleStatus == noErr ? sample : nil)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        #expect(input.append(videoSample))
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        #expect(writer.status == .completed)
        let asset = AVURLAsset(url: url)
        let track = try #require(asset.tracks(withMediaType: .video).first)
        #expect(track.preferredTransform == transform)
    }

    @Test func recorderLifecycleHandlesEarlyStopFailureAndClipRecovery() throws {
        var state = CameraSampleBufferRecorderState.idle
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .begin))
        #expect(state == .awaitingVideo)
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .failure))
        #expect(state == .failed)
        #expect(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .stop) == nil)
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .reset))
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .begin))
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .firstVideoAppend))
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .stop))
        #expect(state == .finishing)
        #expect(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .stop) == nil)
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .finishSuccess))
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .reset))
        #expect(state == .idle)
        #expect(CameraSampleBufferRecorderLifecyclePolicy.acceptsCompletion(
            callbackGeneration: 9, activeGeneration: 9
        ))
        #expect(!CameraSampleBufferRecorderLifecyclePolicy.acceptsCompletion(
            callbackGeneration: 8, activeGeneration: 9
        ))
        #expect(!CameraSampleBufferRecorderLifecyclePolicy.acceptsCompletion(
            callbackGeneration: 9, activeGeneration: nil
        ))
    }

    @Test func lifecycleActivationIsIdempotentAndBackgroundInvalidatesPendingConfigure() throws {
        var gate = CameraLifecycleGate()
        let firstActivation = gate.activate()
        let firstGeneration = try #require(firstActivation)
        let duplicateActivation = gate.activate()
        #expect(duplicateActivation == nil)
        #expect(gate.accepts(firstGeneration))

        gate.deactivate()
        #expect(!gate.accepts(firstGeneration))
        let resumedActivation = gate.activate()
        let resumedGeneration = try #require(resumedActivation)
        #expect(resumedGeneration != firstGeneration)
        #expect(gate.accepts(resumedGeneration))
    }

    @Test func terminalTimerGenerationRejectsAlreadyQueuedTicksAndReplacementTicks() throws {
        var state = RecordingTimerGeneration()
        let first = state.begin()
        #expect(state.accepts(first))
        state.end()
        #expect(!state.accepts(first))

        let second = state.begin()
        #expect(second != first)
        #expect(!state.accepts(first))
        #expect(state.accepts(second))
    }

    @Test func shutterMeterCallbacksAreInvalidatedAtCameraModeBoundaries() {
        for _ in ["recording", "manual exposure", "lens change", "session stop"] {
            var generation = CameraMeteringGeneration()
            let queuedMeter = generation.issue()
            #expect(generation.accepts(queuedMeter))
            generation.invalidate()
            #expect(!generation.accepts(queuedMeter))
        }
    }

    @Test func recordingCompletionUsesTheRealNSErrorPlayableFlag() {
        let key = AVErrorRecordingSuccessfullyFinishedKey as String
        let playable = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                               userInfo: [key: NSNumber(value: true)])
        let unplayable = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                                 userInfo: [key: NSNumber(value: false)])
        let missingFlag = NSError(domain: "AVFoundationErrorDomain", code: -11800)

        #expect(RecordingCompletionPolicy.shouldPublish(errorExists: false, finishedPlayable: nil))
        #expect(RecordingCompletionPolicy.shouldPublish(
            errorExists: true,
            finishedPlayable: ((playable as NSError).userInfo[key] as? NSNumber)?.boolValue
        ))
        #expect(!RecordingCompletionPolicy.shouldPublish(
            errorExists: true,
            finishedPlayable: ((unplayable as NSError).userInfo[key] as? NSNumber)?.boolValue
        ))
        #expect(!RecordingCompletionPolicy.shouldPublish(
            errorExists: true,
            finishedPlayable: ((missingFlag as NSError).userInfo[key] as? NSNumber)?.boolValue
        ))
    }
}
