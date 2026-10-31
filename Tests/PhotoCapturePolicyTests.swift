import Foundation
import Testing

struct PhotoCapturePolicyTests {
    @Test func idleControlsRequireACommittedIdleGraph() throws {
        var graph = SharedCameraGraphOwnership()
        #expect(!graph.acceptsIdleControls)
        graph.request(.idle)
        let idleLease = graph.begin(.idle)
        let lease = try #require(idleLease)
        #expect(!graph.acceptsIdleControls)
        let overlappingVideoLease = graph.begin(.video)
        #expect(overlappingVideoLease == nil)
        let idleCommitted = graph.finish(lease, actual: .idle)
        #expect(idleCommitted)
        #expect(graph.acceptsIdleControls)
    }

    @Test func cancelledRecordKeepsDrainOwnershipAndRejectsStaleLaunch() throws {
        var graph = SharedCameraGraphOwnership()
        let record = graph.request(.video)
        let videoLease = graph.begin(.video)
        let lease = try #require(videoLease)
        graph.request(.idle)
        #expect(graph.isBusy)
        #expect(graph.owns(lease))
        #expect(!graph.acceptsVideoRequest(record))
        #expect(!graph.acceptsIdleControls)
        let videoCommitted = graph.finish(lease, actual: .video)
        #expect(videoCommitted)
        let idleRestoreLease = graph.begin(.idle)
        let restore = try #require(idleRestoreLease)
        let staleCompletion = graph.finish(lease, actual: .video)
        #expect(!staleCompletion)
        #expect(graph.owns(restore))
        let idleRestored = graph.finish(restore, actual: .idle)
        #expect(idleRestored)
        #expect(graph.acceptsIdleControls)
    }

    @Test func backgroundSupersedesPendingRecordWithoutReleasingItsLease() throws {
        var graph = SharedCameraGraphOwnership()
        let record = graph.request(.video)
        let recordLease = graph.begin(.video)
        let lease = try #require(recordLease)
        graph.request(.stopped)
        #expect(!graph.acceptsVideoRequest(record))
        let overlappingStopLease = graph.begin(.stopped)
        #expect(overlappingStopLease == nil)
        let recordDrainFinished = graph.finish(lease, actual: .video)
        #expect(recordDrainFinished)
        let stopLease = graph.begin(.stopped)
        let stop = try #require(stopLease)
        let stopCommitted = graph.finish(stop, actual: .stopped)
        #expect(stopCommitted)
        #expect(!graph.acceptsIdleControls)
        #expect(!graph.isBusy)
    }

    @Test func lensExitWaitsForItsSingleDrainOwner() throws {
        var lens = PhotoLensSwitchOwnership()
        let firstLensLease = lens.begin()
        let first = try #require(firstLensLease)
        let overlappingLensLease = lens.begin()
        #expect(overlappingLensLease == nil)
        let exitDeferred = lens.requestExit()
        #expect(exitDeferred)
        #expect(lens.owns(first))
        let firstLensCompletion = lens.finish(first)
        #expect(firstLensCompletion == .exitRequested)
        let secondLensLease = lens.begin()
        let second = try #require(secondLensLease)
        let staleLensCompletion = lens.finish(first)
        #expect(staleLensCompletion == nil)
        #expect(lens.owns(second))
        let secondLensCompletion = lens.finish(second)
        #expect(secondLensCompletion == .completed)
    }

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

    // MARK: - Shutter readiness

    @Test func theShutterAttemptsACaptureInEveryState() {
        let states: [PhotoShutterReadiness] = [.ready, .capturing, .changingMode, .cameraNotReady]
        for state in states {
            #expect(state.attemptsCapture, "\(state) must still accept the tap")
        }
    }

    @Test func onlyTheUnblockedStateHasNoReason() {
        #expect(PhotoShutterReadiness.ready.blockedReason == nil)
        for state: PhotoShutterReadiness in [.capturing, .changingMode, .cameraNotReady] {
            let reason = state.blockedReason
            #expect(reason != nil && reason?.isEmpty == false, "\(state) must explain itself")
        }
    }

    @Test func readinessReadsTheLiveCameraState() {
        let policy = PhotoShutterReadinessPolicy.self
        #expect(policy.readiness(isPhotoMode: true, isChangingFrameRate: false,
                                 isChangingCaptureProfile: false, isCaptureBusy: false,
                                 canCapture: true) == .ready)
        #expect(policy.readiness(isPhotoMode: true, isChangingFrameRate: false,
                                 isChangingCaptureProfile: false, isCaptureBusy: true,
                                 canCapture: false) == .capturing)
        #expect(policy.readiness(isPhotoMode: true, isChangingFrameRate: true,
                                 isChangingCaptureProfile: false, isCaptureBusy: false,
                                 canCapture: true) == .changingMode)
        #expect(policy.readiness(isPhotoMode: true, isChangingFrameRate: false,
                                 isChangingCaptureProfile: true, isCaptureBusy: false,
                                 canCapture: true) == .changingMode)
        // The photo graph is not up (or is draining): the tap is accepted and the
        // refusal is explained rather than the control going dead.
        #expect(policy.readiness(isPhotoMode: true, isChangingFrameRate: false,
                                 isChangingCaptureProfile: false, isCaptureBusy: false,
                                 canCapture: false) == .cameraNotReady)
        #expect(policy.readiness(isPhotoMode: false, isChangingFrameRate: false,
                                 isChangingCaptureProfile: false, isCaptureBusy: false,
                                 canCapture: true) == .cameraNotReady)
    }

    @Test func anInFlightCaptureOutranksATransition() {
        // Busy is the more specific answer: the operator's own capture is what
        // blocks the next tap.
        #expect(PhotoShutterReadinessPolicy.readiness(isPhotoMode: true, isChangingFrameRate: true,
                                                      isChangingCaptureProfile: true, isCaptureBusy: true,
                                                      canCapture: false) == .capturing)
    }

    // MARK: - RAW-less sensor fallback

    @Test func aRefusedIdleRequestBecomesTheVideoGraph() {
        #expect(SharedIdleCapabilityFallback.substituteProfile(for: .idle) == .video)
        // Only the still profile has a stand-in; other failures keep the fatal path.
        #expect(SharedIdleCapabilityFallback.substituteProfile(for: .video) == nil)
        #expect(SharedIdleCapabilityFallback.substituteProfile(for: .stopped) == nil)
    }

    @Test func aVideoFallbackIsSettledRatherThanRetryingIdle() throws {
        var graph = SharedCameraGraphOwnership()
        graph.request(.idle)
        let idleLeaseOption = graph.begin(.idle)
        let idleLease = try #require(idleLeaseOption)
        let installedVideo = graph.finish(idleLease, actual: .video)
        #expect(installedVideo)
        // The arbiter is left asking for the graph it actually has, so the
        // refused idle request cannot be re-entered by driveSharedGraph.
        let fallback = try #require(SharedIdleCapabilityFallback.substituteProfile(for: .idle))
        graph.request(fallback)
        #expect(graph.isSettledVideo)
        #expect(graph.isSettled)
        #expect(!graph.acceptsIdleControls)
        // Record still starts from the settled Video graph without a rebuild.
        let recordEpoch = graph.request(.video)
        #expect(graph.acceptsVideoRequest(recordEpoch))
    }

    @Test func onlyVideoIntentMayDowngradeALensChange() {
        // Video keeps the lens selectable; Photo keeps its lens and refuses.
        #expect(SharedIdleCapabilityFallback.admitsLensDowngrade(photoIntent: false))
        #expect(!SharedIdleCapabilityFallback.admitsLensDowngrade(photoIntent: true))
    }

    @Test func aRefusedSensorIsNotAskedTwice() {
        let refusals: Set<String> = ["front"]
        #expect(!SharedIdleCapabilityFallback.attemptsStillProfile(deviceID: "front", refusals: refusals))
        #expect(SharedIdleCapabilityFallback.attemptsStillProfile(deviceID: "wide", refusals: refusals))
        #expect(SharedIdleCapabilityFallback.attemptsStillProfile(deviceID: "wide", refusals: []))
    }

    /// `stopped` is both requested and installed on a fresh or drained arbiter.
    /// Treating that as settled let a lens change run against a stopped session.
    @Test func aStoppedGraphIsNotASettledLensTarget() throws {
        var graph = SharedCameraGraphOwnership()
        #expect(!graph.isSettled)
        #expect(!graph.isSettledVideo)
        let stoppedLeaseOption = graph.begin(.stopped)
        let stoppedLease = try #require(stoppedLeaseOption)
        #expect(!graph.isSettled)
        graph.finish(stoppedLease, actual: .stopped)
        #expect(!graph.isSettled)
        // Only a running profile may accept the lens change.
        graph.request(.idle)
        let idleLeaseOption = graph.begin(.idle)
        let idleLease = try #require(idleLeaseOption)
        graph.finish(idleLease, actual: .idle)
        #expect(graph.isSettled)
    }
}
