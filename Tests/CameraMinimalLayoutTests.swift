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
            #expect(abs(row.midX - CGFloat(width) / 2) < 0.001)
            #expect(row.width == 4 * CameraMinimalLayout.lensHitSize)
            #expect(row.maxY < controls.minY)
            #expect(row.maxY <= controls.minY + shooting.record.minY)
            #expect(!row.intersects(shooting.exposure.offsetBy(dx: controls.minX, dy: controls.minY)))
            for index in 0..<3 {
                let hit = CGRect(x: row.minX + CGFloat(index) * 44, y: row.minY, width: 44, height: 44)
                let next = hit.offsetBy(dx: 44, dy: 0)
                #expect(hit.intersection(next).width == 0)
            }
        }
    }

    @Test func absentLensesAndUnusableBoundsDoNotCreateDeadControls() {
        let controls = CGRect(x: 0, y: 500, width: 390, height: 204)
        #expect(CameraMinimalLayout.lensRow(in: controls, canvasWidth: 390, lensCount: 0) == nil)
        #expect(CameraMinimalLayout.lensRow(in: controls, canvasWidth: 160, lensCount: 4) == nil)
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
        #expect(!bar.contains("ExposureIndicatorView("))
        #expect(bar.contains("Button(action: onShowStockSheet)"))
        #expect(!bar.contains("pushPullBadge("))
        #expect(screen.contains("PushPullControl(resolved: resolvedPushPull,"))
        #expect(screen.contains("manualStops: $pushPullStops,"))
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
