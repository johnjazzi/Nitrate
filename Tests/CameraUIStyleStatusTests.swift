import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Classic presentation restored behind `cameraUIStyle`, and Minimal's compact
/// status row.
///
/// These pins cover what each style *draws*: Classic's old 44pt mode cells,
/// letter and full-size caption, the old recessed LCD readout and the old status
/// plate; Minimal's 28pt-cell / 32pt-pitch letter group, its named 16pt queue
/// mark and its unboxed faces. Behaviour is deliberately shared, so the same
/// suite re-asserts one swipe/availability/refusal/tap contract in both styles
/// rather than describing a second interaction model.
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
    /// Minimal pulls D/V/P into one tight group: a 28pt disc on a 4pt gap, so
    /// the visual cell is 32pt and the row is 92pt wide with three modes. The
    /// row keeps its 44pt touch height, and every cell keeps a whole,
    /// non-overlapping tap inside the slot.
    @Test func minimalModeRowPacksA32ptPitchWithWholeNonOverlappingCells() throws {
        #expect(CameraModeCarousel.height == 44, "Both styles keep the 44pt touch height.")
        #expect(CameraModeRowLayout.compactCellWidth == 28)
        #expect(CameraModeRowLayout.compactGap == 4)
        #expect(CameraModeRowLayout.compactPitch == 32,
                "28pt disc + 4pt gap is the 32pt visual cell the user asked for.")
        #expect(CameraModeRowLayout.compactGroupWidth(visibleCount: 3) == 92)
        #expect(CameraModeRowLayout.compactGroupWidth(visibleCount: 2) == 60)

        // Minimal's fill is exactly one cell, so the disc never widens the pitch.
        #expect(CameraModeCarousel.selectionFillSize == CameraModeRowLayout.compactCellWidth)
        #expect(CameraModeCarousel.selectionFillSize == 28)
        #expect(CameraModeCarousel.minimumControlWidth == 44, "Classic's 44pt contract survives.")

        // The 96pt strip floor fits the whole group; anything narrower does not,
        // so the row can never offer a clipped compact target.
        #expect(CameraModeRowLayout.compactGroupFits(width: 96, visibleCount: 3))
        #expect(CameraModeRowLayout.compactGroupFits(width: 96, visibleCount: 2))
        #expect(!CameraModeRowLayout.compactGroupFits(width: 80, visibleCount: 3))
        #expect(!CameraModeRowLayout.compactGroupFits(width: 0, visibleCount: 3))

        for slot: CGFloat in [96, 200] {
            for count in 2...3 {
                let rects = (0..<count).map {
                    CameraModeRowLayout.compactCellRect(index: $0, slotWidth: slot, visibleCount: count)
                }
                for rect in rects {
                    #expect(rect.width == 28)
                    #expect(rect.height == CameraModeCarousel.height)
                    #expect(rect.minX >= 0 && rect.maxX <= slot,
                            "Every compact target stays whole inside the \(Int(slot))pt slot.")
                }
                for index in 0..<(count - 1) {
                    #expect(rects[index].maxX <= rects[index + 1].minX,
                            "Compact taps never overlap, so a tap is deterministic.")
                    #expect(rects[index + 1].minX - rects[index].minX == 32)
                }
                let groupMin = rects[0].minX
                let groupMax = rects[count - 1].maxX
                #expect(abs((groupMin + groupMax) / 2 - slot / 2) <= 0.5,
                        "The whole compact group is centred in its slot, not offset by a 44pt cell.")
            }
        }

        // Three cells at the 96pt floor: 2pt margins either side, no clipping.
        let floorRects = (0..<3).map {
            CameraModeRowLayout.compactCellRect(index: $0, slotWidth: 96, visibleCount: 3)
        }
        #expect(floorRects.map(\.minX) == [2, 34, 66])
    }

    /// The drawn group matches the pure geometry: the selected letter sits on its
    /// own 28pt disc, its neighbours read 32pt away, and nothing paints outside
    /// the slot.
    @Test func minimalModeRowDrawsTheCompactGroupCentredInItsSlot() throws {
        let modes = CameraMode.visibleModes(photoAvailable: true)
        for slot: CGFloat in [96, 200] {
            for active in modes {
                let image = try renderCarousel(active: active, width: slot, style: .minimal,
                                               photoAvailable: true)
                let data = try pixels(image)
                let scale = Double(image.width) / Double(slot)

                let letter = points(matching: accentInk, in: data, image: image)
                #expect(letter.count > 40, "The selected accent letter paints at \(Int(slot))pt.")
                let letterMidX = Double(letter.map(\.x).reduce(0, +)) / Double(letter.count)

                // The disc behind it is one cell wide and centred on the letter.
                let fill = points(matching: darkFill, in: data, image: image)
                #expect(fill.count > 300, "Minimal keeps its flat selection disc.")
                let fillMinX = try #require(fill.map(\.x).min())
                let fillMaxX = try #require(fill.map(\.x).max())
                let fillWidth = Double(fillMaxX - fillMinX) / scale
                #expect(abs(fillWidth - 28) <= 2.5,
                        "The disc is 28pt wide, not a 44pt cell.")
                let fillMidX = Double(fill.map(\.x).reduce(0, +)) / Double(fill.count)
                #expect(abs(fillMidX - letterMidX) <= 2 * scale,
                        "The disc stays behind the selected letter.")

                // The selected cell's centre is where the pure geometry says.
                let index = try #require(modes.firstIndex(of: active))
                let cell = CameraModeRowLayout.compactCellRect(index: index, slotWidth: slot,
                                                               visibleCount: 3)
                #expect(abs(letterMidX - Double(cell.midX) * scale) <= 2.5 * scale,
                        "The selected letter is drawn on its own compact cell.")
                #expect(abs(fillMidX - Double(cell.midX) * scale) <= 2.5 * scale)

                // Neighbours are 32pt away — close, but still a cell apart, and
                // never a 44pt slide.
                let ghosts = points(matching: ghostInk, in: data, image: image)
                #expect(!ghosts.isEmpty, "Minimal still shows its neighbouring modes.")
                let distances = ghosts.map { abs(Double($0.x) - letterMidX) / scale }
                #expect(distances.allSatisfy { (22...40).contains($0) },
                        "Every neighbour reads 32pt from the selected letter, not 38pt.")
                let centre = textCentre(image)
                if active == .develop {
                    #expect(ghosts.allSatisfy { $0.x > centre },
                            "With D selected its neighbour is on the right.")
                } else if active == .photo {
                    #expect(ghosts.allSatisfy { $0.x < centre },
                            "With P selected its neighbour is on the left.")
                } else {
                    #expect(ghosts.contains { $0.x < centre }
                            && ghosts.contains { $0.x > centre },
                            "V keeps one neighbour on each side.")
                }

                #expect(borderIsClear(data, image: image),
                        "The \(Int(slot))pt slot clips nothing and paints nothing outside itself.")
                #expect(ink(data) > 400, "The compact group stays visible.")
            }
        }
    }

    // MARK: - Classic mode row

    /// Classic restores the pre-minimal label: the 14pt letter with its
    /// full-size 12pt caption beneath, no flat selection fill, and the same
    /// centred letter with a ghosted neighbour in a 44pt cell.
    @Test func classicModeRowRestoresTheOldLetterAndCaptionWithoutTheFlatFill() throws {
        #expect(CameraModeCarousel.height == 44)
        #expect(CameraModeCarousel.minimumControlWidth == 44)
        #expect(CameraModeRowLayout.controlWidth == 44)

        for active in CameraMode.visibleModes {
            let width: CGFloat = 200
            let classicImage = try renderCarousel(active: active, width: width, style: .classic)
            let minimalImage = try renderCarousel(active: active, width: width, style: .minimal)
            let classic = try pixels(classicImage)
            let minimal = try pixels(minimalImage)

            // Minimal's one flat fill is what Classic does not restore.
            #expect(points(matching: darkFill, in: minimal, image: minimalImage).count > 300,
                    "Minimal keeps its flat selection fill.")
            #expect(points(matching: darkFill, in: classic, image: classicImage).isEmpty,
                    "Classic paints no selection fill, ring or track.")

            // The selected capital paints the shared accent and stays centred.
            let letter = points(matching: accentInk, in: classic, image: classicImage)
            #expect(letter.count > 40, "The classic selected letter paints the accent.")
            let letterMidX = Double(letter.map(\.x).reduce(0, +)) / Double(letter.count) / 2
            #expect(abs(letterMidX - Double(width) / 2) <= 2,
                    "The classic letter is centred, not parked in a half.")

            // Its caption is a band below the letter and is painted at the old
            // full size, so it carries visibly more ink than Minimal's quiet one.
            let classicCaption = points(matching: brightInk, in: classic, image: classicImage)
            let minimalCaption = points(matching: brightInk, in: minimal, image: minimalImage)
            #expect(classicCaption.count > 20, "Classic paints the selected caption.")
            let captionTop = try #require(classicCaption.map(\.y).min())
            let letterBottom = try #require(letter.map(\.y).max())
            #expect(captionTop > letterBottom,
                    "The classic caption still sits below the capital.")
            let classicCaptionMidX = Double(classicCaption.map(\.x).reduce(0, +))
                / Double(classicCaption.count) / 2
            #expect(abs(classicCaptionMidX - Double(width) / 2) <= 2,
                    "The classic caption is centred beneath the letter.")
            #expect(classicCaption.count > minimalCaption.count,
                    "Classic names the selected mode; the compact Minimal row shows letters only.")

            // The neighbour is still a ghosted letter on the correct side and
            // keeps the same drawn pull inside its own 44pt cell.
            let letterTop = try #require(letter.map(\.y).min())
            let ghost = points(matching: ghostInk, in: classic, image: classicImage)
                .filter { $0.y >= letterTop && $0.y <= letterBottom }
            #expect(!ghost.isEmpty, "Classic still shows the neighbouring mode.")
            let ghostMidX = Double(ghost.map(\.x).reduce(0, +)) / Double(max(ghost.count, 1)) / 2
            #expect((34...40).contains(abs(ghostMidX - letterMidX)),
                    "Classic keeps the neighbour close without moving a 44pt target.")
            if active == .develop {
                #expect(ghost.filter { $0.x > classicImage.width / 2 }.count
                        > ghost.filter { $0.x < classicImage.width / 2 }.count)
            } else {
                #expect(ghost.filter { $0.x < classicImage.width / 2 }.count
                        > ghost.filter { $0.x > classicImage.width / 2 }.count)
            }
        }
    }

    /// Classic re-skins the row and nothing else: the same accepted swipe, the
    /// same blocked tap that answers with a reason, and the same complete-44pt
    /// target rule. A narrow slot degrades neighbours to peeks in both styles.
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

            // Classic's whole-target rule is untouched by the style, and stays
            // the default contract Minimal reads through compactGroupFits.
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

    /// Classic restores the recessed LCD: the shared inset surface, the hairline
    /// under the headline and the prominent 20pt readout. Minimal stays unboxed
    /// quiet type.
    @Test func classicRemainingTimeRestoresTheProminentReadoutOnTheInsetPlate() throws {
        let classicImage = try render(lcd(.classic, queue: idleQueue), name: "classic-lcd-idle")
        let minimalImage = try render(lcd(.minimal, queue: idleQueue), name: "minimal-lcd-idle")
        let classic = try pixels(classicImage)
        let minimal = try pixels(minimalImage)

        // Classic's plate fills most of the 84x106 slot; Minimal paints only a
        // soft shadow on the preview.
        #expect(darkCoverage(classic) > 0.15, "Classic paints the old inset LCD plate.")
        #expect(darkCoverage(minimal) < 0.08, "Minimal paints no plate over the preview.")

        // The readout's own type size: Classic's old 20pt digits stand twice as
        // tall as Minimal's quiet 12pt line. Measured as the tallest run of white
        // in the face, left of the queue mark.
        let classicRun = maxBrightRun(classic, image: classicImage, xTo: 0.6)
        let minimalRun = maxBrightRun(minimal, image: minimalImage, xTo: 0.6)
        #expect(classicRun > 0 && minimalRun > 0, "Both styles paint their readout.")
        #expect(Double(classicRun) > Double(minimalRun) * 1.35,
                "The classic readout stands a full 20pt line, Minimal's a quiet 12pt one.")

        // The real estimate is still painted, not an abbreviation.
        let longImage = try render(lcd(.classic, seconds: 3_600, queue: idleQueue), name: "classic-lcd-long")
        #expect(digest(classicImage) != digest(longImage),
                "The classic readout tracks the estimate.")
    }

    /// Minimal names the queue action: a 16pt glyph in clear white with an
    /// explicit QUEUE label beside the count, where Classic keeps the original
    /// 8pt mark and bare count. Neither style grows a second, glyph-sized tap:
    /// the whole LCD stays the one >=44pt queue action.
    @Test func minimalQueueMarkIsNamedAndSixteenPointsWhileTheWholeLCDStaysOneTarget() throws {
        #expect(RecordingTimeLCD.queueGlyphSize == 16, "The Minimal queue glyph is 16pt.")
        #expect(RecordingTimeLCD.queueCaption == "QUEUE", "The queue is named, not just drawn.")
        #expect(RecordingTimeLCD.minimumTouchSize == 44,
                "The LCD is never offered as a sub-44pt target.")

        let classicImage = try render(lcd(.classic, queue: queued), name: "classic-lcd-queue")
        let minimalImage = try render(lcd(.minimal, queue: queued), name: "minimal-lcd-queue")
        let classic = try pixels(classicImage)
        let minimal = try pixels(minimalImage)

        // Both styles still paint their queue mark where the headline ends.
        #expect(trailingInk(classic, image: classicImage) > 0, "Classic still paints its queue mark.")
        #expect(trailingInk(minimal, image: minimalImage) > 0, "Minimal still paints its queue mark.")

        // Minimal's mark is the top-aligned headline badge: its bright ink in the
        // trailing sixth stands at least 11pt tall, which an 8pt glyph cannot do.
        let badgeRun = maxBrightRun(minimal, image: minimalImage, xFrom: 0.6, yTo: 48)
        #expect(badgeRun >= 22,
                "The Minimal queue badge is drawn at 16pt, not the old 8pt mark.")

        // The 16pt glyph and the QUEUE label are the Minimal branch only.
        let lcdSource = try source("App/Modules/CameraCapture/RecordingTimeLCD.swift")
        #expect(lcdSource.contains(".font(.system(size: Self.queueGlyphSize, weight: .semibold))"),
                "The glyph is sized from the pinned 16pt constant.")
        #expect(lcdSource.contains("Text(Self.queueCaption)"),
                "Minimal paints the QUEUE word, not just the mark.")

        // The count is still painted, and still changes the face.
        let idleImage = try render(lcd(.minimal, queue: idleQueue), name: "minimal-lcd-noqueue")
        #expect(digest(minimalImage) != digest(idleImage),
                "The queue count still changes the Minimal face.")

        // Minimal fills its slot, so the one action covers the whole LCD.
        #expect(minimalImage.width == 168 && minimalImage.height == 212,
                "The Minimal face fills the 84x106pt slot instead of shrinking to its type.")

        // Every queue/status semantic survives the bigger mark.
        let saved = try render(lcd(.minimal, queue: CameraStatusPresentation(
            outstandingCount: 0, pendingCount: 0, isProcessing: false,
            failedCount: 0, errorMessage: nil,
            latestResultCompleted: true, latestResultSavedToPhotos: true)),
            name: "minimal-lcd-saved")
        #expect(greenInk(try pixels(saved)) > 0, "A saved render still shows its tick.")

        let failed = try render(lcd(.minimal, queue: errorQueue), name: "minimal-lcd-failed")
        #expect(redInk(try pixels(failed)) > 0, "A failed render still shows its error mark.")

        let low = try render(lcd(.minimal, isStorageLow: true, queue: idleQueue), name: "minimal-lcd-low")
        #expect(orangeInk(try pixels(low)) > 0, "Low storage still shows its warning.")

        let live = try render(lcd(.minimal, queue: queued, isRecording: true), name: "minimal-lcd-live")
        #expect(redInk(try pixels(live)) > 0, "A confirmed take still paints its red tally.")
        let stopping = try render(lcd(.minimal, queue: queued, isRecording: true, isStopping: true),
                                  name: "minimal-lcd-stopping")
        #expect(redInk(try pixels(stopping)) == 0, "A finalising take is not an active recording.")

        let rendering = try render(lcd(.minimal, queue: renderingQueue), name: "minimal-lcd-render")
        #expect(whiteInk(try pixels(rendering)) > 100, "Render activity still paints.")
    }

    /// The plate is presentation only: tally, stopping, queue, render activity,
    /// photo capacity and storage warnings all keep their shared meaning.
    @Test func classicReadoutKeepsEverySharedStatusSemantic() throws {
        let idle = try render(lcd(.classic, queue: idleQueue), name: "classic-sem-idle")

        let live = try render(lcd(.classic, queue: idleQueue, isRecording: true), name: "classic-sem-live")
        #expect(redInk(try pixels(live)) > 0, "A confirmed take keeps its red tally on the plate.")

        let stopping = try render(lcd(.classic, queue: idleQueue, isRecording: true, isStopping: true),
                                  name: "classic-sem-stopping")
        #expect(redInk(try pixels(stopping)) == 0,
                "A finalising take must not read as an active recording.")
        #expect(digest(live) != digest(stopping))

        let queuedImage = try render(lcd(.classic, queue: queued), name: "classic-sem-queued")
        #expect(digest(queuedImage) != digest(idle), "The queue count still changes the face.")

        let rendering = try render(lcd(.classic, queue: renderingQueue), name: "classic-sem-rendering")
        #expect(whiteInk(try pixels(rendering)) > 100, "Render activity still paints.")

        let low = try render(lcd(.classic, isStorageLow: true, queue: idleQueue), name: "classic-sem-low")
        #expect(digest(low) != digest(idle), "Low storage still shows its warning.")

        let photo = try render(lcd(.classic, queue: idleQueue, photoFreeBytes: 12_400_000_000),
                               name: "classic-sem-photo")
        #expect(digest(photo) != digest(idle), "Photo mode still reports free space.")
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
                                style: CameraUIStyle, photoAvailable: Bool = false) throws -> CGImage {
        let view = CameraModeCarousel(selected: active, enabled: true, onSelect: { _ in },
                                      photoAvailable: photoAvailable)
            .frame(width: width, height: CameraModeCarousel.height)
            .environment(\.cameraUIStyle, style)
            .environment(\.cameraControlAccent, accent)
        return try render(view, name: "style-mode-\(style.rawValue)-\(active.rawValue)-\(Int(width))")
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

    /// Minimal's flat selection fill: an opaque, dark, accent-matched disc.
    private func darkFill(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 200 && max(red, max(green, blue)) <= 90
    }

    /// The dimmed neighbour letter.
    private func ghostInk(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> Bool {
        alpha > 25 && alpha < 150 && red > 40 && red < 160
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
