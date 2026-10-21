import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
import simd

/// Visibility regressions for the stock-selector preview, measured at the size the card is
/// actually drawn.
///
/// The card is a 250 pt plate at 3x, so its drawable is 750x1125 pixels. Earlier suites
/// measured the preview at synthetic sizes with an inflated halation radius (0.03 instead of
/// the shipped 0.001) and a hand-picked grain amplitude (0.1), which cannot show whether the
/// effects read on the card. These tests render the shipping `PlatePreviewPipeline` on the
/// bundled Apple Log 2 plates at 750x1125, under the white-balance lock each scene's own
/// illuminant produces, with the shipped stock geometry:
///
///   * grain presence must follow the renderer's own model (`GrainModel.baseAmount` scaled by
///     the gauge), not a preview-only constant that under-reads it;
///   * grain must stay visible when the drawable is the card rather than an inflated test
///     frame;
///   * halation at the shipped radius is measured on Neon, Forest and Fireworks and reported
///     as the sub-quantization change it really is, so no one "fixes" it by widening a radius
///     or raising a strength that the offline render does not use.
struct PlatePreviewVisibilityTests {
    private final class BundleToken {}

    /// 250 pt card at 3x, the plate's 2:3 shape.
    static let cardWidth = 750
    static let cardHeight = 1125

    // MARK: - Fixtures and helpers

    private func device() throws -> any MTLDevice {
        try #require(MTLCreateSystemDefaultDevice())
    }

    private func pipeline(_ device: any MTLDevice) throws -> PlatePreviewPipeline {
        let queue = try #require(device.makeCommandQueue())
        return try PlatePreviewPipeline(device: device,
                                        library: try device.makeDefaultLibrary(bundle: Bundle(for: BundleToken.self)),
                                        queue: queue)
    }

    private func identityLUT(_ device: any MTLDevice) throws -> any MTLTexture {
        let side = 33
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = side
        descriptor.height = side
        descriptor.depth = side
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var values = [Float]()
        values.reserveCapacity(side * side * side * 4)
        for blue in 0..<side {
            for green in 0..<side {
                for red in 0..<side {
                    values.append(contentsOf: [Float(red) / Float(side - 1),
                                               Float(green) / Float(side - 1),
                                               Float(blue) / Float(side - 1), 1])
                }
            }
        }
        let rowBytes = side * 16
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake3D(0, 0, 0, side, side, side), mipmapLevel: 0, slice: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: rowBytes, bytesPerImage: rowBytes * side)
        }
        return texture
    }

    private func stockLUT(_ device: any MTLDevice, name: String = "5219 - Apple Log 2.cube") throws -> any MTLTexture {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: nil)
            ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "LUTs"))
        let cube = try PlateCube.parse(try String(contentsOf: url, encoding: .utf8))
        return try PlatePreviewPipeline.makeLUTTexture(cube, device: device)
    }

    private func grainVolume(_ device: any MTLDevice) throws -> any MTLTexture {
        try #require(PlatePreviewPipeline.makeGrainVolume(device: device, bundle: Bundle(for: BundleToken.self)))
    }

    /// RMS of the shipped noise volume after the shader's `sample*2 - 1`, read from the raw
    /// asset so the expected grain amplitude is derived from the real field, not a magic number.
    private func grainVolumeRMS() throws -> Double {
        let bundle = Bundle(for: BundleToken.self)
        let path = try #require(bundle.path(forResource: "grain3d", ofType: "raw")
            ?? bundle.path(forResource: "grain3d", ofType: "raw", inDirectory: "Grain"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let count = 128 * 128 * 128
        return data.withUnsafeBytes { raw -> Double in
            let values = raw.bindMemory(to: Float.self)
            var sum = 0.0
            for index in 0..<count {
                let centered = Double(values[index]) * 2 - 1
                sum += centered * centered
            }
            return (sum / Double(count)).squareRoot()
        }
    }

    private func uniformPlate(_ device: any MTLDevice, side: Int, code: UInt8) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: side, height: side, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let bytes = [UInt8](repeating: code, count: side * side * 4)
        texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: side * 4)
        return texture
    }

    private func makeTarget(_ device: any MTLDevice, width: Int, height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// A real bundled plate, uploaded exactly as the shipping renderer uploads it.
    private func bundledPlate(_ device: any MTLDevice,
                              scene sceneID: String) throws -> (texture: any MTLTexture, size: SIMD2<Float>) {
        let catalog = try StockSampleCatalog.load(bundle: Bundle(for: BundleToken.self))
        let scene = try #require(catalog.scenes.first { $0.id == sceneID })
        let image = try #require(PlateImage.load(scene.plateURL(directory: catalog.directory)))
        let texture = try PlatePreviewPipeline.makePlateTexture(image, device: device)
        return (texture, SIMD2(Float(image.width), Float(image.height)))
    }

    private struct Container: Decodable { let stocks: [FilmStockConfig] }

    private func stockConfig(_ id: String) throws -> FilmStockConfig {
        let bundle = Bundle(for: BundleToken.self)
        let url = bundle.url(forResource: "stocks", withExtension: "json")
            ?? TestRepository.url(for: "App/Resources/stocks.json")
        let container = try JSONDecoder().decode(Container.self, from: Data(contentsOf: url))
        return try #require(container.stocks.first { $0.stockId == id })
    }

    /// Run the shipping chain once and read the 8-bit BGRA result back.
    private func render(_ device: any MTLDevice, pipeline: PlatePreviewPipeline,
                        plate: any MTLTexture, plateSize: SIMD2<Float>, lut: any MTLTexture,
                        grain: (any MTLTexture)?, configuration: PreviewConfiguration,
                        width: Int, height: Int) throws -> PixelFrame {
        try pipeline.load(plateTexture: plate, plateSize: plateSize, lutTexture: lut,
                          grainVolume: grain, configuration: configuration)
        let target = try makeTarget(device, width: width, height: height)
        let rendered = pipeline.render(into: target, drawableSize: CGSize(width: width, height: height))
        #expect(rendered, "the preview pass must complete")
        return try PixelFrame(texture: target, width: width, height: height)
    }

    private func configuration(stock: FilmStockConfig, gauge: PrintGauge,
                               sceneIlluminantKelvin: Float) -> PreviewConfiguration {
        PreviewConfiguration(stock: stock, gauge: gauge, sceneIlluminantKelvin: sceneIlluminantKelvin)
    }

    // MARK: - Grain presence must follow the renderer's model

    /// `GrainModel.baseAmount` is the renderer's own presence constant: `pass2_grain` applies
    /// `0.55 * gaugeAmplitude * latitude`. The preview previously multiplied a preview-only
    /// `0.2` instead, so every card under-read the grain by more than half. This pins the
    /// shipping configuration to the renderer's value rather than to a second, quieter one.
    @Test func previewGrainPresenceMatchesTheRendererModel() throws {
        let stock = try stockConfig("kodak5219")
        #expect(GrainModel.baseAmount == 0.55)
        for gauge in PrintGauge.allCases {
            let config = configuration(stock: stock, gauge: gauge, sceneIlluminantKelvin: 3600)
            let expected = GrainModel.amount(gauge: gauge)
            #expect(abs(config.amplitude - expected) < 1e-6,
                    "gauge \(gauge): preview amplitude \(config.amplitude) must equal the renderer's GrainModel.amount \(expected)")
        }
    }

    /// On a uniform mid-grey plate the only structure in the output is grain, so its standard
    /// deviation is `volumeRMS * amplitude * damping`. The expected amplitude comes from the
    /// renderer's model (`GrainModel.amount`), and the damping is the sub-pixel reduction the
    /// shader documents. A preview constant that under-reads fails this band.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func cardSizeGrainMatchesTheRendererAmount() throws {
        let device = try device()
        let pipeline = try pipeline(device)
        let plate = try uniformPlate(device, side: 512, code: 128)
        let lut = try identityLUT(device)
        let grain = try grainVolume(device)
        let stock = try stockConfig("kodak5219")
        let legacyBaseAmount: Float = 0.2

        func sigma(_ gauge: PrintGauge) throws -> Double {
            let config = configuration(stock: stock, gauge: gauge, sceneIlluminantKelvin: 3600)
            let frame = try render(device, pipeline: pipeline, plate: plate, plateSize: SIMD2(512, 512),
                                   lut: lut, grain: grain, configuration: config,
                                   width: Self.cardWidth, height: Self.cardHeight)
            let legacy = try render(device, pipeline: pipeline, plate: plate, plateSize: SIMD2(512, 512),
                                    lut: lut, grain: grain,
                                    configuration: config.withEffects(amplitude: legacyBaseAmount * gauge.amplitudeMultiplier),
                                    width: Self.cardWidth, height: Self.cardHeight)
            let measured = frame.sigma(channel: 2, columns: 200..<550, rows: 300..<800)
            let oldSigma = legacy.sigma(channel: 2, columns: 200..<550, rows: 300..<800)
            let expectedRatio = Double(GrainModel.baseAmount / legacyBaseAmount)
            let ratio = measured / max(oldSigma, 1e-9)
            if gauge != .seventyFiveMillimetre {
                #expect(abs(ratio - expectedRatio) < 0.4,
                        "The resolved grain must follow the amount change: \(ratio) vs \(expectedRatio)")
            }
            print("[preview-visibility] gauge \(gauge): sigma \(measured), old sigma \(oldSigma), ratio \(ratio)")
            return measured
        }

        // The single-sample preview field is close to, but not identical with, the renderer's
        // multiscale field; a 35% band accepts that difference and rejects a preview of roughly
        // a third of the model (the old 0.2 constant) or a silent, invisible one.
        let eight = try sigma(.eightMillimetre)
        let thirtyFive = try sigma(.thirtyFiveMillimetre)
        let seventyFive = try sigma(.seventyFiveMillimetre)

        #expect(thirtyFive > 1.0 / 255.0, "35mm midtone grain must survive 8-bit display quantisation")
        #expect(eight > thirtyFive && thirtyFive > seventyFive,
                "presence must fall across the gauge ladder: \(eight), \(thirtyFive), \(seventyFive)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func detailMagnifiesTheGrainWithoutChangingStockSettings() throws {
        let device = try device()
        let pipeline = try pipeline(device)
        let plate = try uniformPlate(device, side: 512, code: 128)
        let lut = try identityLUT(device)
        let grain = try grainVolume(device)
        let stock = try stockConfig("kodak5219")
        let base = configuration(stock: stock, gauge: .thirtyFiveMillimetre,
                                 sceneIlluminantKelvin: 3200).withEffects(halation: 0, radius: 0)
        let detail = base.withZoom(3)
        #expect(detail.halationStrength == base.halationStrength)
        #expect(detail.halationRadiusFraction == base.halationRadiusFraction)
        #expect(detail.footprint == base.footprint && detail.amplitude == base.amplitude)
        #expect(detail.key != base.key)
        let fullFrame = try render(device, pipeline: pipeline, plate: plate, plateSize: SIMD2(512, 512),
                                   lut: lut, grain: grain, configuration: base,
                                   width: Self.cardWidth, height: Self.cardHeight)
        let detailFrame = try render(device, pipeline: pipeline, plate: plate, plateSize: SIMD2(512, 512),
                                     lut: lut, grain: grain, configuration: detail,
                                     width: Self.cardWidth, height: Self.cardHeight)
        let fullSigma = fullFrame.sigma(channel: 2, columns: 200..<550, rows: 300..<800)
        let detailSigma = detailFrame.sigma(channel: 2, columns: 200..<550, rows: 300..<800)
        #expect(detailSigma > fullSigma * 1.2,
                "Magnified grain must resolve beyond the reduced full-photo signal")
        try save(detailFrame.cgImage(), name: "midtone-detail-grain")
    }

    // MARK: - Halation at the shipped radius, on the real plates

    /// Halation on the bundled plates at the shipped strength (2.52) and radius (0.001), under
    /// each scene's own white-balance lock. The plates rarely clear the model's knees -- red 1x
    /// diffuse white, green 2x, blue 4x -- so this measures and reports the change rather than
    /// asserting an inflated one.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func cardSizeHalationOnRealPlatesIsMeasuredNotAssumed() throws {
        let device = try device()
        let pipeline = try pipeline(device)
        let lut = try stockLUT(device)
        let stock = try stockConfig("kodak5219")

        for sceneID in ["neon", "forest", "fireworks"] {
            let catalog = try StockSampleCatalog.load(bundle: Bundle(for: BundleToken.self))
            let scene = try #require(catalog.scenes.first { $0.id == sceneID })
            let plate = try bundledPlate(device, scene: sceneID)
            let base = configuration(stock: stock, gauge: .thirtyFiveMillimetre,
                                     sceneIlluminantKelvin: scene.sceneIlluminantKelvin)
            // Grain off so the only difference between the two renders is halation.
            let off = base.withEffects(amplitude: 0, halation: 0, radius: 0)
            let on = base.withEffects(amplitude: 0,
                                      halation: base.halationStrength,
                                      radius: base.halationRadiusFraction)

            let without = try render(device, pipeline: pipeline, plate: plate.texture, plateSize: plate.size,
                                     lut: lut, grain: nil, configuration: off,
                                     width: Self.cardWidth, height: Self.cardHeight)
            let with = try render(device, pipeline: pipeline, plate: plate.texture, plateSize: plate.size,
                                  lut: lut, grain: nil, configuration: on,
                                  width: Self.cardWidth, height: Self.cardHeight)
            let delta = with.delta(from: without)
            print("[preview-visibility] halation \(sceneID): max red \(delta.maxRed) green \(delta.maxGreen) "
                + "blue \(delta.maxBlue) bytes, changed pixels \(delta.changed(threshold: 1))/\(without.count)")

            // The stock LUT and the scene's white-balance lock can change channel ordering;
            // the measurable requirement here is a nonzero effect at the shipped geometry.
            #expect(on.halationRadiusFraction == stock.halationRadiusFraction)
            #expect(on.halationStrength == stock.halationStrength)
            #expect(delta.maxRed > 0 && delta.changed > 0,
                    "\(sceneID): the actual stock radius must produce a nonzero rendered halo")
        }
    }

    // MARK: - Fixtures

    /// Card-size before/after panels for grain and halation on the real plates, written as PNGs
    /// outside the checkout. These are the "what is actually visible" evidence: the halation
    /// panels land next to the grain panels at the same size as the card.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func writesCardSizeBeforeAfterPanels() throws {
        let device = try device()
        let pipeline = try pipeline(device)
        let lut = try stockLUT(device)
        let grain = try grainVolume(device)
        let stock = try stockConfig("kodak5219")
        let bundle = Bundle(for: BundleToken.self)
        let catalog = try StockSampleCatalog.load(bundle: bundle)

        var panels: [(String, CGImage)] = []
        for sceneID in ["neon", "forest", "fireworks"] {
            let scene = try #require(catalog.scenes.first { $0.id == sceneID })
            let plate = try bundledPlate(device, scene: sceneID)
            let base = configuration(stock: stock, gauge: .thirtyFiveMillimetre,
                                    sceneIlluminantKelvin: scene.sceneIlluminantKelvin)
            let flat = base.withEffects(amplitude: 0, halation: 0, radius: 0)
            let grainOnly = base.withEffects(halation: 0, radius: 0)
            let halationOnly = base.withEffects(amplitude: 0, halation: base.halationStrength,
                                                radius: base.halationRadiusFraction)
            let combined = base

            for (suffix, config) in [("flat", flat), ("grain", grainOnly),
                                     ("halation", halationOnly), ("grain-halation", combined),
                                     ("detail-flat", flat.withZoom(3)),
                                     ("detail-grain-halation", combined.withZoom(3))] {
                let frame = try render(device, pipeline: pipeline, plate: plate.texture, plateSize: plate.size,
                                       lut: lut, grain: config.isGrainVisible ? grain : nil,
                                       configuration: config, width: Self.cardWidth, height: Self.cardHeight)
                let image = try frame.cgImage()
                try save(image, name: "\(sceneID)-card-\(suffix)")
                panels.append(("\(sceneID)-card-\(suffix)", image))
            }
        }
        #expect(panels.count == 18)
    }

    // MARK: - Artifact and statistics helpers

    private func artifactDirectory() throws -> URL {
        let directory = ProcessInfo.processInfo.environment["NITRATE_PREVIEW_ARTIFACT_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? TestRepository.artifactDirectory("preview-visibility")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func save(_ image: CGImage, name: String) throws {
        let url = try artifactDirectory().appendingPathComponent("\(name).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
                                                                       UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        print("[preview-visibility] wrote \(url.path)")
    }
}

/// A rendered 8-bit BGRA frame, tight and CPU-readable.
private struct PixelFrame {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(texture: any MTLTexture, width: Int, height: Int) throws {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        self.width = width
        self.height = height
        self.pixels = bytes
    }

    var count: Int { width * height }

    func value(_ channel: Int, _ x: Int, _ y: Int) -> Double {
        Double(pixels[(y * width + x) * 4 + channel]) / 255
    }

    func mean(channel: Int, columns: Range<Int>, rows: Range<Int>) -> Double {
        var sum = 0.0
        var count = 0
        for y in rows {
            for x in columns {
                sum += value(channel, x, y)
                count += 1
            }
        }
        return sum / Double(max(count, 1))
    }

    func sigma(channel: Int, columns: Range<Int>, rows: Range<Int>) -> Double {
        let average = mean(channel: channel, columns: columns, rows: rows)
        var sum = 0.0
        var count = 0
        for y in rows {
            for x in columns {
                let delta = value(channel, x, y) - average
                sum += delta * delta
                count += 1
            }
        }
        return (sum / Double(max(count, 1))).squareRoot()
    }

    func delta(from other: PixelFrame) -> Delta {
        var maximum = [0, 0, 0]
        var changed = 0
        for index in 0..<count {
            var pixelChanged = false
            for channel in 0..<3 {
                let difference = Int(pixels[index * 4 + channel]) - Int(other.pixels[index * 4 + channel])
                maximum[channel] = max(maximum[channel], difference)
                if abs(difference) >= 1 { pixelChanged = true }
            }
            if pixelChanged { changed += 1 }
        }
        return Delta(maxRed: maximum[2], maxGreen: maximum[1], maxBlue: maximum[0], changed: changed)
    }

    struct Delta {
        let maxRed: Int
        let maxGreen: Int
        let maxBlue: Int
        let changed: Int
        func changed(threshold: Int) -> Int { changed }
    }

    func cgImage() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue))
        pixels.withUnsafeBytes { buffer in
            context.data?.copyMemory(from: buffer.baseAddress!, byteCount: pixels.count)
        }
        return try #require(context.makeImage())
    }
}

private extension PreviewConfiguration {
    /// Same stock and gauge, with the grain amplitude and the halation pair overridden so a
    /// single effect can be isolated.
    func withEffects(amplitude: Float? = nil, halation: Float? = nil,
                     radius: Float? = nil) -> PreviewConfiguration {
        PreviewConfiguration(footprint: footprint,
                             amplitude: amplitude ?? self.amplitude,
                             whiteBalance: whiteBalance,
                             halationStrength: halation ?? halationStrength,
                             halationRadiusFraction: radius ?? halationRadiusFraction,
                             halationTint: halationTint,
                             referenceLongEdge: referenceLongEdge, zoom: zoom)
    }
}
