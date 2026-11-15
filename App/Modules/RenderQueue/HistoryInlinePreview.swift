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
        GeometryReader { geometry in
            let size = fittedImageSize(in: geometry.size)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    frameLabel(stockAndGauge, degrees: -90)
                    previewImage
                        .frame(width: size.width, height: size.height)
                        .clipped()
                    ZStack {
                        frameLabel(captureExposure, degrees: 90)
                        if !job.presentsAsPhoto {
                            frameLabel("\(ReceiptMetadataCards.frameRate(job.receipt?.framesPerSecond)) FPS",
                                       degrees: 90, alignment: .trailing)
                        }
                    }
                    .frame(width: 24)
                }
                .frame(height: size.height)
                HStack {
                    Spacer(minLength: 0)
                    Text(recordedDateAndTime)
                        .font(NitrateTypography.font(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 24)
                .frame(height: 24)
            }
            .padding(.top, 10)
            .frame(width: size.width + 48, height: size.height + 34)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background(.black)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func fittedImageSize(in available: CGSize) -> CGSize {
        let source: CGSize
        if let image {
            source = image.size
        } else if let jpeg = job.receipt?.thumbnailJPEG, let poster = UIImage(data: jpeg) {
            source = poster.size
        } else if let width = job.receipt?.pixelWidth, let height = job.receipt?.pixelHeight,
                  width > 0, height > 0 {
            source = CGSize(width: width, height: height)
        } else {
            source = CGSize(width: 4, height: 3)
        }
        let width = max(available.width - 48, 1)
        let height = max(available.height - 34, 1)
        let scale = min(width / source.width, height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
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
            guard isActive, job.permitsLocalMedia else {
                image = nil
                isLoading = false
                return
            }
            image = job.receipt?.thumbnailJPEG.flatMap { UIImage(data: $0) }
            isLoading = true
            if let url = job.retainedOutputURL {
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

    private func frameLabel(_ text: String, degrees: Double,
                            alignment: Alignment = .leading) -> some View {
        GeometryReader { geometry in
            Text(text)
                .font(NitrateTypography.font(size: 9))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: max(geometry.size.height - 12, 0), height: 20, alignment: alignment)
                .rotationEffect(.degrees(degrees))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .frame(width: 24)
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

    private var recordedDateAndTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: job.receipt?.recordedAt ?? job.createdAt)
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
