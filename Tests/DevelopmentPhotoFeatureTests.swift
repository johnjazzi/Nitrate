import Foundation
import Testing

struct DevelopmentPhotoFeatureTests {
    @Test func onlyDebugDevelopmentBundleCanExposePhoto() {
        #expect(DevelopmentPhotoFeature.isAvailable(
            isDebugBuild: true, bundleIdentifier: "com.nitrate.app.dev"))
        #expect(!DevelopmentPhotoFeature.isAvailable(
            isDebugBuild: false, bundleIdentifier: "com.nitrate.app.dev"))
        #expect(!DevelopmentPhotoFeature.isAvailable(
            isDebugBuild: true, bundleIdentifier: "com.nitrate.app"))
        #expect(!DevelopmentPhotoFeature.isAvailable(
            isDebugBuild: true, bundleIdentifier: "com.nitrate.app.dev.test"))
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
