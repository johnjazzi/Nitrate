import Foundation
import Testing

/// The default-OFF build switch that owns the manual 120 fps mode, and the
/// wiring contract that keeps `project.yml`, the generated Info.plist, the
/// policy, the session and the menu on that one switch.
struct HighFrameRateFeatureTests {
    // MARK: - Parsing the generated Info.plist value

    @Test func explicitAffirmativeValuesEnableTheMode() {
        #expect(HighFrameRateFeature.isEnabled(configuredValue: true))
        #expect(HighFrameRateFeature.isEnabled(configuredValue: "YES"))
        #expect(HighFrameRateFeature.isEnabled(configuredValue: "yes"))
        #expect(HighFrameRateFeature.isEnabled(configuredValue: " TRUE "))
        #expect(HighFrameRateFeature.isEnabled(configuredValue: "1"))
    }

    @Test func absentEmptyFalseAndUnexpandedValuesKeepTheModeOff() {
        #expect(HighFrameRateFeature.isEnabled(configuredValue: nil) == false)
        #expect(HighFrameRateFeature.isEnabled(configuredValue: "") == false)
        #expect(HighFrameRateFeature.isEnabled(configuredValue: false) == false)
        #expect(HighFrameRateFeature.isEnabled(configuredValue: "NO") == false)
        #expect(HighFrameRateFeature.isEnabled(configuredValue: "no") == false)
        #expect(HighFrameRateFeature.isEnabled(configuredValue: "0") == false)
        // An unsubstituted build setting means the switch never reached the
        // plist. That fails closed instead of enabling the mode.
        #expect(HighFrameRateFeature.isEnabled(configuredValue: "$(NITRATE_ENABLE_120_FPS)") == false)
        // A wrong type is not an affirmative value either.
        #expect(HighFrameRateFeature.isEnabled(configuredValue: 120) == false)
    }

    // MARK: - Configuration × identity

    @Test func onlyShippingIdentitiesSeeTheMode() {
        for identity in HighFrameRateFeature.shippedBundleIdentifiers {
            #expect(HighFrameRateFeature.isAvailable(enabled: true, bundleIdentifier: identity))
            #expect(HighFrameRateFeature.isAvailable(enabled: false, bundleIdentifier: identity) == false)
        }
    }

    @Test func fixturesTestHostsAndEmptyIdentitiesNeverSeeTheMode() {
        let others: [String?] = ["com.nitrate.app.dev.interaction-tests",
                                 "com.nitrate.CameraDesignTests",
                                 "com.nitrate.app.dev.tests", "", nil]
        for identity in others {
            #expect(HighFrameRateFeature.isAvailable(enabled: true, bundleIdentifier: identity) == false)
        }
    }

    // MARK: - One predicate owns one rate

    @Test func theSwitchOwnsOnlyTheOneHundredAndTwentyRate() {
        for fps in [24, 60] {
            #expect(HighFrameRateFeature.allows(fps: fps, available: false))
            #expect(HighFrameRateFeature.allows(fps: fps, available: true))
        }
        #expect(HighFrameRateFeature.allows(fps: 120, available: true))
        #expect(HighFrameRateFeature.allows(fps: 120, available: false) == false)
    }

    // MARK: - Build wiring

    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func everyConfigurationDefaultsTheSwitchOffAndMirrorsItIntoThePlist() throws {
        let yaml = try source("project.yml")
        // The generated Info.plist carries the value, substituted at build time.
        #expect(yaml.contains("Nitrate120FPSEnabled: $(NITRATE_ENABLE_120_FPS)"))
        // The UI-test bundle needs the same substituted key so its worker can
        // skip the production 120 fps tests when the build leaves the gate off.
        #expect(yaml.contains("path: build/generated/CameraInteractionUITests-Info.plist"))
        for configuration in ["Debug", "DevRelease", "Release"] {
            let start = try #require(yaml.range(of: "\n        \(configuration):"),
                                     "\(configuration) must be configured explicitly")
            let block = yaml[start.upperBound...].prefix(500)
            #expect(block.contains("NITRATE_ENABLE_120_FPS: \"NO\""),
                    "\(configuration) must default NITRATE_ENABLE_120_FPS off")
        }
    }

    @Test func thePolicyTheSessionAndTheMenuShareOnePredicate() throws {
        let policy = try source("App/Modules/CameraCapture/CameraFrameRatePolicy.swift")
        #expect(policy.contains("HighFrameRateFeature.allows(fps:"))
        let session = try source("App/Modules/CameraCapture/CameraSession.swift")
        #expect(session.contains("guard HighFrameRateFeature.allows(fps: mode.fps,"))
        let viewModel = try source("App/Modules/CameraCapture/CameraViewModel.swift")
        #expect(viewModel.contains("var isHighFrameRateEnabled: Bool { HighFrameRateFeature.isAvailableInThisBuild() }"))
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("highFrameRateEnabled: cameraViewModel.isHighFrameRateEnabled"))
        let control = try source("App/Modules/CameraCapture/CameraFrameRateControl.swift")
        #expect(control.contains("HighFrameRateFeature.allows("))
        // The generated key name is the contract the build and the reader share.
        let availability = try source("App/Modules/CameraCapture/CameraHighFrameRateAvailability.swift")
        #expect(availability.contains("static let infoPlistKey = \"Nitrate120FPSEnabled\""))
    }
}
