import Foundation
import Testing

@Suite("Focal-length pinch zoom policy and engine")
struct CameraFocalZoomPolicyTests {
    private let allTiers: [CameraFocalZoomLensTier] = [.ultraWide, .wide, .telephoto, .front]

    // MARK: - Ruler landmarks and lens boundaries

    @Test func majorTicksAreTheSharedRulerLandmarks() {
        #expect(CameraFocalZoomPolicy.majorTicks == [13, 24, 35, 50, 75, 96, 110, 150])
        #expect(CameraFocalZoomPolicy.isMajorTick(96))
        #expect(CameraFocalZoomPolicy.isMajorTick(96.3))
        #expect(!CameraFocalZoomPolicy.isMajorTick(97.5))
        #expect(!CameraFocalZoomPolicy.isMajorTick(.nan))
        #expect(CameraFocalZoomPolicy.nearestMajorTick(to: 34) == 35)
        #expect(CameraFocalZoomPolicy.nearestMajorTick(to: .infinity) == nil)
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

    // MARK: - Display factor conversion (snapshot semantics)

    @Test func nonPerLensDisplayFactorUsesTheWideTwentyFourMillimetreReference() {
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 24, isPerLens: false, tier: .wide) == 1)
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 96, isPerLens: false, tier: .telephoto) == 4)
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 12, isPerLens: false, tier: .ultraWide) == 0.5)
        #expect(CameraFocalZoomPolicy.focalLengthMM(displayFactor: 5, isPerLens: false, tier: .wide) == 120)
        #expect(CameraFocalZoomPolicy.focalLengthMM(displayFactor: 0.5, isPerLens: false, tier: .ultraWide) == 12)
    }

    @Test func perLensDisplayFactorUsesEachLensesOwnBase() {
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 13, isPerLens: true, tier: .ultraWide) == 1)
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 24, isPerLens: true, tier: .wide) == 1)
        #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: 96, isPerLens: true, tier: .telephoto) == 1)
        #expect(CameraFocalZoomPolicy.focalLengthMM(displayFactor: 2, isPerLens: true, tier: .telephoto) == 192)
    }

    @Test func conversionRejectsNonPositiveAndNonFiniteFactors() {
        for invalid: Double in [0, -1, .nan, .infinity] {
            #expect(CameraFocalZoomPolicy.focalLengthMM(displayFactor: invalid, isPerLens: false, tier: .wide) == nil)
            #expect(CameraFocalZoomPolicy.displayFactor(forFocalLengthMM: invalid,
                                                        isPerLens: false, tier: .wide) == nil)
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
