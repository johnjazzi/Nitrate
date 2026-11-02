import Foundation
import simd

/// Render-time push/pull in fixed stops.
///
/// Negative stops pull the development (darker), positive stops push it
/// (brighter). The ladder is deliberately short and fixed rather than
/// continuous: the operator is choosing a development convention for the stock,
/// the same way a lab pushes or pulls a roll, and every step must be
/// reproducible from the queue's persisted value alone.
///
/// The value is *not* a capture exposure change — the take is already recorded.
/// It is applied to the Apple Log 2 code the decoder hands the colour pipeline,
/// before the stock's cube, so the cube still sees a correctly encoded frame.
enum PushPullStops: Int, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case pullTwo = -2
    case pullOne = -1
    case none = 0
    case pushOne = 1
    case pushTwo = 2

    var id: Int { rawValue }

    var stops: Int { rawValue }

    /// Picker/metadata label: a pull reads "-2", a push reads "+1".
    var displayName: String { rawValue > 0 ? "+\(rawValue)" : "\(rawValue)" }

    var isPull: Bool { rawValue < 0 }

    /// Scene-light multiplier this stop count represents.
    var linearGain: Double { pow(2, Double(rawValue)) }

    /// Past-tense word used in prose and diagnostics ("pulled 2 stops").
    var effectName: String { rawValue == 0 ? "normal" : (isPull ? "pulled" : "pushed") }

    /// Nearest rung for a persisted integer. A queue written by a future build
    /// with a wider ladder must not make every job unreadable.
    static func nearest(to stops: Int) -> PushPullStops {
        allCases.min { abs($0.rawValue - stops) < abs($1.rawValue - stops) } ?? .none
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = PushPullStops.nearest(to: raw)
    }
}

// MARK: - Automatic selection

/// Automatic selection rule: when the meter reads at least one full stop over
/// the operator's target, the render is pulled by that many stops.
///
/// The rule only ever pulls. A scene metered *under* the target is the
/// operator's own exposure decision and a push cannot recover it, so auto stays
/// neutral there rather than silently brightening a deliberately dark frame.
/// The operator can always switch auto off and choose by hand.
enum PushPullAutoPolicy {
    /// First threshold: +1 EV over target selects a one-stop pull.
    static let firstTriggerEV: Float = 1
    /// Second threshold: +2 EV over target selects a two-stop pull.
    static let secondTriggerEV: Float = 2

    static func isTriggered(meteredOffsetEV: Float?) -> Bool {
        stops(forMeteredOffsetEV: meteredOffsetEV) != .none
    }

    static func stops(forMeteredOffsetEV offset: Float?) -> PushPullStops {
        guard let offset, offset.isFinite else { return .none }
        if offset >= secondTriggerEV { return .pullTwo }
        if offset >= firstTriggerEV { return .pullOne }
        return .none
    }
}

// MARK: - Setting carried by a render

/// A resolved push/pull plus how it was chosen, so metadata can say the take
/// was pulled *and* whether the operator or the meter asked for it.
struct PushPullExposure: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Equatable, Sendable {
        case manual
        case automatic
    }

    var stops: PushPullStops
    var origin: Origin
    /// Metered offset in EV (positive = over the operator's target) that the
    /// automatic rule saw. Nil for a manual choice or a legacy render.
    var meteredOffsetEV: Float?

    static let neutral = PushPullExposure(stops: .none, origin: .manual, meteredOffsetEV: nil)

    static func manual(_ stops: PushPullStops) -> PushPullExposure {
        PushPullExposure(stops: stops, origin: .manual, meteredOffsetEV: nil)
    }

    /// Resolve the automatic rule against a live meter reading. A missing or
    /// non-finite reading resolves neutral: an automatic pull is never applied
    /// on a guess.
    static func automatic(meteredOffsetEV: Float?) -> PushPullExposure {
        let reading = meteredOffsetEV.flatMap { $0.isFinite ? $0 : nil }
        return PushPullExposure(stops: PushPullAutoPolicy.stops(forMeteredOffsetEV: reading),
                                origin: .automatic, meteredOffsetEV: reading)
    }

    var isNeutral: Bool { stops == .none }

    /// "auto: pulled 2 stops (meter +2.1 EV over target)" / "pulled 1 stop".
    var summary: String {
        let amount = abs(stops.stops)
        let plural = amount == 1 ? "stop" : "stops"
        guard !isNeutral else {
            return origin == .automatic ? "auto: normal (no pull)" : "normal"
        }
        let core = "\(stops.effectName) \(amount) \(plural)"
        guard origin == .automatic, let meteredOffsetEV else { return core }
        return "auto: \(core) (meter \(String(format: "%+.1f", meteredOffsetEV)) EV over target)"
    }
}

// MARK: - Transfer maths

/// The operator's *preference* for the stock sheet: whether auto is checked and
/// what manual rung is dialled. Persisted per stock as one short string so the
/// sheet opens showing what was last chosen ("auto" / "manual:+1").
struct PushPullPreference: Equatable, Sendable {
    var isAutomatic: Bool
    var manualStops: PushPullStops

    /// Auto on, neutral manual fallback: the state a stock starts in.
    static let standard = PushPullPreference(isAutomatic: true, manualStops: .none)

    /// Resolve against the live meter. With auto off the manual rung wins and
    /// no metered offset is claimed.
    func resolved(meteredOffsetEV: Float?) -> PushPullExposure {
        isAutomatic ? .automatic(meteredOffsetEV: meteredOffsetEV) : .manual(manualStops)
    }

    var encoded: String { isAutomatic ? "auto" : "manual:\(manualStops.displayName)" }

    /// Decode a persisted preference. Anything unrecognized falls back to the
    /// standard state rather than failing the sheet.
    static func decode(_ text: String?) -> PushPullPreference {
        guard let text, text.hasPrefix("manual:") else { return .standard }
        let digits = text.dropFirst("manual:".count).replacingOccurrences(of: "+", with: "")
        guard let raw = Int(digits) else { return .standard }
        return PushPullPreference(isAutomatic: false, manualStops: .nearest(to: raw))
    }
}

/// Apple Log 2 code ↔ scene linear, and the push/pull gain between them.
///
/// DOMAIN: a push/pull is a scene-light change, so the gain is applied in the
/// *linear* domain — decode the log code, multiply by 2^stops, re-encode. The
/// tempting shortcut (multiply the log code by 2^stops) is not a stop: log
/// codes are not proportional to scene light, so ±2 code units is a different
/// exposure at the toe and shoulder than in the midtones, and it would shift
/// the whole curve rather than expose it.
///
/// The curve is the OCIO v2.6 Apple Log/Log 2 transfer function
/// (`AppleCameras.cpp`) — the same constants the LUT generator, `RAWToLog2Stage`
/// and `PhotoColorMath` use, so a pushed or pulled frame stays in the exact
/// encoding the cubes were authored for. Unlike `PhotoColorMath` this variant
/// is *unclamped at black*: Apple Log 2 places linear 0 at code 0.1505, and
/// clamping the decoded value at 0 would re-encode every dark pixel to 0.1505
/// on a pull — a black lift on exactly the frames the negative ladder exists
/// for.
///
/// Headroom, measured from the shipped cubes: the peak LUT output is 0.976
/// (249/255) and never clips; +3.1 stops over 18% grey reaches 0.9 and +4.2
/// stops reaches 0.95. So a -1 or -2 stop pull has real highlight information
/// to recover and cannot crush true whites, and no extra highlight protection
/// is layered on top of the cube.
enum PushPullTransfer {
    // OCIO AppleCameras.cpp Apple Log 2 constants.
    static let blackOffset: Double = -0.05641088
    static let linearKnee: Double = 0.01
    static let scale: Double = 47.28711236
    static let beta: Double = 0.00964052
    static let gamma: Double = 0.08550479
    static let delta: Double = 0.69336945
    /// Code where the two curve segments meet: scale * (knee - offset)^2.
    static let codeKnee: Double = scale * (linearKnee - blackOffset) * (linearKnee - blackOffset)

    /// Apple Log 2 code → scene linear, signed and unclamped at black.
    static func decode(_ code: Double) -> Double {
        guard code.isFinite else { return 0 }
        if code >= codeKnee { return pow(2, (code - delta) / gamma) - beta }
        if code >= 0 { return (code / scale).squareRoot() + blackOffset }
        return blackOffset
    }

    /// Scene linear → Apple Log 2 code. Values below the curve's black offset
    /// clamp to code 0.
    static func encode(_ linear: Double) -> Double {
        guard linear.isFinite else { return 0 }
        let value = max(linear, blackOffset)
        if value < linearKnee {
            let shifted = value - blackOffset
            return scale * shifted * shifted
        }
        return delta + gamma * log2(value + beta)
    }

    /// One Apple Log 2 code value exposed by `stops`. Exactly the input for a
    /// neutral setting so a zero-stop render is bit-identical to no push/pull.
    ///
    /// Apple Log 2 is a *signed* log curve: codes below 0.1505 carry negative
    /// scene values, and scaling a negative linear value towards zero would
    /// pull them *up* the curve. Those codes hold no scene light to recover, so
    /// the result is clamped to never move against the requested direction.
    static func gained(code: Double, stops: PushPullStops) -> Double {
        guard code.isFinite else { return code }
        guard stops != .none else { return code }
        let exposed = encode(decode(code) * stops.linearGain)
        return stops.isPull ? min(exposed, code) : max(exposed, code)
    }

    static func gained(code: Float, stops: PushPullStops) -> Float {
        Float(gained(code: Double(code), stops: stops))
    }

    static func gained(rgb: SIMD3<Double>, stops: PushPullStops) -> SIMD3<Double> {
        guard stops != .none else { return rgb }
        return SIMD3(gained(code: rgb.x, stops: stops),
                     gained(code: rgb.y, stops: stops),
                     gained(code: rgb.z, stops: stops))
    }

    /// Scene-linear multiplier the render applies, exposed so a diagnostic can
    /// state the gain without re-deriving the ladder.
    static func linearGain(for stops: PushPullStops) -> Double { stops.linearGain }
}
