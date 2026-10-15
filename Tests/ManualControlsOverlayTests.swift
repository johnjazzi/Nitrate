import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

struct ManualControlsOverlayTests {
    @Test func panelGeometryUsesOnlyAvailableViewportAndStationaryChrome() {
        for size in [CGSize(width: 320, height: 430), CGSize(width: 390, height: 763), CGSize(width: 430, height: 820)] {
            for toolbar: CGFloat in [52, 154, 174] {
                let rect = ManualControlsOverlayGeometry.rect(viewport: size, toolbarBottom: toolbar,
                                                              controlsTop: size.height - 180)
                #expect(rect.minX == 16 && rect.maxX == size.width - 16)
                #expect(rect.minY == toolbar + 6)
                #expect(rect.maxY <= size.height - 186)
                #expect(rect.height >= 0)
            }
        }
        let noSpace = ManualControlsOverlayGeometry.rect(viewport: CGSize(width: 320, height: 200),
                                                         toolbarBottom: 180, controlsTop: 100)
        #expect(noSpace.height == 0)
    }

    @MainActor @Test func tallPanelStaysBelowToolbarInsideShortAndNarrowViewports() throws {
        for size in [CGSize(width: 320, height: 430), CGSize(width: 390, height: 763), CGSize(width: 430, height: 820)] {
            for degrees in [0.0, 90.0, -90.0] {
                let top: CGFloat = 110
                let bottom = size.height - 180
                let view = ManualControlsOverlay(
                    viewport: size, toolbarBottom: top, controlsTop: bottom
                ) {
                    VStack {
                        Text("MANUAL").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .fixedSize()
                            .rotationEffect(.degrees(degrees))
                            .frame(width: 80, height: 80)
                        Color.red.frame(height: 900)
                        Text("Stabilization help").rotationEffect(.degrees(degrees))
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                }.padding(32)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: CGSize(width: size.width + 64, height: size.height + 64))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = try #require(bitmap.cgImage)
                let scale = CGFloat(image.width) / (size.width + 64)
                #expect(CGFloat(image.height) == (size.height + 64) * scale)
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                        space: CGColorSpaceCreateDeviceRGB(),
                                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                let ink = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 160 && pixels[$0 + 1] < 100 }
                let xs = ink.map { ($0 / 4) % image.width }
                let ys = ink.map { ($0 / 4) / image.width }
                #expect(ink.count > 10_000, "The manual surface must actually be visible.")
                #expect(try #require(xs.min()) == Int(48 * scale))
                #expect(try #require(xs.max()) < Int((size.width + 16) * scale))
                #expect(try #require(ys.min()) >= Int((top + 38) * scale))
                #expect(try #require(ys.max()) < Int((bottom + 32) * scale))
                let glyphInk = stride(from: 0, to: pixels.count, by: 4).filter {
                    pixels[$0] > 220 && pixels[$0 + 1] > 220 && pixels[$0 + 2] > 220 && pixels[$0 + 3] > 220
                }
                #expect(glyphInk.count > 60, "The rotated manual header must retain visible native ink.")
                let glyphRows = glyphInk.map { ($0 / 4) / image.width }
                #expect(try #require(glyphRows.min()) >= Int((top + 38) * scale))
                #expect(try #require(glyphRows.max()) < Int((bottom + 32) * scale))
                let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("build/camera-design-renders")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("manual-\(Int(size.width))-\(degrees).png")
                let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
            }
        }
    }
}
