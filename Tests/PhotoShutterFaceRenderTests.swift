import AppKit
import CoreGraphics
import SwiftUI
import Testing

/// The Photo shutter face is a light-grey donut with concave shading. These
/// assertions read the rendered pixels, so the shape, the open hole and the
/// light direction are checked rather than described; the PNG is written out as
/// reviewable evidence.
struct PhotoShutterFaceRenderTests {
    // Mirrors the face's own defaults; a change there should fail these bounds.
    private let diameter: CGFloat = 68
    private let thickness: CGFloat = 19

    /// Rendered pixels with buffer row 0 = the image's top row.
    ///
    /// `ImageRenderer`'s bitmap rows run bottom-up for this content, so the
    /// context is deliberately left unflipped. That was established by rendering
    /// a white bar at the top of a black frame and reading both orientations:
    /// unflipped it lands at row 10, flipped at row 126.
    private func rgbaTopDown(_ image: CGImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (bytes, image.width, image.height)
    }

    @Test @MainActor func donutFaceIsAConcaveLightGreyRingAroundAnOpenHole() throws {
        // 4x so a 1 pt feature is 4 px and edge antialiasing cannot be mistaken
        // for shading. No background: the hole must read as transparent.
        let renderer = ImageRenderer(content: PhotoShutterFace().frame(width: 100, height: 100))
        renderer.scale = 4
        let image = try #require(renderer.cgImage)
        let (pixels, width, height) = try rgbaTopDown(image)
        #expect(width == 400 && height == 400)
        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let index = (y * width + x) * 4
            return (Int(pixels[index]), Int(pixels[index + 1]),
                    Int(pixels[index + 2]), Int(pixels[index + 3]))
        }
        let scale = 4
        let centre = width / 2                        // 50 pt in a 100 pt frame
        let edge = (height - Int(diameter) * scale) / 2   // 64 px: the face's top

        // The hole is open: the preview shows through the middle of the shutter.
        #expect(pixel(centre, centre).a == 0, "the hole must be transparent")
        for (x, y) in [(2, 2), (width - 3, 2), (2, height - 3), (width - 3, height - 3)] {
            #expect(pixel(x, y).a == 0, "the face must not fill its frame: the ring stays outside")
        }

        // Geometry: a donut of the requested size, centred in its frame.
        let lip = pixel(centre, edge + 3)
        let wallInsideLip = pixel(centre, centre - Int(thickness) * scale)
        let holeEdge = centre - (Int(diameter) - 2 * Int(thickness)) * scale / 2
        #expect(lip.a == 255, "the band is opaque")
        #expect(pixel(centre, edge - 8).a == 0, "nothing is drawn outside the outer edge")
        #expect(pixel(centre, holeEdge - 20).a == 255, "the band is opaque up to the hole")
        // The lip casts a soft shadow over the inner rim, so the hole is only
        // fully clear a little way inside its own edge.
        #expect(pixel(centre, holeEdge + 40).a == 0, "the hole matches diameter - 2 * thickness")

        // Light grey, one surface tone: no pixel of the face is dark or blown.
        let bandLuminance = (edge..<(height - edge)).map { pixel(centre, $0) }
            .filter { $0.a == 255 }.map(\.r)
        #expect(!bandLuminance.isEmpty)
        #expect(bandLuminance.min()! >= 150, "light grey surface, never a dark disc")
        #expect(bandLuminance.max()! <= 245, "light grey surface, never blown white")

        // Concave, not domed: the near lip catches the light and the wall just
        // inside it falls away into shade, while the lit far wall stays brighter.
        #expect(lip.r - wallInsideLip.r >= 25,
                "the lip must overhang a shaded wall (lip \(lip.r), wall \(wallInsideLip.r))")
        let farWall = pixel(centre, centre + Int(thickness) * scale)
        #expect(farWall.r > wallInsideLip.r,
                "the wall away from the light stays brighter than the wall in shade")
        #expect(abs(lip.r - farWall.r) < 60, "concave shading, not a hard split")

        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/cache/scratch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("photo-shutter-donut-verified.png"))
    }
}
