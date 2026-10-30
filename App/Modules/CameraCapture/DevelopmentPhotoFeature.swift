import Foundation

/// Availability policy for the Photo mode.
///
/// Photo ships in every configuration: the archive that goes to TestFlight
/// carries `com.nitrate.app`, and a local build carries `com.nitrate.app.dev`.
/// The decision is the installation's identity, never the optimisation level —
/// a Release build used to compile the feature out and there is no way back
/// from that at runtime.
///
/// `isDebugBuild` stays in the signature because the callers and tests already
/// pass it; it no longer decides anything.
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

    /// The policy for the running app. Callers that already hold a bundle id can
    /// use `isAvailable`; this is the form the UI reads so no call site has to
    /// restate the identity rule.
    static func isAvailableForCurrentBundle(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        isAvailable(isDebugBuild: currentBuildIsDebug, bundleIdentifier: bundleIdentifier ?? "")
    }

    /// Reported for diagnostics only — the policy does not branch on it.
    static var currentBuildIsDebug: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func isAvailable(isDebugBuild: Bool, bundleIdentifier: String) -> Bool {
        _ = isDebugBuild
        return availableBundleIdentifiers.contains(bundleIdentifier)
    }
}
