import Foundation
import Testing

/// Semantic coverage for the first-three-launch stock-selector hint. These test
/// behaviour (boundaries, suppression, sustain, resets), not source strings.
@Suite("Stock selector hint policy")
struct StockSelectorHintPolicyTests {

    // MARK: - Classification

    @Test func coolSceneIsHigherKelvinAndWarmSceneIsLowerKelvin() {
        // Reference 5600K (daylight stock) is ~178.6 mired. 13000K sits ~102
        // mired cooler (higher Kelvin, lower mired); 3500K sits ~107 mired warmer.
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: 13000, referenceKelvin: 5600) == .cool)
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: 3500, referenceKelvin: 5600) == .warm)
        // Against a tungsten stock (3200K) the same direction flips with reference.
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: 4800, referenceKelvin: 3200) == .cool)
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: 2300, referenceKelvin: 3200) == .warm)
    }

    @Test func subThresholdSeparationStaysNeutral() {
        // 5600K is ~178.6 mired. Ninety mired either way is a visible-but-modest
        // shift and must stay inside the neutral band; 110 mired is directional.
        let reference = 5600.0
        let referenceMired = 178.57142857142858
        let cool90 = 1_000_000 / (referenceMired - 90)
        let warm90 = 1_000_000 / (referenceMired + 90)
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: cool90, referenceKelvin: reference) == nil)
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: warm90, referenceKelvin: reference) == nil)
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: 1_000_000 / (referenceMired - 110),
                                                 referenceKelvin: reference) == .cool)
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: 1_000_000 / (referenceMired + 110),
                                                 referenceKelvin: reference) == .warm)
    }

    @Test func implausibleAndNeutralEstimatesNeverMismatch() {
        // Non-finite / non-positive estimates are unusable.
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: .nan, referenceKelvin: 5600) == nil)
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: .infinity, referenceKelvin: 5600) == nil)
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: 0, referenceKelvin: 5600) == nil)
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: -5600, referenceKelvin: 5600) == nil)
        // Out-of-range (below the plausible Kelvin floor).
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: 500, referenceKelvin: 5600) == nil)
        // A near-neutral scene sits inside the threshold.
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: 5600, referenceKelvin: 5600) == nil)
        #expect(StockSelectorHintPolicy.mismatch(estimatedKelvin: 6000, referenceKelvin: 5600) == nil)
    }

    @Test func staleEstimateExpiresPromptly() {
        #expect(StockSelectorHintPolicy.freshMismatch(estimatedKelvin: 13000, referenceKelvin: 5600,
                                                      ageSeconds: 0) == .cool)
        #expect(StockSelectorHintPolicy.freshMismatch(estimatedKelvin: 13000, referenceKelvin: 5600,
                                                      ageSeconds: StockSelectorHintPolicy.maximumSampleAge) == .cool)
        #expect(StockSelectorHintPolicy.freshMismatch(estimatedKelvin: 13000, referenceKelvin: 5600,
                                                      ageSeconds: StockSelectorHintPolicy.maximumSampleAge + 0.1) == nil)
        // A future or non-finite age is treated as unusable too.
        #expect(StockSelectorHintPolicy.freshMismatch(estimatedKelvin: 13000, referenceKelvin: 5600,
                                                      ageSeconds: -1) == nil)
        #expect(StockSelectorHintPolicy.freshMismatch(estimatedKelvin: 13000, referenceKelvin: 5600,
                                                      ageSeconds: .nan) == nil)
    }

    @Test func gainsUsabilityRejectsNonFiniteAndOutOfRange() {
        let maxGain = 8.0
        #expect(StockSelectorHintPolicy.gainsAreUsable(red: 1, green: 1.2, blue: 2.5, maximumGain: maxGain))
        #expect(!StockSelectorHintPolicy.gainsAreUsable(red: .nan, green: 1, blue: 1, maximumGain: maxGain))
        #expect(!StockSelectorHintPolicy.gainsAreUsable(red: 1, green: .infinity, blue: 1, maximumGain: maxGain))
        #expect(!StockSelectorHintPolicy.gainsAreUsable(red: 0.5, green: 1, blue: 1, maximumGain: maxGain))
        #expect(!StockSelectorHintPolicy.gainsAreUsable(red: 1, green: 1, blue: maxGain + 0.1, maximumGain: maxGain))
        #expect(!StockSelectorHintPolicy.gainsAreUsable(red: 1, green: 1, blue: 1, maximumGain: 0))
    }

    // MARK: - Active-time crediting

    @Test func backgroundGapCreditsNoActiveTime() {
        // A tick after a paused tick credits nothing, whatever the gap.
        #expect(StockSelectorHintPolicy.creditedElapsed(gapSeconds: 60, wasActive: false) == 0)
        // A long gap while supposedly active is clamped to one tick.
        #expect(StockSelectorHintPolicy.creditedElapsed(gapSeconds: 60, wasActive: true)
                == StockSelectorHintPolicy.maximumTickGap)
        // A normal poll gap is credited as-is.
        #expect(StockSelectorHintPolicy.creditedElapsed(gapSeconds: 0.5, wasActive: true) == 0.5)
        #expect(StockSelectorHintPolicy.creditedElapsed(gapSeconds: .nan, wasActive: true) == 0)
    }

    // MARK: - Launch ledger

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "StockSelectorHintPolicyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CocoaError(.fileReadUnknown)
        }
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test func launchCountIncrementsOncePerProcessAndSaturates() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = StockSelectorHintLaunchTracker(userDefaults: defaults)

        // A fresh install's first process launch is ordinal 1.
        #expect(tracker.beginLaunch() == 1)
        #expect(tracker.recordedLaunchCount == 1)
        // Two more processes: 2 and 3.
        #expect(tracker.beginLaunch() == 2)
        #expect(tracker.beginLaunch() == 3)
        // The fourth open is still recorded but never eligible again.
        #expect(tracker.beginLaunch() == 4)
        #expect(tracker.recordedLaunchCount == 4)
        // Further opens saturate rather than growing without bound.
        #expect(tracker.beginLaunch() == 4)
        #expect(tracker.beginLaunch() == 4)
        #expect(tracker.recordedLaunchCount == 4)
    }

    @Test func eligibilityCoversOnlyTheFirstThreeOpens() {
        #expect(StockSelectorHintLaunchTracker.isEligible(launch: 1))
        #expect(StockSelectorHintLaunchTracker.isEligible(launch: 2))
        #expect(StockSelectorHintLaunchTracker.isEligible(launch: 3))
        #expect(!StockSelectorHintLaunchTracker.isEligible(launch: 4))
        #expect(!StockSelectorHintLaunchTracker.isEligible(launch: 99))
        #expect(!StockSelectorHintLaunchTracker.isEligible(launch: 0))
    }

    @Test func persistenceIsIsolatedBetweenStores() throws {
        let (first, firstSuite) = try isolatedDefaults()
        let (second, secondSuite) = try isolatedDefaults()
        defer {
            first.removePersistentDomain(forName: firstSuite)
            second.removePersistentDomain(forName: secondSuite)
        }
        let firstTracker = StockSelectorHintLaunchTracker(userDefaults: first)
        let secondTracker = StockSelectorHintLaunchTracker(userDefaults: second)

        _ = firstTracker.beginLaunch()
        _ = firstTracker.beginLaunch()
        _ = secondTracker.beginLaunch()

        #expect(firstTracker.recordedLaunchCount == 2)
        #expect(secondTracker.recordedLaunchCount == 1)
        // A new tracker over the same store observes the persisted value: the
        // count survives a process restart.
        #expect(StockSelectorHintLaunchTracker(userDefaults: first).recordedLaunchCount == 2)
    }

    // MARK: - Engine

    private func activeFrame(_ elapsed: TimeInterval = 1,
                             mismatch: StockSelectorHintMismatch? = .cool,
                             opened: Bool = false,
                             eligible: Bool = true) -> StockSelectorHintEngine.Frame {
        StockSelectorHintEngine.Frame(elapsed: elapsed, isActive: true,
                                      isSelectorOpened: opened, isEligibleLaunch: eligible,
                                      mismatch: mismatch)
    }

    private func pausedFrame(opened: Bool = false, eligible: Bool = true) -> StockSelectorHintEngine.Frame {
        StockSelectorHintEngine.Frame(elapsed: 0, isActive: false,
                                      isSelectorOpened: opened, isEligibleLaunch: eligible,
                                      mismatch: nil)
    }

    /// Drive `seconds` of one-second active ticks; return how many times the cue fired.
    private func run(_ engine: inout StockSelectorHintEngine, seconds: Int,
                     mismatch: StockSelectorHintMismatch? = .cool) -> Int {
        var fires = 0
        for _ in 0..<seconds where engine.advance(activeFrame(mismatch: mismatch)) { fires += 1 }
        return fires
    }

    @Test func firesOnceAfterNinetyActiveSecondsAndTenSustained() {
        var engine = StockSelectorHintEngine()
        // 89 active seconds with no usable estimate: no cue, but time accrues.
        #expect(run(&engine, seconds: 89, mismatch: nil) == 0)
        #expect(engine.activeSeconds == 89)
        // The 90th second is not yet enough: the condition must also be sustained.
        #expect(engine.advance(activeFrame(mismatch: .cool)) == false)
        // Eight more sustained cool seconds (nine total): still short of ten.
        #expect(run(&engine, seconds: 8) == 0)
        // The tenth sustained second fires exactly once.
        #expect(engine.advance(activeFrame(mismatch: .cool)) == true)
        // And never again for this launch.
        #expect(run(&engine, seconds: 200) == 0)
    }

    @Test func oneShotRepeatSuppressionHoldsAfterDisplay() {
        var engine = StockSelectorHintEngine()
        _ = run(&engine, seconds: 100)
        #expect(engine.didShowCue)
        // Continuing to stare at the same cool scene never repeats the cue.
        #expect(run(&engine, seconds: 300) == 0)
    }

    @Test func ineligibleLaunchNeverFires() {
        var engine = StockSelectorHintEngine()
        for _ in 0..<500 {
            #expect(engine.advance(activeFrame(eligible: false)) == false)
        }
        #expect(engine.didShowCue == false)
    }

    @Test func openingTheSelectorSuppressesForTheWholeLaunch() {
        var engine = StockSelectorHintEngine()
        // The user finds the control early; after that the cue is skipped forever,
        // even if a strong condition later persists.
        _ = engine.advance(activeFrame(opened: true))
        #expect(engine.didOpenSelector)
        #expect(run(&engine, seconds: 500) == 0)
    }

    @Test func inactiveFramesPauseTheClockAndClearSustain() {
        var engine = StockSelectorHintEngine()
        // Accumulate 85 active, sustained seconds, then background for a long time.
        #expect(run(&engine, seconds: 85) == 0)
        _ = engine.advance(pausedFrame())
        // A long inactive gap contributes no active time.
        for _ in 0..<120 { _ = engine.advance(pausedFrame()) }
        #expect(engine.activeSeconds == 85)
        // The sustained condition was cleared by the pause: nine cool seconds are
        // not enough again.
        #expect(run(&engine, seconds: 9) == 0)
        // One more active second crosses both the 90s and 10s thresholds.
        #expect(run(&engine, seconds: 1) == 1)
    }

    @Test func neutralSceneNeverFires() {
        var engine = StockSelectorHintEngine()
        #expect(run(&engine, seconds: 600, mismatch: nil) == 0)
        #expect(engine.didShowCue == false)
    }

    @Test func missingEstimateClearsASustainedCondition() {
        var engine = StockSelectorHintEngine()
        // Nine sustained cool seconds, then the estimate becomes unusable.
        #expect(run(&engine, seconds: 89, mismatch: nil) == 0)
        #expect(run(&engine, seconds: 9) == 0)
        #expect(engine.advance(activeFrame(mismatch: nil)) == false)
        // The direction must restart: nine more cool seconds do not fire.
        #expect(run(&engine, seconds: 9) == 0)
        #expect(engine.advance(activeFrame(mismatch: .cool)) == true)
    }

    @Test func directionChangeRestartsTheSustainedWindow() {
        var engine = StockSelectorHintEngine()
        #expect(run(&engine, seconds: 95, mismatch: nil) == 0)
        // A flapping scene: nine warm, nine cool, nine warm... never ten in one
        // direction, so no cue.
        #expect(run(&engine, seconds: 9, mismatch: .warm) == 0)
        #expect(run(&engine, seconds: 9, mismatch: .cool) == 0)
        #expect(run(&engine, seconds: 9, mismatch: .warm) == 0)
        // A stable cool scene finally holds for ten.
        #expect(run(&engine, seconds: 10, mismatch: .cool) == 1)
    }

    @Test func stockOrLensChangeResetsSustainButKeepsActiveTime() {
        var engine = StockSelectorHintEngine()
        #expect(run(&engine, seconds: 92, mismatch: nil) == 0)
        #expect(run(&engine, seconds: 9) == 0)
        // The user swaps the stock or lens: the reference moved, so restart.
        engine.resetMismatch()
        #expect(run(&engine, seconds: 9) == 0)
        #expect(engine.advance(activeFrame(mismatch: .cool)) == true)
        // Active time kept accruing across the reset.
        #expect(engine.activeSeconds >= StockSelectorHintPolicy.requiredActiveSeconds)
    }

    @Test func recordingAndTransitionStatesAreJustInactiveFrames() {
        var engine = StockSelectorHintEngine()
        // A take is starting/recording/stopping, or a lens/frame-rate transition
        // is running: the caller passes isActive = false.
        #expect(run(&engine, seconds: 120, mismatch: nil) == 0)
        for _ in 0..<30 { _ = engine.advance(pausedFrame()) }
        #expect(engine.didShowCue == false)
        #expect(engine.activeSeconds == 120)
    }
}
