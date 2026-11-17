import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import simd

/// The development white balance is a value, not a UI gesture: it must decode
/// from old and malformed jobs, resolve to an exact no-op by default, clamp what
/// it does apply, and state what it applied without ever claiming the capture's
/// own white balance. These tests run without a GPU.
struct DevelopWhiteBalanceTests {
    private func stock(_ temperature: Float = 5_600) -> FilmStockConfig {
        var config = FilmStockConfig(stockId: "test", displayName: "Kodak 5219", category: .video,
                                     lutName: "test.cube", halationStrength: 0, glowStrength: 0,
                                     grainSize: 1, defaultISO: 600)
        config.colorTemperature = temperature
        return config
    }

    // MARK: - Resolution

    /// The default develop is the decode this app always ran: the stock's own
    /// lock, passed through numerically untouched, and exactly zero warmth.
    @Test func neutralResolvesToTheStockLockAndZeroWarmth() {
        #expect(DevelopWhiteBalance.neutral.photoKelvin == nil)
        #expect(DevelopWhiteBalance.neutral.videoWarmth == nil)
        #expect(DevelopWhiteBalance.neutral.isPhotoNeutral)
        #expect(DevelopWhiteBalance.neutral.isVideoNeutral)
        for kelvin: Float in [2_000, 3_200, 5_600, 6_500, 9_000] {
            #expect(DevelopWhiteBalance.neutral.resolvedPhotoKelvin(stockKelvin: kelvin) == kelvin,
                    "a neutral still must decode at the stock's lock exactly")
            // Exactly: not a re-clamped or re-rounded copy of the stock's value.
            #expect(DevelopWhiteBalance.neutral.resolvedPhotoKelvin(stockKelvin: kelvin).bitPattern
                == kelvin.bitPattern)
        }
        #expect(DevelopWhiteBalance.neutral.resolvedVideoWarmth == 0)
        // A stock without a usable lock cannot be handed to the decoder as-is.
        #expect(DevelopWhiteBalance.neutral.resolvedPhotoKelvin(stockKelvin: .nan)
            == DevelopWhiteBalance.referenceKelvin)
        #expect(DevelopWhiteBalance.neutral.resolvedPhotoKelvin(stockKelvin: 0)
            == DevelopWhiteBalance.referenceKelvin)
    }

    @Test func photoKelvinIsClampedIntoTheDecoderRange() {
        #expect(DevelopWhiteBalance(photoKelvin: 1_500).resolvedPhotoKelvin(stockKelvin: 3_200)
            == DevelopWhiteBalance.photoKelvinRange.lowerBound)
        #expect(DevelopWhiteBalance(photoKelvin: 50_000).resolvedPhotoKelvin(stockKelvin: 3_200)
            == DevelopWhiteBalance.photoKelvinRange.upperBound)
        #expect(DevelopWhiteBalance(photoKelvin: 7_000).resolvedPhotoKelvin(stockKelvin: 3_200) == 7_000)
        // A clamped override wins over the stock even when the stock is in range.
        #expect(DevelopWhiteBalance(photoKelvin: 2_100).resolvedPhotoKelvin(stockKelvin: 3_200) == 2_100)
    }

    @Test func videoWarmthIsClampedToFullScaleAndZeroStaysZero() {
        #expect(DevelopWhiteBalance(videoWarmth: 4).resolvedVideoWarmth == 1)
        #expect(DevelopWhiteBalance(videoWarmth: -4).resolvedVideoWarmth == -1)
        #expect(DevelopWhiteBalance(videoWarmth: 0.25).resolvedVideoWarmth == 0.25)
        #expect(DevelopWhiteBalance(videoWarmth: -0).resolvedVideoWarmth == 0)
        #expect(DevelopWhiteBalance(videoWarmth: 0).isVideoNeutral)
        #expect(!DevelopWhiteBalance(videoWarmth: 0.001).isVideoNeutral)
    }

    /// A non-finite ask is no ask. Storing one would compare false against both
    /// clamp bounds and poison the decode or the matrix.
    @Test func nonFiniteAsksAreNoAsks() {
        for bad: Float in [.nan, .infinity, -.infinity, .signalingNaN] {
            let balance = DevelopWhiteBalance(photoKelvin: bad, videoWarmth: bad)
            #expect(balance.photoKelvin == nil, "\(bad) must not survive as a Kelvin")
            #expect(balance.videoWarmth == nil, "\(bad) must not survive as a warmth")
            #expect(balance == .neutral)
            #expect(balance.resolvedPhotoKelvin(stockKelvin: 3_200) == 3_200)
            #expect(balance.resolvedVideoWarmth == 0)
        }
    }

    // MARK: - Codable

    /// Old jobs carry no key at all; a field that is null or the wrong type
    /// degrades to "no adjustment" instead of failing the whole job decode.
    @Test func missingNullAndMalformedFieldsDecodeToNeutral() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(DevelopWhiteBalance.self, from: Data("{}".utf8)) == .neutral)
        #expect(try decoder.decode(DevelopWhiteBalance.self,
            from: Data(#"{"photoKelvin":null,"videoWarmth":null}"#.utf8)) == .neutral)
        #expect(try decoder.decode(DevelopWhiteBalance.self,
            from: Data(#"{"photoKelvin":"warm","videoWarmth":[1]}"#.utf8)) == .neutral)
        #expect(try decoder.decode(DevelopWhiteBalance.self,
            from: Data(#"{"photoKelvin":7000.5}"#.utf8))
            == DevelopWhiteBalance(photoKelvin: 7_000.5))
        #expect(try decoder.decode(DevelopWhiteBalance.self,
            from: Data(#"{"videoWarmth":-0.25}"#.utf8)) == DevelopWhiteBalance(videoWarmth: -0.25))
    }

    @Test func malformedWholeValuesDecodeToNeutral() throws {
        for json in ["null", "42", "[]", "\"warm\""] {
            let decoded = try JSONDecoder().decode(DevelopWhiteBalance.self, from: Data(json.utf8))
            #expect(decoded == .neutral, "Malformed optional adjustment must be neutral: \(json)")
        }
    }

    @Test func anAppliedValueRoundTripsThroughCodable() throws {
        let balance = DevelopWhiteBalance(photoKelvin: 6_100, videoWarmth: 0.375)
        let data = try JSONEncoder().encode(balance)
        #expect(try JSONDecoder().decode(DevelopWhiteBalance.self, from: data) == balance)
        let neutral = try JSONEncoder().encode(DevelopWhiteBalance.neutral)
        #expect(try JSONDecoder().decode(DevelopWhiteBalance.self, from: neutral) == .neutral)
    }

    // MARK: - Adaptation

    /// Zero warmth must be EXACTLY identity, not approximately: a neutral job may
    /// not move a single code.
    @Test func zeroWarmthIsExactlyIdentity() {
        for reference: Float in [2_000, 3_200, 5_600, 12_000] {
            #expect(DevelopWhiteBalanceStage.adaptation(referenceKelvin: reference, warmth: 0)
                == matrix_identity_float3x3)
        }
        // A non-finite warmth resolves to zero, and a nonsense reference falls
        // back to the documented one rather than producing a NaN matrix.
        #expect(DevelopWhiteBalanceStage.adaptation(referenceKelvin: 5_600, warmth: .nan)
            == matrix_identity_float3x3)
        let fallback = DevelopWhiteBalanceStage.adaptation(referenceKelvin: .nan, warmth: 0.5)
        let documented = DevelopWhiteBalanceStage.adaptation(
            referenceKelvin: DevelopWhiteBalance.referenceKelvin, warmth: 0.5)
        #expect(fallback == documented)
    }

    /// A positive warmth is a warm picture: red carries further than blue on the
    /// plate's neutral, and negative warmth is the mirror image.
    @Test func warmthMovesTheNeutralInTheOppositeDirection() {
        let neutral = SIMD3<Float>(repeating: 1)
        let warm = DevelopWhiteBalanceStage.adaptation(referenceKelvin: 5_600, warmth: 1) * neutral
        let cool = DevelopWhiteBalanceStage.adaptation(referenceKelvin: 5_600, warmth: -1) * neutral
        #expect(warm.x > warm.z, "a warm correction must raise red above blue, got \(warm)")
        #expect(cool.z > cool.x, "a cool correction must raise blue above red, got \(cool)")
        #expect(warm.x > cool.x)
        #expect(cool.z > warm.z)

        // Full scale is a mired shift, so it is the same visible step at a
        // tungsten reference as at a daylight one (a fixed Kelvin offset is not).
        let warmTungsten = DevelopWhiteBalanceStage.adaptation(referenceKelvin: 3_200, warmth: 1) * neutral
        #expect(warmTungsten.x > warmTungsten.z)
    }

    // MARK: - Metadata

    /// A delivered still states the Kelvin its develop applied and keeps the
    /// capture lock beside it. A neutral still states no development key at all.
    @Test func stillPayloadSeparatesDevelopmentKelvinFromTheCaptureLock() throws {
        let config = stock(3_200)
        let properties = try PhotoDeliveryMetadata.properties(
            config: config, capture: .init(), deliveredSize: CGSize(width: 64, height: 96),
            whiteBalance: DevelopWhiteBalance(photoKelvin: 7_000))
        let overridden = try payload(properties)
        let receipt = RenderReceiptService.stillMetadata(inImageProperties: properties)
        #expect(receipt["com.filmemulation.development-photo-kelvin"] == "7000.0")
        #expect(overridden["white-balance-kelvin"] == "3200", "the capture lock is untouched")
        #expect(overridden["development-photo-kelvin"] == "7000.0")

        let neutral = try payload(PhotoDeliveryMetadata.properties(
            config: config, capture: .init(), deliveredSize: CGSize(width: 64, height: 96)))
        #expect(neutral["white-balance-kelvin"] == "3200")
        #expect(neutral["development-photo-kelvin"] == nil)

        // A clamped override reports what the develop actually used.
        let clamped = try payload(PhotoDeliveryMetadata.properties(
            config: config, capture: .init(), deliveredSize: CGSize(width: 64, height: 96),
            whiteBalance: DevelopWhiteBalance(photoKelvin: 40_000)))
        #expect(clamped["development-photo-kelvin"] == "12000.0")
    }

    /// A delivered movie states the RELATIVE warmth, never a Kelvin the take was
    /// not captured at, and leaves the capture lock alone.
    @Test func movieItemsStateRelativeWarmthAndKeepTheCaptureLock() throws {
        let config = stock(5_600)
        let warm = try movieValues(RenderMovieMetadata.make(
            config: config, whiteBalance: DevelopWhiteBalance(videoWarmth: 0.4)))
        #expect(warm["development-video-warmth"] == "0.400")
        #expect(warm["white-balance-kelvin"] == "5600")
        #expect(warm["development-photo-kelvin"] == nil, "a movie makes no photo-decode claim")

        let neutral = try movieValues(RenderMovieMetadata.make(config: config))
        #expect(neutral["development-video-warmth"] == nil)
        #expect(neutral["white-balance-kelvin"] == "5600")
    }

    // MARK: - Helpers

    private func payload(_ properties: [CFString: Any]) throws -> [String: String] {
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let comment = try #require(exif[kCGImagePropertyExifUserComment] as? String)
        let object = try JSONSerialization.jsonObject(with: Data(comment.utf8))
        return try #require(object as? [String: String])
    }

    private func movieValues(_ items: [AVMetadataItem]) throws -> [String: String] {
        var values: [String: String] = [:]
        for item in items where item.keySpace == .quickTimeMetadata {
            guard let key = item.key as? String, key.hasPrefix("com.filmemulation."),
                  let value = item.value as? String else { continue }
            values[String(key.dropFirst("com.filmemulation.".count))] = value
        }
        #expect(!values.isEmpty)
        return values
    }
}
