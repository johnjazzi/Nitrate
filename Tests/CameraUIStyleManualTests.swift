import AppKit
import CoreGraphics
import SwiftUI
import Testing

/// The camera UI style is presentation only, so this suite pins two things: the
/// manual controls draw measurably differently in Minimal and Classic, and the
/// taps, drags, holds, ruler mappings and single hardware writes are untouched
/// by the choice.
@Suite struct CameraUIStyleManualTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Presentation values

    @Test func minimalDropsTheManualPlateAndClassicKeepsIt() {
        let minimal = ManualControlChrome.face(.minimal)
        #expect(!minimal.drawsPlate, "Minimal draws no plate behind the manual faces.")
        #expect(minimal.fillOpacity == 0)
        #expect(minimal.castsShadow, "Without a plate one soft shadow holds the ink off the footage.")

        let classic = ManualControlChrome.face(.classic)
        #expect(classic.drawsPlate, "Classic keeps the pre-minimal plate.")
        #expect(classic.fillOpacity == 0.45, "Classic draws the same dark fill it always had.")
        #expect(!classic.castsShadow, "Classic keeps its plate rather than gaining a second depth cue.")
        #expect(minimal != classic)
    }

    @Test func zoomReadoutScrimOnlyExistsInClassic() {
        #expect(ManualControlChrome.readoutScrim(.minimal) == 0,
                "Minimal draws the focal readout with no capsule.")
        #expect(ManualControlChrome.readoutScrim(.classic) == 0.65,
                "Classic keeps the capsule that held the readout clear of footage.")
    }

    @Test func holdKeysReadLiveZoomStateInTheAccentOnlyWhenMinimal() {
        #expect(ManualControlChrome.holdGlyph(.minimal, enabled: true) == .accent)
        #expect(ManualControlChrome.holdGlyph(.minimal, enabled: false) == .muted,
                "A key that cannot act never borrows the accent.")
        #expect(ManualControlChrome.holdGlyph(.classic, enabled: true) == .neutral)
        #expect(ManualControlChrome.holdGlyph(.classic, enabled: false) == .neutral)
    }

    @Test func stabilizationFaceIsFullAccentInMinimalAndRampedInClassic() {
        #expect(InlineManualControlPresentation.stabilizationOpacity(.standard, style: .minimal) == 1)
        #expect(InlineManualControlPresentation.stabilizationOpacity(.cinematic, style: .minimal) == 1)
        #expect(InlineManualControlPresentation.stabilizationOpacity(.extreme, style: .minimal) == 1)
        #expect(InlineManualControlPresentation.stabilizationOpacity(.standard, style: .classic) == 0.4)
        #expect(InlineManualControlPresentation.stabilizationOpacity(.cinematic, style: .classic) == 0.7)
        #expect(InlineManualControlPresentation.stabilizationOpacity(.extreme, style: .classic) == 1)
        // Off is never accent: both styles leave the grey to the caller.
        #expect(InlineManualControlPresentation.stabilizationOpacity(.off, style: .minimal) == 0)
        #expect(InlineManualControlPresentation.stabilizationOpacity(.off, style: .classic) == 0)
    }

    // MARK: - Rendered faces

    @MainActor private func bitmap<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Fraction of the sampled column that carries a dark, opaque face. The
    /// columns sit inside the drawn rail but clear of the tick strokes, the
    /// marker labels and the readout, so only a plate can darken them.
    private func plateCoverage(_ rep: NSBitmapImageRep,
                               columns fractions: [Double] = [0.62, 0.70]) -> Double {
        let columns = fractions.map { Int(Double(rep.pixelsWide) * $0) }
        let top = Int(Double(rep.pixelsHigh) * 0.12)
        let bottom = Int(Double(rep.pixelsHigh) * 0.88)
        var dark = 0
        var total = 0
        for y in top..<bottom {
            for x in columns {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                if color.alphaComponent > 0.3, brightness < 0.25 { dark += 1 }
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }

    private struct FocusRulerHarness: View {
        let style: CameraUIStyle

        var body: some View {
            ManualFocusRuler(lensPosition: .constant(0.5), enabled: true, visualWidth: 44)
                .environment(\.cameraUIStyle, style)
                .environment(\.cameraControlAccent, CameraControlColorPreference.orangeAccent)
        }
    }

    @MainActor @Test func classicFocusRailKeepsThePlateThatMinimalRemoves() throws {
        let size = CGSize(width: 44, height: 300)
        let classic = try bitmap(FocusRulerHarness(style: .classic), size: size)
        let minimal = try bitmap(FocusRulerHarness(style: .minimal), size: size)

        #expect(plateCoverage(classic) > 0.9, "Classic keeps the dark focus rail plate.")
        #expect(plateCoverage(minimal) < 0.05, "Minimal draws the focus ticks straight over the preview.")
        // Neither style may change the ruler's 44pt column.
        #expect(abs(Double(classic.pixelsWide) / Double(classic.pixelsHigh)
                    - Double(minimal.pixelsWide) / Double(minimal.pixelsHigh)) < 0.001)
    }

    private struct ZoomRulerHarness: View {
        let style: CameraUIStyle

        var body: some View {
            FrameZoomRuler(millimeters: 48, enabled: true, revision: 0,
                           begin: { _ in }, end: { _ in }, step: { _ in },
                           availableFocalRange: 13...150, visualWidth: 44)
                .environment(\.cameraUIStyle, style)
                .environment(\.cameraControlAccent, CameraControlColorPreference.orangeAccent)
        }
    }

    @MainActor @Test func zoomRailPlateAndCapsuleFollowTheStyleButTheAccentIndexDoesNot() throws {
        let size = CGSize(width: 44, height: 300)
        let classic = try bitmap(ZoomRulerHarness(style: .classic), size: size)
        let minimal = try bitmap(ZoomRulerHarness(style: .minimal), size: size)

        // The zoom rail carries tick labels at 62% of its width and a centred
        // readout, so the plate columns sit to the right of both.
        let classicCoverage = plateCoverage(classic, columns: [0.86, 0.92])
        #expect(classicCoverage > 0.9,
                "Classic keeps the dark zoom rail plate (saw \(classicCoverage)).")
        #expect(plateCoverage(minimal, columns: [0.86, 0.92]) < 0.05,
                "Minimal draws the zoom ticks straight over the preview.")

        let reference = try bitmap(Color(CameraControlColorPreference.orangeAccent),
                                   size: CGSize(width: 8, height: 8))
            .colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB)
        let accent = try #require(reference)

        func accentIndexRows(_ rep: NSBitmapImageRep) -> Int {
            let middle = rep.pixelsHigh / 2
            var rows = 0
            for y in (middle - 4)...(middle + 4) {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    guard color.alphaComponent > 0.9 else { continue }
                    if abs(color.redComponent - accent.redComponent) < 0.04,
                       abs(color.greenComponent - accent.greenComponent) < 0.04,
                       abs(color.blueComponent - accent.blueComponent) < 0.04 {
                        rows += 1
                        break
                    }
                }
            }
            return rows
        }

        #expect(accentIndexRows(classic) >= 3, "Classic paints the focal index in the resolved accent.")
        #expect(accentIndexRows(minimal) >= 3, "Minimal keeps the same accent index.")
    }

    private struct HoldKeyHarness: View {
        let style: CameraUIStyle

        var body: some View {
            ZoomHoldControl(symbol: "chevron.up", label: "Zoom out", enabled: true,
                            revision: 0, begin: {}, end: { _ in }, step: {})
                .environment(\.cameraUIStyle, style)
                .environment(\.cameraControlAccent, CameraControlColorPreference.orangeAccent)
        }
    }

    /// The corner of the 44pt key is clear of the glyph, so any ink there is the
    /// key's own face — the plate Classic draws and Minimal removes.
    @MainActor @Test func holdKeyFaceIsUnboxedInMinimalAndFilledInClassic() throws {
        let size = CGSize(width: 44, height: 44)
        let classic = try bitmap(HoldKeyHarness(style: .classic), size: size)
        let minimal = try bitmap(HoldKeyHarness(style: .minimal), size: size)

        func cornerInk(_ rep: NSBitmapImageRep) -> Double {
            let inset = Int(Double(rep.pixelsWide) * 0.16)
            var total = 0.0
            var samples = 0
            for y in inset..<(inset * 2) {
                for x in inset..<(inset * 2) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    total += color.alphaComponent
                    samples += 1
                }
            }
            return samples == 0 ? 0 : total / Double(samples)
        }

        #expect(cornerInk(classic) > 0.08, "Classic keeps the hold key's faint plate.")
        #expect(cornerInk(minimal) < 0.02, "Minimal leaves the hold key unboxed; only its glyph is drawn.")
        #expect(classic.pixelsWide == minimal.pixelsWide && classic.pixelsHigh == minimal.pixelsHigh,
                "Both styles keep the same 44pt key footprint.")
    }

    // MARK: - Unchanged actions

    @Test func stylesNeverMoveAHitRegionOrReachTheManualActions() throws {
        let surface = try source("App/Modules/CameraCapture/ManualControlsSurface.swift")
        let zoom = try source("App/Modules/CameraCapture/FrameZoomRuler.swift")
        let focus = try source("App/Modules/CameraCapture/ManualFocusRuler.swift")
        let panel = try source("App/Modules/CameraCapture/ManualControlsPanel.swift")
        let inline = try source("App/Modules/CameraCapture/InlineManualControls.swift")

        // The hold key keeps its whole 44pt target and rectangle hit shape.
        #expect(surface.contains(".frame(width: 44, height: 44)"))
        #expect(surface.contains(".contentShape(Rectangle())"))
        // The rulers keep the 44pt column, the cosmetic (non-hit-testing) rail
        // and every hold/drag threshold that maps a touch to a lens position.
        #expect(focus.contains(".frame(width: 44)"))
        #expect(zoom.contains(".allowsHitTesting(false)"))
        #expect(focus.contains("ManualFocusStopEdit.focusDragThreshold"))
        #expect(focus.contains("ManualFocusStopEdit.holdDuration"))
        #expect(focus.contains("ManualFocusStopEdit.removalBand"))
        #expect(zoom.contains("FrameZoomRulerScale.resolvedRange"))
        // The begin/end/revision zoom protocol is shared and unedited.
        #expect(surface.contains("if inside, heldRevision == nil, !cancelledUntilRelease"))
        #expect(surface.contains("if let heldRevision { end(heldRevision) }"))
        // One hardware write per control, still only in the panel.
        #expect(panel.contains("cameraViewModel.setLensAperture(nil)"))
        #expect(panel.contains("cameraViewModel.beginSlowZoom"))
        #expect(panel.contains("cameraViewModel.endSlowZoom(revision:)"))
        // Live state reads the resolved accent; the adjustable aperture keeps its
        // semantic purple and a fixed lens keeps the shared grey.
        #expect(surface.contains("@Environment(\\.cameraControlAccent)"))
        #expect(inline.contains("SettingsControlChrome.lightPurple"))
        #expect(inline.contains("InlineManualControlPresentation.inactiveGrey"))
        #expect(panel.contains("SettingsControlChrome.lightPurple"))
        #expect(panel.contains("InlineManualControlPresentation.inactiveGrey"))
        #expect(!inline.contains("Color.yellow"))
        #expect(!focus.contains("Color.yellow"))
        #expect(!zoom.contains(".yellow"))
    }

    @Test func thePlateLivesInOnePlaceAndBothRulersRouteThroughIt() throws {
        let surface = try source("App/Modules/CameraCapture/ManualControlsSurface.swift")
        let zoom = try source("App/Modules/CameraCapture/FrameZoomRuler.swift")
        let focus = try source("App/Modules/CameraCapture/ManualFocusRuler.swift")

        #expect(surface.components(separatedBy: "fillOpacity: 0.45").count == 2,
                "Only the shared chrome names the classic plate fill.")
        #expect(zoom.contains("ManualRulerFace(chrome: ManualControlChrome.face(uiStyle)"))
        #expect(focus.contains("ManualRulerFace(chrome: ManualControlChrome.face(uiStyle)"))
        #expect(!zoom.contains("RoundedRectangle(cornerRadius: 10).fill("))
        #expect(!focus.contains("RoundedRectangle(cornerRadius: 8)"))
        #expect(zoom.contains("ManualControlChrome.readoutScrim(uiStyle)"),
                "The readout capsule is the shared chrome's decision, not a second local rule.")
        // The style may never become a second state owner: it is read from the
        // environment in every manual control.
        for text in [surface, zoom, focus] {
            #expect(text.contains("@Environment(\\.cameraUIStyle)"),
                    "The manual controls read the style from the environment.")
            #expect(!text.contains("= CameraUIStyle."))
        }
    }
}
