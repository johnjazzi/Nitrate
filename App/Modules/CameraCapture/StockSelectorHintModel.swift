import Foundation
import Observation

/// One push of camera state from the screen to the hint model.
///
/// The estimate fields are `nil` whenever the hint is no longer armed, so the
/// screen stops publishing a fresh `tick` once the cue has fired or the launch is
/// ineligible — the outline never silently keeps recomputing after it is done.
struct StockSelectorHintInputs: Equatable {
    /// True only while the app is active, the camera is ready, and no take,
    /// transition, sheet, fault or warning is blocking.
    var isActive: Bool
    /// True once the stock selector has been opened this launch.
    var isSelectorOpened: Bool
    /// Advances on every exposure poll (0.5s), driving the active-use clock even
    /// while an estimate is temporarily unavailable.
    var tick: UInt64
    /// Latest Gray-World neutral estimate, in Kelvin.
    var estimateKelvin: Float?
    /// When that estimate was read.
    var estimateCapturedAt: Date?
    /// The selected stock's locked reference temperature, in Kelvin.
    var referenceKelvin: Float?
}

/// Per-process owner of the stock-selector discoverability hint.
///
/// Created once by the app, so the launch counter increments exactly once per
/// process — never on a SwiftUI `onAppear`, and never on a foreground transition.
/// It only decides when to raise `isCueVisible` for a single ~3 second outline;
/// it never touches the selected stock, white balance, exposure or recording.
@MainActor
@Observable
final class StockSelectorHintModel {
    /// True for the one brief outline around the whole stock-selector well.
    private(set) var isCueVisible = false
    /// The 1-based launch ordinal recorded for this process.
    let launch: Int
    /// Whether this launch may ever show the hint (opens 1...3).
    let isEligibleLaunch: Bool

    private var engine = StockSelectorHintEngine()
    /// The last inputs, so a tick can credit time using the previous active state.
    private var context = StockSelectorHintInputs(
        isActive: false, isSelectorOpened: false, tick: 0,
        estimateKelvin: nil, estimateCapturedAt: nil, referenceKelvin: nil)
    private var lastTick: Date?
    private var cueGeneration: UInt64 = 0

    init(userDefaults: UserDefaults = .standard) {
        let tracker = StockSelectorHintLaunchTracker(userDefaults: userDefaults)
        self.launch = tracker.beginLaunch()
        self.isEligibleLaunch = StockSelectorHintLaunchTracker.isEligible(launch: launch)
    }

    /// Whether the cue can still fire this launch. The screen uses this to gate
    /// publishing estimate inputs, so nothing is recomputed once it is done.
    var isArmed: Bool {
        isEligibleLaunch && !engine.didShowCue && !engine.didOpenSelector
    }

    /// Advance the hint one tick. `elapsed` is credited only across two
    /// consecutive active ticks, so a background or blocked gap contributes no
    /// camera use.
    func update(_ inputs: StockSelectorHintInputs, now: Date = Date()) {
        let gap = lastTick.map { now.timeIntervalSince($0) } ?? 0
        let elapsed = StockSelectorHintPolicy.creditedElapsed(gapSeconds: gap, wasActive: context.isActive)
        lastTick = now
        context = inputs
        let frame = StockSelectorHintEngine.Frame(
            elapsed: elapsed,
            isActive: inputs.isActive,
            isSelectorOpened: inputs.isSelectorOpened,
            isEligibleLaunch: isEligibleLaunch,
            mismatch: mismatch(for: inputs, at: now))
        if engine.advance(frame) { presentCue() }
    }

    /// A stock or lens change moves the reference the estimate is compared with,
    /// so the sustained window restarts.
    func resetMismatch() {
        engine.resetMismatch()
    }

    private func mismatch(for inputs: StockSelectorHintInputs, at now: Date) -> StockSelectorHintMismatch? {
        guard inputs.isActive,
              let kelvin = inputs.estimateKelvin,
              let capturedAt = inputs.estimateCapturedAt,
              let reference = inputs.referenceKelvin else { return nil }
        return StockSelectorHintPolicy.freshMismatch(
            estimatedKelvin: Double(kelvin),
            referenceKelvin: Double(reference),
            ageSeconds: now.timeIntervalSince(capturedAt))
    }

    /// Show the single, non-repeating outline for its fixed duration.
    private func presentCue() {
        cueGeneration &+= 1
        let generation = cueGeneration
        isCueVisible = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(StockSelectorHintPolicy.cueDuration))
            guard let self, generation == self.cueGeneration else { return }
            self.isCueVisible = false
        }
    }
}
