import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Correction contract for the live recording indicator. The lamp and timer are
/// presentation for a confirmed `.recording` take only — never idle, starting or
/// finalizing. Portrait hands the toolbar's rightmost first-row slot to the
/// timer and hides the lens; landscape keeps the physical-edge overlay and
/// leaves a clear 44pt lens slot. Geometry is measured from the natural size of
/// the slot's occupant, never from a fixed reserve, so idle and recording share
/// one toolbar height and the framed preview cannot jump.
struct LiveRecordingStatusTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.url(for: path), encoding: .utf8)
    }

    // MARK: - Native tally render (frame 24x24)

    @MainActor
    @Test func tallyRendersNothingWhileIdleAndOpaqueRedWhileRecording() throws {
        let idle = try render(tallyFrame(false), name: "tally-idle")
        let active = try render(tallyFrame(true), name: "tally-active")
        // Idle draws nothing at all: no dark-red lens, no bezel, zero alpha.
        #expect(alphaInk(idle) == 0, "An idle tally must be entirely transparent, with no lens or bezel.")
        #expect(redInk(idle) == 0)
        // A live take paints a steady, opaque red lamp.
        #expect(redInk(active) > 20, "A live tally must paint a visible red lamp.")
        #expect(alphaInk(active) > 20, "The live lamp must be opaque, not a faint ghost.")
    }

    @MainActor
    private func tallyFrame(_ isRecording: Bool) -> some View {
        ZStack {
            Color.clear.frame(width: 24, height: 24)
            RecordingTallyLight(isRecording: isRecording)
        }
        .frame(width: 24, height: 24)
    }

    // MARK: - Pure geometry (320 / 390 / 430 viewports)

    @Test func portraitTimerOwnsTheRightmostSlotWithoutClipping() {
        let timer = CGSize(width: 112, height: 40)
        let lens = CGSize(width: 44, height: 44)
        for viewport: CGFloat in [320, 390, 430] {
            let width = viewport - 32
            let geometry = CameraTopPanelGeometry(width: width, statusSize: timer,
                                                  lensSize: lens, diagnosticsHeight: 44)
            // Right-aligned at its measured width, never clipped by the edge.
            #expect(geometry.status.width == timer.width)
            #expect(geometry.status.maxX == width)
            #expect(geometry.status.minX >= geometry.manual.maxX)
            #expect(!geometry.status.intersects(geometry.settings))
            #expect(!geometry.status.intersects(geometry.manual))
            // The lens slot the timer replaces is hidden.
            #expect(geometry.lens.isEmpty)
            // First row keeps its 44pt height; the timer fits inside it.
            #expect(geometry.settings.height == 44)
            #expect(geometry.status.minY >= 0 && geometry.status.maxY <= 44)
            // No second-row timer: the diagnostics rail alone owns row two.
            #expect(geometry.diagnostics.minY >= geometry.status.maxY)
        }
    }

    @Test func idleAndRecordingShareOneToolbarHeight() {
        let lens = CGSize(width: 44, height: 44)
        for viewport: CGFloat in [320, 390, 430] {
            for diagnosticsHeight: CGFloat in [0, 44, 92] {
                let width = viewport - 32
                let idle = CameraTopPanelGeometry(width: width, statusSize: .zero,
                                                  lensSize: lens, diagnosticsHeight: diagnosticsHeight)
                let live = CameraTopPanelGeometry(width: width, statusSize: CGSize(width: 112, height: 40),
                                                  lensSize: lens, diagnosticsHeight: diagnosticsHeight)
                #expect(idle.height == live.height, "The toolbar must not jump when a take starts.")
                #expect(idle.status.isEmpty)
                #expect(idle.lens.width == 44 && idle.lens.maxX == width)
                #expect(live.lens.isEmpty)
            }
        }
    }

    @Test func landscapeKeepsTheQuarterTurnedFaceOffTheToolbar() {
        for viewport: CGFloat in [320, 390, 430] {
            let width = viewport - 32
            let geometry = CameraTopPanelGeometry(width: width, statusSize: CGSize(width: 40, height: 112),
                                                  lensSize: CGSize(width: 44, height: 44), diagnosticsHeight: 92)
            // The quarter-turned face belongs to the physical edge, not the row.
            #expect(geometry.status.isEmpty)
            // A clear 44pt slot is left where the lens sits under the floating timer.
            #expect(geometry.lens.width == 44 && geometry.lens.maxX == width && geometry.lens.maxY <= 44)
            #expect(geometry.height == CGFloat(142))
        }
    }

    // MARK: - Source wiring

    @Test func dotAndTimerExistOnlyForAConfirmedTake() throws {
        let screen = try source("App/ContentView.swift")
        // Framed and immersive tallies share one committed-state gate.
        let tallyGate = "RecordingTallyLight(isRecording: recordPresentation == .recording)"
        #expect(screen.components(separatedBy: tallyGate).count == 3,
                "Both the framed and immersive tallies must gate on the committed presentation.")
        // The face is gated behind the same state; no idle placeholder survives.
        #expect(screen.contains("if recordPresentation == .recording {"))
        #expect(!screen.contains("--:--.--"))
        #expect(!screen.contains("cameraViewModel.isRecording && !cameraViewModel.isStoppingRecording"))
    }

    @Test func portraitReplacesTheLensWhileLandscapeKeepsTheEdgeOverlay() throws {
        let screen = try source("App/ContentView.swift")
        let layout = try source("App/Modules/CameraCapture/CameraTopPanelLayout.swift")
        // Portrait keeps the toolbar; landscape keeps the physical-edge overlay.
        #expect(screen.contains("CameraTopPanel(statusInToolbar: abs(statusRotationDegrees) != 90)"))
        #expect(screen.contains("RecordingStatusOverlay(viewport: geometry.size"))
        // The rightmost slot is measured, never hardcoded to the old 84pt reserve.
        #expect(layout.contains("lensSize: subviews[2].sizeThatFits(.unspecified)"))
        #expect(!layout.contains("width: 84"))
        // The lens switch is hidden while a take is live in both holds.
        #expect(screen.contains(".opacity(recordPresentation == .recording ? 0 : 1)"))
    }

    @Test func tallyViewHasNoIdleLensOrBezelInk() throws {
        let tally = try source("App/Modules/CameraCapture/RecordingTallyLight.swift")
        #expect(tally.contains("if isRecording {"))
        #expect(!tally.contains("Color(red: 0.22, green: 0.045, blue: 0.035)"))
    }

    // MARK: - Render helpers

    @MainActor
    private func render(_ view: some View, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = TestRepository.artifactDirectory("live-recording-status")
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

    private func redInk(_ image: CGImage) -> Int {
        guard let data = try? pixels(image) else { return 0 }
        return stride(from: 0, to: data.count, by: 4).filter { index in
            data[index] > 170 && data[index + 1] < 90 && data[index + 2] < 90 && data[index + 3] > 100
        }.count
    }

    private func alphaInk(_ image: CGImage) -> Int {
        guard let data = try? pixels(image) else { return 0 }
        return stride(from: 3, to: data.count, by: 4).filter { data[$0] > 8 }.count
    }
}
