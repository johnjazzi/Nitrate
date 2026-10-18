import Testing
import Foundation

/// Prelaunch camera state fixes: L02 (configured-microphone audio evidence and
/// microphone-output attachment), L09 (manual-focus hardware/UI reconciliation),
/// L10 (manual-ISO recording-transition gate) and L11 (async take ownership).
///
/// These exercise the pure decision seams the recorder, session and view model
/// call, so the RED/GREEN cycle is a real behaviour contract rather than a
/// source-string assertion.
struct PrelaunchCameraStateTests {

    // MARK: - L02: configured-microphone audio evidence

    @Test func configuredMicrophoneWithNoAudioRequiresFailureEvidence() {
        #expect(CameraAudioEvidencePolicy.missingConfiguredAudio(
            requiresAudioEvidence: true, hasAudioSettings: true, appendedAudioSamples: 0))
    }

    @Test func configuredMicrophoneWithAudioIsACleanSuccess() {
        #expect(!CameraAudioEvidencePolicy.missingConfiguredAudio(
            requiresAudioEvidence: true, hasAudioSettings: true, appendedAudioSamples: 12))
    }

    @Test func deliberatelyVideoOnlyTakeStaysACleanSuccess() {
        #expect(!CameraAudioEvidencePolicy.missingConfiguredAudio(
            requiresAudioEvidence: false, hasAudioSettings: false, appendedAudioSamples: 0))
    }

    @Test func audioEvidenceRequiresBothTheFlagAndAudioSettings() {
        // A configured-mic flag with no attached audio settings is the
        // attachment-rollback case: it must not fail a video-only take.
        #expect(!CameraAudioEvidencePolicy.missingConfiguredAudio(
            requiresAudioEvidence: true, hasAudioSettings: false, appendedAudioSamples: 0))
    }

    // MARK: - L02: microphone output attachment

    @Test func microphoneRollsBackWhenTheAudioOutputCannotAttach() {
        #expect(CameraMicrophoneAttachmentPolicy.plan(audioOutputCanAttach: false) == .rollbackInput)
    }

    @Test func microphoneIsConfiguredOnlyWhenTheAudioOutputAttaches() {
        #expect(CameraMicrophoneAttachmentPolicy.plan(audioOutputCanAttach: true) == .configureAudio)
    }

    // MARK: - L09: manual-focus hardware/UI reconciliation

    @Test func aTapDoesNotAutofocusWhileManualFocusIsCommitted() {
        #expect(!CameraManualFocusPolicy.allowsAutofocusOnTap(committedLensPosition: 0.42))
    }

    @Test func aTapAutofocusesWhenNoManualFocusIsCommitted() {
        #expect(CameraManualFocusPolicy.allowsAutofocusOnTap(committedLensPosition: nil))
    }

    @Test func lensChangeReappliesSupportedManualFocus() {
        #expect(CameraManualFocusPolicy.lensPositionAfterLensChange(
            committed: 0.3, newDeviceSupportsLock: true) == 0.3)
    }

    @Test func lensChangeResetsManualFocusWhenUnsupported() {
        #expect(CameraManualFocusPolicy.lensPositionAfterLensChange(
            committed: 0.3, newDeviceSupportsLock: false) == nil)
    }

    @Test func lensChangeResetsManualFocusWhenNoneIsCommitted() {
        #expect(CameraManualFocusPolicy.lensPositionAfterLensChange(
            committed: nil, newDeviceSupportsLock: true) == nil)
    }

    @Test func lensChangeClampsReappliedManualFocus() {
        #expect(CameraManualFocusPolicy.lensPositionAfterLensChange(
            committed: 2.0, newDeviceSupportsLock: true) == 1.0)
        #expect(CameraManualFocusPolicy.lensPositionAfterLensChange(
            committed: -1.0, newDeviceSupportsLock: true) == 0.0)
    }

    // MARK: - L10: manual-ISO recording-transition gate

    @Test func manualISOChangeIsRefusedDuringEveryRecordingTransition() {
        #expect(!CameraManualExposureSelectionPolicy.canChangeISO(
            isStartingRecording: true, isRecording: false, isStoppingRecording: false))
        #expect(!CameraManualExposureSelectionPolicy.canChangeISO(
            isStartingRecording: false, isRecording: true, isStoppingRecording: false))
        #expect(!CameraManualExposureSelectionPolicy.canChangeISO(
            isStartingRecording: false, isRecording: false, isStoppingRecording: true))
    }

    @Test func manualISOChangeIsAllowedWhenIdle() {
        #expect(CameraManualExposureSelectionPolicy.canChangeISO(
            isStartingRecording: false, isRecording: false, isStoppingRecording: false))
    }

    @Test func rejectedISOSelectionReconcilesToTheLastAcceptedValue() {
        #expect(CameraManualExposureSelectionPolicy.reconciledISO(
            previous: 400, requested: 800, accepted: false) == 400)
    }

    @Test func acceptedISOSelectionKeepsTheRequestedValue() {
        #expect(CameraManualExposureSelectionPolicy.reconciledISO(
            previous: 400, requested: 800, accepted: true) == 800)
    }

    // MARK: - L11: async take ownership fence

    @Test func finishingTakeSnapshotsAndClearsTheSharedTimer() throws {
        var origin: Date? = Date(timeIntervalSinceReferenceDate: 100)
        var stoppedAt: Date? = Date(timeIntervalSinceReferenceDate: 130)
        let snapshot = try #require(CameraRecordingTakeFence.snapshotAndClear(
            origin: &origin, stoppedAt: &stoppedAt, generation: 7))
        #expect(origin == nil)
        #expect(stoppedAt == nil)
        #expect(snapshot.generation == 7)
        #expect(snapshot.origin == Date(timeIntervalSinceReferenceDate: 100))
        #expect(snapshot.stoppedAt == Date(timeIntervalSinceReferenceDate: 130))
    }

    @Test func noSnapshotIsTakenWhenTheTakeNeverSetATimerOrigin() {
        var origin: Date?
        var stoppedAt: Date?
        #expect(CameraRecordingTakeFence.snapshotAndClear(
            origin: &origin, stoppedAt: &stoppedAt, generation: 1) == nil)
    }

    @Test func aNewTakeKeepsItsOwnTimerAfterTheOldTakeSnapshots() throws {
        var origin: Date? = Date(timeIntervalSinceReferenceDate: 100)
        var stoppedAt: Date?
        let oldTake = try #require(CameraRecordingTakeFence.snapshotAndClear(
            origin: &origin, stoppedAt: &stoppedAt, generation: 7))
        // Take B begins while the old duration load is still suspended.
        origin = Date(timeIntervalSinceReferenceDate: 200)
        stoppedAt = Date(timeIntervalSinceReferenceDate: 210)
        #expect(!CameraRecordingTakeFence.accepts(
            snapshot: oldTake, currentGeneration: 8,
            isRecording: false, isStartingRecording: false))
        // B's timer state survives the stale snapshot.
        #expect(origin == Date(timeIntervalSinceReferenceDate: 200))
        #expect(stoppedAt == Date(timeIntervalSinceReferenceDate: 210))
    }

    @Test func aVerdictIsRejectedWhileANewTakeIsRunning() {
        let snapshot = CameraRecordingTakeFence.Snapshot(
            generation: 3, origin: Date(timeIntervalSinceReferenceDate: 0), stoppedAt: nil)
        #expect(!CameraRecordingTakeFence.accepts(
            snapshot: snapshot, currentGeneration: 3,
            isRecording: true, isStartingRecording: false))
        #expect(!CameraRecordingTakeFence.accepts(
            snapshot: snapshot, currentGeneration: 3,
            isRecording: false, isStartingRecording: true))
        #expect(!CameraRecordingTakeFence.accepts(
            snapshot: snapshot, currentGeneration: 4,
            isRecording: false, isStartingRecording: false))
    }

    @Test func aVerdictAppliesToTheLiveFinishingTake() {
        let snapshot = CameraRecordingTakeFence.Snapshot(
            generation: 3, origin: Date(timeIntervalSinceReferenceDate: 0), stoppedAt: nil)
        #expect(CameraRecordingTakeFence.accepts(
            snapshot: snapshot, currentGeneration: 3,
            isRecording: false, isStartingRecording: false))
    }
}
