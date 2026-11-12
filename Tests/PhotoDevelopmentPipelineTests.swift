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

    /// A still that the RAW decode lifted by N stops must be measured against the
    /// same onsets as a take; the lift moves the FRAME, not the threshold.
    ///
    /// This is the bug behind "raw gets more halation than video": a ProRAW
    /// carrying BaselineExposure +2.99 EV put an indoor wall at ~2x nominal white
    /// while the thresholds stayed on the unlifted scale, so an ordinary lit
    /// surface cleared red AND green on every pixel and the whole frame bloomed
    /// orange. The fix is an offset in the frame, not a weaker stock, so the halo
    /// around a true specular is unchanged.
    @Test func liftedStillsMeasureAgainstTheSameOnsets() {
        let onsets = SpatialEffectsStage.halationOnsets()
        #expect(onsets == SpatialEffectsStage.authoredOnsets)
        #expect(onsets.x < onsets.y && onsets.y < onsets.z, "red comes on first")

        // The scene level a layer triggers at, in the frame the mask reads.
        func trigger(onset: Float, lift: Float) -> Float {
            pow(2, onset + SpatialEffectsStage.frameWhiteStops(sceneLiftStops: lift))
        }
        // A lift raises the trigger by exactly the lift, so the halo stays on the
        // same scene light however the file was exposed: a still and a take of one
        // scene grade the same way.
        let unlifted = trigger(onset: onsets.x, lift: 0)
        let lifted = trigger(onset: onsets.x, lift: 2.988)
        #expect(abs(lifted / unlifted - pow(2, 2.988)) < 0.001,
                "the trigger must follow the decode lift exactly")

        // The wall the lift put at 1.59x: with the authored onsets it sits BELOW
        // red's lifted trigger, so an ordinary lit wall does not scatter at all.
        // That is the job the onsets do, and it is why raising them from the debug
        // sheet's outdoor scene mattered.
        let wall: Float = 1.59
        #expect(wall < lifted, "the lifted wall must not reach red's trigger")
        #expect(wall < trigger(onset: onsets.x, lift: 0) * powf(2, 2.988),
                "nor an unlifted one, at the same scene light")

        // A genuine specular still clears every layer, so the halo does not vanish.
        let specular: Float = 20
        for onset in [onsets.x, onsets.y, onsets.z] {
            #expect(specular > trigger(onset: onset, lift: 2.988),
                    "a bright specular must still clear every layer")
        }
    }

    /// The delivered onsets, and where the compensation for holding the capture
    /// under now lives: the frame offset, and nothing else.
    @Test func theDeliveredOnsetIsTheAuthoredOnset() {
        let scheme = SystemExposureScheme.self
        #expect(scheme.captureStops == -1, "the scheme captures one stop under")
        #expect(scheme.developLiftStops == -scheme.captureStops,
                "the develop lift is the capture stop put back, or the delivered exposure moves")

        let onsets = SpatialEffectsStage.halationOnsets()
        #expect(abs(powf(2, onsets.x) - 0.75262) < 0.001, "red responds from 0.75x diffuse white")
        #expect(abs(powf(2, onsets.y) - 1.32869) < 0.001, "green from 1.33x")
        #expect(abs(powf(2, onsets.z) - 2.98970) < 0.001, "blue from 2.99x")

        // A take is measured a stop under the picture it delivers, and that offset
        // is the whole of the compensation: the same onset lands on the same
        // delivered level without a threshold scale.
        let frameWhite = SpatialEffectsStage.frameWhiteStops(sceneLiftStops: 0)
        #expect(abs(frameWhite - scheme.captureStops) < 0.0001)
        #expect(abs(2 * powf(2, onsets.x + frameWhite) - powf(2, onsets.x)) < 0.001,
                "the mask-frame trigger, doubled by the develop lift, is the delivered onset")
    }

    /// The delivery switch still governs a photo this app CAPTURED; only an
    /// import is exempt. Kept as a pair so the exemption cannot quietly widen.
    @Test func capturedPhotosStillHonourTheOriginalSwitchButImportsDoNot() {
        var job = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/capture.dng"),
                            stockId: "kodak5219", iso: 400)
        job.isPhoto = true
        job.deliveryPreferences = RenderDeliveryPreferences(saveOriginalRAWToPhotos: true)
        #expect(job.shouldSaveOriginal, "a capture returns its raw when asked")

        job.isImportedPhoto = true
        #expect(!job.shouldSaveOriginal, "a develop has nothing to return")

        // And an imported video keeps its existing exemption.
        var movie = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/clip.mov"),
                              stockId: "kodak5219", iso: 400)
        movie.isImportedVideo = true
        movie.deliveryPreferences = RenderDeliveryPreferences(saveOriginalLog: true)
        #expect(!movie.shouldSaveOriginal)
    }

    /// The original-save guard must accept every file the pipeline develops.
    ///
    /// It allowed only `dng`, so an imported Nikon NEF — developed and delivered
    /// fine — was refused here and reported as a failed delivery.
    @Test func originalSaveAcceptsEveryDevelopableRaw() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func file(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            // Bytes ImageIO cannot type at all — the case the name fallback
            // exists for. (A sequential 0..63 pattern sniffs as TGA, which is a
            // rendered image and is correctly refused.)
            try Data(repeating: 0, count: 64).write(to: url)
            return url
        }

        for name in ["DSC_4800.NEF", "shot.ARW", "IMG_0001.CR3", "frame.RAF", "pro.cr2",
                     "capture.DNG", "developed.JPG", "developed.jpeg"] {
            #expect(DevelopmentPhotoLibrarySaver.isStorable(try file(name)),
                    "\(name) must be storable — the renderer develops it")
        }
    }

    /// Decode applies no still lift. The scheme's stop goes back in AFTER the
    /// emulsion, so the frame offset `frameWhiteStops` carries is the capture's own
    /// baseline and nothing else.
    @Test func stillsDecodeWithoutALiftSoTheSceneLiftIsTheCaptureBaseline() {
        #expect(RAWPhotoDecoder.baseExposureEV == 0)
        #expect(RAWPhotoDecoder.sceneLiftStops(baselineExposure: 0) == 0)
        #expect(RAWPhotoDecoder.sceneLiftStops(baselineExposure: 2.988) == 2.988)

        // The frame offset moves with the capture's own baseline, which is the part
        // of the lift a raw decode applies before any film stage sees it; the
        // onsets themselves stay authored.
        let unlifted = SpatialEffectsStage.frameWhiteStops(sceneLiftStops: 0)
        let lifted = SpatialEffectsStage.frameWhiteStops(
            sceneLiftStops: RAWPhotoDecoder.sceneLiftStops(baselineExposure: 2.988))
        #expect(abs(lifted - unlifted - 2.988) < 0.0001)
        #expect(SpatialEffectsStage.halationOnsets() == SpatialEffectsStage.authoredOnsets)
    }

    @Test func nativeFlashUsesItsMeteredExposureWithoutTheAmbientStillLift() {
        #expect(RAWPhotoDecoder.exposureEV(for: .nativePhoto(requested: true, resolved: true)) == 0)
        let controls: [FlashRecord?] = [nil, .off,
            .nativePhoto(requested: true, resolved: false),
            .nativePhoto(requested: true, resolved: nil),
            .nativePhoto(requested: true, resolved: true, refusalReason: "Unavailable"),
            FlashRecord(mode: .native, resolved: false),
            FlashRecord(mode: .native, requested: true),
            FlashRecord(mode: .off, resolved: true),
            FlashRecord(mode: .front, intensityPercent: 100),
            FlashRecord(mode: .rear, intensityPercent: 100),
            FlashRecord(mode: .continuous, intensityPercent: 100)]
        for record in controls {
            #expect(RAWPhotoDecoder.exposureEV(for: record) == RAWPhotoDecoder.baseExposureEV)
        }
        #expect(RAWPhotoDecoder.sceneLiftStops(baselineExposure: 2.988, exposureEV: 0) == 2.988)
        #expect(RAWPhotoDecoder.sceneLiftStops(baselineExposure: 0, exposureEV: 0) == 0)
    }

    /// A DNG offers the DNG-tagged decoder version; a NEF, ARW or CR2 offers its
    /// own and never "8.dng". Requiring the tagged one refused every non-DNG raw
    /// at the first line of the decode, which is what a Nikon file hit.
    @Test func decoderVersionFollowsTheFileInsteadOfDemandingDNG() {
        let dng = CIRAWDecoderVersion(rawValue: "8.dng")
        #expect(RAWPhotoDecoder.preferredDecoderVersion(from: [dng]) == dng)
        // A DNG that also offers a newer numbered version still pins 8.dng.
        #expect(RAWPhotoDecoder.preferredDecoderVersion(
            from: [CIRAWDecoderVersion(rawValue: "9.0"), dng]) == dng)

        // A maker's own raw: no DNG tag, so the newest supported version wins.
        let maker = ["6.0", "8.0", "9.0"].map { CIRAWDecoderVersion(rawValue: $0) }
        #expect(RAWPhotoDecoder.preferredDecoderVersion(from: maker)?.rawValue == "9.0")
        // Natural order, so 10.0 is not below 9.0.
        let wide = ["9.0", "10.0"].map { CIRAWDecoderVersion(rawValue: $0) }
        #expect(RAWPhotoDecoder.preferredDecoderVersion(from: wide)?.rawValue == "10.0")

        // A file that offers nothing cannot be developed, and says so.
        #expect(RAWPhotoDecoder.preferredDecoderVersion(from: []) == nil)
    }

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

    /// Bulk re-develop is the same return-to-step-one applied to a selection,
    /// with one set of settings, and it must not fail the whole selection because
    /// one job's original was cleaned up.
    @Test @MainActor func bulkRedevelopAppliesOneSetOfSettingsToTheSelection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let renders = Counter()
        let model = RenderQueueViewModel(persistenceURL: folder.appendingPathComponent("queue.json"),
            render: { _ in
                renders.value += 1
                let output = folder.appendingPathComponent("out-\(renders.value).jpg")
                try CIContext().writeJPEGRepresentation(of: CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
                    .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)), to: output,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                return output
            }, save: { _ in })

        func queuedPhoto(_ name: String) throws -> UUID {
            let source = folder.appendingPathComponent(name)
            try Data([1]).write(to: source)
            return try #require(model.enqueuePhoto(sourceURL: source, stockId: "kodak5219", iso: 500,
                gauge: .neutral, cropZoom: 1, seed: 3, isImported: true))
        }
        let one = try queuedPhoto("a.dng")
        let two = try queuedPhoto("b.dng")
        for _ in 0..<400 where model.jobs.contains(where: { $0.status != .completed }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        // A third job whose original is gone must be skipped, not fatal.
        let gone = folder.appendingPathComponent("gone.dng")
        try Data([1]).write(to: gone)
        let three = try #require(model.enqueuePhoto(sourceURL: gone, stockId: "kodak5219", iso: 500,
            gauge: .neutral, cropZoom: 1, seed: 4, isImported: true))
        for _ in 0..<400 where model.jobs.contains(where: { $0.status != .completed }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try FileManager.default.removeItem(at: gone)

        let requeued = model.redevelopPhotos(jobIds: [one, two, three],
                                             stockId: "kodak5207", gauge: .eightMillimetre,
                                             pushPull: .neutral)
        #expect(requeued == 2, "the job without its original is skipped")
        let refreshed = model.jobs.filter { [one, two].contains($0.id) }
        #expect(refreshed.allSatisfy { $0.stockId == "kodak5207" })
        #expect(refreshed.allSatisfy { $0.printGauge == .eightMillimetre })
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

    /// A still gets the SAME scene-linear diffusion node as a video frame, and
    /// the node's absence or presence is what changes the picture — nothing
    /// else. The comparison pins the wiring at the level the photo renderer
    /// actually calls: same stock, same gauge, same seed, diffusion off vs on.
    @Test func stillPhotoAppliesTheDiffusionNode() throws {
        // A hard step edge: diffusion widens the transition and lifts the dark
        // side. Grain alone cannot do that at this scale.
        // Wide enough for the widest rung to actually spread: at 512 px the
        // 8mm gauge's 35 px radius is ~5 full-resolution pixels of sigma.
        let width = 512, height = 128
        let step = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05))
            .cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
            .composited(over: CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9))
                .cropped(to: CGRect(x: width / 2, y: 0, width: width / 2, height: height)))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        func render(diffusion: DiffusionSettings??, gauge: PrintGauge) throws -> [Double] {
            let film = try StillFilmRenderResources(stockID: "kodak5219", gauge: gauge, seed: 7,
                bundle: Bundle(for: BundleToken.self), diffusion: diffusion)
            let developed = try DevelopmentPhotoRenderer.develop(linearImage: step, film: film)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            film.context.render(developed, toBitmap: &bytes, rowBytes: width * 4,
                bounds: step.extent, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            // Mean red of rows across the middle, so grain noise averages out.
            return (0..<width).map { x in
                var total = 0.0
                for y in (height / 4)..<(3 * height / 4) {
                    total += Double(bytes[(y * width + x) * 4 + 2])
                }
                return total / Double(height / 2)
            }
        }

        let off = try render(diffusion: .some(nil), gauge: .eightMillimetre)
        let on = try render(diffusion: nil, gauge: .eightMillimetre)
        #expect(off != on, "the still renderer must pass the gauge's diffusion through")

        // The dark side of the edge gains light from the bright side — and it
        // gains it WHERE the scatter lands. A ~4.7 px sigma at this width puts
        // the scattered light within a few pixels of the edge; an average lift
        // spread evenly across the whole dark side is not a diffuser, it is the
        // unphysical skirt a coarse ladder level puts around a highlight (see
        // DiffusionHighlightProfileTests, which pins the radial shape). Measured
        // over the band that actually receives the light.
        let darkBand = (width / 2 - 10)..<(width / 2 - 2)
        let darkOff = darkBand.map { off[$0] }.reduce(0, +) / Double(darkBand.count)
        let darkOn = darkBand.map { on[$0] }.reduce(0, +) / Double(darkBand.count)
        // Shipped stills mix half the take's amount (`stillDiffusionScale` 0.5),
        // so 8mm arrives at 0.175 rather than 0.35 and the lift is about half the
        // one a video frame gets at the same gauge.
        #expect(darkOn > darkOff + 0.2,
                "diffusion must lift the dark side of the edge (\(darkOff) -> \(darkOn))")

        // And a bypassed gauge is still a true pass-through of the node itself.
        let bypass = try render(diffusion: nil, gauge: .seventyFiveMillimetre)
        let bypassOff = try render(diffusion: .some(nil), gauge: .seventyFiveMillimetre)
        #expect(bypass == bypassOff, "75mm must render no diffusion at all")
    }

    /// Spread must scale with the FRAME, not stay a fixed pixel count.
    ///
    /// A still from the phone and a 45MP raw have to bloom and diffuse by the
    /// same fraction of the picture, or one looks blown out and the other
    /// invisible. Measured here as the radius, in units of frame width, at which
    /// the effect has fallen to a small fraction of its peak.
    @Test func halationAndDiffusionSpreadScalesWithFrameWidth() throws {
        func spread(width: Int, height: Int, apply: (StillFilmRenderResources, CIImage) throws -> CIImage) throws -> Double {
            // A single bright dot on black: its halo is the thing being measured.
            let dot = CIImage(color: CIColor(red: 6, green: 6, blue: 6))
                .cropped(to: CGRect(x: 0, y: 0, width: max(2, width / 128), height: max(2, height / 128)))
                .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)))
            let film = try StillFilmRenderResources(stockID: "kodak5219", gauge: .sixteenMillimetre,
                                                     seed: 1, bundle: Bundle(for: BundleToken.self))
            let out = try apply(film, dot)

            // Scale to a fixed sample grid FIRST: rendering the full extent into
            // a narrow bitmap mismatches rowBytes and reads garbage.
            let sampleWidth = 256
            let scale = Float(sampleWidth) / Float(width)
            let sampled = out.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
                .cropped(to: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleWidth))
            var pixels = [UInt8](repeating: 0, count: sampleWidth * 4)
            film.context.render(sampled, toBitmap: &pixels, rowBytes: sampleWidth * 4,
                                bounds: CGRect(x: 0, y: 0, width: sampleWidth, height: 1), format: .RGBA8,
                                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            let values = (0..<sampleWidth).map { Double(pixels[$0 * 4]) }
            let peak = values.max() ?? 0
            guard peak > 1 else { return 0 }
            // First sample under 10% of peak, as a fraction of the frame.
            let index = values.firstIndex { $0 < peak * 0.1 } ?? sampleWidth
            return Double(index) / Double(sampleWidth)
        }

        let small = 512, large = 2048
        // Halation: the whole frame is the halo of one dot.
        let halationSmall = try spread(width: small, height: small) { film, image in
            try film.halation(RAWToLog2Stage.apply(image), sceneLiftStops: 1)
        }
        let halationLarge = try spread(width: large, height: large) { film, image in
            try film.halation(RAWToLog2Stage.apply(image), sceneLiftStops: 1)
        }
        // Same fraction of the frame within a generous band.
        #expect(halationLarge > halationSmall * 0.6 && halationLarge < halationSmall * 1.6,
                "halation spread should be frame-relative: small \(halationSmall) large \(halationLarge)")

        let diffusionSmall = try spread(width: small, height: small) { film, image in
            try DevelopmentPhotoRenderer.develop(linearImage: image, film: film,
                                                 sceneLiftStops: 1)
        }
        let diffusionLarge = try spread(width: large, height: large) { film, image in
            try DevelopmentPhotoRenderer.develop(linearImage: image, film: film,
                                                 sceneLiftStops: 1)
        }
        #expect(diffusionLarge > diffusionSmall * 0.5 && diffusionLarge < diffusionSmall * 1.8,
                "diffusion spread should be frame-relative: small \(diffusionSmall) large \(diffusionLarge)")
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

/// Delivering a developed photo's original DNG as a separate Photos resource.
/// The injected save stands in for the Photos writer; the queue ownership rules
/// (ordering, retry, reload) are the real system under test.
@Suite(.serialized)
struct PhotoOriginalDeliveryTests {
    private struct Files {
        let directory: URL
        var source: URL { directory.appendingPathComponent("capture.dng") }
        var output: URL { directory.appendingPathComponent("developed.jpg") }
        var persistence: URL { directory.appendingPathComponent("queue.json") }
    }

    private enum Failure: Error { case save, render }

    private func scratch() throws -> Files {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = Files(directory: directory)
        try Data([1, 2, 3]).write(to: files.source)
        let image = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        try CIContext().writeJPEGRepresentation(of: image, to: files.output,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return files
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for queue state")
    }

    @Test func originalSelectionIsMediaAwareAndIndependentOfSaveOriginalLog() {
        func photo(raw: Bool, log: Bool) -> RenderJob {
            var job = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/a.dng"), stockId: "kodak5219",
                                iso: 400, deliveryPreferences: RenderDeliveryPreferences(
                                    saveOriginalLog: log, saveOriginalRAWToPhotos: raw))
            job.isPhoto = true
            return job
        }
        func video(log: Bool, raw: Bool) -> RenderJob {
            RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"), stockId: "kodak5219",
                      iso: 400, deliveryPreferences: RenderDeliveryPreferences(
                          saveOriginalLog: log, saveOriginalRAWToPhotos: raw))
        }

        #expect(photo(raw: true, log: false).shouldSaveOriginal)
        #expect(!photo(raw: false, log: true).shouldSaveOriginal)
        #expect(video(log: true, raw: false).shouldSaveOriginal)
        #expect(!video(log: false, raw: true).shouldSaveOriginal)
        // Imported video never exports its original, whatever the photo switch says.
        var imported = video(log: true, raw: true)
        imported.isImportedVideo = true
        #expect(!imported.shouldSaveOriginal)
    }

    @Test @MainActor func enqueuePhotoSnapshotsThePreferenceAtEnqueue() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let model = RenderQueueViewModel(persistenceURL: files.persistence,
                                         render: { _ in files.output },
                                         save: { _ in }, postDelivery: { _, _ in })
        let requested = RenderDeliveryPreferences(saveOriginalRAWToPhotos: true)
        let id = try #require(model.enqueuePhoto(sourceURL: files.source, stockId: "kodak5219",
            iso: 400, gauge: .sixteenMillimetre, cropZoom: 1, seed: 7, preferences: requested))
        let job = try #require(model.jobs.first(where: { $0.id == id }))
        #expect(job.deliveryPreferences == requested)
        try await waitUntil { model.jobs.first?.status == .completed }
        let persisted = try #require(try QueuePersister(storageURL: files.persistence).load().first)
        #expect(persisted.deliveryPreferences == requested)
        #expect(persisted.deliveryPreferences?.saveOriginalRAWToPhotos == true)
    }

    @Test(arguments: [false, true])
    @MainActor func photoDeliverySavesDevelopedJPEGAndOptionallyTheOriginalDNG(saveOriginal: Bool) async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var saves: [URL] = []
        let model = RenderQueueViewModel(persistenceURL: files.persistence,
                                         render: { _ in files.output },
                                         save: { saves.append($0) }, postDelivery: { _, _ in })
        let preferences = RenderDeliveryPreferences(saveOriginalLog: false,
                                                    saveOriginalRAWToPhotos: saveOriginal)
        let id = try #require(model.enqueuePhoto(sourceURL: files.source, stockId: "kodak5219",
            iso: 400, gauge: .sixteenMillimetre, cropZoom: 1, seed: 11, preferences: preferences))
        try await waitUntil { model.jobs.first?.status == .completed }
        let job = try #require(model.jobs.first(where: { $0.id == id }))
        #expect(job.status == .completed)
        #expect(job.outputSavedToPhotos == true)
        #expect(job.sourceSavedToPhotos == (saveOriginal ? true : nil))
        #expect(saves == (saveOriginal ? [files.output, files.source] : [files.output]))
        // The local DNG survives delivery so the photo can be developed again.
        #expect(FileManager.default.fileExists(atPath: files.source.path))
        #expect(job.hasRedevelopableOriginal)
    }

    @Test @MainActor func failedOriginalDNGKeepsTheJPEGAndRetrySavesOnlyTheOriginal() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var renders = 0
        var saves: [URL] = []
        var failOriginal = true
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            renders += 1
            return files.output
        }, save: { url in
            saves.append(url)
            if url == files.source, failOriginal { throw Failure.save }
        }, postDelivery: { _, _ in })
        let preferences = RenderDeliveryPreferences(saveOriginalRAWToPhotos: true)
        let id = try #require(model.enqueuePhoto(sourceURL: files.source, stockId: "kodak5219",
            iso: 400, gauge: .sixteenMillimetre, cropZoom: 1, seed: 13, preferences: preferences))
        try await waitUntil { !model.isProcessing && model.jobs.first?.status == .failed }
        let failed = try #require(model.jobs.first(where: { $0.id == id }))
        #expect(failed.outputSavedToPhotos == true)
        #expect(failed.sourceSavedToPhotos == false)
        #expect(failed.outputURL == files.output)
        #expect(failed.status == .failed)
        let message = try #require(failed.errorMessage)
        // Short on screen: what happened, then what Retry does.
        #expect(message.contains("Developed photo saved."))
        #expect(message.contains("Original not added to Photos"))
        #expect(message.contains("Retry tries only that"))
        #expect(!message.contains("Apple Log"))

        failOriginal = false
        model.retry(jobId: failed.id)
        try await waitUntil { !model.isProcessing && model.jobs.first?.status == .completed }
        #expect(model.jobs.first?.sourceSavedToPhotos == true)
        #expect(model.jobs.first?.outputSavedToPhotos == true)
        #expect(model.jobs.first?.deliveryPreferences == preferences)
        #expect(renders == 1, "Retry must not develop the photo again")
        #expect(saves == [files.output, files.source, files.source],
                "Retry saves only the original; the JPEG is not saved twice")
    }

    @Test @MainActor func reloadedQueueKeepsThePreferenceAndSavesOnlyTheOriginal() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let preferences = RenderDeliveryPreferences(saveOriginalRAWToPhotos: true)
        var interrupted = RenderJob(sourceURL: files.source, stockId: "kodak5219", iso: 400,
                                    printGauge: .sixteenMillimetre,
                                    deliveryPreferences: preferences)
        interrupted.isPhoto = true
        interrupted.photoCropZoom = 1
        interrupted.photoGrainSeed = 17
        interrupted.status = .processing
        interrupted.outputURL = files.output
        interrupted.outputSavedToPhotos = true
        try QueuePersister(storageURL: files.persistence).save([interrupted])

        var renders = 0
        var saves: [URL] = []
        let restored = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            renders += 1
            throw Failure.render
        }, save: { saves.append($0) }, postDelivery: { _, _ in })
        restored.onAppear()
        try await waitUntil { !restored.isProcessing && restored.jobs.first?.status == .completed }
        #expect(restored.jobs.first?.deliveryPreferences == preferences)
        #expect(restored.jobs.first?.sourceSavedToPhotos == true)
        #expect(restored.jobs.first?.outputSavedToPhotos == true)
        #expect(renders == 0, "A reloaded photo with a delivered JPEG only needs its original")
        #expect(saves == [files.source])
    }
}
