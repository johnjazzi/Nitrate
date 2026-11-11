import SwiftUI

/// One label shared by the popout's real lens keys. The face shows the lens
/// number alone, or the textual "Front" choice; no aperture icon and no unit.
/// Rotate the natural-size text, not its shallow text bounds. Selection lives
/// outside it.
struct CameraLensFace: View {
    let label: String
    var rotationDegrees: Double = 0
    var isSelected = false

    var body: some View {
        Text(label)
            .font(NitrateTypography.font(size: 13).monospacedDigit())
            .lineLimit(1)
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
}
