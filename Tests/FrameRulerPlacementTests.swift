import CoreGraphics
import Testing

/// Pure geometry for the in-frame rulers. These are the placement rules the
/// live screen feeds with the preview rectangle and the measured control
/// bounds; they never read a ruler's own size, so no view-measurement feedback
/// is involved.
struct FrameRulerPlacementTests {
    private let frame = CGRect(x: 40, y: 120, width: 300, height: 520)

    @Test func physicalRightEdgeMapsToThePhysicalHold() {
        // Portrait keeps the physical right on the canvas right.
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .right, orientationDegrees: 0) == .right)
        // A +90° hold turns the portrait right edge onto the physical top, so
        // the physical right edge is the canvas bottom.
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .right, orientationDegrees: 90) == .bottom)
        // The -90° hold is the mirror image: the physical right is the canvas top.
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .right, orientationDegrees: -90) == .top)
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .right, orientationDegrees: 180) == .left)
    }

    @Test func physicalBottomEdgeMatchesTheManualPanelConvention() {
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .bottom, orientationDegrees: 0) == .bottom)
        // Mirrors ManualControlsOverlayGeometry: +90° puts the physical bottom
        // on portrait left, -90° on portrait right.
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .bottom, orientationDegrees: 90) == .left)
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .bottom, orientationDegrees: -90) == .right)
    }

    @Test func nonFiniteOrientationFallsBackToPortrait() {
        #expect(FrameRulerPlacementGeometry.normalized(.nan) == 0)
        #expect(FrameRulerPlacementGeometry.normalized(.infinity) == 0)
        #expect(FrameRulerPlacementGeometry.normalized(-0.0) == 0)
        #expect(FrameRulerPlacementGeometry.normalized(450) == 90)
        #expect(FrameRulerPlacementGeometry.normalized(-450) == -90)
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .right, orientationDegrees: .nan) == .right)
    }

    @Test func portraitRulersHugTheRightAndBottomEdgesInsideTheFrame() {
        let focus = FrameRulerPlacementGeometry.rect(
            inFrame: frame, edge: .right, thickness: FrameRulerPlacementGeometry.focusThickness,
            orientationDegrees: 0)
        #expect(focus.width == FrameRulerPlacementGeometry.focusThickness)
        #expect(focus.maxX <= frame.maxX && focus.minX >= frame.minX)
        #expect(focus.minY >= frame.minY && focus.maxY <= frame.maxY)
        #expect(abs(focus.maxX - (frame.maxX - FrameRulerPlacementGeometry.margin)) < 0.001,
                "the focus ruler sits inset from the physical right edge")

        let zoom = FrameRulerPlacementGeometry.rect(
            inFrame: frame, edge: .bottom, thickness: FrameRulerPlacementGeometry.zoomThickness,
            orientationDegrees: 0)
        #expect(zoom.height == FrameRulerPlacementGeometry.zoomThickness)
        #expect(zoom.width > zoom.height, "the zoom ruler is a wide strip along the bottom")
        #expect(zoom.minX >= frame.minX && zoom.maxX <= frame.maxX)
        #expect(abs(zoom.maxY - (frame.maxY - FrameRulerPlacementGeometry.margin)) < 0.001)
    }

    @Test func everyHoldStaysWithinTheFrameAndKeepsTheThickness() {
        for degrees in [0.0, 90.0, -90.0, 180.0] {
            for edge in [FrameRulerPlacementGeometry.PhysicalEdge.right,
                         FrameRulerPlacementGeometry.PhysicalEdge.bottom] {
                let rect = FrameRulerPlacementGeometry.rect(
                    inFrame: frame, edge: edge, thickness: 44, orientationDegrees: degrees)
                #expect(!rect.isNull)
                #expect(rect.minX >= frame.minX - 0.001 && rect.maxX <= frame.maxX + 0.001,
                        "\(edge) at \(degrees) must stay inside the frame horizontally")
                #expect(rect.minY >= frame.minY - 0.001 && rect.maxY <= frame.maxY + 0.001,
                        "\(edge) at \(degrees) must stay inside the frame vertically")
                #expect(min(rect.width, rect.height) == 44,
                        "the ruler keeps its 44pt thickness on a canvas axis")
            }
        }
    }

    @Test func focusAndZoomNeverOverlapInAnyHold() {
        for degrees in [0.0, 90.0, -90.0, 180.0] {
            let focus = FrameRulerPlacementGeometry.rect(
                inFrame: frame, edge: .right, thickness: 44, orientationDegrees: degrees,
                bottomClearance: 52)
            let zoom = FrameRulerPlacementGeometry.rect(
                inFrame: frame, edge: .bottom, thickness: 44, orientationDegrees: degrees)
            #expect(!focus.isNull && !zoom.isNull)
            #expect(!focus.intersects(zoom))
        }
    }

    @Test func narrowFramesNeverPushFocusOutsideThePreview() {
        let narrow = CGRect(x: 0, y: 0, width: 30, height: 400)
        #expect(FrameRulerPlacementGeometry.rect(
            inFrame: narrow, edge: .right, thickness: 44, orientationDegrees: 0).isNull)
    }

    @Test func degenerateFrameOrThicknessProducesNoRuler() {
        #expect(FrameRulerPlacementGeometry.rect(inFrame: .zero, edge: .right,
                                                 thickness: 44, orientationDegrees: 0).isNull)
        #expect(FrameRulerPlacementGeometry.rect(inFrame: frame, edge: .right,
                                                 thickness: 0, orientationDegrees: 0).isNull)
        // A frame no wider than the ruler's own margins cannot host one.
        let sliver = CGRect(x: 0, y: 0, width: 10, height: 400)
        #expect(FrameRulerPlacementGeometry.rect(
            inFrame: sliver, edge: .bottom, thickness: 44, orientationDegrees: 0).isNull)
    }
}
