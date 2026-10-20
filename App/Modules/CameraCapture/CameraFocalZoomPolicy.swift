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
/// The capture session's display zoom factor is anchored at the wide-angle
/// camera's 1x. `CameraLens` publishes `ultraWide` as 13 mm (~0.54x), `wide` as
/// 24 mm (1x) and `telephoto` as 96 mm (4x); `publishZoom()` multiplies the
/// device's `videoZoomFactor` by `CameraZoomPolicy`'s multiplier, which is the
/// device's `displayVideoZoomFactorMultiplier` on iOS 18+ (a global display
/// zoom, so one 24 mm reference converts any lens) and 1 on iOS 17 where the
/// snapshot reports `isPerLens == true` (the device's own 1x, so each lens
/// converts with its own base focal length).
enum CameraFocalZoomPolicy {
    /// Ruler landmarks shared with the UI, so haptics land on the same values
    /// the policy treats as boundaries.
    static let majorTicks: [Double] = [13, 24, 35, 50, 75, 96, 110, 150]

    static let minimumFocalLengthMM: Double = 13
    static let maximumFocalLengthMM: Double = 150

    /// The wide (1x) camera's equivalent full-frame focal length. The session's
    /// non-per-lens display factor is measured against this lens.
    static let wideReferenceFocalLengthMM: Double = 24
    /// Below this the target prefers the ultrawide camera.
    static let ultraWideUpperBoundMM: Double = 24
    /// Above this the target prefers the telephoto camera.
    static let wideUpperBoundMM: Double = 96

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

    /// Session display zoom factor that renders `millimeters` on `tier`.
    static func displayFactor(forFocalLengthMM millimeters: Double,
                              isPerLens: Bool,
                              tier: CameraFocalZoomLensTier) -> Double? {
        guard millimeters.isFinite, millimeters > 0 else { return nil }
        let reference = isPerLens ? baseFocalLengthMM(for: tier) : wideReferenceFocalLengthMM
        guard reference > 0 else { return nil }
        return millimeters / reference
    }

    /// Equivalent full-frame focal length of a published display factor.
    static func focalLengthMM(displayFactor: Double,
                              isPerLens: Bool,
                              tier: CameraFocalZoomLensTier) -> Double? {
        guard displayFactor.isFinite, displayFactor > 0 else { return nil }
        let reference = isPerLens ? baseFocalLengthMM(for: tier) : wideReferenceFocalLengthMM
        return displayFactor * reference
    }

    /// Whether `millimeters` sits on a shared ruler landmark, in the frame's own
    /// units. Used by the UI to fire major-tick haptics.
    static func isMajorTick(_ millimeters: Double, tolerance: Double = 0.5) -> Bool {
        guard millimeters.isFinite else { return false }
        return majorTicks.contains { abs($0 - millimeters) <= tolerance }
    }

    static func nearestMajorTick(to millimeters: Double) -> Double? {
        guard millimeters.isFinite else { return nil }
        return majorTicks.min { abs($0 - millimeters) < abs($1 - millimeters) }
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
        let desired = CameraFocalZoomPolicy.tier(forFocalLength: mm)
        guard let tier = CameraFocalZoomPolicy.resolvedTier(desired, available: available) else {
            return .ignore
        }
        if tier == activeTier { return .adjust(tier: tier, targetMM: mm) }
        isSwitching = true
        pendingTargetMM = mm
        return .switchLens(to: tier, targetMM: mm)
    }
}
