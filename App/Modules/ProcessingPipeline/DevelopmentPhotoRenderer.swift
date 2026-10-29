import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// Development-only still renderer. Exposure gain is intentionally uncalibrated (1.0).
enum DevelopmentPhotoRenderer {
    static func render(originalDNG: URL, stockID: String, resourcesURL: URL? = nil,
                       gauge: PrintGauge = .neutral, seed: UInt32 = 0, cropZoom: Double = 1, bundle: Bundle = .main) throws -> URL {
        let normalizedStock: String
        switch stockID.lowercased() {
        case "kodak5207", "5207": normalizedStock = "5207"
        case "kodak5219", "5219": normalizedStock = "5219"
        default: throw RenderError.unsupportedStock(stockID)
        }
        let film = try StillFilmRenderResources(stockID: "kodak" + normalizedStock, gauge: gauge, seed: seed, bundle: bundle)
        let decoder = try RAWPhotoDecoder(device: film.device, queue: film.queue)
        let decodedRAW = try decoder.decode(url: originalDNG, temperature: film.config.lightType == "D" ? 5600 : 3200)
        guard let decoded = CIImage(mtlTexture: decodedRAW.texture,
            options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!]) else {
            throw RenderError.decode("RAW texture unavailable")
        }
        guard let crop = PhotoZoomGeometry.centeredCrop(in: decoded.extent, zoom: cropZoom) else {
            throw RenderError.decode("Invalid Photo zoom or RAW extent")
        }
        let oriented = decoded.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let inputSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let finished = try develop(linearImage: oriented, film: film, resourcesURL: resourcesURL)
        // LUT output is Rec.709 gamma 2.4. Decode it before the final sRGB encoding.
        let linear709 = try FilmOutputDisplayConverter.linearImage(fromGamma24: finished)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw RenderError.decode("sRGB unavailable") }
        let context = CIContext(options: [.workingColorSpace: inputSpace, .outputColorSpace: srgb, .cacheIntermediates: false])
        let rendered = linear709
        let destination = originalDNG.deletingPathExtension().appendingPathExtension("jpg")
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).jpg")
        guard let cg = context.createCGImage(rendered, from: rendered.extent, format: .RGBA8, colorSpace: srgb),
              let sink = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RenderError.decode("JPEG destination unavailable")
        }
        // Deliver the same Nitrate tags a movie carries; the shared payload is
        // built from the same recipe the movie writer uses.
        let capture = PhotoDeliveryMetadata.capture(fromDNG: originalDNG)
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.94]
        for (key, value) in try PhotoDeliveryMetadata.properties(
            config: film.config, capture: capture,
            deliveredSize: CGSize(width: cg.width, height: cg.height)) {
            properties[key] = value
        }
        CGImageDestinationAddImage(sink, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(sink), let source = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              let check = CGImageSourceCreateImageAtIndex(source, 0, nil), check.width == cg.width, check.height == cg.height,
              let profile = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              profile[kCGImagePropertyColorModel] != nil else {
            try? FileManager.default.removeItem(at: temporary)
            throw RenderError.decode("JPEG verification failed")
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// The same stages used by DNG delivery, exposed to actual GPU regressions.
    static func develop(linearImage: CIImage, film: StillFilmRenderResources, resourcesURL: URL? = nil) throws -> CIImage {
        let prepared = try RAWToLog2Stage.apply(linearImage)
        let halated = try film.halation(prepared)
        let graded = try film.grade(halated, resourcesURL: resourcesURL)
        return try film.glowAndGrain(graded)
    }

    enum RenderError: Error { case unsupportedStock(String), missingCube(String), decode(String) }
}
