import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
import simd

/// Native GPU regressions for the stock-selector preview's effects chain.
///
/// The preview must stand in for a full-size render of the same stock and show the same
/// effects the composed clip does, so these tests drive the shipping
/// `PlatePreviewPipeline` on real Metal textures -- the compiled `camera-preview.metal`
/// kernels plus the production `SpatialEffectsStage` halation -- and measure the pixels:
///
///   * grain is sized in the REFERENCE frame's pixels, so a cell shrinks in proportion as the
///     drawable shrinks, and subpixel grain is damped rather than aliased;
///   * grain presence follows the print gauge, from 8mm down to a nearly silent 75mm;
///   * halation is real energy appearing around a bright spot and absent on dark input;
///   * the stock's reduced halation total amount is carried, not reduced a second time;
///   * the CPU uniform mirror matches the shader's struct layout;
///   * a real bundled scene renders to 8-bit PNG, including the before/after comparison.
struct PlatePreviewEffectsTests {
    private final class BundleToken {}

    // MARK: - Fixtures

    private static let identityWhiteBalance = matrix_identity_float3x3
    private static let defaultTint = SIMD3<Float>(1.0, 0.32, 0.10)

    private func device() throws -> any MTLDevice {
        try #require(MTLCreateSystemDefaultDevice())
    }

    private func library(_ device: any MTLDevice) throws -> any MTLLibrary {
        try device.makeDefaultLibrary(bundle: Bundle(for: BundleToken.self))
    }

    private func pipeline(_ device: any MTLDevice) throws -> PlatePreviewPipeline {
        let queue = try #require(device.makeCommandQueue())
        return try PlatePreviewPipeline(device: device, library: try library(device), queue: queue)
    }

    /// A uniform plate at one Apple Log 2 code value. With a uniform plate and an identity LUT
    /// the only structure in the output is the grain the pass adds, so its statistics can be
    /// measured directly.
    private func uniformPlate(_ device: any MTLDevice, side: Int, code: UInt8) throws -> any MTLTexture {
        try makePlate(device, width: side, height: side) { _, _ in (code, code, code) }
    }

    private func makePlate(_ device: any MTLDevice, width: Int, height: Int,
                           _ code: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: width, height: height,
                                                                 mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue) = code(x, y)
                let index = (y * width + x) * 4
                bytes[index] = blue
                bytes[index + 1] = green
                bytes[index + 2] = red
                bytes[index + 3] = 255
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    /// An identity `33^3` LUT: trilinear sampling returns the input coordinate to within the
    /// sampler's interpolation precision, so it isolates the effect chain from a grade.
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

    private func grainVolume(_ device: any MTLDevice) throws -> any MTLTexture {
        try #require(PlatePreviewPipeline.makeGrainVolume(device: device, bundle: Bundle(for: BundleToken.self)))
    }

    private func makeTarget(_ device: any MTLDevice, width: Int, height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: width, height: height,
                                                                 mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// Run one full effect pass at the given drawable size and read the 8-bit BGRA result back.
    private func renderFx(_ device: any MTLDevice, pipeline: PlatePreviewPipeline,
                          plate: any MTLTexture, plateSize: SIMD2<Float>,
                          lut: any MTLTexture, grain: (any MTLTexture)?,
                          configuration: PreviewConfiguration,
                          width: Int, height: Int) throws -> Frame {
        try pipeline.load(plateTexture: plate, plateSize: plateSize, lutTexture: lut,
                          grainVolume: grain, configuration: configuration)
        let target = try makeTarget(device, width: width, height: height)
        let rendered = pipeline.render(into: target, drawableSize: CGSize(width: width, height: height))
        #expect(rendered, "the preview pass must complete")
        return try read(target, width: width, height: height)
    }

    private func read(_ texture: any MTLTexture, width: Int, height: Int) throws -> Frame {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return Frame(width: width, height: height, pixels: pixels)
    }

    private func configuration(footprint: Float, amplitude: Float,
                               halationStrength: Float = 0,
                               halationRadiusFraction: Float = 0,
                               referenceLongEdge: Float = PreviewConfiguration.defaultReferenceLongEdge,
                               tint: SIMD3<Float>? = nil) -> PreviewConfiguration {
        PreviewConfiguration(footprint: footprint, amplitude: amplitude,
                             whiteBalance: Self.identityWhiteBalance,
                             halationStrength: halationStrength,
                             halationRadiusFraction: halationRadiusFraction,
                             halationTint: tint ?? Self.defaultTint,
                             referenceLongEdge: referenceLongEdge)
    }

    // MARK: - Uniform ABI

    /// The CPU mirror must match the shader's `PlatePreviewUniforms` exactly. A field added on
    /// only one side changes the stride or a later offset and fails here before it silently
    /// scrambles the uniforms on device. `platePrepareUniformsMatchTheShaderLayout` does the
    /// same for the white-balance pass.
    @Test func previewUniformsMatchTheShaderLayout() {
        #expect(MemoryLayout<PlatePreviewUniformsCPU>.stride == 40)
        #expect(MemoryLayout<PlatePreviewUniformsCPU>.alignment == 8)
        #expect(MemoryLayout<PlatePreviewUniformsCPU>.offset(of: \.uvScale) == 0)
        #expect(MemoryLayout<PlatePreviewUniformsCPU>.offset(of: \.drawableSize) == 8)
        #expect(MemoryLayout<PlatePreviewUniformsCPU>.offset(of: \.footprint) == 16)
        #expect(MemoryLayout<PlatePreviewUniformsCPU>.offset(of: \.amplitude) == 20)
        #expect(MemoryLayout<PlatePreviewUniformsCPU>.offset(of: \.offset) == 24)
        #expect(MemoryLayout<PlatePreviewUniformsCPU>.offset(of: \.referenceLongEdge) == 28)
        #expect(MemoryLayout<PlatePreviewUniformsCPU>.offset(of: \.zoom) == 32)
    }

    @Test func platePrepareUniformsMatchTheShaderLayout() {
        // float3x3 is three padded float3 columns on both sides.
        #expect(MemoryLayout<PlatePrepareUniformsCPU>.stride == 48)
        #expect(MemoryLayout<PlatePrepareUniformsCPU>.alignment == 16)
        #expect(MemoryLayout<PlatePrepareUniformsCPU>.offset(of: \.whiteBalance) == 0)
    }

    // MARK: - Grain scale

    /// The grain cell is sized in the reference frame's pixels, so at a drawable twice as
    /// large each cell covers twice as many pixels. Measured as the mean absolute difference
    /// between horizontally adjacent pixels of a uniform plate: with the same amplitude and
    /// damping saturated at one, that roughness is inversely proportional to the cell size, so
    /// it must roughly halve when the drawable doubles.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func grainCellShrinksInProportionToTheDrawable() throws {
        let device = try device()
        let pipeline = try pipeline(device)
        let plate = try uniformPlate(device, side: 512, code: 128)
        let lut = try identityLUT(device)
        let grain = try grainVolume(device)
        // 8mm on a 1.3 stock: 5.2 reference pixels per cell, so both drawables resolve it.
        let config = configuration(footprint: 5.2, amplitude: 0.1)

        func roughness(_ width: Int) throws -> Double {
            let frame = try renderFx(device, pipeline: pipeline, plate: plate,
                                     plateSize: SIMD2(512, 512), lut: lut, grain: grain,
                                     configuration: config, width: width, height: width)
            return frame.meanAbsoluteHorizontalDifference(channel: 2,
                                                          columns: 64..<(width - 64),
                                                          rows: (width / 4)..<(3 * width / 4))
        }

        let small = try roughness(1024)
        let large = try roughness(2048)
        #expect(small > 0.002, "grain must be present at the small drawable (was \(small))")
        #expect(large > 0.002, "grain must be present at the large drawable (was \(large))")
        let ratio = small / large
        #expect(ratio > 1.4 && ratio < 2.8,
                "doubling the drawable must roughly halve the grain cell: ratio \(ratio)")
    }

    /// Subpixel grain fades instead of aliasing. Averaging the cells inside one output pixel
    /// reduces the noise RMS by sqrt(count) = the cell's size in drawable pixels, so a cell
    /// well under one pixel must measure far weaker while staying present.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func subpixelGrainIsDampedRatherThanAliased() throws {
        let device = try device()
        let pipeline = try pipeline(device)
        let plate = try uniformPlate(device, side: 512, code: 128)
        let lut = try identityLUT(device)
        let grain = try grainVolume(device)

        func sigma(footprint: Float) throws -> Double {
            let frame = try renderFx(device, pipeline: pipeline, plate: plate,
                                     plateSize: SIMD2(512, 512), lut: lut, grain: grain,
                                     configuration: configuration(footprint: footprint, amplitude: 0.1),
                                     width: 1024, height: 1024)
            return frame.sigma(channel: 2, columns: 128..<896, rows: 128..<896)
        }

        // Cell 1.23 px (resolved) versus cell 0.25 px (subpixel).
        let resolved = try sigma(footprint: 4.6)
        let subpixel = try sigma(footprint: 0.95)
        #expect(resolved > 0.002, "resolved grain must be present (was \(resolved))")
        #expect(subpixel > 0.0005, "subpixel grain must fade, not vanish (was \(subpixel))")
        #expect(subpixel < resolved * 0.5,
                "a subpixel cell must be damped well below a resolved one (resolved \(resolved), subpixel \(subpixel))")
    }

    /// The gauge owns presence: 8mm is loudest and 75mm nearly silent, and the ordering holds
    /// across the ladder. Measured as the output standard deviation of a uniform plate, which
    /// is the grain's own amplitude once the constants cancel.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func grainPresenceFollowsThePrintGaugeOrder() throws {
        let device = try device()
        let pipeline = try pipeline(device)
        let plate = try uniformPlate(device, side: 512, code: 128)
        let lut = try identityLUT(device)
        let grain = try grainVolume(device)
        let stock = try stockConfig("kodak5219")

        func sigma(_ gauge: PrintGauge) throws -> Double {
            let config = PreviewConfiguration(stock: stock, gauge: gauge, sceneIlluminantKelvin: 3200)
            let frame = try renderFx(device, pipeline: pipeline, plate: plate,
                                     plateSize: SIMD2(512, 512), lut: lut, grain: grain,
                                     configuration: config, width: 1536, height: 1536)
            return frame.sigma(channel: 2, columns: 128..<1408, rows: 128..<1408)
        }

        let eight = try sigma(.eightMillimetre)
        let sixteen = try sigma(.sixteenMillimetre)
        let thirtyFive = try sigma(.thirtyFiveMillimetre)
        let seventyFive = try sigma(.seventyFiveMillimetre)

        #expect(eight > sixteen && sixteen > thirtyFive && thirtyFive > seventyFive,
                "presence must fall across the ladder: \(eight), \(sixteen), \(thirtyFive), \(seventyFive)")
        #expect(seventyFive < eight * 0.4,
                "75mm must read nearly silent next to 8mm: \(seventyFive) vs \(eight)")
        #expect(eight > 0.002, "8mm grain must be clearly present (was \(eight))")

        // The realised footprints back the same ordering, so both gauge axes move together.
        #expect(GrainModel.effectiveSize(stockGrainSize: stock.grainSize, gauge: .eightMillimetre)
                > GrainModel.effectiveSize(stockGrainSize: stock.grainSize, gauge: .seventyFiveMillimetre))
    }

    /// The reference long edge is the last uniform field and is what rescales the grain: the
    /// legacy implicit reference was the volume's own 128-texel repeat, which is what made the
    /// preview grain 30x too large. Rendering at 128 must therefore produce far coarser grain
    /// -- fewer, much larger cells, so the image varies more slowly pixel to pixel -- proving
    /// the field is read at the right offset.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func referenceLongEdgeUniformControlsTheGrainScale() throws {
        let device = try device()
        let pipeline = try pipeline(device)
        let plate = try uniformPlate(device, side: 512, code: 128)
        let lut = try identityLUT(device)
        let grain = try grainVolume(device)

        func roughness(_ referenceLongEdge: Float) throws -> Double {
            let frame = try renderFx(device, pipeline: pipeline, plate: plate,
                                     plateSize: SIMD2(512, 512), lut: lut, grain: grain,
                                     configuration: configuration(footprint: 2.6, amplitude: 0.1,
                                                                 referenceLongEdge: referenceLongEdge),
                                     width: 1024, height: 1024)
            return frame.meanAbsoluteHorizontalDifference(channel: 2,
                                                          columns: 64..<960, rows: 256..<768)
        }

        let corrected = try roughness(PreviewConfiguration.defaultReferenceLongEdge)
        let legacy = try roughness(128)
        #expect(corrected > 0.0005, "the corrected grain must be present (was \(corrected))")
        #expect(legacy > 0.00005, "the legacy grain must be present (was \(legacy))")
        #expect(corrected > legacy * 5,
                "the corrected reference must resolve far finer grain than the legacy 128-pixel one (corrected \(corrected), legacy \(legacy))")
    }

    // MARK: - Halation

    private static let block = 400..<624

    /// A bright block on a dark field, with a band just outside it where only scattered light
    /// can appear.
    private func blockPlate(_ device: any MTLDevice, side: Int = 1024) throws -> any MTLTexture {
        try makePlate(device, width: side, height: side) { x, y in
            let inside = Self.block.contains(x) && Self.block.contains(y)
            let code: UInt8 = inside ? 230 : 46
            return (code, code, code)
        }
    }

    /// Halation adds real energy outside the highlight, and it is warm. Disabled must show
    /// none of it, so the two renders are measured on the same pixels.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationAddsWarmEnergyAroundTheHighlight() throws {
        let device = try device()
        let pipeline = try pipeline(device)
        let plate = try blockPlate(device)
        let lut = try identityLUT(device)

        func band(_ strength: Float) throws -> [Double] {
            let frame = try renderFx(device, pipeline: pipeline, plate: plate,
                                     plateSize: SIMD2(1024, 1024), lut: lut, grain: nil,
                                     configuration: configuration(footprint: 0, amplitude: 0,
                                                                 halationStrength: strength,
                                                                 halationRadiusFraction: 0.03),
                                     width: 1024, height: 1024)
            return [frame.mean(channel: 2, columns: 640..<760, rows: 420..<600),
                    frame.mean(channel: 1, columns: 640..<760, rows: 420..<600),
                    frame.mean(channel: 0, columns: 640..<760, rows: 420..<600)]
        }

        let disabled = try band(0)
        let enabled = try band(2.52)

        let addedRed = enabled[0] - disabled[0]
        let addedGreen = enabled[1] - disabled[1]
        #expect(addedRed > 0.01, "halation must add light outside the highlight (was \(addedRed))")
        #expect(addedRed > addedGreen,
                "halation light must be red-dominant (red \(addedRed), green \(addedGreen))")
        // The dark field must be unchanged where no light scatters, so this is local energy.
        #expect(abs(disabled[0] - disabled[1]) < 0.01, "the dark field is neutral before halation")
    }

    /// Dark input stays dark: a frame whose scene light never clears red's knee produces an
    /// empty halation mask, so enabling halation must not change it beyond float rounding.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationLeavesDarkInputUnchanged() throws {
        let device = try device()
        let pipeline = try pipeline(device)
        let plate = try uniformPlate(device, side: 512, code: 140)   // decoded linear ~0.30
        let lut = try identityLUT(device)

        func frame(_ strength: Float) throws -> Frame {
            try renderFx(device, pipeline: pipeline, plate: plate,
                         plateSize: SIMD2(512, 512), lut: lut, grain: nil,
                         configuration: configuration(footprint: 0, amplitude: 0,
                                                     halationStrength: strength,
                                                     halationRadiusFraction: 0.03),
                         width: 512, height: 512)
        }

        let disabled = try frame(0)
        let enabled = try frame(2.52)
        let maximumDifference = zip(disabled.pixels, enabled.pixels)
            .map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
        #expect(maximumDifference <= 2,
                "halation must not touch input below the knees (max byte difference \(maximumDifference))")
    }

    /// The 30% halation reduction lives in the catalogs only. The configuration must carry the
    /// stock's value unchanged, so neither the preview nor the renderer multiplies by 0.7 a
    /// second time.
    @Test func previewCarriesTheStocksReducedHalationWithoutReapplyingIt() throws {
        let stock = try stockConfig("kodak5219")
        #expect(abs(stock.halationStrength - 2.52) < 0.0001,
                "the bundle must carry the reduced total amount")
        for gauge in PrintGauge.allCases {
            let config = PreviewConfiguration(stock: stock, gauge: gauge, sceneIlluminantKelvin: 3600)
            #expect(config.halationStrength == stock.halationStrength,
                    "the preview must pass the catalog value through, not reduce it again")
            #expect(config.halationRadiusFraction == stock.halationRadiusFraction)
            #expect(config.halationTint == stock.halationTint)
        }
        // The gauge must not disturb the stock's halation geometry.
        let a = PreviewConfiguration(stock: stock, gauge: .eightMillimetre, sceneIlluminantKelvin: 3600)
        let b = PreviewConfiguration(stock: stock, gauge: .seventyFiveMillimetre, sceneIlluminantKelvin: 3600)
        #expect(a.halationStrength == b.halationStrength && a.halationRadiusFraction == b.halationRadiusFraction)
    }

    // MARK: - Real 8-bit output fixture

    /// Renders a real bundled scene through the shipping chain at 8-bit and writes the
    /// before/after comparison plus its four panels as PNGs. "Before" is the same shipping
    /// shader with the legacy implicit reference (the 128-texel volume repeat) that made the
    /// grain 30x too large; "after" is the corrected 4K reference. The halation row uses the
    /// stock's reduced total amount with its radius widened to 0.02 so a static card shows the
    /// halo; the third panel-free image renders the true stock geometry.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func writesBeforeAfterComparisonFixture() throws {
        let device = try device()
        let pipeline = try pipeline(device)
        let bundle = Bundle(for: BundleToken.self)
        let catalog = try StockSampleCatalog.load(bundle: bundle)
        let scene = try #require(catalog.scenes.first { $0.id == "neon" } ?? catalog.scenes.first)
        let image = try #require(PlateImage.load(scene.plateURL(directory: catalog.directory)))
        let plate = try PlatePreviewPipeline.makePlateTexture(image, device: device)
        let plateSize = SIMD2(Float(image.width), Float(image.height))
        let cube = try PlateCube.parse(try lutText("5219 - Apple Log 2.cube"))
        let lut = try PlatePreviewPipeline.makeLUTTexture(cube, device: device)
        let grain = try grainVolume(device)

        let stock = try stockConfig("kodak5219")
        let gauge: PrintGauge = .eightMillimetre
        let base = PreviewConfiguration(stock: stock, gauge: gauge,
                                        sceneIlluminantKelvin: scene.sceneIlluminantKelvin)

        let width = 540
        let height = 810
        // Row 0: grain only. Row 1: grain plus halation at a radius widened for legibility.
        let grainOnly = base.withHalation(strength: 0, radius: 0)
        let halationLab = base.withHalation(strength: base.halationStrength, radius: 0.02)
        let panels: [(String, PreviewConfiguration)] = [
            ("before-grain", grainOnly.withReference(128)),
            ("after-grain", grainOnly),
            ("before-grain-halation", halationLab.withReference(128)),
            ("after-grain-halation", halationLab),
            ("after-stock-halation", base),
        ]
        var images: [CGImage] = []
        for (name, config) in panels {
            let frame = try renderFx(device, pipeline: pipeline, plate: plate, plateSize: plateSize,
                                     lut: lut, grain: config.isGrainVisible ? grain : nil,
                                     configuration: config, width: width, height: height)
            let cgImage = try frame.cgImage()
            try save(cgImage, name: name)
            images.append(cgImage)
        }

        // The comparison sheet: grain-only on the top row, grain plus halation below.
        let sheet = try composite([images[0], images[1], images[2], images[3]], columns: 2, rows: 2)
        try save(sheet, name: "preview-before-after")
    }

    // MARK: - Helpers

    private func lutText(_ name: String) throws -> String {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: nil)
            ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "LUTs"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private struct Container: Decodable { let stocks: [FilmStockConfig] }

    private func stockConfig(_ id: String) throws -> FilmStockConfig {
        let bundle = Bundle(for: BundleToken.self)
        let url = bundle.url(forResource: "stocks", withExtension: "json")
            ?? TestRepository.url(for: "App/Resources/stocks.json")
        let container = try JSONDecoder().decode(Container.self, from: Data(contentsOf: url))
        return try #require(container.stocks.first { $0.stockId == id })
    }

    /// Diagnostic renders are written outside the source checkout and signed bundle.
    private func artifactDirectory() throws -> URL {
        let directory = ProcessInfo.processInfo.environment["NITRATE_PREVIEW_ARTIFACT_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? TestRepository.artifactDirectory("preview-effects")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func save(_ image: CGImage, name: String) throws {
        let url = try artifactDirectory().appendingPathComponent("\(name).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
                                                                      UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        print("[preview-effects] wrote \(url.path)")
    }

    private func composite(_ images: [CGImage], columns: Int, rows: Int) throws -> CGImage {
        let tileWidth = images[0].width
        let tileHeight = images[0].height
        let width = tileWidth * columns
        let height = tileHeight * rows
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (index, image) in images.enumerated() {
            let column = index % columns
            let row = index / columns
            // CGContext's origin is bottom-left; place row 0 at the top.
            context.draw(image, in: CGRect(x: column * tileWidth,
                                           y: height - (row + 1) * tileHeight,
                                           width: tileWidth, height: tileHeight))
        }
        return try #require(context.makeImage())
    }
}

/// A rendered 8-bit BGRA frame, tight and CPU-readable.
private struct Frame {
    let width: Int
    let height: Int
    let pixels: [UInt8]

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

    /// Population standard deviation over a rectangle.
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

    /// Mean absolute difference between horizontally adjacent pixels -- a direct proxy for how
    /// fast the grain varies, i.e. how small its cells are in pixels.
    func meanAbsoluteHorizontalDifference(channel: Int, columns: Range<Int>, rows: Range<Int>) -> Double {
        var sum = 0.0
        var count = 0
        for y in rows {
            for x in columns where x + 1 < width {
                sum += abs(value(channel, x + 1, y) - value(channel, x, y))
                count += 1
            }
        }
        return sum / Double(max(count, 1))
    }

    func cgImage() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: width * 4,
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
    func withReference(_ longEdge: Float) -> PreviewConfiguration {
        PreviewConfiguration(footprint: footprint, amplitude: amplitude, whiteBalance: whiteBalance,
                             halationStrength: halationStrength,
                             halationRadiusFraction: halationRadiusFraction,
                             halationTint: halationTint, referenceLongEdge: longEdge)
    }

    func withHalation(strength: Float, radius: Float) -> PreviewConfiguration {
        PreviewConfiguration(footprint: footprint, amplitude: amplitude, whiteBalance: whiteBalance,
                             halationStrength: strength, halationRadiusFraction: radius,
                             halationTint: halationTint, referenceLongEdge: referenceLongEdge)
    }
}
