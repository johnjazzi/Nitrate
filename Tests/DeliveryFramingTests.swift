import AVFoundation
import CoreGraphics
import Foundation
import Testing

/// Delivery framing is a render-time crop: the recorded original stays 16:9 and
/// the *delivered* file is the centred 4:3 crop. These tests pin the policy's
/// arithmetic, the writer configuration that consumes it, the metadata the file
/// carries, and the live-preview guide geometry.
struct DeliveryFramingTests {
    // MARK: - Policy

    @Test func widescreenSourceIsCroppedToCentredFourThree() {
        let delivery = DeliveryFraming.fourThree.delivery(forSourceSize: CGSize(width: 3840, height: 2160))
        #expect(delivery.deliveredWidth == 2880)
        #expect(delivery.deliveredHeight == 2160)
        #expect(delivery.cropX == 480)
        #expect(delivery.cropY == 0)
        #expect(delivery.isCropped)
        #expect(delivery.cropRect == CGRect(x: 480, y: 0, width: 2880, height: 2160))
        // The crop is centred: equal removed columns on both sides.
        #expect(delivery.cropX == 3840 - (delivery.cropX + delivery.deliveredWidth))
    }

    @Test func widescreenDeliveryIsTheSourceUnchanged() {
        for size in [CGSize(width: 3840, height: 2160), CGSize(width: 1920, height: 1080),
                     CGSize(width: 2160, height: 3840), CGSize(width: 2880, height: 2160)] {
            let delivery = DeliveryFraming.widescreen.delivery(forSourceSize: size)
            #expect(delivery.deliveredWidth == Int(size.width))
            #expect(delivery.deliveredHeight == Int(size.height))
            #expect(!delivery.isCropped)
            #expect(delivery.cropX == 0)
            #expect(delivery.cropY == 0)
        }
    }

    @Test(arguments: [
        // Already 4:3, and narrower than 4:3 (portrait / square): unchanged,
        // never upscaled and never letterboxed.
        CGSize(width: 2880, height: 2160),
        CGSize(width: 2160, height: 2880),
        CGSize(width: 1080, height: 1080),
        CGSize(width: 1620, height: 2160)
    ])
    func sourcesAtOrBelowFourThreePassThrough(size: CGSize) {
        let delivery = DeliveryFraming.fourThree.delivery(forSourceSize: size)
        #expect(delivery.deliveredWidth == Int(size.width))
        #expect(delivery.deliveredHeight == Int(size.height))
        #expect(!delivery.isCropped)
        #expect(delivery.cropRect == CGRect(origin: .zero, size: size))
    }

    @Test func nonSixteenNineWidescreenSizesCropByHeight() {
        // 1080p: 1440x1080 is the 4:3 shape at the same height.
        let hd = DeliveryFraming.fourThree.delivery(forSourceSize: CGSize(width: 1920, height: 1080))
        #expect(hd.deliveredWidth == 1440)
        #expect(hd.deliveredHeight == 1080)
        #expect(hd.cropX == 240)

        // A 2.4:1 source keeps its height and gives up more width.
        let scope = DeliveryFraming.fourThree.delivery(forSourceSize: CGSize(width: 3840, height: 1600))
        #expect(scope.deliveredHeight == 1600)
        #expect(scope.deliveredWidth == 2134) // 1600 × 4/3 = 2133.33 → 2134 (even)
        #expect(scope.cropX == (3840 - 2134) / 2)
        #expect(scope.cropX + scope.deliveredWidth <= 3840)
    }

    @Test func oddSizesRoundToEvenAndStayConsistent() {
        // 1081 × 4/3 = 1441.33 → nearest pixel 1441 → widened to even 1442.
        let odd = DeliveryFraming.fourThree.delivery(forSourceSize: CGSize(width: 2000, height: 1081))
        #expect(odd.deliveredHeight == 1081)
        #expect(odd.deliveredWidth == 1442)
        #expect(odd.deliveredWidth % 2 == 0)
        // Deterministic: the same source always resolves to the same crop.
        let again = DeliveryFraming.fourThree.delivery(forSourceSize: CGSize(width: 2000, height: 1081))
        #expect(again == odd)

        // A fractional natural size is normalised before the crop is computed,
        // so a 3839.6-wide track behaves as 3840.
        let fractional = DeliveryFraming.fourThree.delivery(forSourceSize: CGSize(width: 3839.6, height: 2160))
        #expect(fractional.sourceWidth == 3840)
        #expect(fractional.deliveredWidth == 2880)
    }

    @Test func cropNeverUpscalesOrLeavesTheSource() {
        let sizes = [CGSize(width: 3840, height: 2160), CGSize(width: 1920, height: 1080),
                     CGSize(width: 1999, height: 1081), CGSize(width: 5000, height: 2001),
                     CGSize(width: 2880, height: 2160), CGSize(width: 320, height: 180)]
        for size in sizes {
            let delivery = DeliveryFraming.fourThree.delivery(forSourceSize: size)
            #expect(delivery.deliveredWidth <= delivery.sourceWidth)
            #expect(delivery.deliveredHeight <= delivery.sourceHeight)
            #expect(delivery.cropX >= 0)
            #expect(delivery.cropY >= 0)
            #expect(delivery.cropX + delivery.deliveredWidth <= delivery.sourceWidth)
            #expect(delivery.cropY + delivery.deliveredHeight <= delivery.sourceHeight)
            // Never taller or wider than the original: a crop only removes.
            #expect(delivery.deliveredWidth * delivery.deliveredHeight
                <= delivery.sourceWidth * delivery.sourceHeight)
        }
    }

    @Test func framingResolvesFromStoredStrings() {
        #expect(DeliveryFraming.resolved(nil) == .widescreen)
        #expect(DeliveryFraming.resolved("") == .widescreen)
        #expect(DeliveryFraming.resolved("4:5") == .widescreen)
        #expect(DeliveryFraming.resolved("16:9") == .widescreen)
        #expect(DeliveryFraming.resolved("4:3") == .fourThree)
        #expect(DeliveryFraming.preferenceKey == "delivery.framing")
    }

    // MARK: - Writer configuration

    @Test func writerSettingsUseTheCroppedDimensions() throws {
        let delivery = DeliveryFraming.fourThree.delivery(forSourceSize: CGSize(width: 3840, height: 2160))
        let settings = RenderVideoSettings.output(width: delivery.deliveredWidth,
                                                 height: delivery.deliveredHeight,
                                                 bitrate: 60_000_000, nominalFrameRate: 24)
        #expect(settings[AVVideoWidthKey] as? Int == 2880)
        #expect(settings[AVVideoHeightKey] as? Int == 2160)
        #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == AVVideoCodecType(rawValue: RenderEncodingContract.codec))
        // The colour tags and compression contract are unchanged by framing.
        let color = try #require(settings[AVVideoColorPropertiesKey] as? [String: String])
        #expect(color[AVVideoColorPrimariesKey] == RenderEncodingContract.colorPrimaries)
        #expect(color[AVVideoTransferFunctionKey] == RenderEncodingContract.transferFunction)
        #expect(color[AVVideoYCbCrMatrixKey] == RenderEncodingContract.yCbCrMatrix)
        let compression = try #require(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(compression[AVVideoAverageBitRateKey] as? Int == 60_000_000)
        #expect(compression[AVVideoMaxKeyFrameIntervalKey] as? Int == 48)
        #expect(compression[AVVideoExpectedSourceFrameRateKey] as? Float == 24)
        #expect(compression[AVVideoAllowFrameReorderingKey] as? Bool == true)

        // 16:9 writes the source size, byte-for-byte the previous contract.
        let wide = DeliveryFraming.widescreen.delivery(forSourceSize: CGSize(width: 3840, height: 2160))
        let wideSettings = RenderVideoSettings.output(width: wide.deliveredWidth,
                                                      height: wide.deliveredHeight,
                                                      bitrate: 60_000_000, nominalFrameRate: 24)
        #expect(wideSettings[AVVideoWidthKey] as? Int == 3840)
        #expect(wideSettings[AVVideoHeightKey] as? Int == 2160)
    }

    // MARK: - Metadata

    @Test func metadataStatesTheFramingAndDeliveredSize() throws {
        let config = try Self.loadConfig()
        let fourThree = try RenderMovieMetadata.recipeValues(
            config: config, framing: .fourThree, deliveredSize: CGSize(width: 2880, height: 2160))
        #expect(fourThree["framing"] == "4:3")
        #expect(fourThree["delivered-width"] == "2880")
        #expect(fourThree["delivered-height"] == "2160")

        let widescreen = try RenderMovieMetadata.recipeValues(
            config: config, framing: .widescreen, deliveredSize: CGSize(width: 3840, height: 2160))
        #expect(widescreen["framing"] == "16:9")
        #expect(widescreen["delivered-width"] == "3840")
        #expect(widescreen["delivered-height"] == "2160")

        // Existing keys are untouched by the additive framing facts.
        #expect(widescreen["encoding-codec"] == fourThree["encoding-codec"])
        #expect(widescreen["render-settings"] == fourThree["render-settings"])

        // Callers that do not record framing (the still path) gain no keys.
        let still = try RenderMovieMetadata.recipeValues(config: config)
        #expect(still["framing"] == nil)
        #expect(still["delivered-width"] == nil)
    }

    // MARK: - Preferences

    @Test func storedFramingDefaultsToWidescreenAndRoundTrips() throws {
        let suite = "DeliveryFramingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(DeliverySettings.renderPreferences(defaults: defaults).framing == .widescreen)
        defaults.set("4:3", forKey: DeliverySettings.deliveryFramingKey)
        #expect(DeliverySettings.renderPreferences(defaults: defaults).framing == .fourThree)
        defaults.set("not-a-framing", forKey: DeliverySettings.deliveryFramingKey)
        #expect(DeliverySettings.renderPreferences(defaults: defaults).framing == .widescreen)
    }

    @Test func queuedJobsFromBeforeFramingExistedDeliverWidescreen() throws {
        let legacy = Data(#"{"saveOriginalLog":true,"quality":"smaller"}"#.utf8)
        let decoded = try JSONDecoder().decode(RenderDeliveryPreferences.self, from: legacy)
        #expect(decoded.framing == .widescreen)
        #expect(decoded.quality == .smaller)

        // A queued job keeps the framing it was enqueued with.
        let prefs = RenderDeliveryPreferences(quality: .high, framing: .fourThree)
        let roundTripped = try JSONDecoder().decode(
            RenderDeliveryPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(roundTripped == prefs)
        #expect(roundTripped.framing == .fourThree)
    }

    // MARK: - Preview guide

    @Test func previewGuideIsTheCentredDeliveredRegion() throws {
        // A 2:3 framed preview surface, 300x450 pt.
        let rect = CGRect(x: 20, y: 100, width: 300, height: 450)
        let guide = try #require(DeliveryFramingGuide.deliveredRect(in: rect, framing: .fourThree))
        // Full width; 4:3 of the 9:16 frame keeps 75% of the displayed height.
        #expect(guide.width == rect.width)
        #expect(abs(guide.height - 400) < 0.001)
        #expect(guide.midX == rect.midX)
        #expect(guide.midY == rect.midY)
        // The scrim therefore covers only the top and bottom bands.
        #expect(abs((rect.height - guide.height) / 2 - 25) < 0.001)
    }

    @Test func previewGuideIsAbsentForWidescreenAndNeverExceedsThePreview() throws {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 450)
        #expect(DeliveryFramingGuide.deliveredRect(in: rect, framing: .widescreen) == nil)
        #expect(DeliveryFramingGuide.deliveredRect(in: .zero, framing: .fourThree) == nil)

        for size in [CGSize(width: 200, height: 300), CGSize(width: 390, height: 500),
                     CGSize(width: 500, height: 300)] {
            let preview = CGRect(origin: .zero, size: size)
            let guide = try #require(DeliveryFramingGuide.deliveredRect(in: preview, framing: .fourThree))
            #expect(preview.contains(guide) || preview.insetBy(dx: -0.001, dy: -0.001).contains(guide))
            #expect(abs(guide.width - preview.width) < 0.001 || abs(guide.height - preview.height) < 0.001)
        }
    }

    // MARK: - Helpers

    private static func loadConfig() throws -> FilmStockConfig {
        let url = TestRepository.root.appendingPathComponent("App/Resources/stocks.json")
        let container = try JSONDecoder().decode(StockContainer.self, from: Data(contentsOf: url))
        let config = try #require(container.stocks.first { $0.stockId == "kodak5219" },
                                  "kodak5219 stock configuration")
        return config
    }

    private struct StockContainer: Decodable { let stocks: [FilmStockConfig] }
}
