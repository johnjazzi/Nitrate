import Foundation

/// The operator's development white balance for one delivery.
///
/// This is a processing decision, not a capture claim. Imported media may have
/// unknown capture WB. RAW can override the stock's decoding temperature; video
/// gets a relative correction around a stock-defined reference, never a measured
/// source temperature. Neither changes capture controls or source provenance.
/// Both defaults preserve the existing processing path.
///
/// The photo lane passes `resolvedPhotoKelvin(stockKelvin:)` into
/// `RAWPhotoDecoder.decode`, i.e. the override enters the decode and the grade
/// downstream is untouched. The video lane applies `resolvedVideoWarmth` as a
/// chromatic adaptation in linear Apple Wide Gamut BEFORE halation, exposure
/// and the stock LUT — never as a display tint and never on sRGB-encoded Log
/// codes. `DevelopWhiteBalanceStage` is the single implementation of that
/// correction, shared by the frame preview and the export.
struct DevelopWhiteBalance: Codable, Equatable, Sendable {
    /// A photo Kelvin override. Nil develops at the stock's own lock.
    let photoKelvin: Float?

    /// A video relative warmth in `-1...1`. Nil is the unmodified take.
    let videoWarmth: Float?

    /// No operator adjustment: the stock's own white balance on both lanes.
    static let neutral = DevelopWhiteBalance()

    /// The range the RAW decoder is asked for on a still.
    static let photoKelvinRange: ClosedRange<Float> = 2_000...12_000

    /// Full scale of the relative video control.
    static let videoWarmthRange: ClosedRange<Float> = -1...1

    /// Fallback reference for the relative correction. Production uses the
    /// selected stock temperature; neither reference measures capture WB.
    static let referenceKelvin: Float = 5_600

    init(photoKelvin: Float? = nil, videoWarmth: Float? = nil) {
        // A non-finite ask is no ask. Storing one would poison every downstream
        // clamp, because a NaN compares false against both bounds.
        self.photoKelvin = photoKelvin.flatMap { $0.isFinite ? $0 : nil }
        self.videoWarmth = videoWarmth.flatMap { $0.isFinite ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey {
        case photoKelvin
        case videoWarmth
    }

    /// Old jobs predate this value and carry nothing at all; a malformed field
    /// degrades to "no adjustment" instead of failing the whole job decode.
    init(from decoder: Decoder) throws {
        // A value that is not a keyed object at all — null, a string, a
        // number, an array — is no adjustment, not a failed job.
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .neutral
            return
        }
        self.init(photoKelvin: try? container.decodeIfPresent(Float.self, forKey: .photoKelvin),
                  videoWarmth: try? container.decodeIfPresent(Float.self, forKey: .videoWarmth))
    }

    /// The Kelvin the photo decoder is asked for.
    ///
    /// With no override the stock's lock passes through untouched — not
    /// re-clamped — so the default still is the decode it always was. An
    /// override is clamped into the decoder's ordinary still range.
    func resolvedPhotoKelvin(stockKelvin: Float) -> Float {
        guard let photoKelvin else {
            return stockKelvin.isFinite && stockKelvin > 0 ? stockKelvin : Self.referenceKelvin
        }
        return Self.clampedPhotoKelvin(photoKelvin)
    }

    /// The relative warmth that will be applied: finite and inside `-1...1`,
    /// with "no adjustment" resolving to exactly zero.
    var resolvedVideoWarmth: Float {
        guard let videoWarmth else { return 0 }
        return min(max(videoWarmth, Self.videoWarmthRange.lowerBound),
                   Self.videoWarmthRange.upperBound)
    }

    /// True when the still developed at the stock's own lock.
    var isPhotoNeutral: Bool { photoKelvin == nil }

    /// True when the movie is the unmodified take.
    var isVideoNeutral: Bool { resolvedVideoWarmth == 0 }

    /// Tags for a delivered still, stating the Kelvin the develop actually
    /// applied. Empty when the stock's own develop ran, so a neutral still
    /// claims nothing it did not do. Present, it is distinct from
    /// `white-balance-kelvin`, which reports the selected stock temperature.
    var photoMetadataValues: [String: String] {
        guard let photoKelvin else { return [:] }
        // The value the decode actually used, so a clamped ask is not reported
        // as if it had been honoured.
        return ["development-photo-kelvin": Self.format(Self.clampedPhotoKelvin(photoKelvin), places: 1)]
    }

    /// Tags for a delivered movie. The video value is a RELATIVE warmth, so it
    /// is stated as the control's own number rather than as a Kelvin the take
    /// was never captured at.
    var videoMetadataValues: [String: String] {
        let warmth = resolvedVideoWarmth
        guard warmth != 0 else { return [:] }
        return ["development-video-warmth": Self.format(warmth, places: 3)]
    }

    private static func format(_ value: Float, places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    /// One clamp rule for the decode and for what the file states it did.
    private static func clampedPhotoKelvin(_ kelvin: Float) -> Float {
        min(max(kelvin, photoKelvinRange.lowerBound), photoKelvinRange.upperBound)
    }
}
