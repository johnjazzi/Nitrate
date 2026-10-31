import AppKit
import CoreGraphics
import SwiftUI
import Testing

/// The manual Video block's frame-rate key: one native menu that offers the
/// actual 24/60/120 rates, disables what the session cannot deliver, and is
/// locked while the session is recording or transitioning.
///
/// Every assertion is either pure presentation, a guard on the real control, or
/// a source contract over the wiring, so the menu can be inspected without a
/// camera. Physical rate selection and capture still need device validation.
struct CameraFrameRateControlTests {
    // MARK: - Offered rates

    @Test func offeredRatesAreCanonicalAndAscending() {
        let options = CameraFrameRateControlPresentation.options(availableFPS: [24, 60, 120])
        #expect(options.map(\.fps) == [24, 60, 120])
        #expect(options.map(\.faceValue) == ["24", "60", "120"])
    }

    @Test func unavailableRatesStayListedSoNothingIsHidden() {
        // A device that cannot run 120 still shows it, disabled, rather than
        // pretending the rate does not exist.
        let options = CameraFrameRateControlPresentation.options(availableFPS: [24, 60])
        #expect(options.map(\.fps) == [24, 60, 120])
        #expect(CameraFrameRateControlPresentation.isSupported(120, availableFPS: [24, 60]) == false)
        #expect(CameraFrameRateControlPresentation.canSelect(120, availableFPS: [24, 60], canChange: true) == false)
        #expect(CameraFrameRateControlPresentation.canSelect(24, availableFPS: [24, 60], canChange: true))
    }

    @Test func duplicateAndExtraRatesCollapseToOneOrderedList() {
        let options = CameraFrameRateControlPresentation.options(availableFPS: [120, 24, 120, 30])
        #expect(options.map(\.fps) == [24, 30, 60, 120])
        #expect(Set(options.map(\.id)).count == options.count)
    }

    // MARK: - Locking

    @Test func everyRateIsBlockedWhileTheSessionCannotChange() {
        for fps in [24, 60, 120] {
            #expect(CameraFrameRateControlPresentation.canSelect(
                fps, availableFPS: [24, 60, 120], canChange: false) == false)
        }
    }

    // MARK: - Honest face

    @Test func faceNeverRelabelsAnotherRateAsSixty() {
        #expect(CameraFrameRateOption(fps: 120).faceValue == "120")
        #expect(CameraFrameRateOption(fps: 24).faceValue == "24")
        #expect(CameraFrameRateControlPresentation.accessibilityValue(currentFPS: 120)
                == "120 frames per second")
        #expect(CameraFrameRateControlPresentation.rowTitle(fps: 60, currentFPS: 120)
                == "60 frames per second")
        #expect(CameraFrameRateControlPresentation.rowTitle(fps: 120, currentFPS: 120)
                == "120 frames per second, current")
    }

    @Test func standardRateIsNeutralAndHigherRatesAreOrange() {
        #expect(CameraFrameRateControlPresentation.faceColor(currentFPS: 24) == .white.opacity(0.85))
        #expect(CameraFrameRateControlPresentation.faceColor(currentFPS: 60)
                == InlineManualControlPresentation.activeOrange)
        #expect(CameraFrameRateControlPresentation.faceColor(currentFPS: 120)
                == InlineManualControlPresentation.activeOrange)
    }

    // MARK: - Layout

    @Test func rateKeyKeepsItsFortyFourPointFaceOnTheLeftColumn() {
        #expect(CameraFrameRateControlPresentation.optionHeight == 44)
        #expect(InlineFrameRateKeyPlacement.keyHeight == 44)
        #expect(InlineFrameRateKeyPlacement.spacing == 4)
        // The right stack is back to its three keys: AF/MF, aperture, stabilization.
        #expect(InlineManualControlPresentation.stackHeight == 140)
    }

    @Test func rateKeyDocksUnderTheZoomRailInVideoOnly() {
        // Video, a full-height column: the key docks and the rail keeps the rest.
        #expect(InlineFrameRateKeyPlacement.docksKey(isVideoMode: true, slotRun: 400))
        #expect(InlineFrameRateKeyPlacement.railHeight(slotRun: 400, docksKey: true) == 400 - 48)
        // Photo and Develop have no rate pipeline to steer.
        #expect(InlineFrameRateKeyPlacement.docksKey(isVideoMode: false, slotRun: 400) == false)
        #expect(InlineFrameRateKeyPlacement.railHeight(slotRun: 400, docksKey: false) == 400)
    }

    @Test func rateKeyNeverSqueezesTheZoomRailBelowItsOwnMinimum() {
        let shortest = InlineFrameRateKeyPlacement.keyHeight
            + InlineFrameRateKeyPlacement.spacing
            + InlineFrameRateKeyPlacement.minimumRailHeight
        #expect(shortest == 92)
        // Exactly the shortest column still docks the key and keeps a 44pt rail.
        #expect(InlineFrameRateKeyPlacement.docksKey(isVideoMode: true, slotRun: 92))
        #expect(InlineFrameRateKeyPlacement.railHeight(slotRun: 92, docksKey: true) == 44)
        // One point shorter: the zoom rail keeps the whole column rather than
        // producing a clipped button or an unusable rail.
        #expect(InlineFrameRateKeyPlacement.docksKey(isVideoMode: true, slotRun: 91) == false)
        #expect(InlineFrameRateKeyPlacement.railHeight(slotRun: 91, docksKey: false) == 91)
        // Non-finite geometry can never place a control off-frame.
        #expect(InlineFrameRateKeyPlacement.docksKey(isVideoMode: true, slotRun: .infinity) == false)
        #expect(InlineFrameRateKeyPlacement.docksKey(isVideoMode: true, slotRun: .nan) == false)
        #expect(InlineFrameRateKeyPlacement.railHeight(slotRun: .nan, docksKey: true) == 0)
    }

    // MARK: - Guards on the real control

    @Test @MainActor func choosingASupportedRateCallsTheSingleWriterOnce() {
        var written: [Int] = []
        let control = CameraFrameRateControl(availableFPS: [24, 60, 120], currentFPS: 24,
                                             canChange: true, select: { written.append($0) })
        control.choose(120)
        #expect(written == [120])
    }

    @Test @MainActor func choosingAnUnsupportedOrLockedRateWritesNothing() {
        var written: [Int] = []
        let unsupported = CameraFrameRateControl(availableFPS: [24, 60], currentFPS: 24,
                                                 canChange: true, select: { written.append($0) })
        unsupported.choose(120)
        let locked = CameraFrameRateControl(availableFPS: [24, 60, 120], currentFPS: 120,
                                            canChange: false, select: { written.append($0) })
        locked.choose(60)
        #expect(written.isEmpty)
    }

    // MARK: - Real composed layout

    /// The docked key, rendered through the real `FrameRulerSlot`, the real
    /// `FrameZoomRuler` and the real `CameraFrameRateControl` at the 44pt face
    /// the helper reports. The thin stroke rings mark each real frame without
    /// covering its face, so the measured ink is the actual layout:
    ///
    /// * the key is the bottom-most element of the physical-left column in
    ///   portrait and in both landscape holds (the single outer rotation),
    /// * the zoom rail keeps the run above it, with the 4pt gap intact,
    /// * nothing paints outside the left slot or into the focus column.
    @MainActor @Test func realLeftColumnDocksTheRateKeyAtTheSlotEndInEveryHold() throws {
        let canvas = CGSize(width: 200, height: 520)
        let bounds = CGRect(x: 20, y: 60, width: 160, height: 420)
        for degrees in [0.0, 90.0, -90.0] {
            let zoom = FrameRulerPlacementGeometry.rect(
                inFrame: bounds, edge: .left,
                thickness: FrameRulerPlacementGeometry.zoomThickness,
                orientationDegrees: degrees)
            let focus = FrameRulerPlacementGeometry.rect(
                inFrame: bounds, edge: .right,
                thickness: FrameRulerPlacementGeometry.focusThickness,
                orientationDegrees: degrees)
            #expect(!zoom.isNull && !focus.isNull && !zoom.intersects(focus))
            let run = abs(FrameRulerPlacementGeometry.normalized(degrees)) == 90
                ? zoom.width : zoom.height
            let docks = InlineFrameRateKeyPlacement.docksKey(isVideoMode: true, slotRun: run)
            #expect(docks, "a full-height column must dock the key at \(degrees)")

            let view = ZStack {
                Color.black
                FrameRulerSlot(rect: zoom, rotationDegrees: degrees) {
                    VStack(spacing: InlineFrameRateKeyPlacement.spacing) {
                        FrameZoomRuler(millimeters: 384, enabled: true, revision: 1,
                                       begin: { _ in }, end: { _ in }, step: { _ in },
                                       availableFocalRange: 96...384,
                                       visualWidth: FrameRulerPlacementGeometry.rulerVisualThickness)
                            .frame(height: InlineFrameRateKeyPlacement.railHeight(
                                slotRun: run, docksKey: docks))
                            .overlay(Rectangle().strokeBorder(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1), lineWidth: 2))
                        CameraFrameRateControl(
                            availableFPS: CameraFrameRateControlPresentation.canonicalFPS,
                            currentFPS: 120, canChange: true, select: { _ in })
                            .frame(height: InlineFrameRateKeyPlacement.keyHeight)
                            .overlay(Rectangle().strokeBorder(Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1), lineWidth: 2))
                    }
                    .frame(width: FrameRulerPlacementGeometry.zoomThickness)
                }
            }
            .frame(width: canvas.width, height: canvas.height)

            let image = try bitmap(view, size: canvas)
            let scale = CGFloat(image.width) / canvas.width
            func point(_ pixel: (x: Int, y: Int)) -> CGPoint {
                CGPoint(x: CGFloat(pixel.x) / scale, y: CGFloat(pixel.y) / scale)
            }
            let railInk = try ink(image) { $0.red > 0.75 && $0.green < 0.25 && $0.blue < 0.25 }
            let keyInk = try ink(image) { $0.blue > 0.75 && $0.red < 0.25 && $0.green < 0.25 }
            #expect(railInk.count > 200, "the real zoom rail must render at \(degrees)")
            #expect(keyInk.count > 200, "the real rate key must render at \(degrees)")

            let outside = (railInk + keyInk).filter {
                !zoom.insetBy(dx: -1, dy: -1).contains(point($0))
            }
            #expect(outside.isEmpty, "the left column must stay inside its slot at \(degrees)")
            let inFocusSlot = (railInk + keyInk).filter {
                focus.insetBy(dx: 1, dy: 1).contains(point($0))
            }
            #expect(inFocusSlot.isEmpty, "the left column must not reach the focus slot at \(degrees)")

            func inkBounds(_ pixels: [(x: Int, y: Int)]) -> CGRect {
                let points = pixels.map(point)
                let minX = points.map(\.x).min() ?? 0
                let maxX = points.map(\.x).max() ?? 0
                let minY = points.map(\.y).min() ?? 0
                let maxY = points.map(\.y).max() ?? 0
                return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            let key = inkBounds(keyInk)
            let rail = inkBounds(railInk)
            let slack: CGFloat = 4
            switch FrameRulerPlacementGeometry.normalized(degrees) {
            case 0:
                #expect(key.maxY >= zoom.maxY - slack, "portrait: the key must reach the slot bottom")
                #expect(rail.minY <= zoom.minY + slack, "portrait: the rail must keep the slot top")
                #expect(key.minY - rail.maxY >= 2, "portrait: the 4pt gap must survive")
                #expect((40...48).contains(key.height), "portrait: the key must keep its 44pt face")
            case 90:
                // The same single outer rotation that carries the column to the
                // physical-left edge also maps the authored bottom to this end.
                #expect(key.minX <= zoom.minX + slack, "+90: the key must reach the column's end")
                #expect(rail.maxX >= zoom.maxX - slack, "+90: the rail must keep the other end")
                #expect(rail.minX - key.maxX >= 2, "+90: the 4pt gap must survive")
                #expect((40...48).contains(key.width), "+90: the key must keep its 44pt face")
            default:
                #expect(key.maxX >= zoom.maxX - slack, "-90: the key must reach the column's end")
                #expect(rail.minX <= zoom.minX + slack, "-90: the rail must keep the other end")
                #expect(key.minX - rail.maxX >= 2, "-90: the 4pt gap must survive")
                #expect((40...48).contains(key.width), "-90: the key must keep its 44pt face")
            }
        }
    }

    // MARK: - Existing daylight compatibility

    @Test func armed120IsNeverPresentedOrSpokenAsDaylightSixty() {
        let face = RecordingStatusFace(presentation: .recording, text: "00:01.00",
                                       frameRateFPS: 120)
        #expect(face.modeStatusLabel == "REC · 120FPS")
        let spoken = face.spokenStatus
        #expect(spoken.contains("120 fps armed"))
        #expect(!spoken.contains("Daylight 60"))
    }

    @Test func legacyDaylightSixtyFaceIsUnchanged() {
        let armed = RecordingStatusFace(presentation: .recording, text: "00:01.00",
                                        daylight60Active: true)
        #expect(armed.modeStatusLabel == "REC · 60FPS")
        #expect(armed.spokenStatus.contains("Daylight 60 fps armed."))
        let standard = RecordingStatusFace(presentation: .recording, text: "00:01.00")
        #expect(standard.modeStatusLabel == "REC")
        #expect(standard.spokenStatus.contains("armed") == false)
    }

    // MARK: - Source contracts over the wiring

    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func contentViewWiresOneWriterFromTheSessionRates() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("currentFPS: cameraViewModel.sessionFrameRate.rawValue"))
        #expect(screen.contains("cameraViewModel.availableSessionFrameRates.map(\\.rawValue)"))
        #expect(screen.contains("canChange: cameraViewModel.canChangeSessionFrameRate"))
        #expect(screen.contains("select: selectInlineFrameRate"))
        #expect(screen.contains("cameraViewModel.setSessionFrameRate(mode)"))
        #expect(screen.contains("InlineManualControlPresentation.stackHeight"))
        // The too-bright rescue is the daylight 60 flow; a manual 120 must not
        // be offered it.
        #expect(screen.contains("daylightRescueSuppressedByHighRate"))
        #expect(screen.contains("cameraViewModel.sessionFrameRate == .high120"))
    }

    @Test func theRateKeyLivesInThePhysicalLeftZoomColumnUnderTheRail() throws {
        let screen = try source("App/ContentView.swift")
        let start = try #require(screen.range(of: "private func inlineFrameRulers"))
        let focusStart = try #require(screen.range(of: "let focusRect",
                                                  range: start.upperBound..<screen.endIndex))
        let leftColumn = String(screen[start.lowerBound..<focusStart.lowerBound])
        let rightColumn = String(screen[focusStart.lowerBound..<screen.endIndex].prefix(2400))

        // Same physical-left slot as the zoom rail, and the key is written under it.
        #expect(leftColumn.contains("edge: .left"))
        #expect(leftColumn.contains("FrameZoomRuler("))
        #expect(leftColumn.contains("CameraFrameRateControl(availableFPS: availableInlineFrameRates"))
        let rail = try #require(leftColumn.range(of: "FrameZoomRuler("))
        let key = try #require(leftColumn.range(of: "CameraFrameRateControl("))
        #expect(rail.lowerBound < key.lowerBound, "the key must sit below the zoom rail")
        #expect(leftColumn.contains("VStack(spacing: InlineFrameRateKeyPlacement.spacing)"))
        #expect(leftColumn.contains("InlineFrameRateKeyPlacement.docksKey("))
        #expect(leftColumn.contains("isVideoMode: !isPhotoMode && !isDevelopMode"))
        // One slot, one outer rotation: no extra rotation or canvas position for
        // the key, so landscape needs no second geometry.
        #expect(!leftColumn.contains("rotationEffect"))
        #expect(!leftColumn.contains(".position("))

        // The right stack no longer hosts it and keeps its three-key height.
        #expect(!rightColumn.contains("CameraFrameRateControl"))
        #expect(rightColumn.contains("InlineManualControls("))
        #expect(screen.contains(".frame(width: 44, height: InlineManualControlPresentation.stackHeight)"))
        #expect(!screen.contains("showsFrameRate:"))
    }

    @Test func theRightStackNoLongerHostsTheRateKey() throws {
        let stack = try source("App/Modules/CameraCapture/InlineManualControls.swift")
        #expect(!stack.contains("CameraFrameRateControl("))
        #expect(!stack.contains("availableFrameRates"))
        #expect(!stack.contains("chooseFrameRate"))
        #expect(stack.contains("static let stackHeight: CGFloat = 140"))
        // Three keys and nothing conditional left in the body.
        #expect(stack.contains("focusButton\n            apertureButton\n            stabilizationButton"))
    }

    // MARK: - Render helpers

    @MainActor private func bitmap<V: View>(_ view: V, size: CGSize) throws -> CGImage {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    private struct RGB { let red: CGFloat; let green: CGFloat; let blue: CGFloat }

    private func ink(_ image: CGImage, where matches: (RGB) -> Bool) throws -> [(x: Int, y: Int)] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width,
                                                 height: image.height, bitsPerComponent: 8,
                                                 bytesPerRow: image.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var hits: [(x: Int, y: Int)] = []
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = RGB(red: CGFloat(pixels[index]) / 255,
                          green: CGFloat(pixels[index + 1]) / 255,
                          blue: CGFloat(pixels[index + 2]) / 255)
            guard pixels[index + 3] > 220, matches(rgb) else { continue }
            hits.append(((index / 4) % image.width, (index / 4) / image.width))
        }
        return hits
    }
}
