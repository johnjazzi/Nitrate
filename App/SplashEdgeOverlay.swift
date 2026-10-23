import SwiftUI

/// Film-edge markings framing the launch splash, with the version along the
/// bottom edge. Static by design: edge markings are baked into the film rather
/// than animated in.
struct SplashEdgeOverlay: View {
    let details: SplashEdgeDetails
    let version: String

    private static let cornerInset: CGFloat = 22
    private static let topInset: CGFloat = 12
    private static let versionInset: CGFloat = 10
    private static let verticalCodeHeight: CGFloat = 200

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                cornerPair(details.format, details.capture)
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    cornerPair(details.stock, details.marking)
                    Text(version)
                        .font(NitrateTypography.font(size: 10))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.42))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 0) {
                vertical(details.edgeCode, flipped: false)
                Spacer(minLength: 0)
                vertical(details.frameCounter, flipped: true)
            }
        }
        .padding(.horizontal, Self.cornerInset)
        .padding(.top, Self.topInset)
        .padding(.bottom, Self.versionInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Try both full labels on one line before giving each its own wrapping row.
    /// Fixed-size candidates prevent truncation from falsely reporting a fit.
    private func cornerPair(_ leading: String, _ trailing: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                corner(leading).fixedSize()
                Spacer(minLength: 8)
                corner(trailing).fixedSize()
            }
            VStack(spacing: 6) {
                corner(leading)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                corner(trailing)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func corner(_ text: String) -> some View {
        Text(text)
            .font(NitrateTypography.font(size: 9))
            .tracking(1.6)
            .foregroundStyle(.white.opacity(0.34))
    }

    /// Rotation does not change the reported layout size, so the frame is sized
    /// for the text's unrotated width and the rendered column stays narrow.
    private func vertical(_ text: String, flipped: Bool) -> some View {
        Text(text)
            .font(NitrateTypography.font(size: 9))
            .tracking(1.6)
            .foregroundStyle(.white.opacity(0.26))
            .lineLimit(1)
            .fixedSize()
            .rotationEffect(.degrees(flipped ? 90 : -90))
            .frame(width: 16, height: Self.verticalCodeHeight)
    }
}
