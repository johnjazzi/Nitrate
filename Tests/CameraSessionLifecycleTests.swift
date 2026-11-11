import Foundation
import Testing

struct CameraSessionLifecycleTests {
    /// Test-first regression: the original idle contract injected 1/48 or 1/120
    /// on Photo -> Video even though the operator never held a shutter.
    @Test func automaticIdleDoesNotAcquireARecordingShutter() {
        for rate in CameraFrameRate.allCases {
            let idle = VideoExposureContract.idle(frameRate: rate, isManualExposure: false,
                manualISO: 400, bias: -1.2)
            let duration: Double? = idle.durationSeconds
            #expect(duration == nil)
            #expect(idle.lockedISO == nil)
            #expect(idle.exposureBias == -1.2)
        }
    }
}
