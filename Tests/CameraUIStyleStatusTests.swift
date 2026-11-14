import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// What each finish draws, and the shared surfaces underneath both.
///
/// The approved camera UI is one compact presentation: both finishes run the
/// same 28pt-disc / 32pt-pitch mode row with no caption, the same unboxed
/// queue/capacity face in the shared well, and the same wells and plates. Only
/// the well's face still differs — Classic keeps its bevel, Minimal its
/// borderless fill — and the recording-status face keeps its Classic plate.
/// Behaviour is deliberately shared, so the same suite re-asserts one
/// swipe/availability/refusal/tap contract rather than describing a second
/// interaction model. The assertions below therefore render the reachable path;
/// the retired Classic letter-and-caption row and inset LCD plate are gone from
/// the source and are not asserted as if they still existed.
@MainActor
struct CameraUIStyleStatusTests {
    /// The accent the appearance layer resolves for a daylight stock. Injected
    /// rather than inherited, so both styles pin the same colour owner.
    private let accent = Color(.sRGB, red: 0.95, green: 0.45, blue: 0.12, opacity: 1)

    private let idleQueue = CameraStatusPresentation(
        outstandingCount: 0, pendingCount: 0, isProcessing: false,
        failedCount: 0, errorMessage: nil,
        latestResultCompleted: false, latestResultSavedToPhotos: nil)

    private let queued = CameraStatusPresentation(
        outstandingCount: 3, pendingCount: 2, isProcessing: false,
        failedCount: 0, errorMessage: nil,
        latestResultCompleted: false, latestResultSavedToPhotos: nil)

    private let renderingQueue = CameraStatusPresentation(
        outstandingCount: 3, pendingCount: 2, isProcessing: true,
        failedCount: 0, errorMessage: nil,
        latestResultCompleted: false, latestResultSavedToPhotos: nil)

    private let errorQueue = CameraStatusPresentation(
        outstandingCount: 1, pendingCount: 0, isProcessing: false,
        failedCount: 1, errorMessage: "Render failed",
        latestResultCompleted: true, latestResultSavedToPhotos: false)

    // MARK: - Minimal mode row geometry
    // MARK: - Minimal mode row geometry
    /// Minimal runs a real carousel: a 28pt disc on a 4pt gap, so one visual
    /// cell is 32pt. The selected letter holds the slot's centre and the rest
    /// ride the track beside it, so the row slides instead of re-centring a
    /// group. The row keeps its 44pt touch height, and every cell keeps a whole,
    /// non-overlapping 28pt tap while its disc fits the slot.
    @Test func minimalModeRowKeepsTheSelectionCentredOnA32ptPitch() throws {
        #expect(CameraModeCarousel.height == 44, "Both styles keep the 44pt touch height.")
        #expect(CameraModeRowLayout.compactCellWidth == 28)
        #expect(CameraModeRowLayout.compactGap == 4)
        #expect(CameraModeRowLayout.compactPitch == 32,
                "28pt disc + 4pt gap is the 32pt pitch the carousel rides on.")
        #expect(CameraModeRowLayout.compactGroupWidth(visibleCount: 3) == 92)
        #expect(CameraModeRowLayout.compactGroupWidth(visibleCount: 2) == 60)

        // The selected cell is the slot's centre; its neighbours ride the pitch.
        #expect(CameraModeRowLayout.compactCellOffset(index: 1, selectedIndex: 1) == 0)
        #expect(CameraModeRowLayout.compactCellOffset(index: 0, selectedIndex: 1) == -32)
        #expect(CameraModeRowLayout.compactCellOffset(index: 2, selectedIndex: 1) == 32)

        // The track slides one pitch per mode, which is what keeps the selected
        // letter — not the group — on the centre.
        #expect(CameraModeRowLayout.compactTrackOffset(selectedIndex: 1, visibleCount: 3) == 0)
        #expect(CameraModeRowLayout.compactTrackOffset(selectedIndex: 0, visibleCount: 3) == 32)
        #expect(CameraModeRowLayout.compactTrackOffset(selectedIndex: 2, visibleCount: 3) == -32)

        // Minimal's fill is exactly one cell, so the disc never widens the pitch.
        #expect(CameraModeCarousel.selectionFillSize == 28)
        #expect(CameraModeCarousel.minimumControlWidth == 44, "Classic's 44pt contract survives.")

        // At the 96pt floor a middle selection fits the whole row; an end
        // selection keeps the centre and its first neighbour and ghosts the far
        // one rather than clipping a live target.
        #expect(CameraModeRowLayout.compactCarouselFits(width: 96, visibleCount: 3, selectedIndex: 1))
        #expect(!CameraModeRowLayout.compactCarouselFits(width: 96, visibleCount: 3, selectedIndex: 0))
        #expect(CameraModeRowLayout.compactCellFits(index: 1, selectedIndex: 0, slotWidth: 96),
                "The first neighbour still fits whole at the floor.")
        #expect(!CameraModeRowLayout.compactCellFits(index: 2, selectedIndex: 0, slotWidth: 96),
                "The far neighbour would be clipped, so it is drawn, never tappable.")
        #expect(!CameraModeRowLayout.compactCarouselFits(width: 0, visibleCount: 3, selectedIndex: 1))
        #expect(CameraModeRowLayout.compactCarouselFits(width: 200, visibleCount: 3, selectedIndex: 0))

        for slot: CGFloat in [96, 200] {
            for selectedIndex in 0..<3 {
                let rects = (0..<3).map {
                    CameraModeRowLayout.compactCellRect(index: $0, selectedIndex: selectedIndex,
                                                        slotWidth: slot)
                }
                #expect(abs(rects[selectedIndex].midX - slot / 2) <= 0.5,
                        "The selected cell is the slot's centre, not a member of a centred group.")
                for rect in rects {
                    #expect(rect.width == 28)
                    #expect(rect.height == CameraModeCarousel.height)
                }
                for index in 0..<2 {
                    #expect(rects[index].maxX <= rects[index + 1].minX,
                            "A 32pt pitch never overlaps two taps.")
                    #expect(rects[index + 1].minX - rects[index].minX == 32)
                }
                for (index, rect) in rects.enumerated()
                where CameraModeRowLayout.compactCellFits(index: index, selectedIndex: selectedIndex,
                                                          slotWidth: slot) {
                    #expect(rect.minX >= 0 && rect.maxX <= slot,
                            "Every live target stays whole inside the \(Int(slot))pt slot.")
                }
            }
        }
    }

    /// The drawn carousel matches the pure geometry: the selected letter sits on
    /// the centre disc, its neighbours read 32pt away, one capsule hugs the
    /// group, and nothing paints outside the slot.
    @Test func minimalModeRowDrawsTheSelectionCentredOnItsTrack() throws {
        let modes = CameraMode.visibleModes(photoAvailable: true)
        for slot: CGFloat in [96, 200] {
            for active in modes {
                let image = try renderCarousel(active: active, width: slot, style: .minimal,
                                               photoAvailable: true)
                let data = try pixels(image)
                let scale = Double(image.width) / Double(slot)
                let selectedIndex = try #require(modes.firstIndex(of: active))

                let letter = points(matching: accentInk, in: data, image: image)
                #expect(letter.count > 40, "The selected accent letter paints at \(Int(slot))pt.")
                let letterMidX = Double(letter.map(\.x).reduce(0, +)) / Double(letter.count)
                #expect(abs(letterMidX - Double(slot) / 2 * scale) <= 2.5 * scale,
                        "The selected letter holds the slot's centre at \(Int(slot))pt.")

                // The disc behind it is one cell wide and centred on the letter.
                let fill = points(matching: darkFill, in: data, image: image)
                #expect(fill.count > 300, "Minimal keeps its flat selection disc.")
                let fillMinX = try #require(fill.map(\.x).min())
                let fillMaxX = try #require(fill.map(\.x).max())
                #expect(abs(Double(fillMaxX - fillMinX) / scale - 28) <= 2.5,
                        "The disc is 28pt wide, not a 44pt cell.")

                // When the whole track fits, one capsule hugs exactly the group
                // and rides with the centred selection. An end selection on the
                // 96pt floor is wider than the slot, so its far ghost and that
                // end of the plate are clipped by the strip instead.
                let allCellsFit = CameraModeRowLayout.compactCarouselFits(
                    width: slot, visibleCount: modes.count, selectedIndex: selectedIndex)
                if allCellsFit {
                    let capsule = points(matching: wellFill, in: data, image: image)
                    let capsuleMinX = try #require(capsule.map(\.x).min())
                    let capsuleMaxX = try #require(capsule.map(\.x).max())
                    let capsuleWidth = Double(capsuleMaxX - capsuleMinX) / scale
                    #expect(abs(capsuleWidth - CameraModeRowLayout.compactGroupWidth(
                        visibleCount: modes.count)) <= 3,
                            "The capsule hugs the 92pt group (saw \(Int(capsuleWidth))pt).")
                    #expect(abs(Double(capsuleMinX + capsuleMaxX) / 2 / scale - Double(slot) / 2) <= 3,
                            "The capsule rides with the centred selection.")
                    #expect(borderIsClear(data, image: image),
                            "A fitting track clips nothing and paints nothing outside itself.")
                }

                // Neighbours sit a whole pitch away on the track.
                let ghosts = points(matching: ghostInk, in: data, image: image)
                #expect(!ghosts.isEmpty, "Minimal still shows its neighbouring modes.")
                let distances = ghosts.map { abs(Double($0.x) - letterMidX) / scale }
                let nearest = distances.min() ?? 0
                #expect((22...40).contains(nearest),
                        "The nearest neighbour reads 32pt away (saw \(Int(nearest))pt).")
                #expect(distances.max() ?? 0 <= 72,
                        "Neighbours stay on the 32pt pitch.")

                #expect(ink(data) > 400, "The carousel stays visible.")
            }
        }
    }

    // MARK: - The one mode row

    /// Both finishes now draw the same compact row: the selected capital on its
    /// 28pt disc, the neighbour a 32pt pitch away, and no word caption. Classic's
    /// pre-minimal letter-and-caption treatment is no longer reachable, so this
    /// pin asserts the shipped path instead of a second Classic-only rendering.
    @Test func bothFinishesDrawTheSameCompactModeRowWithoutACaption() throws {
        #expect(CameraModeCarousel.height == 44)
        #expect(CameraModeCarousel.minimumControlWidth == 44)
        #expect(CameraModeRowLayout.controlWidth == 44)

        for active in CameraMode.visibleModes {
            let width: CGFloat = 200
            let classicImage = try renderCarousel(active: active, width: width, style: .classic)
            let minimalImage = try renderCarousel(active: active, width: width, style: .minimal)
            let classic = try pixels(classicImage)
            let minimal = try pixels(minimalImage)

            // One row: the style no longer changes the carousel's letters — only
            // the well's face behind them, which the backing suite pins.
            let classicLetter = points(matching: accentInk, in: classic, image: classicImage)
            let minimalLetter = points(matching: accentInk, in: minimal, image: minimalImage)
            #expect(abs(classicLetter.count - minimalLetter.count) <= 4,
                    "Both finishes draw the same accent capital for \(active.rawValue).")
            #expect(points(matching: darkFill, in: classic, image: classicImage).count > 300,
                    "The selected cell keeps its one flat selection disc in both finishes.")

            // The selected capital paints the shared accent and stays centred.
            let letter = points(matching: accentInk, in: classic, image: classicImage)
            #expect(letter.count > 40, "The selected letter paints the accent.")
            let letterMidX = Double(letter.map(\.x).reduce(0, +)) / Double(letter.count) / 2
            #expect(abs(letterMidX - Double(width) / 2) <= 2,
                    "The selected letter is centred, not parked in a half.")

            // A 28pt disc over a 4pt gap leaves no room for a word: the shared
            // label paints no caption band. Measured on the borderless fill,
            // where the only bright ink could be type — Classic's material plate
            // is not a glyph.
            #expect(points(matching: brightInk, in: minimal, image: minimalImage).isEmpty,
                    "The compact row paints no caption.")

            // The neighbour is still a ghosted letter on the correct side, one
            // 32pt pitch away on the shared track. Measured inside that
            // neighbour's own cell on the flat Minimal face over an opaque
            // ground: Classic's translucent material and its inset rim paint
            // their own mid-greys across the whole plate, so a grey mask there
            // cannot tell one glyph from the well's bevel — and the ghost on a
            // transparent ground is a 0.45-alpha white no grey mask catches.
            let letterTop = try #require(letter.map(\.y).min())
            let letterBottom = try #require(letter.map(\.y).max())
            let groundedImage = try renderCarousel(active: active, width: width, style: .minimal,
                                                   grounded: true)
            let groundedScale = Double(groundedImage.width) / Double(width)
            let modes = CameraMode.visibleModes
            let selectedIndex = try #require(modes.firstIndex(of: active))
            let neighbourIndex = selectedIndex == 0 ? min(1, modes.count - 1) : selectedIndex - 1
            let neighbourOffset = Double(CameraModeRowLayout.compactCellOffset(
                index: neighbourIndex, selectedIndex: selectedIndex))
            let neighbourCentre = Double(width) / 2 + neighbourOffset
            // The neighbour's own cell, clipped where the strip clips it: the only
            // place its capital can legitimately paint.
            let cellReach = Double(CameraModeRowLayout.compactCellWidth) / 2
            let viewportHalf = Double(min(width, CameraModeRowLayout.compactGroupWidth(
                visibleCount: modes.count))) / 2
            let cellLow = neighbourCentre - cellReach
            let cellHigh = min(neighbourCentre + cellReach, Double(width) / 2 + viewportHalf)
            let ghost = points(matching: ghostInk, in: try pixels(groundedImage), image: groundedImage)
                .filter { $0.y >= letterTop && $0.y <= letterBottom }
                .filter {
                    let x = Double($0.x) / groundedScale
                    return (x - Double(width) / 2) * neighbourOffset > 0
                        && x >= cellLow - 0.5 && x <= cellHigh + 0.5
                }
            #expect(ghost.count > 20, "The neighbouring mode is still drawn inside its own cell.")
            let ghostMidX = Double(ghost.map(\.x).reduce(0, +)) / Double(max(ghost.count, 1)) / groundedScale
            #expect(ghostMidX >= cellLow - 1 && ghostMidX <= cellHigh + 1,
                    "Ghost cell \(cellLow)...\(cellHigh)pt; centroid \(ghostMidX)pt.")
            #expect((26...38).contains(abs(ghostMidX - letterMidX)),
                    "The neighbour rides the 32pt pitch (saw \(abs(ghostMidX - letterMidX))pt).")
            #expect((ghostMidX - letterMidX).sign == neighbourOffset.sign,
                    "The ghost sits on the correct side of the selection.")
            // Classic still ghosts its neighbour; only the pitch is measured on
            // the face that lets a grey mask be glyph-only.
            #expect(!points(matching: ghostInk, in: classic, image: classicImage)
                .filter { $0.y >= letterTop && $0.y <= letterBottom }.isEmpty,
                "The classic row still shows its neighbouring mode.")
        }
    }

    /// Neither finish re-skins the interaction: the same accepted swipe, the
    /// same blocked tap that answers with a reason, and the same complete-target
    /// rule. A narrow slot degrades neighbours to peeks in both styles.
    @Test func classicModeRowKeepsTheSharedSwipeAvailabilityAndCompleteTargets() throws {
        for style in [CameraUIStyle.classic, .minimal] {
            let live = CameraModeCarousel(selected: .develop, enabled: true, onSelect: { _ in })
            #expect(live.resolvedSwipe(CGSize(width: -60, height: 4)) == .select(.video))
            #expect(live.resolvedSwipe(CGSize(width: 60, height: 0)) == .none)
            #expect(live.resolvedSwipe(CGSize(width: -60, height: 90)) == .none)
            #expect(live.resolvedTap(.video) == .select(.video))

            let blocked = CameraModeCarousel(selected: .develop, enabled: false, onSelect: { _ in })
            #expect(blocked.resolvedSwipe(CGSize(width: -80, height: 0)) == .none,
                    "A disabled \(style.rawValue) row still swallows the swipe.")
            #expect(blocked.resolvedTap(.video) == .refused(.video),
                    "A dimmed \(style.rawValue) letter answers a tap instead of ignoring it.")

            // Classic's whole-target rule is untouched by the style; Minimal
            // reads its own compactCellFits rule against the 28pt disc.
            #expect(!live.isInteractive(.video, in: 96))
            #expect(live.isInteractive(.video, in: 132))
            let three = CameraModeCarousel(selected: .video, enabled: true, onSelect: { _ in },
                                           photoAvailable: true)
            #expect(three.isInteractive(.video, in: 96))
            #expect(!three.isInteractive(.develop, in: 96))
            #expect(three.isInteractive(.develop, in: 132))

            // The behaviour above is style-independent because the row carries
            // no second selection or refusal state.
            #expect(three.resolvedSwipe(CGSize(width: -60, height: 0)) == .select(.photo))
            #expect(three.resolvedSwipe(CGSize(width: 60, height: 0)) == .select(.develop))
        }

        // A narrow classic slot clips its peeks instead of painting past the
        // camera strip, just like Minimal.
        let margin = 24
        let scale = 2
        let width: CGFloat = 96
        for active in CameraMode.visibleModes {
            let view = CameraModeCarousel(selected: active, enabled: true, onSelect: { _ in },
                                          photoAvailable: true)
                .frame(width: width, height: CameraModeCarousel.height)
                .padding(CGFloat(margin))
                .environment(\.cameraUIStyle, .classic)
                .environment(\.cameraControlAccent, accent)
            let image = try render(view, name: "classic-mode-bounds-\(active.rawValue)")
            let data = try pixels(image)
            var outside = 0
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let inside = x >= margin * scale && x < (margin + Int(width)) * scale
                        && y >= margin * scale && y < (margin + Int(CameraModeCarousel.height)) * scale
                    if !inside, data[(y * image.width + x) * 4 + 3] > 20 { outside += 1 }
                }
            }
            #expect(outside == 0, "The classic row must stay inside its \(Int(width))pt slot.")
        }
    }

    // MARK: - Remaining time

    /// The LCD is one shared face in both finishes: no recessed plate, no
    /// headline rule, no 20pt readout. The bar seats this same content in the
    /// shared well, so Classic no longer draws a plate of its own — its
    /// "restored" inset surface is gone from the source.
    @Test func bothFinishesDrawTheOneSharedUnboxedLcdFace() throws {
        let classicImage = try render(lcd(.classic, queue: idleQueue), name: "classic-lcd-idle")
        let minimalImage = try render(lcd(.minimal, queue: idleQueue), name: "minimal-lcd-idle")
        let classic = try pixels(classicImage)
        let minimal = try pixels(minimalImage)

        // The face paints no surface of its own; the bar's one well is the plate.
        #expect(darkCoverage(minimal) < 0.08, "The face paints no plate over the preview.")
        #expect(darkCoverage(classic) < 0.08, "Classic's plate is gone too; the well is the plate now.")
        #expect(classic == minimal, "Both finishes draw the same LCD content.")

        let lcdSource = try source("App/Modules/CameraCapture/RecordingTimeLCD.swift")
        #expect(!lcdSource.contains("CameraInsetSurface"),
                "The recessed LCD plate no longer exists; the bar's well replaced it.")
        let bar = try source("App/Modules/CameraCapture/CameraControlBar.swift")
        #expect(bar.contains(".cameraWellBacking(cornerRadius: 10)"),
                "The bar seats the one face in the shared well.")

        // The approved compact type: a 22pt mark over one 12pt line.
        #expect(RecordingTimeLCD.queueGlyphSize == 22, "The mark is the approved 22pt glyph.")
        #expect(RecordingTimeLCD.minimalReadoutSize == 12, "The readout is one 12pt line.")
        #expect(maxBrightRun(classic, image: classicImage, xTo: 0.6) > 0,
                "The face still paints its white readout.")
        #expect(whiteInk(minimal) > 200, "The readout line paints.")

        // The real estimate is still painted, not an abbreviation.
        let longImage = try render(lcd(.classic, seconds: 3_600, queue: idleQueue), name: "classic-lcd-long")
        #expect(digest(classicImage) != digest(longImage),
                "The shared readout tracks the estimate.")
    }

    /// One shared face: a 22pt queue mark over one 12pt capacity line —
    /// hundredths of free space in Photo, hundredths of a minute in Video. No
    /// QUEUE, FREE SPACE, REC LEFT or remaining-time caption is printed. The
    /// take and the count ride the mark as small marks; success, failure and low
    /// storage are drawn by the bar's outline over this same content, and are
    /// spoken by the queue's accessibility value. Neither finish grows a second,
    /// glyph-sized tap: the whole LCD stays the one >=44pt queue action.
    @Test func theSharedFaceIsOneQueueMarkOverOneCapacityLine() throws {
        #expect(RecordingTimeLCD.queueGlyphSize == 22,
                "The approved mark is the 22pt queue glyph.")
        #expect(RecordingTimeLCD.minimalReadoutSize == 12,
                "The line under it is 12pt, for both media and both finishes.")
        #expect(RecordingTimeLCD.minimumTouchSize == 44,
                "The LCD is never offered as a sub-44pt target.")

        let classicImage = try render(lcd(.classic, queue: queued), name: "classic-lcd-queue")
        let minimalImage = try render(lcd(.minimal, queue: queued), name: "minimal-lcd-queue")
        let classic = try pixels(classicImage)
        let minimal = try pixels(minimalImage)

        // One face, both finishes: the style no longer re-skins the LCD, so the
        // Classic 8pt mark and QUEUE word are gone rather than merely unused.
        #expect(classic == minimal, "Both finishes draw the same queue/capacity face.")

        // The mark and its one line are centred as one tight column: the mark's
        // ink sits above the slot's middle, the single readout line below it.
        let bright = points(matching: brightInk, in: minimal, image: minimalImage)
        _ = try #require(bright.map(\.y).min(), "The shared face still paints its queue mark.")
        _ = try #require(bright.map(\.y).max())
        let middle = minimalImage.height / 2
        #expect(bright.contains { $0.y < middle }, "The mark sits above the readout.")
        #expect(bright.contains { $0.y > middle }, "The readout line sits below the mark.")
        let brightMidX = Double(bright.map(\.x).reduce(0, +)) / Double(bright.count)
        #expect(abs(brightMidX - Double(minimalImage.width) / 2) <= 5,
                "The mark and its capacity line share the slot's centre.")

        // The line itself: GB in Photo, minutes in Video, hundredths, floored.
        let photo = RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false, queueStatus: idleQueue,
                                     photoFreeBytes: 12_400_000_000, isPhotoMode: true)
        #expect(photo.minimalReadoutText == "12.40 GB")
        #expect(RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false,
                                 queueStatus: idleQueue).minimalReadoutText == "12.56 min")
        #expect(RecordingTimeLCD(estimatedSeconds: 30, isStorageLow: false,
                                 queueStatus: idleQueue).minimalReadoutText == "0.50 min",
                "A nearly full card reports the fraction it has, not a whole minute.")
        #expect(RecordingTimeLCD(estimatedSeconds: nil, isStorageLow: false,
                                 queueStatus: idleQueue).minimalReadoutText == "-- min")

        // The capacity line tracks the medium; no caption is drawn beside it.
        let generous = try render(lcd(.minimal, queue: idleQueue, photoFreeBytes: 97_300_000_000), name: "minimal-lcd-photo-high")
        #expect(digest(generous) != digest(minimalImage),
                "Photo capacity replaces the video minutes.")

        // What the face builds: one shared presentation, exactly one text line
        // and no caption word. The state is carried by marks and the outline.
        let lcdSource = try source("App/Modules/CameraCapture/RecordingTimeLCD.swift")
        #expect(lcdSource.contains("private var presentation: some View { minimalFace }"),
                "Both finishes present the one shared face.")
        let faceStart = try #require(lcdSource.range(of: "private var minimalFace: some View"))
        let faceEnd = try #require(lcdSource.range(of: "/// The queue glyph, or the render ring"))
        let face = String(lcdSource[faceStart.lowerBound..<faceEnd.lowerBound])
        #expect(face.components(separatedBy: "Text(").count == 2,
                "The face prints exactly one readout line.")
        for caption in ["QUEUE", "FREE SPACE", "REC LEFT", "RECORDING", "headlineText", "queueStatus.label"] {
            #expect(!face.contains(caption),
                    "The face paints no \(caption) word; its state is carried by marks.")
        }

        // Success and issue are the bar's outline over this same content, so the
        // face's own ink is identical for saved, failed and low storage.
        let idle = try render(lcd(.minimal, queue: idleQueue), name: "minimal-lcd-noqueue")
        #expect(digest(minimalImage) != digest(idle),
                "The queue count still changes the face.")
        let saved = try render(lcd(.minimal, queue: CameraStatusPresentation(
            outstandingCount: 0, pendingCount: 0, isProcessing: false,
            failedCount: 0, errorMessage: nil,
            latestResultCompleted: true, latestResultSavedToPhotos: true)),
            name: "minimal-lcd-saved")
        #expect(digest(saved) == digest(idle),
                "A saved render adds no glyph to the face; the shared outline says it.")
        // `errorQueue` carries one outstanding render as well as the failure, and
        // that outstanding render is a real, visible count mark on the face.
        // Compare mark-for-mark at equal counts so the only difference left is
        // the failure itself; the count keeps its own, separate meaning.
        let failed = try render(lcd(.minimal, queue: errorQueue), name: "minimal-lcd-failed")
        let countOnly = try render(lcd(.minimal, queue: CameraStatusPresentation(
            outstandingCount: 1, pendingCount: 0, isProcessing: false,
            failedCount: 0, errorMessage: nil,
            latestResultCompleted: true, latestResultSavedToPhotos: false)),
            name: "minimal-lcd-count1")
        #expect(digest(failed) == digest(countOnly),
                "A failure adds no glyph: one outstanding render paints the same count mark with or without it.")
        #expect(digest(failed) != digest(idle),
                "The outstanding render in that fixture is what changes the face, not the failure.")
        let failedIdle = try render(lcd(.minimal, queue: CameraStatusPresentation(
            outstandingCount: 0, pendingCount: 0, isProcessing: false,
            failedCount: 1, errorMessage: "Render failed",
            latestResultCompleted: true, latestResultSavedToPhotos: false)),
            name: "minimal-lcd-failed-empty")
        #expect(digest(failedIdle) == digest(idle),
                "A failure with an empty queue draws nothing inside the face.")
        let low = try render(lcd(.minimal, isStorageLow: true, queue: idleQueue), name: "minimal-lcd-low")
        #expect(digest(low) == digest(idle),
                "Low storage is the outline's cue, not a glyph in the face.")

        let live = try render(lcd(.minimal, queue: queued, isRecording: true), name: "minimal-lcd-live")
        #expect(redInk(try pixels(live)) > 0, "A confirmed take still paints its red tally.")
        let stopping = try render(lcd(.minimal, queue: queued, isRecording: true, isStopping: true),
                                  name: "minimal-lcd-stopping")
        #expect(redInk(try pixels(stopping)) == 0, "A finalising take is not an active recording.")

        let rendering = try render(lcd(.minimal, queue: renderingQueue), name: "minimal-lcd-render")
        #expect(whiteInk(try pixels(rendering)) > 100, "Render activity still paints.")
    }


    /// The plate is presentation only: tally, stopping, queue, render activity,
    /// photo capacity and storage warnings all keep their shared meaning in
    /// *both* finishes, because there is only one face. The cue the face no
    /// longer draws — success, failure and low storage — is asserted where it
    /// now lives: the bar's queue-attention outline.
    @Test func sharedReadoutKeepsEveryStatusSemanticInBothFinishes() throws {
        for style in [CameraUIStyle.classic, .minimal] {
            let idle = try render(lcd(style, queue: idleQueue), name: "\(style.rawValue)-sem-idle")

            let live = try render(lcd(style, queue: idleQueue, isRecording: true),
                                  name: "\(style.rawValue)-sem-live")
            #expect(redInk(try pixels(live)) > 0,
                    "A confirmed take keeps its red tally in \(style.rawValue).")

            let stopping = try render(lcd(style, queue: idleQueue, isRecording: true, isStopping: true),
                                      name: "\(style.rawValue)-sem-stopping")
            #expect(redInk(try pixels(stopping)) == 0,
                    "A finalising take must not read as an active recording.")
            #expect(digest(live) != digest(stopping))

            let queuedImage = try render(lcd(style, queue: queued), name: "\(style.rawValue)-sem-queued")
            #expect(digest(queuedImage) != digest(idle), "The queue count still changes the face.")

            let rendering = try render(lcd(style, queue: renderingQueue), name: "\(style.rawValue)-sem-rendering")
            #expect(whiteInk(try pixels(rendering)) > 100, "Render activity still paints.")

            let photo = try render(lcd(style, queue: idleQueue, photoFreeBytes: 12_400_000_000),
                                   name: "\(style.rawValue)-sem-photo")
            #expect(digest(photo) != digest(idle), "Photo mode still reports free space.")

            // A success, a failure and low storage change nothing inside the
            // face: one shared outline draws them over it.
            let saved = try render(lcd(style, queue: CameraStatusPresentation(
                outstandingCount: 0, pendingCount: 0, isProcessing: false,
                failedCount: 0, errorMessage: nil,
                latestResultCompleted: true, latestResultSavedToPhotos: true)),
                name: "\(style.rawValue)-sem-saved")
            #expect(digest(saved) == digest(idle), "Success is the outline's cue, not a face glyph.")
            // `errorQueue` also carries one outstanding render, which the face
            // legitimately draws as its count mark. Pin the failure semantics at
            // equal counts, then prove an empty-queue failure adds no ink at all.
            let failed = try render(lcd(style, queue: errorQueue), name: "\(style.rawValue)-sem-failed")
            let countOnly = try render(lcd(style, queue: CameraStatusPresentation(
                outstandingCount: 1, pendingCount: 0, isProcessing: false,
                failedCount: 0, errorMessage: nil,
                latestResultCompleted: true, latestResultSavedToPhotos: false)),
                name: "\(style.rawValue)-sem-count1")
            #expect(digest(failed) == digest(countOnly),
                    "A failure adds no glyph in \(style.rawValue); the count mark is its own semantic.")
            #expect(digest(failed) != digest(idle),
                    "The outstanding render in that fixture is what changes the \(style.rawValue) face.")
            let failedIdle = try render(lcd(style, queue: CameraStatusPresentation(
                outstandingCount: 0, pendingCount: 0, isProcessing: false,
                failedCount: 1, errorMessage: "Render failed",
                latestResultCompleted: true, latestResultSavedToPhotos: false)),
                name: "\(style.rawValue)-sem-failed-empty")
            #expect(digest(failedIdle) == digest(idle),
                    "A failure with an empty queue is the outline's cue too.")
            let low = try render(lcd(style, isStorageLow: true, queue: idleQueue),
                                 name: "\(style.rawValue)-sem-low")
            #expect(digest(low) == digest(idle), "Low storage is the outline's cue, not a face glyph.")
        }

        // The one owner of those cues: the bar's outline, plus the spoken value.
        let bar = try source("App/Modules/CameraCapture/CameraControlBar.swift")
        #expect(bar.contains("CameraQueueAttentionOutline(hasIssue: queueAttention.hasUnseenIssue,"),
                "The bar draws the issue/success border over the shared face.")
        #expect(bar.contains("if isStorageLow { snapshot.issues.insert(\"low-storage\") }"),
                "Low storage still raises its warning, on the outline.")
    }

    // MARK: - Recording status

    /// Classic restores the old 112x40 plate with its rim and fuller mark while
    /// the shared presentation, tint and text drive what it paints.
    @Test func classicStatusFaceRestoresThePlateWithoutChangingItsState() throws {
        for state: RecordButtonPresentation in [.idle, .starting, .recording, .stopping] {
            let classicImage = try render(status(.classic, state: state), name: "classic-status-\(state)")
            let minimalImage = try render(status(.minimal, state: state), name: "minimal-status-\(state)")
            let classic = try pixels(classicImage)
            let minimal = try pixels(minimalImage)

            #expect(classicImage.width == 256 && classicImage.height == 112,
                    "The shared 112x40 footprint must not move.")
            // The face is 112x40 inside a padded 128x56 canvas, so an opaque
            // plate covers ~16% of the image; Minimal's soft shadow covers far
            // less and no plate at all.
            #expect(darkCoverage(classic) > 0.12, "The \(state) classic face paints its plate.")
            #expect(darkCoverage(minimal) < 0.06, "The \(state) minimal face stays unboxed.")
            #expect(faceInk(classic) > 40,
                    "The \(state) classic face still paints its mark and type on the plate.")
            #expect(faceInk(minimal) > 40,
                    "The \(state) minimal face still paints its mark and type over the preview.")
        }

        // Quarter-turned, the same plate measures 40x112.
        let landscape = try render(
            RecordingStatusFace(presentation: .recording, text: "00:01.00", rotationDegrees: 90)
                .environment(\.cameraUIStyle, .classic)
                .padding(8),
            name: "classic-status-landscape")
        #expect(landscape.width == 112 && landscape.height == 256)

        // The confirmed take still paints the semantic red, not the plate.
        let recording = try pixels(render(status(.classic, state: .recording), name: "classic-status-red"))
        #expect(redInk(recording) > 0)

        // Shared timer text drives the face in Classic too.
        let one = try render(status(.classic, state: .recording, text: "00:01.00"), name: "classic-status-t1")
        let two = try render(status(.classic, state: .recording, text: "00:02.00"), name: "classic-status-t2")
        #expect(digest(one) != digest(two), "The classic face still paints the live timer.")

        // The armed idle badge is still words only: the timer must not leak in.
        let armedLong = try render(status(.classic, state: .idle, text: "99:59.99", daylight60: true),
                                   name: "classic-status-armed-long")
        let armedShort = try render(status(.classic, state: .idle, text: "00:00.00", daylight60: true),
                                    name: "classic-status-armed-short")
        #expect(digest(armedLong) == digest(armedShort),
                "The armed idle badge must not paint elapsed timer digits.")
        #expect(digest(armedLong) != digest(one))

        // Chrome never changes the spoken contract.
        #expect(RecordingStatusFace(presentation: .recording, text: "00:01.00").spokenStatus
                == "Recording, capture confirmed. 00:01.00")
        #expect(RecordingStatusFace(presentation: .idle, text: "",
                                    daylight60Active: true).spokenStatus
                == "Ready, not recording. Daylight 60 fps armed.")
    }

    /// The armed idle off-ramp keeps its original split: Classic's plate is
    /// visible on its own, Minimal has to say what it is. Both paint no timer.
    @Test func armedIdleBadgeIsNamedInMinimalAndAnEmptyPlateInClassic() throws {
        let classicImage = try render(status(.classic, state: .idle, text: "", daylight60: true),
                                      name: "classic-armed-idle")
        let minimalImage = try render(status(.minimal, state: .idle, text: "", daylight60: true),
                                      name: "minimal-armed-idle")
        let classic = try pixels(classicImage)
        let minimal = try pixels(minimalImage)

        #expect(faceInk(classic) == 0, "Classic's armed idle badge is the original empty plate.")
        #expect(faceInk(minimal) > 40, "Minimal names its armed idle state in words.")
        #expect(darkCoverage(classic) > 0.12, "Classic's off-ramp is still a visible plate.")

        #expect(RecordingStatusFace(presentation: .idle, text: "", daylight60Active: true).spokenStatus
                == "Ready, not recording. Daylight 60 fps armed.",
                "The spoken contract is identical in both styles.")
    }

    // MARK: - Fixtures

    private func lcd(_ style: CameraUIStyle,
                     seconds: TimeInterval? = 754,
                     isStorageLow: Bool = false,
                     queue: CameraStatusPresentation,
                     isRecording: Bool = false,
                     isStopping: Bool = false,
                     photoFreeBytes: Int64? = nil) -> some View {
        RecordingTimeLCD(estimatedSeconds: seconds, isStorageLow: isStorageLow, queueStatus: queue,
                         isRecording: isRecording, isStopping: isStopping,
                         photoFreeBytes: photoFreeBytes, isPhotoMode: photoFreeBytes != nil)
            .frame(width: 84, height: 106)
            .environment(\.cameraUIStyle, style)
    }

    private func status(_ style: CameraUIStyle, state: RecordButtonPresentation,
                        text: String = "00:01.00", daylight60: Bool = false) -> some View {
        RecordingStatusFace(presentation: state, text: text, daylight60Active: daylight60)
            .environment(\.cameraUIStyle, style)
            .padding(8)
    }

    private func renderCarousel(active: CameraMode, width: CGFloat,
                                style: CameraUIStyle, photoAvailable: Bool = false,
                                grounded: Bool = false) throws -> CGImage {
        let row = CameraModeCarousel(selected: active, enabled: true, onSelect: { _ in },
                                     photoAvailable: photoAvailable)
            .frame(width: width, height: CameraModeCarousel.height)
            .environment(\.cameraUIStyle, style)
            .environment(\.cameraControlAccent, accent)
        // An opaque ground so a 0.45-alpha glyph composites as mid-grey ink
        // instead of an almost-transparent white that no grey mask can catch.
        let view = grounded ? AnyView(row.background(Color.black)) : AnyView(row)
        return try render(view,
                          name: "style-mode-\(style.rawValue)-\(active.rawValue)-\(Int(width))\(grounded ? "-grounded" : "")")
    }

    /// Pixel centre of the slot, used to tell a left neighbour from a right one.
    private func textCentre(_ image: CGImage) -> Int { image.width / 2 }

    /// Repository-relative source read, resolved through the packaged snapshot so
    /// it works where no checkout exists.
    private func source(_ relative: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(relative),
                   encoding: .utf8)
    }

    // MARK: - Render helpers

    private struct Point { let x: Int; let y: Int }

    private func render(_ view: some View, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = TestRepository.artifactDirectory("camera-ui-style")
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
                if predicate(Int(data[index]), Int(data[index + 1]),
                             Int(data[index + 2]), Int(data[index + 3])) {
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

    /// Minimal's flat selection fill: an opaque, dark, accent-matched disc. The
    /// capsule behind the whole group is neutral charcoal, so its tint tells the
    /// two apart without either one losing its contrast.
    private func darkFill(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        let high = max(red, max(green, blue))
        return alpha > 200 && high <= 90 && high - min(red, min(green, blue)) >= 3
    }

    /// The capsule Minimal seats the whole mode group in: a neutral charcoal
    /// plate, darker than the type it carries.
    private func wellFill(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 150 && max(red, max(green, blue)) <= 45
            && abs(red - green) < 3 && abs(green - blue) < 3
    }

    /// The dimmed neighbour letter — over the preview or over the capsule, where
    /// the composite is opaque instead of translucent.
    private func ghostInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 25 && red > 40 && red < 170
            && abs(red - green) < 6 && abs(green - blue) < 6
    }

    /// A bright glyph core: the selected caption, the QUEUE label, or a white
    /// readout.
    private func brightInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 128 && red > 170 && green > 170 && blue > 170
    }

    /// The classic plate is half-opaque black over the preview, so it lands at
    /// a mid alpha rather than the opaque fill Minimal does not paint.
    private func plateInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 100 && max(red, max(green, blue)) <= 90
    }

    /// Painted glyph ink of any tint: brighter than the plate and its rim, so a
    /// dim white, orange or red status all count, while an empty plate does not.
    private func faceInk(_ data: [UInt8]) -> Int {
        var count = 0
        var index = 0
        while index + 3 < data.count {
            if data[index + 3] > 80,
               max(Int(data[index]), max(Int(data[index + 1]), Int(data[index + 2]))) > 70 {
                count += 1
            }
            index += 4
        }
        return count
    }

    /// The tallest vertical run of bright ink inside a window of the face — a
    /// glyph's own height, wherever it sits.
    private func maxBrightRun(_ data: [UInt8], image: CGImage,
                              xFrom: Double = 0, xTo: Double = 1, yTo: Int? = nil) -> Int {
        let minX = max(0, Int(Double(image.width) * xFrom))
        let maxX = min(image.width, Int(Double(image.width) * xTo))
        let bottom = min(image.height, yTo ?? image.height)
        var longest = 0
        for x in minX..<maxX {
            var run = 0
            for y in 0..<bottom {
                let index = (y * image.width + x) * 4
                if brightInk(Int(data[index]), Int(data[index + 1]),
                             Int(data[index + 2]), Int(data[index + 3])) {
                    run += 1
                    if run > longest { longest = run }
                } else {
                    run = 0
                }
            }
        }
        return longest
    }

    /// Fraction of the rendered slot covered by a dark plate.
    private func darkCoverage(_ data: [UInt8]) -> Double {
        let total = data.count / 4
        var covered = 0
        var index = 0
        while index < data.count {
            if plateInk(Int(data[index]), Int(data[index + 1]),
                        Int(data[index + 2]), Int(data[index + 3])) { covered += 1 }
            index += 4
        }
        return Double(covered) / Double(max(total, 1))
    }

    private func whiteInk(_ data: [UInt8]) -> Int {
        var count = 0
        var index = 0
        while index < data.count {
            if brightInk(Int(data[index]), Int(data[index + 1]),
                         Int(data[index + 2]), Int(data[index + 3])) { count += 1 }
            index += 4
        }
        return count
    }

    /// Bright ink in the trailing third of the face — the queue mark's band.
    private func trailingInk(_ data: [UInt8], image: CGImage, from fraction: Double = 0.6) -> Int {
        var count = 0
        let start = Int(Double(image.width) * fraction)
        for y in 0..<image.height {
            for x in start..<image.width {
                let index = (y * image.width + x) * 4
                if brightInk(Int(data[index]), Int(data[index + 1]),
                             Int(data[index + 2]), Int(data[index + 3])) { count += 1 }
            }
        }
        return count
    }

    private func redInk(_ data: [UInt8]) -> Int {
        var count = 0
        var index = 0
        while index < data.count {
            if data[index] > 180 && data[index + 1] < 110 && data[index + 2] < 110
                && data[index + 3] > 180 { count += 1 }
            index += 4
        }
        return count
    }

    private func greenInk(_ data: [UInt8]) -> Int {
        var count = 0
        var index = 0
        while index < data.count {
            if data[index + 1] > 150 && data[index] < 150 && data[index + 2] < 150
                && data[index + 3] > 180 { count += 1 }
            index += 4
        }
        return count
    }

    private func orangeInk(_ data: [UInt8]) -> Int {
        var count = 0
        var index = 0
        while index < data.count {
            if data[index] > 190 && data[index + 1] > 110 && data[index + 1] < 190
                && data[index + 2] < 110 && data[index + 3] > 180 { count += 1 }
            index += 4
        }
        return count
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

    /// Cheap content digest, so two frames can be compared without pinning a
    /// colour threshold.
    private func digest(_ image: CGImage) -> Int {
        var hasher = Hasher()
        hasher.combine(image.width)
        hasher.combine(image.height)
        guard let data = try? pixels(image) else { return hasher.finalize() }
        var checksum = 0
        var index = 0
        while index < data.count {
            checksum = checksum &* 31 &+ Int(data[index])
            index += 4
        }
        hasher.combine(checksum)
        return hasher.finalize()
    }
}
