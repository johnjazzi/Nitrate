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
}
