import Foundation
import Testing

@Suite struct SettingsDisclosureTests {
    @Test func pricingPlacesBillingPeriodBelowTheAmount() throws {
        let source = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/Purchase/PurchaseView.swift"), encoding: .utf8)
        #expect(source.contains(#"billing: "per year""#))
        #expect(source.contains(#"billing: "one time""#))
        #expect(source.contains("private func priceAmount"))
        #expect(source.contains("Text(billing)"))
    }

    @Test func lcdUsesTheNeutralExposureSurfaceAndSelectorsAreCompact() throws {
        let source = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/RecordingTimeLCD.swift"), encoding: .utf8)
        // The readout owns no plate at all: its quiet 12pt line survives and the
        // well belongs to the bar's shared backing, shared by both finishes.
        #expect(!source.contains("CameraInsetSurface"),
                "the LCD draws no recessed plate of its own")
        #expect(!source.contains("cameraWellBacking"),
                "the well is the bar's, applied once around this face")
        #expect(source.contains("static let minimalReadoutSize: CGFloat = 12"),
                "the quiet 12pt readout survives")
        #expect(source.contains(".font(NitrateTypography.font(size: Self.minimalReadoutSize))"))
        #expect(!source.contains("Color(red: 0.055, green: 0.14, blue: 0.105)"))
        // One well, on the bar, and no accent plate in its place.
        let bar = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraControlBar.swift"), encoding: .utf8)
        #expect(bar.components(separatedBy: ".cameraWellBacking(cornerRadius: 10)").count - 1 == 1,
                "the queue face is seated in exactly one shared well")
        #expect(!bar.contains("CameraInsetSurface"),
                "no accent plate replaces the shared well")
        #expect(CameraControlGeometry.leftWidth == 84)
        #expect(CameraControlGeometry.exposureWidth == 84)
    }

    @Test func settingsEndsWithCollapsedPricingAndLegalSections() throws {
        let source = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/Purchase/PurchaseView.swift"), encoding: .utf8)
        #expect(source.contains("@State private var pricingExpanded = false"))
        #expect(source.contains("@State private var legalExpanded = false"))
        let body = try #require(source.range(of: "var body: some View"))
        let end = try #require(source.range(of: "// MARK: - Subviews"))
        let layout = String(source[body.lowerBound..<end.lowerBound])
        let camera = try #require(layout.range(of: "previewModeSection")?.lowerBound)
        let about = try #require(layout.range(of: "appInfoSection")?.lowerBound)
        let pricing = try #require(layout.range(of: "pricingDisclosure")?.lowerBound)
        let legal = try #require(layout.range(of: "legalDisclosure")?.lowerBound)
        #expect(camera < about && about < pricing && pricing < legal)
        #expect(source.contains("DisclosureGroup(\"Pricing\""))
        #expect(source.contains("DisclosureGroup(\"Legal & Support\""))
        #expect(source.contains("purchaseOptionsSection"))
        #expect(source.contains("launchPricingPreview(preview)"))
        #expect(source.contains("legalLinksSection"))
    }
}
