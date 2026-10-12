import Foundation
import AVFoundation
import Testing

@Suite("Camera lifecycle and recording policies")
struct CameraPolicyTests {
    @Test func captureFormatSearchFindsLog2AlternativeAndRejectsUnsupportedLens() {
        let unsupported: [CameraCaptureFormatPolicy.Candidate] = [
            .init(width: 3840, height: 2160, supportsAppleLog2: false, supports24FPS: true),
            .init(width: 1920, height: 1080, supportsAppleLog2: true, supports24FPS: true),
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: false)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2Index(in: unsupported) == nil)
        let candidates = unsupported + [
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2Index(in: candidates) == 3)
    }

    @Test func preferredTenBitLog2FormatWinsButNoSubtypeEvidenceKeepsFirstMatch() {
        let formats: [CameraCaptureFormatPolicy.Candidate] = [
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true),
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2Index(in: formats) == 1)
        #expect(CameraCaptureFormatPolicy.appleLog2Index(in: [formats[0]]) == 0)
    }

    @Test func movieCapabilityPolicyValidatesCodecAndAdvertisedSettingsKeys() throws {
        let baseKeys: Set<String> = ["codec", "compression"]
        func settings(codecs: [String], keys: Set<String>) throws -> [String: Any] {
            try CameraMovieCapabilityPolicy.settings(
                availableCodecs: codecs, hevcCodec: "hvc1", availableSettingsKeys: keys,
                formatDescription: "3840x2160, subtype x420",
                codecKey: "codec", compressionKey: "compression", averageBitRateKey: "bitrate",
                maxKeyFrameIntervalKey: "keyframe", profileLevelKey: "profile",
                averageBitRate: 100, maxKeyFrameInterval: 48, main10Profile: "main10")
        }
        #expect(throws: CameraMovieCapabilityError.self) { try settings(codecs: [], keys: baseKeys) }
        #expect(throws: CameraMovieCapabilityError.self) { try settings(codecs: ["avc1"], keys: baseKeys) }
        #expect(throws: CameraMovieCapabilityError.self) { try settings(codecs: ["apcn"], keys: baseKeys) }
        #expect(throws: CameraMovieCapabilityError.self) { try settings(codecs: ["hvc1"], keys: ["compression"]) }
        let sparse = try settings(codecs: ["hvc1"], keys: ["codec"])
        #expect(sparse.count == 1)
        #expect(sparse["codec"] as? String == "hvc1")
        let complete = try settings(codecs: ["hvc1"], keys: baseKeys)
        #expect(complete["codec"] as? String == "hvc1")
        let compression = try #require(complete["compression"] as? [String: Any])
        #expect(compression["bitrate"] as? Int == 100)
        #expect(compression["keyframe"] as? Int == 48)
        #expect(compression["profile"] as? String == "main10")
    }

    @Test func lifecycleActivationIsIdempotentAndBackgroundInvalidatesPendingConfigure() throws {
        var gate = CameraLifecycleGate()
        let firstActivation = gate.activate()
        let firstGeneration = try #require(firstActivation)
        #expect(gate.activate() == nil)
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
