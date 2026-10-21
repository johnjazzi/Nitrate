import Foundation

/// Grain temporal cadence for an exported clip.
///
/// `perFrame` is the legacy/default behaviour: every output frame gets its own
/// grain realization. `pairedAtHalfRate` is the experimental daylight-60fps
/// choice: grain runs at half the motion rate, so frames `(2k, 2k+1)` share one
/// grain realization (30 Hz grain over 60 Hz motion). This shares only the grain
/// *field* — the seed/z-slice, phase and sampling coordinates — not a
/// pixel-identical composite; the two source frames differ in content, so the
/// luminance-adapted latitude, edgeFactor, headroom budget and base mix differ.
/// Paired grain is not an industry standard and is not visually approved.
enum GrainPairing: String, Codable, Equatable, Sendable {
    case perFrame
    case pairedAtHalfRate
}

/// Pure mapping from the render loop's per-frame index to the index fed to the
/// grain kernel. The render loop keeps its own `frameIndex` for diagnostics and
/// failure injection; only the grain call uses the derived index.
enum GrainPairingPolicy {
    /// `pairedAtHalfRate`: 0,0,1,1,2,2,…   `perFrame`: 0,1,2,3,…
    static func grainIndex(frameIndex: UInt32, pairing: GrainPairing) -> UInt32 {
        switch pairing {
        case .perFrame: return frameIndex
        case .pairedAtHalfRate: return frameIndex / 2
        }
    }
}
