import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Pure policy for what a finished drag on the mode row means.
///
/// A deliberate horizontal swipe moves to the neighbouring *visible* mode.
/// A vertical or ambiguous drag selects nothing, so the row never intercepts a
/// vertical scroll. Because the policy only ever walks `visibleModes`, no swipe
/// — however long — can reach the hidden photo slot.
struct CameraModeCarouselGestureTests {
    @Test func aHorizontalSwipeSelectsTheNeighbouringVisibleMode() {
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: -60, height: 4), from: .develop)
                == .select(.video))
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: 60, height: 4), from: .video)
                == .select(.develop))
    }

    @Test func aSwipeNeverOverscrollsPastTheVisibleModes() {
        // Already at the leading edge and swiping back, or at the trailing edge
        // and swiping on, is a no-op — there is nowhere (least of all photo) to go.
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: 60, height: 0), from: .develop) == .none)
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: -60, height: 0), from: .video) == .none)
        for width: CGFloat in [-400, -60, 60, 400] {
            #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: width, height: 0), from: .develop)
                    != .select(.photo))
            #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: width, height: 0), from: .video)
                    != .select(.photo))
        }
    }

    @Test func verticalAndAmbiguousDragsSelectNothing() {
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: 0, height: 90), from: .develop) == .none)
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: 30, height: 60), from: .develop) == .none)
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: -40, height: 55), from: .video) == .none)
    }

    @Test func aShortNudgeIsNotADeliberateSwipe() {
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: 12, height: 0), from: .develop) == .none)
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: -12, height: 0), from: .video) == .none)
    }
}

/// Native proof of the real row. These render the actual `CameraModeCarousel`
/// with `ImageRenderer` and measure its pixels, so a blank or mis-sized row
/// fails here rather than shipping. Nothing in this suite claims gesture
/// recognition — SwiftUI resolves drags at runtime; the policy above pins what a
/// resolved drag means.
@MainActor
struct CameraModeCarouselRenderTests {
    private let narrowWidth: CGFloat = 200
    private let defaultWidth: CGFloat = 360

    @Test func rendersNonBlankWithTheActiveLetterInOrangeAtBothWidths() throws {
        for width in [narrowWidth, defaultWidth] {
            for mode in CameraMode.visibleModes {
                let image = try render(carousel(active: mode), width: width,
                                       name: "carousel-\(mode.rawValue)-\(Int(width))")
                #expect(image.height == Int(CameraModeCarousel.height * 2),
                        "The row keeps its fixed height at every width.")
                let data = try pixels(image)
                #expect(ink(data) > 400, "The mode letters must be visible at \(width)pt.")
                #expect(orangeInk(data) > 40, "The active letter must paint the selected orange at \(width)pt.")
            }
        }
    }

    @Test func keepsAStableFootprintWhenTheActiveModeChanges() {
        // The inactive word is laid out (reserving space) but not painted, so the
        // row's measured width must not move as the selected mode changes.
        let developSize = fittingSize(carousel(active: .develop))
        let videoSize = fittingSize(carousel(active: .video))
        #expect(developSize == videoSize,
                "Reserving the label space must keep the row's footprint identical as the active label moves.")
        #expect(developSize.height == CameraModeCarousel.height)
    }

    @Test func onlyTheActiveModePaintsItsLowercaseTitle() throws {
        // If both words were always painted the two renders would carry the same
        // glyph coverage. Because only the active word is painted, the longer
        // "develop" state carries strictly more ink than "video".
        let develop = try pixels(render(carousel(active: .develop), width: defaultWidth, name: "carousel-develop"))
        let video = try pixels(render(carousel(active: .video), width: defaultWidth, name: "carousel-video"))
        #expect(develop != video, "The active label moves, so the two states cannot render identically.")
        #expect(ink(develop) > ink(video),
                "Only the active lowercase title is painted, so the longer active word carries more ink.")
    }

    // MARK: - Helpers

    private func carousel(active: CameraMode) -> some View {
        CameraModeCarousel(selected: active, enabled: true, onSelect: { _ in })
    }

    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func render(_ view: some View, width: CGFloat, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: width, height: CameraModeCarousel.height))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = TestRepository.artifactDirectory("camera-mode-carousel")
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

    /// Count of visibly painted pixels (the row draws on a transparent ground).
    private func ink(_ data: [UInt8]) -> Int {
        stride(from: 0, to: data.count, by: 4).filter { data[$0 + 3] > 20 }.count
    }

    /// Count of pixels matching SwiftUI's orange (sRGB 1.0, 0.584, 0.0).
    private func orangeInk(_ data: [UInt8]) -> Int {
        var count = 0
        var index = 0
        while index + 3 < data.count {
            let red = Int(data[index])
            let green = Int(data[index + 1])
            let blue = Int(data[index + 2])
            let alpha = Int(data[index + 3])
            if alpha > 128, red > 150, green > 60, green < 210, blue < 120, red > blue + 60 {
                count += 1
            }
            index += 4
        }
        return count
    }
}
