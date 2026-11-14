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
        #expect(classic.record == minimal.record)
        #expect(classic.exposure == minimal.exposure)
        #expect(classic.lcd.maxY < classic.stock.minY)
        #expect(minimal.stock.maxY < minimal.lcd.minY)
        #expect(classic.stock.height >= 44)
        #expect(minimal.stock.height >= 44)
    }

    @Test func aTapAsksForTheCompactPickerAndAHoldForTheFullList() {
        #expect(CameraStockEntry.holdThreshold == 0.5)
        // Minimal offers both surfaces: a short press is the compact picker, a
        // held press the full stock list with the sample preview.
        for duration: TimeInterval in [0, 0.1, 0.49] {
            #expect(CameraStockEntry.destination(style: .minimal, pressDuration: duration) == .compact)
        }
        for duration: TimeInterval in [0.5, 0.9, 3] {
            #expect(CameraStockEntry.destination(style: .minimal, pressDuration: duration) == .full)
        }
        // Classic has one stock sheet, so it answers every press with the full list.
        for duration: TimeInterval in [0, 0.2, 0.49, 5] {
            #expect(CameraStockEntry.destination(style: .classic, pressDuration: duration) == .full)
        }
        #expect(CameraStockEntry.resolved(.compact, style: .minimal) == .compact)
        #expect(CameraStockEntry.resolved(.compact, style: .classic) == .full)
    }

    /// The sheet draws the surface it was handed, so the style is resolved once,
    /// on the camera bar, and a presented sheet can never swap under the finger.
    @Test func theSheetDrawsTheSurfaceItWasHanded() throws {
        let screen = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/ContentView.swift"), encoding: .utf8)
        let sheet = try #require(screen.components(separatedBy: "private struct StockSheetView").last)
        #expect(sheet.contains("var entry: CameraStockEntry = .compact"))
        #expect(sheet.contains("if entry == .compact {"))
        #expect(sheet.contains("presentationDetents(entry == .compact ? [.height(360), .large] : [.large])"))
        #expect(!sheet.contains("uiStyle == .minimal"),
                "The sheet must not re-resolve the style in front of the operator.")
    }

    @Test func compactLensFacesHaveFourPointGapsAndDisjointTouchCells() throws {
        let cell = CameraMinimalLayout.lensCellWidth(style: .minimal)
        #expect(cell - CameraMinimalLayout.lensFaceSize == 4)
        #expect(CameraMinimalLayout.lensCellWidth(style: .classic) == 44)
        let controls = CGRect(x: 0, y: 600, width: 390, height: 168)
        let row = try #require(CameraMinimalLayout.lensRow(in: controls, canvasWidth: 390, lensCount: 4))
        #expect(row.width == cell * 4)
        #expect(row.height == 44)
        #expect(row.maxY < controls.minY)
        #expect(row.midX == controls.midX)
        let first = CGRect(x: row.minX, y: row.minY, width: cell, height: row.height)
        let next = first.offsetBy(dx: cell, dy: 0)
        #expect(!first.intersects(next))
    }
}
