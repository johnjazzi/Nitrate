import SwiftUI

/// The compact toolbar key owns presentation only. Its selection always comes
/// from the camera's committed lens state, never from an optimistic local copy.
struct CameraLensSelector: View {
    let availableLenses: [CameraLens]
    let selectedLens: CameraLens
    let onSelectLens: (CameraLens) -> Void

    @State private var isPresented = false

    /// Physical orientation, re-injected into the popout so its keys rotate the
    /// same way even if the popover does not inherit the presenter's values.
    @Environment(\.cameraDeviceOrientation) private var deviceOrientation

    var body: some View {
        Group {
            if availableLenses.isEmpty {
                // Keep the current lens visible without offering a dead action.
                triggerLabel
                    .modifier(CameraRaisedSurface(faceColor: nil))
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
                .buttonStyle(CameraRaisedButtonStyle())
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
        Group {
            if isLandscape && selectedLens == .front {
                // A horizontal icon + Front is wider than the turned 44pt
                // interior. Stack the natural-size group rather than shrink it.
                VStack(spacing: 2) {
                    apertureIcon
                    focalLabel(selectedLens)
                }
            } else {
                HStack(spacing: 4) {
                    apertureIcon
                    focalLabel(selectedLens)
                }
            }
        }
        .foregroundStyle(.white)
        .fixedSize()
        .cameraRotatingControl()
        .frame(width: 84, height: 44)
    }

    private var isLandscape: Bool {
        abs(CameraGlyphRotation.degrees(for: deviceOrientation)) == 90
    }

    private var apertureIcon: some View {
        Image(systemName: "camera.aperture")
            .font(.system(size: 16, weight: .medium))
            .accessibilityHidden(true)
    }

    private var selectionMark: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func focalLabel(_ lens: CameraLens) -> some View {
        if isLandscape && lens != .front {
            VStack(spacing: 0) {
                Text("\(lens.focalLengthMM)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                Text("mm")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
            }
        } else {
            Text(title(lens))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
        }
    }

    private var lensWell: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            ForEach(availableLenses) { lens in
                lensKey(lens)
            }
        }
        // Add to the shared well's 6pt horizontal / 5pt vertical inset:
        // this rim extends 10pt / 9pt beyond the raised faces.
        .padding(4)
        .cameraControlWell(cornerRadius: 16)
        // Separate transparent clearance keeps key shadows and the rim away
        // from the presentation boundary. 264pt also fits a 320pt screen.
        .padding(10)
        .frame(width: 264)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.cameraDeviceOrientation, deviceOrientation)
        .accessibilityLabel("Available camera lenses")
    }

    private func lensKey(_ lens: CameraLens) -> some View {
        let isSelected = lens == selectedLens
        return Button {
            isPresented = false
            onSelectLens(lens)
        } label: {
            GeometryReader { geometry in
                Group {
                    if isLandscape && lens == .front {
                        VStack(spacing: 2) {
                            apertureIcon
                            focalLabel(lens)
                        }
                    } else {
                        HStack(spacing: 6) {
                            focalLabel(lens)
                            if isSelected { selectionMark }
                        }
                    }
                }
                .foregroundStyle(isSelected ? .black : .white)
                .fixedSize()
                .cameraRotatingControl()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay(alignment: .trailing) {
                    // Keep Front's selected state out of the natural-width
                    // group so both selected and unselected labels always turn.
                    if isLandscape && lens == .front && isSelected {
                        selectionMark
                            .foregroundStyle(.black)
                            .cameraRotatingControl()
                            .padding(.trailing, 8)
                    }
                }
            }
            .frame(height: 44)
        }
        .buttonStyle(CameraRaisedButtonStyle(faceColor: isSelected ? .white : nil))
        .accessibilityLabel(title(lens))
        .accessibilityHint(isSelected ? "Current camera lens" : "Switches camera lens and closes selector")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func title(_ lens: CameraLens) -> String {
        lens == .front ? "Front" : "\(lens.focalLengthMM) mm"
    }
}
