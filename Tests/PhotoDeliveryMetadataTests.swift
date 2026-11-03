import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A delivered still must carry the same Nitrate tags as a delivered movie, in
/// the fields photo apps actually read.
struct PhotoDeliveryMetadataTests {
    private final class BundleToken {}

    @Test(arguments: PrintGauge.allCases)
    func constructedStillResourcesCarryRequestedGaugeIntoJPEG(gauge: PrintGauge) throws {
        // Start with the catalog, not an already-overridden test config: the
        // construction seam previously rendered one gauge but tagged 35mm.
        let film = try StillFilmRenderResources(stockID: "kodak5219", gauge: gauge, seed: 42,
            bundle: Bundle(for: BundleToken.self))
        #expect(film.gauge == gauge)
        #expect(film.config.effectivePrintGauge == gauge)
        let properties = try writtenProperties(film.config, capture: .init())
        let recipe = try payload(properties)
        #expect(recipe["print-gauge"] == gauge.rawValue)
        let effectiveSize = try #require(recipe["grain-size-effective"].flatMap(Float.init))
        #expect(abs(effectiveSize - GrainModel.effectiveSize(
            stockGrainSize: film.config.grainSize, gauge: gauge)) < 0.001)
        let iptc = try #require(properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String
            == "nitrate: \(film.config.displayName) | \(gauge.rawValue)")
    }

    private func config(gauge: PrintGauge?) throws -> FilmStockConfig {
        let stock = FilmStockConfig(stockId: "test", displayName: "Kodak 5219", category: .video,
            lutName: "test.cube", halationStrength: 0, glowStrength: 0, grainSize: 1, defaultISO: 600)
        return stock.overridingGauge(gauge)
    }

    /// Write a tiny JPEG with the delivery tags and read its properties back, so
    /// the assertions run against what a photo app would see.
    private func writtenProperties(_ config: FilmStockConfig, capture: PhotoDeliveryMetadata.StillCapture,
                                   size: CGSize = CGSize(width: 64, height: 96)) throws -> [CFString: Any] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-tags-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try #require(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        for (key, value) in try PhotoDeliveryMetadata.properties(config: config, capture: capture,
                                                                 deliveredSize: size) {
            properties[key] = value
        }
        CGImageDestinationAddImage(sink, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(sink))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func payload(_ properties: [CFString: Any]) throws -> [String: String] {
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let comment = try #require(exif[kCGImagePropertyExifUserComment] as? String)
        let data = Data(comment.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: String])
    }

    @Test func stillCarriesTheSameConsumerCaptionAndKeywordsAsAMovie() throws {
        let config = try config(gauge: .sixteenMillimetre)
        let properties = try writtenProperties(config, capture: .init())
        let caption = "nitrate: Kodak 5219 | 16mm"

        let iptc = try #require(properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String == caption)
        // 64x96 is portrait: the keyword names the delivered shape, as it does
        // for a movie's preferred transform.
        #expect(iptc[kCGImagePropertyIPTCKeywords] as? [String] == ["nitrate", "portrait"])

        // ImageIO writes no TIFF dictionary for JPEG — checked by round trip —
        // so the still must not rely on one for its description.
        #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
    }

    @Test func stillPayloadMatchesTheMoviePayloadKeyForKey() throws {
        let config = try config(gauge: .sixteenMillimetre)
        let movieItems = try RenderMovieMetadata.make(config: config)
        var movie: [String: String] = [:]
        for item in movieItems where item.keySpace == .quickTimeMetadata {
            guard let key = item.key as? String, key.hasPrefix("com.filmemulation."),
                  let value = item.value as? String else { continue }
            movie[String(key.dropFirst("com.filmemulation.".count))] = value
        }
        let still = try payload(try writtenProperties(config, capture: .init()))

        // Everything the movie states about the recipe the still states too.
        let shared = movie.keys.filter { !PhotoDeliveryMetadata.movieOnlyKeys.contains($0) }
        #expect(!shared.isEmpty)
        for key in shared where key != "encoding-codec" {
            #expect(still[key] == movie[key], "still \(key) must match the movie: \(still[key] ?? "nil") vs \(movie[key] ?? "nil")")
        }
        // Movie-only claims are dropped, and the codec tells the truth.
        for key in PhotoDeliveryMetadata.movieOnlyKeys {
            #expect(still[key] == nil, "\(key) describes a take, not a still")
        }
        #expect(still["encoding-codec"] == "jpeg")
        #expect(still["film-stock"] == "test")
    }

    @Test func captureExposureReplacesTheMoviesNominalShutter() throws {
        let config = try config(gauge: .thirtyFiveMillimetre)
        let capture = PhotoDeliveryMetadata.StillCapture(exposureSeconds: 1.0 / 500.0, iso: 800)
        let still = try payload(try writtenProperties(config, capture: capture))
        #expect(still["shutter-speed"] == "1/500")
        #expect(still["iso"] == "800")
        #expect(still["iso-role"] == "capture-exposure-index")

        let exif = try #require(try writtenProperties(config, capture: capture)[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect((exif[kCGImagePropertyExifISOSpeedRatings] as? [Int]) == [800])
        #expect(abs(((exif[kCGImagePropertyExifExposureTime] as? Double) ?? 0) - 1.0 / 500.0) < 1e-9)
    }

    @Test func unknownCaptureExposureMakesNoClaim() throws {
        let config = try config(gauge: nil)
        let still = try payload(try writtenProperties(config, capture: .init()))
        // With no DNG exposure there is nothing measured to report, so the
        // recipe's nominal shutter and ISO role stand as the movie states them
        // rather than the still inventing a capture exposure.
        #expect(still["shutter-speed"] == "1/48")
        #expect(still["iso-role"] == "selected-render-exposure-index")
        #expect(PhotoDeliveryMetadata.StillCapture().shutterDenominator == nil)
    }

    @Test func shutterDenominatorIgnoresNonFiniteExposure() {
        #expect(PhotoDeliveryMetadata.StillCapture(exposureSeconds: 0.002).shutterDenominator == 500)
        #expect(PhotoDeliveryMetadata.StillCapture(exposureSeconds: 0).shutterDenominator == nil)
        #expect(PhotoDeliveryMetadata.StillCapture(exposureSeconds: .nan).shutterDenominator == nil)
        // A missing or unreadable DNG path yields no claim instead of throwing.
        #expect(PhotoDeliveryMetadata.capture(fromDNG: URL(fileURLWithPath: "/nonexistent.dng")) == .init())
    }

    /// A still carries the whole card set, not just exposure: the same push/pull
    /// the take was developed with, plus the lens and aperture the DNG knows.
    @Test func stillRecordsPushPullLensAndSlate() throws {
        let config = try config(gauge: .thirtyFiveMillimetre).overridingPushPull(.manual(.pullTwo))
        let capture = PhotoDeliveryMetadata.StillCapture(exposureSeconds: 1.0 / 500.0, iso: 800,
            fNumber: 3.99932, lensModel: "iPhone 16 Pro back camera", focalLengthMM: 24)
        let properties = try writtenProperties(config, capture: capture)
        let still = try payload(properties)

        #expect(still["push-pull"] == "pulled")
        #expect(still["push-pull-stops"] == "-2")
        #expect(still["push-pull-linear-gain"] == "0.25")
        #expect(still["aperture-f-number"] == "3.99932")
        #expect(still["lens"] == "iPhone 16 Pro back camera")
        #expect(still["focal-length-mm"] == "24.0")
        #expect(still["color-space"] == config.effectiveRecipe.input.transfer)
        #expect(still["white-balance-kelvin"] == String(Int(config.colorTemperature)))
        #expect(still["wb-tint"] == "0")
        #expect(still["reel"] == "1")
        #expect(still["scene"] == "1")
        #expect(still["take"] == "1")

        // Photo apps read the aperture from EXIF, not from the payload comment.
        // The EXIF rational round-trips through single precision, hence the
        // generous tolerance.
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(abs(((exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue ?? 0) - 3.99932) < 1e-4)
        #expect(exif[kCGImagePropertyExifLensModel] as? String == "iPhone 16 Pro back camera")
    }
}
