import SwiftUI

enum RecordingIndicatorStyle: String, CaseIterable, Identifiable {
    case red
    case monochrome

    static let preferenceKey = "camera.recordingIndicatorStyle"
    static func resolved(_ value: String) -> Self { Self(rawValue: value) ?? .red }
    var id: String { rawValue }
    var title: String { self == .red ? "Red" : "Monochrome" }
}

/// Presentation-only snapshot. The origin and frozen stop time remain model-owned.
struct RecordingStatusFace: View {
    let presentation: RecordButtonPresentation
    let text: String
    var style: RecordingIndicatorStyle = .red
    var rotationDegrees: Double = 0

    var stateLabel: String {
        switch presentation {
        case .idle: "READY"
        case .starting: "WAIT"
        case .recording: "REC"
        case .stopping: "STOP"
        }
    }

    var accessibilityStatus: String {
        switch presentation {
        case .idle: "Ready, not recording"
        case .starting: "Starting, capture not yet confirmed"
        case .recording: "Recording, capture confirmed"
        case .stopping: "Stopping, timer frozen, finalizing recording"
        }
    }

    private var tint: Color {
        if style == .monochrome { return .white.opacity(presentation == .idle ? 0.55 : 0.95) }
        switch presentation {
        case .idle: return .white.opacity(0.55)
        case .starting: return Color(red: 0.95, green: 0.57, blue: 0.12)
        case .recording: return Color(red: 0.95, green: 0.22, blue: 0.18)
        case .stopping: return Color(red: 0.72, green: 0.42, blue: 0.40)
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                statusMark.frame(width: 10, height: 10)
                Text(text)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Text(stateLabel).font(.system(size: 8, weight: .bold, design: .rounded)).tracking(1)
        }
        .foregroundStyle(tint)
        .frame(width: 112, height: 40)
        .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15), lineWidth: 1) }
        .rotationEffect(.degrees(rotationDegrees))
        .frame(width: abs(rotationDegrees) == 90 ? 40 : 112,
               height: abs(rotationDegrees) == 90 ? 112 : 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording status")
        .accessibilityValue("\(accessibilityStatus). \(text)")
        .allowsHitTesting(false)
    }

    @ViewBuilder private var statusMark: some View {
        switch presentation {
        case .idle: Circle().strokeBorder(lineWidth: 1).opacity(0.5)
        case .starting: Circle().strokeBorder(lineWidth: 2)
        case .recording: Circle().fill()
        case .stopping: RoundedRectangle(cornerRadius: 1).fill()
        }
    }
}

/// Primary keys and status use separate measured rows. DEBUG/FAULT have their
/// own left rail, never squeezed into the lens/status touch bounds on small phones.
struct CameraTopPanel<Settings: View, Manual: View, Lens: View, Status: View, Diagnostics: View>: View {
    @ViewBuilder var settings: () -> Settings
    @ViewBuilder var manual: () -> Manual
    @ViewBuilder var lens: () -> Lens
    @ViewBuilder var status: () -> Status
    @ViewBuilder var diagnostics: () -> Diagnostics

    var body: some View {
        CameraTopPanelLayout() {
            settings()
            manual()
            lens()
            status()
            diagnostics()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
