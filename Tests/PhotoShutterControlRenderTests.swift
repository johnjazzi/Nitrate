import AppKit
import SwiftUI
import Testing

struct PhotoShutterControlRenderTests {
    @Test @MainActor func sharedRulerSupportsHorizontalWithoutChangingDefaultVerticalBounds() throws {
        for horizontal in [false, true] {
            let ruler = RulerSlider(value: .constant(1.0 / 30), range: 0.000014...1,
                step: 1, pointsPerStep: 12, length: 160, width: 44,
                orientation: horizontal ? .horizontal : .vertical)
            let renderer = ImageRenderer(content: ruler)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(image.width == (horizontal ? 160 : 44))
            #expect(image.height == (horizontal ? 44 : 160))
        }
    }

    /// The old horizontal mapping moved the tick strip against the finger. A
    /// dial turns with it: dragging toward the longer ticks (rightward) brings
    /// the shorter neighbour under the pointer.
    @Test func aRightwardDragShortensTheShutterLikeTurningADial() {
        let range = 1.0 / 8000.0...1.0
        let ladder = PhotoShutterPresentation.detents(in: range)
        let scale = RulerScale.logarithmic(pointsPerStop: RulerScale.detentTravel * 3)
        let detents = RulerDetents(scale: scale, range: range, step: 1,
                                   anchor: range.lowerBound, ladder: ladder)
        let start = 1.0 / 30.0
        let bounds = scale.toPosition(range.lowerBound)...scale.toPosition(range.upperBound)
        var drag = RulerDragState()

        // One stop (36pt) right is one stop shorter under the reversed dial.
        let right = RulerDragDirection(horizontal: true, reversed: true).travel(width: 36, height: 0)
        let rightPosition = drag.update(valuePosition: scale.toPosition(start),
                                        translation: right, bounds: bounds)
        #expect(detents.changedValue(from: start, to: scale.fromPosition(rightPosition)) == 1.0 / 60.0)
        drag.end()

        // The mirror gesture lengthens it.
        let left = RulerDragDirection(horizontal: true, reversed: true).travel(width: -36, height: 0)
        let leftPosition = drag.update(valuePosition: scale.toPosition(start),
                                       translation: left, bounds: bounds)
        #expect(detents.changedValue(from: start, to: scale.fromPosition(leftPosition)) == 1.0 / 15.0)
    }

    /// The rail behind the shutter ruler is the same dark translucent plate the
    /// manual focus and zoom rulers draw, not the light inset control surface.
    @Test func shutterRailReusesTheManualRulerBackground() throws {
        let control = try String(contentsOf: TestRepository.root
            .appendingPathComponent("App/Modules/CameraCapture/PhotoShutterControl.swift"), encoding: .utf8)
        let focus = try String(contentsOf: TestRepository.root
            .appendingPathComponent("App/Modules/CameraCapture/ManualFocusRuler.swift"), encoding: .utf8)
        #expect(focus.contains("RoundedRectangle(cornerRadius: 8)"))
        #expect(focus.contains(".black.opacity(0.45)"))
        #expect(control.contains("cornerRadius: 8"))
        #expect(control.contains(".black.opacity(0.45)"))
        #expect(!control.contains("CameraInsetSurface()"))
    }

    @Test @MainActor func horizontalRailFitsItsDeclaredBounds() throws {
        let state = PhotoExposureSnapshot(iso: 400, durationSeconds: 1.0 / 30,
            isoRange: 55...12320, shutterRange: 0.000014...1,
            isoLocked: false, shutterLocked: false, ev: 0, meteringOffset: -0.1,
            isSettling: false, canCapture: true, targetLimited: false)
        let view = PhotoShutterControl(snapshot: state, setDuration: { _ in },
            setLocked: { _ in }, width: 280)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try #require(renderer.cgImage)
        #expect(image.width == 840)
        #expect(image.height == 168)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/cache/scratch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("photo-shutter-horizontal-verified.png"))
    }
}
