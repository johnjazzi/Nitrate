import Foundation

/// UI names, not a claim to reproduce Blackmagic's proprietary stabilization.
/// Extreme is explicitly bridged to Apple's cinematicExtended in CameraSession.
enum CameraStabilizationMode: String, CaseIterable, Identifiable, Sendable {
    case off, standard, cinematic, extreme

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    init(persistedValue: String?) {
        self = persistedValue.flatMap(Self.init(rawValue:)) ?? .off
    }

    /// Apple's documented raw values; unknown modes must remain unknown.
    init?(activeRawValue: Int) {
        switch activeRawValue {
        case 0: self = .off
        case 1: self = .standard
        case 2: self = .cinematic
        case 3: self = .extreme
        default: return nil
        }
    }
}

enum CameraStabilizationPolicy {
    static let preferenceKey = "camera.recordingStabilizationMode"

    struct Capability: Equatable, Sendable {
        let connectionSupported: Bool
        let formatModes: Set<CameraStabilizationMode>

        static let unavailable = Self(connectionSupported: false, formatModes: [])

        var availableModes: [CameraStabilizationMode] {
            CameraStabilizationMode.allCases.filter { $0 == .off || (connectionSupported && formatModes.contains($0)) }
        }

        func effectiveMode(for preferred: CameraStabilizationMode) -> CameraStabilizationMode {
            availableModes.contains(preferred) ? preferred : .off
        }
    }

    static func canChange(recording: Bool, starting: Bool, finishing: Bool) -> Bool {
        !recording && !starting && !finishing
    }

    /// Capability while the shared idle lease owns the session.
    ///
    /// Photo's still profile detaches the recording video output, so there is no
    /// live connection to ask. The format the take will be recorded on still
    /// answers per-mode support, and connection support is the answer the real
    /// video data output connection gave the last time it was attached — never
    /// assumed, so an unobserved connection advertises nothing.
    static func idleCapability(videoConnectionSupportsStabilization: Bool,
                               recordingFormatModes: Set<CameraStabilizationMode>) -> Capability {
        guard videoConnectionSupportsStabilization else { return .unavailable }
        return Capability(connectionSupported: true, formatModes: recordingFormatModes)
    }
}

/// One immutable, queue-read snapshot. No AVFoundation objects cross to UI.
struct CameraStabilizationSnapshot: Equatable, Sendable {
    let preferred: CameraStabilizationMode
    let capability: CameraStabilizationPolicy.Capability
    let activeRawValue: Int?
    let cameraRevision: UInt64
    let changesAllowed: Bool

    var active: CameraStabilizationMode? {
        activeRawValue.flatMap(CameraStabilizationMode.init(activeRawValue:))
    }

    var statusText: String {
        guard let activeRawValue else { return "Requested \(preferred.title) · Active unavailable" }
        guard let active else { return "Requested \(preferred.title) · Active unknown (\(activeRawValue))" }
        if !capability.availableModes.contains(preferred) {
            return "Requested \(preferred.title) · Active \(active.title) (unsupported)"
        }
        if active != preferred {
            return "Requested \(preferred.title) · Active \(active.title) (pending)"
        }
        return "Requested \(preferred.title) · Active \(active.title)"
    }
}
