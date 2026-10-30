import SwiftUI

/// Determinate only when a genuine, finite rendering fraction is available.
///
/// Saving and queued states are indeterminate: the overlay never invents a
/// percentage for work whose progress the renderer does not report.
struct DevelopProgressPresentation: Equatable, Sendable {
    let caption: String
    /// Non-nil only for a genuine rendering fraction in `0...1`.
    let fraction: Double?

    var isDeterminate: Bool { fraction != nil }

    init(progress: RenderJobProgress?, queued: Bool) {
        guard !queued else {
            caption = "Queued to render"
            fraction = nil
            return
        }
        switch progress?.phase {
        case .rendering:
            if let value = progress?.fractionComplete, value.isFinite {
                let clamped = min(max(value, 0), 1)
                fraction = clamped
                caption = "Rendering… \(Int((clamped * 100).rounded()))%"
            } else {
                fraction = nil
                caption = "Rendering…"
            }
        case .saving:
            caption = "Saving to Photos…"
            fraction = nil
        case nil:
            caption = "Preparing…"
            fraction = nil
        }
    }
}

/// Full-frame dark cover shown over the entire supplied preview frame while a
/// render job is pending or processing. Rendering shows the real fraction;
/// saving and queued states show an indeterminate spinner.
///
/// Platform-neutral SwiftUI so a macOS `ImageRenderer` test can verify that the
/// cover fills every corner of the frame it is given.
struct DevelopProgressOverlay: View {
    let progress: RenderJobProgress?
    let queued: Bool

    private var presentation: DevelopProgressPresentation {
        DevelopProgressPresentation(progress: progress, queued: queued)
    }

    /// Coverage of the whole supplied frame; asserted opaque at every corner by
    /// the macOS render test.
    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 14) {
                if let fraction = presentation.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(SettingsControlChrome.halationOrange)
                        .frame(maxWidth: 220)
                } else {
                    ProgressView()
                        .tint(SettingsControlChrome.halationOrange)
                }
                Text(presentation.caption)
                    .font(NitrateTypography.font(.callout))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("develop.progress")
    }
}
