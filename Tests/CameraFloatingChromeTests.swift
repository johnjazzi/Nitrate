import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Floating-chrome contract. Camera chrome that lives in an overlay must never
/// participate in the measured toolbar or in the framed-preview rectangle.
///
/// The toolbar's own height is the stationary 44pt keys plus the existing 6pt
/// gap, so a rotation, an idle/live switch, a DEBUG/FAULT toggle or a timer tick
/// cannot move the preview. The portrait timer is a centered overlay position —
/// never right-slotted against the lens and never resized to fit a control. The
/// DEBUG/FAULT rail is a separate non-sizing sibling overlay outside the
/// measured top bar, so it stays off the framing bounds while its round 44pt
/// keys keep their actions. These are pure-geometry and native-compositing
/// checks; nothing here asserts camera hardware behavior.
struct CameraFloatingChromeTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.url(for: path), encoding: .utf8)
    }

    private let portraitStatus = CGSize(width: 112, height: 40)
    private let landscapeStatus = CGSize(width: 40, height: 112)
    private let phoneWidths: [CGFloat] = [288, 358, 398]

    // MARK: - One rotation-agnostic framed-preview frame edge

    @Test func framingBottomIgnoresRotation() {
        for bottom: CGFloat in [52, 58, 74, 92, 170] {
            for degrees in [0.0, 90.0, -90.0, 180.0] {
                let framed = CameraTopPanelGeometry.framingBottom(toolbarBottom: bottom, rotationDegrees: degrees)
                #expect(framed == bottom,
                        "The framed preview must take the stationary toolbar bottom unchanged in every hold.")
            }
        }
    }

    // MARK: - Toolbar height never tracks the rail or the timer

    @Test func toolbarHeightIsTheStationaryKeysPlusTheGap() {
        for width in phoneWidths {
            for diagnosticsHeight: CGFloat in [0, 44, 92] {
                let idle = CameraTopPanelGeometry(width: width, statusSize: .zero,
                                                  diagnosticsHeight: diagnosticsHeight)
                let live = CameraTopPanelGeometry(width: width, statusSize: portraitStatus,
                                                  diagnosticsHeight: diagnosticsHeight)
                let turned = CameraTopPanelGeometry(width: width, statusSize: landscapeStatus,
                                                    diagnosticsHeight: diagnosticsHeight)
                // 44pt keys + the existing 6pt gap; never the rail, never the face.
                #expect(idle.height == 50)
                #expect(live.height == 50)
                #expect(turned.height == 50, "A quarter-turned face must not add a landscape ghost row.")
                // The diagnostics rect is retained for the existing geometry
                // contracts, but it is bookkeeping only — it never sizes chrome.
                #expect(idle.diagnostics.height == diagnosticsHeight)
                #expect(idle.diagnostics.minY == 50)
            }
        }
    }

    @Test func framedPreviewRectIsStableAcrossHoldsStatesAndChrome() {
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        let bottomControlsTop: CGFloat = 620
        var rects: [CGRect] = []
        for degrees in [0.0, 90.0, -90.0] {
            for statusSize in [CGSize.zero, portraitStatus] {
                for diagnosticsHeight: CGFloat in [0, 44, 92] {
                    let geometry = CameraTopPanelGeometry(width: 358, statusSize: statusSize,
                                                          diagnosticsHeight: diagnosticsHeight)
                    // The topBar's existing 8pt top padding rides on the measured bottom.
                    let toolbarBottom = geometry.height + 8
                    rects.append(FramedPreviewLayout.previewRect(
                        in: viewport,
                        topControlsBottom: CameraTopPanelGeometry.framingBottom(toolbarBottom: toolbarBottom,
                                                                               rotationDegrees: degrees),
                        bottomControlsTop: bottomControlsTop))
                }
            }
        }
        #expect(Set(rects).count == 1,
                "Portrait, both landscape holds, idle/live and DEBUG/FAULT must share one framed preview rectangle.")
    }

    // MARK: - Timer placement

    @Test func portraitTimerIsCenteredAndLandscapeLeavesTheRow() {
        for width in phoneWidths {
            let geometry = CameraTopPanelGeometry(width: width, statusSize: portraitStatus, diagnosticsHeight: 44)
            #expect(geometry.status.midX == width / 2, "The live portrait timer must be screen-centered, not right-slotted.")
            #expect(geometry.status.width == portraitStatus.width && geometry.status.height == portraitStatus.height,
                    "The timer keeps its natural measured size, never a resized slot.")
            #expect(geometry.status.minX > 0 && geometry.status.maxX < width)
            // The lens slot the timer replaces is hidden.
            #expect(geometry.lens.isEmpty)

            let turned = CameraTopPanelGeometry(width: width, statusSize: landscapeStatus, diagnosticsHeight: 44)
            #expect(turned.status.isEmpty, "A quarter-turned face belongs to the physical edge, not the toolbar row.")
            #expect(turned.lens.width == 44 && turned.lens.maxX == width)
        }
    }

    // MARK: - Source wiring

    @Test func measuredTopBarExcludesTheDiagnosticRail() throws {
        let screen = try source("App/ContentView.swift")
        let layout = try source("App/Modules/CameraCapture/CameraTopPanelLayout.swift")

        // The measured top bar's fifth slot stays concrete but renders nothing:
        // the DEBUG/FAULT rail no longer reserves toolbar height.
        let topBarBody = screen.components(separatedBy: "private var topBar").last ?? screen
        let measuredTopBar = topBarBody.components(separatedBy: "/// DEBUG/FAULT render").first ?? topBarBody
        #expect(measuredTopBar.contains("EmptyView()"))
        #expect(!measuredTopBar.contains("diagnosticButtons"))

        // The rail is a real, tappable sibling overlay below the stationary row
        // at x16 — not a custom-layout child outside its own hit-test bounds.
        #expect(screen.contains("debugControlsOverlay(in: geometry)"))
        #expect(screen.contains("debugControlsOverlay(in geometry: GeometryProxy)"))
        #expect(screen.contains("diagnosticButtons }"))
        #expect(screen.contains(".padding(.leading, 16)"))

        // The rotation-specific phantom reservation is gone; the stationary
        // bottom edge and the constant toolbar height remain.
        #expect(layout.contains("static func framingBottom(toolbarBottom: CGFloat, rotationDegrees: Double) -> CGFloat"))
        #expect(!layout.contains("abs(rotationDegrees) == 90 ?"))
        #expect(!layout.contains("50 + diagnosticsHeight"))
        #expect(layout.contains("height = 50"))
        #expect(layout.contains("(width - toolbarStatusSize.width) / 2"))
    }

    // MARK: - Native compositing (real toolbar, real conditional timer, overlay)

    @MainActor @Test func realToolbarAndDiagnosticOverlayCompositeWithoutResizingTheBar() throws {
        for degrees in [0.0, 90.0, -90.0] {
            for recording in [false, true] {
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
                        .opacity(recording ? 0 : 1)
                } status: {
                    if recording {
                        RecordingStatusFace(presentation: .recording, text: "00:01.00", rotationDegrees: degrees)
                    }
                } diagnostics: {
                    EmptyView()
                }
                .frame(width: 320)

                // The DEBUG/FAULT rail is a real sibling overlay below the
                // stationary row (x16, just under the measured 58pt edge) — the
                // same shape ContentView composites onto the canvas.
                let rail = VStack(spacing: 4) {
                    Text("DEBUG")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 44, height: 44).background(Circle().fill(.yellow))
                    Text("FAULT")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Circle().fill(.red))
                }
                .padding(.leading, 16)
                .padding(.top, 58)

                let composed = ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: 320, height: 260)
                    panel
                    rail
                }
                .frame(width: 320, height: 260)

                let image = try render(composed, name: "composite-\(Int(degrees))-\(recording)")
                #expect(image.width == 640)
                // The measured toolbar's own height is exactly the stationary
                // keys (44) plus the existing 8pt top padding — the timer, the
                // rail and the hold must never move this edge.
                let measured = try render(CameraTopPanel(statusInToolbar: degrees == 0) {
                    Color.clear.frame(width: 44, height: 44)
                } manual: {
                    Color.clear.frame(width: 44, height: 44)
                } lens: {
                    Color.clear.frame(width: 44, height: 44)
                } status: {
                    if recording {
                        RecordingStatusFace(presentation: .recording, text: "00:01.00", rotationDegrees: degrees)
                    }
                } diagnostics: {
                    EmptyView()
                }
                .frame(width: 320), name: "measured-\(Int(degrees))-\(recording)")
                #expect(measured.height == 116,
                        "The measured toolbar height must not change with the timer, the rail or the hold.")

                let data = try pixels(image)
                let settingsInk = stride(from: 0, to: data.count, by: 4).filter { index in
                    let column = (index / 4) % image.width
                    return column < 128 && Int(data[index + 1]) > Int(data[index]) + 50 && data[index + 1] > 80
                }
                let manualInk = stride(from: 0, to: data.count, by: 4).filter { index in
                    let column = (index / 4) % image.width
                    return column >= 144 && column < 232 && Int(data[index + 2]) > Int(data[index]) + 30
                }
                // The floating rail must actually draw below the stationary row
                // (image row 116+), proving it never stole toolbar bounds.
                let railInk = stride(from: 0, to: data.count, by: 4).filter { index in
                    let row = (index / 4) / image.width
                    return row > 130 && data[index + 3] > 8
                }
                #expect(settingsInk.count > 20, "The settings key must survive the overlay split.")
                #expect(manualInk.count > 20, "The manual key must survive the overlay split.")
                #expect(railInk.count > 200, "The DEBUG/FAULT overlay must draw as a real sibling below the row.")
            }
        }
    }

    // MARK: - Render helpers

    @MainActor
    private func render(_ view: some View, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = TestRepository.artifactDirectory("camera-floating-chrome")
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
