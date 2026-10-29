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

    @Test func stillPhotoGrainReadsAtStillPresenceStrength() throws {
        // A flat mid-grey through the shipping still stages: the only variation
        // can be grain. Video re-randomises per frame and reads ~2x louder than
        // one static slice, so the still stage applies GrainModel.stillPresenceGain.
        let input = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18))
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        let film = try StillFilmRenderResources(stockID: "kodak5219", gauge: .sixteenMillimetre,
            seed: 11, bundle: Bundle(for: BundleToken.self))
        let developed = try DevelopmentPhotoRenderer.develop(linearImage: input, film: film)
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        film.context.render(developed, toBitmap: &bytes, rowBytes: 256 * 4,
            bounds: input.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        let luma = stride(from: 0, to: bytes.count, by: 4).map { Double(bytes[$0]) }
        let mean = luma.reduce(0, +) / Double(luma.count)
        let sigma = (luma.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(luma.count)).squareRoot()
        // Unboosted 16mm grain measured ~1.5 code steps here; a static slice at
        // that strength is invisible. Require the boosted field to clear 4.
        #expect(sigma > 4.0, "Static still grain must clear the visible floor: sigma=\(sigma)")
        #expect(GrainModel.stillPresenceGain > 1, "A still needs a presence boost over per-frame video grain")
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
        #expect(monoSigma > 4.0, "The still grain must still be visible: sigma=\(monoSigma)")
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
