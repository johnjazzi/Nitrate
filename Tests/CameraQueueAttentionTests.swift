import Foundation
import Testing

struct CameraQueueAttentionTests {
    private func snapshot(working: Set<UUID> = [], delivered: Set<UUID> = [],
                          issues: Set<String> = []) -> CameraQueueAttentionSnapshot {
        .init(isReady: true, workingIDs: working, deliveredIDs: delivered, issues: issues)
    }

    @Test func loadingQueueHistoryDoesNotAnnounceOldErrors() {
        var state = CameraQueueAttentionState()
        let loading = CameraQueueAttentionSnapshot()
        let history = snapshot(issues: ["old failure"])
        state.receive(previous: loading, current: loading, queueIsOpen: false)
        state.receive(previous: loading, current: history, queueIsOpen: false)
        #expect(!state.hasUnseenIssue)
        state.receive(previous: history, current: history, queueIsOpen: false)
        #expect(!state.hasUnseenIssue)
        let newFailure = snapshot(issues: ["old failure", "new failure"])
        state.receive(previous: history, current: newFailure, queueIsOpen: false)
        #expect(state.hasUnseenIssue)
    }

    @Test func openingQueueAcknowledgesCueWithoutRemovingItsFailures() {
        var state = CameraQueueAttentionState()
        let clean = snapshot()
        let failed = snapshot(issues: ["failure"])
        state.receive(previous: clean, current: clean, queueIsOpen: false)
        state.receive(previous: clean, current: failed, queueIsOpen: false)
        #expect(state.hasUnseenIssue)
        state.receive(previous: failed, current: failed, queueIsOpen: true)
        #expect(!state.hasUnseenIssue)
        #expect(failed.issues == ["failure"])
        state.receive(previous: failed, current: failed, queueIsOpen: false)
        #expect(!state.hasUnseenIssue)
    }

    @Test func issueStaysLatchedUntilQueueIsOpenedEvenIfTheWarningResolves() {
        var state = CameraQueueAttentionState()
        let clean = snapshot()
        let warning = snapshot(issues: ["low storage"])
        state.receive(previous: clean, current: clean, queueIsOpen: false)
        state.receive(previous: clean, current: warning, queueIsOpen: false)
        state.receive(previous: warning, current: clean, queueIsOpen: false)
        #expect(state.hasUnseenIssue)
        state.receive(previous: clean, current: clean, queueIsOpen: true)
        #expect(!state.hasUnseenIssue)
    }

    @Test func successRequiresObservedWorkNotLoadedCompletedHistory() throws {
        var state = CameraQueueAttentionState()
        let old = UUID()
        let fresh = UUID()
        let history = snapshot(delivered: [old])
        state.receive(previous: .init(), current: history, queueIsOpen: false)
        #expect(state.successAt == nil)
        let working = snapshot(working: [fresh], delivered: [old])
        let completed = snapshot(delivered: [old, fresh])
        state.receive(previous: history, current: working, queueIsOpen: false)
        state.receive(previous: working, current: completed, queueIsOpen: false)
        let started = try #require(state.successAt)
        state.expireSuccess(startedAt: started.addingTimeInterval(-1))
        #expect(state.successAt == started, "An obsolete expiry cannot clear a newer cue.")
        state.expireSuccess(startedAt: started)
        #expect(state.successAt == nil)
    }

    @Test func freshFailureOutranksASuccessInTheSameQueueUpdate() {
        var state = CameraQueueAttentionState()
        let job = UUID()
        let working = snapshot(working: [job])
        let mixed = snapshot(delivered: [job], issues: ["another job failed"])
        state.receive(previous: .init(), current: working, queueIsOpen: false)
        state.receive(previous: working, current: mixed, queueIsOpen: false)
        #expect(state.hasUnseenIssue)
        #expect(state.successAt == nil)
    }
}
