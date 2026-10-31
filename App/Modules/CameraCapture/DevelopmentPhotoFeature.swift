import Foundation

/// Availability policy for the Photo mode.
///
/// Two things decide whether the running app offers Photo, and neither is the
/// optimisation level — a Release build used to compile the feature out, and
/// there is no way back from that at runtime:
///
/// 1. `PHOTO_MODE_ENABLED` in `project.yml`, per configuration, copied into
///    Info.plist as `PhotoModeEnabled`. Turning Photo off for a build — a
///    TestFlight build, say — is a configuration edit plus a rebuild.
/// 2. The installation's identity: the two bundle ids this product ships under.
///    Everything else (interaction-test host, fixture harness, empty bundle id)
///    stays unavailable even when the switch is on.
///
/// `isDebugBuild` stays in the signature because callers and tests pass it; it
/// no longer decides anything.
enum DevelopmentPhotoFeature {
    /// Matches `PRODUCT_BUNDLE_IDENTIFIER` for the Release configuration in
    /// `project.yml`, which must equal the App Store Connect record.
    static let productionBundleIdentifier = "com.nitrate.app"
    /// Matches the Debug and DevRelease configurations.
    static let developmentBundleIdentifier = "com.nitrate.app.dev"

    /// Identities this product ships under. Anything else — the interaction-test
    /// host, a preview harness, an empty bundle id — stays unavailable.
    static let availableBundleIdentifiers: Set<String> = [
        productionBundleIdentifier,
        developmentBundleIdentifier
    ]

    /// The Info.plist key that mirrors the `PHOTO_MODE_ENABLED` build setting.
    static let infoPlistKey = "PhotoModeEnabled"

    /// Parse the contract's value. Xcode writes `YES`/`NO` for a string setting;
    /// an unexpanded `$(PHOTO_MODE_ENABLED)` means the setting is missing, and a
    /// misconfiguration must not switch the feature on.
    static func isEnabled(configuredValue: Any?) -> Bool {
        switch configuredValue {
        case let flag as Bool:
            return flag
        case let text as String:
            return ["YES", "TRUE", "1"].contains(text.uppercased())
        default:
            return false
        }
    }

    /// The switch for the running app, read once from the built Info.plist.
    static var isEnabledByConfiguration: Bool {
        isEnabled(configuredValue: Bundle.main.object(forInfoDictionaryKey: infoPlistKey))
    }

    /// The policy for the running app. Callers that already hold a bundle id can
    /// use `isAvailable`; this is the form the UI reads so no call site has to
    /// restate the identity rule or the switch.
    static func isAvailableForCurrentBundle(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        enabled: Bool = isEnabledByConfiguration
    ) -> Bool {
        isAvailable(isDebugBuild: currentBuildIsDebug,
                    bundleIdentifier: bundleIdentifier ?? "",
                    enabled: enabled)
    }

    /// Reported for diagnostics only — the policy does not branch on it.
    static var currentBuildIsDebug: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    /// Both gates: the configuration's switch and a shipped identity.
    static func isAvailable(isDebugBuild: Bool, bundleIdentifier: String, enabled: Bool) -> Bool {
        _ = isDebugBuild
        return enabled && availableBundleIdentifiers.contains(bundleIdentifier)
    }
}
