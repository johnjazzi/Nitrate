import Foundation
import Testing

/// The splash shows the version on its bottom edge, so the formatting is part of
/// the user-visible surface even though the strings themselves come from
/// MARKETING_VERSION in project.yml and the bundle's CFBundleVersion.
struct AppVersionTests {
    @Test func displayIncludesBuildAndStage() {
        #expect(AppVersion.display(marketing: "0.1.0", build: "1", stage: .alpha) == "0.1.0 (1) · ALPHA")
    }

    @Test func displayOmitsStageWhenReleased() {
        #expect(AppVersion.display(marketing: "1.2.3", build: "45", stage: nil) == "1.2.3 (45)")
    }

    @Test func bundleVersionResolvesToNonEmptyStrings() {
        #expect(!AppVersion.marketing().isEmpty)
        #expect(!AppVersion.build().isEmpty)
    }

    @Test func currentVersionUsesTheSharedDisplayFormat() {
        let text = AppVersion.current()
        #expect(text.hasPrefix("\(AppVersion.marketing()) (\(AppVersion.build()))"))
    }

    /// No build shows a stage suffix. A visible BETA marker made the App Store
    /// submission look like a beta (guideline 2.2), so the shipped value is nil.
    @Test func noBuildShowsAStageSuffix() {
        #expect(AppVersion.stage == nil)
        #expect(!AppVersion.current().uppercased().contains("BETA"))
        #expect(!AppVersion.current().hasSuffix("· BETA"))
    }

    @Test func currentVersionAppliesTheCurrentStage() {
        #expect(AppVersion.current() == AppVersion.display(marketing: AppVersion.marketing(),
                                                          build: AppVersion.build(),
                                                          stage: AppVersion.stage))
    }

    @Test func splashAndAboutShareOneVersionString() {
        #expect(AboutPresentation.versionLine() == AboutPresentation.versionPrefix + AppVersion.current())
    }

    @Test func placeholderEdgeDetailsArePopulated() {
        let details = SplashEdgeDetails.placeholder
        let fields = [
            details.format, details.capture, details.stock,
            details.marking, details.edgeCode, details.frameCounter
        ]
        #expect(fields.allSatisfy { !$0.isEmpty })
    }

    @Test func identityNameMatchesTheBundleDisplayName() {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        #expect(displayName == nil || displayName == AppIdentity.name)
    }
}
