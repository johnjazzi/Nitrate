import Foundation
import SwiftUI
import Testing

struct CameraDesignTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func recordDesignKeepsPhysicalPressWithoutBurst() throws {
        let bar = try source("App/Modules/CameraCapture/CameraControlBar.swift")
        #expect(bar.contains("RecordPlungerFace("))
        #expect(!bar.contains(".scaleEffect(isUnclicked ? 0.92 : 1)"))
        #expect(!bar.contains(".scaleEffect(isUnclicked ? 1.3 : 0.88)"))
        #expect(bar.contains("RecordButtonTimingPolicy.unclickDelay"))
        #expect(!bar.contains("recordingTimerBadge(presentation)"))
    }

    @Test func recordingActionsAreNotOptimisticallyConfirmed() {
        let policy = RecordButtonPresentationPolicy.self
        #expect(policy.presentation(isRecording: false, isStarting: true, isStopping: false) == .starting)
        #expect(policy.action(for: .starting) == .stop)
        #expect(policy.action(for: .recording) == .stop)
        #expect(policy.action(for: .stopping) == .none)
        #expect(policy.action(for: .idle) == .start)
        #expect(policy.presentation(isRecording: true, isStarting: false, isStopping: true) == .stopping)
        #expect(policy.isEnabled(isSpaceCritical: true, presentation: .starting))
        #expect(policy.isEnabled(isSpaceCritical: true, presentation: .recording))
        #expect(!policy.isEnabled(isSpaceCritical: true, presentation: .idle))
        #expect(policy.accessibilityLabel(for: .starting) == "Cancel starting recording")
    }

    @Test func topLampReadsCaptureState() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("RecordingStatusFace("))
        #expect(screen.contains("RecordingIndicatorStyle.preferenceKey"))
        let settings = try source("App/Modules/Purchase/PurchaseView.swift")
        #expect(settings.contains("Recording Indicator"))
        #expect(settings.contains("RecordingIndicatorStyle.allCases"))
        #expect(screen.contains("isRecording: cameraViewModel.isRecording"))
        #expect(screen.contains("isStarting: cameraViewModel.isStartingRecording"))
        #expect(screen.contains("isStopping: cameraViewModel.isStoppingRecording"))
    }

    @Test func lensUsesSharedStackForTriggerAndKeys() throws {
        let selector = try source("App/Modules/CameraCapture/CameraLensSelector.swift")
        #expect(selector.components(separatedBy: "CameraLensFace(").count == 3)
        #expect(!selector.contains("isLandscape && selectedLens == .front"))
        #expect(!selector.contains("isLandscape && lens == .front"))
        #expect(selector.contains(".accessibilityAddTraits(isSelected ? [.isSelected] : [])"))
    }

    @Test func leftColumnSharesFullExposureHeightAndRealGauge() throws {
        let bar = try source("App/Modules/CameraCapture/CameraControlBar.swift")
        let screen = try source("App/ContentView.swift")
        #expect(bar.contains("CameraShootingLayout()"))
        #expect(bar.contains("CameraGaugeLabel(gauge: selectedGauge,"))
        #expect(screen.contains("selectedGauge: selectedStock.flatMap { library.lastGauge(for: $0.stockId) } ?? .neutral"))
        #expect(bar.components(separatedBy: "length: 120").count == 3)
        #expect(bar.contains("onShowQueueSheet"))
    }
}
