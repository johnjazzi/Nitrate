import Foundation
import Testing

struct PhotoShutterFloatPolicyTests {
    // The ISO watermark is gone: holding the ISO no longer holds the shutter, so
    // there is no "ISO is extreme enough to justify a float" question left. The
    // floor is the whole policy.

    @Test func floatStopsAtOneEighthOfASecond() {
        // The slow end is 1/8s: AVFoundation would not acknowledge the exposure
        // writes below it, so asking for slower stopped EV and shutter landing.
        let floor = PhotoShutterFloatPolicy.floorSeconds
        #expect(abs(floor - 0.125) < 1e-9)
        #expect(abs(PhotoShutterFloatPolicy.clampedFloat(1.0 / 2.0, current: 1.0 / 48.0) - floor) < 1e-9)
        #expect(abs(PhotoShutterFloatPolicy.clampedFloat(1.0 / 30.0, current: 1.0 / 48.0) - 1.0 / 30.0) < 1e-9)
    }

    @Test func floatLeavesAManualShutterSlowerThanTheFloorAlone() {
        let manual = 1.0 / 4.0
        #expect(abs(PhotoShutterFloatPolicy.clampedFloat(2.0, current: manual) - manual) < 1e-9)
    }
}
