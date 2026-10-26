import CoreGraphics
import Foundation
import SwiftUI
import Testing

@Suite("Develop progress overlay")
struct DevelopProgressOverlayTests {
    // MARK: - Presentation policy

    @Test func determinateOnlyForAGenuineRenderingFraction() {
        #expect(DevelopProgressPresentation(progress: nil, queued: false).isDeterminate == false)
        #expect(DevelopProgressPresentation(progress: nil, queued: true).fraction == nil)

        let rendering = DevelopProgressPresentation(
            progress: RenderJobProgress(phase: .rendering, fractionComplete: 0.42), queued: false)
        #expect(rendering.fraction == 0.42)
        #expect(rendering.isDeterminate)
        #expect(rendering.caption == "Rendering… 42%")

        let saving = DevelopProgressPresentation(
            progress: RenderJobProgress(phase: .saving, fractionComplete: 0.42), queued: false)
        #expect(saving.fraction == nil, "saving must stay indeterminate, never a fake percentage")
        #expect(saving.isDeterminate == false)
        #expect(saving.caption == "Saving to Photos…")

        let queued = DevelopProgressPresentation(
            progress: RenderJobProgress(phase: .rendering, fractionComplete: 0.9), queued: true)
        #expect(queued.fraction == nil)
        #expect(queued.caption == "Queued to render")
    }

    @Test func renderingFractionIsClampedAndRejectsNonFinite() {
        #expect(DevelopProgressPresentation(
            progress: RenderJobProgress(phase: .rendering, fractionComplete: 1.4), queued: false).fraction == 1)
        #expect(DevelopProgressPresentation(
            progress: RenderJobProgress(phase: .rendering, fractionComplete: -0.2), queued: false).fraction == 0)
        #expect(DevelopProgressPresentation(
            progress: RenderJobProgress(phase: .rendering, fractionComplete: .nan), queued: false).fraction == nil)
    }

    @Test func indeterminateRenderingHasNoFraction() {
        let presentation = DevelopProgressPresentation(
            progress: RenderJobProgress(phase: .rendering, fractionComplete: nil), queued: false)
        #expect(presentation.fraction == nil)
        #expect(presentation.caption == "Rendering…")
    }

    // MARK: - Full-frame coverage

    @MainActor @Test func overlayCoversEveryCornerAndIsNotBlank() throws {
        let cases: [(progress: RenderJobProgress?, queued: Bool)] = [
            (nil, true),
            (RenderJobProgress(phase: .rendering, fractionComplete: 0.3), false),
            (RenderJobProgress(phase: .rendering, fractionComplete: nil), false),
            (RenderJobProgress(phase: .saving, fractionComplete: 0.9), false)
        ]
        for (index, state) in cases.enumerated() {
            let view = DevelopProgressOverlay(progress: state.progress, queued: state.queued)
                .frame(width: 180, height: 320)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(image.width == 180 && image.height == 320, "case \(index)")
            let bytes = try pixels(image)
            for (name, point) in [("top-left", (0, 0)),
                                  ("top-right", (image.width - 1, 0)),
                                  ("bottom-left", (0, image.height - 1)),
                                  ("bottom-right", (image.width - 1, image.height - 1))] {
                let alpha = alpha(bytes, image: image, x: point.0, y: point.1)
                #expect(alpha > 120, "case \(index) \(name) corner alpha \(alpha) must be covered")
            }
            #expect(visiblePixelCount(bytes) > 0, "case \(index) overlay must not render blank")
        }
    }

    // MARK: - Pixel helpers

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width,
                                                height: image.height, bitsPerComponent: 8,
                                                bytesPerRow: image.width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func alpha(_ bytes: [UInt8], image: CGImage, x: Int, y: Int) -> Int {
        Int(bytes[(y * image.width + x) * 4 + 3])
    }

    private func visiblePixelCount(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).reduce(into: 0) { count, index in
            if Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2]) > 100 { count += 1 }
        }
    }
}
