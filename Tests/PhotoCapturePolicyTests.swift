import Foundation
import Testing

struct PhotoCapturePolicyTests {
    @Test func permitsMeasuredBayerPaddingWithoutIncreasingUsableImageBudget() {
        let usable = PhotoCapturePolicy.Dimensions(width: 4032, height: 3024)
        #expect(PhotoCapturePolicy.permitsBayerStorage(.init(width: 4224, height: 3024), usable: usable))
        #expect(PhotoCapturePolicy.permitsBayerStorage(usable, usable: usable))
        for storage in [PhotoCapturePolicy.Dimensions(width: 8064, height: 6048),
                        .init(width: 4000, height: 3024), .init(width: 4224, height: 3025),
                        .init(width: 0, height: 0), .init(width: Int.max, height: Int.max)] {
            #expect(!PhotoCapturePolicy.permitsBayerStorage(storage, usable: usable))
        }
        #expect(!PhotoCapturePolicy.permitsBayerStorage(
            .init(width: 4224, height: 3024), usable: .init(width: 4224, height: 3024)))
    }

    @Test func completionWaitsForAllRequiredEventsInEitherOrder() {
        let sequences: [[PhotoCompletionStep]] = [
            [.rawProcessed, .captureTerminated], [.captureTerminated, .rawProcessed],
            [.graphConfigured, .exposureApplied, .whiteBalanceApplied, .biasApplied],
            [.whiteBalanceApplied, .biasApplied, .exposureApplied, .graphConfigured]
        ]
        for sequence in sequences {
            var barrier = PhotoCompletionBarrier(waitingFor: Set(sequence))
            #expect(!barrier.isReady)
            for step in sequence.dropLast() {
                barrier.complete(step)
                barrier.complete(step)
                #expect(!barrier.isReady)
            }
            barrier.complete(sequence.last!)
            #expect(barrier.isReady)
        }
        var unrelated = PhotoCompletionBarrier(waitingFor: [.exposureApplied])
        unrelated.complete(.whiteBalanceApplied)
        #expect(!unrelated.isReady)
    }

    @Test func selectsLargestBayerDimensionWithinApprovedBudget() {
        let selected = PhotoCapturePolicy.selectDimensions(
            candidates: [.init(width: 1920, height: 1080), .init(width: 4032, height: 3024),
                         .init(width: 8064, height: 6048)],
            bayerPixelFormats: [7], pixelFormat: 7)
        #expect(selected == .init(width: 4032, height: 3024))
        #expect(PhotoCapturePolicy.permitsActualDimensions(.init(width: 3024, height: 4032)))
    }

    @Test func rejectsUnsupportedAndInvalidDimensions() {
        let valid = PhotoCapturePolicy.Dimensions(width: 4032, height: 3024)
        #expect(PhotoCapturePolicy.selectDimensions(
            candidates: [valid], bayerPixelFormats: [], pixelFormat: 7) == nil)
        #expect(PhotoCapturePolicy.selectDimensions(
            candidates: [], bayerPixelFormats: [7], pixelFormat: 7) == nil)
        for invalid in [PhotoCapturePolicy.Dimensions(width: 6048, height: 4032),
                        .init(width: 0, height: 3024), .init(width: -1, height: 3024),
                        .init(width: Int.max, height: Int.max)] {
            #expect(!PhotoCapturePolicy.permitsActualDimensions(invalid))
            #expect(PhotoCapturePolicy.selectDimensions(
                candidates: [invalid], bayerPixelFormats: [7], pixelFormat: 7) == nil)
        }
    }

    @Test func terminalOwnershipSurvivesTimeoutAndRejectsLateCallbacks() {
        var state = PhotoCaptureTransactionState(uniqueID: 42)
        let foreign = state.acceptCallback(uniqueID: 9)
        #expect(foreign == .foreign)
        #expect(!state.callbackSeen)
        let timedOut = state.timeout()
        #expect(timedOut == .markedFailed)
        #expect(state.timedOut && state.isInFlight)
        let repeatTimeout = state.timeout()
        #expect(repeatTimeout == .alreadyFailed)
        let wrongFinish = state.finish(uniqueID: 9)
        #expect(!wrongFinish && state.isInFlight)
        let late = state.acceptCallback(uniqueID: 42)
        #expect(late == .accepted)
        let duplicate = state.acceptCallback(uniqueID: 42)
        #expect(duplicate == .duplicate)
        let finished = state.finish(uniqueID: 42)
        #expect(finished && !state.isInFlight)
        let secondFinish = state.finish(uniqueID: 42)
        #expect(!secondFinish)
        let afterTerminal = state.acceptCallback(uniqueID: 42)
        #expect(afterTerminal == .terminal)
        let terminalTimeout = state.timeout()
        #expect(terminalTimeout == .terminal)

        var success = PhotoCaptureTransactionState(uniqueID: 43)
        let successfulFinish = success.finish(uniqueID: 43)
        #expect(successfulFinish)
        let afterSuccess = success.timeout()
        #expect(afterSuccess == .terminal && !success.timedOut)
    }
}
