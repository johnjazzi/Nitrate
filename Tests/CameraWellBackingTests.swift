import AppKit
import SwiftUI
import Testing

/// The Minimal clusters — the stock entry, the status LCD, the exposure column
/// and the mode row — are placed by the shooting bar and the mode strip, so their
/// footprints are fixed. These assertions pin the well as paint only: one subtle
/// borderless fill behind the cluster, no resize, and nothing at all in Classic,
/// whose plates own their own chrome.
struct CameraWellBackingTests {
    /// An 88x44 face over a white scene, rendered at 1x. Under a black fill the
    /// red channel is what the fill lets through, so `1 - red` is its opacity.
    @MainActor
    private func probe(style: CameraUIStyle, verticalInset: CGFloat = 0,
                       x: Int = 44, y: Int = 22) throws -> (red: CGFloat, size: CGSize) {
        let view = Color.clear
            .frame(width: 88, height: 44)
            .cameraWellBacking(verticalInset: verticalInset)
            .background(.white)
            .environment(\.cameraUIStyle, style)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let colour = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return (colour.redComponent, CGSize(width: image.width, height: image.height))
    }

    @MainActor
    @Test func classicDrawsNoSecondPlateBehindTheClusters() throws {
        let minimal = try probe(style: .minimal)
        let classic = try probe(style: .classic)
        #expect(minimal.size == classic.size, "The backing must not change the face's footprint.")
        #expect(classic.red == 1,
                "Classic draws nothing here: its stock plate, LCD plate and inset column already exist.")
        #expect(minimal.red < 1, "Minimal seats the cluster in the well.")
    }

    @MainActor
    @Test func theMinimalWellIsSubtleAndBorderless() throws {
        let centre = try probe(style: .minimal)
        let edge = try probe(style: .minimal, x: 1)
        let fill = 1 - centre.red
        #expect(fill > 0.2 && fill < 0.5, "Subtle: a translucent fill, not an opaque plate.")
        #expect(abs((1 - edge.red) - fill) < 0.02, "No rim: the edge carries the same fill as the middle.")
    }

    @MainActor
    @Test func theWellNeverResizesTheFaceItSeats() throws {
        for inset: CGFloat in [0, 4] {
            let minimal = try probe(style: .minimal, verticalInset: inset)
            let classic = try probe(style: .classic, verticalInset: inset)
            #expect(minimal.size == classic.size,
                    "The backing adds no padding, so the seated face keeps its size.")
        }
    }
}
