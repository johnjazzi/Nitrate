import Foundation

/// Pure display policy. Activity is not progress, and completion requires Photos delivery.
struct CameraStatusPresentation {
    let outstandingCount: Int
    let pendingCount: Int
    let isProcessing: Bool
    let failedCount: Int
    let errorMessage: String?
    let latestResultCompleted: Bool
    let latestResultSavedToPhotos: Bool?

    var hasError: Bool { failedCount > 0 || errorMessage != nil }
    var isBusy: Bool { outstandingCount > 0 || isProcessing }
    var isSaved: Bool {
        !isBusy && !hasError && latestResultCompleted && latestResultSavedToPhotos == true
    }
    var countText: String? {
        guard outstandingCount > 0 else { return nil }
        return outstandingCount > 99 ? "99+" : "\(outstandingCount)"
    }
    func shouldAnimateRendering(reduceMotion: Bool) -> Bool {
        isProcessing && !reduceMotion
    }

    var label: String {
        if isBusy { return isProcessing ? "RENDERING" : "WAITING" }
        if hasError { return "FAILED" }
        return isSaved ? "SAVED" : "QUEUE"
    }
    var accessibilityDescription: String {
        let activity = isProcessing ? "Rendering..." : "Waiting."
        var description = isBusy
            ? "\(activity) \(outstandingCount) videos outstanding, \(pendingCount) waiting."
            : (isSaved ? "Video saved to Photos." : "No active renders.")
        if hasError {
            description += " " + (errorMessage ?? "\(failedCount) videos failed. Open details to retry.")
        }
        return description
    }

    /// Exact duration for accessibility and details; invalid storage never looks like zero.
    static func timeText(for seconds: TimeInterval?) -> String {
        guard let total = wholeSeconds(seconds) else { return "--:--" }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%ld:%02ld:%02ld", hours, minutes, remainder)
        }
        return String(format: "%02ld:%02ld", minutes, remainder)
    }

    /// Keep native 20pt digits readable in the compact face; only the visual estimate is abbreviated.
    static func compactTimeText(for seconds: TimeInterval?) -> String {
        guard let total = wholeSeconds(seconds) else { return "--:--" }
        let hours = total / 3_600
        guard hours > 0 else { return timeText(for: seconds) }
        if hours > 99 { return "99h+" }
        if hours >= 10 { return "\(hours)h+" }
        return "\(hours)h\((total % 3_600) / 60)m"
    }

    private static func wholeSeconds(_ seconds: TimeInterval?) -> Int? {
        guard let seconds, seconds.isFinite, seconds >= 0,
              seconds < Double(Int.max) else { return nil }
        return Int(seconds.rounded(.down))
    }
}


/// Presentation-only event identities. No queue jobs, delivery or retry state
/// is mutated when the shooting-screen notification is acknowledged.
struct CameraQueueAttentionSnapshot: Equatable {
    var isReady = false
    var workingIDs: Set<UUID> = []
    var deliveredIDs: Set<UUID> = []
    var issues: Set<String> = []
}

struct CameraQueueAttentionState {
    private var initialized = false
    private(set) var hasUnseenIssue = false
    private(set) var successAt: Date?

    mutating func receive(previous: CameraQueueAttentionSnapshot, current: CameraQueueAttentionSnapshot,
                          queueIsOpen: Bool) {
        guard current.isReady else { return }
        guard initialized else {
            // Loaded failures/warnings are history, not new notifications. Keep
            // them in the queue, but do not flash red merely for opening the app.
            initialized = true
            return
        }
        guard !queueIsOpen else { acknowledge(); return }
        if !current.issues.subtracting(previous.issues).isEmpty {
            hasUnseenIssue = true
            successAt = nil
        }
        // Loaded history is not a newly successful render. Only work observed
        // pending/processing can produce a green completion cue.
        if initialized, !hasUnseenIssue,
           !current.deliveredIDs.intersection(previous.workingIDs).isEmpty {
            successAt = .now
        }
    }

    mutating func acknowledge() {
        hasUnseenIssue = false
        successAt = nil
    }

    mutating func expireSuccess(startedAt: Date) {
        if successAt == startedAt { successAt = nil }
    }
}
