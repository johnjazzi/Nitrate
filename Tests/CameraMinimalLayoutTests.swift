import CoreGraphics
import Foundation
import Testing

struct CameraMinimalLayoutTests {
    @Test func compactLensFacesRetainNonOverlappingHitTargets() throws {
        #expect(CameraMinimalLayout.lensFaceSize == 30)
        #expect(CameraMinimalLayout.lensHitSize >= 44)
        for width in [320.0, 375, 390, 430] {
            let controls = CGRect(x: 16, y: 500, width: width - 32, height: 204)
            let row = try #require(CameraMinimalLayout.lensRow(in: controls, canvasWidth: width, lensCount: 4))
            let shooting = CameraControlGeometry(width: controls.width, height: controls.height - 8)
            // 30pt faces on a 4pt gap: one 34pt cell each, in a 44pt-high strip.
            let cell = CameraMinimalLayout.lensCellWidth(style: .minimal)
            #expect(cell == CameraMinimalLayout.lensFaceSize + 4)
            #expect(CameraMinimalLayout.lensCellWidth(style: .classic) == cell,
                    "both finishes use the same compact cell")
            #expect(row.width == 4 * cell)
            #expect(row.height == CameraMinimalLayout.lensHitSize)
            // The row sits below the preview and above the shutter: its bottom
            // edge is 4pt above the shutter's actual top, computed from the
            // bar's real height and the REC size, not from the bar's top edge.
            let shutterTop = controls.minY + (controls.height - 8 - CameraControlGeometry.recordSize) / 2
            #expect(row.maxY + 4 == shutterTop)
            #expect(row.maxY <= controls.minY + shooting.record.minY)
            #expect(!row.intersects(shooting.record.offsetBy(dx: controls.minX, dy: controls.minY)))
            // The strip now sits inside the bar's band, so its trailing edge has
            // to clear the drawn exposure dial: the 72pt small ruler leaves 12pt
            // of empty leading slot inside the 84pt column.
            let slotLeading = CameraControlGeometry.exposureWidth - CameraExposureDialSize.small.width
            #expect(row.maxX - controls.minX <= controls.width - CameraControlGeometry.exposureWidth + slotLeading,
                    "the lens strip never reaches the drawn exposure dial")
            for index in 0..<3 {
                let hit = CGRect(x: row.minX + CGFloat(index) * cell, y: row.minY,
                                 width: cell, height: row.height)
                let next = hit.offsetBy(dx: cell, dy: 0)
                #expect(hit.intersection(next).width == 0)
            }
        }
    }

    /// The row clears the preview by the 2pt guard and disappears rather than
    /// shrinking or overlapping when the bar is too short to hold it.
    @Test func lensRowClearsThePreviewAndHasBoundedFallbacks() throws {
        let controls = CGRect(x: 16, y: 500, width: 358, height: 204)
        let row = try #require(CameraMinimalLayout.lensRow(in: controls, canvasWidth: 390, lensCount: 4))
        #expect(CameraMinimalLayout.lensRow(in: controls, canvasWidth: 390, lensCount: 4,
                                            previewBottom: row.minY - 2) == row,
                "2pt of preview clearance is enough")
        #expect(CameraMinimalLayout.lensRow(in: controls, canvasWidth: 390, lensCount: 4,
                                            previewBottom: row.minY - 1) == nil,
                "the row is withheld rather than drawn over the preview")
        #expect(CameraMinimalLayout.lensRow(in: CGRect(x: 0, y: 0, width: 390, height: 12),
                                            canvasWidth: 390, lensCount: 4) == nil,
                "a bar too short to seat the strip offers no row")
        // The strip keeps the fixed 44pt target and never resizes the bar or the
        // 84pt shutter it sits above.
        #expect(CameraMinimalLayout.lensHitSize == 44)
        #expect(CameraControlGeometry.recordSize == 84)
    }

    @Test func absentLensesAndUnusableBoundsDoNotCreateDeadControls() {
        let controls = CGRect(x: 0, y: 500, width: 390, height: 204)
        #expect(CameraMinimalLayout.lensRow(in: controls, canvasWidth: 390, lensCount: 0) == nil)
        // 4 x 34pt cells plus a 16pt margin is 152pt, so a 150pt canvas has no row.
        #expect(CameraMinimalLayout.lensRow(in: controls, canvasWidth: 150, lensCount: 4) == nil)
        #expect(CameraMinimalLayout.lensRow(in: controls, canvasWidth: .nan, lensCount: 4) == nil)
    }

    @Test func measuredExposureFitsThePreviewBottomWithoutOccupyingSideRails() throws {
        for width in [200.0, 260, 370, 430] {
            let preview = CGRect(x: 10, y: 80, width: width, height: 400)
            let meter = try #require(CameraMinimalLayout.exposureMeter(in: preview))
            #expect(preview.contains(meter))
            #expect(meter.midX == preview.midX)
            #expect(preview.maxY - meter.maxY == 10)
            #expect(meter.minX - preview.minX >= 48)
            #expect(preview.maxX - meter.maxX >= 48)
        }
        #expect(CameraMinimalLayout.exposureMeter(in: .zero) == nil)
        #expect(CameraMinimalLayout.exposureMeter(in: CGRect(x: 0, y: 0, width: 100, height: 50)) == nil)
    }

    @Test func sharedStockEntryAndMeterReadTheExistingStateOwners() throws {
        let screen = try source("App/ContentView.swift")
        let bar = try source("App/Modules/CameraCapture/CameraControlBar.swift")
        #expect(screen.contains("CameraLensControlPosition.resolved(lensControlPositionRaw)"))
        #expect(screen.contains(".color(lightType: selectedStock?.lightType)"))
        #expect(screen.contains("CameraLensRow(availableLenses: availableLenses, selectedLens: selectedLens,"))
        #expect(screen.contains("meteredEV: cameraViewModel.liveExposureTargetOffset,"))
        #expect(screen.contains("targetEV: cameraViewModel.liveExposureBias,"))
        // The well is the bar's shared backing, not a per-style inset plate: both
        // rulers seat in `cameraWellBacking` and the column adds none of its own.
        let exposureSetting = try #require(bar.components(separatedBy: "private var exposureSetting: some View").last)
        let exposureBody = try #require(exposureSetting.components(separatedBy: "private var exposureHeader").first)
        #expect(exposureBody.components(separatedBy: ".cameraWellBacking()").count - 1 == 2,
                "the ISO and EV rulers each seat in the shared well")
        #expect(!bar.contains("CameraInsetSurface"),
                "the well belongs to the shared backing, not a per-style inset plate")
        #expect(bar.contains(".gesture(stockEntryGesture)"))
        #expect(!bar.contains("pushPullBadge("))
        // The stock sheet's bottom row belongs to the shared compact picker:
        // ContentView hands it the resolved push/pull and the persisted bindings
        // and builds no pill of its own.
        #expect(screen.contains("CompactStockPicker(stocks: stocks, selectedStockId: selectedStockIdBinding,"))
        #expect(screen.contains("gauge: $gauge, resolvedPushPull: resolvedPushPull,"))
        #expect(screen.contains("isAutomatic: $pushPullAutomatic, manualStops: $pushPullStops,"))
        #expect(screen.contains("onPushPullChange: persistPreferences,"),
                "the picker writes through the existing persistence callback")
        #expect(!screen.contains("PushPullControl("),
                "the pill is the picker's, never a second copy in the sheet")
        let picker = try source("App/Modules/FilmStockLibrary/CompactStockPicker.swift")
        #expect(picker.contains("PushPullControl(resolved: resolvedPushPull,"),
                "the picker instantiates the canonical shared pill")
        #expect(picker.contains("manualStops: $manualStops,"))
        #expect(picker.contains("enlarged: true"),
                "the sheet shows the enlarged pill, not the compact toolbar rung")
        #expect(picker.contains("GaugeControl(gauge: $gauge, enlarged: true)"),
                "the gauge is the shared control at the same enlarged size")
    }

    @Test func overlaysClearEachOtherWithoutGrowingTheShootingBar() throws {
        for width in [320.0, 375, 390, 430] {
            let controls = CGRect(x: 16, y: 500, width: width - 32, height: 176)
            let preview = CGRect(x: 10, y: 70, width: width - 20, height: 422)
            let lens = try #require(CameraMinimalLayout.lensRow(in: controls, canvasWidth: width, lensCount: 4))
            let meter = try #require(CameraMinimalLayout.exposureMeter(in: preview, above: lens))
            let pinch = try #require(CameraMinimalLayout.pinchRuler(in: preview, avoiding: [meter, lens]))
            #expect(preview.contains(meter))
            #expect(preview.contains(pinch))
            #expect(!lens.intersects(meter))
            #expect(!pinch.intersects(meter))
            #expect(!pinch.intersects(lens))
            let exposure = CGRect(x: width - 100, y: controls.minY, width: 84, height: 168)
            for angle in [0.0, 90, -90] {
                let rescue = try #require(DaylightExposureRescueGeometry.buttonRect(
                    above: exposure, in: CGSize(width: width, height: 700),
                    rotationDegrees: angle, excluding: meter.union(lens).union(pinch)))
                #expect(!rescue.intersects(meter))
                #expect(!rescue.intersects(lens))
                #expect(!rescue.intersects(pinch))
            }
        }
        let layout = try source("App/Modules/CameraCapture/CameraShootingLayout.swift")
        #expect(layout.contains("height: exposure.height"))
        #expect(!layout.contains("minimumBarHeight"))
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.url(for: path), encoding: .utf8)
    }
}
