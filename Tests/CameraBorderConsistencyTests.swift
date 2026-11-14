import Foundation
import Testing

/// The minimal camera surfaces are flat: one fill, a restrained pressed opacity
/// and the existing padding and hit regions. These assertions pin the convention
/// where the shared styles are defined, so re-adding simulated hardware — a
/// material, a rim gradient, a bevel or a shadow — has to change this contract
/// deliberately.
@Suite struct CameraBorderConsistencyTests {
    @Test func sharedSurfacesStayFlatWithoutMaterialRimOrShadow() throws {
        let source = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraRaisedButtonStyle.swift"), encoding: .utf8)
        let minimalBranches = source.components(separatedBy: "} else {").dropFirst()
            .map { $0.components(separatedBy: "\n        }")[0] }
        #expect(minimalBranches.count == 4,
                "Round, raised, inset and well faces each retain a Minimal branch")
        for branch in minimalBranches {
            for forbidden in ["ultraThinMaterial", "LinearGradient", ".shadow(", "strokeBorder("] {
                #expect(!branch.contains(forbidden), "Minimal surfaces exclude \(forbidden); Classic may retain it")
            }
        }
        // The well the Minimal clusters sit in is one flat charcoal fill: light
        // enough to read on dark footage, and no rim or padding, so seating a
        // face in it cannot move or resize that face.
        #expect(source.contains("shape.fill(Color(white: 0.11).opacity(0.62))"),
                "The Minimal well is one flat charcoal fill, not black on black.")
        // Classic's well is the skeuomorphic plate — material body plus an inset
        // dark-over-light rim — so both finishes seat the same faces, only the
        // finish differs.
        let wellFaceSource = try #require(source.components(separatedBy: "struct CameraWellFace: View").last)
        let wellFace = try #require(wellFaceSource.components(separatedBy: "struct CameraControlWell: ViewModifier").first)
        #expect(wellFace.contains(".ultraThinMaterial"),
                "Classic keeps the translucent plate the well is known for.")
        #expect(wellFace.contains("strokeBorder("),
                "Classic keeps the inset bevel rim around the well.")
        let backing = try #require(source.components(separatedBy: "struct CameraWellBacking: ViewModifier").last)
        #expect(!backing.contains(".frame("),
                "The backing adds no size; only the shared fill.")
        // Both finishes draw the shared plate: the padding and hit-testing
        // exemptions live on the plate, never on the content it sits under.
        #expect(backing.contains("CameraWellFace(cornerRadius: cornerRadius)"),
                "The backing draws the one shared well face in both finishes.")
        #expect(backing.contains(".padding(.vertical, verticalInset)"),
                "Insets belong to the plate, never to the content it sits under.")
        #expect(backing.contains(".allowsHitTesting(false)"),
                "The plate never intercepts the face's hit region.")
        #expect(!backing.contains("uiStyle != .classic"),
                "Classic now shares the well; the finish is resolved inside CameraWellFace.")
        // Press state is a fill-opacity change on both faces, not a bevel.
        // Two authored occurrences (the round face and the rectangular face), so
        // `components` splits into three pieces: the count is one above the
        // number of call sites and must stay that way.
        #expect(source.components(separatedBy: "isPressed ? 0.66 : 0.5").count - 1 == 2,
                "Round and rectangular faces darken slightly while pressed.")
        #expect(source.components(separatedBy: "(faceColor ?? .clear).opacity(isPressed ? 0.42 : 0.28)").count - 1 == 2,
                "A tinted face is a restrained accent cast over the dark fill, not an accent plate.")
    }

    @Test func sharedSurfaceNamesAndLayoutAreRetained() throws {
        let source = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraRaisedButtonStyle.swift"), encoding: .utf8)
        for name in ["struct CameraRoundButtonStyle: ButtonStyle",
                     "struct CameraRaisedButtonStyle: ButtonStyle",
                     "struct CameraRaisedSurface: ViewModifier",
                     "struct CameraInsetSurface: ViewModifier",
                     "struct CameraControlWell: ViewModifier",
                     "func cameraControlWell(",
                     "static let lineWidth: CGFloat = 1"] {
            #expect(source.contains(name), "Callers keep the existing surface API: \(name)")
        }
        let well = try #require(source.components(separatedBy: "struct CameraControlWell: ViewModifier").last)
            .components(separatedBy: "extension View")[0]
        #expect(well.contains(".padding(.horizontal, horizontalPadding)"),
                "The flat well keeps its existing horizontal padding.")
        #expect(well.contains(".padding(.vertical, 5)"),
                "The flat well keeps its existing vertical padding.")
        #expect(well.contains("contentShape(shape)"),
                "The hit region is unchanged by the flat fill.")
        #expect(source.contains("@Environment(\\.accessibilityReduceMotion)"),
                "Press feedback still honours Reduce Motion.")
        // No face pads itself: the 44pt minimum targets come from the callers.
        #expect(!source.contains(".frame("),
                "A surface must not resize or pad its caller's target.")
    }
}
