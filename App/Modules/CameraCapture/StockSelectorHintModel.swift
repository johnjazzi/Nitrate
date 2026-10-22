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
#if DEBUG
    /// True while the DEBUG "Preview stock outline" cue is the one on screen. It
    /// borrows the same ~3 s outline but is not the automatic cue: it never
    /// advances the engine, never consumes the launch limit, and never changes
    /// the stored launch count.
    private(set) var isDebugPreviewing = false
    /// Token for the in-flight preview, so a stale timer cannot hide a newer one.
    private var previewGeneration: UInt64 = 0
#endif

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
        if !inputs.isActive {
            // A genuine blocking state ends any cue at once, preview included.
            endCue()
        } else if inputs.isSelectorOpened, !isDebugPreviewingActive {
            // An open selector suppresses the automatic cue. A latched historical
            // open must not clear an explicitly requested DEBUG preview, whose
            // own sheet dismissal already guards a real open through `isActive`.
            endCue()
        }
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
#if DEBUG
        // An automatic cue supersedes a DEBUG preview; invalidate the preview's
        // token so its timer cannot later cut this replacement short.
        previewGeneration &+= 1
        isDebugPreviewing = false
#endif
        let generation = cueGeneration
        isCueVisible = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(StockSelectorHintPolicy.cueDuration))
            guard let self, generation == self.cueGeneration else { return }
            self.isCueVisible = false
        }
    }

    /// Clear any visible cue and invalidate its timer. In DEBUG it also ends the
    /// preview and retires its token, so a superseded preview timer is a no-op.
    private func endCue() {
        cueGeneration &+= 1
#if DEBUG
        previewGeneration &+= 1
        isDebugPreviewing = false
#endif
        isCueVisible = false
    }

    /// True while a DEBUG preview cue is on screen. Always false in release, so
    /// the selector-open suppression in `update` is unchanged for the automatic
    /// hint.
    private var isDebugPreviewingActive: Bool {
#if DEBUG
        isDebugPreviewing
#else
        false
#endif
    }
}

#if DEBUG
extension StockSelectorHintModel {
    /// Outline the whole stock/gauge well once for the fixed cue duration, like
    /// the automatic hint but with none of its conditions. It bypasses the
    /// active-time clock, the three-open launch limit and the selector history,
    /// and it leaves the automatic engine, the stored launch count, white
    /// balance, exposure and the selected stock untouched. Only a genuine
    /// blocking state (`update`) or a newer cue ends it early.
    @discardableResult
    func beginDebugPreview() -> UInt64 {
        cueGeneration &+= 1
        previewGeneration &+= 1
        let token = previewGeneration
        isDebugPreviewing = true
        isCueVisible = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(StockSelectorHintPolicy.cueDuration))
            self?.endDebugPreview(token: token)
        }
        return token
    }

    /// Hide a preview only if `token` is still the current one, so a superseded
    /// timer cannot cut a newer preview short.
    func endDebugPreview(token: UInt64) {
        guard isDebugPreviewing, token == previewGeneration else { return }
        endCue()
    }

    /// Read-only decision snapshot for the DEBUG sheet. Captured live when the
    /// sheet opens, then shown frozen. Takes the estimate and stock reference the
    /// caller read at the same moment so nothing is re-read inside the model.
    func debugDiagnostics(estimatedKelvin: Float?, estimateCapturedAt: Date?,
                          referenceKelvin: Float?, now: Date = Date()) -> StockSelectorHintDiagnostics {
        var mismatch: StockSelectorHintMismatch?
        if let kelvin = estimatedKelvin, let reference = referenceKelvin, let capturedAt = estimateCapturedAt {
            mismatch = StockSelectorHintPolicy.freshMismatch(
                estimatedKelvin: Double(kelvin),
                referenceKelvin: Double(reference),
                ageSeconds: now.timeIntervalSince(capturedAt))
        }
        return StockSelectorHintDiagnostics(
            launchOrdinal: launch,
            launchLimit: StockSelectorHintLaunchTracker.maximumEligibleLaunch,
            isEligibleLaunch: isEligibleLaunch,
            activeSeconds: engine.activeSeconds,
            requiredActiveSeconds: StockSelectorHintPolicy.requiredActiveSeconds,
            sustainedSeconds: engine.debugSustainedSeconds,
            requiredSustainedSeconds: StockSelectorHintPolicy.requiredSustainedSeconds,
            didShowCue: engine.didShowCue,
            didOpenSelector: engine.didOpenSelector,
            referenceKelvin: referenceKelvin,
            estimatedKelvin: estimatedKelvin,
            estimateCapturedAt: estimateCapturedAt,
            snapshotAt: now,
            mismatch: mismatch)
    }
}
#endif
