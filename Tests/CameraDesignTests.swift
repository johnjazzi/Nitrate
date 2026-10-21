import Foundation
import SwiftUI
import Testing

struct CameraDesignTests {
    @Test func daylightRescueUsesAThresholdedCanvasSiblingAndExplicitModal() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("DaylightExposureRescuePolicy.shouldOffer("))
        #expect(screen.contains("DaylightExposureRescueGeometry.buttonRect("))
        #expect(screen.contains("controlBounds[\"exposure\"]"))
        // An in-camera overlay, not a system sheet: no page-level presentation.
        #expect(screen.contains("DaylightExposureRescueOverlay("))
        #expect(!screen.contains(".sheet(isPresented: $showDaylightRescue)"))
        #expect(!screen.contains("presentationDetents([.large])"))
        #expect(screen.contains("cameraViewModel.setDaylight60Enabled(enabled)"))
        // The confirmation is a card with padded actions, not a cramped sheet row.
        let card = try source("App/Modules/CameraCapture/ExposureRescueControl.swift")
        #expect(card.contains("padding(.horizontal, 18)"))
        #expect(card.contains("frame(maxWidth: .infinity, minHeight: 52)"))
        #expect(card.contains("Color.black.opacity(0.55)"),
                "The canvas behind the card must be dimmed, not replaced by an opaque page.")
        #expect(!screen.contains("daylight60UnavailableReason: Daylight60Control"))
        // Below the threshold the armed 60 badge is the idle-only return path.
        #expect(screen.contains("DaylightIdleBadgeGeometry.rect("))
        #expect(screen.contains("!shouldOfferDaylightRescue, recordPresentation == .idle,"))
        #expect(screen.contains("cameraViewModel.sessionFrameRate == .daylight60,"))
    }

    private func source(_ path: String) throws -> String {
        let root = TestRepository.root
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
        #expect(screen.contains("RecordingStatusOverlay(viewport: geometry.size"))
        #expect(screen.contains("CameraTopPanel(statusInToolbar: abs(statusRotationDegrees) != 90)"))
        #expect(screen.contains("CameraTopPanelGeometry.framingBottom(toolbarBottom: top.maxY"))
        #expect(screen.contains("excluding: RecordingStatusOverlayGeometry.rect("))
        #expect(screen.contains("RecordingIndicatorStyle.preferenceKey"))
        let settings = try source("App/Modules/Purchase/PurchaseView.swift")
        #expect(settings.contains("Recording Indicator"))
        #expect(settings.contains("RecordingIndicatorStyle.allCases"))
        #expect(screen.contains("isRecording: cameraViewModel.isRecording"))
        #expect(screen.contains("isStarting: cameraViewModel.isStartingRecording"))
        #expect(screen.contains("isStopping: cameraViewModel.isStoppingRecording"))
    }

    @Test func lensUsesRoundTriggerAndReadableSharedPopoutKeys() throws {
        let selector = try source("App/Modules/CameraCapture/CameraLensSelector.swift")
        #expect(selector.components(separatedBy: "CameraLensFace(").count == 2)
        #expect(selector.contains("CameraRoundButtonStyle()"))
        #expect(selector.contains(".frame(width: 44, height: 44)"))
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
