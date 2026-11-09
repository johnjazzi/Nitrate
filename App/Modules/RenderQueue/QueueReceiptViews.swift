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
    let openPhotos: () -> Void
    let showMetadata: () -> Void
    let playLocal: () -> Void
    let shareLocal: () -> Void
    /// Return a retained photo or video original to the shared Develop review.
    var redevelop: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            posterControl
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Image(systemName: statusSymbol)
                        .font(NitrateTypography.font(.subheadline))
                        .foregroundStyle(statusColor)
                        .accessibilityLabel(statusDescription)
                    if job.retainedReason != nil || job.cleanupWarning != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(NitrateTypography.font(.caption))
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Warning; open details")
                    }
                    if job.receiptActions.playLocal || job.receiptActions.shareLocal {
                        Menu { localActions } label: {
                            Label("More", systemImage: "ellipsis")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityIdentifier("queue.more")
                    }
                }
                .frame(height: 44)
                HStack(spacing: 0) {
                    primaryActions
                    redevelopmentAction
                }
            }
            .frame(minWidth: 132, maxWidth: .infinity, alignment: .trailing)
        }
        .labelStyle(.iconOnly)
        .font(NitrateTypography.font(.title3))
        .tint(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.receiptCard")
        .accessibilityLabel(job.receiptTitle)
        .accessibilityValue((job.receipt?.recordedAt ?? job.createdAt)
            .formatted(date: .abbreviated, time: .shortened))
    }

    @ViewBuilder private var posterControl: some View {
        if !job.permitsLocalMedia {
            poster
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
    }

    private var statusSymbol: String {
        switch job.status {
        case .failed: "exclamationmark.circle.fill"
        case .pending: "clock"
        case .processing: "arrow.triangle.2.circlepath"
        case .awaitingStock: "film"
        case .completed:
            job.outputSavedToPhotos == true ? "checkmark.circle.fill"
                : (job.sourceSavedToPhotos == true ? "doc.badge.checkmark" : "internaldrive")
        }
    }

    private var statusColor: Color {
        if job.status == .failed { return .red }
        return job.outputSavedToPhotos == true ? .green : .secondary
    }

    private var statusDescription: String {
        if job.status == .failed { return "Failed; open details" }
        if job.outputSavedToPhotos == true { return "Rendered output saved to Photos" }
        if job.sourceSavedToPhotos == true { return "Original saved to Photos; output save unconfirmed" }
        return "Local media; Photos save unconfirmed"
    }

    private var poster: some View {
        Group {
            if job.permitsLocalMedia, let data = job.receipt?.thumbnailJPEG, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                    Text("No preview")
                        .font(NitrateTypography.font(.caption))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 80, maxWidth: 136, minHeight: 104, maxHeight: 104)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        .clipped()
    }

    @ViewBuilder private var primaryActions: some View {
        if job.receiptActions.openPhotos {
            Button(action: openPhotos) {
                Label("Open Photos", systemImage: "photo.on.rectangle")
                    .frame(width: 44, height: QueueReceiptPresentation.minimumActionHeight)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Opens Photos generally. Look in Recently Saved.")
            .accessibilityIdentifier(QueueReceiptPresentation.photosActionID)
        }
        Button(action: showMetadata) {
            Label("Metadata", systemImage: "info.circle")
                .frame(width: 44, height: QueueReceiptPresentation.minimumActionHeight)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Metadata for \(job.receiptTitle)")
        .accessibilityIdentifier(QueueReceiptPresentation.metadataActionID)
    }

    @ViewBuilder private var localActions: some View {
        if job.receiptActions.playLocal {
            Button(action: playLocal) {
                Label(job.isPhoto == true ? "Preview" : "Play",
                      systemImage: job.isPhoto == true ? "photo" : "play.circle")
            }
        }
        if job.receiptActions.shareLocal {
            Button(action: shareLocal) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder private var redevelopmentAction: some View {
        if job.hasRedevelopableSource, let redevelop {
            Button(action: redevelop) {
                Label("Re-develop", systemImage: "arrow.counterclockwise")
                    .frame(width: 44, height: 44)
            }.buttonStyle(.borderless)
            .accessibilityHint("Returns the original to Develop for preview, gauge and push/pull before rendering.")
            .accessibilityIdentifier(job.isPhoto == true ? "queue.redevelopPhoto" : "queue.redevelopVideo")
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
            ("Record", job.receiptTitle),
            ("Queued", job.createdAt.formatted(date: .abbreviated, time: .shortened)),
            ("Stock", value("stock-name") == QueueReceiptPresentation.unavailable
                ? QueueReceiptPresentation.text(job.stockId) : value("stock-name")),
            ("Selected render ISO", metadata.isEmpty
                ? QueueReceiptPresentation.number(Double(job.iso))
                : QueueReceiptPresentation.numericMetadata(metadata, "iso")),
            ("Print gauge", value("print-gauge")),
            ("Diffusion", ReceiptMetadataCards.diffusionValue(metadata, job: job)),
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
            ("App build", QueueReceiptPresentation.text(receipt?.appBuild)),
            // Technical record the compact cards have no room for.
            ("Delivered codec", QueueReceiptPresentation.text(receipt?.codec)),
            ("Delivered resolution", deliveredResolution),
            ("Delivered frame rate", QueueReceiptPresentation.number(receipt?.framesPerSecond, suffix: " fps")),
            ("Delivered file size", QueueReceiptPresentation.number(
                receipt?.fileSizeBytes.map { Double($0) / 1_048_576.0 }, suffix: " MB")),
            ("Colour space", value("color-space")),
            ("White balance", QueueReceiptPresentation.numericMetadata(metadata, "white-balance-kelvin")),
            ("WB tint", QueueReceiptPresentation.numericMetadata(metadata, "wb-tint")),
            ("Reel", value("reel")),
            ("Scene", value("scene")),
            ("Take", value("take")),
            ("Capture policy", capturePolicyValue),
            ("Job id", job.id.uuidString)
        ]
        if let reason = job.retainedReason { details.append(("Kept original", reason)) }
        if let error = job.errorMessage { details.append(("Error", error)) }
        if let warning = job.cleanupWarning { details.append(("Cleanup warning", warning)) }
        return details
    }

    private func value(_ suffix: String) -> String { QueueReceiptPresentation.metadata(metadata, suffix) }

    private var deliveredResolution: String {
        guard let width = receipt?.pixelWidth, let height = receipt?.pixelHeight else {
            return QueueReceiptPresentation.unavailable
        }
        return "\(width) × \(height)"
    }

    private var capturePolicyValue: String {
        guard let policy = job.capturePolicy else { return QueueReceiptPresentation.unavailable }
        return "\(policy.frameRate) fps, 1/\(policy.shutterDenominator), \(policy.grainPairing)"
    }

    private var cleanupStatus: String {
        switch job.mediaCleanupCompleted {
        case true: "Completed — full-resolution app copies removed"
        case false: "Not completed — local media may be retained for delivery or retry"
        case nil: "Unknown (legacy record)"
        }
    }
}
