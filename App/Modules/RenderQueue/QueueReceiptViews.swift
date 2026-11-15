import SwiftUI
import UIKit

extension RenderJob {
    var receiptActions: QueueReceiptPresentation.Actions {
        .init(savedToPhotos: outputSavedToPhotos == true || sourceSavedToPhotos == true,
              retainedOutput: permitsLocalMedia && retainedOutputURL != nil)
    }

    var receiptTitle: String {
        if presentsAsPhoto { return "Rendered photo" }
        if originalOnly == true { return "Original recording" }
        let name = QueueReceiptPresentation.metadata(receipt?.metadata ?? [:], "stock-name")
        if name != QueueReceiptPresentation.unavailable { return name }
        return status == .completed || receipt != nil ? "Rendered recording" : "Render job"
    }
}

/// Independent sibling controls: the image never wraps the metadata/play/share actions.
///
/// `contactSheet` is the History sheet's presentation of the same receipt: one
/// 4:3 poster with its stock/ISO/date line underneath and no inline buttons, so
/// three or more cells fit across a phone. It reuses the same persisted
/// `receipt.thumbnailJPEG` path as the regular row and adds no thumbnail store.
/// The default keeps every existing usage exactly as it was.
struct QueueReceiptCard: View {
    let job: RenderJob
    let openPhotos: () -> Void
    let showMetadata: () -> Void
    let playLocal: () -> Void
    let shareLocal: () -> Void
    /// Return a retained photo or video original to the shared Develop review.
    var redevelop: (() -> Void)? = nil
    /// History contact-sheet cell: poster first, metadata outside the frame.
    var contactSheet = false

    var body: some View {
        if contactSheet { contactSheetCell } else { row }
    }

    // MARK: - Regular row (unchanged usage)

    private var row: some View {
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

    // MARK: - Contact-sheet cell

    private var contactSheetCell: some View {
        contactPoster
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("queue.receiptCard")
            .accessibilityLabel(contactTitle)
            .accessibilityValue(contactMetadataLine)
    }

    /// Crop only the displayed poster, never the retained media. Explicit bounds
    /// prevent a portrait image's ideal size from escaping the landscape cell.
    private var contactPoster: some View {
        Rectangle()
            .fill(.black)
            .aspectRatio(QueueContactSheetLayout.cellAspect, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    contactPosterContent
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
            .clipped()
            .padding(6)
            .background(.black)
            .overlay(alignment: .bottom) {
                if !job.presentsAsPhoto {
                    QueueFrameStripBorder()
                        .padding(.horizontal, 6)
                        .padding(.bottom, 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                contactStatusMark
            }
    }

    /// A quiet corner mark for anything that is not a finished render. The
    /// poster is the subject; status stays legible without a caption row.
    @ViewBuilder private var contactStatusMark: some View {
        switch job.status {
        case .completed:
            EmptyView()
        case .failed:
            contactMarkSymbol("exclamationmark", color: .red, label: "Failed")
        case .pending:
            contactMarkSymbol("clock", color: .white, label: "Pending")
        case .processing:
            contactMarkSymbol("arrow.triangle.2.circlepath", color: .white, label: "Processing")
        case .awaitingStock:
            contactMarkSymbol("film", color: .white, label: "Awaiting stock")
        }
    }

    private func contactMarkSymbol(_ symbol: String, color: Color, label: String) -> some View {
        Image(systemName: symbol)
            .font(NitrateTypography.font(.caption2))
            .foregroundStyle(color)
            .padding(4)
            .background(.black.opacity(0.6), in: Circle())
            .padding(3)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var contactPosterContent: some View {
        if job.permitsLocalMedia, let data = job.receipt?.thumbnailJPEG {
            HistoryGridThumbnail(jpeg: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("No preview")
        }
    }

    /// Stock/record name; the same wording the regular card and metadata use.
    private var contactTitle: String { job.receiptTitle }

    /// Selected ISO and the recorded (or queued) day, outside the poster frame.
    private var contactMetadataLine: String {
        let iso = QueueReceiptPresentation.number(Double(job.iso))
        let day = (job.receipt?.recordedAt ?? job.createdAt)
            .formatted(.dateTime.day().month(.abbreviated))
        return "ISO \(iso) · \(day)"
    }


    @ViewBuilder private var posterControl: some View {
        if !job.permitsLocalMedia {
            poster
        } else if job.presentsAsPhoto, job.retainedOutputURL != nil {
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
                Label(job.presentsAsPhoto ? "Preview" : "Play",
                      systemImage: job.presentsAsPhoto ? "photo" : "play.circle")
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
            .accessibilityIdentifier(job.presentsAsPhoto ? "queue.redevelopPhoto" : "queue.redevelopVideo")
        }
    }
}

/// Narrow alternating black/white strip along a video poster's edge.
///
/// It reads as a film edge — a media-type cue only. Status stays in the cell's
/// spoken value and its own marks, so the strip is never the sole signal and is
/// hidden from VoiceOver.
struct QueueFrameStripBorder: View {
    var height: CGFloat = 3
    var segmentWidth: CGFloat = 7

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            var isBlack = true
            while x < size.width {
                let width = min(segmentWidth, size.width - x)
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                             with: .color(isBlack ? .black : .white))
                x += width
                isBlack.toggle()
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct QueueReceiptMetadataView: View {
    let job: RenderJob
    var retry: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private var receipt: RenderReceipt? { job.receipt }
    private var metadata: [String: String] { receipt?.metadata ?? [:] }

    var body: some View {
        NavigationStack {
            MetadataCardsView(cards: ReceiptMetadataCards.make(job: job),
                              details: recordDetails)
                .navigationTitle("Metadata")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if let retry {
                            Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
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
