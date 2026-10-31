import SwiftUI

/// Pure presentation for the compact in-frame manual control stack.
///
/// The stack carries no capture or AVFoundation dependency: it renders the
/// values the parent supplies and calls the callbacks the parent owns, so every
/// decision here is inspectable without a camera session.
enum InlineManualControlPresentation {
    /// Off and locked controls share one muted foreground.
    static let inactiveGrey = Color.white.opacity(0.45)

    /// The active manual-control tint, matching the in-frame zoom toggle.
    static let activeOrange = SettingsControlChrome.halationOrange

    /// Monotonic orange intensity per stabilization mode. Off draws no orange,
    /// so the face falls back to `inactiveGrey` and a stronger mode reads
    /// brighter than a weaker one.
    static func stabilizationIntensity(_ mode: CameraStabilizationMode) -> Double {
        switch mode {
        case .off: return 0
        case .standard: return 0.4
        case .cinematic: return 0.7
        case .extreme: return 1
        }
    }

    /// Off is grey; an active mode is orange at its intensity.
    static func stabilizationColor(for mode: CameraStabilizationMode) -> Color {
        let intensity = stabilizationIntensity(mode)
        return intensity == 0 ? inactiveGrey : activeOrange.opacity(intensity)
    }

    /// The mode the control paints. A saved but unsupported preference shows as
    /// its effective Off fallback rather than as an active mode, so the palette
    /// never claims a mode the capability cannot deliver.
    static func effectiveMode(_ snapshot: CameraStabilizationSnapshot) -> CameraStabilizationMode {
        snapshot.capability.effectiveMode(for: snapshot.preferred)
    }

    /// Compact value so the selected mode stays legible in a 44pt column.
    static func stabilizationAbbreviation(_ mode: CameraStabilizationMode) -> String {
        switch mode {
        case .off: return "OFF"
        case .standard: return "ST"
        case .cinematic: return "CIN"
        case .extreme: return "EXT"
        }
    }

    /// The focus key's face: MF while the ruler is locked, AF otherwise.
    static func focusTitle(manualFocus: Bool) -> String { manualFocus ? "MF" : "AF" }

    /// Matches the panel's existing manual-focus on/off value.
    static func focusValue(manualFocus: Bool) -> String { manualFocus ? "On" : "Off" }

    /// The stack's reserved height for a given set of keys: every key keeps its
    /// 44pt face, so adding the frame-rate key grows the stack by exactly one
    /// row and its 4pt spacing rather than squeezing an existing control.
    static func stackHeight(showsFrameRate: Bool) -> CGFloat {
        let keys = showsFrameRate ? 4 : 3
        return CGFloat(keys) * 44 + CGFloat(keys - 1) * 4
    }

    /// The frame-rate key belongs to the manual Video block only: Photo has no
    /// frame-rate pipeline to steer and Develop has no capture at all.
    static func showsFrameRateKey(isPhotoMode: Bool, isDevelopMode: Bool) -> Bool {
        !isPhotoMode && !isDevelopMode
    }

    /// An adjustable aperture reads in the app's light-purple menu tint; a fixed
    /// lens greys out without offering a control it cannot honour.
    static func apertureColor(canChange: Bool) -> Color {
        canChange ? SettingsControlChrome.lightPurple : inactiveGrey
    }
}

/// The compact in-frame manual control stack that replaces the old popup face:
/// a 44pt column of MF/AF, aperture and stabilization keys placed directly under
/// the focus ruler. Every key is a native button or menu, all three keep a 44pt
/// height, and the stack never scrolls or hides a control behind a fold.
struct InlineManualControls: View {
    @Binding var manualFocus: Bool
    let apertureReadout: String
    let apertureStops: [Float]
    let selectedAperture: Float?
    let canChangeAperture: Bool
    let setAperture: (Float?) -> Void
    let stabilization: CameraStabilizationSnapshot
    let canChangeStabilization: Bool
    let selectStabilization: (CameraStabilizationMode) -> Void
    var isPhotoMode = false
    var shutterControlEnabled = false
    var toggleShutterControl: () -> Void = {}
    /// Actual rates the session reports as available, in frames per second.
    /// Empty by default so a hosted stack never invents a rate.
    var availableFrameRates: [Int] = []
    /// The rate actually in force. Defaults to the 24 fps cold-launch rate.
    var currentFrameRate: Int = 24
    /// Whether the session will accept a frame-rate change right now.
    var canChangeFrameRate = false
    var selectFrameRate: (Int) -> Void = { _ in }

    private var effectiveStabilization: CameraStabilizationMode {
        InlineManualControlPresentation.effectiveMode(stabilization)
    }

    /// The menu is inert while a change is unavailable or the snapshot forbids it.
    private var stabilizationInteractive: Bool {
        canChangeStabilization && stabilization.changesAllowed
    }

    var body: some View {
        VStack(spacing: 4) {
            focusButton
            apertureButton
            if !isPhotoMode {
                CameraFrameRateControl(availableFPS: availableFrameRates,
                                       currentFPS: currentFrameRate,
                                       canChange: canChangeFrameRate,
                                       select: { chooseFrameRate($0) })
                stabilizationButton
            }
        }
        .frame(width: 44)
        .font(NitrateTypography.font(size: 12))
        .buttonStyle(CameraRaisedButtonStyle(cornerRadius: 6))
    }

    private var focusButton: some View {
        Button(action: toggleFocus) {
            Text(InlineManualControlPresentation.focusTitle(manualFocus: manualFocus))
                .foregroundStyle(manualFocus ? InlineManualControlPresentation.activeOrange
                                             : InlineManualControlPresentation.inactiveGrey)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel("Manual focus")
        .accessibilityValue(InlineManualControlPresentation.focusValue(manualFocus: manualFocus))
        .accessibilityHint("Switch between autofocus and manual focus")
    }

    private var apertureButton: some View {
        Menu {
            Button("Hold") { selectAperture(nil) }
            ForEach(apertureStops, id: \.self) { stop in
                Button(String(format: "f/%.1f", stop)) { selectAperture(stop) }
            }
        } label: {
            HStack(spacing: 2) {
                Text(apertureReadout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Image(systemName: "chevron.down")
                    .font(NitrateTypography.font(size: 9).weight(.semibold))
            }
            .foregroundStyle(InlineManualControlPresentation.apertureColor(canChange: canChangeAperture))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(!canChangeAperture)
        .accessibilityLabel("Aperture")
        .accessibilityValue(apertureReadout)
    }

    private var stabilizationButton: some View {
        Menu {
            ForEach(CameraStabilizationMode.allCases) { mode in
                Button(mode.title) { selectMode(mode) }
                    .disabled(!stabilization.capability.availableModes.contains(mode))
            }
        } label: {
            VStack(spacing: 0) {
                Image(systemName: "camera.viewfinder")
                    .font(NitrateTypography.font(size: 12))
                Text(InlineManualControlPresentation.stabilizationAbbreviation(effectiveStabilization))
                    .font(NitrateTypography.font(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(InlineManualControlPresentation.stabilizationColor(for: effectiveStabilization))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(!stabilizationInteractive)
        .accessibilityLabel("Recording stabilization mode")
        .accessibilityValue(stabilization.statusText)
        .accessibilityHint("Unavailable modes are listed but cannot be selected.")
    }

    // MARK: - Named guards

    // Named actions are shared by the live controls and the focused binding
    // tests, so the guard is exercised once and never re-implemented.

    func toggleFocus() { manualFocus.toggle() }

    func selectAperture(_ aperture: Float?) {
        guard canChangeAperture else { return }
        setAperture(aperture)
    }

    /// The frame-rate key writes only a supported rate on an unlocked session.
    func chooseFrameRate(_ fps: Int) {
        guard CameraFrameRateControlPresentation.canSelect(
            fps, availableFPS: availableFrameRates, canChange: canChangeFrameRate) else { return }
        selectFrameRate(fps)
    }

    func selectMode(_ mode: CameraStabilizationMode) {
        guard canChangeStabilization,
              stabilization.changesAllowed,
              stabilization.capability.availableModes.contains(mode) else { return }
        selectStabilization(mode)
    }
}
