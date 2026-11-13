import CoreImage
import Foundation

/// Same captured RAW, stock, seed and color transform; only gauge/presence vary.
/// Exports delivery-color PNGs and native crops, not encoded-stage visualizations.
enum PhotoGrainComparison {
    /// The digital-zoom case: one decode rendered at several crops, so the
    /// realized cell can be read against the delivered picture rather than
    /// against the source's own pixels. Before the reference-frame conversion
    /// the cropped variant carried a cell magnified by exactly the zoom, which
    /// is what made a 2.8x telephoto still read like a coarser gauge.
    ///
    /// Prints, per zoom, the delivered raster, the cell the kernel samples in
    /// that raster's pixels and the sub-pixel damping applied to it, and writes
    /// the delivered-colour PNG that carries the grain.
    static func zoomRun(input: URL, stock: String, directory: URL,
                        zooms: [Double] = [1, 2, 2.783, 4]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let bundle = Bundle(url: executableDirectory.appendingPathComponent("RenderCLITests.xctest")) ?? .main
        let film = try StillFilmRenderResources(stockID: stock, gauge: .neutral, seed: 42, bundle: bundle)
        let decoder = try RAWPhotoDecoder(device: film.device, queue: film.queue)
        let decoded = try decoder.decode(url: input,
                                        temperature: film.config.lightType == "D" ? 5600 : 3200)
        let footprint = GrainModel.effectiveSize(stockGrainSize: film.config.grainSize, gauge: .neutral)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        print("GRAIN-ZOOM stock=\(stock) gauge=\(PrintGauge.neutral.rawValue) "
            + "stockGrainSize=\(film.config.grainSize) referenceLongEdge=\(GrainModel.referenceLongEdge) "
            + "footprintReferencePx=\(footprint)")
        for zoom in zooms {
            guard let crop = PhotoZoomGeometry.centeredCrop(in: decoded.linearImage.extent, zoom: zoom) else {
                print("GRAIN-ZOOM zoom=\(zoom) refused")
                continue
            }
            let oriented = decoded.linearImage.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            let prepared = try RAWToLog2Stage.apply(oriented)
            let halated = try film.halation(prepared, sceneLiftStops: decoded.sceneLiftStops,
                                           halationHeadroom: decoded.halationHeadroom)
            let graded = try film.grade(halated)
            let grained = try film.glowAndGrain(graded)
            let linear = try FilmOutputDisplayConverter.linearImage(fromGamma24: grained)
            let extent = linear.extent
            let width = Int(extent.width), height = Int(extent.height)
            let scale = GrainModel.referenceScale(width: width, height: height)
            let cell = footprint / scale
            try film.context.writePNGRepresentation(
                of: linear,
                to: directory.appendingPathComponent(String(format: "zoom-%.3f.png", zoom)),
                format: .RGBA8, colorSpace: srgb)
            print("GRAIN-ZOOM zoom=\(zoom) raster=\(width)x\(height) "
                + "referenceScale=\(scale) cellRasterPx=\(cell) damping=\(min(cell, 1))")
        }
    }

    /// Flat-field grain readout: a constant mid-grey frame carried through the
    /// same glow-and-grain stage at each raster size, so the grain can be
    /// measured with nothing under it. Writes the PNG that carries the grain
    /// and prints the cell the kernel samples in that raster's own pixels.
    static func flatRun(stock: String, directory: URL,
                        rasters: [(Int, Int)] = [(4032, 3024), (2880, 2160), (2016, 1512),
                                                  (1448, 1086), (1008, 756)]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let bundle = Bundle(url: executableDirectory.appendingPathComponent("RenderCLITests.xctest")) ?? .main
        let film = try StillFilmRenderResources(stockID: stock, gauge: .neutral, seed: 42, bundle: bundle)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let footprint = GrainModel.effectiveSize(stockGrainSize: film.config.grainSize, gauge: .neutral)
        print("GRAIN-FLAT stock=\(stock) referenceLongEdge=\(GrainModel.referenceLongEdge) "
            + "footprintReferencePx=\(footprint)")
        for (width, height) in rasters {
            let flat = CIImage(color: CIColor(red: 0.45, green: 0.45, blue: 0.45))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let grained = try film.glowAndGrain(flat)
            let linear = try FilmOutputDisplayConverter.linearImage(fromGamma24: grained)
            let scale = GrainModel.referenceScale(width: width, height: height)
            let cell = footprint / scale
            try film.context.writePNGRepresentation(
                of: linear,
                to: directory.appendingPathComponent("flat-\(width)x\(height).png"),
                format: .RGBA8, colorSpace: srgb)
            print("GRAIN-FLAT raster=\(width)x\(height) referenceScale=\(scale) "
                + "cellRasterPx=\(cell) damping=\(min(cell, 1))")
        }
    }

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
