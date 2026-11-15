import Foundation

/// Which part of the local render history a delete request would cover.
///
/// Stub only. This type answers one question — "would a receipt recorded at
/// this moment fall inside the requested scope?" — and nothing else. It
/// deletes no file, removes no `RenderJob`, writes no queue persistence,
/// touches no hidden IDs, and never reaches a Photos record or a Photos API;
/// the library's originals and its own history are outside its reach by
/// construction. The owner wires the button to an explicit "not enabled"
/// notice.
enum HistoryDeletionScope: String, CaseIterable, Identifiable, Sendable {
    case olderThan30Days
    case olderThan7Days
    case all

    var id: String { rawValue }

    /// Whole days of history this scope keeps, counted back from `now`.
    /// `nil` for `.all`, which has no cutoff at all.
    var retainedDays: Int? {
        switch self {
        case .olderThan30Days: return 30
        case .olderThan7Days: return 7
        case .all: return nil
        }
    }

    /// The shortest label that still says what the scope covers. Kept terse so
    /// three segments fit one row of the sheet.
    var title: String {
        switch self {
        case .olderThan30Days: return "30 days"
        case .olderThan7Days: return "7 days"
        case .all: return "All"
        }
    }

    /// The exact boundary a receipt has to be older than, or `nil` for `.all`.
    ///
    /// The arithmetic goes through `Calendar` rather than adding seconds, so a
    /// daylight-saving change never shifts the boundary by an hour.
    func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        guard let retainedDays else { return nil }
        return calendar.date(byAdding: .day, value: -retainedDays, to: now)
    }

    /// Strictly older than the calendar cutoff: a receipt recorded exactly on
    /// the boundary is kept, and only an earlier moment is in scope. `.all`
    /// always includes everything.
    ///
    /// If the calendar cannot resolve the cutoff, nothing is in scope — the
    /// conservative answer for a request that would eventually destroy data.
    func includes(_ recordedAt: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let cutoff = cutoff(now: now, calendar: calendar) else {
            return retainedDays == nil
        }
        return recordedAt < cutoff
    }
}
