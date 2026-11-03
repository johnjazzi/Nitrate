import SwiftUI
import UIKit

extension RenderJob {
    var receiptActions: QueueReceiptPresentation.Actions {
        .init(savedToPhotos: outputSavedToPhotos == true || sourceSavedToPhotos == true,
              retainedOutput: permitsLocalMedia && retainedOutputURL != nil)
    }

    var receiptTitle: String {
        if isPhoto == true { return "Rendered photo" }
        if originalOnly == true { return "Original recording" }
        let name = QueueReceiptPresentation.metadata(receipt?.metadata ?? [:], "stock-name")
        if name != QueueReceiptPresentation.unavailable { return name }
        return status == .completed || receipt != nil ? "Rendered recording" : "Render job"
    }
}

/// Independent sibling controls: the image never wraps the metadata/play/share actions.
struct QueueReceiptCard: View {
    let job: RenderJob
    var prominent = false
    let openPhotos: () -> Void
    let showMetadata: () -> Void
    let playLocal: () -> Void
    let shareLocal: () -> Void
    /// Photo-only: re-develop from the retained original. Absent for video jobs.
    var redevelop: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if !job.permitsLocalMedia {
                    Image(systemName: "film").foregroundStyle(.secondary)
                } else if job.isPhoto == true, job.retainedOutputURL != nil {
                    Button(action: playLocal) { poster }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Preview rendered photo")
                        .accessibilityIdentifier("queue.photoPreview")
                } else if job.receiptActions.openPhotos {
                    Button(action: openPhotos) { poster }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Open Photos for saved recording")
                        .accessibilityHint("Opens Photos, not this specific video. Look in Recently Saved.")
                        .accessibilityIdentifier(QueueReceiptPresentation.photosActionID + ".thumbnail")
                } else {
                    poster.accessibilityLabel("Local thumbnail; Photos save not confirmed")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.receiptTitle).font(NitrateTypography.font(.headline))
                    Text(subtitle)
                        .font(NitrateTypography.font(.caption)).foregroundStyle(.secondary)
                    Text((job.receipt?.recordedAt ?? job.createdAt).formatted(date: .abbreviated, time: .shortened))
                        .font(NitrateTypography.font(.caption)).foregroundStyle(.secondary)
                    if job.outputSavedToPhotos == true {
                        Text("Rendered saved to Photos").font(NitrateTypography.font(.caption)).foregroundStyle(.secondary)
                    } else if job.sourceSavedToPhotos == true {
                        Text("Original saved to Photos").font(NitrateTypography.font(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { primaryActions }
                VStack(alignment: .leading) { primaryActions }
            }
            if job.receiptActions.playLocal || job.receiptActions.shareLocal {
                ViewThatFits(in: .horizontal) {
                    HStack { localActions }
                    VStack(alignment: .leading) { localActions }
                }
            }
            if let reason = job.retainedReason {
                Text("Kept original: \(reason)").font(NitrateTypography.font(.caption)).foregroundStyle(.secondary)
            }
            if let warning = job.cleanupWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(NitrateTypography.font(.caption)).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, prominent ? 8 : 4)
    }

    private var subtitle: String {
        if job.originalOnly == true { return "Original · no rendered look" }
        if job.status == .failed { return "Failed · retry available" }
        return job.isPhoto == true ? "Rendered photo" : "Rendered video"
    }

    private var poster: some View {
        Group {
            if job.permitsLocalMedia, let data = job.receipt?.thumbnailJPEG, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                    Text("No thumbnail").font(NitrateTypography.font(.caption2))
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: prominent ? 112 : 80, height: prominent ? 84 : 60)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .clipped()
    }

    @ViewBuilder private var primaryActions: some View {
        if job.receiptActions.openPhotos {
            Button(action: openPhotos) {
                Label("Open Photos", systemImage: "photo.on.rectangle")
                    .frame(minHeight: QueueReceiptPresentation.minimumActionHeight)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Opens Photos generally. Look in Recently Saved.")
            .accessibilityIdentifier(QueueReceiptPresentation.photosActionID)
        }
        Button(action: showMetadata) {
            Label("Metadata", systemImage: "info.circle")
                .frame(minHeight: QueueReceiptPresentation.minimumActionHeight)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Metadata for \(job.receiptTitle)")
        .accessibilityIdentifier(QueueReceiptPresentation.metadataActionID)
    }

    @ViewBuilder private var localActions: some View {
        if job.receiptActions.playLocal {
            Button(action: playLocal) {
                Label(job.isPhoto == true ? "Preview photo" : "Play local copy", systemImage: job.isPhoto == true ? "photo" : "play.circle").frame(minHeight: 44)
            }.buttonStyle(.borderless)
        }
        if job.receiptActions.shareLocal {
            Button(action: shareLocal) {
                Label("Share local copy", systemImage: "square.and.arrow.up").frame(minHeight: 44)
            }.buttonStyle(.borderless)
        }
        if job.hasRedevelopableOriginal, let redevelop {
            Button(action: redevelop) {
                Label("Re-render photo", systemImage: "arrow.clockwise").frame(minHeight: 44)
            }.buttonStyle(.borderless)
            .accessibilityHint("Develops the photo again from the saved original.")
            .accessibilityIdentifier("queue.redevelopPhoto")
        }
    }
}

struct QueueReceiptMetadataView: View {
    let job: RenderJob
    @Environment(\.dismiss) private var dismiss

    private var receipt: RenderReceipt? { job.receipt }
    private var metadata: [String: String] { receipt?.metadata ?? [:] }

    var body: some View {
        NavigationStack {
            MetadataCardsView(cards: ReceiptMetadataCards.make(job: job),
                              details: recordDetails)
                .navigationTitle("Metadata")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    /// The recipe and delivery evidence that used to be the whole sheet. It now
    /// sits collapsed beneath the cards rather than replacing them.
    private var recordDetails: [(label: String, value: String)] {
        var details: [(label: String, value: String)] = [
            ("Stock", value("stock-name")),
            ("Selected render ISO", QueueReceiptPresentation.numericMetadata(metadata, "iso")),
            ("Print gauge", value("print-gauge")),
            ("Push / pull", ReceiptMetadataCards.pushPullValue(metadata, job: job)),
            ("Recipe version", value("recipe-version")),
            ("Halation level", QueueReceiptPresentation.numericMetadata(metadata, "halation-level")),
            ("Glow level", QueueReceiptPresentation.numericMetadata(metadata, "glow-level")),
            ("Grain size", QueueReceiptPresentation.numericMetadata(metadata, "grain-size")),
            ("Light type", value("light-type")),
            ("Duration", QueueReceiptPresentation.number(receipt?.durationSeconds, suffix: " s")),
            ("Render elapsed", QueueReceiptPresentation.number(receipt?.renderDurationSeconds, suffix: " s")),
            ("Rendered in Photos", QueueReceiptPresentation.savedStatus(job.outputSavedToPhotos)),
            ("Original in Photos", QueueReceiptPresentation.savedStatus(job.sourceSavedToPhotos)),
            ("Local media cleanup", cleanupStatus),
            ("Recorded timestamp", receipt.map {
                $0.recordedAt.formatted(date: .complete, time: .complete)
            } ?? QueueReceiptPresentation.unavailable),
            ("App version", QueueReceiptPresentation.text(receipt?.appVersion)),
            ("App build", QueueReceiptPresentation.text(receipt?.appBuild))
        ]
        if let warning = job.cleanupWarning { details.append(("Cleanup warning", warning)) }
        return details
    }

    private func value(_ suffix: String) -> String { QueueReceiptPresentation.metadata(metadata, suffix) }

    private var cleanupStatus: String {
        switch job.mediaCleanupCompleted {
        case true: "Completed — full-resolution app copies removed"
        case false: "Not completed — local media may be retained for delivery or retry"
        case nil: "Unknown (legacy record)"
        }
    }
}
