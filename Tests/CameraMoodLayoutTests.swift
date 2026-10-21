import Foundation
import Testing

/// iOS-only view wiring; native shared-face render coverage lives in CameraDesignRenderTests.
struct CameraMoodLayoutTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func framedPreviewFillsTwoByThreeWithoutChangingCaptureIdentity() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("videoGravity: .resizeAspectFill"))
        #expect(screen.components(separatedBy: "CameraView(viewModel:").count == 2)
        #expect(screen.contains("RecordingTallyLight(isRecording:"))
        #expect(screen.contains(".overlay(alignment: .topTrailing)"))
    }

    @Test func captureAudioAllowsControlHapticsWithoutChangingAudioRouting() throws {
        let app = try source("App/App.swift")
        let ruler = try source("App/Modules/CameraCapture/RulerSlider.swift")
        let bar = try source("App/Modules/CameraCapture/CameraControlBar.swift")
        #expect(app.contains("CameraHaptics.prepareForCaptureFeedback()"))
        #expect(ruler.contains("CameraHaptics.prepareForCaptureFeedback()"))
        #expect(bar.contains("CameraHaptics.prepareForCaptureFeedback()"))
        let haptics = try source("App/Modules/CameraCapture/CameraHaptics.swift")
        #expect(haptics.contains("setAllowHapticsAndSystemSoundsDuringRecording(true)"))
        #expect(!haptics.contains("setCategory("))
        #expect(!haptics.contains("setActive("))
    }

    @Test func focalSwitchCallbacksCannotOverrideAManualChoiceOrResumeAfterTeardown() throws {
        let model = try source("App/Modules/CameraCapture/CameraViewModel.swift")
        #expect(model.contains("preservingFocalZoom: true"))
        #expect(model.contains("if !preservingFocalZoom"))
        #expect(model.contains("self.cameraLensSwitchGeneration == requestGeneration"))
        let gesture = try source("App/Modules/CameraCapture/FocalPinchZoom.swift")
        #expect(gesture.contains("!captureBusy, !interrupted"))
        #expect(gesture.contains("scenePhase == .active"))
        #expect(!gesture.contains("cameraRevision"), "A physical lens switch must not restart a live gesture.")
    }

    @Test func topKeysUseCircularFacesIncludingLensTrigger() throws {
        let screen = try source("App/ContentView.swift")
        let lens = try source("App/Modules/CameraCapture/CameraLensSelector.swift")
        #expect(screen.contains("CameraRoundButtonStyle("))
        #expect(lens.contains("CameraRoundButtonStyle("))
        #expect(lens.contains(".frame(width: 44, height: 44)"))
    }
}
