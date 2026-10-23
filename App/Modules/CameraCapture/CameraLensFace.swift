import SwiftUI

/// One label shared by the toolbar trigger and each real lens key. Rotate the
/// natural-size stack, not its shallow text bounds. Selection lives outside it.
struct CameraLensFace: View {
    let title: String
    let focalLength: String?
    var rotationDegrees: Double = 0
    var isSelected = false

    private var isLandscape: Bool { abs(rotationDegrees) == 90 }

    var body: some View {
        Group {
            if isLandscape {
                VStack(spacing: 2) {
                    apertureIcon
                    focalLabel
                }
            } else {
                HStack(spacing: 4) {
                    apertureIcon
                    focalLabel
                }
            }
        }
        .fixedSize()
        .rotationEffect(.degrees(rotationDegrees))
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(NitrateTypography.font(size: 11))
                    .rotationEffect(.degrees(rotationDegrees))
                    .padding(.trailing, 6)
                    .accessibilityHidden(true)
            }
        }
    }

    private var apertureIcon: some View {
        Image(systemName: "camera.aperture")
            .font(NitrateTypography.font(size: 16))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var focalLabel: some View {
        if isLandscape, let focalLength {
            // Numeric lens group must fit the turned 44pt key interior without
            // reducing either the icon or the number to an unreadable scale.
            VStack(spacing: 0) {
                Text(focalLength)
                    .font(NitrateTypography.font(size: 13).monospacedDigit())
                Text("mm")
                    .font(NitrateTypography.font(size: 9))
            }
        } else {
            Text(title)
                .font(NitrateTypography.font(size: 13).monospacedDigit())
                .lineLimit(1)
        }
    }
}
