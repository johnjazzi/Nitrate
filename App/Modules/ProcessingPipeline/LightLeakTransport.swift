import CoreMedia
import Foundation
import simd

/// The film running before and after the take, and the ramp that gets between
/// them.
///
/// The render used to hand the emulsion a perfect camera: already at nominal
/// speed on its first frame, stopped the instant after its last. A real body
/// does neither. The transport is already rolling when the take starts — the
/// exposed head is preceded by frames the gate was never open on — and the film
/// is still crawling as it comes up to speed, so the first frames of a take are
/// over-exposed and ramp down into the picture. The tail mirrors it: the burn
/// grows again and the take is followed by frames with nothing on them.
///
/// That is the whole model, and it is counted in FRAMES, because a mechanical
/// transport does not know about seconds: `leaderFrames` unexposed frames in
/// front, `burnFrames` over-exposed frames ramping down from `peakStops` to
/// nothing, then the take — and on the way out, `tailBurnFrames` ramping back up
/// into `trailerFrames` unexposed frames.
///
/// Exposure goes as the reciprocal of the film's speed, which is why a burnt
/// head frame is an EXPOSURE and not just a fog: the scene is multiplied by
/// `2^stops` at the same time as the gate leaks its warm veil onto it. The ramp
/// is linear in stops across the burn frames, so "five frames" means five frames.
///
/// What a render applies comes from the Settings switch, except under RenderCLI,
/// where the environment knobs (see `fromEnvironment`) let the same take be
/// rendered with the ramp on and off without a Settings screen to click.
struct LightLeakTransport: Equatable, Sendable {
    /// Unexposed frames in front of the take.
    var leaderFrames: Int
    /// Frames at the start of the take that the transport over-exposes, the
    /// first of them the most. Ramping down across these lands on normal.
    var burnFrames: Int
    /// Unexposed frames after the take.
    var trailerFrames: Int
    /// Frames at the end of the take whose burn ramps up into the trailer.
    var tailBurnFrames: Int
    /// The over-exposure on the first ramping frame, in stops. 0 disables the
    /// whole effect.
    var peakStops: Float
    /// The leak's colour. Stray light arrives through the film base and the gap
    /// at the gate, so it is warm — never neutral.
    var tint: SIMD3<Float>
    /// 0 fogs the whole frame evenly, 1 weights the leak entirely toward the
    /// frame's edges. A gate leak is uneven in practice; the burn of a crawling
    /// first frame is not.
    var edgeShare: Float
    /// How far in the edge weighting reaches, as a fraction of the shorter side.
    var edgeFalloff: Float
    /// How much of the take's FIRST frame was still crossing the gate while it
    /// was exposed, as a fraction of the frame.
    ///
    /// The transport is stopped between takes with the film mid-frame, so the
    /// frame that opens a take is the one straddling the aperture: its lower part
    /// is what the gate was already looking at while the transport was at rest
    /// (and it is therefore the most burned thing in the take), while its upper
    /// part has not yet been drawn into the aperture at all and never sees light.
    /// Later frames are wholly in register by the time they are exposed — the
    /// second frame is only slightly short — so this is the one frame with a foot
    /// in both worlds. 0 disables the partial frame and leaves the head as a
    /// uniformly burned frame.
    var firstFrameSlip: Float = 0.55
    /// Whether the delivered clip opens with a frame of the take at the exposure
    /// the camera metered it at, ahead of the black film.
    ///
    /// Nothing about the mechanism makes this frame: the film in front of a take
    /// is unexposed, and that is what the leader is for. It is here because a clip
    /// that opens on black film cannot be told from any other clip that opens on
    /// black film — not in Photos, not in a preview grid, not in a thumbnail —
    /// and a take nobody can identify is worse than a take that is one frame less
    /// pure. Only meaningful while the ramp is on.
    var opensWithNominalFrame: Bool = true

    static let off = LightLeakTransport(leaderFrames: 0, burnFrames: 0, trailerFrames: 0,
                                        tailBurnFrames: 0, peakStops: 0,
                                        tint: SIMD3<Float>(1, 1, 1), edgeShare: 0, edgeFalloff: 0)

    /// The ramp at full strength: three frames of film either side of the take,
    /// eight frames of burn at each end, the head starting two and a half stops
    /// over. Eight is a third of a second at 24 fps — long enough to read as the
    /// transport gathering speed rather than a flash frame. This is what the
    /// Settings switch turns on, and the baseline the environment knobs modify.
    static let standard = LightLeakTransport(leaderFrames: 3, burnFrames: 8, trailerFrames: 3,
                                             tailBurnFrames: 8, peakStops: 2.5,
                                             tint: SIMD3<Float>(1.0, 0.62, 0.34),
                                             edgeShare: 0.6, edgeFalloff: 0.45)

    var leaderCount: Int { max(leaderFrames, 0) }
    var trailerCount: Int { max(trailerFrames, 0) }

    /// True when the render has anything to do: a frame to add, or light to add.
    var isActive: Bool { leaderCount > 0 || trailerCount > 0 || peakStops > 0 }

    /// The burn this frame carries, and how it is shaped, for the frame at
    /// `index` of a take `count` frames long.
    func frame(atFrame index: Int, ofFrameCount count: Int) -> LightLeakFrame {
        let stops = stops(atFrame: index, ofFrameCount: count)
        let slip = slip(atFrame: index)
        guard stops > 0 || slip > 0 else { return .none }
        return LightLeakFrame(stops: stops, tint: tint, edgeShare: edgeShare,
                              edgeFalloff: edgeFalloff, slip: slip)
    }

    /// How much of this frame the gate never saw. Only the take's opening frame
    /// is properly short, and the one after it a little; by the third the film is
    /// in register and stays there.
    func slip(atFrame index: Int) -> Float {
        guard peakStops > 0, index >= 0 else { return 0 }
        if index == 0 { return min(max(firstFrameSlip, 0), 1) }
        if index == 1 { return min(max(firstFrameSlip, 0), 1) * 0.3 }
        return 0
    }

    /// Stops of over-exposure for one frame of the take. Linear in stops across
    /// the burn frames: the first frame is `peakStops` over, and the frame after
    /// the last burn frame is the take as the camera metered it.
    func stops(atFrame index: Int, ofFrameCount count: Int) -> Float {
        guard peakStops > 0, index >= 0 else { return 0 }
        let burns = max(burnFrames, 0)
        if burns > 0, index < burns {
            return peakStops * (1 - Float(index) / Float(burns))
        }
        let tailBurns = max(tailBurnFrames, 0)
        let fromEnd = count - 1 - index
        if tailBurns > 0, fromEnd >= 0, fromEnd < tailBurns {
            return peakStops * (1 - Float(fromEnd) / Float(tailBurns))
        }
        return 0
    }
}

/// One frame's share of the burn, in the shape the GPU stages take it.
struct LightLeakFrame: Equatable, Sendable {
    var stops: Float = 0
    var tint: SIMD3<Float> = SIMD3<Float>(1.0, 0.62, 0.34)
    var edgeShare: Float = 0
    var edgeFalloff: Float = 0
    /// The share of the frame that never crossed the gate during this frame's
    /// exposure. The frame is exposed where the film had reached the aperture and
    /// black where it had not, so an unexposed band is a partial frame rather than
    /// a dim one.
    var slip: Float = 0

    /// No burn: a frame the transport was already at speed for, and every still.
    static let none = LightLeakFrame()

    var isActive: Bool { stops > 0 || slip > 0 }
}

/// The persisted shape of the transport ramp, and what the Settings switch sets.
///
/// The ramp is a flourish of the mechanism rather than a property of a stock —
/// it is the same whatever emulsion is loaded — and it adds frames a take did not
/// have, so it is off by default and turned on in Settings.
enum TransportRampSettings {
    static let isEnabledKey = "processing.transportRamp"
    static let lengthKey = "processing.transportRampLength"

    /// How long the burn takes to clear, and how much film runs either side of
    /// the take. In frames, because that is what a transport counts in.
    enum Length: String, CaseIterable {
        case short
        case standard
        case long

        var title: String {
            switch self {
            case .short: return "Short"
            case .standard: return "Standard"
            case .long: return "Long"
            }
        }

        /// Frames of burn at each end of the take.
        var burnFrames: Int {
            switch self {
            case .short: return 5
            case .standard: return 8
            case .long: return 12
            }
        }

        /// Unexposed frames of film beyond the burn, at each end.
        var filmFrames: Int {
            switch self {
            case .short: return 2
            case .standard: return 3
            case .long: return 4
            }
        }
    }

    static func length(defaults: UserDefaults = .standard) -> Length {
        defaults.string(forKey: lengthKey).flatMap(Length.init(rawValue:)) ?? .standard
    }

    /// The ramp a render should apply, or `.off` when the switch is off.
    static func resolved(defaults: UserDefaults = .standard) -> LightLeakTransport {
        guard defaults.bool(forKey: isEnabledKey) else { return .off }
        let length = length(defaults: defaults)
        var transport = LightLeakTransport.standard
        transport.burnFrames = length.burnFrames
        transport.tailBurnFrames = length.burnFrames
        transport.leaderFrames = length.filmFrames
        transport.trailerFrames = length.filmFrames
        return transport
    }
}

extension LightLeakTransport {
    /// Resolve the ramp one render applies.
    ///
    /// The environment wins where it speaks, because RenderCLI has no Settings
    /// screen and the comparison renders depend on the knobs; when it says
    /// nothing, the persisted switch decides — and that switch is off by default.
    static func resolved(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LightLeakTransport {
        fromEnvironment(environment) ?? TransportRampSettings.resolved(defaults: defaults)
    }

    /// The command-line knobs, read off the environment, so RenderCLI can drive
    /// the ramp without a Settings screen. `nil` when the environment says nothing
    /// about the ramp, which leaves the decision to the persisted switch:
    ///
    /// - `NITRATE_LEAK_OFF=1` — render the take with no ramp at all.
    /// - `NITRATE_LEAK_ON=1` — force the full ramp whatever the switch says.
    /// - `NITRATE_LEAK_LEADER_FRAMES`, `NITRATE_LEAK_BURN_FRAMES`,
    ///   `NITRATE_LEAK_TRAILER_FRAMES`, `NITRATE_LEAK_TAIL_BURN_FRAMES`
    /// - `NITRATE_LEAK_PEAK_STOPS`, `NITRATE_LEAK_EDGE`, `NITRATE_LEAK_SLIP`,
    ///   `NITRATE_LEAK_TINT="r,g,b"`
    ///
    /// Any one of them puts the environment in charge, so a bare
    /// `NITRATE_LEAK_PEAK_STOPS=1.5` still turns the ramp on.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LightLeakTransport? {
        let knobs = ["NITRATE_LEAK_ON", "NITRATE_LEAK_OFF",
                     "NITRATE_LEAK_LEADER_FRAMES", "NITRATE_LEAK_BURN_FRAMES",
                     "NITRATE_LEAK_TRAILER_FRAMES", "NITRATE_LEAK_TAIL_BURN_FRAMES",
                     "NITRATE_LEAK_PEAK_STOPS", "NITRATE_LEAK_EDGE",
                     "NITRATE_LEAK_TINT", "NITRATE_LEAK_SLIP"]
        guard knobs.contains(where: { environment[$0] != nil }) else { return nil }
        guard environment["NITRATE_LEAK_OFF"] == nil else { return .off }
        var transport = LightLeakTransport.standard
        func frames(_ key: String, _ apply: (Int) -> Void) {
            if let value = environment[key], let number = Int(value) { apply(max(number, 0)) }
        }
        frames("NITRATE_LEAK_LEADER_FRAMES") { transport.leaderFrames = $0 }
        frames("NITRATE_LEAK_BURN_FRAMES") { transport.burnFrames = $0 }
        frames("NITRATE_LEAK_TRAILER_FRAMES") { transport.trailerFrames = $0 }
        frames("NITRATE_LEAK_TAIL_BURN_FRAMES") { transport.tailBurnFrames = $0 }
        if let value = environment["NITRATE_LEAK_PEAK_STOPS"], let stops = Float(value) {
            transport.peakStops = stops
        }
        if let value = environment["NITRATE_LEAK_EDGE"], let share = Float(value) {
            transport.edgeShare = min(max(share, 0), 1)
        }
        if let value = environment["NITRATE_LEAK_SLIP"], let slip = Float(value) {
            transport.firstFrameSlip = min(max(slip, 0), 1)
        }
        if let value = environment["NITRATE_LEAK_TINT"] {
            let parts = value.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 3 {
                transport.tint = SIMD3<Float>(parts[0], parts[1], parts[2])
            }
        }
        return transport
    }
}
