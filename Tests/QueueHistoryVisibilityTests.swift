import Foundation
import Testing

/// Persistence and reconciliation coverage for the presentation-only hidden
/// receipt-UUID store. Nothing here exercises jobs, media, or queue APIs.
@Suite("Queue history visibility", .serialized)
@MainActor
struct QueueHistoryVisibilityTests {

    /// Unique suite per test so concurrent suites never share a domain.
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "QueueHistoryVisibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test func hiddenReceiptSurvivesNewInstance() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hidden = UUID()
        let visible = UUID()
        let store = QueueHistoryVisibility(defaults: defaults)
        #expect(store.hiddenIDs.isEmpty, "Every ID starts visible")
        store.hide(hidden)
        #expect(store.hiddenIDs == [hidden])

        let reloaded = QueueHistoryVisibility(defaults: defaults)
        #expect(reloaded.hiddenIDs == [hidden], "Hidden receipt survives a new instance")
        #expect(!reloaded.hiddenIDs.contains(visible), "Untouched receipts stay visible")
    }

    @Test func shownReceiptIsGoneFromNewInstance() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let store = QueueHistoryVisibility(defaults: defaults)
        store.hide(id)
        store.show(id)
        #expect(store.hiddenIDs.isEmpty)
        #expect(QueueHistoryVisibility(defaults: defaults).hiddenIDs.isEmpty, "Show survives a new instance")
    }

    @Test func reconcileDropsStaleIDsAndKeepsLiveOnes() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let live = UUID()
        let alsoLive = UUID()
        let removed = UUID()
        let store = QueueHistoryVisibility(defaults: defaults)
        store.hide(live)
        store.hide(alsoLive)
        store.hide(removed)

        store.reconcile(with: [live, alsoLive])
        #expect(store.hiddenIDs == [live, alsoLive], "Stale ID dropped, live hidden IDs kept")
        #expect(QueueHistoryVisibility(defaults: defaults).hiddenIDs == [live, alsoLive], "Reconcile is persisted")
    }

    @Test func reconcileWithoutChangesKeepsHiddenIDs() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let store = QueueHistoryVisibility(defaults: defaults)
        store.hide(id)
        store.reconcile(with: [id, UUID()])
        #expect(store.hiddenIDs == [id], "A live hidden ID is never treated as stale")
    }

    @Test func malformedStoredUUIDsAreIgnored() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let valid = UUID()
        defaults.set(["not-a-uuid", valid.uuidString, "", "  "], forKey: "queue.hidden-history.ids.v1")

        let store = QueueHistoryVisibility(defaults: defaults)
        #expect(store.hiddenIDs == [valid], "Only parseable UUID strings load")
        store.hide(UUID())
        #expect(store.hiddenIDs.count == 2, "Malformed entries do not block further hiding")
    }

    @Test func nonArrayStoredValueIsIgnored() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(42, forKey: "queue.hidden-history.ids.v1")

        let store = QueueHistoryVisibility(defaults: defaults)
        #expect(store.hiddenIDs.isEmpty, "A malformed stored value degrades to all-visible")
    }

    @Test func injectedDefaultsAndKeyStayIsolated() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID()
        let second = UUID()
        let customKey = "queue.hidden-history.ids.custom"
        QueueHistoryVisibility(defaults: defaults, key: customKey).hide(first)
        QueueHistoryVisibility(defaults: defaults).hide(second)

        #expect(QueueHistoryVisibility(defaults: defaults, key: customKey).hiddenIDs == [first], "Injected key is used")
        #expect(QueueHistoryVisibility(defaults: defaults).hiddenIDs == [second], "Default key stays separate")
    }
}
