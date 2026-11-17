import Foundation
import Observation

/// Presentation-only memory of receipt rows the owner chose to hide from the
/// contact-sheet history. This store never touches jobs, originals, outputs,
/// recipes, or Photos — it only remembers which receipt UUIDs stay hidden so the
/// choice survives relaunches.
///
/// Persistence is a deterministic, sorted array of UUID strings under one
/// injected defaults key; unparseable entries are skipped rather than failing the
/// load, and every ID defaults to visible.
///
/// IDs that no longer correspond to a queue job are dropped by
/// `reconcile(with:)`; the coordinator calls that at real queue
/// initialization/removal boundaries, never from `init`, because the queue loads
/// after model construction and an initial empty set would erase live choices.
@MainActor
@Observable
final class QueueHistoryVisibility {
    private(set) var hiddenIDs: Set<UUID> = []

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "queue.hidden-history.ids.v1"
    ) {
        self.defaults = defaults
        self.key = key
        hiddenIDs = Self.loadHiddenIDs(from: defaults, key: key)
    }

    /// Hide one receipt row. Hiding an already hidden ID is a no-op.
    func hide(_ id: UUID) {
        guard hiddenIDs.insert(id).inserted else { return }
        persist()
    }

    /// Make a previously hidden receipt row visible again.
    func show(_ id: UUID) {
        guard hiddenIDs.remove(id) != nil else { return }
        persist()
    }

    /// Drop hidden IDs that no longer match a live queue job, preserving the
    /// owner's choices for every job that still exists.
    func reconcile(with validIDs: Set<UUID>) {
        let retained = hiddenIDs.intersection(validIDs)
        guard retained != hiddenIDs else { return }
        hiddenIDs = retained
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let strings = hiddenIDs.map(\.uuidString).sorted()
        defaults.set(strings, forKey: key)
    }

    private static func loadHiddenIDs(from defaults: UserDefaults, key: String) -> Set<UUID> {
        guard let strings = defaults.stringArray(forKey: key) else { return [] }
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }
}

/// Pure continuation rule for an open History preview when the displayed receipt
/// order changes underneath it.
///
/// The pager must never re-seat itself on the first page just because the page it
/// was showing left the list: the operator asked to hide one image, not to jump
/// back to the newest one. Hiding therefore continues to the next surviving row in
/// the order that was on screen, and at the end of the list falls back to the
/// nearest surviving predecessor. An emptied list closes the preview.
///
/// A wholly replaced list (the visible/hidden eye flip, a queue reload) has no
/// survivor to continue from, so it keeps the previous first-row fallback rather
/// than leaving a dangling selection. This type owns no state.
enum QueuePreviewContinuation {
    /// The preview selection that should follow `current` once `newIDs` replaces
    /// `oldIDs` as the displayed order.
    static func selection(current: UUID?, oldIDs: [UUID], newIDs: [UUID]) -> UUID? {
        guard !newIDs.isEmpty else { return nil }
        guard let current else { return nil }
        let survivors = Set(newIDs)
        if survivors.contains(current) { return current }

        if let index = oldIDs.firstIndex(of: current) {
            // Forward first: the next row that survived several removals at once.
            if let successor = oldIDs[oldIDs.index(after: index)...].first(where: survivors.contains) {
                return successor
            }
            // At the end of the list, so the closest surviving neighbour behind it.
            if let predecessor = oldIDs[..<index].reversed().first(where: survivors.contains) {
                return predecessor
            }
        }
        // Nothing from the previous order survived: the list was replaced.
        return newIDs.first
    }
}
