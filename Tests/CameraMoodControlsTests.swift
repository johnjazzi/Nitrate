import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Contract for the shooting bar's mood controls: the LCD moves to the upper
/// two thirds, the stock selector and gauge share the recessed well below it,
/// a confirmed take owns the LCD headline over any queue activity, and the
/// exposure lock acknowledgement is driven by the committed mode alone.
struct CameraMoodControlsTests {
    private let screenWidths: [CGFloat] = [320, 375, 430]
    private let barHeights: [CGFloat] = [168, 180, 200]

    @Test func exposureControlKeepsNumbersWithoutRepeatedVisibleCaptions() throws {
        let root = TestRepository.root
        let bar = try String(contentsOf: root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraControlBar.swift"), encoding: .utf8)
        let meter = try String(contentsOf: root.appendingPathComponent(
            "App/Modules/CameraCapture/ExposureOverlay.swift"), encoding: .utf8)
        #expect(!bar.contains("Text(cameraViewModel.isManualExposure ? \"ISO\" : \"EV\")"))
        #expect(bar.contains("return \"ISO \\(Int(cameraViewModel.liveISO))\""),
                "Keep the existing ISO readout above its ruler")
        #expect(!meter.contains("directionLabel(\"OVER\")"))
        #expect(!meter.contains("directionLabel(\"UNDER\")"))
        #expect(!meter.contains("Text(statusText)"))
        #expect(meter.contains(".accessibilityLabel("), "Retain nonvisual meter information")
        // The ISO number above the ruler survives the simplification, and it is
        // now the only case that prints one: Minimal's auto EV drops its
        // standalone number in both finishes, because the ruler's own drawn
        // index is the value. The line stays in the layout, invisible and out of
        // the accessibility tree, so the column's measured height does not move.
        #expect(bar.contains("let showsNumbers = cameraViewModel.isManualExposure"),
                "Only the manual ISO keeps a number above its ruler, in both styles.")
        #expect(bar.contains(".opacity(showsNumbers ? 1 : 0)"))
        #expect(bar.contains(".accessibilityHidden(!showsNumbers)"),
                "The hidden auto line must leave the accessibility tree too.")
        #expect(bar.contains(".accessibilityIdentifier(\"camera.evBiasRuler\")"))
        #expect(bar.contains(".accessibilityValue(evBiasSpokenValue)"))
    }

    @Test func exposureLongPressHasVisibleProgressAsWellAsCommittedHaptics() throws {
        let bar = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraControlBar.swift"), encoding: .utf8)
        #expect(bar.contains("@GestureState private var isExposureHolding = false"))
        #expect(bar.contains(".updating($isExposureHolding)"),
                "Release or cancellation must reset the visual hold state")
        #expect(bar.contains(".scaleEffect("))
        #expect(bar.contains("value: isExposureHolding"))
        #expect(bar.contains(".sensoryFeedback(trigger: cameraViewModel.isManualExposure)"))
        #expect(bar.contains("LongPressGesture(minimumDuration: 0.5, maximumDistance: 3)"))
    }

    @Test func removingCaptionsPreservesTheShootingBarHeight() throws {
        let bar = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraControlBar.swift"), encoding: .utf8)
        #expect(bar.contains("Text(\" \")"),
                "Reserve the old footer's font metrics without visible words so the preview does not resize")
        #expect(bar.contains(".accessibilityHidden(true)"))
    }

    @Test func aBusyCaptureDoesNotAcknowledgeAnExposureHold() throws {
        let bar = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraControlBar.swift"), encoding: .utf8)
        #expect(bar.contains("state = current && exposureHoldEnabled"))
        #expect(bar.contains("guard exposureHoldEnabled else { return }"))
    }

    @Test func exposureHoldBelongsToTheWholeWellRatherThanTheRuler() throws {
        let bar = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraControlBar.swift"), encoding: .utf8)
        let wellStart = try #require(bar.range(of: "private var exposureControl: some View"))
        let enabledStart = try #require(bar.range(of: "private var exposureHoldEnabled: Bool"))
        let settingStart = try #require(bar.range(of: "private var exposureSetting: some View"))
        let readoutStart = try #require(bar.range(of: "private var exposureReadout: String"))
        let well = String(bar[wellStart.lowerBound..<enabledStart.lowerBound])
        let setting = String(bar[settingStart.lowerBound..<readoutStart.lowerBound])
        #expect(well.contains(".contentShape(Rectangle())"))
        #expect(well.contains(".simultaneousGesture("))
        #expect(well.contains(".scaleEffect("))
        #expect(well.contains(".sensoryFeedback(trigger: cameraViewModel.isManualExposure)"))
        #expect(!setting.contains(".simultaneousGesture("))
        #expect(!setting.contains(".scaleEffect("))
        let scale = try #require(well.range(of: ".scaleEffect("))
        let measured = try #require(well.range(of: ".background {"))
        #expect(scale.lowerBound < measured.lowerBound,
                "Measure the unscaled well so the rescue anchor does not move during a hold")
        // The bar now carries two long presses — the stock entry's hold for the
        // full list and this exposure lock — so the count is scoped to the
        // control that owns it instead of the whole file.
        #expect(well.components(separatedBy: "LongPressGesture(minimumDuration:").count == 2,
                "The exposure well owns exactly one long press.")
        #expect(!setting.contains("LongPressGesture"),
                "The ruler beneath the well never grows a second long press.")
        #expect(bar.contains("LongPressGesture(minimumDuration: CameraStockEntry.holdThreshold"),
                "The other long press is the stock entry's hold, not a second exposure path.")
    }

    @Test func lcdSlotFollowsTheStockAndStaysClearOfRecord() {
        for screenWidth in screenWidths {
            for height in barHeights {
                let width = screenWidth - 32
                let geometry = CameraControlGeometry(width: width, height: height)
                // Exposure still owns the shared height.
                #expect(geometry.exposure.height == height)
                // Remaining-time type follows the flat stock entry.
                #expect(geometry.lcd.minY == geometry.stock.maxY + CameraControlGeometry.columnGap)
                #expect(geometry.lcd.maxY <= height)
                #expect(geometry.stock.height >= 44)
                // REC stays screen-centred and never collides with the left column.
                #expect(geometry.record.midX == width / 2)
                for slot in [geometry.lcd, geometry.stock] {
                    #expect(slot.minX >= 0)
                    #expect(slot.maxX <= CameraControlGeometry.leftWidth)
                    #expect(!slot.intersects(geometry.record))
                    #expect(!slot.intersects(geometry.exposure))
                }
                #expect(!geometry.lcd.intersects(geometry.stock))
            }
        }
    }

    @Test func bothLeftSlotsKeepGlyphsUprightInEveryHold() {
        for screenWidth in screenWidths {
            for degrees in [0.0, 90.0, -90.0, 180.0] {
                let geometry = CameraControlGeometry(width: screenWidth - 32, height: 168)
                for slot in [geometry.lcd.size, geometry.stock.size] {
                    let face = CameraControlGeometry.faceSize(in: slot, degrees: degrees)
                    #expect(CameraControlGeometry.faceSize(in: face, degrees: degrees) == slot,
                            "Swapping the LCD and well must not disturb the rotated-face contract.")
                }
            }
        }
    }

    @Test func lcdFocusPrefersAConfirmedTakeOverQueueActivity() {
        #expect(RecordingTimeLCDFocus.resolve(isRecording: true, isStopping: false, isProcessing: true) == .recording)
        #expect(RecordingTimeLCDFocus.resolve(isRecording: true, isStopping: false, isProcessing: false) == .recording)
        // Finalising is a live take but must never read as an active recording.
        #expect(RecordingTimeLCDFocus.resolve(isRecording: true, isStopping: true, isProcessing: true) == .rendering)
        #expect(RecordingTimeLCDFocus.resolve(isRecording: true, isStopping: true, isProcessing: false) == .remaining)
        // Nothing in flight means rendering; otherwise the remaining time stands alone.
        #expect(RecordingTimeLCDFocus.resolve(isRecording: false, isStopping: false, isProcessing: true) == .rendering)
        #expect(RecordingTimeLCDFocus.resolve(isRecording: false, isStopping: false, isProcessing: false) == .remaining)
    }

    @MainActor @Test func recordingLCDShowsATallyOnlyWhileTheTakeIsLive() throws {
        let rendering = CameraStatusPresentation(outstandingCount: 3, pendingCount: 2, isProcessing: true,
                                                 failedCount: 0, errorMessage: nil,
                                                 latestResultCompleted: false, latestResultSavedToPhotos: nil)
        let idle = CameraStatusPresentation(outstandingCount: 0, pendingCount: 0, isProcessing: false,
                                            failedCount: 0, errorMessage: nil,
                                            latestResultCompleted: false, latestResultSavedToPhotos: nil)
        let slot = CameraControlGeometry(width: 288, height: 168).lcd.size
        let live = try render(lcdFrame(RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false,
                                                        queueStatus: rendering,
                                                        isRecording: true), slot: slot),
                              name: "lcd-recording")
        let stopping = try render(lcdFrame(RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false,
                                                            queueStatus: idle,
                                                            isRecording: true, isStopping: true), slot: slot),
                                  name: "lcd-stopping")
        let quiet = try render(lcdFrame(RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false,
                                                         queueStatus: idle), slot: slot),
                               name: "lcd-idle")
        #expect(tallyInk(live) > 0, "An active take must read RECORDING on the LCD.")
        #expect(tallyInk(stopping) == 0, "A finalising take must not read as an active recording.")
        #expect(tallyInk(quiet) == 0, "Queue rendering alone must not raise the recording tally.")
        #expect(whiteInk(live) > 200, "Queue and remaining-time ink must survive the recording state.")
        #expect(whiteInk(quiet) > 200)
        #expect(pixelsDigest(live) != pixelsDigest(quiet), "The recording face must differ from the idle one.")
        #expect(pixelsDigest(stopping) == pixelsDigest(quiet),
                "A finalising take falls back to the plain face, never the recording headline.")
    }

    /// Both finishes report free space in Photo, and both now print it on the
    /// same one capacity line — `12.50 GB`, hundredths floored — because the LCD
    /// is one shared face. Classic's captioned plate readout is gone: the
    /// one-decimal `capacityText` accessor below is legacy surface with no
    /// drawing path left, kept only so its formatted value stays pinned.
    @MainActor @Test func photoLCDPrintsFreeSpaceInBothStyles() throws {
        let idle = CameraStatusPresentation(outstandingCount: 0, pendingCount: 0, isProcessing: false,
            failedCount: 0, errorMessage: nil, latestResultCompleted: false, latestResultSavedToPhotos: nil)
        let slot = CameraControlGeometry(width: 288, height: 168).lcd.size
        let low = RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false, queueStatus: idle,
            photoFreeBytes: 12_500_000_000)
        let high = RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false, queueStatus: idle,
            photoFreeBytes: 97_300_000_000)
        #expect(low.capacityText == "12.5 GB")
        #expect(high.capacityText == "97.3 GB")
        #expect(low.minimalReadoutText == "12.50 GB", "The shared line prints hundredths, floored.")
        #expect(high.minimalReadoutText == "97.30 GB")

        func digest(_ lcd: RecordingTimeLCD, _ style: CameraUIStyle) throws -> Int {
            try pixelsDigest(try render(lcdFrame(lcd.environment(\.cameraUIStyle, style), slot: slot),
                                        name: "photo-lcd-\(style.rawValue)-\(lcd.capacityText)"))
        }
        let minimalLow = try digest(low, .minimal)
        let minimalHigh = try digest(high, .minimal)
        let classicLow = try digest(low, .classic)
        let classicHigh = try digest(high, .classic)
        #expect(minimalLow != minimalHigh,
                "Minimal's capacity line still changes with free bytes.")
        #expect(classicLow != classicHigh,
                "Classic prints the same capacity line, and it still changes with free bytes.")
        #expect(classicLow == minimalLow && classicHigh == minimalHigh,
                "Both finishes draw the same LCD face; the style no longer re-skins it.")
    }

    @MainActor @Test func photoRenderingOwnsTheLCDEvenWhenCapacityIsAvailable() {
        let rendering = CameraStatusPresentation(outstandingCount: 1, pendingCount: 0, isProcessing: true,
            failedCount: 0, errorMessage: nil, latestResultCompleted: false, latestResultSavedToPhotos: nil)
        let lcd = RecordingTimeLCD(estimatedSeconds: 754, isStorageLow: false, queueStatus: rendering,
            photoFreeBytes: 12_500_000_000, isPhotoMode: true)
        #expect(lcd.showsRenderingActivity,
                "Active Photo rendering must replace idle free-space digits with the render activity, not hide behind them.")
    }

    @Test func photoLensMenuIsNotBlanketDisabled() throws {
        let screen = try String(contentsOf: TestRepository.url(for: "App/ContentView.swift"), encoding: .utf8)
        #expect(!screen.contains(".disabled(isPhotoMode || cameraViewModel.isPhotoCaptureBusy)"),
            "Photo must allow the actual top lens menu, not only direct session calls.")
    }

    @Test func photoModeKeepsStorageVisible() throws {
        let bar = try String(contentsOf: TestRepository.url(for: "App/Modules/CameraCapture/CameraControlBar.swift"), encoding: .utf8)
        #expect(!bar.contains(".opacity(isPhotoMode ? 0 : 1)"), "Photo must not hide free capacity.")
        #expect(!bar.contains(".accessibilityHidden(isPhotoMode)"))
    }

    @Test func barOwnsTheWellRecordingStateAndTheLockHapticOnce() throws {
        let bar = try String(contentsOf: TestRepository.url(for: "App/Modules/CameraCapture/CameraControlBar.swift"),
                             encoding: .utf8)
        #expect(bar.contains("CameraShootingLayout(style: uiStyle)"))
        // Stock and gauge share one entry. A tap opens the compact picker and a
        // held press the full list in both finishes — the bar names the two
        // destinations directly and hands the request to `CameraStockEntry`, so
        // the entry times its own press instead of using a Button, which would
        // fire once on release whatever happened.
        #expect(bar.contains(".gesture(stockEntryGesture)"))
        #expect(bar.contains(".exclusively(before: TapGesture())"),
                "Exclusivity is what stops a recognized hold also firing the tap action.")
        #expect(bar.contains("if held { openStockEntry(.full) }"),
                "A hold opens the full list straight away, without waiting for release.")
        #expect(bar.contains("case .second(_):"),
                "Only the tap reaches the compact, item-based picker.")
        #expect(bar.contains("openStockEntry(.compact)"))
        #expect(bar.contains("CameraStockEntry.resolved(requested, style: uiStyle)"),
                "The style no longer rewrites a requested entry; resolution preserves it.")
        #expect(!bar.contains("CameraStockEntry.destination("),
                "The bar times the real gesture; it does not re-derive a destination from a duration.")
        #expect(!bar.contains("Button(action: onShowStockSheet)"))
        // Both finishes seat the cluster in the shared well; the plate's face is
        // the only difference (Classic keeps its bevel). The 3pt pad gives the
        // face breathing room and the matching negative pad keeps it from
        // growing the slot.
        #expect(bar.contains("selectorContents\n            .padding(3)\n            .cameraWellBacking()"),
                "The cluster sits in the shared well on a 3pt pad.")
        #expect(bar.contains(".padding(-3)\n        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)"),
                "The negative pad cancels the inset, so the well never resizes the slot.")
        #expect(bar.contains("CameraGaugeLabel(gauge: selectedGauge)"),
                "The gauge label is the readout under the stock face.")
        // The processing readout is hidden while the exposure is neutral, and
        // takes the shared processing tint — push one colour, pull the other —
        // rather than a control-accent colour of its own.
        #expect(bar.contains("if let pushPull, !pushPull.isNeutral {"),
                "A neutral exposure adds no badge: there is nothing being processed.")
        #expect(bar.contains("pushPull.stops.processingTint"),
                "The badge reads the one shared processing tint.")
        #expect(!bar.contains("CameraPushPullTint"),
                "No second copy of the processing colours on the camera bar.")
        // Both rulers read the shared dial-size preference, and the 120pt outer
        // slot keeps the preview and the shooting bar fixed.
        #expect(bar.components(separatedBy: "length: exposureDialSize.length").count == 3,
                "The exposure rulers are untouched: they take their window from the shared size.")
        #expect(bar.components(separatedBy: "width: exposureDialSize.width").count == 3)
        #expect(bar.components(separatedBy: ".frame(height: 120)").count == 3,
                "The 120pt outer slot is unchanged whatever dial size is chosen.")
        // The LCD acknowledges the accepted take before the writer confirms it.
        #expect(bar.contains("isRecording: recordPresentation.showsLiveChrome"))
        #expect(bar.contains("isStopping: cameraViewModel.isStoppingRecording"))
        // Success and issue content is the same inside the LCD, because one
        // shared outline draws it over the face.
        #expect(bar.contains("CameraQueueAttentionOutline(hasIssue: queueAttention.hasUnseenIssue,"))
        #expect(bar.contains("if isStorageLow { snapshot.issues.insert(\"low-storage\") }"),
                "Low storage is a queue issue, carried by the outline and the spoken value.")
        // Queue/storage access survives an active take.
        #expect(bar.contains("onShowQueueSheet"))
        // One acknowledgement, keyed to the committed mode, so neither the long
        // press nor the accessibility action can double-fire it and polling cannot trigger it.
        #expect(bar.components(separatedBy: "trigger: cameraViewModel.isManualExposure").count == 2)
        #expect(bar.contains("ManualExposureLockFeedback.sensory(isManual: isManual)"))
        // Distinct lock and release feedback.
        #expect(bar.contains("flexibility: .rigid") && bar.contains("flexibility: .soft"))
    }

    // MARK: - Helpers

    private func lcdFrame<Content: View>(_ lcd: Content, slot: CGSize) -> some View {
        lcd
            .frame(width: slot.width, height: slot.height)
            .padding(4)
            .background(Color.black)
    }

    @MainActor
    private func render(_ view: some View, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = TestRepository.artifactDirectory("camera-mood-controls")
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

    private func tallyInk(_ image: CGImage) -> Int {
        guard let data = try? pixels(image) else { return 0 }
        return stride(from: 0, to: data.count, by: 4).filter { index in
            Int(data[index]) > 170 && Int(data[index + 1]) < 90 && Int(data[index + 2]) < 90
        }.count
    }

    private func whiteInk(_ image: CGImage) -> Int {
        guard let data = try? pixels(image) else { return 0 }
        return stride(from: 0, to: data.count, by: 4).filter { index in
            data[index] > 200 && data[index + 1] > 200 && data[index + 2] > 200
        }.count
    }

    private func pixelsDigest(_ image: CGImage) -> Int {
        var hasher = Hasher()
        hasher.combine(image.width)
        hasher.combine(image.height)
        if let data = try? pixels(image) {
            hasher.combine(data)
        }
        return hasher.finalize()
    }
}
