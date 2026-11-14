import Foundation
import SwiftUI
import Testing

struct CameraUIStyleTests {
    @Test func currentInterfaceIsTheMigrationAndEnvironmentDefault() {
        #expect(CameraUIStyle.preferenceKey == "camera.uiStyle")
        #expect(CameraUIStyle.defaultValue == .minimal)
        #expect(EnvironmentValues().cameraUIStyle == .minimal)
        #expect(CameraUIStyle.allCases.map(\.title) == ["Classic", "Minimal"])
        #expect(CameraUIStyle.resolved("classic") == .classic)
        #expect(CameraUIStyle.resolved("minimal") == .minimal)
        for unknown in ["", "CLASSIC", "unknown"] {
            #expect(CameraUIStyle.resolved(unknown) == .minimal)
        }
    }

    @Test func stylePersistsWithoutOverwritingIndependentPreferences() throws {
        let suite = "CameraUIStyleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CameraControlColorPreference.green.save(to: defaults)
        CameraLensControlPosition.aboveShutter.save(to: defaults)
        defaults.set(1.3, forKey: CameraExposureBiasPreference.preferenceKey)
        defaults.set(true, forKey: CameraRulerContrastPreference.preferenceKey)
        for style in CameraUIStyle.allCases {
            style.save(to: defaults)
            #expect(CameraUIStyle.load(from: defaults) == style)
            #expect(CameraControlColorPreference.load(from: defaults) == .green)
            #expect(CameraLensControlPosition.load(from: defaults) == .aboveShutter)
            #expect(defaults.double(forKey: CameraExposureBiasPreference.preferenceKey) == 1.3)
            #expect(defaults.bool(forKey: CameraRulerContrastPreference.preferenceKey))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func switchingIsBlockedThroughoutCapture(captureBusy: Bool, photoBusy: Bool) {
        #expect(CameraUIStyle.canChange(captureBusy: captureBusy, photoCaptureBusy: photoBusy)
                == (!captureBusy && !photoBusy))
    }

    @Test(arguments: [CGFloat(288), 358, 400])
    func stylesReuseThePreviewShutterAndExposureFootprint(width: CGFloat) {
        let classic = CameraControlGeometry(width: width, height: 168, style: .classic)
        let minimal = CameraControlGeometry(width: width, height: 168, style: .minimal)
        // Both finishes place the same compact column: only the well chrome
        // differs, so switching style cannot move or resize a control.
        #expect(classic.record == minimal.record)
        #expect(classic.exposure == minimal.exposure)
        #expect(classic.stock == minimal.stock)
        #expect(classic.lcd == minimal.lcd)
        // Classic joins Minimal's compact arrangement: stock above the readout.
        #expect(classic.stock.maxY < classic.lcd.minY)
        #expect(minimal.stock.maxY < minimal.lcd.minY)
        #expect(classic.stock.height >= 44)
        #expect(minimal.stock.height >= 44)
    }

    @Test func aTapAsksForTheCompactPickerAndAHoldForTheFullList() {
        #expect(CameraStockEntry.holdThreshold == 0.5)
        // Both finishes offer both surfaces: a short press is the compact
        // picker, a held press the full stock list with the sample preview.
        for style in CameraUIStyle.allCases {
            for duration: TimeInterval in [0, 0.1, 0.49] {
                #expect(CameraStockEntry.destination(style: style, pressDuration: duration) == .compact)
            }
            for duration: TimeInterval in [0.5, 0.9, 3] {
                #expect(CameraStockEntry.destination(style: style, pressDuration: duration) == .full)
            }
        }
        // The requested entry is preserved; neither finish rewrites it.
        #expect(CameraStockEntry.resolved(.compact, style: .minimal) == .compact)
        #expect(CameraStockEntry.resolved(.compact, style: .classic) == .compact)
        #expect(CameraStockEntry.resolved(.full, style: .minimal) == .full)
        #expect(CameraStockEntry.resolved(.full, style: .classic) == .full)
    }

    /// The bar hands the sheet the entry the operator asked for, and the
    /// exclusive gesture owns the first presentation: a recognised hold can
    /// never also fire the tap action.
    @Test func theBarResolvesTheRequestedEntryAndTheHoldOwnsThePresentation() throws {
        let bar = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraControlBar.swift"), encoding: .utf8)
        #expect(bar.contains("onShowStockSheet(CameraStockEntry.resolved(requested, style: uiStyle))"),
                "the bar resolves the requested entry without forcing a Classic full list")
        #expect(bar.contains(".exclusively(before: TapGesture())"),
                "the hold and the tap are exclusive, so only one sheet is presented")
        #expect(bar.contains("if held { openStockEntry(.full) }"))
        #expect(bar.contains("openStockEntry(.compact)"))
    }

    /// The sheet draws the detent it was handed, so the style is resolved once,
    /// on the camera bar, and a presented sheet can never swap under the finger.
    @Test func theSheetDrawsTheSurfaceItWasHanded() throws {
        let screen = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/ContentView.swift"), encoding: .utf8)
        let sheet = try #require(screen.components(separatedBy: "private struct StockSheetView").last)
        #expect(sheet.contains("var entry: CameraStockEntry = .compact"))
        // Both entries now reach both heights: the entry picks the first detent
        // and a drag is the only thing that changes it.
        #expect(sheet.contains(".presentationDetents([.height(360), .large], selection: detentSelection)"),
                "Neither entry may be pinned to a single detent.")
        #expect(sheet.contains("private var resolvedEntry: CameraStockEntry { presentationOverride ?? entry }"))
        #expect(sheet.contains("private var isExpanded: Bool { resolvedEntry == .full }"),
                "The large detent is what reveals the sample preview above the same controls.")
        #expect(!sheet.contains("if entry == .compact {"),
                "A branch on the requested entry is what made the two heights two layouts.")
        #expect(!sheet.contains("uiStyle == .minimal"),
                "The sheet must not re-resolve the style in front of the operator.")
    }

    @Test func compactLensFacesHaveFourPointGapsAndDisjointTouchCells() throws {
        // Both finishes use the same 34 x 44 cell: a 30pt face on a 4pt gap.
        let cell = CameraMinimalLayout.lensCellWidth(style: .minimal)
        #expect(cell - CameraMinimalLayout.lensFaceSize == 4)
        #expect(cell == 34)
        #expect(CameraMinimalLayout.lensCellWidth(style: .classic) == cell,
                "Classic shares Minimal's compact lens cell")
        let controls = CGRect(x: 0, y: 600, width: 390, height: 168)
        let row = try #require(CameraMinimalLayout.lensRow(in: controls, canvasWidth: 390, lensCount: 4))
        // The bar's bottom padding is not part of the shooting layout, so the
        // shutter sits at the layout's own measured height.
        let shooting = CameraControlGeometry(width: controls.width, height: controls.height - 8)
        #expect(row.width == cell * 4)
        #expect(row.height == 44)
        // The row sits above the shutter with a 4pt gap: below the preview,
        // never over the REC button and never resizing the bar.
        #expect(row.maxY + 4 == controls.minY + shooting.record.minY)
        #expect(!row.intersects(shooting.record.offsetBy(dx: controls.minX, dy: controls.minY)))
        #expect(row.midX == controls.midX)
        let first = CGRect(x: row.minX, y: row.minY, width: cell, height: row.height)
        let next = first.offsetBy(dx: cell, dy: 0)
        #expect(!first.intersects(next))
    }
}
