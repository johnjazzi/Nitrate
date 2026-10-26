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

    // MARK: - Stop model

    @Test func stopModelIsEquatableWithStableIdentity() {
        let id = UUID()
        let first = ManualFocusStop(id: id, lensPosition: 0.25)
        #expect(first == ManualFocusStop(id: id, lensPosition: 0.25))
        #expect(first != ManualFocusStop(id: id, lensPosition: 0.50))
        #expect(first.id == id)
        // The convenience initialiser mints a fresh identity each call.
        #expect(ManualFocusStop(lensPosition: 0.4).id != ManualFocusStop(lensPosition: 0.4).id)
    }

    @Test func addsUpToThreeStopsAndRejectsAFourth() {
        #expect(ManualFocusStopEdit.maximumStops == 3)
        var stops: [ManualFocusStop] = []
        #expect(!ManualFocusStopEdit.isAtCapacity(stops))

        stops = ManualFocusStopEdit.adding(stops, lensPosition: 0.2)
        stops = ManualFocusStopEdit.adding(stops, lensPosition: 0.5)
        stops = ManualFocusStopEdit.adding(stops, lensPosition: 0.8)
        #expect(stops.count == 3)
        #expect(stops.map(\.lensPosition) == [0.2, 0.5, 0.8])
        #expect(ManualFocusStopEdit.isAtCapacity(stops))

        // A fourth press leaves the three established stops untouched.
        let rejected = ManualFocusStopEdit.adding(stops, lensPosition: 0.95)
        #expect(rejected == stops)
        #expect(rejected.count == 3)
    }

    @Test func addingAndMovingClampTheRawLensRange() {
        let stops = ManualFocusStopEdit.adding([], lensPosition: 4)
        #expect(stops.first?.lensPosition == 1)
        let nan = ManualFocusStopEdit.adding([], lensPosition: .nan)
        #expect(nan.first?.lensPosition == 0.5)

        let id = UUID()
        let seeded = [ManualFocusStop(id: id, lensPosition: 0.5)]
        #expect(ManualFocusStopEdit.moving(seeded, id: id, lensPosition: -2).first?.lensPosition == 0)
        #expect(ManualFocusStopEdit.moving(seeded, id: id, lensPosition: 9).first?.lensPosition == 1)
    }

    @Test func movingOneStopKeepsEveryStableIdentity() {
        let first = ManualFocusStop(lensPosition: 0.1)
        let second = ManualFocusStop(lensPosition: 0.4)
        let third = ManualFocusStop(lensPosition: 0.7)
        let stops = [first, second, third]

        let moved = ManualFocusStopEdit.moving(stops, id: second.id, lensPosition: 0.55)
        #expect(moved.map(\.id) == [first.id, second.id, third.id])
        #expect(moved[1].lensPosition == 0.55)
        #expect(moved[0] == first)
        #expect(moved[2] == third)

        // Moving an unknown identity leaves the set unchanged.
        #expect(ManualFocusStopEdit.moving(stops, id: UUID(), lensPosition: 0.9) == stops)
    }

    @Test func removingDeletesAtBothEndpointsAndIsIdentityRouted() {
        let top = ManualFocusStop(lensPosition: 0.05)
        let mid = ManualFocusStop(lensPosition: 0.5)
        let bottom = ManualFocusStop(lensPosition: 0.95)
        var stops = [top, mid, bottom]

        stops = ManualFocusStopEdit.removing(stops, id: top.id)
        #expect(stops.map(\.id) == [mid.id, bottom.id])
        stops = ManualFocusStopEdit.removing(stops, id: bottom.id)
        #expect(stops.map(\.id) == [mid.id])
        #expect(stops.isEmpty == false)

        // Removing an unknown identity is a no-op.
        #expect(ManualFocusStopEdit.removing(stops, id: UUID()) == stops)
        #expect(ManualFocusStopEdit.removing(stops, id: mid.id).isEmpty)
    }

    @Test func removalEdgeDetectsBothEndpointsAndIgnoresTheMiddle() {
        #expect(ManualFocusStopEdit.removalEdge(offsetFromTop: 0, length: 200) == .top)
        #expect(ManualFocusStopEdit.removalEdge(offsetFromTop: 200, length: 200) == .bottom)
        #expect(ManualFocusStopEdit.removalEdge(offsetFromTop: 100, length: 200) == nil)
        // Just outside the band is neither end.
        let band = ManualFocusStopEdit.removalBand * 200
        #expect(ManualFocusStopEdit.removalEdge(offsetFromTop: band + 1, length: 200) == nil)
        #expect(ManualFocusStopEdit.removalEdge(offsetFromTop: 200 - band - 1, length: 200) == nil)
        // A degenerate or non-finite track never reports an endpoint.
        #expect(ManualFocusStopEdit.removalEdge(offsetFromTop: 0, length: 0) == nil)
        #expect(ManualFocusStopEdit.removalEdge(offsetFromTop: .nan, length: 200) == nil)
    }

    @Test func snapTargetPicksTheNearestMarkerWithinTolerance() {
        let stops = [ManualFocusStop(lensPosition: 0.2),
                     ManualFocusStop(lensPosition: 0.55),
                     ManualFocusStop(lensPosition: 0.9)]

        #expect(ManualFocusStopEdit.snapTarget(stops, toLensPosition: 0.24, tolerance: 0.05)?
            .lensPosition == 0.2)
        #expect(ManualFocusStopEdit.snapTarget(stops, toLensPosition: 0.52, tolerance: 0.05)?
            .lensPosition == 0.55)
        // Outside the tolerance there is nothing to snap to.
        #expect(ManualFocusStopEdit.snapTarget(stops, toLensPosition: 0.75, tolerance: 0.05) == nil)
        // No markers and non-finite input resolve to nil.
        #expect(ManualFocusStopEdit.snapTarget([], toLensPosition: 0.5, tolerance: 1) == nil)
        #expect(ManualFocusStopEdit.snapTarget(stops, toLensPosition: .nan, tolerance: 1) == nil)
    }

    @Test func hitToleranceScalesWithTrackLengthAndStaysBounded() {
        let long = ManualFocusStopEdit.hitTolerance(length: 400)
        let short = ManualFocusStopEdit.hitTolerance(length: 100)
        #expect(long < short)
        #expect(long <= ManualFocusStopEdit.maximumHitTolerance)
        // A degenerate track still yields the safe upper bound rather than infinity.
        #expect(ManualFocusStopEdit.hitTolerance(length: 0) == ManualFocusStopEdit.maximumHitTolerance)
        #expect(ManualFocusStopEdit.hitTolerance(length: .infinity) == ManualFocusStopEdit.maximumHitTolerance)
    }

    @Test func stopLabelsReadOneThroughThree() {
        #expect(ManualFocusStopEdit.label(index: 0) == "1")
        #expect(ManualFocusStopEdit.label(index: 1) == "2")
        #expect(ManualFocusStopEdit.label(index: 2) == "3")
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
        #expect(screen.contains("guard request == focusReadGeneration, scenePhase == .active,"))
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
        #expect(screen.contains("edge: .left"))
        #expect(screen.contains("FrameRulerPlacementGeometry.rect("))
        #expect(screen.contains("ManualFocusRuler(lensPosition: $manualFocusPosition"))
        // Existing pinch behaviour is preserved when the zoom toggle is off.
        #expect(screen.contains("if pinchIsActive, !zoomControlsEnabled, let bottom = controlBounds[\"bottom\"]"))
    }

    // The layout worker owns ContentView; these assert the shared stop contract
    // it must wire so the ruler's session-local state survives a ruler toggle.
    @Test func screenHoldsSessionLocalStopsAndPassesThemToTheRuler() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("@State private var focusStops: [ManualFocusStop] = []"))
        #expect(screen.contains("stops: $focusStops"))
        // Session-only: stops are never written to a persisted store.
        #expect(!screen.contains("@AppStorage(\"camera.focusStops\")"))
        #expect(!screen.contains("@SceneStorage(\"camera.focusStops\")"))
    }

    @Test func zoomArrowsReuseTheHoldControlAndChevrons() throws {
        let screen = try source("App/ContentView.swift")
        let zoom = try source("App/Modules/CameraCapture/FrameZoomRuler.swift")
        #expect(zoom.contains("ZoomHoldControl("))
        #expect(zoom.contains("chevron.up"))
        #expect(zoom.contains("chevron.down"))
        #expect(zoom.contains("arrow(.out, symbol: \"chevron.up\", label: \"Zoom out\")"))
        #expect(zoom.contains("arrow(.in, symbol: \"chevron.down\", label: \"Zoom in\")"))
        #expect(screen.contains("begin: { cameraViewModel.beginSlowZoom("))
        #expect(screen.contains("end: cameraViewModel.endSlowZoom(revision:)"))
        #expect(screen.contains("step: cameraViewModel.stepDisplayZoom"))
        #expect(screen.contains("millimeters: pinchIsActive ? pinchFocalLength"))
        // Controlled arrows are allowed during the take, but lifecycle and
        // transition gates remain independent; cancellation still tracks availability.
        #expect(screen.contains("scenePhase == .active && !cameraViewModel.isStartingRecording"))
        #expect(screen.contains("!cameraViewModel.isStoppingRecording"))
        #expect(screen.contains("!cameraViewModel.isChangingFrameRate"))
        #expect(screen.contains("!cameraViewModel.isSwitchingCameraLens"))
        #expect(screen.contains("cameraViewModel.zoomSnapshot != nil"))
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

    // The ruler routes holds to stop editing and keeps the ordinary focus drag
    // separate, so a hold or a marker tap never also drags the live focus.
    @Test func rulerRoutesHoldsToStopEditingAndKeepsFocusDragSeparate() throws {
        let ruler = try source("App/Modules/CameraCapture/ManualFocusRuler.swift")
        // Lossless default keeps the existing call sites and render harness valid.
        #expect(ruler.contains("stops: Binding<[ManualFocusStop]> = .constant([])"))
        #expect(ruler.contains("func adding("))
        #expect(ruler.contains("func moving("))
        #expect(ruler.contains("func removing("))
        #expect(ruler.contains("func snapTarget("))
        // A hold-then-drag sequence edits a stop; a plain drag still moves focus.
        #expect(ruler.contains("LongPressGesture("))
        #expect(ruler.contains("sequenced(before:"))
        #expect(ruler.contains("DragGesture("))
        #expect(ruler.contains(".simultaneousGesture("))
        // The 44pt accessible hit width and the yellow index are preserved.
        #expect(ruler.contains(".frame(width: 44)"))
        #expect(ruler.contains("ManualFocusRulerScale.indexFraction(lensPosition: lensPosition)"))
    }

    @Test func rulerExposesNonGestureStopEditingActions() throws {
        let ruler = try source("App/Modules/CameraCapture/ManualFocusRuler.swift")
        #expect(ruler.contains(".accessibilityAction(named: \"Add focus stop\")"))
        #expect(ruler.contains(".accessibilityAction(named: \"Snap to focus stop\")"))
        #expect(ruler.contains(".accessibilityAction(named: \"Remove focus stop\")"))
        #expect(ruler.contains(".accessibilityAction(named: \"Move focus stop\")"))
    }

    @Test func stopEditingWaitsForConfirmedHoldAndResetsAfterCancellation() throws {
        let ruler = try source("App/Modules/CameraCapture/ManualFocusRuler.swift")
        #expect(ruler.contains("case .second(true, let drag):"))
        #expect(!ruler.contains("case .first(true):\n                    beginStopEdit"))
        #expect(ruler.contains(".onChange(of: touchIsActive)"))
    }

    // MARK: - Native render

    @MainActor @Test(arguments: [ColorScheme.light, .dark])
    func realRulerRendersATickRailAndYellowIndex(_ scheme: ColorScheme) throws {
        @MainActor func bitmap<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }

        // Compare with the actual semantic yellow in the same appearance and
        // explicit color space, rather than assuming device RGB component values.
        let reference = try bitmap(Color.yellow, size: CGSize(width: 8, height: 8))
        let expected = try #require(reference.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        #expect(expected.alphaComponent > 0.95)
        #expect(expected.redComponent > expected.blueComponent + 0.2)
        #expect(expected.greenComponent > expected.blueComponent + 0.2)
        let rep = try bitmap(FocusRulerHarness(position: 0.5), size: CGSize(width: 44, height: 300))
        let image = try #require(rep.cgImage)

        var yellow = 0
        var ink = 0
        for x in 0..<image.width {
            for y in 0..<image.height {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                // Restrict the yellow check to the middle of the track so the
                // MF title cannot pass it when the live index is missing.
                if y > image.height * 3 / 10, y < image.height * 7 / 10,
                   color.alphaComponent > 0.9,
                   abs(r - expected.redComponent) < 0.03,
                   abs(g - expected.greenComponent) < 0.03,
                   abs(b - expected.blueComponent) < 0.03 { yellow += 1 }
                if r + g + b > 0.75 { ink += 1 }
            }
        }
        #expect(yellow > 20, "The middle of the rail must contain the rendered yellow index (\(scheme)); reference=\(expected).")
        #expect(ink > 60, "The tick rail and MF label must render visible ink.")
        #expect(abs(Double(image.width) / Double(image.height) - 44.0 / 300.0) < 0.05,
                "The ruler keeps its 44pt hit width against its track length.")
    }

    @MainActor @Test func realRulerRendersSessionStopsOnTheRail() throws {
        let stops = [ManualFocusStop(lensPosition: 0.25), ManualFocusStop(lensPosition: 0.75)]
        let host = NSHostingView(rootView: FocusRulerHarness(position: 0.5, stops: stops)
            .frame(width: 44, height: 300))
        host.frame = CGRect(x: 0, y: 0, width: 44, height: 300)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        var orange = 0
        for x in 0..<44 {
            for y in 0..<300 {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                if r > 0.6, (0.3..<0.65).contains(g), b < 0.35 { orange += 1 }
            }
        }
        #expect(orange > 30, "each session stop must draw a visible orange marker and label")
    }

    /// The narrower drawn rail sits inside the 44pt touch column, flush to the
    /// frame edge — its ink must stay clear of the leading strip that faces the
    /// frame interior rather than being centred with a gap on both sides.
    @MainActor @Test func narrowerVisualRailIsInsetFlushToTheFrameEdge() throws {
        let visual = FrameRulerPlacementGeometry.rulerVisualThickness
        let host = NSHostingView(rootView: FocusRulerHarness(position: 0.5, visualWidth: visual)
            .frame(width: 44, height: 300))
        host.frame = CGRect(x: 0, y: 0, width: 44, height: 300)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let inset = 44 - visual
        #expect(inset > 0, "the visible rail must be narrower than its 44pt column")
        var leadingInk = 0
        var trailingInk = 0
        for x in 0..<44 {
            for y in 0..<300 {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let bright = (color.redComponent + color.greenComponent + color.blueComponent) > 0.4
                guard color.alphaComponent > 0.05, bright else { continue }
                if CGFloat(x) < inset - 1 { leadingInk += 1 } else { trailingInk += 1 }
            }
        }
        #expect(leadingInk == 0, "the rail must be inset flush to the frame edge, not centred")
        #expect(trailingInk > 30, "the inset rail must still render its ticks, index and label")
    }

    // MARK: - ContentView wiring: in-frame master controls

    @Test func toolbarMasterKeyTogglesTheInFrameControlsAndReadsActiveInOrange() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("private var manualControlsActive: Bool"))
        #expect(screen.contains("setInlineManualControlsShown(!showInlineManualControls)"))
        #expect(screen.contains("faceColor: manualControlsActive ? SettingsControlChrome.halationOrange : nil"))
        #expect(!screen.contains("faceColor: manualControlsActive ? .yellow : nil"))
        #expect(screen.contains(".accessibilityLabel(\"Manual controls\")"))
        #expect(screen.contains(".accessibilityValue(manualControlsActive ? \"Expanded\" : \"Collapsed\")"))
        // The in-frame block is the default; the old pop-up is the flagged path.
        #expect(screen.contains("else if showInlineManualControls {"))
        #expect(screen.contains("if showManualControls, legacyManualControlsEnabled,"))
    }

    @Test func hidingTheInFrameControlsNeverResetsHardwareModes() throws {
        let screen = try source("App/ContentView.swift")
        let start = try #require(screen.range(of: "private func setInlineManualControlsShown"))
        let body = String(screen[start.lowerBound...].prefix(270))
        #expect(body.contains("cameraViewModel.endSlowZoom()"))
        // Hiding stops the rumble but keeps every chosen hardware mode and the
        // session focus stops exactly as they were.
        #expect(!body.contains("isManualFocus"))
        #expect(!body.contains("resetAutoFocus"))
        #expect(!body.contains("Aperture"))
        #expect(!body.contains("Stabilization"))
        #expect(!body.contains("focusStops"))
    }

    @Test func inFrameBlockReservesTheButtonStackAndGreysTheRailInAutofocus() throws {
        let screen = try source("App/ContentView.swift")
        // The button stack keeps its three 44pt controls reserved even in AF.
        #expect(screen.contains(".frame(width: 44, height: 140)"))
        #expect(screen.contains("InlineManualControls("))
        // The rail is greyed and disabled while autofocus is selected rather
        // than forcing the lens into manual focus.
        #expect(screen.contains("enabled: canUseManualFocusRuler && isManualFocus"))
        let ruler = try source("App/Modules/CameraCapture/ManualFocusRuler.swift")
        #expect(ruler.contains("fill(enabled ? Color.yellow : Color.gray)"))
        #expect(ruler.contains("foregroundStyle(enabled ? Color.yellow : Color.gray)"))
    }

    @Test func inFrameControlsUseLiveHardwareReadbackAndHonestGates() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("cameraViewModel.liveAperture.map { String(format: \"f/%.1f\", $0) } ?? \"N/A\""))
        #expect(screen.contains("cameraViewModel.canSelectAperture && !cameraViewModel.isChangingFrameRate"))
        #expect(screen.contains("setAperture: { cameraViewModel.setLensAperture($0) }"))
        #expect(screen.contains("selectedAperture: cameraViewModel.selectedLensAperture"))
        #expect(screen.contains("apertureStops: cameraViewModel.apertureStops"))
        #expect(screen.contains("stabilization: cameraViewModel.recordingStabilization"))
        #expect(screen.contains("canChangeStabilization: cameraViewModel.canSetRecordingStabilization"))
        #expect(screen.contains("selectStabilization: { cameraViewModel.setRecordingStabilization($0) })"))
    }

    @Test func settingsSwitchesRevealTheMasterAndTheRailIsInset() throws {
        let screen = try source("App/ContentView.swift")
        // The Settings rows share one visible state with the toolbar key.
        #expect(screen.contains("zoomControlsEnabled: zoomControlsSetting,"))
        #expect(screen.contains("private var zoomControlsSetting: Binding<Bool>"))
        #expect(screen.contains("setInlineManualControlsShown(newValue)"))
        // Enabling Settings Manual Focus reveals the master without forcing
        // aperture or stabilization on.
        #expect(screen.contains("if !legacyManualControlsEnabled { setInlineManualControlsShown(true) }"))
        // The in-frame rails are handed the narrower visual width.
        #expect(screen.contains("visualWidth: FrameRulerPlacementGeometry.rulerVisualThickness"))
    }

    @Test func inFrameBlockCannotResizeThePreview() throws {
        let screen = try source("App/ContentView.swift")
        // The in-frame block is bounded by the same preview ∩ safe rectangle as
        // before, and that helper never reads a ruler's own size or any of the
        // new master state, so showing the block cannot move the preview.
        #expect(screen.contains("private func frameRulerBounds(in geometry: GeometryProxy) -> CGRect?"))
        #expect(screen.contains("let bounds = preview.intersection(safe)"))
        let start = try #require(screen.range(of: "private func frameRulerBounds"))
        let end = try #require(screen.range(of: "private func cameraLayer",
                                            range: start.upperBound..<screen.endIndex))
        let helper = String(screen[start.lowerBound..<end.lowerBound])
        #expect(!helper.contains("showInlineManualControls"))
        #expect(!helper.contains("visualWidth"))
        #expect(!helper.contains("manualControlsActive"))
    }
}

/// A stateful host so the rendered ruler can hold a real binding.
private struct FocusRulerHarness: View {
    @State var position: Double
    @State var stops: [ManualFocusStop] = []
    /// The drawn rail width; the default preserves the historical 44pt column.
    var visualWidth: CGFloat = 44

    var body: some View {
        ManualFocusRuler(lensPosition: $position, enabled: true, stops: $stops,
                         visualWidth: visualWidth)
    }
}
