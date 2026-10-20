import CoreGraphics
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

struct CameraMoodRenderTests {
    @MainActor @Test func tallyRendersBrightRedOnlyWhileRecording() throws {
        var redCounts: [Int] = []
        for active in [false, true] {
            let image = try render(RecordingTallyLight(isRecording: active)
                .frame(width: 24, height: 24).padding(8), name: "tally-\(active)")
            let data = try pixels(image)
            if !active {
                #expect(stride(from: 3, to: data.count, by: 4).allSatisfy { data[$0] == 0 },
                        "Idle recording light must leave no dot, bezel, or shadow.")
            }
            redCounts.append(stride(from: 0, to: data.count, by: 4).filter {
                data[$0] > 200 && data[$0 + 1] < 100 && data[$0 + 2] < 100 && data[$0 + 3] > 220
            }.count)
        }
        #expect(redCounts[0] == 0)
        #expect(redCounts[1] > 200)
    }

    @MainActor @Test func roundToolbarFaceHasClearCornersAndReadableIcon() throws {
        for degrees in [0.0, 90.0, -90.0] {
            let view = Button {} label: {
                Image(systemName: "gearshape.fill").font(.system(size: 20))
                    .foregroundStyle(.white).rotationEffect(.degrees(degrees))
                    .frame(width: 44, height: 44)
            }.buttonStyle(CameraRoundButtonStyle())
            let image = try render(view, name: "round-key-\(degrees)")
            #expect(image.width == 88 && image.height == 88)
            let data = try pixels(image)
            #expect(data[3] < 40, "A round face must not fill its square corner.")
            let ink = stride(from: 0, to: data.count, by: 4).filter {
                data[$0] > 220 && data[$0 + 1] > 220 && data[$0 + 2] > 220 && data[$0 + 3] > 200
            }
            #expect(ink.count > 120)
        }
    }

    @MainActor @Test func focalRulerRendersAtNarrowAndWidePhoneWidths() throws {
        for width: CGFloat in [288, 358, 398] {
            for focal in FocalLengthRulerScale.majorTicks {
                let image = try render(FocalLengthRuler(millimeters: focal).frame(width: width),
                                       name: "ruler-\(Int(width))-\(Int(focal))")
                #expect(image.width == Int(width * 2))
                let data = try pixels(image)
                let ink = stride(from: 0, to: data.count, by: 4).filter {
                    data[$0] > 180 && data[$0 + 1] > 180 && data[$0 + 3] > 200
                }
                #expect(ink.count > 150, "Real scale labels and index must remain nonblank.")
            }
        }
    }

    @MainActor
    private func render(_ view: some View, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = TestRepository.artifactDirectory("mood-camera-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return image
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                               bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
