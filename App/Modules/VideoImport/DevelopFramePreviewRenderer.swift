import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal

struct DevelopFramePreview: Sendable {
    let image: CGImage
    let measuredOffsetEV: Double?
    let captureDescription: String?
}

/// One surface owns one actor. All decode/grade work is off the main actor;
/// only bounded decoded sources (three files) are cached, never exported files.
/// A newer request fences an older suspended load, even if its caller forgot to cancel.
actor DevelopFramePreviewRenderer {
    static let maximumDimension = 960
    static let exposureEstimateDescription = "Center-weighted file exposure estimate relative to 18% gray; not calibrated EV100. Video measures one frame, not the full take."

    private struct SourceKey: Hashable {
        let url: URL
        let isPhoto: Bool
        let size: Int?
        let modified: Date?
    }
    private struct WhiteBalance: Hashable {
        let temperature: Float
        let tint: Float
    }
    private final class PhotoSource {
        let decoder: RAWPhotoDecoder
        var decodes: [WhiteBalance: RAWPhotoDecoder.Decoded]
        let measurement: Double?
        let description: String?

        init(decoder: RAWPhotoDecoder, balance: WhiteBalance, decoded: RAWPhotoDecoder.Decoded,
             measurement: Double?, description: String?) {
            self.decoder = decoder
            self.decodes = [balance: decoded]
            self.measurement = measurement
            self.description = description
        }
    }
    private struct VideoSource {
        let buffer: CVPixelBuffer
        let transform: CGAffineTransform
        let measurement: Double?
        let description: String?
    }
    private enum Source {
        case photo(PhotoSource)
        case video(VideoSource)
    }

    private let bundle: Bundle
    private var cache: [SourceKey: Source] = [:]
    private var recency: [SourceKey] = []
    private var latestRequest = UUID()
    private var colorResources: DevelopColorPreviewResources?

    private func resources() throws -> DevelopColorPreviewResources {
        if let colorResources { return colorResources }
        let resources = try DevelopColorPreviewResources(bundle: bundle)
        colorResources = resources
        return resources
    }

    init(bundle: Bundle = .main) { self.bundle = bundle }

    func preview(url: URL, isPhoto: Bool, stock: FilmStockConfig, gauge: PrintGauge,
                 pushPull: PushPullExposure, cropZoom: Double = 1) async throws -> DevelopFramePreview {
        let request = UUID()
        latestRequest = request
        do {
            try check(request)
            guard url.isFileURL, cropZoom.isFinite, cropZoom >= 1 else { throw PreviewError.invalidSource }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw PreviewError.invalidSource }
            let key = SourceKey(url: url, isPhoto: isPhoto, size: values.fileSize, modified: values.contentModificationDate)
            let source: Source
            if let existing = cache[key] {
                source = existing
            } else if isPhoto {
                source = .photo(try loadPhoto(url))
            } else {
                source = .video(try await loadVideo(url))
            }
            try check(request)
            cache[key] = source
            recency.removeAll { $0 == key }
            recency.append(key)
            while recency.count > 3 { cache.removeValue(forKey: recency.removeFirst()) }

            let result: DevelopFramePreview
            switch source {
            case .photo(let photo):
                // Delivery uses the stock temperature with zero tint. The file
                // meter uses its own as-shot WB and is cached separately, so
                // neither a stock change nor gauge/push/pull rewrites the reading.
                let balance = WhiteBalance(temperature: stock.colorTemperature, tint: 0)
                let decoded: RAWPhotoDecoder.Decoded
                if let existing = photo.decodes[balance] {
                    decoded = existing
                } else {
                    decoded = try photo.decoder.decode(url: url, temperature: balance.temperature,
                                                       maximumDimension: Self.maximumDimension)
                    if photo.decodes.count >= 2 { photo.decodes.removeAll() }
                    photo.decodes[balance] = decoded
                }
                result = try renderPhoto(decoded, stock: stock, gauge: gauge, pushPull: pushPull,
                                         cropZoom: cropZoom, measurement: photo.measurement,
                                         captureDescription: photo.description)
            case .video(let video):
                result = try renderVideo(video.buffer, transform: video.transform, stock: stock,
                                         gauge: gauge, pushPull: pushPull, cropZoom: cropZoom,
                                         measurement: video.measurement, captureDescription: video.description)
            }
            try check(request)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PreviewError {
            try check(request)
            throw error
        } catch {
            try check(request)
            throw PreviewError.failed(error.localizedDescription)
        }
    }

    private func check(_ request: UUID) throws {
        try Task.checkCancellation()
        guard request == latestRequest else { throw CancellationError() }
    }

    private func loadPhoto(_ url: URL) throws -> PhotoSource {
        let color = try resources()
        guard let raw = CIRAWFilter(imageURL: url) else { throw PreviewError.decode }
        let balance = WhiteBalance(temperature: raw.neutralTemperature, tint: raw.neutralTint)
        let decoder = try RAWPhotoDecoder(device: color.device, queue: color.queue)
        let decoded = try decoder.decode(url: url, temperature: balance.temperature, tint: balance.tint,
                                         maximumDimension: Self.maximumDimension)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let frozen = CIImage(mtlTexture: decoded.texture, options: [.colorSpace: space]) else { throw PreviewError.decode }
        let reading = Self.measurePhoto(frozen, exposureEV: decoded.exposureEV)
        return PhotoSource(decoder: decoder, balance: balance, decoded: decoded, measurement: reading,
                           description: Self.captureDescription(PhotoDeliveryMetadata.capture(fromDNG: url)))
    }

    /// Production photo stages, also exercised directly with spatial numerical
    /// fixtures. CIRAWFilter already applied EXIF; do NOT rotate this again.
    func renderPhoto(_ decoded: RAWPhotoDecoder.Decoded, stock: FilmStockConfig, gauge: PrintGauge,
                     pushPull: PushPullExposure, cropZoom: Double = 1, measurement: Double?,
                     captureDescription: String?) throws -> DevelopFramePreview {
        try Task.checkCancellation()
        let color = try resources()
        // The texture is the materialized bounded decode. Reusing the lazy RAW
        // CIImage here would silently demosaic the file again on every control.
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let frozen = CIImage(mtlTexture: decoded.texture, options: [.colorSpace: space]),
              let crop = PhotoZoomGeometry.centeredCrop(in: frozen.extent, zoom: cropZoom) else {
            throw PreviewError.invalidSource
        }
        let image = Self.normalized(frozen.cropped(to: crop))
        let prepared = try RAWToLog2Stage.apply(image)
        let finished = try color.grade(color.materialize(prepared), stock: stock, pushPull: pushPull,
                                       ceiling: SpatialEffectsStage.halationCeiling(
                                        sceneLiftStops: decoded.sceneLiftStops, headroom: decoded.halationHeadroom))
        try Task.checkCancellation()
        return DevelopFramePreview(image: try FilmOutputDisplayConverter.makeSRGBImage(fromGamma24: finished),
                                   measuredOffsetEV: measurement, captureDescription: captureDescription)
    }

    private func loadVideo(_ url: URL) async throws -> VideoSource {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PreviewError.decode }
        let descriptions = try await track.load(.formatDescriptions)
        let profile = try Self.sourceProfile(descriptions)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration).seconds
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 16_384, size.height <= 16_384, duration.isFinite, duration > 0 else {
            throw PreviewError.invalidSource
        }
        let scale = min(1, CGFloat(Self.maximumDimension) / max(size.width, size.height))
        let width = max(2, Int(size.width * scale) / 2 * 2)
        let height = max(2, Int(size.height * scale) / 2 * 2)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: profile == .hlgBT2020
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            AVVideoAllowWideColorKey: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw PreviewError.decode }
        let provider = reader.outputProvider(for: output)
        // Decode the first available still rather than seeking through a long take.
        reader.timeRange = CMTimeRange(start: .zero,
            duration: CMTime(seconds: min(duration, 1), preferredTimescale: 600))
        guard reader.startReading() else { throw PreviewError.decode }
        let cancellation = RenderCancellationHandle(writer: nil, videoReader: reader, audioReader: nil)
        defer { cancellation.cancel() }
        let providerBox = ReadProviderBox(provider)
        let sampleBox = SampleBox<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?>()
        // Reuse the queue renderer's explicit cancellation race: cancelling an
        // AVAssetReader alone does not reliably resume a wedged provider.next().
        // This provider is single-use; an abandoned read is never reused.
        try await withTaskCancellationHandler {
            try await raceAgainstCancellation(gate: cancellation.cancellationGate) {
                sampleBox.set(try await providerBox.provider.next())
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        guard let sample = sampleBox.value.flatMap({ $0 }) else { throw PreviewError.decode }
        let bufferBox = try sample.withUnsafeSampleBuffer { sampleBuffer in
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  RenderInputColorProvenance.profile(of: buffer) == profile else {
                throw PreviewError.unsupportedVideo
            }
            // Retain the frame through the existing immutable ownership bridge.
            // Only this preview actor reads it after the provider is finished;
            // neither the cached frame nor its planes are mutated after handoff.
            return RacedInputs(try Self.boundedBuffer(buffer))
        }
        let buffer = bufferBox.value
        try Task.checkCancellation()
        let description = try await Self.videoCaptureDescription(asset)
        return VideoSource(buffer: buffer, transform: transform, measurement: Self.measureVideo(buffer),
                           description: description)
    }

    static func sourceProfile(_ descriptions: [CMFormatDescription]) throws -> CameraSourceProfile {
        for profile in [CameraSourceProfile.appleLog2, .hlgBT2020] {
            if (try? RenderInputColorProvenance.inspect(descriptions, expectedProfile: profile)) != nil { return profile }
        }
        throw PreviewError.unsupportedVideo
    }

    /// Color-only resources use the production source-profile adapter,
    /// including native HLG. Its highlight ceiling is frame-specific, NOT the
    /// full-export eight-frame measurement. The meter never consumes the grade.
    func renderVideo(_ buffer: CVPixelBuffer, transform: CGAffineTransform = .identity,
                     stock: FilmStockConfig, gauge: PrintGauge, pushPull: PushPullExposure,
                     cropZoom: Double = 1, measurement: Double?, captureDescription: String?) throws -> DevelopFramePreview {
        try Task.checkCancellation()
        guard RenderInputColorProvenance.profile(of: buffer) != nil else { throw PreviewError.unsupportedVideo }
        let color = try resources()
        let source = try Self.boundedBuffer(buffer, cropZoom: cropZoom)
        let finished = try color.grade(color.prepare(source), stock: stock, pushPull: pushPull)
        // The track transform is authored for a top-down frame, and Core Image's
        // space is bottom-up: applying it verbatim turns the odd quarter turns the
        // wrong way round. Negating the off-diagonal terms is the same transform
        // written in Core Image's space, and it leaves 0° and 180° untouched.
        let rotation = CGAffineTransform(a: transform.a, b: -transform.b, c: -transform.c, d: transform.d, tx: 0, ty: 0)
        let upright = Self.normalized(finished.transformed(by: Self.bufferToTopDown).transformed(by: rotation))
        try Task.checkCancellation()
        return DevelopFramePreview(image: try FilmOutputDisplayConverter.makeSRGBImage(fromGamma24: upright),
                                   measuredOffsetEV: measurement, captureDescription: captureDescription)
    }

    /// A decoded buffer's first row is its TOP row. Handing that buffer to Core
    /// Image through a Metal texture puts that row at Core Image's origin, which is
    /// the bottom, so every frame arrives upside down. Undoing it ONCE here, before
    /// the track transform, is what makes a preview match what a player shows — a
    /// vertical mirror of a real scene reads as an upside-down frame.
    private static let bufferToTopDown = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)

    private static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// Deterministic code-domain resampling, not a display thumbnail. Copying
    /// planes avoids CI/AVFoundation transfer interpretation or RGB->YUV retagging.
    /// Enforces the bound even on decoders that ignore requested output dimensions.
    static func boundedBuffer(_ source: CVPixelBuffer, cropZoom: Double = 1) throws -> CVPixelBuffer {
        guard cropZoom.isFinite, cropZoom >= 1 else { throw PreviewError.invalidSource }
        let format = CVPixelBufferGetPixelFormatType(source)
        guard format == kCVPixelFormatType_64RGBAHalf || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
            throw PreviewError.unsupportedVideo
        }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { throw PreviewError.decode }
        let scale = min(1, Double(maximumDimension) / Double(max(width, height))) / cropZoom
        let outWidth = max(2, Int(Double(width) * scale) / 2 * 2)
        let outHeight = max(2, Int(Double(height) * scale) / 2 * 2)
        if cropZoom == 1, width == outWidth, height == outHeight { return source }
        var optional: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, outWidth, outHeight, format, attributes as CFDictionary, &optional) == kCVReturnSuccess,
              let destination = optional else { throw PreviewError.decode }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { throw PreviewError.decode }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { throw PreviewError.decode }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        let planes = format == kCVPixelFormatType_64RGBAHalf ? 1 : 2
        for plane in 0..<planes {
            let planar = CVPixelBufferIsPlanar(source)
            let sourceBase = planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source)
            let destinationBase = planar ? CVPixelBufferGetBaseAddressOfPlane(destination, plane) : CVPixelBufferGetBaseAddress(destination)
            guard let sourceBase, let destinationBase else { throw PreviewError.decode }
            let sw = planar ? CVPixelBufferGetWidthOfPlane(source, plane) : width
            let sh = planar ? CVPixelBufferGetHeightOfPlane(source, plane) : height
            let dw = planar ? CVPixelBufferGetWidthOfPlane(destination, plane) : outWidth
            let dh = planar ? CVPixelBufferGetHeightOfPlane(destination, plane) : outHeight
            let sourceStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let destinationStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(destination, plane) : CVPixelBufferGetBytesPerRow(destination)
            let pixelBytes = planar ? (plane == 0 ? 2 : 4) : 8
            for y in 0..<dh {
                if y.isMultiple(of: 64) { try Task.checkCancellation() }
                let sy = min(sh - 1, Int((Double(sh) * (1 - 1 / cropZoom) / 2) + (Double(y) + 0.5) / Double(dh) * Double(sh) / cropZoom))
                for x in 0..<dw {
                    let sx = min(sw - 1, Int((Double(sw) * (1 - 1 / cropZoom) / 2) + (Double(x) + 0.5) / Double(dw) * Double(sw) / cropZoom))
                    destinationBase.advanced(by: y * destinationStride + x * pixelBytes)
                        .copyMemory(from: sourceBase.advanced(by: sy * sourceStride + sx * pixelBytes), byteCount: pixelBytes)
                }
            }
        }
        CVBufferPropagateAttachments(source, destination)
        if let attachments = CVBufferCopyAttachments(source, .shouldNotPropagate) {
            CVBufferSetAttachments(destination, attachments, .shouldNotPropagate)
        }
        return destination
    }

    static func measurePhoto(_ image: CIImage, exposureEV: Float = RAWPhotoDecoder.baseExposureEV) -> Double? {
        let size = 96
        let scale = CGFloat(size) / max(image.extent.width, image.extent.height)
        let small = normalized(image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(small.extent.width)), height = max(1, Int(small.extent.height))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .cacheIntermediates: false])
        context.render(small, toBitmap: &pixels, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: space)
        let baseGain = pow(2, Double(exposureEV))
        let luminance = stride(from: 0, to: pixels.count, by: 4).map { index in
            DevelopExposureMeter.linearSRGBLuminance(SIMD3(Double(pixels[index]), Double(pixels[index + 1]),
                                                          Double(pixels[index + 2]))) / baseGain
        }
        return DevelopExposureMeter.offsetEV(luminance: luminance, width: width, height: height)
    }

    static func measureVideo(_ buffer: CVPixelBuffer) -> Double? {
        guard let profile = RenderInputColorProvenance.profile(of: buffer),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let sampleWidth = min(96, width), sampleHeight = min(96, height)
        guard sampleWidth > 0, sampleHeight > 0 else { return nil }
        var luminance: [Double] = []
        for y in 0..<sampleHeight {
            let sy = min(height - 1, Int((Double(y) + 0.5) * Double(height) / Double(sampleHeight)))
            for x in 0..<sampleWidth {
                let sx = min(width - 1, Int((Double(x) + 0.5) * Double(width) / Double(sampleWidth)))
                if profile == .appleLog2 {
                    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBAHalf,
                          let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
                    let row = base.advanced(by: sy * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float16.self)
                    luminance.append(DevelopExposureMeter.appleLog2Luminance(SIMD3(Double(row[sx * 4]),
                                                        Double(row[sx * 4 + 1]), Double(row[sx * 4 + 2]))))
                } else {
                    guard CVPixelBufferGetPlaneCount(buffer) == 2,
                          let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                          let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
                    let luma = yBase.advanced(by: sy * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
                    let chroma = cBase.advanced(by: sy / 2 * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)).assumingMemoryBound(to: UInt16.self)
                    luminance.append(DevelopExposureMeter.hlgLuminance(y: Double(luma[sx]) / 64,
                                        cb: Double(chroma[sx / 2 * 2]) / 64, cr: Double(chroma[sx / 2 * 2 + 1]) / 64))
                }
            }
        }
        return DevelopExposureMeter.offsetEV(luminance: luminance, width: sampleWidth, height: sampleHeight)
    }

    static func captureDescription(_ capture: PhotoDeliveryMetadata.StillCapture) -> String? {
        var parts: [String] = []
        if let iso = capture.iso, iso > 0 { parts.append("ISO \(iso)") }
        if let seconds = capture.exposureSeconds, seconds.isFinite, seconds > 0 {
            let reciprocal = 1 / seconds
            if seconds >= 1 { parts.append(String(format: "%.2f s", seconds)) }
            else if reciprocal.isFinite { parts.append(String(format: "1/%.0f s", max(1, reciprocal.rounded()))) }
        }
        if let aperture = capture.fNumber, aperture.isFinite, aperture > 0 { parts.append(String(format: "f/%.1f", aperture)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func videoCaptureDescription(_ asset: AVURLAsset) async throws -> String? {
        var parts: [String] = []
        let fields = [("iso", "ISO "), ("shutter-angle", "Shutter angle "), ("aperture-f-number", "f/")]
        let metadata = try await asset.load(.metadata)
        for (field, label) in fields {
            for item in metadata {
                guard (item.key as? String) == "com.filmemulation.\(field)",
                      let value = try await item.load(.stringValue),
                      let number = Double(value), number.isFinite, number > 0 else { continue }
                parts.append(label + value)
                break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    enum PreviewError: LocalizedError {
        case invalidSource, decode, unsupportedVideo, grade, failed(String)
        var errorDescription: String? {
            switch self {
            case .invalidSource: return "The original is missing, empty, or has invalid preview geometry."
            case .decode: return "The original could not be decoded for a film preview."
            case .unsupportedVideo: return "Preview requires verified Apple Log 2 or ten-bit BT.2020 HLG video. Other profiles are unavailable."
            case .grade: return "The film preview could not be rendered."
            case .failed(let detail): return "Film preview unavailable: \(detail)"
            }
        }
    }
}
