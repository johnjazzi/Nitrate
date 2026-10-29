import Foundation
import CoreImage

/// Developer-only local replay of a captured DNG through the shipping Photo stages.
enum PhotoPipelineProbe {
    static func run(input: URL, stock: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("RenderCLITests.xctest")
        let bundle = Bundle(url: resources) ?? .main
        let film = try StillFilmRenderResources(stockID: stock, gauge: .sixteenMillimetre, seed: 42, bundle: bundle)
        let decoder = try RAWPhotoDecoder(device: film.device, queue: film.queue)
        let decoded = try decoder.decode(url: input, temperature: film.config.lightType == "D" ? 5600 : 3200)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let raw = CIImage(mtlTexture: decoded.texture, options: [.colorSpace: space]) else {
            throw DevelopmentPhotoRenderer.RenderError.decode("Probe RAW texture missing")
        }
        func inspect(_ name: String, _ image: CIImage) throws {
            let small = image.transformed(by: CGAffineTransform(scaleX: 64 / image.extent.width, y: 64 / image.extent.height))
            var pixels = [Float](repeating: 0, count: 64 * 64 * 4)
            film.context.render(small, toBitmap: &pixels, rowBytes: 64 * 16,
                bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBAf, colorSpace: space)
            let rgb = pixels.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
            let finite = rgb.filter(\.isFinite)
            let average = finite.reduce(0, +) / Float(max(1, finite.count))
            print("PHOTO-STAGE \(name): min=\(finite.min() ?? .nan) max=\(finite.max() ?? .nan) mean=\(average) nonFinite=\(rgb.count - finite.count) aboveOne=\(finite.filter { $0 > 1 }.count)")
            try film.context.writePNGRepresentation(of: image.transformed(by: CGAffineTransform(scaleX: 0.2, y: 0.2)),
                to: directory.appendingPathComponent(name + ".png"), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        if let nativeRAW = CIRAWFilter(imageURL: input), let nativeImage = nativeRAW.outputImage {
            try inspect("00-native-raw", nativeImage)
        }
        print("RAW settings: \(decoded.settings)")
        try inspect("00-configured-raw", decoded.linearImage)
        try inspect("01-raw", raw)
        let log = try RAWToLog2Stage.apply(raw)
        try inspect("02-log", log)
        let halation = try film.halation(log)
        try inspect("03-halation", halation)
        let graded = try film.grade(halation)
        try inspect("04-graded", graded)
        let finished = try film.glowAndGrain(graded)
        try inspect("05-grain", finished)
        let result = try DevelopmentPhotoRenderer.render(originalDNG: input, stockID: stock,
            gauge: .sixteenMillimetre, seed: 42, bundle: bundle)
        print("PHOTO-OUTPUT \(result.path)")
    }

    /// Quantifies what the decoder's zeroed RAW controls cost, without changing them.
    static func exposureProbe(input: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space, .cacheIntermediates: false])
        func stats(_ label: String, _ configure: (CIRAWFilter) -> Void) throws {
            guard let raw = CIRAWFilter(imageURL: input) else { throw NSError(domain: "probe", code: 1) }
            raw.decoderVersion = CIRAWDecoderVersion(rawValue: "8.dng")
            raw.scaleFactor = 1
            configure(raw)
            guard let image = raw.outputImage else { throw NSError(domain: "probe", code: 2) }
            let small = image.transformed(by: CGAffineTransform(scaleX: 64 / image.extent.width, y: 64 / image.extent.height))
            var pixels = [Float](repeating: 0, count: 64 * 64 * 4)
            context.render(small, toBitmap: &pixels, rowBytes: 64 * 16,
                bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBAf, colorSpace: space)
            let rgb = pixels.enumerated().filter { $0.offset % 4 != 3 }.map(\.element).filter(\.isFinite)
            let mean = rgb.reduce(0, +) / Float(rgb.count)
            print(String(format: "RAW-PROBE %@: baselineExposure=%.3f exposure=%.3f mean=%.4f min=%.4f max=%.4f",
                label, raw.baselineExposure, raw.exposure, mean, rgb.min() ?? 0, rgb.max() ?? 0))
        }
        try stats("sdk-defaults") { _ in }
        try stats("policy-zeros") { raw in
            raw.exposure = 0; raw.baselineExposure = 0; raw.shadowBias = 0
            raw.boostAmount = 0; raw.boostShadowAmount = 0
            raw.isGamutMappingEnabled = false
            raw.extendedDynamicRangeAmount = 1
        }
    }
}
