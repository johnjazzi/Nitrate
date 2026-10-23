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
        #expect(source.contains("CameraInsetSurface"))
        #expect(!source.contains("Color(red: 0.055, green: 0.14, blue: 0.105)"))
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
