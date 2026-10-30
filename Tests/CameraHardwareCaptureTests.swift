import Foundation
import Testing

struct CameraHardwareCaptureTests {
    @Test func fullPressCapturesOnlyOnceOnRelease() {
        var press = CameraHardwareCapturePress()
        let outcomes = [press.receive(.began, isEnabled: true),
                        press.receive(.ended, isEnabled: true),
                        press.receive(.ended, isEnabled: true)]
        #expect(outcomes == [false, true, false])
    }

    @Test func cancelledAndUnarmedReleasesNeverCapture() {
        var press = CameraHardwareCapturePress()
        let outcomes = [press.receive(.ended, isEnabled: true),
                        press.receive(.began, isEnabled: true),
                        press.receive(.cancelled, isEnabled: true),
                        press.receive(.ended, isEnabled: true)]
        #expect(outcomes == [false, false, false, false])
    }

    @Test func hiddenCameraCannotArmOrFinishAPress() {
        var press = CameraHardwareCapturePress()
        let outcomes = [press.receive(.began, isEnabled: false),
                        press.receive(.ended, isEnabled: true),
                        press.receive(.began, isEnabled: true),
                        press.receive(.ended, isEnabled: false)]
        #expect(outcomes == [false, false, false, false])
    }

    @Test func dismissingAModalCannotResumeAnOldPress() {
        var press = CameraHardwareCapturePress()
        _ = press.receive(.began, isEnabled: true)
        press.reset()
        let outcomes = [press.receive(.ended, isEnabled: true),
                        press.receive(.began, isEnabled: true),
                        press.receive(.ended, isEnabled: true)]
        #expect(outcomes == [false, false, true])
    }

    @Test func idlePreviewKeepsHardwareZoomOnTheExistingCropPath() throws {
        let root = TestRepository.root.appendingPathComponent("App/Modules/CameraCapture")
        let model = try String(contentsOf: root.appendingPathComponent("CameraViewModel.swift"), encoding: .utf8)
        let session = try String(contentsOf: root.appendingPathComponent("CameraSession.swift"), encoding: .utf8)
        #expect(model.contains("usesNativeIdlePreview: usesNativeIdlePreview"))
        #expect(model.contains("photoCropZoom * (zoomSnapshot?.displayMultiplier ?? 1)"))
        #expect(!model.contains("!usesNativeIdlePreview else { return false }"))
        #expect(session.contains("request.usesNativeIdlePreview ? bounds.multiplier * 4"))
    }

    @Test func sliderTeardownAndDragAvoidStaleWriteback() throws {
        let root = TestRepository.root.appendingPathComponent("App/Modules/CameraCapture")
        let controls = try String(contentsOf: root.appendingPathComponent("CameraHardwareControls.swift"), encoding: .utf8)
        let session = try String(contentsOf: root.appendingPathComponent("CameraSession.swift"), encoding: .utf8)
        let model = try String(contentsOf: root.appendingPathComponent("CameraViewModel.swift"), encoding: .utf8)
        #expect(controls.contains("if interaction.allowsProgrammaticWrite,"))
        #expect(session.contains("self.hardwareControlRequest = nil\n            self.hardwareControls.uninstall()"))
        #expect(model.contains("var isRecording = false { didSet { pushCameraHardwareControls() } }"))
    }

    // Source contracts only; physical Camera Control and haptics need an iPhone.
    @Test func hardwareAndTouchShareTheCaptureActions() throws {
        let bar = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraControlBar.swift"), encoding: .utf8)
        #expect(bar.contains(".onCameraCaptureEvent(isEnabled: hardwareCaptureEnabled)"))
        let hasFreshHardwareGate = bar.contains("cameraViewModel.canAcceptHardwareCapture")
        #expect(hasFreshHardwareGate)
        #expect(bar.contains("performPhotoCapture()"))
        #expect(bar.contains("performVideoCapture()"))
        #expect(bar.components(separatedBy: "cameraViewModel.startRecording()").count == 2)
        #expect(bar.components(separatedBy: "cameraViewModel.stopRecording()").count == 2)
        #expect(bar.components(separatedBy: "onPhotoCapture()").count == 2)
    }
}
