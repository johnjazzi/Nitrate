import Foundation
import Testing

struct DevelopmentPhotoFeatureTests {
    /// Both registered identities expose Photo in every configuration: the
    /// TestFlight/App Store Release build carries `com.nitrate.app` and a local
    /// build carries `com.nitrate.app.dev`, so optimisation must not decide.
    @Test func registeredIdentitiesExposePhotoInEveryBuildConfiguration() {
        for isDebugBuild in [true, false] {
            #expect(DevelopmentPhotoFeature.isAvailable(
                isDebugBuild: isDebugBuild, bundleIdentifier: "com.nitrate.app"))
            #expect(DevelopmentPhotoFeature.isAvailable(
                isDebugBuild: isDebugBuild, bundleIdentifier: "com.nitrate.app.dev"))
        }
    }

    /// Regression: Release used to compile Photo out and return false for the
    /// production identity. A release build must now expose it.
    @Test func releaseBuildExposesPhotoForTheProductionIdentity() {
        #expect(DevelopmentPhotoFeature.isAvailable(
            isDebugBuild: false, bundleIdentifier: "com.nitrate.app"))
    }

    /// Anything else — an interaction-test host, a fixture, a missing bundle id
    /// — stays unavailable, so the gate still means something.
    @Test func unknownIdentitiesStayUnavailable() {
        for isDebugBuild in [true, false] {
            #expect(!DevelopmentPhotoFeature.isAvailable(
                isDebugBuild: isDebugBuild, bundleIdentifier: "com.nitrate.app.dev.test"))
            #expect(!DevelopmentPhotoFeature.isAvailable(
                isDebugBuild: isDebugBuild,
                bundleIdentifier: "com.nitrate.app.dev.interaction-tests"))
            #expect(!DevelopmentPhotoFeature.isAvailable(
                isDebugBuild: isDebugBuild, bundleIdentifier: ""))
            #expect(!DevelopmentPhotoFeature.isAvailable(
                isDebugBuild: isDebugBuild, bundleIdentifier: "com.example.other"))
        }
    }
}

struct PhotoShutterPresentationTests {
    @Test func detentsStayWithinAndSpanTheActualSupportedBounds() {
        let range = 1.0 / 8000.0...1.0 / 2.0
        let detents = PhotoShutterPresentation.detents(in: range)
        #expect(detents.first == range.lowerBound)
        #expect(detents.last == range.upperBound)
        #expect(detents.allSatisfy { range.contains($0) })
        #expect(detents.contains(1.0 / 8000.0))
        #expect(detents.contains(1.0 / 2.0))
    }

    /// Old-camera dial numbers: the tick and readout show the denominator only,
    /// so 1/125 s reads "125". Fractions are spoken, not printed.
    @Test func durationsPrintDenominatorOnlyLikeAnOldCameraDial() {
        #expect(PhotoShutterPresentation.label(for: 2.0) == "2″")
        #expect(PhotoShutterPresentation.label(for: 0.5) == "2")
        #expect(PhotoShutterPresentation.label(for: 1.0 / 125.0) == "125")
        #expect(PhotoShutterPresentation.label(for: 1.0 / 8000.0) == "8000")
    }

    /// Accessibility keeps the full photographic reading even though the face
    /// prints only the denominator.
    @Test func spokenLabelsKeepSecondsAndReciprocals() {
        #expect(PhotoShutterPresentation.spokenLabel(for: 2.0) == "2 seconds")
        #expect(PhotoShutterPresentation.spokenLabel(for: 1.0) == "1 second")
        #expect(PhotoShutterPresentation.spokenLabel(for: 0.5) == "1/2 second")
        #expect(PhotoShutterPresentation.spokenLabel(for: 1.0 / 125.0) == "1/125 second")
    }
}
