import Foundation

/// A transient camera notice: a warning or an error that flares beside the
/// toolbar, can be opened for its full text, and clears itself.
///
/// The lifetime is part of the contract, not a view detail: a warning is advice
/// and must not outlive the moment, an error is something the operator has to
/// know and gets twice as long.
struct CameraNotice: Identifiable, Equatable, Sendable {
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

    init(id: UUID = UUID(), severity: Severity, message: String) {
        self.id = id
        self.severity = severity
        self.message = message
    }

    /// The accessor the view uses, so the flag and the timer cannot disagree
    /// about how long the same notice should stand.
    var lifetime: TimeInterval { severity.lifetime }
}
