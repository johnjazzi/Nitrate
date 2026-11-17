#if os(iOS)
import SwiftUI

/// Shared presentation only: callers retain their existing media, recipe and
/// metadata owners. All three preview surfaces print in the same reserved bands.
struct ContactPreviewFrame<Content: View>: View {
    let imageSize: CGSize?
    let stockAndGauge: String
    let exposure: String
    var frameRate: String? = nil
    let date: String
    var isVideo = false
    var metadataIdentifier = "preview.contactMetadata"
    @ViewBuilder let content: () -> Content

    private let borderWidth: CGFloat = 24
    private let topInset: CGFloat = 10
    private let bottomInset: CGFloat = 24
    private let printColor = Color.white.opacity(0.85)

    var body: some View {
        GeometryReader { geometry in
            let size = fittedImageSize(in: geometry.size)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    frameLabel(stockAndGauge, degrees: -90)
                    content()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                    ZStack {
                        frameLabel(exposure, degrees: 90)
                        if let frameRate {
                            frameLabel(frameRate, degrees: 90, alignment: .trailing)
                        }
                    }
                    .frame(width: borderWidth)
                }
                .frame(height: size.height)
                VStack(spacing: 0) {
                    Group {
                        if isVideo {
                            QueueFrameStripBorder()
                        } else {
                            Color.clear.frame(height: 3)
                        }
                    }
                    .frame(width: size.width)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Text(date)
                            .font(NitrateTypography.font(size: 9).monospacedDigit())
                            .foregroundStyle(printColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .padding(.horizontal, borderWidth)
                    .frame(height: bottomInset - 3)
                }
                .frame(height: bottomInset)
            }
            .padding(.top, topInset)
            .frame(width: size.width + borderWidth * 2,
                   height: size.height + topInset + bottomInset)
            .background(.black)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background(.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(metadataIdentifier)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func fittedImageSize(in available: CGSize) -> CGSize {
        let source = imageSize.flatMap { size in
            size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 ? size : nil
        } ?? CGSize(width: 4, height: 3)
        let scale = min(max(available.width - borderWidth * 2, 1) / source.width,
                        max(available.height - topInset - bottomInset, 1) / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    private func frameLabel(_ text: String, degrees: Double,
                            alignment: Alignment = .leading) -> some View {
        GeometryReader { geometry in
            Text(text)
                .font(NitrateTypography.font(size: 9).monospacedDigit())
                .foregroundStyle(printColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: max(geometry.size.height - 12, 0), height: 20, alignment: alignment)
                .rotationEffect(.degrees(degrees))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .frame(width: borderWidth)
        .allowsHitTesting(false)
    }
}

enum ContactPreviewPrinting {
    static func date(_ date: Date?) -> String {
        guard let date else { return "DATE —" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
#endif
