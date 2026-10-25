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
    @Test func aHorizontalSwipeSelectsTheNeighbouringVisibleModeAndNeverReachesPhoto() {
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: -60, height: 4), from: .develop)
                == .select(.video))
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: 60, height: 4), from: .video)
                == .select(.develop))

        // At either edge a swipe back has nowhere — least of all the hidden
        // photo slot — to go.
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: 60, height: 0), from: .develop) == .none)
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: -60, height: 0), from: .video) == .none)
        for width: CGFloat in [-400, -60, 60, 400] {
            #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: width, height: 0), from: .develop)
                    != .select(.photo))
            #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: width, height: 0), from: .video)
                    != .select(.photo))
        }
    }

    @Test func verticalAmbiguousAndShortDragsSelectNothing() {
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: 0, height: 90), from: .develop) == .none)
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: 30, height: 60), from: .develop) == .none)
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: -40, height: 55), from: .video) == .none)
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: 12, height: 0), from: .develop) == .none)
        #expect(CameraModeCarouselGesture.outcome(translation: CGSize(width: -12, height: 0), from: .video) == .none)
    }
}

/// Native proof of the real centred row. These render the actual
/// `CameraModeCarousel` with `ImageRenderer` and measure its pixels, so the
/// centred selection, its lower caption band, the ghosted neighbour's side and
/// the row's footprint are pinned to what is drawn — not to geometry or source
/// strings.
@MainActor
struct CameraModeCarouselRenderTests {
    private let narrowWidth: CGFloat = 96
    private let defaultWidth: CGFloat = 200

    @Test func compactStripFitsItsRealCameraSlotWithoutDrawingOutsideIt() throws {
        // The row's fixed height is the touch floor; the bounds check below
        // renders at exactly that height. 96/120pt are the compact fallback
        // slots, 180/200pt are ordinary widths.
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
                #expect(outside == 0, "The centred row must stay inside the \\(width)pt camera slot.")
            }
        }
    }

    @Test func centresTheSelectedLetterWithItsCaptionBelowAndTheGhostBeside() throws {
        #expect(CameraModeCarousel.minimumControlWidth == 44,
                "The centred selected target keeps the 44pt touch floor.")
        var captionInk: [CameraMode: Int] = [:]

        for width: CGFloat in [narrowWidth, defaultWidth] {
            let centreInPoints = Double(width) / 2
            for active in CameraMode.visibleModes {
                let image = try render(carousel(active: active), width: width,
                                       name: "carousel-centred-\\(active.rawValue)-\\(Int(width))")
                #expect(image.height == Int(CameraModeCarousel.height * 2),
                        "The row keeps its fixed height at every width.")
                let data = try pixels(image)
                #expect(ink(data) > 400, "The mode letters must be visible at \\(width)pt.")

                // The active capital paints the accent and sits centred — not
                // parked in a left or right half.
                let letter = pixels(matching: accentInk, in: data, image: image)
                #expect(letter.count > 40, "The selected letter must paint the accent at \\(width)pt.")
                let letterMidX = Double(letter.map(\.x).reduce(0, +)) / Double(letter.count) / 2
                #expect(abs(letterMidX - centreInPoints) <= centreInPoints * 0.1,
                        "The selected letter is centred, not owned by a half.")

                // Its lowercase caption is a band strictly below the capital.
                let caption = pixels(matching: brightInk, in: data, image: image)
                #expect(caption.count > 20, "The selected mode paints its lowercase caption at \\(width)pt.")
                let captionMidY = Double(caption.map(\.y).reduce(0, +)) / Double(max(caption.count, 1))
                let letterMidY = Double(letter.map(\.y).reduce(0, +)) / Double(letter.count)
                #expect(captionMidY > letterMidY + 8,
                        "The caption sits in a band below the capital, not beside it.")
                captionInk[active, default: 0] += caption.count

                // The neighbour keeps only a ghosted letter, on the correct side:
                // D always reads left of V.
                let ghost = pixels(matching: dimInk, in: data, image: image)
                let ghostLeft = ghost.filter { $0.x < image.width / 2 }.count
                let ghostRight = ghost.filter { $0.x >= image.width / 2 }.count
                if active == .develop {
                    #expect(ghostRight > ghostLeft, "Develop centred leaves the ghosted V to its right.")
                } else {
                    #expect(ghostLeft > ghostRight, "Video centred leaves the ghosted D to its left.")
                }
            }
        }

        // Only the selected caption is painted, so the longer active word
        // carries strictly more caption ink than the shorter one.
        #expect(captionInk[.develop, default: 0] > captionInk[.video, default: 0],
                "Only the selected lowercase caption is painted, so 'develop' outweighs 'video'.")
    }

    @Test func aDisabledRowDimsAndSwallowsSwipe() throws {
        let enabled = try pixels(render(carousel(active: .develop, enabled: true),
                                        width: defaultWidth, name: "carousel-enabled"))
        let disabled = try pixels(render(carousel(active: .develop, enabled: false),
                                         width: defaultWidth, name: "carousel-disabled"))
        #expect(ink(disabled) < ink(enabled), "A disabled row dims its glyphs.")
        #expect(ink(disabled) > 0, "A disabled row is dimmed, not erased.")

        let view = CameraModeCarousel(selected: .develop, enabled: false, onSelect: { _ in })
        #expect(view.resolvedSwipe(CGSize(width: -80, height: 0)) == .none,
                "A disabled row swallows a swipe.")
    }

    @Test func landscapeLabelsRotateWithoutExpandingTheStrip() throws {
        for width: CGFloat in [96, 200] {
            for mode in CameraMode.visibleModes {
                let upright = try pixels(render(carousel(active: mode), width: width, name: "upright-\\(mode.rawValue)"))
                for degrees in [-90.0, 90.0] {
                    let view = CameraModeCarousel(selected: mode, enabled: true, rotationDegrees: degrees, onSelect: { _ in })
                    let rotated = try pixels(render(view, width: width, name: "landscape-\\(mode.rawValue)-\\(Int(degrees))"))
                    let different = rotated != upright
                    #expect(different)
                    #expect(ink(rotated) > 100)
                    #expect(rotated.count == upright.count)
                }
            }
        }
    }

    // MARK: - Helpers

    private struct Pixel { let x: Int; let y: Int }

    private func carousel(active: CameraMode, enabled: Bool = true) -> some View {
        CameraModeCarousel(selected: active, enabled: enabled, onSelect: { _ in })
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

    /// Every pixel matching `predicate`, with its coordinates, so a test can
    /// measure where a colour actually landed rather than trusting geometry.
    private func pixels(matching predicate: (Int, Int, Int, Int) -> Bool,
                        in data: [UInt8], image: CGImage) -> [Pixel] {
        var result: [Pixel] = []
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                if predicate(Int(data[index]), Int(data[index + 1]), Int(data[index + 2]), Int(data[index + 3])) {
                    result.append(Pixel(x: x, y: y))
                }
            }
        }
        return result
    }

    /// The selected capital's accent (SwiftUI orange, sRGB 1.0, 0.584, 0.0).
    private func accentInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 128 && red > 150 && green > 60 && green < 210 && blue < 120 && red > blue + 60
    }

    /// The selected caption's near-white glyph core; the transparent inactive
    /// caption and the dim ghost both fall below the alpha gate.
    private func brightInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 128 && red > 170 && green > 170 && blue > 170
    }

    /// The ghosted neighbour: a dim, unaccented grey.
    private func dimInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 25 && alpha < 150 && red > 40 && red < 160
            && abs(red - green) < 30 && abs(green - blue) < 30
    }

    /// Count of visibly painted pixels (the row draws on a transparent ground).
    private func ink(_ data: [UInt8]) -> Int {
        stride(from: 0, to: data.count, by: 4).filter { data[$0 + 3] > 20 }.count
    }
}
