import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Contract for the live recording indicator. The lamp and timer are optimistic:
/// they appear on the record tap — while capture is still `.starting` — as well
/// as for a confirmed `.recording` take, so the UI answers the tap at once
/// instead of waiting for the writer to confirm. Idle and finalizing stay hidden,
/// so a cancelled start and a failed start (both of which roll back to idle)
/// leave no chrome behind. Portrait floats the timer at the toolbar's horizontal
/// centre; landscape keeps the physical-edge overlay. Timer and diagnostics never
/// reserve space or resize the framed preview.
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

    @Test func portraitTimerIsCenteredWithoutReservingAControlSlot() {
        let timer = CGSize(width: 112, height: 40)
        let lens = CGSize(width: 44, height: 44)
        for viewport: CGFloat in [320, 390, 430] {
            let width = viewport - 32
            let geometry = CameraTopPanelGeometry(width: width, statusSize: timer,
                                                  lensSize: lens, diagnosticsHeight: 44)
            // Placement is relative to the viewport, not a left/right control slot.
            #expect(geometry.status.width == timer.width)
            #expect(geometry.status.midX == width / 2)
            #expect(geometry.status.minX >= 0 && geometry.status.maxX <= width)
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
                #expect(idle.height == 50, "Floating diagnostics cannot reserve preview space.")
                #expect(idle.status.isEmpty)
                #expect(idle.lens.width == 44 && idle.lens.maxX == width)

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
            #expect(geometry.height == CGFloat(50))
        }
    }

    // MARK: - Source wiring

    @Test func dotAndTimerAppearFromTheTapAndHideWhenIdleOrFinalizing() throws {
        let screen = try source("App/ContentView.swift")
        // Framed and immersive tallies share one optimistic gate: the lamp lights
        // on the tap, while capture is still spinning up, not only once confirmed.
        let tallyGate = "RecordingTallyLight(isRecording: recordPresentation.showsLiveChrome)"
        #expect(screen.components(separatedBy: tallyGate).count == 3,
                "Both tallies must light from the tap, on the shared optimistic gate.")
        // The timer face and the lens-hiding follow the same one gate; no
        // recording chrome may wait for a confirmed take before it shows.
        #expect(screen.contains("if recordPresentation.showsLiveChrome {"))
        #expect(!screen.contains("recordPresentation == .recording"),
                "No chrome may gate on the confirmed take alone; the tap must show it.")
        #expect(!screen.contains("--:--.--"))
        #expect(!screen.contains("cameraViewModel.isRecording && !cameraViewModel.isStoppingRecording"))
    }

    /// The one idle off-ramp that survives the live-only timer: while the
    /// session-only 60 fps mode is armed and no take is running, the armed badge
    /// is the only way back to 24 fps once the rescue trigger has dropped below
    /// its threshold. It is the status face in its idle-armed form, so it carries
    /// no recording mark and no elapsed timer.
    @Test func armedIdleBadgeIsTheOnlyIdleChromeAndCarriesNoTimer() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("!shouldOfferDaylightRescue, recordPresentation == .idle,"))
        #expect(screen.contains("cameraViewModel.sessionFrameRate == .daylight60,"))
        #expect(screen.contains("DaylightIdleBadgeGeometry.rect("))
        #expect(screen.contains("statusFace(text: \"\")"),
                "The idle badge must pass an empty timer text, never a placeholder.")
        // A non-sizing sibling, exactly like the rescue button: never a slot.
        let badge = try source("App/Modules/CameraCapture/ExposureRescueControl.swift")
        #expect(badge.contains("enum DaylightIdleBadgeGeometry"))
        #expect(badge.contains("static let badgeSize = CGSize(width: 112, height: 40)"))
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
        // The lens switch is hidden from the tap, in both holds, so it never
        // collides with the optimistic timer that now shares the empty slot.
        #expect(screen.contains(".opacity(recordPresentation.showsLiveChrome ? 0 : 1)"))
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
