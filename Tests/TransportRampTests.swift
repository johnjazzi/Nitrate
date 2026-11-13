import AVFoundation
import CoreVideo
import Foundation
import Testing

/// The transport ramp is what a real body does to the ends of a take: the film
/// is already running before the take starts and is still crawling as it comes
/// up to speed, so the take opens on over-exposed frames and closes the same way,
/// with unexposed film either side. These are the model's own rules — how many
/// frames burn, how far the ramp falls, which frames are short, and what the
/// Settings switch resolves to.
@Suite struct TransportRampModelTests {
    private let take = 100

    @Test func theHeadBurnsFromThePeakDownToNothing() {
        let ramp = LightLeakTransport.standard
        #expect(ramp.stops(atFrame: 0, ofFrameCount: take) == ramp.peakStops)
        for index in 1..<ramp.burnFrames {
            #expect(ramp.stops(atFrame: index, ofFrameCount: take)
                < ramp.stops(atFrame: index - 1, ofFrameCount: take),
                "frame \(index) is not dimmer than frame \(index - 1)")
        }
        // The frame after the last burn frame is the take the camera metered.
        #expect(ramp.stops(atFrame: ramp.burnFrames, ofFrameCount: take) == 0)
    }

    @Test func theTailMirrorsTheHead() {
        let ramp = LightLeakTransport.standard
        let last = take - 1
        #expect(ramp.stops(atFrame: last, ofFrameCount: take) == ramp.peakStops)
        for offset in 1..<ramp.tailBurnFrames {
            #expect(ramp.stops(atFrame: last - offset, ofFrameCount: take)
                < ramp.stops(atFrame: last - offset + 1, ofFrameCount: take),
                "the tail is not ramping back up at \(offset) frames from the end")
        }
        #expect(ramp.stops(atFrame: last - ramp.tailBurnFrames, ofFrameCount: take) == 0)
    }

    @Test func theBodyOfTheTakeCarriesNoBurn() {
        let ramp = LightLeakTransport.standard
        let lastBodyFrame = take - ramp.tailBurnFrames - 1
        for index in ramp.burnFrames...lastBodyFrame {
            #expect(ramp.stops(atFrame: index, ofFrameCount: take) == 0)
            #expect(ramp.frame(atFrame: index, ofFrameCount: take) == .none)
        }
    }

    /// A take shorter than the burn is burned end to end rather than counted
    /// twice at the head and the tail.
    @Test func aTakeShorterThanTheBurnIsBurnedThroughout() {
        let ramp = LightLeakTransport.standard
        let short = ramp.burnFrames - 3
        for index in 0..<short {
            #expect(ramp.stops(atFrame: index, ofFrameCount: short) > 0,
                    "frame \(index) of a \(short)-frame take went unburned")
        }
    }

    /// The transport is stopped between takes with the film mid-frame, so the
    /// frame that opens a take is the one straddling the aperture: part of it
    /// never crossed the gate and was never exposed at all.
    @Test func theOpeningFrameIsPartialAndTheThirdIsWhole() {
        let ramp = LightLeakTransport.standard
        #expect(ramp.slip(atFrame: 0) == ramp.firstFrameSlip)
        #expect(ramp.slip(atFrame: 1) < ramp.slip(atFrame: 0))
        #expect(ramp.slip(atFrame: 2) == 0)
        let opening = ramp.frame(atFrame: 0, ofFrameCount: take)
        #expect(opening.slip == ramp.firstFrameSlip)
        #expect(opening.isActive)
    }

    @Test func theOffRampAddsNothingAtAll() {
        let off = LightLeakTransport.off
        #expect(!off.isActive)
        #expect(off.leaderCount == 0)
        #expect(off.trailerCount == 0)
        #expect(off.frame(atFrame: 0, ofFrameCount: take) == .none)
        // With the peak at zero nothing burns, whatever the slip says.
        #expect(off.slip(atFrame: 0) == 0)
    }

    /// The keys are the persisted contract: renaming one silently drops the
    /// setting a user already chose.
    @Test func thePersistedKeysAreStable() {
        #expect(TransportRampSettings.isEnabledKey == "processing.transportRamp")
        #expect(TransportRampSettings.lengthKey == "processing.transportRampLength")
    }

    @Test func theSwitchIsOffByDefaultAndOnWhenSet() {
        let defaults = Self.freshDefaults(named: "TransportRampSwitchTests")
        defer { Self.clearDefaults(named: "TransportRampSwitchTests") }
        #expect(TransportRampSettings.resolved(defaults: defaults) == .off)

        defaults.set(true, forKey: TransportRampSettings.isEnabledKey)
        let ramp = TransportRampSettings.resolved(defaults: defaults)
        #expect(ramp.burnFrames == TransportRampSettings.Length.standard.burnFrames)
        #expect(ramp.leaderFrames == TransportRampSettings.Length.standard.filmFrames)
        #expect(ramp.peakStops > 0)
        // A clip that opens on black cannot be identified in Photos, so the
        // delivered one opens on the take itself.
        #expect(ramp.opensWithNominalFrame)
    }

    @Test func theLengthSetsTheBurnAndTheFilmEitherSide() {
        let defaults = Self.freshDefaults(named: "TransportRampLengthTests")
        defer { Self.clearDefaults(named: "TransportRampLengthTests") }
        defaults.set(true, forKey: TransportRampSettings.isEnabledKey)

        for length in TransportRampSettings.Length.allCases {
            defaults.set(length.rawValue, forKey: TransportRampSettings.lengthKey)
            let ramp = TransportRampSettings.resolved(defaults: defaults)
            #expect(ramp.burnFrames == length.burnFrames)
            #expect(ramp.tailBurnFrames == length.burnFrames)
            #expect(ramp.leaderFrames == length.filmFrames)
            #expect(ramp.trailerFrames == length.filmFrames)
        }
        #expect(TransportRampSettings.Length.short.burnFrames < TransportRampSettings.Length.long.burnFrames)

        // An unrecognised value keeps the standard ramp rather than a zero one.
        defaults.set("enormous", forKey: TransportRampSettings.lengthKey)
        #expect(TransportRampSettings.resolved(defaults: defaults).burnFrames
            == TransportRampSettings.Length.standard.burnFrames)
    }

    /// The environment is how RenderCLI and the render comparisons drive the
    /// ramp — there is no Settings screen in a command-line render — so where it
    /// speaks it wins over the switch.
    @Test func theEnvironmentOverridesTheSwitch() {
        let defaults = Self.freshDefaults(named: "TransportRampEnvironmentTests")
        defer { Self.clearDefaults(named: "TransportRampEnvironmentTests") }

        #expect(LightLeakTransport.resolved(defaults: defaults, environment: [:]) == .off)
        #expect(LightLeakTransport.resolved(defaults: defaults, environment: ["NITRATE_LEAK_ON": "1"]).isActive)

        defaults.set(true, forKey: TransportRampSettings.isEnabledKey)
        #expect(LightLeakTransport.resolved(defaults: defaults, environment: [:]).isActive)
        let forcedOff = LightLeakTransport.resolved(defaults: defaults,
                                                    environment: ["NITRATE_LEAK_OFF": "1"])
        #expect(forcedOff == .off)
    }

    /// One knob is enough to put the environment in charge, and the knobs land on
    /// the standard ramp rather than replacing it.
    @Test func oneKnobTurnsTheRampOnAndShapesIt() throws {
        #expect(LightLeakTransport.fromEnvironment([:]) == nil)

        let trimmed = LightLeakTransport.fromEnvironment(["NITRATE_LEAK_PEAK_STOPS": "1.5",
                                                          "NITRATE_LEAK_BURN_FRAMES": "4",
                                                          "NITRATE_LEAK_SLIP": "0"])
        let ramp = try #require(trimmed)
        #expect(ramp.peakStops == 1.5)
        #expect(ramp.burnFrames == 4)
        #expect(ramp.firstFrameSlip == 0)
        #expect(ramp.leaderFrames == LightLeakTransport.standard.leaderFrames)
    }

    /// A suite of the test's own, so a switch set here cannot reach the standard
    /// domain a concurrent render reads.
    private static func freshDefaults(named name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func clearDefaults(named name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

/// End-to-end: a real render of a real take, with the ramp on and off, so the
/// added frames are counted in the encoded file and the burn is measured on the
/// delivered pixels rather than argued from the model.
@Suite(.serialized)
struct TransportRampRenderTests {
    private final class BundleToken {}

    private static let width = 96
    private static let height = 64
    /// Long enough that the head burn and the tail burn do not meet, so the
    /// middle of the take is a real control region.
    private static let takeFrames = 24

    /// Frames ahead of the take's first frame: the nominal frame, then the film.
    private var headFrames: Int { 1 + LightLeakTransport.standard.leaderCount }

    @Test(.timeLimit(.minutes(2)))
    func theRampAddsFilmAndOpensOnTheTake() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("take.mov")
        try await Self.writeTake(at: source)
        let ramp = LightLeakTransport.standard

        let plain = try await Self.render(source: source, in: directory, ramp: .off)
        defer { try? FileManager.default.removeItem(at: plain) }
        let ramped = try await Self.render(source: source, in: directory, ramp: ramp)
        defer { try? FileManager.default.removeItem(at: ramped) }

        let plainFrames = try await Self.frames(of: plain)
        let rampedFrames = try await Self.frames(of: ramped)

        // The take is delivered once, and once with film either side of it and a
        // frame of itself in front.
        #expect(plainFrames.count == Self.takeFrames)
        #expect(rampedFrames.count
            == Self.takeFrames + ramp.leaderCount + ramp.trailerCount + 1)

        // The clip opens on the take at the exposure the camera metered it at:
        // the picture, not black film and not the burn.
        let opening = Self.meanLuma(rampedFrames[0])
        #expect(abs(opening - Self.meanLuma(plainFrames[0])) < 0.2 * 255,
                "the first frame (\(opening)) is not the take's own first frame (\(Self.meanLuma(plainFrames[0])))")
        #expect(Self.regionMean(rampedFrames[0], fromRow: 0, toRow: Self.height / 4)
            > Self.regionMean(rampedFrames[0], fromRow: Self.height * 3 / 4, toRow: Self.height),
                "the opening frame does not carry the fixture's own picture")

        // Then the film the gate was never open on.
        for index in 1...ramp.leaderCount {
            #expect(Self.meanLuma(rampedFrames[index]) < 40,
                    "frame \(index) of the film is not unexposed (\(Self.meanLuma(rampedFrames[index])))")
        }

        // The take's opening frame was still crossing the gate: the part that had
        // not been drawn into it never saw light, and the part that had is burned.
        let partial = rampedFrames[headFrames]
        let partialTop = Self.regionMean(partial, fromRow: 0, toRow: Self.height / 4)
        let partialBottom = Self.regionMean(partial, fromRow: Self.height * 3 / 4, toRow: Self.height)
        #expect(partialTop < 64, "the unexposed part of the opening take frame is not black (\(partialTop))")
        #expect(partialBottom > 200, "the exposed part of the opening take frame is not burned (\(partialBottom))")

        // And the tail: the burn ramps back up into film.
        let lastTakeFrame = rampedFrames[headFrames + Self.takeFrames - 1]
        let bodyFrame = rampedFrames[headFrames + Self.takeFrames / 2]
        #expect(Self.meanLuma(lastTakeFrame) > Self.meanLuma(bodyFrame),
                "the take's last frame is not burned")
        for index in (rampedFrames.count - ramp.trailerCount)..<rampedFrames.count {
            #expect(Self.meanLuma(rampedFrames[index]) < 40,
                    "the film after the take is not unexposed (\(Self.meanLuma(rampedFrames[index])))")
        }
    }

    /// The ramp is a fact about the ends of a take. Everything between them is
    /// delivered exactly as it was without the ramp, at a known offset.
    @Test(.timeLimit(.minutes(2)))
    func theRampLeavesTheBodyOfTheTakeAlone() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("take.mov")
        try await Self.writeTake(at: source)

        let plain = try await Self.render(source: source, in: directory, ramp: .off)
        defer { try? FileManager.default.removeItem(at: plain) }
        let ramped = try await Self.render(source: source, in: directory,
                                           ramp: LightLeakTransport.standard)
        defer { try? FileManager.default.removeItem(at: ramped) }

        let plainFrames = try await Self.frames(of: plain)
        let rampedFrames = try await Self.frames(of: ramped)
        let ramp = LightLeakTransport.standard

        for takeFrame in [ramp.burnFrames, Self.takeFrames / 2, Self.takeFrames - ramp.tailBurnFrames - 1] {
            let delivered = Self.meanLuma(rampedFrames[headFrames + takeFrame])
            let reference = Self.meanLuma(plainFrames[takeFrame])
            #expect(abs(delivered - reference) < 2,
                    "frame \(takeFrame) of the take changed with the ramp on: \(delivered) vs \(reference)")
        }
    }

    // MARK: - Fixture

    /// A take with a bright upper half and a dark lower half, so which half of a
    /// frame was exposed is measurable on the encoded file — the unexposed band
    /// spends the fixture's own picture, it does not just dim it.
    private static func writeTake(at url: URL) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
        writer.add(input)
        guard writer.startWriting() else { throw FixtureError.writer(writer.error) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<takeFrames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw FixtureError.writer(nil) }
            var created: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess,
                  let buffer = created else { throw FixtureError.writer(nil) }
            fill(buffer)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 6)) else {
                throw FixtureError.writer(writer.error)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw FixtureError.writer(writer.error) }
    }

    private static func fill(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            let value: UInt8 = y < height / 2 ? 220 : 24
            for x in 0..<width {
                row[x * 4 + 0] = value
                row[x * 4 + 1] = value
                row[x * 4 + 2] = value
                row[x * 4 + 3] = 255
            }
        }
    }

    // MARK: - Rendering and measuring

    private static func render(source: URL, in directory: URL,
                               ramp: LightLeakTransport) async throws -> URL {
        let renderer = try PipelineRenderer(resourceBundle: Bundle(for: BundleToken.self),
                                            outputDirectory: directory,
                                            allowsSyntheticInputForTests: true,
                                            transportRamp: ramp)
        return try await renderer.render(sourceURL: source, config: loadConfig(), bitrate: 1_000_000)
    }

    /// Every delivered frame, in BGRA. Small frames, so the whole clip is held.
    private static func frames(of url: URL) async throws -> [[UInt8]] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        guard reader.startReading() else { throw FixtureError.reader }
        var frames: [[UInt8]] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let width = CVPixelBufferGetWidth(image)
            let height = CVPixelBufferGetHeight(image)
            CVPixelBufferLockBaseAddress(image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(image) else { continue }
            let stride = CVPixelBufferGetBytesPerRow(image)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for i in 0..<(width * 4) { pixels[y * width * 4 + i] = row[i] }
            }
            frames.append(pixels)
        }
        reader.cancelReading()
        return frames
    }

    private static func meanLuma(_ pixels: [UInt8]) -> Double {
        regionMean(pixels, fromRow: 0, toRow: height)
    }

    /// Mean of the BGRA triple's average across a band of rows, on the 0-255
    /// scale the fixture is written in.
    private static func regionMean(_ pixels: [UInt8], fromRow: Int, toRow: Int) -> Double {
        var total = 0.0
        var count = 0
        for y in fromRow..<toRow {
            for x in 0..<width {
                let index = (y * width + x) * 4
                total += (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / 3
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    // MARK: - Helpers

    private static func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func loadConfig() -> FilmStockConfig {
        let url = TestRepository.root.appendingPathComponent("App/Resources/stocks.json")
        guard let data = try? Data(contentsOf: url),
              let container = try? JSONDecoder().decode(RampStockContainer.self, from: data),
              let config = container.stocks.first(where: { $0.stockId == "kodak5219" }) else {
            fatalError("kodak5219 stock configuration is required for the transport ramp render test")
        }
        return config
    }

    private enum FixtureError: Error {
        case writer(Error?)
        case reader
    }

    private struct RampStockContainer: Decodable { let stocks: [FilmStockConfig] }
}
