import Foundation

/// Settings → About. The version row reads the same bundle-derived string as the
/// splash's bottom edge, so the two can never disagree about which build is
/// running; nothing here is hardcoded or shipped in a constant.
enum AboutPresentation {
    static let versionPrefix = "Version "
    static let versionRowID = "settings.about.version"

    /// `Version 0.1.3 (3) · ALPHA`
    static func versionLine(version: String = AppVersion.current()) -> String {
        versionPrefix + version
    }
}
