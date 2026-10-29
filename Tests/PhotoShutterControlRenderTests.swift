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
