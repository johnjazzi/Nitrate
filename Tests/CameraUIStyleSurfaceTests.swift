import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Proof that the injected camera surface style selects decoration and nothing
/// else.
///
/// Every face is rendered twice, once under each style, and the test pins what
/// must not move with the style: the REC cap's 84pt footprint in every
/// presentation state, the optimistic state path (the accepted tap paints the
/// live mark at once and finalizing only dims it), the stock row's 28pt and 44pt
/// slots, and the shared surfaces' bounds. The rendered evidence is deliberately
/// coarse — colour mass and bounds, not artwork — so a palette tweak never needs
/// a re-baseline, while a style that leaked into layout or state still fails.
@MainActor
struct CameraUIStyleSurfaceTests {
    private let styles: [CameraUIStyle] = [.classic, .minimal]
    private let states: [RecordButtonPresentation] = [.idle, .starting, .recording, .stopping]

    @Test func everyStyleKeepsTheRECFootprintInEveryState() throws {
        for style in styles {
            for state in states {
                let shot = try capture(plunger(state, style), name: "plunger-\(style)-\(state)")
                #expect(shot.image.width == 200 && shot.image.height == 200,
                        "An 84pt cap with 8pt padding at 2x is 200pt in \(style)/\(state).")
                #expect(shot.data[3] == 0, "Both caps stay circular: no bezel in \(style).")
            }
        }
    }

    /// The optimistic contract is style-independent: an accepted tap shows the
    /// stop mark while capture is still spinning up, so a pending start and a
    /// confirmed take are the same face in both styles.
    @Test func aPendingStartPaintsTheLiveFaceInBothStyles() throws {
        for style in styles {
            let starting = try capture(plunger(.starting, style), name: "start-\(style)")
            let recording = try capture(plunger(.recording, style), name: "live-\(style)")
            #expect(starting.data == recording.data,
                    "\(style) must answer the tap with the live mark, not wait for the writer.")
        }
    }

    @Test func classicRestoresTheRedPlungerAndMinimalStaysNeutral() throws {
        let classic = try capture(plunger(.idle, .classic), name: "idle-classic")
        let minimal = try capture(plunger(.idle, .minimal), name: "idle-minimal")
        #expect(redPixels(classic.data) > 3_000,
                "The classic cap is the red machined body at rest.")
        #expect(redPixels(minimal.data) == 0,
                "The minimal cap is a neutral disc; red stays reserved for a live take.")
        #expect(classic.data != minimal.data, "The injected style must change the drawing.")
    }

    /// Finalizing keeps the same mark in both styles and only dims it: the white
    /// square loses brightness on the classic body, and the red square loses its
    /// saturation on the minimal disc.
    @Test func finalizingOnlyDimsTheMark() throws {
        let classicStopping = try capture(plunger(.stopping, .classic), name: "stop-classic")
        let classicRecording = try capture(plunger(.recording, .classic), name: "rec-classic")
        // The mark is 15pt of an 84pt cap, so measure only the centre fifth.
        #expect(centreMean(classicStopping, crop: 0.2) < centreMean(classicRecording, crop: 0.2) - 8,
                "The classic stop square dims while finalizing.")
        let minimalStopping = try capture(plunger(.stopping, .minimal), name: "stop-minimal")
        let minimalRecording = try capture(plunger(.recording, .minimal), name: "rec-minimal")
        #expect(redMass(minimalStopping.data) < redMass(minimalRecording.data),
                "The minimal stop mark dims while finalizing.")
        #expect(minimalStopping.data != minimalRecording.data)
    }

    @Test func stockRowFacesKeepTheirSlotsInBothStyles() throws {
        for gauge in PrintGauge.allCases {
            let classic = try capture(styled(CameraGaugeLabel(gauge: gauge).padding(4), .classic),
                                     name: "gauge-classic-\(gauge.rawValue)")
            let minimal = try capture(styled(CameraGaugeLabel(gauge: gauge).padding(4), .minimal),
                                     name: "gauge-minimal-\(gauge.rawValue)")
            #expect(classic.image.width == 72 && classic.image.height == 72,
                    "The gauge keeps its 28pt slot in both styles.")
            #expect(classic.image.width == minimal.image.width
                        && classic.image.height == minimal.image.height,
                    "The style cannot resize the stock row.")
            #expect(sepiaPixels(classic.data) > 100,
                    "The classic gauge restores its sepia strip.")
            #expect(sepiaPixels(minimal.data) < 20,
                    "The minimal gauge stays neutral type.")
        }
        let stock = CameraFilmStockFace(primary: .yellow, secondary: .orange, isoLight: "500T")
        let classicStock = try capture(styled(stock, .classic), name: "stock-classic")
        let minimalStock = try capture(styled(stock, .minimal), name: "stock-minimal")
        #expect(classicStock.image.width == minimalStock.image.width
                    && classicStock.image.height == minimalStock.image.height,
                "The ISO chip cannot resize the 44pt swatch.")
        #expect(classicStock.data != minimalStock.data,
                "The classic chip differs from the minimal lettering.")
    }

    /// The shared modifiers are what the toolbar keys and the manual controls
    /// draw with, so their bounds must be style-independent even though their
    /// faces are not.
    @Test func sharedSurfacesDrawTheSameBoundsInBothStyles() throws {
        let plate = Color.clear.frame(width: 44, height: 44)
        let surfaces: [(String, AnyView)] = [
            ("raised", AnyView(plate.modifier(
                CameraRaisedSurface(faceColor: nil, cornerRadius: 6, isPressed: false)))),
            ("round", AnyView(plate.modifier(
                CameraRoundSurface(faceColor: nil, isPressed: false))))
        ]
        for (name, surface) in surfaces {
            let classic = try capture(styled(surface, .classic), name: "\(name)-classic")
            let minimal = try capture(styled(surface, .minimal), name: "\(name)-minimal")
            #expect(classic.image.width == minimal.image.width
                        && classic.image.height == minimal.image.height,
                    "The \(name) surface keeps its caller's target in both styles.")
            #expect(classic.data != minimal.data,
                    "The \(name) surface must actually repaint for the style.")
        }
        let pressed = try capture(styled(plate.modifier(
            CameraRaisedSurface(faceColor: nil, cornerRadius: 6, isPressed: true)), .minimal),
            name: "raised-pressed")
        let resting = try capture(styled(plate.modifier(
            CameraRaisedSurface(faceColor: nil, cornerRadius: 6, isPressed: false)), .minimal),
            name: "raised-resting")
        #expect(pressed.data != resting.data, "The minimal plate still deepens on press.")
    }

    /// A screen that injects nothing keeps the minimal surface exactly.
    @Test func anUnstyledScreenRendersTheMinimalSurface() throws {
        let plain = try capture(RecordPlungerFace(presentation: .recording).padding(8),
                                name: "plunger-default")
        let minimal = try capture(plunger(.recording, .minimal), name: "plunger-minimal")
        #expect(plain.data == minimal.data,
                "The default style is minimal; existing screens cannot change face.")
    }

    /// Every face and shared surface reads the one environment value, and the
    /// minimal branch keeps the flat tokens the border contract pins.
    @Test func everySurfaceReadsTheStyleAndMinimalKeepsItsTokens() throws {
        let surfaces = try source("App/Modules/CameraCapture/CameraRaisedButtonStyle.swift")
        #expect(surfaces.components(separatedBy: "@Environment(\\.cameraUIStyle)").count == 5,
                "The four shared surfaces all read the injected style.")
        #expect(surfaces.components(separatedBy: "if uiStyle == .classic").count == 5)
        for token in ["shape.fill(minimalBase)", "shape.fill(minimalTint)",
                      "shape.fill(Color.black.opacity(0.5))",
                      "shape.fill(Color.black.opacity(0.32))"] {
            #expect(surfaces.contains(token),
                    "The minimal branch keeps its flat token: \(token)")
        }
        #expect(CameraControlBorder.lineWidth == 1 && CameraControlBorder.cornerRadius == 12,
                "The shared border tokens stay the minimal pass's numbers.")

        let faces = try source("App/Modules/CameraCapture/CameraDesignFaces.swift")
        #expect(faces.components(separatedBy: "@Environment(\\.cameraUIStyle)").count == 4,
                "The REC cap, gauge and stock faces all read the injected style.")
        #expect(faces.contains("@Environment(\\.cameraUIStyle) private var uiStyle"))
        #expect(faces.components(separatedBy: "if uiStyle == .classic").count == 6,
                "All five face branches — cap, both glyphs, gauge and stock — are style-gated.")
    }

    // MARK: - Helpers

    private func plunger(_ state: RecordButtonPresentation, _ style: CameraUIStyle) -> some View {
        styled(RecordPlungerFace(presentation: state).padding(8), style)
    }

    private func styled(_ view: some View, _ style: CameraUIStyle) -> some View {
        view.environment(\.cameraUIStyle, style)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: TestRepository.url(for: relativePath), encoding: .utf8)
    }

    private func capture(_ view: some View, name: String) throws -> (image: CGImage, data: [UInt8]) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = TestRepository.artifactDirectory("camera-ui-style-surfaces")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        if let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        return (image, try pixels(image))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress,
                                                 width: image.width, height: image.height,
                                                 bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    /// Red-dominant pixels: the classic body, and the minimal live mark.
    private func redPixels(_ data: [UInt8]) -> Int {
        var count = 0
        var index = 0
        while index + 3 < data.count {
            let red = Int(data[index])
            let green = Int(data[index + 1])
            if red > green + 40 && red > 60 && data[index + 3] > 60 { count += 1 }
            index += 4
        }
        return count
    }

    /// Total red surplus, so a mark dimmed over a neutral disc still measures
    /// lighter even though its pixels stay red-dominant.
    private func redMass(_ data: [UInt8]) -> Int {
        var total = 0
        var index = 0
        while index + 3 < data.count {
            total += max(0, Int(data[index]) - Int(data[index + 1]))
            index += 4
        }
        return total
    }

    /// Sepia pixels: the classic gauge strip, which the minimal gauge drops.
    private func sepiaPixels(_ data: [UInt8]) -> Int {
        var count = 0
        var index = 0
        while index + 3 < data.count {
            let red = Int(data[index])
            let green = Int(data[index + 1])
            let blue = Int(data[index + 2])
            if red > green + 15 && green > blue + 8 && data[index + 3] > 80 { count += 1 }
            index += 4
        }
        return count
    }

    /// Mean luma of the centred box, where the stop mark is drawn. `crop` is the
    /// box side as a fraction of the face, so a small mark can be isolated.
    private func centreMean(_ shot: (image: CGImage, data: [UInt8]), crop: Double) -> Double {
        let width = shot.image.width
        let height = shot.image.height
        let side = max(1, Int(Double(min(width, height)) * crop))
        let box = ((width - side) / 2)..<((width - side) / 2 + side)
        let rows = ((height - side) / 2)..<((height - side) / 2 + side)
        var total = 0
        var count = 0
        for y in rows {
            for x in box {
                let offset = (y * width + x) * 4
                total += Int(shot.data[offset]) + Int(shot.data[offset + 1]) + Int(shot.data[offset + 2])
                count += 3
            }
        }
        return count == 0 ? 0 : Double(total) / Double(count)
    }
}
