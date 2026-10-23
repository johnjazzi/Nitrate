import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import Testing

/// Pure geometry for the in-frame rulers plus the composed native render that
/// proves the real slots bound their content. These are the placement rules the
/// live screen feeds with the preview rectangle and the measured control
/// bounds; they never read a ruler's own size, so no view-measurement feedback
/// is involved.
///
/// The two rulers now hug the frame's physical left and right sides: the zoom
/// ruler on the physical left, the manual-focus ruler on the physical right.
/// Both are vertical rails in portrait and in either landscape hold.
struct FrameRulerPlacementTests {
    private let frame = CGRect(x: 40, y: 120, width: 300, height: 520)

    // MARK: - Edge mapping

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

    @Test func physicalLeftEdgeIsTheMirrorOfThePhysicalRight() {
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .left, orientationDegrees: 0) == .left)
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .left, orientationDegrees: 90) == .top)
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .left, orientationDegrees: -90) == .bottom)
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .left, orientationDegrees: 180) == .right)
    }

    @Test func nonFiniteOrientationFallsBackToPortrait() {
        #expect(FrameRulerPlacementGeometry.normalized(.nan) == 0)
        #expect(FrameRulerPlacementGeometry.normalized(.infinity) == 0)
        #expect(FrameRulerPlacementGeometry.normalized(-0.0) == 0)
        #expect(FrameRulerPlacementGeometry.normalized(450) == 90)
        #expect(FrameRulerPlacementGeometry.normalized(-450) == -90)
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .right, orientationDegrees: .nan) == .right)
        #expect(FrameRulerPlacementGeometry.canvasEdge(for: .left, orientationDegrees: .nan) == .left)
    }

    // MARK: - Placement

    @Test func portraitRulersHugOppositeVerticalEdgesFlushToTheFrame() {
        let focus = FrameRulerPlacementGeometry.rect(
            inFrame: frame, edge: .right, thickness: FrameRulerPlacementGeometry.focusThickness,
            orientationDegrees: 0)
        #expect(focus.width == FrameRulerPlacementGeometry.focusThickness)
        #expect(focus.height > focus.width, "the focus ruler is a tall vertical rail in portrait")
        #expect(focus.maxX <= frame.maxX && focus.minX >= frame.minX)
        #expect(focus.minY >= frame.minY && focus.maxY <= frame.maxY)
        // The margin is zero: the slot runs flush to the physical right edge.
        #expect(FrameRulerPlacementGeometry.margin == 0)
        #expect(focus.maxX == frame.maxX, "the focus ruler runs flush to the physical right edge")
        #expect(focus.minY == frame.minY && focus.maxY == frame.maxY)

        let zoom = FrameRulerPlacementGeometry.rect(
            inFrame: frame, edge: .left, thickness: FrameRulerPlacementGeometry.zoomThickness,
            orientationDegrees: 0)
        #expect(zoom.width == FrameRulerPlacementGeometry.zoomThickness)
        #expect(zoom.height > zoom.width, "the zoom ruler is a tall vertical rail in portrait")
        #expect(zoom.minX >= frame.minX && zoom.maxX <= frame.maxX)
        #expect(zoom.minX == frame.minX, "the zoom ruler runs flush to the physical left edge")
        #expect(zoom.minY == frame.minY && zoom.maxY == frame.maxY)

        // The two rails are on opposite sides and cannot overlap.
        #expect(!zoom.intersects(focus))
        #expect(zoom.maxX < focus.minX)
    }

    /// The visible rail is narrower than the 44pt touch footprint, and the slot
    /// itself keeps the full 44pt so the tap target is unchanged and the rail
    /// runs flush to the preview edge rather than leaving a centered gap.
    @Test func visibleRailIsNarrowerThanItsTouchFootprint() {
        let visual = FrameRulerPlacementGeometry.rulerVisualThickness
        #expect(FrameRulerPlacementGeometry.visualFraction == 0.8)
        #expect(abs(visual - 35.2) < 0.0001, "the visible rail is 80% of the 44pt slot")
        #expect(visual < FrameRulerPlacementGeometry.focusThickness)
        #expect(FrameRulerPlacementGeometry.focusThickness == 44)
        // The granted slot keeps the full 44pt footprint.
        let rect = FrameRulerPlacementGeometry.rect(inFrame: frame, edge: .right,
                                                    thickness: FrameRulerPlacementGeometry.focusThickness,
                                                    orientationDegrees: 0)
        #expect(rect.width == 44)
    }

    @Test func everyHoldStaysWithinTheFrameAndKeepsTheThickness() {
        for degrees in [0.0, 90.0, -90.0, 180.0] {
            for edge in [FrameRulerPlacementGeometry.PhysicalEdge.left,
                         FrameRulerPlacementGeometry.PhysicalEdge.right] {
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

    @Test func bothRulersSitOnThePhysicalLeftAndRightSidesInEveryHold() {
        let physicalTurn: (Double) -> CGAffineTransform = { CGAffineTransform(rotationAngle: -$0 * .pi / 180) }
        func physical(_ point: CGPoint, degrees: Double) -> CGPoint {
            CGPoint(x: point.x - frame.midX, y: point.y - frame.midY).applying(physicalTurn(degrees))
        }
        for degrees in [0.0, 90.0, -90.0] {
            let zoom = FrameRulerPlacementGeometry.rect(inFrame: frame, edge: .left, thickness: 44,
                                                        orientationDegrees: degrees)
            let focus = FrameRulerPlacementGeometry.rect(inFrame: frame, edge: .right, thickness: 44,
                                                         orientationDegrees: degrees)
            let zoomCenter = physical(CGPoint(x: zoom.midX, y: zoom.midY), degrees: degrees)
            let focusCenter = physical(CGPoint(x: focus.midX, y: focus.midY), degrees: degrees)
            #expect(zoomCenter.x < 0, "the zoom ruler must be on the physical left at \(degrees)")
            #expect(focusCenter.x > 0, "the focus ruler must be on the physical right at \(degrees)")

            // The long axis of each rail maps to the physical vertical.
            for rect in [zoom, focus] {
                let horizontal = rect.width >= rect.height
                let start = CGPoint(x: rect.minX, y: rect.minY)
                let longEnd = horizontal ? CGPoint(x: rect.maxX, y: rect.minY)
                                         : CGPoint(x: rect.minX, y: rect.maxY)
                let physicalEnd = physical(longEnd, degrees: degrees)
                let physicalStart = physical(start, degrees: degrees)
                let delta = CGPoint(x: physicalEnd.x - physicalStart.x,
                                    y: physicalEnd.y - physicalStart.y)
                #expect(abs(delta.y) > abs(delta.x),
                        "the rail's long axis must be vertical on the physical frame at \(degrees)")
            }
        }
    }

    @Test func leftAndRightRulersNeverOverlapInSupportedHoldsAndSmallViewports() {
        // Portrait previews and the cramped small-device frames, clipped to the
        // band between the toolbar and the shooting bar as the screen does.
        let frames = [
            frame,
            CGRect(x: 0, y: 100, width: 320, height: 360),
            CGRect(x: 0, y: 120, width: 390, height: 520),
            CGRect(x: 40, y: 120, width: 200, height: 300),
        ]
        for bounds in frames {
            for degrees in [0.0, 90.0, -90.0] {
                let zoom = FrameRulerPlacementGeometry.rect(inFrame: bounds, edge: .left, thickness: 44,
                                                            orientationDegrees: degrees)
                let focus = FrameRulerPlacementGeometry.rect(inFrame: bounds, edge: .right, thickness: 44,
                                                             orientationDegrees: degrees)
                let bothPresent = !zoom.isNull && !focus.isNull
                if bothPresent {
                    #expect(!zoom.intersects(focus),
                            "zoom and focus must stay disjoint at \(degrees) in \(bounds)")
                }
            }
        }
    }

    @Test func narrowFramesNeverPushRulersOutsideThePreview() {
        let narrow = CGRect(x: 0, y: 0, width: 30, height: 400)
        #expect(FrameRulerPlacementGeometry.rect(
            inFrame: narrow, edge: .right, thickness: 44, orientationDegrees: 0).isNull)
        #expect(FrameRulerPlacementGeometry.rect(
            inFrame: narrow, edge: .left, thickness: 44, orientationDegrees: 0).isNull)
    }

    @Test func degenerateFrameOrThicknessProducesNoRuler() {
        #expect(FrameRulerPlacementGeometry.rect(inFrame: .zero, edge: .right,
                                                 thickness: 44, orientationDegrees: 0).isNull)
        #expect(FrameRulerPlacementGeometry.rect(inFrame: frame, edge: .left,
                                                 thickness: 0, orientationDegrees: 0).isNull)
        // A frame no wider than the ruler's own margins cannot host one.
        let sliver = CGRect(x: 0, y: 0, width: 10, height: 400)
        #expect(FrameRulerPlacementGeometry.rect(
            inFrame: sliver, edge: .left, thickness: 44, orientationDegrees: 0).isNull)
    }

    // MARK: - Composed native render

    /// The live composition, reduced to geometry: preview clipped to the band
    /// between the toolbar and the shooting bar, then the two slots. Rendering
    /// the real `FrameRulerSlot` proves the captured size and position hold the
    /// coloured content inside each rect, and that the two never overlap.
    @MainActor @Test func composedSlotsRenderRealContentInsideTheirRectsAndNeverOverlap() throws {
        let viewport = CGSize(width: 390, height: 763)
        for degrees in [0.0, 90.0, -90.0] {
            let preview = CGRect(origin: .zero, size: viewport)
            let top: CGFloat = 110
            let bottom: CGFloat = 583
            let safe = CGRect(x: 0, y: top, width: viewport.width, height: bottom - top)
            let bounds = preview.intersection(safe)
            let zoomRect = FrameRulerPlacementGeometry.rect(inFrame: bounds, edge: .left, thickness: 44,
                                                            orientationDegrees: degrees)
            let focusRect = FrameRulerPlacementGeometry.rect(inFrame: bounds, edge: .right, thickness: 44,
                                                             orientationDegrees: degrees)
            #expect(!zoomRect.isNull && !focusRect.isNull)
            #expect(!zoomRect.intersects(focusRect))

            let view = ZStack {
                Color.black
                FrameRulerSlot(rect: zoomRect, rotationDegrees: degrees) {
                    Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1)
                }
                FrameRulerSlot(rect: focusRect, rotationDegrees: degrees) {
                    Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
                }
            }
            .frame(width: viewport.width, height: viewport.height)

            let image = try bitmap(view, size: viewport)
            let scale = CGFloat(image.width) / viewport.width
            let red = try ink(image) { $0.red > 0.8 && $0.green < 0.3 && $0.blue < 0.3 }
            let blue = try ink(image) { $0.blue > 0.8 && $0.red < 0.3 && $0.green < 0.3 }
            #expect(red.count > 500 && blue.count > 500, "both slot markers must render real ink at \(degrees)")

            func point(_ pixel: (x: Int, y: Int)) -> CGPoint {
                CGPoint(x: CGFloat(pixel.x) / scale, y: CGFloat(pixel.y) / scale)
            }
            let focusBounds = focusRect.insetBy(dx: -1, dy: -1)
            let zoomBounds = zoomRect.insetBy(dx: -1, dy: -1)
            #expect(red.allSatisfy { focusBounds.contains(point($0)) },
                    "focus content must stay inside its slot at \(degrees)")
            #expect(blue.allSatisfy { zoomBounds.contains(point($0)) },
                    "zoom content must stay inside its slot at \(degrees)")
        }
    }

    /// The real vertical zoom ruler must render visible ticks, arrows and the
    /// focal readout inside its 44pt column, for the extremes of the focal
    /// range, without any horizontal overflow into the frame.
    @MainActor @Test func realZoomRulerRendersBoundedContentInsideItsColumn() throws {
        let rect = CGRect(x: 20, y: 100, width: 44, height: 300)
        let canvas = CGSize(width: 200, height: 500)
        for millimeters in [13.0, 35.0, 150.0, 350.0, 384.0, 400.0] {
            let view = ZStack {
                Color.black
                FrameRulerSlot(rect: rect, rotationDegrees: 0) {
                    FrameZoomRuler(millimeters: millimeters, enabled: true, revision: 1,
                                   begin: { _ in }, end: { _ in }, step: { _ in })
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            let image = try bitmap(view, size: canvas)
            let scale = CGFloat(image.width) / canvas.width
            let bright = try ink(image) { $0.red > 0.75 && $0.green > 0.75 && $0.blue > 0.75 }
            #expect(bright.filter { CGFloat($0.y) / scale < rect.minY + 44 }.count > 5,
                    "the upper zoom arrow must remain visible")
            #expect(bright.filter { CGFloat($0.y) / scale > rect.maxY - 44 }.count > 5,
                    "the lower zoom arrow must remain visible")
            #expect(bright.filter {
                let y = CGFloat($0.y) / scale
                return y > rect.minY + 60 && y < rect.maxY - 60
            }.count > 3, "the zoom rail must retain labeled ticks at \(millimeters) mm")
            let bounds = rect.insetBy(dx: -1, dy: -1)
            #expect(bright.allSatisfy { bounds.contains(CGPoint(x: CGFloat($0.x) / scale,
                                                               y: CGFloat($0.y) / scale)) },
                    "the zoom ruler must stay inside its 44pt slot at \(millimeters)mm")
        }
    }

    @MainActor @Test func realRulersWithStopsStayInsideOppositeSlotsInEveryHold() throws {
        let viewport = CGSize(width: 390, height: 763)
        let bounds = CGRect(x: 30, y: 110, width: 330, height: 473)
        for degrees in [0.0, 90.0, -90.0] {
            let zoom = FrameRulerPlacementGeometry.rect(inFrame: bounds, edge: .left,
                                                        thickness: 44, orientationDegrees: degrees)
            let focus = FrameRulerPlacementGeometry.rect(inFrame: bounds, edge: .right,
                                                         thickness: 44, orientationDegrees: degrees)
            let view = ZStack {
                Color.black
                FrameRulerSlot(rect: zoom, rotationDegrees: degrees) {
                    FrameZoomRuler(millimeters: 384, enabled: true, revision: 1,
                                   begin: { _ in }, end: { _ in }, step: { _ in },
                                   availableFocalRange: 96...384)
                }
                FrameRulerSlot(rect: focus, rotationDegrees: degrees) {
                    ManualFocusRuler(lensPosition: .constant(0.5), enabled: true,
                                     stops: .constant([ManualFocusStop(lensPosition: 0.25),
                                                       ManualFocusStop(lensPosition: 0.75)]))
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            let image = try bitmap(view, size: viewport, name: "real-rulers-\(degrees)")
            let scale = CGFloat(image.width) / viewport.width
            let visible = try ink(image) { $0.red + $0.green + $0.blue > 0.9 }
            func inside(_ rect: CGRect, _ pixel: (x: Int, y: Int)) -> Bool {
                rect.insetBy(dx: -1, dy: -1).contains(
                    CGPoint(x: CGFloat(pixel.x) / scale, y: CGFloat(pixel.y) / scale))
            }
            #expect(!zoom.intersects(focus))
            #expect(visible.filter { inside(zoom, $0) }.count > 50)
            #expect(visible.filter { inside(focus, $0) }.count > 50)
            #expect(visible.allSatisfy { inside(zoom, $0) || inside(focus, $0) },
                    "the actual rails, stops and arrows must stay inside their separate slots")
        }
    }

    /// The new default composition: the right slot stacks the narrow
    /// manual-focus rail above three 44pt inline buttons, and the left slot
    /// carries the narrow zoom rail. Rendering the real `FrameRulerSlot` at
    /// portrait, both landscape holds and a narrow phone proves the stack stays
    /// inside its own slot — nothing clips into the live frame — and that the
    /// two slots never overlap.
    @MainActor @Test func realRightStackAndNarrowRailsStayInsideTheirSlots() throws {
        let compositions: [(canvas: CGSize, bounds: CGRect)] = [
            (CGSize(width: 390, height: 763), CGRect(x: 30, y: 110, width: 330, height: 473)),
            (CGSize(width: 320, height: 568), CGRect(x: 0, y: 100, width: 320, height: 340)),
        ]
        let visual = FrameRulerPlacementGeometry.rulerVisualThickness
        for composition in compositions {
            let canvas = composition.canvas
            let bounds = composition.bounds
            for degrees in [0.0, 90.0, -90.0] {
                let zoom = FrameRulerPlacementGeometry.rect(
                    inFrame: bounds, edge: .left,
                    thickness: FrameRulerPlacementGeometry.zoomThickness,
                    orientationDegrees: degrees)
                let focus = FrameRulerPlacementGeometry.rect(
                    inFrame: bounds, edge: .right,
                    thickness: FrameRulerPlacementGeometry.focusThickness,
                    orientationDegrees: degrees)
                #expect(!zoom.isNull && !focus.isNull)
                #expect(!zoom.intersects(focus),
                        "the narrow rails must stay disjoint at \(degrees) in \(bounds)")

                let view = ZStack {
                    Color.black
                    FrameRulerSlot(rect: zoom, rotationDegrees: degrees) {
                        FrameZoomRuler(millimeters: 384, enabled: true, revision: 1,
                                       begin: { _ in }, end: { _ in }, step: { _ in },
                                       availableFocalRange: 96...384, visualWidth: visual)
                    }
                    FrameRulerSlot(rect: focus, rotationDegrees: degrees) {
                        VStack(spacing: 4) {
                            ManualFocusRuler(lensPosition: .constant(0.5), enabled: true,
                                             stops: .constant([ManualFocusStop(lensPosition: 0.3)]),
                                             visualWidth: visual)
                                .frame(maxHeight: .infinity)
                            // The inline button stack the right slot reserves
                            // even in autofocus: three 44pt controls.
                            VStack(spacing: 0) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 1)
                                        .frame(width: 44, height: 44)
                                }
                            }
                        }
                    }
                }
                .frame(width: canvas.width, height: canvas.height)

                let image = try bitmap(view, size: canvas,
                                       name: "right-stack-\(Int(canvas.width))-\(Int(degrees))")
                let scale = CGFloat(image.width) / canvas.width
                func inside(_ rect: CGRect, _ pixel: (x: Int, y: Int)) -> Bool {
                    rect.insetBy(dx: -1, dy: -1).contains(
                        CGPoint(x: CGFloat(pixel.x) / scale, y: CGFloat(pixel.y) / scale))
                }
                let visible = try ink(image) { $0.red + $0.green + $0.blue > 0.9 }
                #expect(visible.allSatisfy { inside(zoom, $0) || inside(focus, $0) },
                        "the real rails, stops and buttons must stay inside their separate slots at \(degrees)")
                #expect(visible.filter { inside(zoom, $0) }.count > 50,
                        "the zoom rail must render real ink at \(degrees)")
                #expect(visible.filter { inside(focus, $0) }.count > 50,
                        "the focus rail and button stack must render real ink at \(degrees)")
            }
        }
    }

    // MARK: - Render helpers
    @MainActor private func bitmap<V: View>(_ view: V, size: CGSize, name: String? = nil) throws -> CGImage {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try #require(rep.cgImage)
        if let name {
            let directory = TestRepository.artifactDirectory("frame-ruler-renders")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(name).png")
            let destination = try #require(CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        return image
    }

    private struct RGB { let red: CGFloat; let green: CGFloat; let blue: CGFloat }

    private func ink(_ image: CGImage, where matches: (RGB) -> Bool) throws -> [(x: Int, y: Int)] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var hits: [(x: Int, y: Int)] = []
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = RGB(red: CGFloat(pixels[index]) / 255,
                          green: CGFloat(pixels[index + 1]) / 255,
                          blue: CGFloat(pixels[index + 2]) / 255)
            guard pixels[index + 3] > 220, matches(rgb) else { continue }
            hits.append(((index / 4) % image.width, (index / 4) / image.width))
        }
        return hits
    }
}
