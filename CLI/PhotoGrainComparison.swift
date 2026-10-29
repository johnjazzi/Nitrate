import CoreImage
import Foundation

/// Same captured RAW, stock, seed and color transform; only gauge/presence vary.
/// Exports delivery-color PNGs and native crops, not encoded-stage visualizations.
enum PhotoGrainComparison {
    static func run(input: URL, stock: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let bundle = Bundle(url: executableDirectory.appendingPathComponent("RenderCLITests.xctest")) ?? .main
        let base = try StillFilmRenderResources(stockID: stock, gauge: .neutral, seed: 42, bundle: bundle)
        let decoder = try RAWPhotoDecoder(device: base.device, queue: base.queue)
        let decoded = try decoder.decode(url: input, temperature: base.config.lightType == "D" ? 5600 : 3200)
        let log = try RAWToLog2Stage.apply(decoded.linearImage)
        let graded = try base.grade(base.halation(log))
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let extent = graded.extent
        // Export a native-resolution central crop plus the whole display image.
        let crop = CGRect(x: floor(extent.midX - 384), y: floor(extent.midY - 384), width: 768, height: 768)
            .intersection(extent)
        let variants: [(PrintGauge, Float)] = PrintGauge.allCases.map { ($0, 2) }
            + [(.neutral, 1), (.neutral, 1.25), (.neutral, 1.5)]
        let legacy = try StillFilmRenderResources(stockID: stock, gauge: .neutral, seed: 42,
            bundle: bundle, stillPresenceGain: 2)
        let legacyImage = try legacy.glowAndGrain(graded)
        var baseline = [Float](repeating: 0, count: Int(crop.width * crop.height) * 4)
        base.context.render(legacyImage, toBitmap: &baseline, rowBytes: Int(crop.width) * 16,
            bounds: crop, format: .RGBAf, colorSpace: space)
        for (gauge, gain) in variants {
            let film = try StillFilmRenderResources(stockID: stock, gauge: gauge, seed: 42,
                bundle: bundle, stillPresenceGain: gain)
            let finished = try film.glowAndGrain(graded)
            let linear = try FilmOutputDisplayConverter.linearImage(fromGamma24: finished)
            let name = "\(gauge.rawValue)-gain-\(gain)"
            try film.context.writePNGRepresentation(of: linear, to: directory.appendingPathComponent(name + ".png"),
                format: .RGBA8, colorSpace: srgb)
            let nativeCrop = linear.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            try film.context.writePNGRepresentation(of: nativeCrop,
                to: directory.appendingPathComponent(name + "-crop.png"), format: .RGBA8, colorSpace: srgb)
            var pixels = [Float](repeating: 0, count: Int(crop.width * crop.height) * 4)
            film.context.render(finished, toBitmap: &pixels, rowBytes: Int(crop.width) * 16,
                bounds: crop, format: .RGBAf, colorSpace: space)
            var squaredDelta = 0.0
            for i in pixels.indices where i % 4 != 3 {
                let delta = Double(pixels[i] - baseline[i]); squaredDelta += delta * delta
            }
            let deltaRMS = sqrt(squaredDelta / Double(pixels.count / 4 * 3))
            print("GRAIN-COMPARISON stock=\(stock) ISO=\(PhotoDeliveryMetadata.capture(fromDNG: input).iso ?? 0) gauge=\(gauge.rawValue) gain=\(gain) seed=42 crop=1 rmsDeltaFrom35mmLegacy=\(deltaRMS)")
        }
    }
}
