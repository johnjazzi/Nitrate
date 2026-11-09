#if os(iOS)
import SwiftUI

/// The one place the Develop panel explains itself.
///
/// The panel keeps a single short line on screen — a paragraph sitting in the
/// middle of a chooser is noise, and it is the first thing to push the buttons
/// off a small screen. Everything that needs reading lives here, including the
/// reason a picked file was refused, so the operator can find out why without
/// leaving for the documentation.
struct DevelopMediaHelp: View {
    /// The specific refusal to lead with, when the panel arrived here from one.
    var refusal: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let refusal {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DevelopPreviewChrome.orange)
                            Text(refusal)
                                .font(NitrateTypography.font(.callout))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DevelopPreviewChrome.orange.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("develop.help.refusal")
                    }

                    row("Video", "Apple Log 2 imports",
                        "Choose an original Apple Log 2 clip. Re-develop can also load supported "
                        + "retained Nitrate camera originals. Videos are reviewed as stills, not playback.")
                    row("Photo", "Raw files only",
                        "DNG (including ProRAW), NEF, ARW, CR2/CR3, RAF, ORF, RW2 — any raw "
                        + "this iPhone's decoder can open.")
                    row("If a raw is refused", "Check the copy",
                        "Photos can hand over a converted JPEG instead of the original. Turn on "
                        + "Settings → Photos → Keep Originals, then pick the file again.")
                    row("Review", "Choose the look before developing",
                        "Single files and batches use the same stock, gauge and push/pull controls. "
                        + "Swipe to review each file. Tap a still to enlarge it, pinch to zoom, "
                        + "or use Reset and Done.")
                    row("Exposure", "An estimate, not calibration",
                        "The center-weighted file estimate is relative to 18% scene-linear gray. "
                        + "It is not calibrated EV100 or an incident-light reading. Recorded ISO, "
                        + "capture metadata and saved meter offsets are shown separately when available. "
                        + "Auto stays neutral for imports; it does not use this estimate. A video "
                        + "still does not measure the entire take's highlight protection.")
                    row("Results", "Delivered stills and retained originals",
                        "Results show delivered files or their stored posters. Re-develop returns "
                        + "available originals to review without rendering immediately. Develop more "
                        + "returns to Photo and Video selection; it never deletes accepted jobs.")
                    row("Open Photos", "General library handoff",
                        "Open Photos does not select a specific new asset. Look in Recently Saved. "
                        + "A Saved label appears only after the queue confirms delivery.")
                    Text("Unsupported files are refused. Cancel releases unqueued app-owned copies; "
                         + "your library originals are never edited.")
                        .font(NitrateTypography.font(.caption))
                        .foregroundStyle(DevelopPreviewChrome.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .navigationTitle("What can I develop?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("develop.help.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(NitrateTypography.font(.subheadline))
                    .foregroundStyle(DevelopPreviewChrome.muted)
                Text(value)
                    .font(NitrateTypography.font(.subheadline))
                    .foregroundStyle(.white)
            }
            Text(detail)
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(DevelopPreviewChrome.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
