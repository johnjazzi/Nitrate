import Foundation
import Testing

struct FramedPreviewLayoutTests {
    @Test func photoUsesVideoWidthWithoutChangingItsNativeAspect() {
        for width: CGFloat in [320, 390, 430] {
            let canvas = CGRect(x: 0, y: 0, width: width, height: 844)
            let video = FramedPreviewLayout.previewRect(in: canvas, topControlsBottom: 80, bottomControlsTop: 620)
            let photo = PhotoPreviewLayout.previewRect(in: canvas, topControlsBottom: 80, bottomControlsTop: 620)
            #expect(photo.width == video.width)
            #expect(photo.minX == video.minX)
            #expect(abs(photo.width / photo.height - 3.0 / 4.0) < 0.000001)
        }
    }

    @Test func frameRectIsInvariantAcrossOrientationAndFloatingChrome() {
        for width: CGFloat in [320, 390, 430] {
            let canvas = CGRect(x: 0, y: 0, width: width, height: 750)
            let referenceToolbar = CameraTopPanelGeometry(width: width - 32, statusSize: .zero,
                                                          diagnosticsHeight: 0)
            let reference = FramedPreviewLayout.previewRect(in: canvas,
                topControlsBottom: referenceToolbar.height + 8, bottomControlsTop: 560)
            for degrees in [0.0, 90.0, -90.0] {
                for diagnosticsHeight: CGFloat in [0, 44, 92] {
                    for statusSize in [CGSize.zero, CGSize(width: 112, height: 40), CGSize(width: 40, height: 112)] {
                        let toolbar = CameraTopPanelGeometry(width: width - 32, statusSize: statusSize,
                                                             diagnosticsHeight: diagnosticsHeight)
                        let top = CameraTopPanelGeometry.framingBottom(toolbarBottom: toolbar.height + 8,
                                                                       rotationDegrees: degrees)
                        let actual = FramedPreviewLayout.previewRect(in: canvas, topControlsBottom: top,
                                                                     bottomControlsTop: 560)
                        #expect(actual == reference,
                                "Orientation, timer and floating Debug/Fault must not resize or move the preview.")
                    }
                }
            }
        }
    }

    @Test(arguments: [CGFloat(320), 390, 430])
    func portraitFitsBetweenControlsWithBlackMargins(width: CGFloat) {
        for height: CGFloat in [568, 844, 932] {
            for top: CGFloat in [52, 196] {
                for bottomHeight: CGFloat in [140, 208] {
                    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
                    let bottom = height - bottomHeight
                    let rect = FramedPreviewLayout.previewRect(
                        in: canvas, topControlsBottom: top, bottomControlsTop: bottom
                    )
                    #expect(rect.width > 0 && rect.height > 0)
                    #expect(rect.minX >= canvas.minX + 8)
                    #expect(rect.maxX <= canvas.maxX - 8)
                    #expect(rect.minY >= top + 8)
                    #expect(rect.maxY <= bottom - 8)
                    #expect(abs(rect.width / rect.height - 2.0 / 3.0) < 0.000_001)
                    #expect(abs(rect.midX - canvas.midX) < 0.000_001)
                    #expect(abs(rect.midY - (top + bottom) / 2) < 0.000_001)
                }
            }
        }
    }

    @Test func lowerToolbarEdgeReducesPreviewWithoutOverlappingEitherBar() {
        let canvas = CGRect(x: 0, y: 0, width: 390, height: 760)
        let compact = FramedPreviewLayout.previewRect(
            in: canvas, topControlsBottom: 52, bottomControlsTop: 580
        )
        let expanded = FramedPreviewLayout.previewRect(
            in: canvas, topControlsBottom: 220, bottomControlsTop: 580
        )
        #expect(expanded.height < compact.height)
        #expect(expanded.minY >= 228)
        #expect(expanded.maxY <= 572)
    }

    @Test func tallCanvasFitsWidthAndLeavesExtraVerticalBlackSpace() {
        let rect = FramedPreviewLayout.previewRect(
            in: CGRect(x: 10, y: 20, width: 320, height: 1_000),
            topControlsBottom: 72, bottomControlsTop: 880, horizontalInset: 16
        )
        #expect(rect.width == 288)
        #expect(rect.minX == 26)
        #expect(rect.maxX == 314)
        #expect(rect.minY > 80)
        #expect(rect.maxY < 872)
        #expect(abs(rect.height - 432) < 0.000_001)
    }

    @Test func tooSmallOrOverlappingControlSpaceClampsToEmptyPreview() {
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 300)
        for bottom: CGFloat in [208, 210, 215] {
            let rect = FramedPreviewLayout.previewRect(
                in: canvas, topControlsBottom: 200, bottomControlsTop: bottom
            )
            #expect(rect.size == .zero)
            #expect(rect.minY >= 0 && rect.maxY <= canvas.maxY)
        }
        let narrow = FramedPreviewLayout.previewRect(
            in: CGRect(x: 0, y: 0, width: 12, height: 300),
            topControlsBottom: 52, bottomControlsTop: 200
        )
        #expect(narrow.size == .zero)
        let empty = FramedPreviewLayout.previewRect(
            in: .zero, topControlsBottom: 52, bottomControlsTop: -20
        )
        #expect(empty == .zero)
    }

    @Test func offCanvasMeasurementsNeverProduceNegativeOrOffCanvasGeometry() {
        let canvas = CGRect(x: 10, y: 20, width: 390, height: 600)
        for top: CGFloat in [-100, 800] {
            for bottom: CGFloat in [-50, 900] {
                let rect = FramedPreviewLayout.previewRect(
                    in: canvas, topControlsBottom: top, bottomControlsTop: bottom
                )
                #expect(rect.width >= 0 && rect.height >= 0)
                #expect(rect.minX >= canvas.minX && rect.maxX <= canvas.maxX)
                #expect(rect.minY >= canvas.minY && rect.maxY <= canvas.maxY)
            }
        }
    }
}
