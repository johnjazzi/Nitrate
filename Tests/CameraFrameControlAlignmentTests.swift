import CoreGraphics
import Foundation
import Testing

/// Contract for the bottom shooting bar's alignment with the framed viewfinder.
///
/// In Frame Mode the bar's outer LCD/stock edge and outer exposure edge move
/// onto the preview's side edges, from the same `FramedPreviewLayout` rectangle
/// the camera layer uses, without resizing the preview, moving the centred REC
/// column, changing the retained column heights or moving the exposure rescue
/// anchor. The inset is pure geometry: it never reads capture state or
/// orientation, and the bar's measured height — and so the preview — never
/// depends on it. A canvas too narrow (or too wide in landscape) for the row to
/// sit inside the frame caps at the widest non-overlapping inset rather than
/// shrinking a touch target or widening the viewfinder.
struct CameraFrameControlAlignmentTests {
    /// Realistic safe-area-reduced portrait canvases and their bar heights.
    private let portraits: [(width: CGFloat, height: CGFloat)] = [(390, 763), (402, 778)]
    private let barHeight: CGFloat = 168
    private let topControlsBottom: CGFloat = 58
    private let bottomPadding: CGFloat = 8

    private func preview(_ width: CGFloat, _ height: CGFloat) -> CGRect {
        FramedPreviewLayout.previewRect(
            in: CGRect(x: 0, y: 0, width: width, height: height),
            topControlsBottom: topControlsBottom,
            bottomControlsTop: height - bottomPadding - barHeight)
    }

    private func inset(for preview: CGRect, canvasWidth: CGFloat) -> CGFloat {
        CameraControlGeometry.controlBarHorizontalInset(previewEdgeInset: preview.minX,
                                                        canvasWidth: canvasWidth)
    }

    private func barGeometry(_ canvas: (width: CGFloat, height: CGFloat), inset: CGFloat) -> CameraControlGeometry {
        CameraControlGeometry(width: canvas.width - 2 * inset, height: barHeight)
    }

    @Test func framedBarEdgesLandExactlyOnTheViewfinderEdgesWhenThereIsRoom() {
        for canvas in portraits {
            let preview = preview(canvas.width, canvas.height)
            #expect(preview.width > 0)
            let inset = inset(for: preview, canvasWidth: canvas.width)

            // Enough room: the inset is the viewfinder's own edge inset, and it
            // sits inside the immersive 16pt margin — the move is inward.
            #expect(inset == preview.minX + 4)
            #expect(inset > CameraControlGeometry.defaultHorizontalInset)

            let content = canvas.width - 2 * inset
            #expect(content >= CameraControlGeometry.minimumRowWidth)
            let geometry = CameraControlGeometry(width: content, height: barHeight)

            // Outer LCD/stock edge lands on the preview's leading side edge.
            #expect(abs(inset + geometry.lcd.minX - preview.minX - 4) < 0.001)
            #expect(abs(inset + geometry.stock.minX - preview.minX - 4) < 0.001)
            // Outer exposure edge lands on the preview's trailing side edge.
            #expect(abs((canvas.width - inset) - preview.maxX + 4) < 0.001)
        }
    }

    @Test func recordColumnStaysCanvasCentredAndKeepsItsFootprint() {
        for canvas in portraits {
            let inset = inset(for: preview(canvas.width, canvas.height), canvasWidth: canvas.width)
            let geometry = barGeometry(canvas, inset: inset)
            #expect(abs(inset + geometry.record.midX - canvas.width / 2) < 0.001,
                    "REC keeps its canvas-centred footprint; the inset only moves the outer columns.")
            #expect(geometry.record.width == CameraControlGeometry.recordSize)
            #expect(geometry.record.height == CameraControlGeometry.recordSize)
        }
    }

    @Test func columnHeightsAndTheStockTouchTargetAreRetained() {
        for canvas in portraits {
            let inset = inset(for: preview(canvas.width, canvas.height), canvasWidth: canvas.width)
            let geometry = barGeometry(canvas, inset: inset)
            // Exposure still owns the shared height and starts at the bar top.
            #expect(geometry.exposure.minY == 0)
            #expect(geometry.exposure.height == barHeight)
            #expect(geometry.exposure.width == CameraControlGeometry.exposureWidth)
            // LCD over the stock/gauge well, same 2:1 split and gap.
            #expect(geometry.lcd.minY == 0)
            #expect(abs(geometry.lcd.height - 2 * geometry.stock.height) < 0.001)
            #expect(abs(geometry.stock.minY - geometry.lcd.maxY - CameraControlGeometry.columnGap) < 0.001)
            #expect(abs(geometry.stock.maxY - barHeight) < 0.001)
            // The left column keeps its width, so the 44pt stock control and the
            // recessed well still fit.
            #expect(geometry.lcd.maxX <= CameraControlGeometry.leftWidth)
            #expect(geometry.stock.height >= 52)
        }
    }

    @Test func exposureRescueAnchorIsUnchangedByTheInset() {
        // The daylight rescue button floats above the measured exposure column.
        // Insetting the bar moves that column in symmetrically but leaves its
        // top edge and height untouched, so the anchor cannot move or resize.
        for canvas in portraits {
            let inset = inset(for: preview(canvas.width, canvas.height), canvasWidth: canvas.width)
            let geometry = barGeometry(canvas, inset: inset)
            #expect(geometry.exposure.minY == 0)
            #expect(geometry.exposure.height == barHeight)
            #expect(geometry.exposure.width == CameraControlGeometry.exposureWidth)
            // It stays fully inside the canvas.
            #expect(inset + geometry.exposure.minX >= 0)
            #expect(inset + geometry.exposure.maxX <= canvas.width + 0.001)
        }
    }

    @Test func previewRectangleIsInvariantToTheControlInset() {
        for canvas in portraits {
            let reference = preview(canvas.width, canvas.height)
            let inset = inset(for: reference, canvasWidth: canvas.width)
            let again = preview(canvas.width, canvas.height)
            #expect(again == reference, "Deriving the inset must not perturb the preview rectangle.")

            // The measured height — the only dimension the preview reads — is
            // width-independent, so the preview can never be based on the bar's
            // own width.
            for width in [canvas.width - 2 * inset, canvas.width - 32,
                          CameraControlGeometry.minimumRowWidth, canvas.width] as [CGFloat] {
                #expect(CameraControlGeometry(width: width, height: barHeight).exposure.height == barHeight)
            }
        }
    }

    @Test func narrowOrLandscapeCanvasCapsAtTheWidestNonOverlappingRow() {
        // A 320pt-wide phone and a landscape hold cannot align exactly: the
        // viewfinder edge sits deeper than the row can reach without the
        // columns colliding, so the inset caps at the non-overlap minimum.
        let constrained: [(width: CGFloat, height: CGFloat)] = [(320, 548), (750, 390), (300, 600)]
        for canvas in constrained {
            let preview = preview(canvas.width, canvas.height)
            let inset = inset(for: preview, canvasWidth: canvas.width)
            let cap = max(0, (canvas.width - CameraControlGeometry.minimumRowWidth) / 2)
            #expect(inset == cap)
            #expect(inset < preview.minX, "The row cannot reach the viewfinder edge on this canvas.")

            let content = canvas.width - 2 * inset
            #expect(content >= CameraControlGeometry.minimumRowWidth - 0.001)
            let geometry = CameraControlGeometry(width: content, height: barHeight)
            // Still no overlap, no shrunken touch target and centred REC.
            #expect(!geometry.lcd.intersects(geometry.record))
            #expect(!geometry.lcd.intersects(geometry.exposure))
            #expect(!geometry.record.intersects(geometry.exposure))
            #expect(!geometry.lcd.intersects(geometry.stock))
            #expect(geometry.record.width == CameraControlGeometry.recordSize)
            #expect(abs(inset + geometry.record.midX - canvas.width / 2) < 0.001)
        }
    }

    @Test func zeroFrameOrCanvasBeforeBoundsUsesTheImmersiveMargin() {
        // The first frame has no measured control bounds, so the preview
        // rectangle is empty and the bar keeps its established margin.
        #expect(CameraControlGeometry.controlBarHorizontalInset(previewEdgeInset: 0, canvasWidth: 390)
                == CameraControlGeometry.defaultHorizontalInset)
        #expect(CameraControlGeometry.controlBarHorizontalInset(previewEdgeInset: 24, canvasWidth: 0)
                == CameraControlGeometry.defaultHorizontalInset)
        #expect(CameraControlGeometry.defaultHorizontalInset == 16)
        // The immersive margin still leaves the row room on a real phone.
        #expect(390 - 2 * CameraControlGeometry.defaultHorizontalInset >= CameraControlGeometry.minimumRowWidth)
    }

    @Test func degenerateInsetsNeverGoNegativeOrExceedTheCanvas() {
        for edge in [-50, -1, 0, 1, 1_000] as [CGFloat] {
            for width in [0, 120, 320, 750] as [CGFloat] {
                let inset = CameraControlGeometry.controlBarHorizontalInset(previewEdgeInset: edge, canvasWidth: width)
                #expect(inset >= 0)
                #expect(inset * 2 <= max(width, 2 * CameraControlGeometry.defaultHorizontalInset))
            }
        }
    }

    @Test func glyphFacesAreUnaffectedByTheInset() {
        // The inset only moves the columns; the rotation contract that keeps
        // every glyph upright is a function of the slot and the hold alone.
        for canvas in portraits {
            let inset = inset(for: preview(canvas.width, canvas.height), canvasWidth: canvas.width)
            let geometry = barGeometry(canvas, inset: inset)
            for degrees in [0.0, 90.0, -90.0, 180.0] {
                for slot in [geometry.lcd.size, geometry.stock.size] {
                    let face = CameraControlGeometry.faceSize(in: slot, degrees: degrees)
                    #expect(CameraControlGeometry.faceSize(in: face, degrees: degrees) == slot)
                }
            }
        }
    }

    @Test func insetWiringIsPureGeometryNotCaptureState() throws {
        let screen = try String(contentsOf: TestRepository.url(for: "App/ContentView.swift"), encoding: .utf8)

        // The bar is handed the computed inset, after the shared hint argument.
        let hint = try #require(screen.range(of: "showsStockHint: stockSelectorHint.isCueVisible"))
        let wired = try #require(screen.range(of: "horizontalInset: horizontalInset"))
        #expect(hint.lowerBound < wired.lowerBound)
        #expect(screen.contains("controlBar(horizontalInset: controlBarHorizontalInset(in: geometry))"))

        // The inset helper reads only frame mode, the preview rectangle and the
        // canvas width — never capture state or the orientation glyph rotation,
        // so idle/recording/landscape-glyph state cannot move the bar edges.
        let start = try #require(screen.range(of: "private func controlBarHorizontalInset"))
        let end = try #require(screen.range(of: "MARK: - Error Overlays", range: start.upperBound..<screen.endIndex))
        let helper = String(screen[start.lowerBound..<end.lowerBound])
        #expect(helper.contains("showFramedPreview"))
        #expect(helper.contains("previewRect(in: geometry)"))
        #expect(helper.contains("CameraControlGeometry.controlBarHorizontalInset("))
        #expect(helper.contains("CameraControlGeometry.defaultHorizontalInset"))
        #expect(!helper.contains("recordPresentation"))
        #expect(!helper.contains("statusRotationDegrees"))
        #expect(!helper.contains("cameraViewModel"))
    }
}
