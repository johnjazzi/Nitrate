import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Visual conventions of the minimal camera chrome: the mode row's one flat
/// selection fill on its centred carousel, the unboxed recording status and the
/// unboxed queue/capacity face.
///
/// These pins cover what the new presentation *draws*. Behaviour — capture
/// phases, armed daylight 60, swipe thresholds, blocked-tap refusal, queue,
/// storage and render-queue state — stays asserted by the existing mode, mood
/// and design-render suites.
@MainActor
struct MinimalCameraModeTests {
    /// The accent the appearance layer resolves for a daylight stock. Injected
    /// rather than inherited, so the row's colour is pinned by the test.
    private let accent = Color(.sRGB, red: 0.95, green: 0.45, blue: 0.12, opacity: 1)

    // MARK: - Mode row

    /// The selected mode is one centred letter on a flat, accent-matched dark
    /// disc: no track, no ring, no raised face, and the disc is visibly smaller
    /// than the row's 44pt touch height.
    @Test func theSelectedLetterSitsOnOneFlatDarkFillAndGrowsNoRing() throws {
        #expect(CameraModeCarousel.selectionFillSize < CameraModeCarousel.minimumControlWidth,
                "The fill is the state; the 44pt target stays invisible.")

        for width: CGFloat in [96, 200] {
            for active in CameraMode.visibleModes {
                let image = try renderCarousel(active: active, width: width)
                let data = try pixels(image)
                let scale = Double(image.width) / Double(width)

                let letter = points(matching: accentInk, in: data, image: image)
                #expect(letter.count > 40, "The selected letter paints the resolved accent at \(width)pt.")
                let centre = CGPoint(
                    x: Double(letter.map(\.x).reduce(0, +)) / Double(letter.count),
                    y: Double(letter.map(\.y).reduce(0, +)) / Double(letter.count))

                let fill = points(matching: flatDarkFill, in: data, image: image)
                #expect(fill.count > 300, "The selected letter sits on a painted flat dark fill at \(width)pt.")
                let fillMidX = Double(fill.map(\.x).reduce(0, +)) / Double(fill.count)
                // Minimal's carousel holds the selected letter on the slot's
                // centre, so its disc is centred whatever the mode.
                let modes = CameraMode.visibleModes
                let selectedIndex = modes.firstIndex(of: active) ?? 0
                let cell = CameraModeRowLayout.compactCellRect(index: selectedIndex,
                                                               selectedIndex: selectedIndex,
                                                               slotWidth: width)
                #expect(abs(fillMidX - Double(width) / 2 * scale) <= 2 * scale,
                        "The fill holds the slot's centre with the selected letter.")
                #expect(abs(cell.midX - width / 2) <= 0.5,
                        "The pure geometry centres the selected cell too.")

                // Nothing bright is drawn just outside the fill's top arc: no
                // ring, rim or second decorative face. (The caption band below
                // the letter is excluded by the upper-half test.)
                let ring = points(matching: brightInk, in: data, image: image).filter { point in
                    let dx = Double(point.x) - centre.x
                    let dy = Double(point.y) - centre.y
                    let distance = (dx * dx + dy * dy).squareRoot()
                    return dy < 0 && distance >= 15.5 * scale && distance <= 17 * scale
                }
                #expect(ring.isEmpty, "The selection must not grow a decorative ring at \(width)pt.")
            }
        }
    }

    /// A neighbour is a control only when its whole 44pt target fits in the
    /// slot. Narrower slots draw it as a peek, so no target is ever clipped in
    /// half — the swipe and the accessibility adjustment still change mode.
    @Test func peekingNeighboursNeverPresentAHalfTarget() throws {
        #expect(CameraModeRowLayout.controlWidth == 44)
        #expect(!CameraModeRowLayout.fullStripFits(width: 96, visibleCount: 2),
                "Centering an end selection needs 132pt to fit the neighbor's full target.")
        #expect(!CameraModeRowLayout.fullStripFits(width: 96, visibleCount: 3))
        #expect(CameraModeRowLayout.fullStripFits(width: 132, visibleCount: 3, selectedIndex: 1))

        let twoModes = CameraModeCarousel(selected: .develop, enabled: true, onSelect: { _ in })
        #expect(!twoModes.isInteractive(.video, in: 96))
        #expect(twoModes.isInteractive(.video, in: 132),
                "A fully visible neighbour stays a real tap target.")
        let edgeSelection = CameraModeCarousel(selected: .develop, enabled: true, onSelect: { _ in },
                                               photoAvailable: true)
        #expect(edgeSelection.isInteractive(.video, in: 132))
        #expect(!edgeSelection.isInteractive(.photo, in: 132))
        #expect(edgeSelection.isInteractive(.photo, in: 220))

        let threeModes = CameraModeCarousel(selected: .video, enabled: true, onSelect: { _ in },
                                            photoAvailable: true)
        #expect(threeModes.isInteractive(.video, in: 96))
        #expect(!threeModes.isInteractive(.develop, in: 96),
                "A half-clipped neighbour is a decorative peek, not a tap target.")
        #expect(!threeModes.isInteractive(.photo, in: 96))
        #expect(threeModes.isInteractive(.develop, in: 132),
                "At 132pt every visible target fits, so the whole row is live.")

        // The peeks are only a drawn pull; the 44pt cells do not overlap.
        #expect(CameraModeRowLayout.letterOffset(index: 0, selectedIndex: 1) == CameraModeRowLayout.peekInset)
        #expect(CameraModeRowLayout.letterOffset(index: 2, selectedIndex: 1) == -CameraModeRowLayout.peekInset)
        #expect(CameraModeRowLayout.letterOffset(index: 1, selectedIndex: 1) == 0)

        for width: CGFloat in [96, 120] {
            let image = try renderCarousel(active: .video, width: width, photoAvailable: true)
            let data = try pixels(image)
            let midX = image.width / 2
            let ghosts = points(matching: ghostInk, in: data, image: image)
            #expect(ghosts.contains { $0.x < midX - 20 }, "Develop peeks in from the left edge.")
            #expect(ghosts.contains { $0.x > midX + 20 }, "Photo peeks in from the right edge.")
            #expect(borderIsClear(data, image: image),
                    "A \(Int(width))pt slot must clip its peeks, not paint past the camera strip.")
            #expect(ink(data) > 400, "The centred mode and its peeks stay visible at \(Int(width))pt.")
        }
    }

    // MARK: - Recording status

    /// The status face is type and a small mark over the preview. The old plate
    /// and rim are gone, and the measured 112x40 / quarter-turned footprint the
    /// toolbar and the physical edge overlay depend on is unchanged.
    @Test func recordingStatusIsUnboxedAndKeepsItsMeasuredFootprint() throws {
        let portrait = try render(RecordingStatusFace(presentation: .recording, text: "00:01.00").padding(8),
                                  name: "minimal-status-portrait")
        #expect(portrait.width == 256 && portrait.height == 112,
                "The shared 112x40 status footprint must not move.")
        let landscape = try render(RecordingStatusFace(presentation: .recording, text: "00:01.00",
                                                       rotationDegrees: 90).padding(8),
                                   name: "minimal-status-landscape")
        #expect(landscape.width == 112 && landscape.height == 256,
                "The quarter-turned face still measures 40x112.")

        for state: RecordButtonPresentation in [.idle, .starting, .recording, .stopping] {
            for degrees in [0.0, 90.0, -90.0] {
                let image = try render(RecordingStatusFace(presentation: state, text: "00:01.00",
                                                           rotationDegrees: degrees).padding(8),
                                       name: "minimal-status-\(state)-\(Int(degrees))")
                let data = try pixels(image)
                #expect(points(matching: plateInk, in: data, image: image).isEmpty,
                        "The \(state) face must not paint a plate or rim.")
                #expect(ink(data) > 40, "The \(state) face still paints its mark and type.")
            }
        }
    }

    /// The idle armed badge has no plate to make an empty face noticeable any
    /// more, so it states its state and rate in words. It still paints no
    /// elapsed timer digits and still differs from a plain idle face.
    @Test func armedIdleBadgeIsUnboxedButStillPaintsItsState() throws {
        func frame(_ text: String) -> some View {
            RecordingStatusFace(presentation: .idle, text: text, daylight60Active: true).padding(8)
        }
        let longImage = try render(frame("99:59.99"), name: "minimal-armed-long")
        let long = try pixels(longImage)
        let short = try pixels(render(frame("00:00.00"), name: "minimal-armed-short"))
        #expect(long == short, "The armed idle badge must not paint elapsed timer digits.")
        #expect(ink(long) > 40, "The armed badge keeps a visible, unboxed state and rate label.")
        #expect(points(matching: plateInk, in: long, image: longImage).isEmpty,
                "The armed badge must be unboxed too.")
        let unarmed = try pixels(render(RecordingStatusFace(presentation: .idle, text: "").padding(8),
                                        name: "minimal-idle-unarmed"))
        #expect(long != unarmed, "The armed badge must still read differently from a plain idle face.")
    }

    // MARK: - Remaining time

    /// The remaining-time readout is quiet type on the preview: no surface, box
    /// or rim, and no abbreviated placeholder. Queue, storage and the static
    /// render ring survive the simplification.
    @Test func remainingTimeIsUnboxedTypeWithItsStatesIntact() throws {
        let slot = CGSize(width: 84, height: 106)
        let idle = CameraStatusPresentation(outstandingCount: 0, pendingCount: 0, isProcessing: false,
                                            failedCount: 0, errorMessage: nil,
                                            latestResultCompleted: false, latestResultSavedToPhotos: nil)
        let rendering = CameraStatusPresentation(outstandingCount: 3, pendingCount: 2, isProcessing: true,
                                                 failedCount: 0, errorMessage: nil,
                                                 latestResultCompleted: false, latestResultSavedToPhotos: nil)

        let short = try render(RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false, queueStatus: idle)
            .frame(width: slot.width, height: slot.height), name: "minimal-lcd-short")
        let shortPixels = try pixels(short)
        #expect(short.width == Int(slot.width * 2) && short.height == Int(slot.height * 2))
        #expect(whiteInk(shortPixels) > 200,
                "The real remaining time is painted, not replaced by an abbreviation.")
        #expect(Double(ink(shortPixels)) / Double(short.width * short.height) < 0.4,
                "The readout must not paint a plate, surface or rim over the preview.")

        let long = try render(RecordingTimeLCD(estimatedSeconds: 3_600, isStorageLow: false, queueStatus: idle)
            .frame(width: slot.width, height: slot.height), name: "minimal-lcd-long")
        #expect(digest(short) != digest(long), "The readout tracks the estimate instead of a fixed placeholder.")

        // Low storage is no longer a glyph inside the face: the bar's shared
        // queue-attention outline raises it over the same content, and the
        // spoken value carries it. The LCD's own ink must therefore not change.
        let low = try render(RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: true, queueStatus: idle)
            .frame(width: slot.width, height: slot.height), name: "minimal-lcd-low")
        #expect(digest(low) == digest(short),
                "Low storage is the bar outline's cue; the face's content is unchanged.")
        let bar = try String(contentsOf: TestRepository.url(for: "App/Modules/CameraCapture/CameraControlBar.swift"),
                             encoding: .utf8)
        #expect(bar.contains("if isStorageLow { snapshot.issues.insert(\"low-storage\") }"),
                "Low storage still raises its warning — on the outline, not in the face.")
        #expect(bar.contains("CameraQueueAttentionOutline(hasIssue: queueAttention.hasUnseenIssue,"))
        #expect(bar.contains("\\(isStorageLow ? \"Low storage. \" : \"\")"),
                "The warning stays spoken even though it paints no glyph.")

        // The render ring is still policy-driven: it animates only while a job is
        // in flight and Reduce Motion freezes it to a static arc.
        #expect(rendering.shouldAnimateRendering(reduceMotion: false))
        #expect(!rendering.shouldAnimateRendering(reduceMotion: true),
                "Reduce Motion keeps the render ring static.")
        let queued = try render(RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false, queueStatus: rendering)
            .frame(width: slot.width, height: slot.height), name: "minimal-lcd-rendering")
        #expect(whiteInk(try pixels(queued)) > 100,
                "The render activity label still draws over the preview.")

        // Recording keeps its red tally; finalising drops back to the plain face.
        let live = try render(RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false, queueStatus: idle,
                                               isRecording: true)
            .frame(width: slot.width, height: slot.height), name: "minimal-lcd-live")
        let stopping = try render(RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false, queueStatus: idle,
                                                   isRecording: true, isStopping: true)
            .frame(width: slot.width, height: slot.height), name: "minimal-lcd-stopping")
        #expect(redInk(try pixels(live)) > 0, "A confirmed take keeps its red tally.")
        #expect(redInk(try pixels(stopping)) == 0, "A finalising take must not read as an active recording.")
    }

    // MARK: - Render helpers

    private struct Point { let x: Int; let y: Int }

    private func renderCarousel(active: CameraMode, width: CGFloat,
                                photoAvailable: Bool = false) throws -> CGImage {
        let view = CameraModeCarousel(selected: active, enabled: true, onSelect: { _ in },
                                      photoAvailable: photoAvailable)
            .frame(width: width, height: CameraModeCarousel.height)
            .environment(\.cameraControlAccent, accent)
        return try render(view, name: "minimal-mode-\(active.rawValue)-\(Int(width))-\(photoAvailable)")
    }

    private func render(_ view: some View, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = TestRepository.artifactDirectory("minimal-camera-mode")
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

    private func points(matching predicate: (Int, Int, Int, Int) -> Bool,
                        in data: [UInt8], image: CGImage) -> [Point] {
        var result: [Point] = []
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                if predicate(Int(data[index]), Int(data[index + 1]), Int(data[index + 2]), Int(data[index + 3])) {
                    result.append(Point(x: x, y: y))
                }
            }
        }
        return result
    }

    /// The selected letter's resolved accent (the injected daylight orange).
    private func accentInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 128 && red > 150 && green > 60 && green < 210 && blue < 120 && red > blue + 60
    }

    /// The flat selection fill: an opaque, dark, accent-matched surface.
    /// The selection disc: dark, opaque and accent-tinted. The capsule behind
    /// the group is neutral charcoal, so its tint separates the two.
    private func flatDarkFill(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        let high = max(red, max(green, blue))
        return alpha > 200 && high <= 90 && high - min(red, min(green, blue)) >= 3
    }

    /// The dimmed neighbour letter — over the preview or over the capsule, where
    /// the composite is opaque rather than translucent.
    private func ghostInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 25 && red > 40 && red < 170
            && abs(red - green) < 6 && abs(green - blue) < 6
    }

    /// A bright glyph core: the selected caption, or a white readout.
    private func brightInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 128 && red > 170 && green > 170 && blue > 170
    }

    /// The removed status plate: an opaque dark surface.
    private func plateInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 200 && max(red, max(green, blue)) < 70
    }

    private func ink(_ data: [UInt8]) -> Int {
        var count = 0
        var index = 3
        while index < data.count {
            if data[index] > 20 { count += 1 }
            index += 4
        }
        return count
    }

    private func whiteInk(_ data: [UInt8]) -> Int {
        var count = 0
        var index = 0
        while index + 3 < data.count {
            if data[index] > 200, data[index + 1] > 200, data[index + 2] > 200 { count += 1 }
            index += 4
        }
        return count
    }

    private func redInk(_ data: [UInt8]) -> Int {
        var count = 0
        var index = 0
        while index + 3 < data.count {
            if Int(data[index]) > 170, Int(data[index + 1]) < 90,
               Int(data[index + 2]) < 90, data[index + 3] > 100 {
                count += 1
            }
            index += 4
        }
        return count
    }

    private func borderIsClear(_ data: [UInt8], image: CGImage) -> Bool {
        var clear = true
        for x in 0..<image.width {
            for y in [0, image.height - 1] {
                if data[(y * image.width + x) * 4 + 3] > 20 { clear = false }
            }
        }
        for y in 0..<image.height {
            for x in [0, image.width - 1] {
                if data[(y * image.width + x) * 4 + 3] > 20 { clear = false }
            }
        }
        return clear
    }

    private func digest(_ image: CGImage) -> Int {
        var hasher = Hasher()
        hasher.combine(image.width)
        hasher.combine(image.height)
        if let data = try? pixels(image) { hasher.combine(data) }
        return hasher.finalize()
    }
}
