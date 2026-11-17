import Foundation

/// The measured exposure meter's second indicator: where the delivered frame
/// will sit once the stock's development stops are applied.
///
/// The meter's solid pointer is the scene as it meters now. The development's
/// push or pull moves only the render, so the second index sits the stops away
/// from that pointer on the same EV scale, in the processing colour of its
/// direction. It is nil while the development is neutral (there is no second
/// value) or before the meter reports (the position would be invented).
struct ExposureRenderMarker: Equatable, Sendable {
    /// What the meter reads now, in EV.
    let meteredEV: Float
    /// Where the render lands: the meter shifted by the stops.
    let renderedEV: Float
    /// The development stops that separate the two.
    let stops: PushPullStops

    init?(pushPull: PushPullExposure?, meteredEV: Float?) {
        guard let pushPull, !pushPull.isNeutral,
              let meteredEV, meteredEV.isFinite else { return nil }
        self.meteredEV = meteredEV
        // Positive stops push the render brighter; a pull is a negative stop.
        self.renderedEV = meteredEV + Float(pushPull.stops.stops)
        self.stops = pushPull.stops
    }

    /// The signed stop count, in the same form the stock sheet's ladder uses.
    var text: String { stops.displayName }

    /// VoiceOver states the shift and its direction, so the second index is
    /// never a bare mark next to the pointer.
    var spokenDescription: String {
        let amount = abs(stops.stops)
        let plural = amount == 1 ? "stop" : "stops"
        let action = stops.isPull ? "pulling" : "pushing"
        return "render \(Self.ev(renderedEV)) EV after \(action) \(amount) \(plural)"
    }

    /// POSIX punctuation keeps the reading identical wherever the phone is set.
    private static func ev(_ value: Float) -> String {
        String(format: "%+.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }
}
