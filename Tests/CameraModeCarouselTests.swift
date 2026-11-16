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

    /// The accent the appearance layer resolves for a daylight stock. Injected
    /// explicitly so the row's selection colour is pinned by the test instead of
    /// inherited from whatever the appearance layer defaults to.
    private let testAccent = Color(.sRGB, red: 0.95, green: 0.45, blue: 0.12, opacity: 1)

    @Test func compactStripFitsItsRealCameraSlotWithoutDrawingOutsideIt() throws {
        // The touch strip remains 44pt. The approved mode caption has a separate
        // non-interactive band below it; no ink may escape their combined bounds.
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
                var captionInk = 0
                let stripBottom = (margin + Int(CameraModeCarousel.height)) * scale
                let captionBottom = stripBottom + Int(CameraModeCarousel.captionHeight) * scale
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        let inside = x >= margin * scale && x < (margin + Int(width)) * scale
                            && y >= margin * scale && y < captionBottom
                        let paints = data[(y * image.width + x) * 4 + 3] > 20
                        if !inside, paints { outside += 1 }
                        if inside, paints, y >= stripBottom { captionInk += 1 }
                    }
                }
                #expect(outside == 0, "Track and caption must stay inside the \(width)pt slot and reserved caption band.")
                #expect(captionInk > 20, "The selected mode name must actually draw below the unchanged touch strip.")
            }
        }
    }

    /// Both finishes now draw the same compact row: the selected capital on its
    /// 28pt disc at the slot's centre, its neighbour a 32pt pitch beside it, and
    /// no word caption in either style. Classic's old 44pt cells with the
    /// full-size caption are gone, so this pin renders both styles and requires
    /// them to agree rather than describing a Classic-only treatment.
    @Test func centresTheSelectedLetterOnTheCompactPitchWithoutACaption() throws {
        #expect(CameraModeCarousel.minimumControlWidth == 44,
                "The centred selected target keeps the 44pt touch floor.")

        for width: CGFloat in [narrowWidth, defaultWidth] {
            let centreInPoints = Double(width) / 2
            for active in CameraMode.visibleModes {
                let classicImage = try render(carousel(active: active)
                    .environment(\.cameraUIStyle, .classic), width: width,
                                              name: "carousel-classic-\(active.rawValue)-\(Int(width))")
                let image = try render(carousel(active: active)
                    .environment(\.cameraUIStyle, .minimal), width: width,
                                       name: "carousel-centred-\(active.rawValue)-\(Int(width))")
                #expect(image.height == Int(CameraModeCarousel.height * 2),
                        "The row keeps its fixed height at every width.")
                let data = try pixels(classicImage)
                let minimalData = try pixels(image)
                #expect(ink(data) > 400, "The mode letters must be visible at \(width)pt.")

                // The active capital paints the accent and sits centred — not
                // parked in a left or right half. Both finishes draw the same
                // capitals; only the well's face behind them differs.
                let letter = pixels(matching: accentInk, in: data, image: classicImage)
                let minimalLetter = pixels(matching: accentInk, in: minimalData, image: image)
                #expect(letter.count > 40, "The selected letter must paint the accent at \(width)pt.")
                #expect(abs(letter.count - minimalLetter.count) <= 4,
                        "Both finishes draw the same accent capital at \(width)pt.")
                let letterMidX = Double(letter.map(\.x).reduce(0, +)) / Double(letter.count) / 2
                #expect(abs(letterMidX - centreInPoints) <= 2,
                        "The selected letter is centred, not owned by a half.")

                // 28pt discs on a 4pt gap leave no room for a word: the shared
                // label paints no caption. Measured on Minimal's charcoal well,
                // where the only bright ink could be type.
                let caption = pixels(matching: brightInk, in: minimalData, image: image)
                #expect(caption.isEmpty,
                        "The compact row prints no caption at \(width)pt.")

                // The neighbour keeps only a ghosted letter, on the correct side,
                // one 32pt pitch away: D always reads left of V. Measured inside
                // that neighbour's own cell on the flat Minimal face over an
                // opaque ground: a 0.45-alpha ghost on a transparent ground is an
                // almost-white no grey mask catches, and Classic's translucent
                // material plus its inset rim flood the same grey band, so that
                // mask averages the well's bevel with the glyph instead of
                // reading one letter.
                let letterTop = try #require(letter.map(\.y).min())
                let letterBottom = try #require(letter.map(\.y).max())
                let groundedImage = try render(carousel(active: active)
                    .environment(\.cameraUIStyle, .minimal)
                    .background(Color.black), width: width,
                                               name: "carousel-grounded-\(active.rawValue)-\(Int(width))")
                let groundedScale = Double(groundedImage.width) / Double(width)
                let modes = CameraMode.visibleModes
                let selectedIndex = try #require(modes.firstIndex(of: active))
                let neighbourIndex = selectedIndex == 0 ? min(1, modes.count - 1) : selectedIndex - 1
                let neighbourOffset = Double(CameraModeRowLayout.compactCellOffset(
                    index: neighbourIndex, selectedIndex: selectedIndex))
                let neighbourCentre = centreInPoints + neighbourOffset
                // The neighbour's own cell, clipped where the strip clips it: the
                // only place its capital can legitimately paint.
                let cellReach = Double(CameraModeRowLayout.compactCellWidth) / 2
                let viewportHalf = Double(min(width, CameraModeRowLayout.compactGroupWidth(
                    visibleCount: modes.count))) / 2
                let cellLow = neighbourCentre - cellReach
                let cellHigh = min(neighbourCentre + cellReach, centreInPoints + viewportHalf)
                let ghost = pixels(matching: ghostInk, in: try pixels(groundedImage), image: groundedImage)
                    .filter { $0.y >= letterTop && $0.y <= letterBottom }
                    .filter {
                        let x = Double($0.x) / groundedScale
                        return (x - centreInPoints) * neighbourOffset > 0
                            && x >= cellLow - 0.5 && x <= cellHigh + 0.5
                    }
                #expect(ghost.count > 20, "The neighbouring mode is still drawn inside its own cell.")
                let ghostMidX = Double(ghost.map(\.x).reduce(0, +)) / Double(max(ghost.count, 1)) / groundedScale
                #expect(ghostMidX >= cellLow - 1 && ghostMidX <= cellHigh + 1,
                        "Ghost cell \(cellLow)...\(cellHigh)pt; centroid \(ghostMidX)pt.")
                #expect((26...38).contains(abs(ghostMidX - letterMidX)),
                        "The ghosted letter reads one 32pt pitch away (saw \(abs(ghostMidX - letterMidX))pt).")
                #expect((ghostMidX - letterMidX).sign == neighbourOffset.sign,
                        "The ghost sits on the correct side of the selection.")
                // Classic still ghosts its neighbour; the pitch is measured on
                // the face whose grey ink can only be a glyph.
                #expect(!pixels(matching: dimInk, in: data, image: classicImage)
                    .filter { $0.y >= letterTop && $0.y <= letterBottom }.isEmpty,
                    "The classic row still shows its neighbouring mode.")
            }
        }
    }

    @Test func aDisabledRowDimsAndSwallowsSwipe() throws {
        let enabled = try pixels(render(carousel(active: .develop, enabled: true),
                                        width: defaultWidth, name: "carousel-enabled"))
        let disabled = try pixels(render(carousel(active: .develop, enabled: false),
                                         width: defaultWidth, name: "carousel-disabled"))
        // The selected letter now sits on a flat fill, so the dim count is the
        // same either way; the row must still *dim*, measured as painted
        // intensity rather than as a count of touched pixels.
        #expect(inkMass(disabled) < inkMass(enabled), "A disabled row dims its glyphs and its fill.")
        #expect(inkMass(disabled) > 0, "A disabled row is dimmed, not erased.")

        let view = CameraModeCarousel(selected: .develop, enabled: false, onSelect: { _ in })
        #expect(view.resolvedSwipe(CGSize(width: -80, height: 0)) == .none,
                "A disabled row swallows a swipe.")

        // It does not swallow a tap: the letter answers with the reason instead.
        #expect(view.resolvedTap(.video) == .refused(.video),
                "A dimmed letter must answer a tap, not ignore it.")
        let live = CameraModeCarousel(selected: .develop, enabled: true, onSelect: { _ in })
        #expect(live.resolvedTap(.video) == .select(.video))
    }

    @Test func landscapeLabelsRotateWithoutExpandingTheStrip() throws {
        for width: CGFloat in [96, 200] {
            for mode in CameraMode.visibleModes {
                let upright = try pixels(render(carousel(active: mode), width: width, name: "upright-\(mode.rawValue)"))
                for degrees in [-90.0, 90.0] {
                    let view = CameraModeCarousel(selected: mode, enabled: true, rotationDegrees: degrees, onSelect: { _ in })
                    let rotated = try pixels(render(view, width: width, name: "landscape-\(mode.rawValue)-\(Int(degrees))"))
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
        let renderer = ImageRenderer(content: view
            .frame(width: width, height: CameraModeCarousel.height)
            .environment(\.cameraControlAccent, testAccent))
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

    /// The ghosted neighbour: a dim, unaccented grey, with no alpha ceiling so a
    /// capital composited over an opaque ground still counts whole.
    private func ghostInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 25 && red > 40 && red < 170
            && abs(red - green) < 6 && abs(green - blue) < 6
    }

    /// The ghosted neighbour on a transparent ground: a dim, unaccented grey.
    private func dimInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 25 && alpha < 150 && red > 40 && red < 160
            && abs(red - green) < 6 && abs(green - blue) < 6
    }

    /// Count of visibly painted pixels (the row draws on a transparent ground).
    private func ink(_ data: [UInt8]) -> Int {
        stride(from: 0, to: data.count, by: 4).filter { data[$0 + 3] > 20 }.count
    }

    /// Total painted intensity, so a dimmed row is measurably quieter than a
    /// live one even when both touch the same pixels.
    private func inkMass(_ data: [UInt8]) -> Int {
        stride(from: 3, to: data.count, by: 4).reduce(0) { $0 + Int(data[$1]) }
    }
}
