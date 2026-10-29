import Foundation

/// Development-only availability policy for the experimental Photo mode.
enum DevelopmentPhotoFeature {
    static let developmentBundleIdentifier = "com.nitrate.app.dev"

    static func isAvailable(isDebugBuild: Bool, bundleIdentifier: String) -> Bool {
        isDebugBuild && bundleIdentifier == developmentBundleIdentifier
    }
}
