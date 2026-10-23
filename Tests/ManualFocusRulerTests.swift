import AppKit
import CoreGraphics
import SwiftUI
import Testing

/// Pure behaviour for the in-frame manual-focus ruler, plus source-contract
/// wiring for the screen that owns the hardware write and the Settings rows.
///
/// The behavioural assertions are pure functions; the wiring assertions read the
/// sources through `TestRepository`, matching the other source-contract suites.
struct ManualFocusRulerTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Pure scale

    @Test func indexReadsFarAtTheTopAndNearAtTheBottom() {
        #expect(ManualFocusRulerScale.indexFraction(lensPosition: 1) == 0)
        #expect(ManualFocusRulerScale.indexFraction(lensPosition: 0) == 1)
        #expect(ManualFocusRulerScale.indexFraction(lensPosition: 0.5) == 0.5)
        // Non-finite input stays at the mid travel rather than pinning an end.
        #expect(ManualFocusRulerScale.indexFraction(lensPosition: .nan) == 0.5)
        #expect(ManualFocusRulerScale.indexFraction(lensPosition: 2) == 0)
        #expect(ManualFocusRulerScale.indexFraction(lensPosition: -1) == 1)
    }

    @Test func dragOffsetMapsToARawLensPositionAndRejectsBadTracks() {
        #expect(ManualFocusRulerScale.lensPosition(offsetFromTop: 0, length: 200) == 1)
        #expect(ManualFocusRulerScale.lensPosition(offsetFromTop: 200, length: 200) == 0)
        #expect(ManualFocusRulerScale.lensPosition(offsetFromTop: 100, length: 200) == 0.5)
        // Past either end clamps instead of running the lens beyond its range.
        #expect(ManualFocusRulerScale.lensPosition(offsetFromTop: -50, length: 200) == 1)
        #expect(ManualFocusRulerScale.lensPosition(offsetFromTop: 400, length: 200) == 0)
        #expect(ManualFocusRulerScale.lensPosition(offsetFromTop: 100, length: 0) == nil)
        #expect(ManualFocusRulerScale.lensPosition(offsetFromTop: .nan, length: 200) == nil)
    }

    @Test func voiceOverAdjustmentStepsAndClamps() {
        #expect(ManualFocusRulerScale.adjusted(lensPosition: 0.5, by: ManualFocusRulerScale.step) == 0.51)
        #expect(ManualFocusRulerScale.adjusted(lensPosition: 0.5, by: -ManualFocusRulerScale.step) == 0.49)
        #expect(ManualFocusRulerScale.adjusted(lensPosition: 1, by: ManualFocusRulerScale.step) == 1)
        #expect(ManualFocusRulerScale.adjusted(lensPosition: 0, by: -ManualFocusRulerScale.step) == 0)
        #expect(ManualFocusRulerScale.adjusted(lensPosition: .nan, by: 0) == 0.5)
        #expect(ManualFocusRulerScale.clamped(.nan) == 0.5)
        #expect(ManualFocusRulerScale.clamped(-3) == 0)
        #expect(ManualFocusRulerScale.clamped(3) == 1)
    }

    // MARK: - Source wiring

    @Test func screenOwnsTheHardwareWriteAndNeverJumpsToAStoredDefault() throws {
        let screen = try source("App/ContentView.swift")
        // The single write site lives on the screen, so the ruler and the
        // Settings switch work with the panel closed.
        #expect(screen.contains("guard isManualFocus else { return }"))
        #expect(screen.contains("cameraViewModel.session.setManualFocusPosition(Float(value))"))
        #expect(screen.contains("cameraViewModel.session.resetAutoFocus()"))
        // Enabling reads the live lens first and only locks when supported.
        #expect(screen.contains("cameraViewModel.session.readManualFocusSnapshot(includeCurrentPosition: true)"))
        #expect(screen.contains("guard snapshot.isSupported, let position = snapshot.lensPosition else { return }"))
        // The old arbitrary jump to a stored position is gone.
        #expect(!screen.contains("setManualFocusPosition(Float(manualFocusPosition))"))
        // The panel and the Settings switch share the one state.
        #expect(screen.contains("var manualFocusBinding: Binding<Bool>"))
        #expect(screen.contains("isManualFocus: manualFocusBinding"))
        #expect(screen.contains("func setManualFocusEnabled(_ enabled: Bool)"))
    }

    @Test func sessionReadsTheLiveLensPositionOnItsOwnQueue() throws {
        let session = try source("App/Modules/CameraCapture/CameraSession.swift")
        #expect(session.contains("includeCurrentPosition: Bool = false"))
        #expect(session.contains("includeCurrentPosition, isSupported, let device = self.activeDevice"))
        #expect(session.contains("device.lensPosition"))
        // The default read keeps its committed semantics.
        #expect(session.contains("lensPosition = self.committedManualFocusLensPosition"))
    }

    @Test func panelNoLongerOwnsFocusWrites() throws {
        let panel = try source("App/Modules/CameraCapture/ManualControlsPanel.swift")
        #expect(!panel.contains("setManualFocusPosition"))
        #expect(!panel.contains("resetAutoFocus"))
    }

    @Test func screenPlacesBothRulersInsideTheBoundedPreview() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("private func frameRulerBounds(in geometry: GeometryProxy) -> CGRect?"))
        #expect(screen.contains("let bounds = preview.intersection(safe)"))
        #expect(screen.contains("edge: .right"))
        #expect(screen.contains("edge: .bottom"))
        #expect(screen.contains("FrameRulerPlacementGeometry.rect("))
        #expect(screen.contains("ManualFocusRuler(lensPosition: $manualFocusPosition"))
        // Existing pinch behaviour is preserved when the zoom toggle is off.
        #expect(screen.contains("if pinchIsActive, !zoomControlsEnabled, let bottom = controlBounds[\"bottom\"]"))
    }

    @Test func zoomArrowsReuseTheHoldControlAndChevrons() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("ZoomHoldControl(symbol: \"chevron.left\""))
        #expect(screen.contains("ZoomHoldControl(symbol: \"chevron.right\""))
        #expect(screen.contains("begin: { cameraViewModel.beginSlowZoom("))
        #expect(screen.contains("end: cameraViewModel.endSlowZoom(revision:)"))
        #expect(screen.contains("step: { cameraViewModel.stepDisplayZoom("))
        #expect(screen.contains("millimeters: pinchIsActive ? pinchFocalLength"))
        // Cancellation on zoom-off, background, lens and capture transitions.
        #expect(screen.contains(".onChange(of: zoomControlsEnabled)"))
        #expect(screen.contains(".onChange(of: captureBusy)"))
    }

    @Test func settingsRowsAreDefaultOffAndNonPersistent() throws {
        let screen = try source("App/ContentView.swift")
        let settings = try source("App/Modules/Purchase/PurchaseView.swift")
        #expect(screen.contains("@State private var zoomControlsEnabled = false"))
        #expect(screen.contains("@State private var isManualFocus = false"))
        // Neither switch is written to a persisted preference.
        #expect(!screen.contains("@AppStorage(\"camera.zoomControlsEnabled\")"))
        #expect(!screen.contains("@AppStorage(\"camera.manualFocus\")"))
        #expect(settings.contains(#"SettingsToggleRow(icon: "scope""#))
        #expect(settings.contains(#"title: "Manual Focus""#))
        #expect(settings.contains(#"SettingsToggleRow(icon: "arrow.up.left.and.arrow.down.right""#))
        #expect(settings.contains(#"title: "Zoom Controls""#))
        #expect(settings.contains("isOn: manualFocusEnabled"))
        #expect(settings.contains("isOn: zoomControlsEnabled"))
    }

    // MARK: - Native render

    @MainActor @Test func realRulerRendersATickRailAndYellowIndex() throws {
        let host = NSHostingView(rootView: FocusRulerHarness(position: 0.5)
            .frame(width: 44, height: 300))
        host.frame = CGRect(x: 0, y: 0, width: 44, height: 300)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try #require(rep.cgImage)

        var yellow = 0
        var ink = 0
        for x in 0..<image.width {
            for y in 0..<image.height {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                if r > 0.6, g > 0.6, b < 0.5 { yellow += 1 }
                if r + g + b > 0.75 { ink += 1 }
            }
        }
        #expect(yellow > 20, "the yellow index must be drawn on the rail")
        #expect(ink > 60, "the tick rail and MF label must render visible ink")
        #expect(abs(Double(image.width) / Double(image.height) - 44.0 / 300.0) < 0.05,
                "the ruler keeps its 44pt hit width against its track length")
    }
}

/// A stateful host so the rendered ruler can hold a real binding.
private struct FocusRulerHarness: View {
    @State var position: Double
    var body: some View {
        ManualFocusRuler(lensPosition: $position, enabled: true)
    }
}
