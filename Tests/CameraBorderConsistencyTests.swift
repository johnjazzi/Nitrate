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
        #expect(!source.contains("ultraThinMaterial"),
                "A flat face cannot blur the preview behind it.")
        #expect(!source.contains("LinearGradient"),
                "No rim or bevel gradients.")
        #expect(!source.contains(".shadow("),
                "No simulated depth on the flat faces.")
        #expect(!source.contains("strokeBorder("),
                "Shared surfaces draw no border; the REC ring owns the one hairline.")
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
