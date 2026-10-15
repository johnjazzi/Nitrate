import Foundation

/// Persisted switches for the debug-only controls on the camera screen.
///
/// They exist so the debug affordances can be taken off the screen without a
/// rebuild. The debug sheet is reachable only from the DEBUG button, so the same
/// switches are mirrored in Settings — otherwise turning that button off would
/// strand the menu that turns it back on.
enum DebugControlPreferences {
    static let showsDebugButtonKey = "debug.showsDebugButton"
    static let showsFaultButtonKey = "debug.showsFaultButton"
}
