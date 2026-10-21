import CoreGraphics
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

struct CameraTopPanelVisibilityTests {
    @MainActor @Test func settingsRemainVisibleWithTheRealConditionalTimer() throws {
        for width: CGFloat in [320, 390, 430] {
            for state: RecordButtonPresentation in [.idle, .starting, .recording, .stopping] {
                for degrees in [0.0, 90.0, -90.0] {
                    for diagnostics in [false, true] {
                        let panel = CameraTopPanel(statusInToolbar: degrees == 0) {
                            Button {} label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 20)).foregroundStyle(.green)
                                    .frame(width: 44, height: 44)
                            }.buttonStyle(CameraRoundButtonStyle())
                        } manual: {
                            Button {} label: {
                                Image(systemName: "slider.vertical.3")
                                    .font(.system(size: 20)).foregroundStyle(.cyan)
                                    .frame(width: 44, height: 44)
                            }.buttonStyle(CameraRoundButtonStyle())
                        } lens: {
                            Text("24 mm").foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .opacity(state == .recording ? 0 : 1)
                        } status: {
                            if state == .recording {
                                RecordingStatusFace(presentation: .recording, text: "00:01.00",
                                                    rotationDegrees: degrees)
                            }
                        } diagnostics: {
                            VStack(spacing: 4) {
                                if diagnostics {
                                    Text("DEBUG").frame(width: 44, height: 44)
                                }
                            }
                        }
                        .frame(width: width)
                        let renderer = ImageRenderer(content: panel)
                        renderer.scale = 2
                        let image = try #require(renderer.cgImage)
                        #expect(image.width == Int(width * 2))
                        #expect(image.height >= 116,
                                "Hiding the timer must not collapse the top menu's 44pt controls.")
                        let data = try pixels(image)
                        var settingsInk = 0
                        var manualInk = 0
                        for pixel in 0..<(data.count / 4) {
                            let column = pixel % image.width
                            let red = Int(data[pixel * 4])
                            let green = Int(data[pixel * 4 + 1])
                            let blue = Int(data[pixel * 4 + 2])
                            if column < 128, green > red + 50, green > blue + 30 { settingsInk += 1 }
                            if column >= 144, column < 232, green > red + 30, blue > red + 30 { manualInk += 1 }
                        }
                        #expect(settingsInk > 20, "The actual settings key must stay visible and correctly positioned.")
                        #expect(manualInk > 20, "The actual manual key must stay visible and correctly positioned.")
                        if width == 320, degrees == 0, !diagnostics {
                            try save(image, name: "toolbar-\(state)")
                        }
                    }
                }
            }
        }
    }

    @MainActor @Test func emptyOptionalStatusAndDiagnosticsKeepThePrimaryKeys() throws {
        let panel = CameraTopPanel {
            Color.green.frame(width: 44, height: 44)
        } manual: {
            Color.cyan.frame(width: 44, height: 44)
        } lens: {
            Color.blue.frame(width: 44, height: 44)
        } status: {
            EmptyView()
        } diagnostics: {
            EmptyView()
        }
        .frame(width: 320)
        let renderer = ImageRenderer(content: panel)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.height == 116)
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

    private func save(_ image: CGImage, name: String) throws {
        let directory = TestRepository.artifactDirectory("toolbar-visibility")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
