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

/// The row's fixed metrics, which the render shots below depend on. Kept
/// deterministic and non-rendering so the touch-target floor is pinned even
/// when the pixel suites are skipped.
struct CameraModeCarouselMetricsTests {
    @Test func theRowHeightIsTheMinimumTouchHeight() {
        #expect(CameraModeCarousel.height == 44)
    }

    @Test func theNarrowestRealSlotFitsTwoControlsAtTheTouchFloor() {
        // 96pt is the smallest camera slot the row is placed in; both mode
        // controls must still meet the 44pt touch width there.
        #expect(CameraModeCarousel.minimumControlWidth == 44)
        #expect(CameraModeCarousel.minimumControlWidth * 2 <= 96)
    }
}

/// Native proof of the real row. These render the actual `CameraModeCarousel`
/// with `ImageRenderer` and measure its pixels, so a blank or mis-sized row
/// fails here rather than shipping. Nothing in this suite claims gesture
/// recognition — SwiftUI resolves drags at runtime; the policy above pins what a
/// resolved drag means.
@MainActor
struct CameraModeCarouselRenderTests {
    private let narrowWidth: CGFloat = 96
    private let defaultWidth: CGFloat = 200

    @Test func compactStripFitsItsRealCameraSlotWithoutDrawingOutsideIt() throws {
        #expect(CameraModeCarousel.height == 44)
        let margin = 24
        let scale = 2
        for width: CGFloat in [96, 120, 180, 200] {
            for mode in CameraMode.visibleModes {
                let view = carousel(active: mode).frame(width: width, height: 44).padding(CGFloat(margin))
                let renderer = ImageRenderer(content: view)
                renderer.scale = CGFloat(scale)
                let image = try #require(renderer.cgImage)
                let data = try pixels(image)
                var outside = 0
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        let inside = x >= margin * scale && x < (margin + Int(width)) * scale
                            && y >= margin * scale && y < (margin + 44) * scale
                        if !inside, data[(y * image.width + x) * 4 + 3] > 20 { outside += 1 }
                    }
                }
                #expect(outside == 0, "Mode glyphs must stay inside the \(width)pt camera slot.")
            }
        }
    }

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
        let distinct = develop != video
        #expect(distinct, "The active label moves, so the two states cannot render identically.")
        #expect(ink(develop) > ink(video),
                "Only the active lowercase title is painted, so the longer active word carries more ink.")
    }

    @Test func onlyTheSelectedSidePaintsTheLowercaseWord() throws {
        // "D develop" / "V video": the lowercase word belongs to the selected
        // mode alone; the inactive side shows only its ghosted letter. Splitting
        // the render down the gap between the two controls measures this
        // directly — whichever half owns the selection must own the bulk of the
        // ink, because the word is drawn there and nowhere else.
        for (active, selectedIsLeft) in [(CameraMode.develop, true), (CameraMode.video, false)] {
            let image = try render(carousel(active: active), width: defaultWidth,
                                   name: "carousel-word-\(active.rawValue)")
            let data = try pixels(image)
            let left = ink(data, image: image, leftHalf: true)
            let right = ink(data, image: image, leftHalf: false)
            let selected = selectedIsLeft ? left : right
            let inactive = selectedIsLeft ? right : left
            #expect(selected > inactive,
                    "The selected word must paint only its own half; the inactive half keeps just a ghosted letter.")
        }
    }

    @Test func onlyTheSelectedSideCarriesTheAccentColour() throws {
        // Subtle emphasis, not a filled segmented control: exactly one letter is
        // accented. Measuring the accent per half proves the ghosted neighbour
        // never picks up the accent colour the selected letter alone carries.
        for (active, selectedIsLeft) in [(CameraMode.develop, true), (CameraMode.video, false)] {
            let image = try render(carousel(active: active), width: defaultWidth,
                                   name: "carousel-accent-\(active.rawValue)")
            let data = try pixels(image)
            let left = orangeInk(data, image: image, leftHalf: true)
            let right = orangeInk(data, image: image, leftHalf: false)
            let selected = selectedIsLeft ? left : right
            let inactive = selectedIsLeft ? right : left
            #expect(selected > 40, "The selected letter paints the accent colour.")
            #expect(inactive <= 4, "The ghosted neighbour is never accented, so the row is not a filled segmented control.")
        }
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

    /// Painted-pixel count restricted to one half of the row, split down the
    /// gap between the two controls (the midpoint never holds a glyph).
    private func ink(_ data: [UInt8], image: CGImage, leftHalf: Bool) -> Int {
        let midpoint = image.width / 2
        let columns = leftHalf ? 0..<midpoint : midpoint..<image.width
        var count = 0
        for y in 0..<image.height {
            for x in columns where data[(y * image.width + x) * 4 + 3] > 20 { count += 1 }
        }
        return count
    }

    /// Accent-colour count restricted to one half of the row, so the test can
    /// prove the accent sits on the selected side alone.
    private func orangeInk(_ data: [UInt8], image: CGImage, leftHalf: Bool) -> Int {
        let midpoint = image.width / 2
        let columns = leftHalf ? 0..<midpoint : midpoint..<image.width
        var count = 0
        for y in 0..<image.height {
            for x in columns {
                let index = (y * image.width + x) * 4
                let red = Int(data[index])
                let green = Int(data[index + 1])
                let blue = Int(data[index + 2])
                let alpha = Int(data[index + 3])
                if alpha > 128, red > 150, green > 60, green < 210, blue < 120, red > blue + 60 {
                    count += 1
                }
            }
        }
        return count
    }
}
