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
                HStack(spacing: 0) {
                    corner(details.format)
                    Spacer(minLength: 8)
                    corner(details.capture)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    corner(details.stock)
                    Spacer(minLength: 8)
                    corner(details.marking)
                }
            }

            HStack(spacing: 0) {
                vertical(details.edgeCode, flipped: false)
                Spacer(minLength: 0)
                vertical(details.frameCounter, flipped: true)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(version)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .padding(.horizontal, Self.cornerInset)
        .padding(.top, Self.topInset)
        .padding(.bottom, Self.versionInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func corner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(.white.opacity(0.34))
            .lineLimit(1)
    }

    /// Rotation does not change the reported layout size, so the frame is sized
    /// for the text's unrotated width and the rendered column stays narrow.
    private func vertical(_ text: String, flipped: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(.white.opacity(0.26))
            .lineLimit(1)
            .fixedSize()
            .rotationEffect(.degrees(flipped ? 90 : -90))
            .frame(width: 16, height: Self.verticalCodeHeight)
    }
}
