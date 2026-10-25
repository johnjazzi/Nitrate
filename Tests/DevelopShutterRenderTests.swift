import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Native proof of the Develop centre face and of its isolation from capture.
///
/// The face is a Render action, not a REC control, so these tests pin two
/// things: the pure face draws a non-blank, unmistakably-orange control when
/// enabled and a subdued one when not — always inside the classic 84pt
/// footprint with a hit target well above 44pt — and the shooting bar wires the
/// Develop centre slot to `onDevelopRender` with no path into the recording
/// session or the REC haptics.
@MainActor
struct DevelopShutterRenderTests {
    @Test func everyStateKeepsTheClassicFootprint() throws {
        for enabled in [true, false] {
            let image = try render(face(enabled), name: "develop-footprint-\(enabled)")
            #expect(image.width == 200 && image.height == 200,
                    "An 84pt face with 8pt padding at 2x is 200pt; the Develop face cannot resize the centre slot.")
            // 44pt minimum hit target: at 2x that is 88px, already exceeded by the reserved slot.
            #expect(image.width >= 88 && image.height >= 88,
                    "The Develop face must keep at least a 44pt circular hit target.")
        }
    }

    @Test func pressingNeverChangesTheReservedFootprint() throws {
        let resting = try render(face(true), name: "develop-resting")
        let pressed = try render(face(true, isPressed: true), name: "develop-pressed")
        #expect(pressed.width == resting.width && pressed.height == resting.height,
                "The press response is a non-layout offset; it cannot move the centre slot.")
    }

    @Test func theFaceIsNeverBlankInEitherState() throws {
        let enabled = try pixels(try render(face(true), name: "develop-enabled"))
        let disabled = try pixels(try render(face(false), name: "develop-disabled"))
        #expect(opaqueInk(enabled) > 1_000, "The enabled Render face must paint a filled disc.")
        #expect(opaqueInk(disabled) > 1_000, "The disabled Render face must still paint its disc, not vanish.")
    }

    @Test func enabledIsOrangeAndDisabledIsSubdued() throws {
        let enabled = try pixels(try render(face(true), name: "develop-enabled"))
        let disabled = try pixels(try render(face(false), name: "develop-disabled"))
        #expect(orangeInk(enabled) > 1_000,
                "The enabled Render action must carry the app's orange accent.")
        #expect(orangeInk(disabled) < 200,
                "A disabled Render action must drop the accent, reading as unavailable.")
        #expect(orangeInk(enabled) > orangeInk(disabled),
                "Enabled and disabled cannot render alike; the disabled face is subdued.")
    }

    // MARK: - Source wiring contract

    @Test func developCentreSlotCallsTheRenderActionAndNeverCapture() throws {
        let bar = try source("App/Modules/CameraCapture/CameraControlBar.swift")

        // The four trailing, defaulted properties that keep Video unchanged.
        #expect(bar.contains("var isDevelopMode: Bool = false"))
        #expect(bar.contains("var developCanRender: Bool = false"))
        #expect(bar.contains("var developIsBusy: Bool = false"))
        #expect(bar.contains("var onDevelopRender: () -> Void = {}"))
        #expect(bar.contains("if isDevelopMode {"), "The centre slot must switch on Develop mode.")

        // Exposure keeps its size but greys and disables in Develop, and the
        // stock/gauge slot stays in place, disabled only while busy.
        #expect(bar.contains(".grayscale(isDevelopMode ? 1 : 0)"))
        #expect(bar.contains(".disabled(isDevelopMode)"),
                "The exposure control must disable in Develop without changing its measurement.")
        #expect(bar.contains(".disabled(isDevelopMode && developIsBusy)"),
                "The left stock/gauge slot is disabled only while a Develop render is busy.")

        // The Develop region calls only `onDevelopRender` and touches no capture,
        // REC haptic or REC-presentation path.
        let region = try developRegion(in: bar)
        #expect(region.contains("onDevelopRender()"),
                "A Develop tap must invoke the render action.")
        #expect(region.contains("developCanRender") && region.contains("developIsBusy"),
                "The Render action is enabled only when it can render and is not busy.")
        #expect(region.contains("DevelopShutterFace("))
        #expect(region.contains("develop.render"), "The Develop face exposes the develop.render identifier.")
        #expect(region.contains("Render video"), "The Develop face is announced as Render video.")
        for forbidden in ["startRecording", "stopRecording", "sensoryFeedback",
                          "cameraViewModel", "recordFeedback", "RecordButtonPresentationPolicy",
                          "RecordPlungerFace", "ModernRecordButtonFace"] {
            #expect(!region.contains(forbidden),
                    "The Develop centre slot must never reach the capture path: found \(forbidden).")
        }
    }

    // MARK: - Helpers

    private func face(_ isEnabled: Bool, isPressed: Bool = false) -> some View {
        DevelopShutterFace(isEnabled: isEnabled, isPressed: isPressed)
            .padding(8)
    }

    /// The declarations between the Develop marker and the next member, so the
    /// isolation assertions cannot accidentally read the Video REC button.
    private func developRegion(in source: String) throws -> String {
        let marker = "// MARK: - Develop render action"
        let afterMarker = try #require(source.components(separatedBy: marker).dropFirst().first,
                                       "The Develop render section must stay marked.")
        return try #require(afterMarker.components(separatedBy: "private var queueStatus").first)
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Count of pixels that carry the accent: clearly red-dominant and bright.
    private func orangeInk(_ data: [UInt8]) -> Int {
        var count = 0
        for index in stride(from: 0, to: data.count, by: 4) {
            let red = Int(data[index])
            let green = Int(data[index + 1])
            if data[index + 3] > 200, red > green + 40,
               data[index] > 120, data[index + 2] < 130 { count += 1 }
        }
        return count
    }

    /// Count of painted (non-transparent) pixels, so a blank render fails.
    private func opaqueInk(_ data: [UInt8]) -> Int {
        stride(from: 0, to: data.count, by: 4).filter { $0 + 3 < data.count && data[$0 + 3] > 200 }.count
    }

    private func render(_ view: some View, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = TestRepository.artifactDirectory("develop-shutter-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
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
