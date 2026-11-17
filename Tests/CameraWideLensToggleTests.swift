import Foundation
import Testing

/// The wide lens key's 24 ↔ 50 mm toggle is presentation plus one absolute
/// focal-length request. Its label and next-target decisions are pure, so they
/// are pinned here; the physical zoom, crop and hardware paths stay owned by
/// `CameraViewModel.setFocalLengthZoom` and its engine.
@Suite("Wide lens key toggle policy")
struct CameraWideLensToggleTests {
    // MARK: - Label

    @Test func wideKeyPrintsItsNativeStopExceptAtFifty() {
        let tier = CameraFocalZoomLensTier.wide
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: 24) == 24)
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: 24.4) == 24)
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: 50) == 50)
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: 50.2) == 50)
    }

    @Test func intermediatePinchKeepsTheNativeLabel() {
        // A pinch between the two stops must not relabel the key as a fixed
        // second stop: 35 mm still reads 24, and so does 48 mm or 52 mm.
        let tier = CameraFocalZoomLensTier.wide
        for intermediate: Double in [13, 24.05, 26, 35, 48.4, 51.6, 75, 96] {
            #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: intermediate) == 24,
                    "\(intermediate) mm must not label the wide key 50")
        }
    }

    @Test func labelMatchesTheWholeMillimetreReadoutRounding() {
        // The key's number must agree with the focal readout's own rounding
        // (`Int(millimeters.rounded())`), so the label flips exactly when the
        // ruler would print 50.
        let tier = CameraFocalZoomLensTier.wide
        for millimeters: Double in stride(from: 48.0, through: 52.0, by: 0.05) {
            let readsFifty = Int(millimeters.rounded()) == 50
            #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: millimeters)
                        == (readsFifty ? 50 : 24),
                    "label disagrees with the readout at \(millimeters) mm")
        }
        // 49.5 rounds up into 50; 50.5 rounds out to 51.
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: 49.5) == 50)
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: 50.49) == 50)
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: 49.49) == 24)
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: 50.5) == 24)
    }

    @Test func otherTiersKeepTheirOwnLabels() {
        // Only the wide lens toggles. Its neighbours keep native bases even if
        // the live value happens to read 50 mm (ultrawide zoomed to 50, front).
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: .ultraWide, currentMM: 50) == 13)
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: .telephoto, currentMM: 50) == 96)
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: .front, currentMM: 50) == 24)
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: .ultraWide, currentMM: 13) == 13)
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: .telephoto, currentMM: 110) == 96)
    }

    @Test func absentOrNonFiniteInputFallsBackToTheNativeLabel() {
        let tier = CameraFocalZoomLensTier.wide
        for invalid: Double in [.nan, .infinity, -.infinity] {
            #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: invalid) == 24)
            #expect(!CameraFocalZoomPolicy.isWideLensAlternate(invalid))
        }
        #expect(CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: tier, currentMM: nil) == 24)
        #expect(!CameraFocalZoomPolicy.isWideLensAlternate(nil))
    }

    // MARK: - Next target

    @Test func toggleTargetAlternatesBetweenTwentyFourAndFifty() {
        #expect(CameraFocalZoomPolicy.wideLensToggleTargetMM(currentMM: 24) == 50,
                "the active 24 mm key asks for 50 mm")
        #expect(CameraFocalZoomPolicy.wideLensToggleTargetMM(currentMM: 50) == 24,
                "the active 50 mm key asks for native 24 mm")
        #expect(CameraFocalZoomPolicy.wideLensToggleTargetMM(currentMM: 50.4) == 24)
        #expect(CameraFocalZoomPolicy.wideLensToggleTargetMM(currentMM: 49.6) == 24)
        #expect(CameraFocalZoomPolicy.wideLensToggleTargetMM(currentMM: 50.5) == 50)
    }

    @Test func intermediatePinchTogglesForwardToFifty() {
        // The label says 24 at these values, so the tap must go to 50.
        for intermediate: Double in [24, 24.05, 35, 48, 52, 96] {
            #expect(CameraFocalZoomPolicy.wideLensToggleTargetMM(currentMM: intermediate) == 50,
                    "\(intermediate) mm must toggle forward to 50")
        }
    }

    @Test func invalidInputTogglesForwardToFifty() {
        #expect(CameraFocalZoomPolicy.wideLensToggleTargetMM(currentMM: nil) == 50)
        #expect(CameraFocalZoomPolicy.wideLensToggleTargetMM(currentMM: .nan) == 50)
        #expect(CameraFocalZoomPolicy.wideLensToggleTargetMM(currentMM: .infinity) == 50)
    }

    @Test func bothStopsResolveToTheSamePhysicalWideLens() {
        // The toggle never crosses a tier boundary, so it reuses the installed
        // wide device and the pinch path's factor conversion.
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 24) == .wide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 50) == .wide)
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 50,
                                                    multiplier: 1,
                                                    tier: .wide) == 50.0 / 24.0)
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 24,
                                                    multiplier: 1,
                                                    tier: .wide) == 1)
    }

    // MARK: - Wiring

    @Test func cameraScreenPassesTheLiveFocalLengthAndTogglesThroughTheZoomPath() throws {
        let screen = try source("App/ContentView.swift")
        // Both the direct row and the popover selector get the live value.
        #expect(screen.contains("currentFocalLengthMM: cameraViewModel.currentFocalLengthMM,"))
        #expect(screen.components(separatedBy: "currentFocalLengthMM: cameraViewModel.currentFocalLengthMM,").count - 1 == 2)
        // Same-lens activation goes through the existing absolute-mm path; the
        // focus-reset/device-selection path stays behind the different-lens branch.
        let select = try #require(screen.range(of: "private func selectLens(_ lens: CameraLens) {"))
        let end = try #require(screen.range(of: "    // MARK: - Control Bar", range: select.upperBound..<screen.endIndex))
        let body = screen[select.lowerBound..<end.lowerBound]
        #expect(body.contains("guard canSelectCameraLens else { return }"))
        #expect(body.contains("guard lens == .wide else { return }"))
        #expect(body.contains("cameraViewModel.setFocalLengthZoom("))
        #expect(body.contains("CameraFocalZoomPolicy.wideLensToggleTargetMM("))
        #expect(body.range(of: "setFocalLengthZoom")!.lowerBound < body.range(of: "focusReadGeneration &+= 1")!.lowerBound,
                "the wide toggle returns before the focus-reset path")
    }

    @Test func minimalRowForwardsLiveFocalAndOnlyWidthCallsBackInPlace() throws {
        let selector = try source("App/Modules/CameraCapture/CameraLensSelector.swift")
        #expect(selector.contains("currentFocalLengthMM: currentFocalLengthMM) { lens in"),
                "the popover's minimal row forwards the live focal length")
        #expect(selector.contains("guard lens != selectedLens || lens == .wide else { return }"))
        // One shared helper reads the policy, so the classic and minimal keys
        // cannot disagree about the label.
        #expect(selector.components(separatedBy: "CameraFocalZoomPolicy.lensKeyFocalLengthMM(for: .wide,").count - 1 == 1)
        #expect(selector.contains("lensKeyFocalMM(lens, selected: selectedLens, currentMM: currentFocalLengthMM)"))
        #expect(selector.contains("guard lens == .wide, selected == .wide else { return lens.focalLengthMM }"),
                "another physical camera at 50 mm must not relabel the inactive wide key")
        #expect(selector.contains("CameraFocalZoomPolicy.wideLensToggleTargetMM(currentMM: currentMM)"))
        #expect(selector.contains(".accessibilityIdentifier(\"camera.lens.\\(lens.rawValue)\")"))
        #expect(selector.contains(".accessibilityAddTraits(isSelected ? [.isSelected] : [])"))
    }

    @Test func lensButtonsShareOneImmediateSelectionHaptic() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains(".sensoryFeedback(.selection, trigger: lensSelectionFeedbackTrigger)"))
        #expect(screen.components(separatedBy: "lensSelectionFeedbackTrigger &+= 1").count - 1 == 1,
                "The row and popover use one feedback trigger, not one each.")
        let start = try #require(screen.range(of: "private func selectLens(_ lens: CameraLens) {"))
        let end = try #require(screen.range(of: "    // MARK: - Control Bar", range: start.upperBound..<screen.endIndex))
        let body = screen[start.lowerBound..<end.lowerBound]
        let guardRange = try #require(body.range(of: "guard canSelectCameraLens else { return }"))
        let audio = try #require(body.range(of: "CameraHaptics.prepareForCaptureFeedback()"))
        let tick = try #require(body.range(of: "lensSelectionFeedbackTrigger &+= 1"))
        let toggle = try #require(body.range(of: "cameraViewModel.setFocalLengthZoom("))
        let cameraSwitch = try #require(body.range(of: "cameraViewModel.selectLens(lens)"))
        #expect(guardRange.lowerBound < audio.lowerBound)
        #expect(audio.lowerBound < tick.lowerBound,
                "Capture's active microphone must not silence lens feedback.")
        #expect(tick.lowerBound < toggle.lowerBound && tick.lowerBound < cameraSwitch.lowerBound,
                "A lens tap ticks immediately, for physical switches and 24↔50 toggles alike.")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }
}
