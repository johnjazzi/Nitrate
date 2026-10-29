import Foundation
import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers
import Testing

@Suite(.serialized)
struct PhotoDevelopmentPipelineTests {
    private final class BundleToken {}
    private final class Counter: @unchecked Sendable { var value = 0 }

    @Test func rawDestinationIsWritableAndPreservesLinearSamples() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let decoder = try RAWPhotoDecoder(device: device, queue: queue)
        let source = CIImage(color: CIColor(red: 0.18, green: 0.10, blue: 0.06))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let texture = try decoder.renderLinearImage(source)
        #expect(texture.usage.contains(.renderTarget))
        #expect(texture.usage.contains(.shaderWrite))
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let image = try #require(CIImage(mtlTexture: texture, options: [.colorSpace: space]))
        let context = CIContext(options: [.workingColorSpace: space])
        var actual = [Float](repeating: 0, count: 4)
        var expected = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &actual, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        context.render(source, toBitmap: &expected, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        for channel in 0..<4 { #expect(abs(actual[channel] - expected[channel]) < 0.002) }
    }

    @Test func rawDestinationPreservesSpatialStructureInsteadOfCollapsing() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let decoder = try RAWPhotoDecoder(device: device, queue: queue)
        // A horizontal ramp: every earlier white-render regression collapsed this
        // to a single constant because the destination texture was not written.
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 255, y: 0),
            "inputColor0": CIColor(red: 0.0, green: 0.0, blue: 0.0),
            "inputColor1": CIColor(red: 1.0, green: 1.0, blue: 1.0),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 8))
        let texture = try decoder.renderLinearImage(ramp)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let image = try #require(CIImage(mtlTexture: texture, options: [.colorSpace: space]))
        var pixels = [Float](repeating: 0, count: 256 * 8 * 4)
        CIContext(options: [.workingColorSpace: space]).render(image, toBitmap: &pixels, rowBytes: 256 * 16,
            bounds: CGRect(x: 0, y: 0, width: 256, height: 8), format: .RGBAf, colorSpace: space)
        let reds = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
        let left = reds.prefix(16).reduce(0, +) / 16
        let right = reds.suffix(16).reduce(0, +) / 16
        #expect(right - left > 0.5, "The RAW destination must carry the full ramp, not one value")
        #expect(reds.allSatisfy { $0.isFinite && $0 >= -0.05 && $0 <= 1.05 })
    }

    @Test @MainActor func redevelopingACompletedPhotoJobRendersAgainFromTheOriginal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.dng")
        try Data([1]).write(to: source)
        let persistence = folder.appendingPathComponent("queue.json")
        let renders = Counter()
        let model = RenderQueueViewModel(persistenceURL: persistence,
            render: { job in
                renders.value += 1
                let output = folder.appendingPathComponent("output-\(renders.value).jpg")
                try CIContext().writeJPEGRepresentation(of: CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
                    .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)), to: output,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                return output
            }, save: { _ in })
        let id = try #require(model.enqueuePhoto(sourceURL: source, stockId: "kodak5219", iso: 500,
            gauge: .sixteenMillimetre, cropZoom: 1, seed: 7))
        for _ in 0..<300 {
            if model.jobs.first(where: { $0.id == id })?.status == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstOutput = try #require(model.jobs.first(where: { $0.id == id })?.outputURL)
        model.redevelopPhoto(jobId: id)
        for _ in 0..<300 {
            guard let job = model.jobs.first(where: { $0.id == id }) else { break }
            if job.status == .completed, job.outputURL != firstOutput { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let job = try #require(model.jobs.first(where: { $0.id == id }))
        #expect(renders.value == 2)
        #expect(job.status == .completed)
        #expect(job.outputURL != firstOutput)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func shippingPhotoStagesApplyStockAndGaugeAndRepeatTheSameSeed() throws {
        let input = CIImage(color: CIColor(red: 0.18, green: 0.10, blue: 0.06))
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        func pixels(stock: String, gauge: PrintGauge, seed: UInt32) throws -> [UInt8] {
            let film = try StillFilmRenderResources(stockID: stock, gauge: gauge, seed: seed,
                bundle: Bundle(for: BundleToken.self))
            let developed = try DevelopmentPhotoRenderer.develop(linearImage: input, film: film)
            var bytes = [UInt8](repeating: 0, count: 96 * 64 * 4)
            film.context.render(developed, toBitmap: &bytes, rowBytes: 96 * 4,
                bounds: input.extent, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            return bytes
        }
        let tungsten = try pixels(stock: "kodak5219", gauge: .sixteenMillimetre, seed: 42)
        let repeated = try pixels(stock: "kodak5219", gauge: .sixteenMillimetre, seed: 42)
        let daylight = try pixels(stock: "kodak5207", gauge: .sixteenMillimetre, seed: 42)
        let neutral = try pixels(stock: "kodak5219", gauge: .neutral, seed: 42)
        let repeatMatches = tungsten == repeated
        let stockChangesPixels = tungsten != daylight
        let gaugeChangesPixels = tungsten != neutral
        #expect(repeatMatches)
        #expect(stockChangesPixels)
        #expect(gaugeChangesPixels)
        #expect(Set(tungsten).count > 4, "The shipping grain kernel must produce spatial variation")
    }

    /// Native float residuals from the real still stage and shipped grain volume.
    /// The upper half is an unclipped midtone patch; the lower half carries a
    /// ramp/checker so output inequality is also checked on nonuniform content.
    private func grainProbe(film: StillFilmRenderResources, seed: UInt32 = 42,
                            gain: Float? = nil) throws -> (pixels: [Float16], rms: Double, lag: Double) {
        let side = 256
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: side, height: side, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let input = try #require(film.device.makeTexture(descriptor: descriptor))
        var source = [Float16](repeating: 1, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let value: Float = y < side / 2 ? 0.5
                    : 0.25 + 0.4 * Float(x) / Float(side - 1) + (((x / 4 + y / 4) % 2 == 0) ? 0.05 : 0)
                for channel in 0..<3 { source[(y * side + x) * 4 + channel] = Float16(value) }
            }
        }
        source.withUnsafeBytes { bytes in
            input.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: side * 8)
        }
        let output = try #require(film.effects.applyGrain(graded: input, commandQueue: film.queue,
            config: film.config, gauge: film.gauge, seed: seed, stillPresenceGain: gain))
        var pixels = source
        pixels.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!, bytesPerRow: side * 8,
                from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }
        let finiteAndInRange = pixels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        let preservesAlpha = stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 1 }
        #expect(finiteAndInRange)
        #expect(preservesAlpha)
        var residuals = [Double](), neighbors = [Double]()
        func luma(_ x: Int, _ y: Int) -> Double {
            let i = (y * side + x) * 4
            return (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / 3 - 0.5
        }
        // Stay away from the patch boundary and the prefilter's clamp border.
        for y in 8..<120 {
            for x in 8..<247 { residuals.append(luma(x, y)); neighbors.append(luma(x + 1, y)) }
        }
        let count = Double(residuals.count)
        let mean = residuals.reduce(0, +) / count
        let neighborMean = neighbors.reduce(0, +) / count
        var covariance = 0.0, energy = 0.0, neighborEnergy = 0.0
        for index in residuals.indices {
            let a = residuals[index] - mean, b = neighbors[index] - neighborMean
            covariance += a * b; energy += a * a; neighborEnergy += b * b
        }
        let rms = (residuals.reduce(0) { $0 + $1 * $1 } / count).squareRoot()
        let lag = covariance / max((energy * neighborEnergy).squareRoot(), 1e-12)
        return (pixels, rms, lag)
    }

    @Test func productionStillKernelDistinguishesAllFourGaugeFootprintsAndPresence() throws {
        var measurements: [(gauge: PrintGauge, rms: Double, lag: Double)] = []
        var outputs = [[Float16]]()
        for gauge in PrintGauge.allCases {
            let film = try StillFilmRenderResources(stockID: "kodak5219", gauge: gauge, seed: 42,
                bundle: Bundle(for: BundleToken.self))
            var rms = 0.0, lag = 0.0
            for seed: UInt32 in [0, 17, 42, 127] {
                let probe = try grainProbe(film: film, seed: seed)
                rms += probe.rms; lag += probe.lag
                if seed == 42 { outputs.append(probe.pixels) }
            }
            measurements.append((gauge, rms / 4, lag / 4))
        }
        #expect(measurements.count == 4)
        for index in 0..<3 {
            let coarse = measurements[index], fine = measurements[index + 1]
            #expect(coarse.rms > fine.rms, "Still luma residual RMS must fall: \(measurements)")
            #expect(coarse.lag > fine.lag, "Still footprint lag-1 must fall: \(measurements)")
            for other in (index + 1)..<4 {
                let differs = outputs[index] != outputs[other]
                #expect(differs, "\(coarse.gauge.rawValue) must differ from \(measurements[other].gauge.rawValue)")
            }
        }
        let film = try StillFilmRenderResources(stockID: "kodak5219", gauge: .neutral, seed: 42,
            bundle: Bundle(for: BundleToken.self))
        let repeated = try grainProbe(film: film)
        let deterministic = repeated.pixels == outputs[2]
        #expect(deterministic)
    }

    @Test func thirtyFiveMillimetreRoughnessIsReducedFromLegacyGain() throws {
        // Real-DNG comparison selected 1.5 as a conservative reduction from 2.0.
        // Bound synthetic roughness separately from any sensor-noise contribution.
        let film = try StillFilmRenderResources(stockID: "kodak5219", gauge: .neutral, seed: 42,
            bundle: Bundle(for: BundleToken.self))
        for seed: UInt32 in [0, 17, 42, 127] {
            let baseline = try grainProbe(film: film, seed: seed, gain: 2.0)
            let current = try grainProbe(film: film, seed: seed)
            #expect(current.rms > 0)
            #expect(current.rms <= baseline.rms * 0.8,
                "35mm residual RMS must be reduced versus legacy gain=2: \(current.rms) vs \(baseline.rms)")
            let candidate = try grainProbe(film: film, seed: seed, gain: 1.0)
            #expect(candidate.rms < baseline.rms * 0.75,
                "The explicit A/B gain must materially reduce RMS: \(candidate.rms) vs \(baseline.rms)")
            // Gain changes presence, not the spatial footprint.
            #expect(abs(candidate.lag - baseline.lag) < 0.05)
        }
    }

    @Test func stillGainOverrideReachesTheShippingGlowAndGrainPath() throws {
        let input = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        func pixels(gain: Float?) throws -> [Float] {
            let film = try StillFilmRenderResources(stockID: "kodak5219", gauge: .neutral, seed: 42,
                bundle: Bundle(for: BundleToken.self), stillPresenceGain: gain)
            let output = try film.glowAndGrain(input)
            var values = [Float](repeating: 0, count: 256 * 256 * 4)
            film.context.render(output, toBitmap: &values, rowBytes: 256 * 16, bounds: input.extent,
                format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            return values
        }
        let selected = try pixels(gain: 1.5), current = try pixels(gain: nil)
        let candidate = try pixels(gain: 1.0), repeated = try pixels(gain: 1.0)
        // Shipping default must use the candidate selected from controlled A/B.
        let preservesDefault = selected == current
        let deterministic = candidate == repeated
        let changesPixels = candidate != selected
        #expect(preservesDefault)
        #expect(deterministic)
        #expect(changesPixels)
        let finite = candidate.allSatisfy(\.isFinite)
        #expect(finite)
    }

    @Test func stillGrainIsLuminanceDominantNotColoured() throws {
        // Regression: the still path applied the video dye-cloud term at full
        // strength, and a single 3024-px frame inspected at 1:1 showed it as
        // red/green/blue specks. Real emulsion grain is a density fluctuation, so
        // the shared (monochrome) part must dominate the anti-correlated R/B part.
        let input = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18))
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        let film = try StillFilmRenderResources(stockID: "kodak5219", gauge: .sixteenMillimetre,
            seed: 11, bundle: Bundle(for: BundleToken.self))
        let developed = try DevelopmentPhotoRenderer.develop(linearImage: input, film: film)
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        film.context.render(developed, toBitmap: &bytes, rowBytes: 256 * 4,
            bounds: input.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var sums = [Double](repeating: 0, count: 3)
        let pixels = bytes.count / 4
        for index in 0..<pixels {
            for channel in 0..<3 { sums[channel] += Double(bytes[index * 4 + channel]) }
        }
        let means = sums.map { $0 / Double(pixels) }
        var mono = 0.0, chroma = 0.0
        for index in 0..<pixels {
            let red = Double(bytes[index * 4]) - means[0]
            let green = Double(bytes[index * 4 + 1]) - means[1]
            let blue = Double(bytes[index * 4 + 2]) - means[2]
            mono += pow((red + green + blue) / 3, 2)
            chroma += pow(red - blue, 2)
        }
        let monoSigma = (mono / Double(pixels)).squareRoot()
        let chromaSigma = (chroma / Double(pixels)).squareRoot()
        #expect(monoSigma > 0, "The chroma ratio requires a nonzero luminance residual: sigma=\(monoSigma)")
        let ratio = chromaSigma / max(monoSigma, 0.0001)
        #expect(ratio < 0.25, "Still grain must read as monochrome, not coloured: R-B sigma is \(ratio)x the luminance sigma")
        #expect(GrainModel.stillChromaAmount < GrainModel.videoChromaAmount,
                "A still needs less dye-cloud chroma than per-frame video grain")
    }

    @Test func photoReceiptHasRealDimensionsAndThumbnailWithoutVideoFields() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = CIContext()
        let image = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        try context.writeJPEGRepresentation(of: image, to: url,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let receipt = await RenderReceiptService.capture(url: url, renderDurationSeconds: 0.5)
        #expect(receipt.pixelWidth == 640)
        #expect(receipt.pixelHeight == 480)
        #expect(receipt.codec == UTType.jpeg.identifier)
        #expect(receipt.framesPerSecond == nil)
        #expect(receipt.durationSeconds == nil)
        let data = try #require(receipt.thumbnailJPEG)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let thumbnail = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(thumbnail.width, thumbnail.height) <= 320)
    }

    @Test @MainActor func photoQueuePersistsSettingsAndRetainsDevelopedPreviewAndOriginal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("queue-unit-fixture.dng")
        let output = folder.appendingPathComponent("developed.jpg")
        // The queue ownership test injects rendering; this is not a RAW decode fixture.
        try Data([1]).write(to: source)
        let image = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        try CIContext().writeJPEGRepresentation(of: image, to: output,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var saved: [URL] = []
        let persistence = folder.appendingPathComponent("queue.json")
        let model = RenderQueueViewModel(persistenceURL: persistence,
            render: { job in
                #expect(job.isPhoto == true)
                #expect(job.stockId == "kodak5219")
                #expect(job.photoGrainSeed == 73)
                #expect(job.photoCropZoom == 1.5)
                return output
            }, save: { saved.append($0) })
        let id = try #require(model.enqueuePhoto(sourceURL: source, stockId: "kodak5219", iso: 500,
            gauge: .sixteenMillimetre, cropZoom: 1.5, seed: 73))
        for _ in 0..<300 {
            if model.jobs.first(where: { $0.id == id })?.status == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let job = try #require(model.jobs.first(where: { $0.id == id }))
        #expect(job.status == .completed)
        #expect(job.outputSavedToPhotos == true)
        #expect(saved == [output])
        #expect(job.retainedOutputURL == output)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(job.receipt?.thumbnailJPEG != nil)
        let persisted = try JSONDecoder().decode([RenderJob].self, from: Data(contentsOf: persistence))
        #expect(persisted.first?.isPhoto == true)
        #expect(persisted.first?.photoGrainSeed == 73)
    }
}
