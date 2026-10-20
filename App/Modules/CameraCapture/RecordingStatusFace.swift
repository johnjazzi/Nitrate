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
    /// Armed daylight 60 fps. Shown whether idle or recording, so the mode is
    /// unmistakable before and during a take.
    var daylight60Active = false

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

    /// Hazard tint while armed; otherwise the presentation tint.
    private var displayTint: Color {
        guard daylight60Active else { return tint }
        return style == .monochrome ? .white : Color(red: 0.95, green: 0.45, blue: 0.12)
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
            Text(daylight60Active ? "60 DAYLIGHT" : stateLabel)
                .font(.system(size: 8, weight: .bold, design: .rounded)).tracking(1)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(displayTint)
        .frame(width: 112, height: 40)
        .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15), lineWidth: 1) }
        .rotationEffect(.degrees(rotationDegrees))
        .frame(width: abs(rotationDegrees) == 90 ? 40 : 112,
               height: abs(rotationDegrees) == 90 ? 112 : 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording status")
        .accessibilityValue("\(accessibilityStatus). \(text)"
                            + (daylight60Active ? ". Daylight 60 fps armed." : ""))
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
    var statusInToolbar = true
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
            Group {
                if statusInToolbar { status() } else { Color.clear.frame(width: 0, height: 0) }
            }
            diagnostics()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// Geometry uses the portrait-locked SAFE-AREA viewport. The physical top edge
/// is the inverse of the existing whole-face rotation: +90 => right, -90 => left.
/// Stationary chrome bounds exclude settings/lens/debug and shooting controls;
/// fixed face bounds make placement independent of timer text and capture state.
enum RecordingStatusOverlayGeometry {
    static func rect(viewport: CGSize, toolbarBottom: CGFloat, controlsTop: CGFloat,
                     rotationDegrees: Double) -> CGRect? {
        guard abs(rotationDegrees) == 90 else { return nil }
        let size = CGSize(width: 40, height: 112)
        let top = max(8, toolbarBottom + 8)
        let bottom = min(viewport.height - 8, controlsTop - 8)
        guard viewport.width >= size.width + 16, bottom - top >= size.height else { return nil }
        let centerY = min(max(viewport.height / 2, top + size.height / 2), bottom - size.height / 2)
        let x = rotationDegrees > 0 ? viewport.width - 8 - size.width : 8
        return CGRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
    }
}

/// A non-sizing sibling overlay: never participates in preview/framing bounds.
struct RecordingStatusOverlay<Content: View>: View {
    let viewport: CGSize
    let toolbarBottom: CGFloat
    let controlsTop: CGFloat
    let rotationDegrees: Double
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let rect = RecordingStatusOverlayGeometry.rect(viewport: viewport, toolbarBottom: toolbarBottom,
                                                          controlsTop: controlsTop, rotationDegrees: rotationDegrees) {
            content()
                .position(x: rect.midX, y: rect.midY)
                .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
                .allowsHitTesting(false)
        }
    }
}
