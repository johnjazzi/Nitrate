import Foundation
import Testing

struct CameraShootingModeGateTests {
    private func gate(isLifecycleActive: Bool = true, isCameraConfigured: Bool = true,
                      isConfigurationInFlight: Bool = false, isChangingFrameRate: Bool = false,
                      isChangingCaptureProfile: Bool = false, isSwitchingCameraLens: Bool = false,
                      isPhotoCaptureBusy: Bool = false, isStartingRecording: Bool = false,
                      isRecording: Bool = false, isStoppingRecording: Bool = false) -> CameraShootingModeGate {
        CameraShootingModeGate(isLifecycleActive: isLifecycleActive,
                               isCameraConfigured: isCameraConfigured,
                               isConfigurationInFlight: isConfigurationInFlight,
                               isChangingFrameRate: isChangingFrameRate,
                               isChangingCaptureProfile: isChangingCaptureProfile,
                               isSwitchingCameraLens: isSwitchingCameraLens,
                               isPhotoCaptureBusy: isPhotoCaptureBusy,
                               isStartingRecording: isStartingRecording,
                               isRecording: isRecording,
                               isStoppingRecording: isStoppingRecording)
    }

    @Test func aQuietCameraAllowsTheChange() {
        let value = gate()
        #expect(value.isAllowed)
        #expect(value.reason == nil)
    }

    /// Every blocked state names itself: a greyed row with no reason is the bug.
    @Test func everyBlockedStateHasItsOwnReason() {
        let blocked: [CameraShootingModeGate] = [
            gate(isLifecycleActive: false),
            gate(isCameraConfigured: false),
            gate(isConfigurationInFlight: true),
            gate(isStartingRecording: true),
            gate(isRecording: true),
            gate(isStoppingRecording: true),
            gate(isPhotoCaptureBusy: true),
            gate(isChangingFrameRate: true),
            gate(isChangingCaptureProfile: true),
            gate(isSwitchingCameraLens: true)
        ]
        for value in blocked {
            #expect(!value.isAllowed)
            #expect(value.reason?.isEmpty == false)
        }
        #expect(Set(blocked.compactMap(\.reason)).count == blocked.count,
                "two blocked states sharing one message is feedback the operator cannot act on")
    }

    /// A take outranks everything else it could be confused with, because it is the
    /// state the operator can see and stop.
    @Test func aRunningTakeIsNamedRatherThanTheProfileBehindIt() {
        let value = gate(isChangingCaptureProfile: true, isPhotoCaptureBusy: true, isRecording: true)
        #expect(value.reason == "Recording — stop the take to change modes")
    }

    // MARK: - Where the reason is shown

    private func screen() throws -> String {
        try String(contentsOf: TestRepository.url(for: "App/ContentView.swift"), encoding: .utf8)
    }

    /// The reason is an answer to a tap, not a label that sits over the take for
    /// as long as it runs. A running take dims the row for its whole length, so a
    /// standing banner is a permanent complaint the operator cannot act on.
    @Test func theReasonIsATapAnswerRatherThanAStandingLabel() throws {
        let source = try screen()
        #expect(source.contains("if let notice = modeRefusalNotice"))
        #expect(!source.contains("shootingModeBlockedReason ?? modeRefusalNotice"),
                "the blocked gate's reason must not be rendered unconditionally")
        // The dimmed row still takes the tap and answers from the same gate.
        #expect(source.contains("onBlockedSelect: { _ in explainBlockedModeTap() }"))
        #expect(source.contains("cameraViewModel.shootingModeBlockedReason"))
    }

    /// The row reports a refused tap instead of swallowing it.
    @Test func aBlockedRowReportsTheTap() {
        #expect(CameraModeRowTap.outcome(for: .video, enabled: false) == .refused(.video))
        #expect(CameraModeRowTap.outcome(for: .video, enabled: true) == .select(.video))
    }
}
