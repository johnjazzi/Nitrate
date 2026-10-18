import SwiftUI
import UIKit

extension RenderJob {
    var retainedOutputURL: URL? {
        guard let outputURL, outputURL.isFileURL,
              let values = try? outputURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
        return outputURL
    }

    var receiptActions: QueueReceiptPresentation.Actions {
        .init(savedToPhotos: outputSavedToPhotos == true || sourceSavedToPhotos == true,
              retainedOutput: retainedOutputURL != nil)
    }

    var receiptTitle: String {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if job.receiptActions.openPhotos {
                    Button(action: openPhotos) { poster }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Open Photos for saved recording")
                        .accessibilityHint("Opens Photos, not this specific video. Look in Recently Saved.")
                        .accessibilityIdentifier(QueueReceiptPresentation.photosActionID + ".thumbnail")
                } else {
                    poster.accessibilityLabel("Local thumbnail; Photos save not confirmed")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.receiptTitle).font(.headline)
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                    Text((job.receipt?.recordedAt ?? job.createdAt).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    if job.outputSavedToPhotos == true {
                        Text("Rendered saved to Photos").font(.caption).foregroundStyle(.secondary)
                    } else if job.sourceSavedToPhotos == true {
                        Text("Original saved to Photos").font(.caption).foregroundStyle(.secondary)
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
                Text("Kept original: \(reason)").font(.caption).foregroundStyle(.secondary)
            }
            if let warning = job.cleanupWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, prominent ? 8 : 4)
    }

    private var subtitle: String {
        if job.originalOnly == true { return "Original · no rendered look" }
        if job.status == .failed { return "Failed · retry available" }
        return "Rendered video"
    }

    private var poster: some View {
        Group {
            if let data = job.receipt?.thumbnailJPEG, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                    Text("No thumbnail").font(.caption2)
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
                Label("Play local copy", systemImage: "play.circle").frame(minHeight: 44)
            }.buttonStyle(.borderless)
        }
        if job.receiptActions.shareLocal {
            Button(action: shareLocal) {
                Label("Share local copy", systemImage: "square.and.arrow.up").frame(minHeight: 44)
            }.buttonStyle(.borderless)
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
            List {
                Section("Rendered file") {
                    detail("Stock", value("stock-name"))
                    detail("Selected render ISO", QueueReceiptPresentation.numericMetadata(metadata, "iso"))
                    detail("ISO role", value("iso-role"))
                    detail("Print gauge", value("print-gauge"))
                    detail("Resolution", resolution)
                    detail("Frame rate", QueueReceiptPresentation.number(receipt?.framesPerSecond, suffix: " fps"))
                    detail("Duration", QueueReceiptPresentation.number(receipt?.durationSeconds, suffix: " s"))
                    detail("Codec / fourcc", QueueReceiptPresentation.text(receipt?.codec))
                    detail("Actual file size", fileSize)
                    detail("Encoding bitrate target (not measured)", bitrateTarget)
                }
                Section("Render record") {
                    detail("Render elapsed", QueueReceiptPresentation.number(receipt?.renderDurationSeconds, suffix: " s"))
                    detail("Recipe version", value("recipe-version"))
                    detail("Halation level", QueueReceiptPresentation.numericMetadata(metadata, "halation-level"))
                    detail("Glow level", QueueReceiptPresentation.numericMetadata(metadata, "glow-level"))
                    detail("Grain size", QueueReceiptPresentation.numericMetadata(metadata, "grain-size"))
                    detail("Light type", value("light-type"))
                    detail("Recorded timestamp", receipt.map {
                        $0.recordedAt.formatted(date: .complete, time: .complete)
                    } ?? QueueReceiptPresentation.unavailable)
                    detail("App version", QueueReceiptPresentation.text(receipt?.appVersion))
                    detail("App build", QueueReceiptPresentation.text(receipt?.appBuild))
                }
                Section("Delivery & local storage") {
                    detail("Rendered video in Photos", QueueReceiptPresentation.savedStatus(job.outputSavedToPhotos))
                    detail("Original in Photos", QueueReceiptPresentation.savedStatus(job.sourceSavedToPhotos))
                    detail("Local media cleanup", cleanupStatus)
                    if let warning = job.cleanupWarning { detail("Cleanup warning", warning) }
                    Text("Photos owns saved full-resolution videos. Open Photos and look in Recently Saved; this app does not read your photo library.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Queued settings") {
                    detail("Stock identifier", QueueReceiptPresentation.text(job.stockId))
                    detail("Print gauge", QueueReceiptPresentation.text(job.printGauge?.rawValue))
                    detail("Selected render ISO", QueueReceiptPresentation.number(Double(job.iso)))
                    Text("Queued settings are not measured capture ISO or proof of the delivered file's contents. Unavailable details were not recorded; they are not filled from today's stock catalog.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func value(_ suffix: String) -> String { QueueReceiptPresentation.metadata(metadata, suffix) }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body).textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }

    private var resolution: String {
        guard let width = receipt?.pixelWidth, let height = receipt?.pixelHeight,
              width > 0, height > 0 else { return QueueReceiptPresentation.unavailable }
        return "\(width) × \(height)"
    }

    private var fileSize: String {
        guard let bytes = receipt?.fileSizeBytes, bytes >= 0 else { return QueueReceiptPresentation.unavailable }
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) (\(bytes) bytes)"
    }

    private var bitrateTarget: String {
        guard let raw = metadata["com.filmemulation.encoding-bitrate-target"],
              let bits = Double(raw), bits.isFinite, bits > 0 else { return QueueReceiptPresentation.unavailable }
        return QueueReceiptPresentation.number(bits, suffix: " bit/s target")
    }

    private var cleanupStatus: String {
        switch job.mediaCleanupCompleted {
        case true: "Completed — full-resolution app copies removed"
        case false: "Not completed — local media may be retained for delivery or retry"
        case nil: "Unknown (legacy record)"
        }
    }
}
