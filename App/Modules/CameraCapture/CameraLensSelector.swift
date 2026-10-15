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
        CameraLensFace(title: title(selectedLens),
                       focalLength: selectedLens == .front ? nil : "\(selectedLens.focalLengthMM)",
                       rotationDegrees: CameraGlyphRotation.degrees(for: deviceOrientation))
            .foregroundStyle(.white)
            .frame(width: 84, height: 44)
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
            CameraLensFace(title: title(lens),
                           focalLength: lens == .front ? nil : "\(lens.focalLengthMM)",
                           rotationDegrees: CameraGlyphRotation.degrees(for: deviceOrientation),
                           isSelected: isSelected)
                .foregroundStyle(isSelected ? .black : .white)
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
