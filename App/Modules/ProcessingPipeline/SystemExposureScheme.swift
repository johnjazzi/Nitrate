/// How the system places a capture against the exposure the operator asked for,
/// and where the pipeline puts it back.
///
/// The camera deliberately captures one stop UNDER the operator's chosen
/// exposure and the render lifts that stop back AFTER the emulsion. The frame
/// the film stages see is therefore a stop darker than the picture that is
/// delivered. That buys a stop of highlight ceiling at capture and carries the
/// halation onset up with it — the asymmetric latitude real film has, where
/// overexposure holds detail and underexposure does not.
///
/// The invariant both halves must preserve: **the delivered exposure equals the
/// exposure the operator set**, and push/pull is the only thing that moves it.
/// Photo and video carry the same scheme — nothing here may be applied to one
/// path only, which is what "1 to 1" means.
enum SystemExposureScheme {
    /// Stops the camera captures under the operator's chosen exposure. Negative
    /// because it rides the capture-time exposure target bias.
    ///
    /// Delivered by the device's own exposure graph (the ISO lever), so a manual
    /// ISO pin is respected rather than overwritten, and it is clamped to the
    /// device's bias range where it is installed.
    static let captureStops: Float = -1

    /// Stops the render lifts back, applied to the scene AFTER the emulsion
    /// stages and BEFORE the stock LUT, so halation is measured against the light
    /// the film actually received and the scattered energy is then lifted with
    /// the scene that produced it.
    ///
    /// Equal and opposite to `captureStops`: the delivered exposure is the
    /// operator's, and only push/pull changes it.
    static let developLiftStops: Float = 1

    /// The halation onset is NOT here: it is authored in stops above diffuse
    /// white in `SpatialEffectsStage` (`redOnsetStops` and friends), and the
    /// scheme's own capture stop reaches the mask through
    /// `SpatialEffectsStage.frameWhiteStops` instead of through a threshold. So
    /// tuning the capture placement still moves what the mask measures without
    /// moving the delivered onset, which is the whole point of holding the
    /// capture under and repaying it after the emulsion.

    /// The compensation to INSTALL on the device for an operator-facing value.
    ///
    /// Everything that talks to the camera's exposure graph — the target bias,
    /// the ISO pin, the metering comparison, the rescue threshold — works in this
    /// value. Everything the operator reads or writes works in the value they
    /// chose. Keeping the two named apart is what lets the readout show the
    /// exposure the operator asked for while the sensor is set a stop under it.
    static func installed(_ displayStops: Float) -> Float {
        displayStops + captureStops
    }

    /// The operator-facing value behind a value the device reports. Exactly the
    /// inverse of `installed(_:)`, so a round trip is the identity.
    static func displayed(_ installedStops: Float) -> Float {
        installedStops - captureStops
    }
}
