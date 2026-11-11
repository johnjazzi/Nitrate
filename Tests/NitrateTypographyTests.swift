import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Proves the app's global typography is real: the bundled Barlow Semi
/// Condensed Medium face ships with its license, registers under its exact
/// PostScript name, and paints readable text at the app's real point sizes.
@MainActor
struct NitrateTypographyTests {
    private let fontRelativePath = "App/Resources/Fonts/Barlow-Medium.ttf"
    private let licenseRelativePath = "App/Resources/Fonts/barlow-OFL.txt"

    private var fontURL: URL { TestRepository.url(for: fontRelativePath) }

    private final class FontBundleToken {}

    // MARK: - Resource contract

    @Test func bundledFaceShipsWithItsLicense() throws {
        let font = try Data(contentsOf: fontURL)
        #expect(!font.isEmpty, "The bundled face must be a non-empty file.")
        let license = try String(contentsOf: TestRepository.url(for: licenseRelativePath), encoding: .utf8)
        #expect(license.contains("SIL OPEN Font License") || license.contains("SIL Open Font License"),
                "The face must ship with its SIL Open Font License text.")
        #expect(license.contains("Barlow") || license.contains("Copyright"),
                "The license text must attribute the font.")
    }

    // MARK: - Registration

    /// The core proof: after registering the shipped file, CoreText resolves the
    /// exact PostScript name the helper uses — so `Font.custom(_:)` never falls
    /// back to a system face.
    @Test func bundledFaceRegistersUnderItsPostScriptName() throws {
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
        let font = CTFontCreateWithName(NitrateTypography.postScriptName as CFString, 12, nil)
        let resolved = CTFontCopyPostScriptName(font) as String
        #expect(resolved == NitrateTypography.postScriptName,
                "CoreText must resolve Barlow-Medium, not a fallback face.")
        #expect((CTFontCopyFamilyName(font) as String).contains("Barlow"),
                "The resolved family must be the semi-condensed Barlow family.")
    }

    @Test func helperRegistrationIsIdempotent() {
        let first = NitrateTypography.registerBundledFont()
        let second = NitrateTypography.registerBundledFont()
        #expect(first == second, "Registration must be a no-op after the first success.")
        if NitrateTypography.bundledFontURL(in: [Bundle(for: FontBundleToken.self)]) != nil {
            #expect(first, "A bundle that carries the face must register successfully.")
        }
    }

    // MARK: - Helper API

    @Test func everyTextStyleHasAPositiveBaseSize() {
        let styles: [Font.TextStyle] = [.largeTitle, .title, .title2, .title3, .headline,
                                        .subheadline, .body, .callout, .footnote, .caption, .caption2]
        for style in styles {
            #expect(NitrateTypography.baseSize(for: style) > 0,
                    "Every Dynamic Type style needs a base size for the custom face.")
        }
        // The style ladder must stay ordered after the family swap.
        #expect(NitrateTypography.baseSize(for: .caption2) < NitrateTypography.baseSize(for: .caption))
        #expect(NitrateTypography.baseSize(for: .caption) < NitrateTypography.baseSize(for: .body))
        #expect(NitrateTypography.baseSize(for: .body) < NitrateTypography.baseSize(for: .title))
    }

    // MARK: - Native render

    /// At the app's real readout sizes the bundled face must actually paint
    /// characters — never an empty or missing-glyph run.
    @MainActor @Test func readoutsPaintCharactersAtTheirRealSizes() throws {
        for (size, text) in [(8.0, "00:00.00"), (12.0, "REC"), (46.0, "COMPUTER MALFUNCTION")] {
            let view = Text(text)
                .font(NitrateTypography.font(size: size))
                .foregroundStyle(.white)
                .fixedSize()
                .padding(4)
                .background(.black)
            let image = try render(view, name: "readout-\(Int(size))")
            let data = try pixels(image)
            let lit = stride(from: 0, to: data.count, by: 4).filter { data[$0] > 180 }.count
            #expect(lit > 40, "\(text) at \(size)pt must render visible characters.")
        }
    }

    // MARK: - Source contract

    /// The migration is complete: no app text is built from a system font
    /// constructor any more, and no `.rounded`/`.monospaced` font family remains
    /// for text. The two settings files are owned elsewhere and excluded.
    @Test func noSystemFontFamiliesRemainInAppText() throws {
        let appRoot = TestRepository.url(for: "App")
        let owned: [String] = []
        let enumerator = try #require(FileManager.default.enumerator(
            at: appRoot, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" && !owned.contains(url.lastPathComponent) {
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(!source.contains(".font(.system("),
                    "\(url.lastPathComponent) still builds text from a system font.")
            #expect(!source.contains("design: .monospaced"),
                    "\(url.lastPathComponent) still requests a monospaced font family.")
            #expect(!source.contains("design: .rounded"),
                    "\(url.lastPathComponent) still requests a rounded font family.")
        }
    }

    // MARK: - Render helpers

    @MainActor
    private func render(_ view: some View, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let directory = TestRepository.artifactDirectory("nitrate-typography-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
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
