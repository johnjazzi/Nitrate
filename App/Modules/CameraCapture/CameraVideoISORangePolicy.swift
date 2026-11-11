import Foundation

/// The ISO band the video (Apple Log 2) capture path can actually honour.
///
/// The shared idle camera graph holds a still-capable format whose ISO range is
/// wider than the recorder's. Measured on an iPhone 18 Pro (iOS 27.2), main
/// camera: still 55...12320 against the Log 2 4K format's 55...5280 — and the
/// top differs per camera (ultra-wide 15...3600, telephoto 15...7680), which is
/// why the band has to be resolved per camera instead of from one constant or
/// from the active format.
enum CameraVideoISORangePolicy {
    /// The intersection of the eligible video formats' ranges, so a frame-rate
    /// mode that resolves a different format cannot offer an ISO the take would
    /// refuse. Nil when no format is eligible or the ranges do not overlap; the
    /// caller then falls back to the active format's range.
    static func range(forCandidates candidates: [ClosedRange<Float>]) -> ClosedRange<Float>? {
        var band: ClosedRange<Float>?
        for candidate in candidates {
            guard candidate.lowerBound.isFinite, candidate.upperBound.isFinite,
                  candidate.lowerBound > 0, candidate.upperBound >= candidate.lowerBound else { continue }
            guard let current = band else { band = candidate; continue }
            let lower = max(current.lowerBound, candidate.lowerBound)
            let upper = min(current.upperBound, candidate.upperBound)
            guard lower <= upper else { return nil }
            band = lower...upper
        }
        return band
    }
}
