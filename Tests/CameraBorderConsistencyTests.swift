import Foundation
import Testing

@Suite struct CameraBorderConsistencyTests {
    @Test func selectorWellsUseTheSharedSingleControlBorder() throws {
        let source = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraRaisedButtonStyle.swift"), encoding: .utf8)
        let well = try #require(source.components(separatedBy: "struct CameraControlWell: ViewModifier").last)
            .components(separatedBy: "extension View")[0]
        #expect(source.contains("static let lineWidth: CGFloat = 1"))
        #expect(well.contains("lineWidth: CameraControlBorder.lineWidth"))
        #expect(well.components(separatedBy: ".strokeBorder(").count == 2,
                "One border, not a doubled inner rim")
        #expect(!well.contains("shape.inset(by: 2)"))
        let raised = try #require(source.components(separatedBy: "struct CameraRaisedSurface: ViewModifier").last)
            .components(separatedBy: "struct CameraControlWell")[0]
        #expect(raised.contains("lineWidth: CameraControlBorder.lineWidth"))
    }
}
