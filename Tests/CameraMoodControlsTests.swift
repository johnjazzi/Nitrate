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

    @Test func lcdSlotSitsAboveTheStockWellAndClearOfRecord() {
        for screenWidth in screenWidths {
            for height in barHeights {
                let width = screenWidth - 32
                let geometry = CameraControlGeometry(width: width, height: height)
                // Exposure still owns the shared height.
                #expect(geometry.exposure.height == height)
                // LCD is the upper slot; the stock/gauge well takes the lower third.
                #expect(geometry.lcd.minY == 0)
                #expect(abs(geometry.stock.maxY - height) < 0.001)
                #expect(abs(geometry.lcd.height - 2 * geometry.stock.height) < 0.001)
                #expect(abs(geometry.stock.minY - geometry.lcd.maxY - CameraControlGeometry.columnGap) < 0.001)
                // The well must still host the 44pt stock control plus its frame.
                #expect(geometry.stock.height >= 52)
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

    @Test func barOwnsTheWellRecordingStateAndTheLockHapticOnce() throws {
        let bar = try String(contentsOf: TestRepository.url(for: "App/Modules/CameraCapture/CameraControlBar.swift"),
                             encoding: .utf8)
        #expect(bar.contains("CameraShootingLayout()"))
        // Stock and gauge share one recessed well.
        #expect(bar.contains(".cameraControlWell("))
        #expect(bar.contains("CameraGaugeLabel(gauge: selectedGauge,"))
        #expect(bar.components(separatedBy: "length: 120").count == 3, "The exposure rulers are untouched.")
        // The LCD learns about a take from the committed presentation only.
        #expect(bar.contains("isRecording: recordPresentation == .recording"))
        #expect(bar.contains("isStopping: cameraViewModel.isStoppingRecording"))
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

    private func lcdFrame(_ lcd: RecordingTimeLCD, slot: CGSize) -> some View {
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
