import ImageIO
import SwiftUI
import UIKit

/// One page inside History, above the same contact sheet. Reads only retained
/// app-owned output or its existing receipt image; never reads the Photos library.
struct HistoryInlinePreview: View {
    let job: RenderJob
    var isActive = true
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        ContactPreviewFrame(imageSize: previewSize, stockAndGauge: stockAndGauge,
                            exposure: captureExposure,
                            frameRate: job.presentsAsPhoto ? nil
                                : "\(ReceiptMetadataCards.frameRate(job.receipt?.framesPerSecond)) FPS",
                            date: ContactPreviewPrinting.date(job.receipt?.recordedAt ?? job.createdAt),
                            isVideo: !job.presentsAsPhoto,
                            metadataIdentifier: "history.contactMetadata") {
            previewImage
        }
    }

    private var previewSize: CGSize? {
        if let image { return image.size }
        if let jpeg = job.receipt?.thumbnailJPEG, let poster = UIImage(data: jpeg) {
            return poster.size
        }
        if let width = job.receipt?.pixelWidth, let height = job.receipt?.pixelHeight,
           width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }
        return nil
    }

    private var previewImage: some View {
        Group {
            if let image {
                HistoryZoomableImage(image: image,
                    label: job.presentsAsPhoto ? "Photo preview" : "Rendered video first frame")
            } else if isLoading {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Preview unavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .task(id: "\(job.id)-\(isActive)") {
            guard isActive, job.permitsReceiptPreview else {
                image = nil
                isLoading = false
                return
            }
            image = job.receipt?.thumbnailJPEG.flatMap { UIImage(data: $0) }
            isLoading = true
            if job.permitsLocalMedia, let url = job.retainedOutputURL {
                let frame: CGImage?
                if job.presentsAsPhoto {
                    frame = await Task.detached(priority: .userInitiated) {
                        Self.photo(at: url)
                    }.value
                } else {
                    frame = await RenderReceiptService.firstFrame(at: url)
                }
                guard !Task.isCancelled else { return }
                if let frame { image = UIImage(cgImage: frame) }
            }
            // Delivery can clean up a video while retaining its genuine rendered
            // first-frame receipt. Reuse it rather than trying to read Photos.
            if image == nil, let jpeg = job.receipt?.thumbnailJPEG {
                image = UIImage(data: jpeg)
            }
            isLoading = false
        }
        .onDisappear { image = nil }
    }

    private var stockAndGauge: String {
        let values = job.receipt?.metadata ?? [:]
        let stock = known(values["com.filmemulation.stock-name"]) ?? job.stockId
        let gauge = known(values["com.filmemulation.print-gauge"]) ?? job.printGauge?.displayName ?? "—"
        return "\(stock) · \(gauge)"
    }

    private var captureExposure: String {
        let values = job.receipt?.metadata ?? [:]
        let iso = ReceiptMetadataCards.captureISO(values, sourceISO: job.sourceCaptureISO)
        let shutter = known(values["com.filmemulation.shutter-speed"]) ?? "—"
        return "ISO \(iso) · \(shutter)"
    }

    private func known(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "unknown-or-not-recorded",
              value != QueueReceiptPresentation.unavailable else { return nil }
        return value
    }

    nonisolated private static func photo(at url: URL) -> CGImage? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ] as CFDictionary)
    }
}
