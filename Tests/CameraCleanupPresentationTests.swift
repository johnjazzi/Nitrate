import Foundation
import Testing

/// Wiring regressions for iOS-only views; geometry itself is covered separately.
struct CameraCleanupPresentationTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func timerRotatesCompleteCapsuleWithoutNestedGlyphRotation() throws {
        let file = try source("App/Modules/CameraCapture/CameraControlBar.swift")
        let start = try #require(file.range(of: "private func recordingTimerBadge"))
        let end = try #require(file.range(of: "/// Idle is a white ring", range: start.upperBound..<file.endIndex))
        let badge = String(file[start.lowerBound..<end.lowerBound])
        #expect(!badge.contains(".cameraUpright()"))
        #expect(badge.contains("RecordingTimerBadge("))
    }

    @Test func manualPanelDoesNotParticipateInMeasuredTopBar() throws {
        let file = try source("App/ContentView.swift")
        // The measurement must belong to topBar, before its non-sizing overlay.
        #expect(file.contains("topBar\n                        .background(controlMeasurement(\"top\"))\n                        .overlay(alignment: .top)"))
        #expect(file.contains(".alignmentGuide(.top) { $0[.bottom] }"))
        #expect(file.components(separatedBy: "CameraView(viewModel:").count == 2)
    }

    @Test func detailedStabilizationExplanationIsBehindPanelHelp() throws {
        let file = try source("App/Modules/CameraCapture/ManualControlsPanel.swift")
        #expect(file.contains("DisclosureGroup(\"Stabilization help\")"))
        #expect(file.contains("Recording only · may crop and delay confirmation."))
    }
}
