import Foundation
import Testing

@Suite("Stock selector hint model")
@MainActor
struct StockSelectorHintModelTests {
    private func defaults() throws -> (UserDefaults, String) {
        let name = "StockSelectorHintModelTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func inputs(tick: UInt64, at date: Date,
                        active: Bool = true, opened: Bool = false) -> StockSelectorHintInputs {
        StockSelectorHintInputs(isActive: active, isSelectorOpened: opened, tick: tick,
                                estimateKelvin: 5600, estimateCapturedAt: date, referenceKelvin: 3200)
    }

    private func showCue(_ model: StockSelectorHintModel, from base: Date) {
        for tick in 0...180 {
            let date = base.addingTimeInterval(Double(tick) / 2)
            model.update(inputs(tick: UInt64(tick), at: date), now: date)
        }
    }

    @Test func blockingTheCameraImmediatelyHidesAnActiveCueWithoutRearming() throws {
        let (store, name) = try defaults()
        defer { store.removePersistentDomain(forName: name) }
        let model = StockSelectorHintModel(userDefaults: store)
        model.update(inputs(tick: 0, at: Date()))
        let base = Date()
        showCue(model, from: base)
        #expect(model.isCueVisible)
        #expect(!model.isArmed)
        let blocked = base.addingTimeInterval(90.1)
        model.update(inputs(tick: 181, at: blocked, active: false), now: blocked)
        #expect(!model.isCueVisible)
        let resumed = base.addingTimeInterval(91)
        model.update(inputs(tick: 182, at: resumed), now: resumed)
        #expect(!model.isCueVisible)
        #expect(!model.isArmed)
    }

    @Test func openingTheSelectorImmediatelyHidesAnActiveCue() throws {
        let (store, name) = try defaults()
        defer { store.removePersistentDomain(forName: name) }
        let model = StockSelectorHintModel(userDefaults: store)
        model.update(inputs(tick: 0, at: Date()))
        let base = Date()
        showCue(model, from: base)
        #expect(model.isCueVisible)
        let opened = base.addingTimeInterval(90.1)
        model.update(inputs(tick: 181, at: opened, opened: true), now: opened)
        #expect(!model.isCueVisible)
        #expect(store.integer(forKey: StockSelectorHintLaunchTracker.launchCountKey) == 1)
    }

#if DEBUG
    /// Seed the stored counter so `beginLaunch` records the given ordinal.
    private func seededLaunch(_ store: UserDefaults, ordinal: Int) {
        store.set(ordinal - 1, forKey: StockSelectorHintLaunchTracker.launchCountKey)
    }

    @Test func debugPreviewShowsEvenBeyondTheLaunchLimit() throws {
        let (store, name) = try defaults()
        defer { store.removePersistentDomain(forName: name) }
        seededLaunch(store, ordinal: 4)
        let model = StockSelectorHintModel(userDefaults: store)
        model.update(inputs(tick: 0, at: Date()))
        #expect(model.launch == 4)
        #expect(!model.isEligibleLaunch)
        model.beginDebugPreview()
        #expect(model.isCueVisible)
        #expect(model.isDebugPreviewing)
        // Untouched: no extra launch recorded and the automatic path stays closed.
        #expect(store.integer(forKey: StockSelectorHintLaunchTracker.launchCountKey) == 4)
        #expect(!model.isArmed)
    }

    @Test func debugPreviewSurvivesAHistoricalSelectorOpen() throws {
        // The selector was opened earlier this launch, so every later tick still
        // reports it. A latched historical open must not clear the preview.
        let (store, name) = try defaults()
        defer { store.removePersistentDomain(forName: name) }
        let model = StockSelectorHintModel(userDefaults: store)
        model.update(inputs(tick: 0, at: Date()))
        let base = Date()
        model.update(inputs(tick: 1, at: base, opened: true), now: base)
        #expect(!model.isArmed)
        model.beginDebugPreview()
        #expect(model.isCueVisible)
        let later = base.addingTimeInterval(1)
        model.update(inputs(tick: 2, at: later, opened: true), now: later)
        #expect(model.isCueVisible)
        #expect(model.isDebugPreviewing)
    }

    @Test func debugPreviewDoesNotConsumeOrRearmTheAutomaticHint() throws {
        let (store, name) = try defaults()
        defer { store.removePersistentDomain(forName: name) }
        let model = StockSelectorHintModel(userDefaults: store)
        model.update(inputs(tick: 0, at: Date()))
        #expect(model.isArmed)
        model.beginDebugPreview()
        #expect(model.isCueVisible)
        // The engine is untouched: still armed, launch count unchanged.
        #expect(model.isArmed)
        #expect(store.integer(forKey: StockSelectorHintLaunchTracker.launchCountKey) == 1)
        // And the automatic hint can still fire its own cue afterwards.
        let base = Date()
        for tick in 0...180 {
            let date = base.addingTimeInterval(Double(tick) / 2)
            model.update(inputs(tick: UInt64(tick), at: date), now: date)
        }
        #expect(model.isCueVisible)
        #expect(!model.isArmed)
    }

    @Test func debugPreviewHidesImmediatelyWhenTheCameraIsBlocked() throws {
        let (store, name) = try defaults()
        defer { store.removePersistentDomain(forName: name) }
        let model = StockSelectorHintModel(userDefaults: store)
        model.update(inputs(tick: 0, at: Date()))
        model.beginDebugPreview()
        #expect(model.isCueVisible)
        let base = Date()
        model.update(inputs(tick: 1, at: base, active: false), now: base)
        #expect(!model.isCueVisible)
        #expect(!model.isDebugPreviewing)
    }

    @Test func debugPreviewDoesNotStartWhileTheCameraIsBlocked() throws {
        let (store, name) = try defaults()
        defer { store.removePersistentDomain(forName: name) }
        let model = StockSelectorHintModel(userDefaults: store)
        model.update(inputs(tick: 0, at: Date()))
        let date = Date()
        model.update(inputs(tick: 0, at: date, active: false), now: date)
        model.beginDebugPreview()
        #expect(!model.isCueVisible)
        #expect(!model.isDebugPreviewing)
        #expect(model.isArmed)
        #expect(store.integer(forKey: StockSelectorHintLaunchTracker.launchCountKey) == 1)
    }

    @Test func aSupersededPreviewTimerCannotHideANewerPreview() throws {
        let (store, name) = try defaults()
        defer { store.removePersistentDomain(forName: name) }
        let model = StockSelectorHintModel(userDefaults: store)
        model.update(inputs(tick: 0, at: Date()))
        let first = model.beginDebugPreview()
        let second = model.beginDebugPreview()
        #expect(first != second)
        model.endDebugPreview(token: first)
        #expect(model.isCueVisible)
        #expect(model.isDebugPreviewing)
        model.endDebugPreview(token: second)
        #expect(!model.isCueVisible)
        #expect(!model.isDebugPreviewing)
    }
#endif
}
