import SwiftUI

/// Settings → About: a real page, reached from the Settings "About" card.
///
/// The owner writes the human copy. The one section that already has its heading
/// fixed — "24 FPS vs 30 or 60 FPS" — carries its body in a single constant so
/// the edit point is obvious and no invented prose ships as a placeholder.
struct AboutView: View {
    /// The owner's copy for the frame-rate section. Left empty on purpose: the
    /// heading below is the visible anchor, and filling this string is the whole
    /// change needed to publish the text.
    static let frameRateSectionCopy: String? = nil

    /// Fixed heading for the frame-rate section. The user will write the words
    /// beneath it; the heading is not editorial prose of its own.
    static let frameRateSectionHeading = "24 FPS vs 30 or 60 FPS"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                introSection
                frameRateSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The same facts the Settings card used to print, plus the bundle-derived
    /// version line — the one row whose identifier Settings, tests and the splash
    /// all agree on.
    private var introSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nitrate")
                .font(NitrateTypography.font(.headline))

            VStack(alignment: .leading, spacing: 4) {
                Label("Film emulation for iPhone video", systemImage: "movieclapper")
                Label("Apple Log + Metal GPU pipeline", systemImage: "cpu")
                Label("Kodak 250D / 5207 & 500T / 5219", systemImage: "film")
                Label(AboutPresentation.versionLine(), systemImage: "number")
                    .accessibilityIdentifier(AboutPresentation.versionRowID)
            }
            .font(NitrateTypography.font(.caption))
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Heading only until the owner supplies the words.
    private var frameRateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.frameRateSectionHeading)
                .font(NitrateTypography.font(.headline))
                .accessibilityIdentifier("settings.about.frameRate")

            if let copy = Self.frameRateSectionCopy {
                Text(copy)
                    .font(NitrateTypography.font(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
