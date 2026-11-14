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
        // The well the Minimal clusters sit in is one flat fill: no rim, and no
        // padding, so seating a face in it cannot move or resize that face.
        #expect(source.contains("shape.fill(Color.black.opacity(0.32))"),
                "The Minimal well is one flat neutral fill.")
        let backing = try #require(source.components(separatedBy: "struct CameraWellBacking: ViewModifier").last)
        #expect(!backing.contains(".padding(.horizontal") && !backing.contains(".frame("),
                "The backing adds no padding and no size; only the shared fill.")
        #expect(backing.contains("if uiStyle != .classic"),
                "Classic draws nothing behind these faces; its plates own their chrome.")
        // Press state is a fill-opacity change on both faces, not a bevel.
        #expect(source.components(separatedBy: "isPressed ? 0.66 : 0.5").count == 3,
                "Round and rectangular faces darken slightly while pressed.")
        #expect(source.components(separatedBy: "(faceColor ?? .clear).opacity(isPressed ? 0.42 : 0.28)").count == 3,
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
