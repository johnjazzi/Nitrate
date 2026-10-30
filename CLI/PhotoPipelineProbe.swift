import Foundation
import CoreImage
import ImageIO

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
        // The shipping decoder's own noise, in the domain the sweep is measured in,
        // so a policy change can be read against the 0-NR baseline.
        if let stats = measure(log, space: space, context: film.context) {
            print(String(format: "PHOTO-NOISE log: chromaSigma %.5f lumaSigma %.5f detail %.5f mean %.4f",
                         stats.chroma, stats.luma, stats.detail, stats.mean))
        }
        if let stats = measure(raw, space: space, context: film.context) {
            print(String(format: "PHOTO-NOISE linear: chromaSigma %.5f lumaSigma %.5f detail %.5f mean %.4f",
                         stats.chroma, stats.luma, stats.detail, stats.mean))
        }
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

    // MARK: - Orientation probe

    /// Prints what the decoder actually returns for a capture and what each EXIF
    /// rotation would do to it, so the still path can follow the pixels instead of
    /// trusting the tag twice.
    static func orientationProbe(inputs: [URL]) throws {
        for input in inputs {
            let capture = PhotoDeliveryMetadata.capture(fromDNG: input)
            guard let raw = CIRAWFilter(imageURL: input) else { print("ORIENT unreadable \(input.lastPathComponent)"); continue }
            raw.decoderVersion = CIRAWDecoderVersion(rawValue: "8.dng")
            raw.scaleFactor = 1
            guard let image = raw.outputImage else { print("ORIENT no image"); continue }
            func extent(_ i: CIImage) -> String {
                "\(Int(i.extent.width))x\(Int(i.extent.height))"
            }
            let six = image.oriented(forExifOrientation: 6)
            let eight = image.oriented(forExifOrientation: 8)
            let three = image.oriented(forExifOrientation: 3)
            print("ORIENT \(input.lastPathComponent) exif=\(capture.orientation) decoded=\(extent(image)) " +
                  "rot6=\(extent(six)) rot8=\(extent(eight)) rot3=\(extent(three)) " +
                  "native=\(Int(raw.nativeSize.width))x\(Int(raw.nativeSize.height))")
        }
    }

    // MARK: - Noise probe

    /// Noise and detail of one decoded image in the log domain the still chain
    /// grades from.
    ///
    /// Noise is the median 32x32-block sigma of the 5x5 high-pass residual, so a
    /// dark frame's empty corners drive the number the operator actually sees;
    /// `luma` and `chroma` are reported apart because multicoloured speckle is a
    /// chroma problem, and `detail` is the mean luma gradient so a reduction that
    /// eats texture cannot hide behind a good noise score.
    struct NoiseStats {
        let chroma: Float
        let luma: Float
        let detail: Float
        let mean: Float
    }

    static func measure(_ image: CIImage, space: CGColorSpace, context: CIContext) -> NoiseStats? {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBAf, colorSpace: space)
        var luma = [Float](repeating: 0, count: width * height)
        var blue = [Float](repeating: 0, count: width * height)
        var red = [Float](repeating: 0, count: width * height)
        var total: Float = 0
        for i in 0..<(width * height) {
            let r = pixels[i * 4], g = pixels[i * 4 + 1], b = pixels[i * 4 + 2]
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luma[i] = y; blue[i] = b - y; red[i] = r - y
            total += y
        }
        func blur(_ source: [Float]) -> [Float] {
            let radius = 2
            var horizontal = [Float](repeating: 0, count: width * height)
            var out = [Float](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    var sum: Float = 0
                    for d in -radius...radius {
                        sum += source[y * width + min(max(x + d, 0), width - 1)]
                    }
                    horizontal[y * width + x] = sum / Float(2 * radius + 1)
                }
            }
            for y in 0..<height {
                for x in 0..<width {
                    var sum: Float = 0
                    for d in -radius...radius {
                        sum += horizontal[min(max(y + d, 0), height - 1) * width + x]
                    }
                    out[y * width + x] = sum / Float(2 * radius + 1)
                }
            }
            return out
        }
        let lumaBlur = blur(luma), blueBlur = blur(blue), redBlur = blur(red)
        let block = 32
        var lumaSigmas: [Float] = [], chromaSigmas: [Float] = [], details: [Float] = []
        var by = 0
        while by + block <= height {
            var bx = 0
            while bx + block <= width {
                var lumaEnergy: Float = 0, chromaEnergy: Float = 0, detail: Float = 0
                for y in by..<(by + block) {
                    for x in bx..<(bx + block) {
                        let i = y * width + x
                        let dl = luma[i] - lumaBlur[i]
                        let db = blue[i] - blueBlur[i]
                        let dr = red[i] - redBlur[i]
                        lumaEnergy += dl * dl
                        chromaEnergy += db * db + dr * dr
                        if x > 0, y > 0 {
                            let gx = luma[i] - luma[i - 1], gy = luma[i] - luma[i - width]
                            detail += (gx * gx + gy * gy).squareRoot()
                        }
                    }
                }
                let count = Float(block * block)
                lumaSigmas.append((lumaEnergy / count).squareRoot())
                chromaSigmas.append((chromaEnergy / count).squareRoot())
                details.append(detail / count)
                bx += block
            }
            by += block
        }
        func median(_ values: [Float]) -> Float {
            guard !values.isEmpty else { return 0 }
            return values.sorted()[values.count / 2]
        }
        return NoiseStats(chroma: median(chromaSigmas), luma: median(lumaSigmas),
                          detail: details.reduce(0, +) / Float(max(1, details.count)),
                          mean: total / Float(width * height))
    }

    /// Sweeps the decoder's colour-noise-reduction control on real captures.
    ///
    /// The control is currently pinned to zero, so this is the measurement that
    /// says whether pinning it is still the right call at high ISO and, if it is
    /// not, where a ramp should sit.
    static func noiseProbe(inputs: [URL]) throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space, .cacheIntermediates: false])
        for input in inputs {
            guard let probe = CIRAWFilter(imageURL: input) else {
                print("NOISE-PROBE \(input.lastPathComponent): unreadable"); continue
            }
            print(String(format: "NOISE-PROBE %@ iso=%.0f colorNRSupported=%@ luminanceNRSupported=%@",
                         input.lastPathComponent, Float(PhotoDeliveryMetadata.capture(fromDNG: input).iso ?? 0),
                         probe.isColorNoiseReductionSupported ? "true" : "false",
                         probe.isLuminanceNoiseReductionSupported ? "true" : "false"))
            for amount in [Float(0), 0.25, 0.5, 0.75, 1.0] as [Float] {
                guard let raw = CIRAWFilter(imageURL: input) else { continue }
                raw.decoderVersion = CIRAWDecoderVersion(rawValue: "8.dng")
                raw.scaleFactor = 1
                raw.exposure = 0
                raw.shadowBias = 0
                raw.boostAmount = 0
                raw.boostShadowAmount = 0
                raw.isGamutMappingEnabled = false
                raw.extendedDynamicRangeAmount = 1
                raw.neutralTemperature = 5600
                raw.neutralTint = 0
                if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
                if raw.isDetailSupported { raw.detailAmount = 0 }
                if raw.isContrastSupported { raw.contrastAmount = 0 }
                if raw.isMoireReductionSupported { raw.moireReductionAmount = 0 }
                if raw.isDespeckleSupported { raw.despeckleAmount = 0 }
                if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
                if raw.isHighlightRecoverySupported { raw.isHighlightRecoveryEnabled = false }
                if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
                if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = amount }
                guard let image = raw.outputImage else { continue }
                let log = try RAWToLog2Stage.apply(image)
                guard let stats = measure(log, space: space, context: context) else { continue }
                print(String(format: "  colorNR %.2f  chromaSigma %.5f  lumaSigma %.5f  detail %.5f  logMean %.4f",
                             amount, stats.chroma, stats.luma, stats.detail, stats.mean))
            }
        }
    }
}
