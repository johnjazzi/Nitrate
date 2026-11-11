import Foundation

/// A transient camera notice: a warning or an error that flares beside the
/// toolbar, can be opened for its full text, and clears itself.
///
/// The lifetime is part of the contract, not a view detail: a warning is advice
/// and must not outlive the moment, an error is something the operator has to
/// know and gets twice as long.
struct CameraNotice: Identifiable, Equatable, Sendable {
    /// Why the notice exists. The kind, not the severity, decides whether the
    /// first occurrence is worth interrupting the operator for: a condition
    /// that will recur (rendering paused, storage low) is explained once and
    /// then reported quietly, while an unexpected failure always surfaces.
    enum Kind: String, CaseIterable, Sendable {
        case accessRequired
        case renderFailed
        case operationFailed
        case storage
        case cameraRecovery
        case generic
    }

    /// How much of the notice the operator sees when it arrives.
    enum Emphasis: String, Equatable, Sendable {
        /// The full panel opens by itself, once, so the condition is read.
        case prominent
        /// The compact flag alone: present, out of the way, openable.
        case compact
    }

    enum Severity: String, Equatable, Sendable {
        case warning
        case error

        /// Seconds the notice stands before it clears itself.
        var lifetime: TimeInterval {
            switch self {
            case .warning: return 10
            case .error: return 20
            }
        }

        var symbolName: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "exclamationmark.octagon.fill"
            }
        }

        var title: String {
            switch self {
            case .warning: return "Warning"
            case .error: return "Error"
            }
        }
    }

    let id: UUID
    let severity: Severity
    let message: String
    let kind: Kind
    let emphasis: Emphasis

    init(id: UUID = UUID(), severity: Severity, message: String,
         kind: Kind = .generic, emphasis: Emphasis = .compact) {
        self.id = id
        self.severity = severity
        self.message = message
        self.kind = kind
        self.emphasis = emphasis
    }

    /// The accessor the view uses, so the flag and the timer cannot disagree
    /// about how long the same notice should stand.
    var lifetime: TimeInterval { severity.lifetime }
}

/// Session-scoped emphasis decision, kept pure so the "explain it once, then
/// stay quiet" contract is testable without a view or a clock.
///
/// The first notice of an actionable kind opens its full panel; every later
/// notice of the same kind — including one that repeats minutes later — is the
/// compact flag. A generic one-off is always compact: an unexpected message
/// that has never appeared before still only needs to be available, not pushed
/// into the operator's face mid-take.
struct CameraNoticeEmphasisPolicy {
    private var announced: Set<CameraNotice.Kind> = []

    mutating func emphasis(for kind: CameraNotice.Kind) -> CameraNotice.Emphasis {
        defer { announced.insert(kind) }
        // A generic one-off is never pushed open; it only needs to be available.
        guard kind != .generic else { return .compact }
        return announced.contains(kind) ? .compact : .prominent
    }
}
