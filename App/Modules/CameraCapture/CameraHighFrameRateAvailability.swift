import Foundation

/// The build-configuration switch that owns the manual 120 fps capture mode.
///
/// The mode ships or does not ship per build configuration. `project.yml` holds
/// `NITRATE_ENABLE_120_FPS` in every configuration and mirrors it into the
/// generated `Info.plist` as `Nitrate120FPSEnabled`; this type is the only place
/// that reads the result, and the policy, the session and the menu all ask it.
/// It is deliberately not a preference: no `UserDefaults`, no launch override.
enum HighFrameRateFeature {
    /// The generated Info.plist key the build setting is substituted into.
    static let infoPlistKey = "Nitrate120FPSEnabled"
    /// The XcodeGen/Xcode build setting that feeds that key.
    static let buildSettingName = "NITRATE_ENABLE_120_FPS"
    /// The one rate this switch owns. 24 and 60 are never gated.
    static let gatedFPS = 120
    /// Identities that actually ship the app. A fixture, a test host or an empty
    /// identity never sees the mode, even in a build that enabled it.
    static let shippedBundleIdentifiers: Set<String> = ["com.nitrate.app", "com.nitrate.app.dev"]

    /// Whether an Info.plist value enables the mode.
    ///
    /// Only explicit affirmative values count. Absent, empty, `NO`, `0`, a
    /// non-boolean type, and an unexpanded `$(NITRATE_ENABLE_120_FPS)` all keep
    /// the mode off, so a build that never substituted the setting fails closed.
    static func isEnabled(configuredValue: Any?) -> Bool {
        switch configuredValue {
        case let flag as Bool:
            return flag
        case let text as String:
            return ["YES", "TRUE", "1"].contains(
                text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        default:
            return false
        }
    }

    /// Whether this configuration and this identity together may offer the mode.
    /// Both gates must pass: a build that enabled it still hides it from a
    /// fixture, a test host or an empty bundle identity.
    static func isAvailable(enabled: Bool, bundleIdentifier: String?) -> Bool {
        enabled && shippedBundleIdentifiers.contains(bundleIdentifier ?? "")
    }

    /// The switch as read from one bundle's Info.plist.
    static func isEnabled(in bundle: Bundle) -> Bool {
        isEnabled(configuredValue: bundle.object(forInfoDictionaryKey: infoPlistKey))
    }

    /// The switch for this build, read once per call from the app's plist.
    static func isAvailableInThisBuild(bundle: Bundle = .main) -> Bool {
        isAvailable(enabled: isEnabled(in: bundle), bundleIdentifier: bundle.bundleIdentifier)
    }

    /// One predicate: may this rate exist in this build at all?
    static func allows(fps: Int, available: Bool) -> Bool {
        fps != gatedFPS || available
    }
}
