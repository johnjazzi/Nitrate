import Foundation

/// Film-edge markings drawn on the launch splash.
///
/// Every field is a stand-in for now: the splash has no capture state to read,
/// so it shows plausible 35 mm edge markings. Replace the values with live
/// state (stock, exposure, frame counter) once the splash is wired to the
/// camera session.
struct SplashEdgeDetails: Equatable {
    /// Top-leading: gauge and perforation pitch.
    var format: String
    /// Top-trailing: capture encoding.
    var capture: String
    /// Bottom-leading: stock and exposure index.
    var stock: String
    /// Bottom-trailing: edge marking.
    var marking: String
    /// Left edge, reading bottom-to-top.
    var edgeCode: String
    /// Right edge, reading top-to-bottom.
    var frameCounter: String

    static let placeholder = SplashEdgeDetails(
        format: "35MM · 4-PERF",
        capture: "APPLE LOG 2",
        stock: "500T · EI 500",
        marking: "SAFETY FILM",
        edgeCode: "NITRATE 500T 031",
        frameCounter: "0042 0043"
    )
}
