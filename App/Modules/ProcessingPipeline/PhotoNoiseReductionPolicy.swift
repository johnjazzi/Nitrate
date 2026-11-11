import Foundation

/// Capture-ISO-dependent RAW color noise reduction, before film effects.
/// Luminance NR remains zero; synthetic grain is a separate post-grade stage.
///
/// Four local DNG sweeps (ISO 640/1000/1600/12500) reduced the median-block
/// chroma high-pass metric. At ISO 1000 it changed from 0.04821 at amount 0 to
/// 0.00763 at 0.75; at ISO 12500 it changed from 0.09238 to 0.01838 at 1.0.
/// These are scene-dependent noise proxies, not proof that fine detail is intact
/// or calibration for every camera. See the Photo spec for experiment provenance.
/// The ramp below is an initial policy, not a measured sensor noise model.
enum PhotoNoiseReductionPolicy {
    /// The control's own maximum, reached at the top of the still ISO band.
    static let maximumColorAmount: Float = 1.0
    /// The ISO below which no reduction is requested.
    static let firstReducedISO: Float = 200
    /// The ISO where the first segment hands over to the second.
    static let shoulderISO: Float = 1000
    /// What the ramp asks for at the shoulder: the measured plateau at 1000 and 1600.
    static let shoulderColorAmount: Float = 0.75
    /// The top of the camera's still ISO band, where the ramp reaches the maximum.
    static let bandTopISO: Float = 12500

    static func colorAmount(iso: Int?) -> Float {
        guard let iso else { return 0 }
        return colorAmount(iso: Float(iso))
    }

    /// Linear in stops in both segments: sensitivity is a doubling scale, so an
    /// ISO-linear ramp would spend most of its travel in the top two stops.
    static func colorAmount(iso: Float) -> Float {
        guard iso.isFinite, iso > 0 else { return 0 }
        let rampToShoulder = log2(iso / firstReducedISO) / log2(shoulderISO / firstReducedISO)
        let lower = min(max(rampToShoulder, 0), 1) * shoulderColorAmount
        guard iso > shoulderISO else { return lower }
        let rampToTop = log2(iso / shoulderISO) / log2(bandTopISO / shoulderISO)
        return shoulderColorAmount + (maximumColorAmount - shoulderColorAmount) * min(rampToTop, 1)
    }

    /// Never requested; see the note above.
    static func luminanceAmount(iso: Float) -> Float { 0 }

    /// The decode's own settings report, so a developed still says how much
    /// reduction it was graded from instead of leaving it to be inferred.
    static func report(iso: Int?) -> String {
        let amount = colorAmount(iso: iso)
        let text = String(format: "%.2f", amount)
        let reason: String
        if amount == 0 {
            reason = "iso-below-\(Int(firstReducedISO))"
        } else if let iso, Float(iso) > shoulderISO {
            reason = "iso-ramped-to-\(Int(bandTopISO))"
        } else {
            reason = "iso-ramped-to-\(Int(shoulderISO))"
        }
        return "color=\(text),luminance=0,reason=\(reason)"
    }
}
