import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

struct CameraDesignRenderTests {
    private let states: [RecordButtonPresentation] = [.idle, .starting, .recording, .stopping]

    @Test func geometryKeepsFullHeightCenteredAndSeparated() {
        for screenWidth: CGFloat in [320, 390, 430] {
            for height: CGFloat in [168, 180, 200] {
                let width = screenWidth - 32
                let geometry = CameraControlGeometry(width: width, height: height)
                #expect(geometry.exposure.height == height)
                #expect(abs(geometry.lcd.height - 2 * geometry.stock.height) < 0.001)
                #expect(geometry.lcd.maxY == height)
                #expect(geometry.record.midX == width / 2)
                #expect(!geometry.stock.intersects(geometry.record))
                #expect(!geometry.lcd.intersects(geometry.record))
                #expect(!geometry.exposure.intersects(geometry.record))
                #expect(geometry.stock.height >= 52)
                for degrees in [0.0, 90.0, -90.0, 180.0] {
                    let face = CameraControlGeometry.faceSize(in: geometry.lcd.size, degrees: degrees)
                    let turned = CameraControlGeometry.faceSize(in: face, degrees: degrees)
                    #expect(turned == geometry.lcd.size)
                }
            }
        }
    }

    @Test func topPanelGeometrySeparatesAllControlsIncludingDiagnostics() {
        for screenWidth: CGFloat in [320, 390, 430] {
            for degrees in [0.0, 90.0, -90.0] {
                let statusSize = abs(degrees) == 90 ? CGSize(width: 40, height: 112) : CGSize(width: 112, height: 40)
                for diagnosticsHeight: CGFloat in [0, 44, 92] {
                    let geometry = CameraTopPanelGeometry(width: screenWidth - 32, statusSize: statusSize,
                                                          diagnosticsHeight: diagnosticsHeight)
                    let faces = [geometry.settings, geometry.manual, geometry.lens, geometry.status, geometry.diagnostics]
                    for (index, face) in faces.enumerated() {
                        #expect(face.minX >= 0 && face.maxX <= screenWidth - 32)
                        #expect(face.minY >= 0 && face.maxY <= geometry.height)
                        for other in faces.dropFirst(index + 1) where !face.isEmpty && !other.isEmpty {
                            #expect(!face.intersects(other), "Complete rotated status and every key must have disjoint reserved bounds.")
                        }
                    }
                }
            }
        }
    }

    @MainActor @Test func statusDistinguishesPendingConfirmedAndStoppingWithoutColor() throws {
        #expect(RecordingIndicatorStyle.resolved("missing") == .red)
        let suite = "CameraDesignTests.indicator"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(RecordingIndicatorStyle.monochrome.rawValue, forKey: RecordingIndicatorStyle.preferenceKey)
        #expect(RecordingIndicatorStyle.resolved(defaults.string(forKey: RecordingIndicatorStyle.preferenceKey) ?? "") == .monochrome)
        for style in RecordingIndicatorStyle.allCases {
            var images: [[UInt8]] = []
            for state in states {
                let face = RecordingStatusFace(presentation: state, text: "99:59.99", style: style)
                let image = try render(face.padding(8), name: "status-\(style)-\(state)")
                let data = try pixels(image)
                #expect(data.contains { $0 > 200 })
                images.append(data)
                if state == .starting { #expect(face.accessibilityStatus.contains("not yet confirmed")) }
                if state == .stopping { #expect(face.accessibilityStatus.contains("timer frozen")) }
            }
            #expect(Set(images).count == 4, "WAIT outline, confirmed dot and STOP square must differ without color.")
        }
    }

    @MainActor @Test func actualTopPanelReservesStatusAndDiagnosticBoundsAtPhoneWidths() throws {
        for width: CGFloat in [320, 390, 430] {
            for degrees in [0.0, 90.0, -90.0] {
                let view = CameraTopPanel {
                    Image(systemName: "gearshape.fill").frame(width: 44, height: 44)
                        .buttonStyle(CameraRaisedButtonStyle())
                } manual: {
                    Image(systemName: "slider.vertical.3").frame(width: 44, height: 44)
                } lens: {
                    CameraLensFace(title: "120 mm", focalLength: "120", rotationDegrees: degrees)
                } status: {
                    RecordingStatusFace(presentation: .recording, text: "99:59.99", rotationDegrees: degrees)
                } diagnostics: {
                    VStack(spacing: 4) {
                        Text("DEBUG").font(.system(size: 11, weight: .bold)).frame(width: 64, height: 44).background(.yellow)
                        Text("FAULT").font(.system(size: 11, weight: .bold)).frame(width: 64, height: 44).background(.red)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: width)
                .padding(8)
                let image = try render(view, name: "top-\(Int(width))-\(degrees)")
                #expect(image.width == Int((width + 16) * 2))
                #expect(image.height == (degrees == 0 ? 332 : 372))
                let face = RecordingStatusFace(presentation: .recording, text: "999:59.99", rotationDegrees: degrees)
                let faceImage = try render(face.padding(8), name: "status-rotation-\(degrees)")
                #expect(faceImage.width == (degrees == 0 ? 256 : 112))
                #expect(faceImage.height == (degrees == 0 ? 112 : 256))
                let data = try pixels(faceImage)
                let ink = stride(from: 0, to: data.count, by: 4).filter {
                    data[$0] > 160 && Int(data[$0]) > Int(data[$0 + 1]) + 60
                }
                #expect(ink.count > 150)
                let xs = ink.map { ($0 / 4) % faceImage.width }
                let ys = ink.map { ($0 / 4) / faceImage.width }
                #expect(try #require(xs.min()) >= 20)
                #expect(try #require(xs.max()) < faceImage.width - 20)
                #expect(try #require(ys.min()) >= 20)
                #expect(try #require(ys.max()) < faceImage.height - 20)
            }
        }
    }

    @MainActor @Test func gaugeStripUsesOrderedRealWidthsAndLegibleLettering() throws {
        #expect(PrintGauge.neutral == .thirtyFiveMillimetre)
        for degrees in [0.0, 90.0, -90.0] {
            var widths: [Int] = []
            for gauge in PrintGauge.allCases {
                let image = try render(CameraGaugeLabel(gauge: gauge, rotationDegrees: degrees)
                    .padding(4), name: "gauge-\(gauge.rawValue)-\(degrees)")
                let data = try pixels(image)
                let sepia = stride(from: 0, to: data.count, by: 4).filter { index in
                    let red = Int(data[index])
                    let green = Int(data[index + 1])
                    let blue = Int(data[index + 2])
                    return red > green + 15 && green > blue + 8 && data[index + 3] > 80
                }
                let white = stride(from: 0, to: data.count, by: 4).filter {
                    data[$0] > 180 && abs(Int(data[$0]) - Int(data[$0 + 2])) < 12
                }
                #expect(sepia.count > 120, "Real gauge needs a subtle, nonblank sepia strip behind its label.")
                #expect(white.count > 35, "Gauge lettering remains bright and legible.")
                let across = sepia.map { degrees == 0 ? ($0 / 4) % image.width : ($0 / 4) / image.width }
                widths.append((across.max() ?? 0) - (across.min() ?? 0))
                #expect(image.width == 72 && image.height == 72, "Gauge cannot enlarge its existing stock-row slot.")
            }
            #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 < $1 },
                    "8, 16, 35 and 75mm must become progressively wider, not follow grain coarseness.")
        }
    }

    @MainActor @Test func plungerStaysMutedRedAndMovesWithoutScaling() throws {
        for state in states {
            for pressed in [false, true] {
                let image = try render(RecordPlungerFace(presentation: state, isPressed: pressed)
                    .padding(8), name: "plunger-\(state)-\(pressed)")
                #expect(image.width == 200 && image.height == 200)
                let data = try pixels(image)
                let redInk = stride(from: 0, to: data.count, by: 4).filter {
                    Int(data[$0]) > Int(data[$0 + 1]) + 35 && data[$0] > 90 && data[$0] < 220
                }
                #expect(redInk.count > 7_000, "The real face must remain a nonblank washed-red cap in every state.")
                #expect(data[3] == 0, "Circular face must not acquire a rectangular bezel.")
            }
        }
    }

    @MainActor @Test func lensFacesRetainNaturalInkInBothLandscapeHolds() throws {
        for degrees in [0.0, 90.0, -90.0] {
            for focal in ["13", "24", "48", "77", "120", "Front"] {
                for selected in [false, true] {
                    let width: CGFloat = selected ? 104 : 84
                    let face = CameraLensFace(title: focal == "Front" ? focal : "\(focal) mm",
                                              focalLength: focal == "Front" ? nil : focal,
                                              rotationDegrees: degrees, isSelected: selected)
                        .foregroundStyle(.white)
                        .frame(width: width, height: 44)
                    let image = try render(face.padding(4), name: "lens-\(degrees)-\(focal)-\(selected)")
                    let data = try pixels(image)
                    let ink = stride(from: 0, to: data.count, by: 4).filter {
                        data[$0] > 220 && data[$0 + 1] > 220 && data[$0 + 2] > 220 && data[$0 + 3] > 220
                    }
                    #expect(ink.count > 140, "Actual label and aperture must not shrink into a blank or tiny glyph.")
                    let columns = ink.map { ($0 / 4) % image.width }
                    let rows = ink.map { ($0 / 4) / image.width }
                    #expect(try #require(columns.min()) >= 8)
                    #expect(try #require(columns.max()) < image.width - 8)
                    #expect(try #require(rows.min()) >= 8)
                    #expect(try #require(rows.max()) < image.height - 8)
                }
            }
        }
    }

    @MainActor @Test func sharedLayoutAndRealLCDRenderAtPhoneWidths() throws {
        for width: CGFloat in [320, 390, 430] {
            for degrees in [0.0, 90.0, -90.0] {
                for processing in [false, true] {
                    let queue = CameraStatusPresentation(outstandingCount: processing ? 3 : 0, pendingCount: 2,
                                                         isProcessing: processing, failedCount: 0,
                                                         errorMessage: nil, latestResultCompleted: false,
                                                         latestResultSavedToPhotos: nil)
                    let view = CameraShootingLayout() {
                        HStack(spacing: 6) {
                            CameraFilmStockFace(primary: .yellow, secondary: .orange, isoLight: "500T")
                                .rotationEffect(.degrees(degrees)).frame(width: 52, height: 52)
                            CameraGaugeLabel(gauge: .seventyFiveMillimetre, rotationDegrees: degrees)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        CameraRotatingSlot(rotationDegrees: degrees) {
                            RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false, queueStatus: queue)
                        }
                        RecordPlungerFace(presentation: .idle, rotationDegrees: degrees)
                        // Layout fixture only, not a substitute for the hardware exposure ruler.
                        Color.gray.opacity(0.3).frame(width: 92, height: 168)
                    }
                    .padding(.horizontal, 16)
                    .frame(width: width)
                    let image = try render(view, name: "layout-\(Int(width))-\(degrees)-\(processing)")
                    #expect(image.width == Int(width * 2))
                    #expect(image.height == 336, "Left column must not increase or truncate the natural exposure height.")
                    let data = try pixels(image)
                    let bright = stride(from: 0, to: data.count, by: 4).filter {
                        data[$0] > 220 && data[$0 + 1] > 220 && data[$0 + 2] > 220
                    }
                    #expect(bright.count > 250, "Real LCD and stock/gauge text must be nonblank.")
                }
            }
        }
    }

    @MainActor
    private func render(_ view: some View, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/camera-design-renders")
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
