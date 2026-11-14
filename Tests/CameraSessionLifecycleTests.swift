import Foundation
import Testing

struct CameraSessionLifecycleTests {
    /// Test-first regression: the shared idle preview holds Video's real film
    /// shutter, so the preview the operator judges is metered at the duration the
    /// take starts at. The old contract passed Photo's held duration through (nil
    /// when nothing was held), which left the preview on a free continuous-AE
    /// shutter and the take several stops off.
    @Test func automaticIdleHoldsTheModeFilmShutter() {
        for rate in CameraFrameRate.allCases {
            let idle = VideoExposureContract.idle(frameRate: rate, isManualExposure: false,
                manualISO: 400, bias: -1.2)
            let duration: Double? = idle.durationSeconds
            #expect(duration == rate.filmShutterDuration.seconds)
            // 180°: 1/48 at 24 fps, 1/120 at 60, 1/240 at 120.
            #expect(duration == 1.0 / Double(rate.shutterDenominator))
            #expect(idle.lockedISO == nil)
            #expect(idle.exposureBias == -1.2)
        }
    }

    /// Photo's own held duration is not a Video mode fact and must never reach
    /// the Video contract, however it is passed.
    @Test func photoHeldDurationNeverBecomesTheVideoShutter() {
        for rate in CameraFrameRate.allCases {
            for held: Double? in [nil, 1.0 / 250.0, 2.0] {
                let idle = VideoExposureContract.idle(frameRate: rate, isManualExposure: false,
                    manualISO: nil, bias: 0, heldDuration: held)
                #expect(idle.durationSeconds == rate.filmShutterDuration.seconds)
                #expect(idle.durationSeconds != held)
            }
        }
    }

    /// A manual ISO is the operator's hold and rides the same film shutter; an
    /// absent manual ISO stays automatic instead of pinning a bogus zero.
    @Test func manualISOHoldKeepsTheFilmShutterAndStaysOptional() {
        let manual = VideoExposureContract.idle(frameRate: .standard24, isManualExposure: true,
                                                manualISO: 800, bias: -1)
        #expect(manual.durationSeconds == 1.0 / 48.0)
        #expect(manual.lockedISO == 800)

        let automatic = VideoExposureContract.idle(frameRate: .standard24, isManualExposure: true,
                                                   manualISO: nil, bias: -1)
        #expect(automatic.durationSeconds == 1.0 / 48.0)
        #expect(automatic.lockedISO == nil)
    }
}
