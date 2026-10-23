import Foundation

/// Which physical lens a focal-length target resolves to. Deliberately free of
/// AVFoundation so the pure policy and its tests compile without the capture
/// session. `CameraViewModel` maps `CameraLens` to and from this tier.
enum CameraFocalZoomLensTier: String, Equatable, Sendable, CaseIterable {
    case ultraWide
    case wide
    case telephoto
    case front
}

/// The focal-length pinch engine's shared, pure decision layer.
///
/// `CameraLens` publishes `ultraWide` as 13 mm, `wide` as 24 mm (1x) and
/// `telephoto` as 96 mm, so every lens has its own native base. The session
/// publishes `displayFactor == device.videoZoomFactor * multiplier`, where the
/// multiplier is the device's real `displayVideoZoomFactorMultiplier` (1 on
/// iOS 17, where the snapshot reports `isPerLens == true`). Conversion is
/// anchored on the tier's native base — `displayFactor == multiplier * mm /
/// base` — never on one global 24 mm reference, because that would report the
/// ultrawide's native 0.5x as 12 mm instead of its 13 mm.
enum CameraFocalZoomPolicy {
    /// Ruler landmarks shared with the UI, so haptics land on the same values
    /// the policy treats as boundaries. The single shared source the UI may
    /// alias for its own ruler.
    static let majorTicks: [Double] = [13, 24, 35, 50, 75, 96, 110, 150]

    static let minimumFocalLengthMM: Double = 13
    static let maximumFocalLengthMM: Double = 150

    /// Below this the target prefers the ultrawide camera.
    static let ultraWideUpperBoundMM: Double = 24
    /// Above this the target prefers the telephoto camera.
    static let wideUpperBoundMM: Double = 96

    /// Deadband around each tier boundary, in millimetres, applied only while
    /// deciding whether to *switch* the physical lens. A pinch that dithers
    /// across 24 mm or 96 mm (hand tremor, a fractional drag) must not rebuild
    /// the capture device: the active lens holds until the target clears the
    /// boundary by this much. Kept well under `(96 - 24) / 2`, so no dead zone
    /// exists where neither neighbouring lens is reachable, and far smaller than
    /// the 24↔96 gap, so a deliberate reversal still switches promptly.
    static let boundaryHysteresisMM: Double = 1.0

    /// Clamp a requested focal length into the valid, finite 13...150 range.
    /// Non-finite input is refused rather than coerced.
    static func clampedTarget(_ millimeters: Double) -> Double? {
        guard millimeters.isFinite else { return nil }
        return min(max(millimeters, minimumFocalLengthMM), maximumFocalLengthMM)
    }

    /// Which lens a focal length prefers: below 24 mm ultrawide, 24 through
    /// 96 mm wide, above 96 mm telephoto.
    static func tier(forFocalLength millimeters: Double) -> CameraFocalZoomLensTier {
        if millimeters < ultraWideUpperBoundMM { return .ultraWide }
        if millimeters <= wideUpperBoundMM { return .wide }
        return .telephoto
    }

    /// The lens to *switch to* for a target, given the lens the pinch is
    /// currently on. This is the hysteresis-aware companion to the pure
    /// preference `tier(forFocalLength:)`: the active lens holds its tier until
    /// the target clears the shared boundary by `boundaryHysteresisMM`, and a
    /// target far onto the other side still resolves straight to its
    /// preference (a single jump may cross more than one boundary).
    ///
    /// Only `tier(forFocalLength:)` decides *preference* (the UI ruler, the
    /// readout window); this decides *switch*. Both the engine and the view
    /// model's normalizer call it, so the announced readout and the engine's
    /// decision can never disagree about whether a switch is warranted.
    static func tier(forFocalLength millimeters: Double,
                     currentlyOn active: CameraFocalZoomLensTier) -> CameraFocalZoomLensTier {
        guard millimeters.isFinite else { return tier(forFocalLength: millimeters) }
        let delta = boundaryHysteresisMM
        switch active {
        case .wide:
            // Hold wide across [24 - delta, 96 + delta].
            if millimeters < ultraWideUpperBoundMM - delta { return .ultraWide }
            if millimeters > wideUpperBoundMM + delta { return .telephoto }
            return .wide
        case .ultraWide:
            // Hold ultrawide up to 24 + delta; beyond, resolve to preference
            // (wide, or telephoto if the gesture jumped the whole wide span).
            if millimeters > ultraWideUpperBoundMM + delta { return tier(forFocalLength: millimeters) }
            return .ultraWide
        case .telephoto:
            // Hold telephoto down to 96 - delta; below, resolve to preference
            // (wide, or ultrawide if the gesture jumped the whole wide span).
            if millimeters < wideUpperBoundMM - delta { return tier(forFocalLength: millimeters) }
            return .telephoto
        case .front:
            return .front
        }
    }

    /// The lens to drive for a target, falling back to the nearest available
    /// rear lens when the preferred tier is absent. Nil when no rear lens exists.
    static func resolvedTier(_ desired: CameraFocalZoomLensTier,
                             available: [CameraFocalZoomLensTier]) -> CameraFocalZoomLensTier? {
        let rear = available.filter { $0 != .front }
        guard !rear.isEmpty else { return nil }
        if rear.contains(desired) { return desired }
        switch desired {
        case .ultraWide: return rear.contains(.wide) ? .wide : rear.first
        case .wide: return rear.contains(.ultraWide) ? .ultraWide : rear.first
        case .telephoto: return rear.contains(.wide) ? .wide : rear.first
        case .front: return nil
        }
    }

    /// A lens's equivalent full-frame focal length at its own 1x.
    static func baseFocalLengthMM(for tier: CameraFocalZoomLensTier) -> Double {
        switch tier {
        case .ultraWide: return 13
        case .wide, .front: return 24
        case .telephoto: return 96
        }
    }

    /// Display zoom factor the session publishes to render `millimeters` on
    /// `tier`: `multiplier * millimeters / tierBase`. `multiplier` is the real
    /// display multiplier from the zoom snapshot; it must be finite and
    /// positive, otherwise the request is refused rather than mis-converted.
    static func displayFactor(forFocalLengthMM millimeters: Double,
                              multiplier: Double,
                              tier: CameraFocalZoomLensTier) -> Double? {
        guard millimeters.isFinite, millimeters > 0,
              multiplier.isFinite, multiplier > 0 else { return nil }
        let base = baseFocalLengthMM(for: tier)
        guard base > 0 else { return nil }
        return multiplier * (millimeters / base)
    }

    /// Equivalent full-frame focal length a published display factor renders on
    /// `tier`: `tierBase * displayFactor / multiplier`. Anchoring on the tier's
    /// own base keeps the ultrawide's native 0.5x at 13 mm instead of the 12 mm
    /// a global 24 mm reference reports.
    static func focalLengthMM(displayFactor: Double,
                              multiplier: Double,
                              tier: CameraFocalZoomLensTier) -> Double? {
        guard displayFactor.isFinite, displayFactor > 0,
              multiplier.isFinite, multiplier > 0 else { return nil }
        let base = baseFocalLengthMM(for: tier)
        guard base > 0 else { return nil }
        return base * (displayFactor / multiplier)
    }

    /// The focal-length window a lens can actually render, converted from the
    /// session's non-round display-factor bounds with the *same* tier/multiplier
    /// converter the live readout uses (`focalLengthMM(displayFactor:multiplier:
    /// tier:)`). The ruler and the readout therefore share one conversion and can
    /// never disagree: a telephoto ceiling of 16x on a 96 mm base reports up to
    /// 1536 mm, a wide ceiling of 16x on a 24 mm base up to 384 mm, and the
    /// iOS 17 per-lens multiplier of 1 needs no special case.
    ///
    /// Nil when either bound is refused (non-finite, zero or negative factor or
    /// multiplier) or when the converted bounds are inverted, so the caller
    /// falls back to the fixed landmarks rather than drawing a bogus rail.
    static func availableFocalLengthRange(minimumDisplayFactor: Double,
                                          maximumDisplayFactor: Double,
                                          multiplier: Double,
                                          tier: CameraFocalZoomLensTier) -> ClosedRange<Double>? {
        guard let minimum = focalLengthMM(displayFactor: minimumDisplayFactor,
                                          multiplier: multiplier, tier: tier),
              let maximum = focalLengthMM(displayFactor: maximumDisplayFactor,
                                          multiplier: multiplier, tier: tier),
              minimum <= maximum else { return nil }
        return minimum...maximum
    }
}

/// Coalesces pinch updates while a physical lens switch is in flight and keeps
/// the gesture continuous in absolute focal length across that switch.
///
/// Pure and value-semantic so the lifecycle is unit-testable: the view model
/// owns the AVFoundation work (the revision-bound `setDisplayZoom` and
/// `selectLens` calls) and feeds decisions back in.
struct CameraFocalZoomEngine: Sendable {
    enum Decision: Equatable, Sendable {
        case ignore
        case adjust(tier: CameraFocalZoomLensTier, targetMM: Double)
        case switchLens(to: CameraFocalZoomLensTier, targetMM: Double)
    }

    private(set) var activeTier: CameraFocalZoomLensTier
    private(set) var isSwitching = false
    private(set) var pendingTargetMM: Double?

    init(activeTier: CameraFocalZoomLensTier) { self.activeTier = activeTier }

    /// Resolve one pinch update. While a switch is in flight the freshest target
    /// is retained and the committed switch applies it, so no update is lost and
    /// none replays out of order.
    mutating func request(targetMM raw: Double,
                          available: [CameraFocalZoomLensTier]) -> Decision {
        guard let mm = CameraFocalZoomPolicy.clampedTarget(raw) else { return .ignore }
        if isSwitching {
            pendingTargetMM = mm
            return .ignore
        }
        return resolve(mm, available: available)
    }

    /// The physical switch committed to `tier` (success, or an externally
    /// committed lens). Drains any queued target, preserving absolute focal
    /// length across the boundary.
    mutating func switchCommitted(to tier: CameraFocalZoomLensTier,
                                  available: [CameraFocalZoomLensTier]) -> Decision {
        activeTier = tier
        isSwitching = false
        guard let mm = pendingTargetMM else { return .ignore }
        pendingTargetMM = nil
        return resolve(mm, available: available)
    }

    /// A recording transition, lifecycle change, manual lens switch or failed
    /// switch drops the gesture: nothing queued may replay afterwards.
    mutating func invalidate() {
        isSwitching = false
        pendingTargetMM = nil
    }

    /// Adopt an externally committed lens (manual selection) and drop any queued
    /// pinch gesture, which the manual switch has superseded.
    mutating func syncActiveTier(_ tier: CameraFocalZoomLensTier) {
        activeTier = tier
        invalidate()
    }

    private mutating func resolve(_ mm: Double,
                                  available: [CameraFocalZoomLensTier]) -> Decision {
        // The front camera never switches away: it only adjusts its own zoom.
        if activeTier == .front { return .adjust(tier: .front, targetMM: mm) }
        // Hysteresis-aware: the active tier holds across a boundary dither, so a
        // pinch that wobbles across 24 mm/96 mm cannot re-issue the switch that
        // is already committed or in flight. The pure preference
        // `tier(forFocalLength:)` is unchanged; only the switch decision damps.
        let desired = CameraFocalZoomPolicy.tier(forFocalLength: mm, currentlyOn: activeTier)
        guard let tier = CameraFocalZoomPolicy.resolvedTier(desired, available: available) else {
            return .ignore
        }
        if tier == activeTier { return .adjust(tier: tier, targetMM: mm) }
        isSwitching = true
        pendingTargetMM = mm
        return .switchLens(to: tier, targetMM: mm)
    }
}
