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
        let base = Date()
        showCue(model, from: base)
        #expect(model.isCueVisible)
        let opened = base.addingTimeInterval(90.1)
        model.update(inputs(tick: 181, at: opened, opened: true), now: opened)
        #expect(!model.isCueVisible)
        #expect(store.integer(forKey: StockSelectorHintLaunchTracker.launchCountKey) == 1)
    }
}
