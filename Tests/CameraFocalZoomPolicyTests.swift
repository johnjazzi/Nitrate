import Foundation
import Testing

@Suite("Focal-length pinch zoom policy and engine")
struct CameraFocalZoomPolicyTests {
    private let allTiers: [CameraFocalZoomLensTier] = [.ultraWide, .wide, .telephoto, .front]

    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func smallBoundaryReversalDoesNotRebuildTheCameraTwice() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        let decision = engine.request(targetMM: 23.9, available: allTiers)
        #expect(decision == .adjust(tier: .wide, targetMM: 23.9),
                "A 0.1 mm reversal must not rebuild the physical camera")
        let next = engine.request(targetMM: 24.05, available: allTiers)
        #expect(next == .adjust(tier: .wide, targetMM: 24.05))
    }

    // MARK: - Ruler landmarks and lens boundaries

    @Test func majorTicksAreTheSharedRulerLandmarks() {
        // The policy owns the landmarks; the UI aliases this array for its ruler.
        #expect(CameraFocalZoomPolicy.majorTicks == [13, 24, 35, 50, 75, 96, 110, 150, 200, 300, 400])
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

    @Test func clampsTargetsToTheThirteenToFourHundredRange() {
        #expect(CameraFocalZoomPolicy.clampedTarget(5) == 13)
        #expect(CameraFocalZoomPolicy.clampedTarget(13) == 13)
        #expect(CameraFocalZoomPolicy.clampedTarget(77) == 77)
        #expect(CameraFocalZoomPolicy.clampedTarget(150) == 150)
        #expect(CameraFocalZoomPolicy.clampedTarget(384) == 384)
        #expect(CameraFocalZoomPolicy.clampedTarget(400) == 400)
        #expect(CameraFocalZoomPolicy.clampedTarget(401) == 400)
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

    @Test func highTargetAndLatestInFlightUpdateSurviveWideToTelephotoSwitch() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: 384, available: allTiers) == .switchLens(to: .telephoto, targetMM: 384))
        #expect(engine.request(targetMM: 400, available: allTiers) == .ignore)
        #expect(engine.pendingTargetMM == 400)
        #expect(engine.switchCommitted(to: .telephoto, available: allTiers)
            == .adjust(tier: .telephoto, targetMM: 400))
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

    // MARK: - Hysteresis: the boundary deadband damps only the switch decision
    //
    // Intentional boundary differences from the pure preference function:
    // `tier(forFocalLength:)` still flips at exactly 24 mm / 96 mm (the UI
    // ruler and the readout window depend on it), while the engine holds the
    // active lens across 24 +/- boundaryHysteresisMM and 96 +/- that band. The
    // tests below pin both contracts so neither drifts into the other.

    @Test func preferenceTierIsUnchangedByTheHysteresisBand() {
        // The pure preference the ruler/report aliases keeps its hard edges.
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 23.9) == .ultraWide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 24) == .wide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 96) == .wide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 96.1) == .telephoto)
    }

    @Test func hysteresisHoldsTheActiveLensInsideTheDeadband() {
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 23.9, currentlyOn: .wide) == .wide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 24.05, currentlyOn: .wide) == .wide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 96.1, currentlyOn: .wide) == .wide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 95.9, currentlyOn: .telephoto) == .telephoto)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 25.0, currentlyOn: .ultraWide) == .ultraWide)
        // Front is never switched away by the policy either.
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 140, currentlyOn: .front) == .front)
    }

    @Test func hysteresisBoundariesAreTheExactBandEdges() {
        let d = CameraFocalZoomPolicy.boundaryHysteresisMM
        #expect(d > 0 && d < (CameraFocalZoomPolicy.wideUpperBoundMM
                              - CameraFocalZoomPolicy.ultraWideUpperBoundMM) / 2,
                "The band must be positive and leave no unreachable dead zone.")
        // Wide holds across [24 - d, 96 + d]; the edges themselves still hold.
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 24 - d, currentlyOn: .wide) == .wide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 24 - d - 0.001, currentlyOn: .wide) == .ultraWide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 96 + d, currentlyOn: .wide) == .wide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 96 + d + 0.001, currentlyOn: .wide) == .telephoto)
        // Ultrawide holds up to 24 + d; telephoto holds down to 96 - d.
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 24 + d, currentlyOn: .ultraWide) == .ultraWide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 24 + d + 0.001, currentlyOn: .ultraWide) == .wide)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 96 - d, currentlyOn: .telephoto) == .telephoto)
        #expect(CameraFocalZoomPolicy.tier(forFocalLength: 96 - d - 0.001, currentlyOn: .telephoto) == .wide)
    }

    @Test func dissipatingDitherAcrossTheBoundaryDoesNotSwitchTheLens() {
        // A whole pinch that only wobbles around 24 mm: no physical switch at all.
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        for mm in [23.9, 24.05, 23.95, 24.1, 23.8, 24.0] {
            #expect(engine.request(targetMM: mm, available: allTiers) == .adjust(tier: .wide, targetMM: mm))
        }
        #expect(!engine.isSwitching)
        #expect(engine.pendingTargetMM == nil)
    }

    @Test func ditherAcrossTwentyFourWhileASwitchIsInFlightDoesNotFlipBack() {
        // Regression: the old engine coalesced 24.05 while the ultrawide switch
        // was in flight and immediately issued an opposite switch back to wide.
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: 15, available: allTiers) == .switchLens(to: .ultraWide, targetMM: 15))
        #expect(engine.request(targetMM: 23.9, available: allTiers) == .ignore)
        #expect(engine.request(targetMM: 24.05, available: allTiers) == .ignore)
        let committed = engine.switchCommitted(to: .ultraWide, available: allTiers)
        #expect(committed == .adjust(tier: .ultraWide, targetMM: 24.05),
                "A 0.15 mm in-flight dither must not flip back to the wide lens")
        #expect(!engine.isSwitching)
    }

    @Test func ditherAcrossNinetySixWhileASwitchIsInFlightDoesNotFlipBack() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: 110, available: allTiers) == .switchLens(to: .telephoto, targetMM: 110))
        #expect(engine.request(targetMM: 95.9, available: allTiers) == .ignore)
        #expect(engine.request(targetMM: 96.05, available: allTiers) == .ignore)
        let committed = engine.switchCommitted(to: .telephoto, available: allTiers)
        #expect(committed == .adjust(tier: .telephoto, targetMM: 96.05),
                "A 0.15 mm in-flight dither across 96 must not flip back to the wide lens")
    }

    @Test func deliberateReversalPastTheBandStillSwitchesPromptly() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: 22.9, available: allTiers) == .switchLens(to: .ultraWide, targetMM: 22.9))
        #expect(engine.activeTier == .wide, "Only a committed switch changes the active tier.")
        var jumped = CameraFocalZoomEngine(activeTier: .wide)
        #expect(jumped.request(targetMM: 97.5, available: allTiers) == .switchLens(to: .telephoto, targetMM: 97.5))
        var down = CameraFocalZoomEngine(activeTier: .telephoto)
        #expect(down.request(targetMM: 94.9, available: allTiers) == .switchLens(to: .wide, targetMM: 94.9))
    }

    @Test func aJumpAcrossTheWholeWideSpanGoesStraightToTheFarLens() {
        // A single jump clears both boundaries and must not be throttled into two
        // switches through the middle lens.
        var up = CameraFocalZoomEngine(activeTier: .ultraWide)
        #expect(up.request(targetMM: 130, available: allTiers) == .switchLens(to: .telephoto, targetMM: 130))
        var down = CameraFocalZoomEngine(activeTier: .telephoto)
        #expect(down.request(targetMM: 13, available: allTiers) == .switchLens(to: .ultraWide, targetMM: 13))
    }

    @Test func aMonotonicSweepSwitchesEachLensExactlyOnce() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        var switches: [CameraFocalZoomLensTier] = []
        func drive(_ mm: Double) {
            if case .switchLens(let to, _) = engine.request(targetMM: mm, available: allTiers) {
                switches.append(to)
                _ = engine.switchCommitted(to: to, available: allTiers)
            }
        }
        // 24 mm -> 150 mm -> 13 mm in 0.5 mm steps.
        var mm = 24.0
        while mm <= 150 { drive(mm); mm += 0.5 }
        while mm >= 13 { drive(mm); mm -= 0.5 }
        #expect(switches == [.telephoto, .wide, .ultraWide])
    }

    @Test func missingHardwareFallsBackWithoutSwitchingOrWideningTheBand() {
        var noTelephoto = CameraFocalZoomEngine(activeTier: .wide)
        #expect(noTelephoto.request(targetMM: 140, available: [.ultraWide, .wide, .front])
            == .adjust(tier: .wide, targetMM: 140))
        #expect(!noTelephoto.isSwitching)

        var noUltraWide = CameraFocalZoomEngine(activeTier: .wide)
        #expect(noUltraWide.request(targetMM: 15, available: [.wide, .front])
            == .adjust(tier: .wide, targetMM: 15))
        #expect(!noUltraWide.isSwitching)

        var noRear = CameraFocalZoomEngine(activeTier: .wide)
        #expect(noRear.request(targetMM: 40, available: [.front]) == .ignore)
        #expect(noRear.request(targetMM: 40, available: []) == .ignore)
        #expect(noRear.pendingTargetMM == nil)
        #expect(!noRear.isSwitching)
    }

    @Test func frontCameraIsIsolatedFromTheBand() {
        var engine = CameraFocalZoomEngine(activeTier: .front)
        for mm in [13.0, 23.9, 24.05, 95.9, 96.05, 150.0] {
            #expect(engine.request(targetMM: mm, available: allTiers) == .adjust(tier: .front, targetMM: mm))
        }
        #expect(!engine.isSwitching)
        #expect(engine.pendingTargetMM == nil)
    }

    @Test func invalidationDropsADitheredPendingTarget() {
        var engine = CameraFocalZoomEngine(activeTier: .wide)
        #expect(engine.request(targetMM: 110, available: allTiers) == .switchLens(to: .telephoto, targetMM: 110))
        #expect(engine.request(targetMM: 96.05, available: allTiers) == .ignore)
        engine.invalidate()
        #expect(engine.pendingTargetMM == nil)
        #expect(!engine.isSwitching)
        #expect(engine.switchCommitted(to: .telephoto, available: allTiers) == .ignore)
        // After re-syncing to the committed lens the band is measured from it.
        engine.syncActiveTier(.telephoto)
        #expect(engine.request(targetMM: 96.05, available: allTiers) == .adjust(tier: .telephoto, targetMM: 96.05))
        #expect(engine.request(targetMM: 94.9, available: allTiers) == .switchLens(to: .wide, targetMM: 94.9))
    }

    // MARK: - Source wiring: raw intent to the engine, clamped readout

    @Test func pinchFeedsRawIntentToTheEngineAndKeepsTheReadoutHonest() throws {
        let gesture = try source("App/Modules/CameraCapture/FocalPinchZoom.swift")
        #expect(gesture.contains("camera.setFocalLengthZoom(requested)"),
                "The engine must receive the raw gesture intent, not the clamped readout.")
        #expect(gesture.contains("millimeters = display"),
                "The visible readout must carry the hardware-clamped value.")
        #expect(!gesture.contains("camera.setFocalLengthZoom(display)"),
                "The clamped readout must never be what the engine resolves or switches on.")
    }

    @Test func normalizerAndEngineShareTheHysteresisAwareTierDecision() throws {
        let model = try source("App/Modules/CameraCapture/CameraViewModel.swift")
        #expect(model.contains("tier(forFocalLength: requested, currentlyOn: activeTier)"),
                "The readout normalizer must use the engine's hysteresis-aware switch decision.")
        #expect(model.contains("let target = CameraFocalZoomPolicy.clampedTarget(millimeters)"),
                "setFocalLengthZoom must hand the engine raw intent, clamped only to the shared pinch window.")
        #expect(!model.contains("focalEngine.request(targetMM: normalized"),
                "The engine must never be fed a device-window-clamped target (it corrupts the coalesced pending target).")
    }
}
