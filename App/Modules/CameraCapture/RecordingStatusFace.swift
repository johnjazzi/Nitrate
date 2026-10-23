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
    /// Armed daylight 60 fps. Shown during a take, and at idle through the
    /// idle-only armed badge, so the mode is unmistakable before and during a
    /// take and can always be returned to 24 fps.
    var daylight60Active = false
    /// Existing active badge is the way back to 24fps when rescue has reduced
    /// exposure below the offer threshold. Never interactive during a take.
    var onManageDaylight: (() -> Void)? = nil

    var stateLabel: String {
        switch presentation {
        case .idle: "READY"
        case .starting: "WAIT"
        case .recording: "REC"
        case .stopping: "STOP"
        }
    }

    var modeStatusLabel: String { daylight60Active ? stateLabel + " · 60FPS" : stateLabel }

    /// Idle-only armed badge. When `.daylight60` is armed and no take is running
    /// this face *is* the return off-ramp to 24 fps (the timer/dot are exclusive
    /// to a confirmed take and are never restored here). It therefore renders the
    /// state and mode label alone: no recording mark, no elapsed timer text.
    private var isArmedIdleBadge: Bool { daylight60Active && presentation == .idle }

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
            // The armed idle badge carries no recording mark and no timer: both
            // stay exclusive to a confirmed take (mood contract).
            if !isArmedIdleBadge {
                HStack(spacing: 6) {
                    statusMark.frame(width: 10, height: 10)
                    Text(text)
                        .font(NitrateTypography.font(size: 12).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Text(modeStatusLabel)
                .font(NitrateTypography.font(size: 8)).tracking(1)
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
        .accessibilityValue(accessibilityStatus
                            + (text.isEmpty || isArmedIdleBadge ? "" : ". \(text)")
                            + (daylight60Active ? ". Daylight 60 fps armed." : ""))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { onManageDaylight?() }
        .accessibilityAddTraits(onManageDaylight == nil ? [] : .isButton)
        .accessibilityHint(onManageDaylight == nil ? "" : "Manage temporary 60fps mode or return to 24fps")
        .accessibilityAction { onManageDaylight?() }
        .allowsHitTesting(onManageDaylight != nil)
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
            // Layout requires five stable slots. Group/EmptyView flatten their
            // children, so an absent timer must live in a concrete container.
            ZStack { settings() }
            ZStack { manual() }
            ZStack { lens() }
            ZStack {
                if statusInToolbar { status() }
            }
            ZStack { diagnostics() }
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
    var isInteractive = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let rect = RecordingStatusOverlayGeometry.rect(viewport: viewport, toolbarBottom: toolbarBottom,
                                                          controlsTop: controlsTop, rotationDegrees: rotationDegrees) {
            content()
                .position(x: rect.midX, y: rect.midY)
                .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
                .allowsHitTesting(isInteractive)
        }
    }
}
