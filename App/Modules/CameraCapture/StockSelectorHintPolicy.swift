import Foundation

/// Direction of a scene's neutral (Gray-World) estimate relative to the selected
/// stock's locked white-balance reference.
enum StockSelectorHintMismatch: Equatable, Sendable {
    /// The scene's estimated neutral is cooler than the stock (higher Kelvin).
    case cool
    /// The scene's estimated neutral is warmer than the stock (lower Kelvin).
    case warm
}

/// A gentle, discoverability-only hint that outlines the whole stock-selector
/// well when a scene stays meaningfully warmer or cooler than the selected stock.
///
/// Pure Foundation: no AVFoundation, no SwiftUI, no device access. The caller
/// converts the device's Gray-World gains to a Kelvin estimate (that AVFoundation
/// call site is macOS-unavailable, so it stays in the iOS-only session), and the
/// resulting mismatch is fed here, where it is unit testable.
///
/// This is a soft nudge toward the stock control, **never** a claim of
/// colorimetric correctness and never an automatic correction. The Gray-World
/// estimate assumes a neutral subject filling the centre 50% of the frame, so an
/// intentionally coloured or off-centre scene can present a false direction.
/// That limitation is accepted for a quiet hint and documented in
/// `docs/camera-controls.md`.
enum StockSelectorHintPolicy {
    /// Whole seconds of active camera use required before a hint may appear.
    static let requiredActiveSeconds: TimeInterval = 90
    /// Seconds a mismatch must persist, in one direction, before a hint.
    static let requiredSustainedSeconds: TimeInterval = 10
    /// Minimum scenario/stock difference, in mired (reciprocal megakelvin), for a
    /// directional mismatch. Deliberately large so only a pronounced cast counts.
    static let minimumMiredDifference: Double = 100
    /// How long a neutral estimate stays usable after the poll read it. A stale
    /// or missing estimate yields no mismatch, so a hint cannot ride an old sample.
    static let maximumSampleAge: TimeInterval = 3
    /// A gap in ticks longer than this is clamped, so a stalled poll cannot credit
    /// a long wall-clock gap to the active clock.
    static let maximumTickGap: TimeInterval = 1
    /// Kelvin bounds outside which an estimate is treated as unusable.
    static let plausibleKelvin: ClosedRange<Double> = 1500...20000
    /// How long the one-shot outline stays on screen.
    static let cueDuration: TimeInterval = 3

    /// Reciprocal megakelvin of a Kelvin temperature, or nil if unusable.
    static func mired(_ kelvin: Double) -> Double? {
        guard kelvin.isFinite, kelvin > 0 else { return nil }
        return 1_000_000 / kelvin
    }

    /// Whether a Gray-World gain triple can be trusted. Gains are normalised so the
    /// smallest channel is 1.0; anything non-finite, below 1, or above the device
    /// maximum (or a non-positive/implausible maximum) is unusable.
    static func gainsAreUsable(red: Double, green: Double, blue: Double, maximumGain: Double) -> Bool {
        guard maximumGain.isFinite, maximumGain >= 1 else { return false }
        return [red, green, blue].allSatisfy { $0.isFinite && $0 >= 1 && $0 <= maximumGain }
    }

    /// Classify a scene's neutral estimate against the stock's reference Kelvin.
    ///
    /// Because mired is reciprocal with Kelvin, a *cooler* scene (higher Kelvin)
    /// has a *smaller* mired, so a negative mired difference is `.cool` and a
    /// positive one is `.warm`. Returns nil for a neutral, implausible, or
    /// sub-threshold difference.
    static func mismatch(estimatedKelvin: Double, referenceKelvin: Double) -> StockSelectorHintMismatch? {
        guard plausibleKelvin.contains(estimatedKelvin),
              plausibleKelvin.contains(referenceKelvin),
              let estimated = mired(estimatedKelvin),
              let reference = mired(referenceKelvin) else { return nil }
        let difference = estimated - reference
        if difference <= -minimumMiredDifference { return .cool }
        if difference >= minimumMiredDifference { return .warm }
        return nil
    }

    /// A mismatch only while the estimate is fresh; a stale, in-the-future, or
    /// missing estimate yields nil so the hint cannot fire on an old sample.
    static func freshMismatch(estimatedKelvin: Double, referenceKelvin: Double,
                              ageSeconds: TimeInterval) -> StockSelectorHintMismatch? {
        guard ageSeconds.isFinite, ageSeconds >= 0, ageSeconds <= maximumSampleAge else { return nil }
        return mismatch(estimatedKelvin: estimatedKelvin, referenceKelvin: referenceKelvin)
    }

    /// Active seconds to credit for a tick that arrived `gapSeconds` after the
    /// previous one, given whether the previous tick was active. A tick that
    /// follows a paused tick credits nothing, so a background or blocked gap is
    /// never counted as camera use; a long gap is clamped for the same reason.
    static func creditedElapsed(gapSeconds: TimeInterval, wasActive: Bool) -> TimeInterval {
        guard wasActive, gapSeconds.isFinite, gapSeconds > 0 else { return 0 }
        return min(gapSeconds, maximumTickGap)
    }
}

/// Counts app launches locally so the discoverability hint is offered only on the
/// first three opens. The count is incremented exactly once per process launch by
/// the app-owned model; foreground/background transitions never touch it.
struct StockSelectorHintLaunchTracker {
    /// Namespaced so this preference never collides with another feature. There is
    /// no analytics service and no account: this is a local integer only.
    static let launchCountKey = "camera.stockSelectorHint.launchCount"
    /// The count saturates here so it never grows past a small constant.
    static let saturatedLaunchCount = 4
    /// Opens 1...3 are eligible; open 4 and later never show the hint.
    static let maximumEligibleLaunch = 3

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// The stored launch ordinal (0 before the first recorded launch).
    var recordedLaunchCount: Int { userDefaults.integer(forKey: Self.launchCountKey) }

    /// Record one launch and return its 1-based ordinal, saturating at
    /// `saturatedLaunchCount`. Call once per process, never per view appearance.
    @discardableResult
    func beginLaunch() -> Int {
        let next = min(max(recordedLaunchCount + 1, 1), Self.saturatedLaunchCount)
        userDefaults.set(next, forKey: Self.launchCountKey)
        return next
    }

    /// Whether a launch ordinal may ever show the hint.
    static func isEligible(launch: Int) -> Bool {
        (1...maximumEligibleLaunch).contains(launch)
    }
}

/// Pure per-launch state machine for the hint. Feed it one frame per tick; it
/// returns `true` exactly once, on the tick the cue should appear.
///
/// No repeating pulse: once it fires it never fires again for the launch, and an
/// interrupted cue stays consumed. A background/blocked frame (`isActive == false`)
/// pauses the active clock and clears any sustained mismatch, so a hint can never
/// fire through a gap or on a stale condition.
struct StockSelectorHintEngine {
    /// One tick of input. `elapsed` is active seconds credited by the caller;
    /// `isActive` is true only while the app is active, the camera is ready, and
    /// no take, transition, sheet or fault is blocking.
    struct Frame: Equatable {
        var elapsed: TimeInterval
        var isActive: Bool
        var isSelectorOpened: Bool
        var isEligibleLaunch: Bool
        var mismatch: StockSelectorHintMismatch?
    }

    private(set) var activeSeconds: TimeInterval = 0
    private(set) var didShowCue = false
    private(set) var didOpenSelector = false
    private var sustainedDirection: StockSelectorHintMismatch?
    private var sustainedSeconds: TimeInterval = 0

    /// Advance one tick. Returns true only on the tick the cue should appear.
    mutating func advance(_ frame: Frame) -> Bool {
        guard frame.isEligibleLaunch else { return false }
        if frame.isSelectorOpened { didOpenSelector = true }
        guard !didOpenSelector, !didShowCue else {
            clearSustained()
            return false
        }
        guard frame.isActive, frame.elapsed > 0 else {
            clearSustained()
            return false
        }
        activeSeconds += frame.elapsed

        if let mismatch = frame.mismatch {
            if mismatch == sustainedDirection {
                sustainedSeconds += frame.elapsed
            } else {
                // A new direction restarts the sustained window from this tick.
                sustainedDirection = mismatch
                sustainedSeconds = frame.elapsed
            }
        } else {
            clearSustained()
        }

        guard activeSeconds >= StockSelectorHintPolicy.requiredActiveSeconds,
              let direction = sustainedDirection,
              direction == frame.mismatch,
              sustainedSeconds >= StockSelectorHintPolicy.requiredSustainedSeconds else {
            return false
        }
        didShowCue = true
        return true
    }

    /// A stock or lens change moves the reference the estimate is compared
    /// against, so any sustained mismatch must restart. Accumulated active time is
    /// preserved: the user has still been using the camera.
    mutating func resetMismatch() {
        clearSustained()
    }

    private mutating func clearSustained() {
        sustainedDirection = nil
        sustainedSeconds = 0
    }
}
