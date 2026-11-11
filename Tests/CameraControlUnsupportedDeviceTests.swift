import Foundation
import Testing

/// Contracts for phones without a physical Camera Control button.
///
/// The whole feature — the Settings row, the light-press slide and the
/// full-press capture — is driven by one capability flag read from
/// `AVCaptureSession.supportsControls`. Presenting a real button needs an iPhone
/// that has one, so these are source contracts over the three files that own the
/// gate: each expectation names the path it protects.
struct CameraControlUnsupportedDeviceTests {
    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(relativePath),
                   encoding: .utf8)
    }

    /// Body of the first declaration after `marker`, resolved by brace matching,
    /// so each gate is checked on its own instead of by global substring.
    private func body(after marker: String, in text: String) throws -> String {
        let start = try #require(text.range(of: marker))
        let remainder = text[start.upperBound...]
        let open = try #require(remainder.firstIndex(of: "{"))
        var depth = 0
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            }
            index = text.index(after: index)
        }
        throw ExtractionError.unbalanced(marker)
    }

    private enum ExtractionError: Error { case unbalanced(String) }

    /// Text between two markers, so a conditional row is checked against the
    /// section it lives in rather than the whole file.
    private func slice(from start: String, to end: String, in text: String) throws -> String {
        let head = try #require(text.range(of: start))
        let remainder = text[head.upperBound...]
        let tail = try #require(remainder.range(of: end))
        return String(remainder[..<tail.lowerBound])
    }

    /// The capability is the platform truth of the hardware, cached once at
    /// construction. It must not be ANDed with graph state (`isRunning`,
    /// `canAddControl`): those are transient, so a stopped graph would hide the
    /// setting on a phone that has the button and show it on one that does not.
    @Test func sessionCachesThePlatformCapabilityWithoutGraphState() throws {
        let session = try source("App/Modules/CameraCapture/CameraSession.swift")
        #expect(session.contains("private(set) var supportsCameraControl = false"),
                "the flag must fail closed before init reads the platform")
        #expect(session.components(separatedBy: "session.supportsControls").count == 2,
                "AVCaptureSession.supportsControls is read exactly once")
        #expect(!session.contains("supportsControls &&"),
                "capability is hardware truth, never gated on isRunning/canAddControl")

        let initBody = try body(after: "override init()", in: session)
        #expect(initBody.contains("supportsCameraControl = session.supportsControls"))
        #expect(!initBody.contains("isRunning"))
        #expect(!initBody.contains("canAddControl"))
    }

    /// Every apply — the first request and each start/lens re-apply — funnels
    /// through `hardwareControlConfiguration`, so one gate there means an
    /// unsupported phone can never install a slider.
    @Test func sessionRefusesASliderRequestOnUnsupportedHardware() throws {
        let session = try source("App/Modules/CameraCapture/CameraSession.swift")
        let request = try body(after: "func updateHardwareControls(", in: session)
        #expect(request.contains("hardwareControlConfiguration(request)"),
                "the request must be resolved through the single configuration funnel")

        let configuration = try body(after: "private func hardwareControlConfiguration", in: session)
        #expect(configuration.contains("isEnabled: request.isEnabled && supportsCameraControl"),
                "an unsupported session presents no control, whatever the UI asked for")
    }

    /// The view model publishes the capability so the settings screen and the
    /// screen's capture gate read the same value.
    @Test func viewModelPublishesTheCapabilityVerbatim() throws {
        let model = try source("App/Modules/CameraCapture/CameraViewModel.swift")
        let getter = try body(after: "var supportsCameraControl: Bool", in: model)
        #expect(getter.contains("session.supportsCameraControl"))
        #expect(!getter.contains("&&"), "the getter is a passthrough, not a second policy")
        #expect(!getter.contains("isRunning"))
    }

    /// Slider eligibility fails closed on unsupported hardware before any of the
    /// per-adjustment rules run. The capability leads the stable presentation
    /// gate; write acceptance is that gate ANDed with the transient capture flag,
    /// so an unsupported phone installs nothing either way.
    @Test func sliderEligibilityFailsClosedOnUnsupportedHardware() throws {
        let model = try source("App/Modules/CameraCapture/CameraViewModel.swift")
        let eligible = try body(after: "private var areHardwareControlsPresented: Bool", in: model)
        #expect(eligible.contains("guard supportsCameraControl,"),
                "the capability leads the eligibility guard")

        let write = try body(after: "private var areHardwareControlsEligible: Bool", in: model)
        #expect(write.contains("areHardwareControlsPresented"),
                "write acceptance cannot outrun the presentation gate")
    }

    /// The full press is part of the feature, so an unsupported phone must not
    /// consume a capture event either.
    @Test func fullPressFailsClosedOnUnsupportedHardware() throws {
        let model = try source("App/Modules/CameraCapture/CameraViewModel.swift")
        let capture = try body(after: "var canAcceptHardwareCapture: Bool", in: model)
        #expect(capture.contains("guard supportsCameraControl,"),
                "the capture gate refuses a press the hardware cannot make")
    }

    /// The Settings row is hidden, not disabled: a phone without the button has
    /// no Camera Control section at all.
    @Test func settingsHidesTheCameraControlRowWhenUnsupported() throws {
        let purchase = try source("App/Modules/Purchase/PurchaseView.swift")
        #expect(purchase.contains("var cameraControlSupported = false"),
                "the property arrives fail-closed so a caller that omits it hides the row")

        let gated = try slice(from: "if cameraControlSupported {",
                              to: "SettingsToggleRow(icon: \"circle.dashed\"",
                              in: purchase)
        #expect(gated.contains("SettingsControlRow(icon: \"hand.tap\""))
        #expect(gated.contains("Camera Control"))
        #expect(gated.contains("cameraControlBinding"))
    }

    /// Hiding the feature must not clear or rewrite the persisted slide target:
    /// the preference keeps its value for a phone that does have the button.
    @Test func persistedSlideTargetIsUntouched() throws {
        let purchase = try source("App/Modules/Purchase/PurchaseView.swift")
        #expect(purchase.contains("@AppStorage(CameraControlAdjustment.preferenceKey)"))
        #expect(purchase.contains("cameraControlAdjustment = $0.rawValue"),
                "the picker still writes the user's selection unchanged")
        #expect(CameraControlAdjustment.defaultValue == .zoom)
        #expect(CameraControlAdjustment(persistedValue: nil) == .zoom)
    }
}
