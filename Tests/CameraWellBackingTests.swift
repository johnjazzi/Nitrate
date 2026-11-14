import AppKit
import SwiftUI
import Testing

/// The clusters — the stock entry, the status LCD, the exposure column and the
/// mode row — are placed by the shooting bar and the mode strip, so their
/// footprints are fixed. These assertions pin the well as paint only: one
/// shared backing with no resize, seated behind both finishes. Classic and
/// Minimal differ only in the plate's face — Classic keeps its beveled plate,
/// Minimal keeps the borderless charcoal fill on exactly the same geometry.
struct CameraWellBackingTests {
    /// An 88x44 face over a known backdrop, rendered at 1x. Minimal's well is a
    /// charcoal fill, so the red channel is the backdrop mixed with it; Classic's
    /// is a thin material plus its ink wash and rim, so it stays much lighter.
    @MainActor
    private func probe(style: CameraUIStyle, verticalInset: CGFloat = 0,
                       background: Color = .white,
                       x: Int = 44, y: Int = 22) throws -> (red: CGFloat, size: CGSize) {
        let view = Color.clear
            .frame(width: 88, height: 44)
            .cameraWellBacking(verticalInset: verticalInset)
            .background(background)
            .environment(\.cameraUIStyle, style)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let colour = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return (colour.redComponent, CGSize(width: image.width, height: image.height))
    }

    /// Both finishes now seat the clusters in the one shared backing: bare
    /// Classic replicates are gone, so a Classic face must paint the well too.
    /// What still separates the finishes is the face, not the footprint.
    @MainActor
    @Test func bothStylesSeatTheClustersInTheWellAndOnlyClassicCarriesTheBevel() throws {
        let minimal = try probe(style: .minimal)
        let classic = try probe(style: .classic)
        #expect(minimal.size == classic.size, "The backing must not change the face's footprint.")
        #expect(classic.red < 0.95,
                "Classic now paints the shared well; it no longer leaves the clusters bare.")
        #expect(minimal.red < classic.red,
                "Minimal's charcoal fill reads darker than Classic's thin material and rim.")
        #expect(minimal.red < 1, "Minimal seats the cluster in the well.")

        // The bevel is the one drawn difference, and it is authored in the one
        // shared face: Classic paints the inset dark-over-light rim, Minimal's
        // branch paints the flat fill and nothing else. The geometry above is
        // identical, so the bevel is paint, not a second layout.
        let face = try String(contentsOf: TestRepository.url(
            for: "App/Modules/CameraCapture/CameraRaisedButtonStyle.swift"), encoding: .utf8)
        let wellStart = try #require(face.range(of: "struct CameraWellFace: View"))
        let wellEnd = try #require(face.range(of: "/// A plate that groups related controls"))
        let well = String(face[wellStart.lowerBound..<wellEnd.lowerBound])
        let classicBranch = try #require(well.range(of: "if uiStyle == .classic {"))
        let minimalBranch = try #require(well.range(of: "// Charcoal, not black"))
        let bevel = String(well[classicBranch.lowerBound..<minimalBranch.lowerBound])
        #expect(bevel.contains("strokeBorder("),
                "Classic's well keeps its inset rim.")
        #expect(bevel.contains("LinearGradient"),
                "The rim is the dark-over-light gradient, not a flat stroke.")
        #expect(String(well[minimalBranch.lowerBound...]).contains("shape.fill(Color(white: 0.11).opacity(0.62))"),
                "Minimal's branch paints one borderless fill.")
        #expect(!String(well[minimalBranch.lowerBound...]).contains("strokeBorder("),
                "Minimal's well paints no rim at all.")
    }

    @MainActor
    @Test func theWellReadsOverDarkAndBrightFootageAlike() throws {
        let dark = try probe(style: .minimal, background: .black)
        #expect(dark.red > 0.05,
                "A charcoal plate must lighten a dark preview, not vanish into it.")
        let bright = try probe(style: .minimal, background: .white)
        #expect(bright.red < 0.6, "The same plate still darkens a bright preview.")
    }

    @MainActor
    @Test func theMinimalWellIsBorderless() throws {
        let centre = try probe(style: .minimal)
        let edge = try probe(style: .minimal, x: 1)
        #expect(abs(edge.red - centre.red) < 0.02,
                "No rim: the edge carries the same fill as the middle.")
    }

    @MainActor
    @Test func theWellNeverResizesTheFaceItSeats() throws {
        for inset: CGFloat in [0, 4] {
            let minimal = try probe(style: .minimal, verticalInset: inset)
            let classic = try probe(style: .classic, verticalInset: inset)
            #expect(minimal.size == classic.size,
                    "The backing adds no padding, so the seated face keeps its size.")
        }
    }
}
