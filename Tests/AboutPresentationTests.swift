import Foundation
import Testing

/// Settings → About listed only descriptive copy, so the running version and
/// build number were nowhere in the app after the splash went away. The row is
/// required to read the same bundle-derived string as the splash's bottom edge.
struct AboutPresentationTests {
    @Test func versionLineNamesBothVersionAndBuild() {
        #expect(AboutPresentation.versionLine(version: "0.1.3 (3) · ALPHA") == "Version 0.1.3 (3) · ALPHA")
    }

    @Test func versionLineReadsTheBundleMarketingVersion() {
        #expect(AboutPresentation.versionLine().contains(AppVersion.marketing()))
    }

    @Test func versionLineReadsTheBundleBuildNumber() {
        #expect(AboutPresentation.versionLine().contains("(\(AppVersion.build()))"))
    }

    @Test func versionLineMatchesTheSplashString() {
        #expect(AboutPresentation.versionLine() == AboutPresentation.versionPrefix + AppVersion.current())
    }

    /// Stable hook for the UI test that reaches the row inside the settings sheet.
    @Test func versionRowHasAStableIdentifier() {
        #expect(AboutPresentation.versionRowID == "settings.about.version")
    }
}
