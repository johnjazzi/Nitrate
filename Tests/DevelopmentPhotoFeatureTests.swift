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

    @Test func durationsUsePhotographicSecondsAndReciprocals() {
        #expect(PhotoShutterPresentation.label(for: 2.0) == "2″")
        #expect(PhotoShutterPresentation.label(for: 0.5) == "1/2")
        #expect(PhotoShutterPresentation.label(for: 1.0 / 125.0) == "1/125")
    }
}
