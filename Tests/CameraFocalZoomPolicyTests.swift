import Foundation
import Testing

@Suite("Focal-length pinch zoom policy and engine")
struct CameraFocalZoomPolicyTests {
    private let allTiers: [CameraFocalZoomLensTier] = [.ultraWide, .wide, .telephoto, .front]

    // MARK: - Ruler landmarks and lens boundaries

    @Test func majorTicksAreTheSharedRulerLandmarks() {
        // The policy owns the landmarks; the UI aliases this array for its ruler.
        #expect(CameraFocalZoomPolicy.majorTicks == [13, 24, 35, 50, 75, 96, 110, 150])
    }

    @Test func lensTierSwitchesAtTwentyFourAndNinetySix() {
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 13) == .ultraWide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 23.9) == .ultraWide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 24) == .wide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 96) == .wide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 96.1) == .telephoto)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 150) == .telephoto)
    }

    // MARK: - Clamping and non-finite input

    @Test func clampsTargetsToTheThirteenToHundredFiftyRange() {
        #expect(CameraFocalZoomPolicy.clampedTarget(5) == 13)
        #expect(CameraFocalZoomPolicy.clampedTarget(13) == 13)
        #expect(CameraFocalZoomPolicy.clampedTarget(77) == 77)
        #expect(CameraFocalZoomPolicy.clampedTarget(150) == 150)
        #expect(CameraFocalZoomPolicy.clampedTarget(400) == 150)
    }

    @Test func rejectsNonFiniteTargets() {
        for invalid: Double in [.nan, .infinity, -.infinity] {
            #expect(CameraFocalZoomPolicy.clampedTarget(invalid) == nil)
        }
    }

    // MARK: - Display factor conversion (real device multiplier)

    @Test func ultraWideHalfFactorIsThirteenMillimetresNotTwelve() {
        // The ultrawide's own 0.5x is its native 13 mm, not 0.5 * 24 = 12 mm.
        #expect(CameraFocalZoomPolicy.focalLengthMM(displayFactor: 0.5, multiplier: 0.5, tier: .ultraWide) == 13)
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 13, multiplier: 0.5, tier: .ultraWide) == 0.5)
    }

    @Test func nativeTelephotoFactorFourIsNinetySixMillimetres() {
        #expect(CameraFocalZoomPolicy.focalLengthMM(displayFactor: 4, multiplier: 4, tier: .telephoto) == 96)
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 96, multiplier: 4, tier: .telephoto) == 4)
    }

    @Test func wideAnchorUsesTheWideNativeBaseAndItsMultiplier() {
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 24, multiplier: 1, tier: .wide) == 1)
        #expect(CameraFocalZoomPolicy.focalLengthMM(displayFactor: 5, multiplier: 1, tier: .wide) == 120)
    }

    @Test func perLensMultiplierOfOneUsesEachLensesOwnBase() {
        // iOS 17 (`isPerLens == true`) publishes multiplier 1, so the factor is
        // the device's own 1x for each lens.
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 13, multiplier: 1, tier: .ultraWide) == 1)
        #expect(CameraFocalZoomPolicy.focalLengthMM(displayFactor: 1, multiplier: 1, tier: .telephoto) == 96)
    }

    @Test func conversionRoundTripsFractionalFocalLengths() {
        let cases: [(Double, Double, CameraFocalZoomLensTier)] = [
            (37.5, 1.3, .wide), (13.0, 0.5, .ultraWide), (145.5, 4.0, .telephoto)
        ]
        for (millimeters, multiplier, tier) in cases {
            let factor = CameraFocalZoomPolicy.displayFactor(
                forFocalLengthMM: millimeters, multiplier: multiplier, tier: tier)
            #expect(factor != nil)
            let roundTripped = factor.flatMap {
                CameraFocalZoomPolicy.focalLengthMM(displayFactor: $0, multiplier: multiplier, tier: tier)
            }
            #expect(roundTripped.map { abs($0 - millimeters) < 1e-9 } == true)
        }
    }

    @Test func conversionRejectsNonPositiveOrNonFiniteInputs() {
        for invalid: Double in [0, -1, .nan, .infinity] {
            #expect(CameraFocalZoomPolicy.focalLengthMM(
                displayFactor: invalid, multiplier: 1, tier: .wide) == nil)
            #expect(CameraFocalZoomPolicy.displayFactor(
                forFocalLengthMM: invalid, multiplier: 1, tier: .wide) == nil)
            // A bad or non-finite device multiplier must refuse, not mis-convert.
            #expect(CameraFocalZoomPolicy.focalLengthMM(
                displayFactor: 1, multiplier: invalid, tier: .wide) == nil)
            #expect(CameraFocalZoomPolicy.displayFactor(
                forFocalLengthMM: 24, multiplier: invalid, tier: .wide) == nil)
        }
    }

    // MARK: - Availability fallbacks and the front camera

    @Test func missingPreferredLensFallsBackToTheNearestRearLens() {
        #expect(CameraFocalZoomPolicy.resolvedTier(.ultraWide, available: [.wide]) == .wide)
        #expect(CameraFocalZoomPolicy.resolvedTier(.telephoto, available: [.wide]) == .wide)
        #expect(CameraFocalZoomPolicy.resolvedTier(.wide, available: [.wide]) == .wide)
        #expect(CameraFocalZoomPolicy.resolvedTier(.ultraWide,
                                                  available: [.ultraWide, .wide, .front]) == .ultraWide)
        #expect(CameraFocalZoomPolicy.resolvedTier(.telephoto,
                                                  available: [.ultraWide, .wide, .front]) == .wide)
        #expect(CameraFocalZoomPolicy.resolvedTier(.wide, available: [.telephoto, .front]) == .telephoto)
        #expect(CameraFocalZoomPolicy.resolvedTier(.wide, available: [.front]) == nil)
        #expect(CameraFocalZoomPolicy.resolvedTier(.wide, available: []) == nil)
    }

    @Test func frontCameraStaysFrontRegardlessOfTarget() {
        var engine = CameraFocalZoomEngine(activeTier: .front)
        #expect(engine.request(targetMM: 140, available: allTiers) == .adjust(tier: .front, targetMM: 140))
        #expect(engine.request(targetMM: 13, available: allTiers) == .adjust(tier: .front, targetMM: 13))
        #expect(!engine.isSwitching)
        #expect(engine.pendingTargetMM == nil)
    }

    // MARK: - Engine: within-lens adjust and switching

    @Test func requestInsideTheActiveLensAdjustsWithoutSwitching() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        let decision = engine.request(targetMM: 50, available: allTiers)
        #expect(decision == .adjust(tier: .wide, targetMM: 50))
        #expect(!engine.isSwitching)
        #expect(engine.pendingTargetMM == nil)
    }

    @Test func crossingAboveNinetySixStartsATelephotoSwitch() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        let decision = engine.request(targetMM: 110, available: allTiers)
        #expect(decision == .switchLens(to: .telephoto, targetMM: 110))
        #expect(engine.isSwitching)
        #expect(engine.pendingTargetMM == 110)
    }

    @Test func crossingBelowTwentyFourFromWideStartsAnUltrawideSwitch() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        let decision = engine.request(targetMM: 15, available: allTiers)
        #expect(decision == .switchLens(to: .ultraWide, targetMM: 15))
        #expect(engine.isSwitching)
    }

    @Test func missingTelephotoClampsToWideInsteadOfSwitching() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        let decision = engine.request(targetMM: 140, available: [.ultraWide, .wide, .front])
        #expect(decision == .adjust(tier: .wide, targetMM: 140))
        #expect(!engine.isSwitching)

        var ultrawideOnly = CameraFocalZoomEngine(activeTier: .wide)
        #expect(ultrawideOnly.request(targetMM: 15, available: [.wide, .front])
            == .adjust(tier: .wide, targetMM: 15))
    }

    @Test func engineWithNoRearLensIgnoresRequests() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: 50, available: [.front]) == .ignore)
        #expect(engine.request(targetMM: 50, available: []) == .ignore)
        #expect(!engine.isSwitching)
    }

    // MARK: - Engine: latest-target lifecycle

    @Test func nonFiniteRequestIsIgnoredByTheEngine() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: .nan, available: allTiers) == .ignore)
        #expect(engine.request(targetMM: .infinity, available: allTiers) == .ignore)
        #expect(engine.pendingTargetMM == nil)
        #expect(!engine.isSwitching)
    }

    @Test func absoluteFocalLengthIsPreservedAcrossASwitch() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: 110, available: allTiers) == .switchLens(to: .telephoto, targetMM: 110))
        #expect(engine.switchCommitted(to: .telephoto, available: allTiers)
            == .adjust(tier: .telephoto, targetMM: 110))
        #expect(engine.activeTier == .telephoto)
    }

    @Test func targetsCoalesceWhileSwitchingAndTheLatestAppliesOnCommit() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: 110, available: allTiers) == .switchLens(to: .telephoto, targetMM: 110))
        // The pinch keeps moving while the switch is in flight: updates are held, not dropped.
        #expect(engine.request(targetMM: 130, available: allTiers) == .ignore)
        #expect(engine.request(targetMM: 120, available: allTiers) == .ignore)
        #expect(engine.pendingTargetMM == 120)
        #expect(engine.switchCommitted(to: .telephoto, available: allTiers)
            == .adjust(tier: .telephoto, targetMM: 120))
        #expect(!engine.isSwitching)
        #expect(engine.pendingTargetMM == nil)
    }

    @Test func aCoalescedTargetThatCrossedBackIssuesTheOppositeSwitch() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: 110, available: allTiers) == .switchLens(to: .telephoto, targetMM: 110))
        #expect(engine.request(targetMM: 40, available: allTiers) == .ignore)
        let back = engine.switchCommitted(to: .telephoto, available: allTiers)
        #expect(back == .switchLens(to: .wide, targetMM: 40))
        #expect(engine.isSwitching)
        #expect(engine.pendingTargetMM == 40)
    }

    @Test func staleGestureCannotReplayAfterInvalidate() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: 110, available: allTiers) == .switchLens(to: .telephoto, targetMM: 110))
        #expect(engine.request(targetMM: 130, available: allTiers) == .ignore)
        engine.invalidate()
        #expect(engine.pendingTargetMM == nil)
        #expect(!engine.isSwitching)
        #expect(engine.switchCommitted(to: .telephoto, available: allTiers) == .ignore)
    }

    @Test func syncingACommittedLensDropsAnyQueuedGesture() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: 110, available: allTiers) == .switchLens(to: .telephoto, targetMM: 110))
        engine.syncActiveTier(.ultraWide)
        #expect(engine.activeTier == .ultraWide)
        #expect(engine.pendingTargetMM == nil)
        #expect(!engine.isSwitching)
    }
}
