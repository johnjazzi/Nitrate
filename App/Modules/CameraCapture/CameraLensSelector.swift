import SwiftUI

/// The compact toolbar key owns presentation only. Its selection always comes
/// from the camera's committed lens state, never from an optimistic local copy.
struct CameraLensSelector: View {
    let availableLenses: [CameraLens]
    let selectedLens: CameraLens
    /// The preview's live focal length, forwarded from the camera view model.
    /// Presentation only: it lets the wide key print 50 mm while the operator
    /// is actually at that stop. Defaulted so older callers keep compiling.
    var currentFocalLengthMM: Double? = nil
    let onSelectLens: (CameraLens) -> Void

    @State private var isPresented = false

    /// Physical orientation, re-injected into the popout so its keys rotate the
    /// same way even if the popover does not inherit the presenter's values.
    @Environment(\.cameraDeviceOrientation) private var deviceOrientation
    @Environment(\.cameraControlAccent) private var controlAccent
    @Environment(\.cameraUIStyle) private var uiStyle

    var body: some View {
        Group {
            if availableLenses.isEmpty {
                // Keep the current lens visible without offering a dead action.
                triggerLabel
                    .background(Circle().fill(Color(white: 0.10)))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Camera lens")
                    .accessibilityValue(title(selectedLens))
                    .accessibilityHint("No camera lenses available")
            } else {
                Button {
                    isPresented.toggle()
                } label: {
                    triggerLabel
                }
                .buttonStyle(CameraRoundButtonStyle())
                .accessibilityLabel("Camera lens")
                .accessibilityValue(title(selectedLens))
                .accessibilityHint("Opens available camera lenses")
                .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    lensWell
                        .presentationCompactAdaptation(.popover)
                        .presentationBackground(.clear)
                }
            }
        }
        .onChange(of: availableLenses) { _, lenses in
            if lenses.isEmpty { isPresented = false }
        }
    }

    private var triggerLabel: some View {
        // One opening affordance for every lens: the aperture glyph only, with
        // no per-lens number or unit. The active lens still reads out via the
        // button's accessibility value.
        Image(systemName: "camera.aperture")
            .font(NitrateTypography.font(size: 17))
            .rotationEffect(.degrees(CameraGlyphRotation.degrees(for: deviceOrientation)))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
    }

    @ViewBuilder
    private var lensWell: some View {
        if uiStyle == .minimal {
            CameraLensRow(availableLenses: availableLenses, selectedLens: selectedLens,
                          currentFocalLengthMM: currentFocalLengthMM) { lens in
                isPresented = false
                onSelectLens(lens)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.9), in: Capsule())
            .environment(\.cameraDeviceOrientation, deviceOrientation)
            .environment(\.cameraControlAccent, controlAccent)
            .environment(\.cameraUIStyle, uiStyle)
            .accessibilityLabel("Available camera lenses")
        } else {
            classicLensWell.environment(\.cameraUIStyle, uiStyle)
        }
    }

    private var classicLensWell: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 8)], spacing: 8) {
            ForEach(availableLenses) { lens in
                lensKey(lens)
            }
        }
        // Add to the shared well's 6pt horizontal / 5pt vertical inset:
        // this rim extends 10pt / 9pt beyond the raised faces.
        .padding(4)
        .cameraControlWell(cornerRadius: 16)
        // Separate transparent clearance keeps key shadows and the rim away
        // from the presentation boundary.
        .padding(10)
        .frame(width: 180)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.cameraDeviceOrientation, deviceOrientation)
        .environment(\.cameraControlAccent, controlAccent)
        .accessibilityLabel("Available camera lenses")
    }

    private func lensKey(_ lens: CameraLens) -> some View {
        let isSelected = lens == selectedLens
        let label = lens == .front
            ? "Front"
            : "\(lensKeyFocalMM(lens, selected: selectedLens, currentMM: currentFocalLengthMM))"
        return Button {
            isPresented = false
            onSelectLens(lens)
        } label: {
            CameraLensFace(label: label,
                           rotationDegrees: CameraGlyphRotation.degrees(for: deviceOrientation),
                           isSelected: isSelected)
                .foregroundStyle(isSelected ? controlAccent : .white.opacity(0.65))
                .frame(height: 44)
        }
        .buttonStyle(CameraRaisedButtonStyle(faceColor: isSelected ? controlAccent.opacity(0.14) : nil))
        .accessibilityLabel(title(lens))
        .accessibilityHint(isSelected
            ? wideKeyToggleHint(lens, selected: selectedLens, currentMM: currentFocalLengthMM)
                ?? "Current camera lens"
            : "Switches camera lens and closes selector")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func title(_ lens: CameraLens) -> String {
        lens == .front ? "Front" : "\(lensKeyFocalMM(lens, selected: selectedLens, currentMM: currentFocalLengthMM)) mm"
    }
}

/// Direct lens choices share the toolbar's committed selection and callback.
/// Minimal uses 30pt faces with a 4pt visual gap in a 44pt-high touch strip.
/// Each adjoining cell has one deterministic lens action; invisible targets never overlap.
struct CameraLensRow: View {
    let availableLenses: [CameraLens]
    let selectedLens: CameraLens
    /// Live focal length, forwarded by the selector or the camera screen.
    /// Defaulted for older callers; the parent passes the real value.
    var currentFocalLengthMM: Double? = nil
    let onSelectLens: (CameraLens) -> Void
    @Environment(\.cameraControlAccent) private var controlAccent
    @Environment(\.cameraUIStyle) private var uiStyle
    @Environment(\.cameraDeviceOrientation) private var deviceOrientation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(availableLenses.sorted {
                ($0 == .front ? Int.max : $0.focalLengthMM) < ($1 == .front ? Int.max : $1.focalLengthMM)
            }) { lens in
                let label = lens == .front
                    ? "F"
                    : "\(lensKeyFocalMM(lens, selected: selectedLens, currentMM: currentFocalLengthMM))"
                Button {
                    // The selected wide key is live: activating it again
                    // toggles 24 ↔ 50 mm. Every other selected key stays inert.
                    guard lens != selectedLens || lens == .wide else { return }
                    onSelectLens(lens)
                } label: {
                    Text(label)
                        .font(NitrateTypography.font(size: 12, relativeTo: .caption))
                        .foregroundStyle(lens == selectedLens ? controlAccent : .white.opacity(0.65))
                        .frame(width: CameraMinimalLayout.lensFaceSize, height: CameraMinimalLayout.lensFaceSize)
                        .background(lens == selectedLens ? controlAccent.opacity(0.14) : Color(white: 0.08),
                                    in: Circle())
                        .rotationEffect(.degrees(CameraGlyphRotation.degrees(for: deviceOrientation)))
                        .frame(width: CameraMinimalLayout.lensCellWidth(style: uiStyle),
                               height: CameraMinimalLayout.lensHitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(lens == .front
                    ? "Front camera"
                    : "\(lensKeyFocalMM(lens, selected: selectedLens, currentMM: currentFocalLengthMM)) mm")
                .accessibilityHint(lens == selectedLens
                    ? wideKeyToggleHint(lens, selected: selectedLens, currentMM: currentFocalLengthMM)
                        ?? "Current camera lens"
                    : "Switches camera lens")
                .accessibilityAddTraits(lens == selectedLens ? .isSelected : [])
                .accessibilityIdentifier("camera.lens.\(lens.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera lenses")
    }
}

/// The number a lens key prints: its native focal length, except the wide lens,
/// which prints 50 mm only while the live preview rounds to 50 mm. An
/// intermediate pinch keeps the native 24 mm label. Shared by the toolbar
/// popover's classic keys and the minimal row so both can never disagree.
private func lensKeyFocalMM(_ lens: CameraLens, selected: CameraLens, currentMM: Double?) -> Int {
    // A 50 mm crop on a different physical lens must not relabel the wide key.
    guard lens == .wide, selected == .wide else { return lens.focalLengthMM }
    return Int(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: .wide, currentMM: currentMM))
}

/// VoiceOver's next action for the selected wide key; nil for every other lens,
/// whose activation still only reports its current state.
private func wideKeyToggleHint(_ lens: CameraLens,
                               selected: CameraLens,
                               currentMM: Double?) -> String? {
    guard lens == .wide, lens == selected else { return nil }
    let next = Int(CameraFocalZoomPolicy.wideLensToggleTargetMM(currentMM: currentMM))
    return "Current camera lens; activate again for \(next) mm"
}
