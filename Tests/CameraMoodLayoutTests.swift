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
        #expect(!screen.contains("videoGravity: isPhotoMode ?"))
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

    // Source contracts only: these do not measure physical haptics or hit testing.
    private func controlBarSection(from start: String, to end: String) throws -> String {
        let bar = try source("App/Modules/CameraCapture/CameraControlBar.swift")
        let startRange = try #require(bar.range(of: start))
        let remainder = bar[startRange.upperBound...]
        let endRange = try #require(remainder.range(of: end))
        return String(remainder[..<endRange.lowerBound])
    }

    @Test func photoShutterAcknowledgesTheTapBeforeCallingCapture() throws {
        let photo = try controlBarSection(from: "        if isPhotoMode {", to: "} else if isDevelopMode {")
        let actionStart = try #require(photo.range(of: "Button {"))
        let actionEnd = try #require(photo.range(of: "} label: {"))
        let action = photo[actionStart.upperBound..<actionEnd.lowerBound]
        let statements = action.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        #expect(statements == ["recordFeedback = .start", "recordFeedbackTrigger &+= 1", "onPhotoCapture()"])
        #expect(photo.components(separatedBy: ".sensoryFeedback(").count == 2)
        #expect(photo.contains(".sensoryFeedback(trigger: recordFeedbackTrigger) { _, _ in recordFeedback.sensory }"))
        #expect(!photo.contains("isPhotoCaptureBusy"))
        #expect(!photo.contains(".onChange("))
    }

    @Test func photoShutterPreservesWholeCircleAndNeverDisables() throws {
        let photo = try controlBarSection(from: "        if isPhotoMode {", to: "} else if isDevelopMode {")
        #expect(photo.contains("ZStack {"))
        #expect(photo.contains("PhotoShutterFace()"))
        #expect(photo.contains("Circle().stroke(.white.opacity(0.8), lineWidth: 2).frame(width: 78, height: 78)"))
        #expect(photo.contains(".contentShape(Circle())"))
        #expect(photo.contains(".buttonStyle(.plain)"))
        #expect(photo.contains(".accessibilityLabel(\"Capture RAW photo\")"))
        #expect(photo.contains(".accessibilityValue(photoShutterAccessibilityValue)"))
        #expect(photo.contains(".accessibilityIdentifier(\"photo.shutter\")"))
        #expect(!photo.contains(".disabled("))
        #expect(!photo.contains(".allowsHitTesting(false)"))
        #expect(!photo.contains("\n            .opacity("), "The shutter must never dim.")
        #expect(!photo.contains("animateUnclick()"))
    }

    @Test func captureTapFeedbackReusesVideoWithoutChangingDevelop() throws {
        let feedback = try controlBarSection(from: "private enum RecordFeedback:", to: "/// Committed manual-exposure")
        #expect(feedback.contains("case .start: .impact(weight: .medium, intensity: 1)"))
        #expect(feedback.contains("case .stop: .impact(weight: .heavy, intensity: 1)"))
        let video = try controlBarSection(from: "private var videoRecordButton:", to: "/// The chosen face.")
        let increment = try #require(video.range(of: "recordFeedbackTrigger &+= 1"))
        let start = try #require(video.range(of: "cameraViewModel.startRecording()"))
        let stop = try #require(video.range(of: "cameraViewModel.stopRecording()"))
        #expect(increment.lowerBound < start.lowerBound && increment.lowerBound < stop.lowerBound)
        #expect(video.components(separatedBy: "recordFeedbackTrigger &+= 1").count == 2)
        #expect(video.contains("recordFeedback = action == .start ? .start : .stop"))
        #expect(video.contains("animateUnclick()"))
        #expect(video.contains(".sensoryFeedback(trigger: recordFeedbackTrigger) { _, _ in recordFeedback.sensory }"))
        let develop = try controlBarSection(from: "private var developRenderButton:", to: "private var queueStatus:")
        #expect(develop.contains("onDevelopRender()"))
        #expect(!develop.contains("recordFeedback"))
        #expect(!develop.contains(".sensoryFeedback("))
    }

    @Test func exposureMeterComparesNeutralSceneOffsetAgainstLiveBiasInEveryMode() throws {
        let meter = try controlBarSection(from: "ExposureIndicatorView(", to: "exposureSetting")
        #expect(meter.contains("meteredEV: cameraViewModel.liveExposureTargetOffset,"))
        #expect(meter.contains("targetEV: cameraViewModel.liveExposureBias,"))
        #expect(!meter.contains("isManualExposure ? 0"))
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
