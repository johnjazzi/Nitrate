import Foundation
import AVFoundation
import Testing

@Suite("Camera lifecycle and recording policies")
struct CameraPolicyTests {
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
