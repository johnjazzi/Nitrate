import Foundation
import Testing

struct CameraModeStripGeometryTests {
    @Test func modeStripFitsBelowShutterAndBetweenTheExistingSideColumns() throws {
        for width: CGFloat in [320, 375, 393, 430] {
            for inset: CGFloat in [16, min(50, (width - CameraControlGeometry.minimumRowWidth) / 2)] {
                let controls = CGRect(x: 0, y: 600, width: width, height: 180)
                let strip = try #require(CameraModeStripGeometry.frame(
                    controls: controls, canvasWidth: width, horizontalInset: inset))
                let shooting = CameraControlGeometry(width: width - 2 * inset, height: controls.height - 8)
                let shutter = shooting.record.offsetBy(dx: inset, dy: controls.minY)
                let stock = shooting.stock.offsetBy(dx: inset, dy: controls.minY)
                let exposure = shooting.exposure.offsetBy(dx: inset, dy: controls.minY)
                #expect(strip.height == 44 && strip.width >= 96 && strip.width <= 200)
                #expect(strip.midX == width / 2)
                #expect(strip.minY >= shutter.maxY + 4)
                #expect(strip.maxY <= controls.maxY)
                #expect(!strip.intersects(stock) && !strip.intersects(exposure))
            }
        }
    }

    @Test func minimumExposureCompositionKeepsTheModeEntryVisible() throws {
        // Even with a zero-height footer: 120pt ruler + 14pt readout +
        // two 6pt stack gaps + two 6pt rims + 8pt bottom padding = 166pt.
        for height: CGFloat in [166, 168, 170, 172] {
            let controls = CGRect(x: 0, y: 600, width: 390, height: height)
            let strip = try #require(CameraModeStripGeometry.frame(
                controls: controls, canvasWidth: 390, horizontalInset: 16))
            let shutter = CameraControlGeometry(width: 358, height: height - 8).record
                .offsetBy(dx: 16, dy: 600)
            #expect(strip.minY >= shutter.maxY)
            #expect(strip.maxY <= controls.maxY)
        }
    }

    @Test func photoControlsKeepTheExitModeStripVisible() throws {
        let bar = try String(contentsOf: TestRepository.url(for: "App/Modules/CameraCapture/CameraControlBar.swift"), encoding: .utf8)
        #expect(bar.contains("CameraShootingLayout()"))
        #expect(bar.contains("exposureControl\n                    .frame(width: CameraControlGeometry.exposureWidth)"))
        #expect(!bar.contains("if isPhotoMode { exposureControl.frame"),
                "Photo must share Video's measured shooting layout, not supply a different bar height.")
        let strip = CameraModeStripGeometry.frame(controls: CGRect(x: 0, y: 600, width: 390, height: 180),
            canvasWidth: 390, horizontalInset: 16)
        #expect(strip != nil)
    }

    @Test func aSlotTooNarrowForBothTouchTargetsIsNotUsed() {
        let strip = CameraModeStripGeometry.frame(
            controls: CGRect(x: 0, y: 600, width: 300, height: 180), canvasWidth: 300, horizontalInset: 20)
        #expect(strip == nil)
    }

    @Test func shortOrInvalidMeasurementsCannotCoverTheShutter() {
        let short = CameraModeStripGeometry.frame(
            controls: CGRect(x: 0, y: 600, width: 390, height: 140), canvasWidth: 390, horizontalInset: 16)
        #expect(short == nil)
        for width: CGFloat in [0, -.infinity, .infinity, .nan] {
            #expect(CameraModeStripGeometry.frame(
                controls: CGRect(x: 0, y: 600, width: 390, height: 180), canvasWidth: width, horizontalInset: 16) == nil)
        }
    }
}
