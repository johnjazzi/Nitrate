import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Native proof of the modern face's states and its optimistic contract.
///
/// Idle is a black disc with red ink and no stop symbol. A pending start paints
/// the same live face as a confirmed take — the disc fills red with a bright
/// white stop square — so the control answers the tap immediately rather than
/// looking dead for the roughly two seconds capture takes to confirm. Finalizing
/// keeps the square but dims it, matching the classic face's busy treatment.
/// Every state keeps the classic 84pt footprint, so switching appearance cannot
/// shift layout.
@MainActor
struct RecordButtonAppearanceRenderTests {
    private let states: [RecordButtonPresentation] = [.idle, .starting, .recording, .stopping]

    @Test func everyStateKeepsTheClassicFootprint() throws {
        for state in states {
            let image = try render(face(state), name: "modern-footprint-\(state)")
            #expect(image.width == 200 && image.height == 200,
                    "An 84pt face with 8pt padding at 2x is 200pt; the modern face cannot resize the button.")
        }
    }

    @Test func idleIsBlackWithRedInkAndNoStopSymbol() throws {
        let data = try pixels(try render(face(.idle), name: "modern-idle"))
        #expect(blackInk(data) > 2_000, "The idle disc must be black.")
        #expect(redInk(data) > 150, "The idle rim and REC mark must be red.")
        #expect(brightWhite(data) < 120, "Idle must not show a stop square.")
        #expect(data[3] == 0, "The face must stay circular, with no rectangular bezel.")
    }

    @Test func aPendingStartPaintsTheSameLiveFaceAsAConfirmedTake() throws {
        // The tap must read as live at once: while capture is still spinning up
        // the face is already the red recording face, so the control never looks
        // dead during the roughly two seconds before the writer confirms.
        let starting = try pixels(try render(face(.starting), name: "modern-starting"))
        let recording = try pixels(try render(face(.recording), name: "modern-recording"))
        let stopping = try pixels(try render(face(.stopping), name: "modern-stopping"))
        #expect(redInk(starting) > 5_000, "A pending start must fill the disc red, like a live take.")
        #expect(brightWhite(starting) > 200, "A pending start must show the bright stop square.")
        #expect(starting == recording, "A pending start must paint the live recording face.")
        #expect(brightWhite(starting) > brightWhite(stopping),
                "A pending start must not be dimmed the way finalizing is.")
    }

    @Test func aConfirmedTakeIsRedWithABrightWhiteStopSquare() throws {
        let data = try pixels(try render(face(.recording), name: "modern-recording"))
        #expect(redInk(data) > 5_000, "A confirmed take must fill the disc red.")
        #expect(brightWhite(data) > 200, "A confirmed take must show a bright white stop square.")
    }

    @Test func finalizingKeepsTheStopSquareButDimsItAsBusy() throws {
        let stopping = try pixels(try render(face(.stopping), name: "modern-stopping"))
        let recording = try pixels(try render(face(.recording), name: "modern-recording"))
        #expect(brightWhite(stopping) > 60, "Finalizing still shows the stop square.")
        #expect(brightWhite(stopping) < brightWhite(recording),
                "Finalizing reads as busy: dimmer than a live take, as the classic face dims its stop square.")
    }

    // MARK: - Helpers

    private func face(_ presentation: RecordButtonPresentation) -> some View {
        ModernRecordButtonFace(presentation: presentation, rotationDegrees: 0)
            .padding(8)
    }

    private func redInk(_ data: [UInt8]) -> Int {
        stride(from: 0, to: data.count, by: 4).filter {
            Int(data[$0]) > Int(data[$0 + 1]) + 40 && data[$0] > 90
        }.count
    }

    private func blackInk(_ data: [UInt8]) -> Int {
        stride(from: 0, to: data.count, by: 4).filter {
            data[$0 + 3] > 200 && data[$0] < 40 && data[$0 + 1] < 40 && data[$0 + 2] < 40
        }.count
    }

    /// Brightest achromatic value in the image. Drives the stop-square proof so
    /// a dimmed (busy) square and a full-brightness square are distinguishable.
    private func brightWhite(_ data: [UInt8]) -> Int {
        var best = 0
        var index = 0
        while index + 2 < data.count {
            let low = min(Int(data[index]), min(Int(data[index + 1]), Int(data[index + 2])))
            if low > best { best = low }
            index += 4
        }
        return best
    }

    private func render(_ view: some View, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = TestRepository.artifactDirectory("record-button-appearance-renders")
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
}
