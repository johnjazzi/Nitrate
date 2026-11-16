#if os(iOS)
import SwiftUI

/// Compact recipe control; no capture controls or independent preference owner.
struct DevelopWhiteBalanceControl: View {
    @Binding var value: DevelopWhiteBalance
    let isPhoto: Bool
    let stockKelvin: Float
    @State private var showsAdjustment = false

    private var caption: String {
        if isPhoto {
            guard value.photoKelvin != nil else { return "Stock" }
            let kelvin = value.resolvedPhotoKelvin(stockKelvin: stockKelvin)
            return String(format: "%.0f K", Double(kelvin))
        }
        let warmth = value.resolvedVideoWarmth
        return warmth == 0 ? "Original" : String(format: "%+.0f", Double(warmth) * 100)
    }

    var body: some View {
        Button { showsAdjustment = true } label: {
            VStack(spacing: 2) {
                Text("WB")
                    .font(NitrateTypography.font(.subheadline))
                    .fontWeight(.semibold)
                    .kerning(0.5)
                Text(caption)
                    .font(NitrateTypography.font(.callout).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .contentShape(Capsule())
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Development white balance")
        .accessibilityValue(caption)
        .accessibilityIdentifier("develop.whiteBalance")
        .popover(isPresented: $showsAdjustment) {
            adjustmentPanel
                .presentationCompactAdaptation(.popover)
        }
    }

    private var adjustmentPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("White balance").font(NitrateTypography.font(.headline))
                Spacer(minLength: 8)
                Button("Done") { showsAdjustment = false }
            }
            Text(isPhoto ? "RAW temperature" : "Video temperature correction")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)
            HStack {
                Text(isPhoto ? "Cooler" : "Cooler −")
                Spacer()
                Text(caption).monospacedDigit()
                Spacer()
                Text(isPhoto ? "Warmer" : "Warmer +")
            }
            .font(NitrateTypography.font(.caption))
            Slider(value: sliderValue, in: isPhoto ? 2000...12000 : -1...1,
                   step: isPhoto ? 100 : 0.01)
                .accessibilityLabel(isPhoto ? "RAW temperature in Kelvin" : "Relative video warmth")
                .accessibilityValue(caption)
                .accessibilityIdentifier("develop.whiteBalance.slider")
            HStack {
                Button(isPhoto ? "Use stock" : "Use original") { reset() }
                    .accessibilityIdentifier("develop.whiteBalance.reset")
                Spacer()
            }
            Text(isPhoto
                ? "Overrides the stock's RAW decoding temperature."
                : "Relative correction, not the camera's recorded white balance.")
                .font(NitrateTypography.font(.caption2))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
        .font(NitrateTypography.font(.body))
        .preferredColorScheme(.dark)
    }

    private var sliderValue: Binding<Double> {
        Binding(get: {
            isPhoto ? Double(value.resolvedPhotoKelvin(stockKelvin: stockKelvin))
                : Double(value.resolvedVideoWarmth)
        }, set: { number in
            if isPhoto {
                value = DevelopWhiteBalance(photoKelvin: Float(number), videoWarmth: value.videoWarmth)
            } else {
                value = DevelopWhiteBalance(photoKelvin: value.photoKelvin, videoWarmth: Float(number))
            }
        })
    }

    private func reset() {
        value = isPhoto ? DevelopWhiteBalance(videoWarmth: value.videoWarmth)
            : DevelopWhiteBalance(photoKelvin: value.photoKelvin)
    }
}
#endif
