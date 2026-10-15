import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Wiring regressions for iOS-only views; geometry itself is covered separately.
struct CameraCleanupPresentationTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func timerRotatesCompleteCapsuleWithoutNestedGlyphRotation() throws {
        let file = try source("App/Modules/CameraCapture/CameraControlBar.swift")
        let start = try #require(file.range(of: "private func recordingTimerBadge"))
        let end = try #require(file.range(of: "/// Idle is a white ring", range: start.upperBound..<file.endIndex))
        let badge = String(file[start.lowerBound..<end.lowerBound])
        #expect(!badge.contains(".cameraUpright()"))
        #expect(badge.contains("RecordingTimerBadge("))
    }

    @Test func manualPanelIsIndependentOfStationaryChromeAndPreviewIdentity() throws {
        let file = try source("App/ContentView.swift")
        #expect(file.contains(".background(controlMeasurement(\"top\"))"))
        #expect(file.contains("ManualControlsOverlay(viewport: geometry.size, toolbarBottom: top.maxY, controlsTop: bottom.minY)"))
        #expect(file.components(separatedBy: "CameraView(viewModel:").count == 2)
    }

    @MainActor
    @Test(arguments: [0.0, 90.0, -90.0])
    func timerRendersFullSizeTextInsideTurnedCapsule(degrees: Double) throws {
        for text in ["00:00.00", "99:59.99", "999:59.99"] {
            for stopping in [false, true] {
                let renderer = ImageRenderer(content: RecordingTimerBadge(
                    text: text, isStopping: stopping, rotationDegrees: degrees
                ))
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(image.width == (degrees == 0 ? 168 : 48))
                #expect(image.height == (degrees == 0 ? 48 : 168))
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try #require(CGContext(
                        data: buffer.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                let ink = stride(from: 0, to: pixels.count, by: 4).filter {
                    pixels[$0] > 235 && pixels[$0 + 1] > 235 && pixels[$0 + 2] > 235
                }
                #expect(ink.count > 160, "Digits must retain legible, nonblank native-size ink.")
                let columns = ink.map { ($0 / 4) % image.width }
                let rows = ink.map { ($0 / 4) / image.width }
                #expect(try #require(columns.min()) > 3)
                #expect(try #require(columns.max()) < image.width - 4)
                #expect(try #require(rows.min()) > 3)
                #expect(try #require(rows.max()) < image.height - 4)
                let longInk = degrees == 0 ? columns : rows
                #expect(try #require(longInk.max()) - #require(longInk.min()) > 75,
                        "Landscape must not fit the digits into shallow portrait glyph bounds.")
                let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("build/cleanup-timer-renders")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("cleanup-timer-\(degrees)-\(text.replacingOccurrences(of: ":", with: "-"))-\(stopping).png")
                let destination = try #require(CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil
                ))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
                print("Timer render: \(url.path)")
            }
        }
    }

    @Test func detailedStabilizationExplanationIsBehindPanelHelp() throws {
        let file = try source("App/Modules/CameraCapture/ManualControlsPanel.swift")
        #expect(file.contains("DisclosureGroup(\"Stabilization help\")"))
        #expect(file.contains("Recording only · may crop and delay confirmation."))
    }
}
