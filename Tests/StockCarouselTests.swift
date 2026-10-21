import Foundation
import Testing

/// Focused coverage for the pure selection rules behind the stock carousel /
/// stock-sheet layout. The rendering (scroll snapping, emphasis, haptics) is
/// exercised on device; these rules are what decide which card centers on open
/// and when a swipe is allowed to restore a remembered print gauge.
struct StockCarouselTests {
    private func stock(_ id: String, iso: Float = 400) -> FilmStockConfig {
        FilmStockConfig(
            stockId: id,
            displayName: id,
            category: .video,
            lutName: "\(id) - Apple Log 2.cube",
            halationStrength: 0,
            glowStrength: 0,
            grainSize: 1,
            defaultISO: iso
        )
    }

    /// The shipped catalogue is exactly these two video stocks, in picker order.
    private var catalogue: [FilmStockConfig] {
        [stock("kodak5207", iso: 250), stock("kodak5219", iso: 500)]
    }

    // MARK: - Initial centering

    @Test func centersThePersistedSelectionOnOpen() {
        #expect(StockCarouselSelection.centeredId(onOpen: "kodak5219", stocks: catalogue) == "kodak5219")
        #expect(StockCarouselSelection.centeredId(onOpen: "kodak5207", stocks: catalogue) == "kodak5207")
    }

    @Test func fallsBackToTheFirstStockWhenNothingIsSelected() {
        #expect(StockCarouselSelection.centeredId(onOpen: nil, stocks: catalogue) == "kodak5207")
    }

    @Test func fallsBackToTheFirstStockWhenThePersistedIdIsGone() {
        #expect(StockCarouselSelection.centeredId(onOpen: "removed-stock", stocks: catalogue) == "kodak5207")
    }

    @Test func anEmptyCatalogueHasNoCenter() {
        #expect(StockCarouselSelection.centeredId(onOpen: nil, stocks: []) == nil)
        #expect(StockCarouselSelection.centeredId(onOpen: "kodak5207", stocks: []) == nil)
    }

    // MARK: - Gauge restore on selection change

    @Test func selectingANewStockRestoresItsRememberedGauge() {
        let gauge = StockCarouselSelection.gauge(
            onSelecting: "kodak5219", from: "kodak5207", remembered: .eightMillimetre
        )
        #expect(gauge == .eightMillimetre)
    }

    @Test func selectingANewStockWithNoRememberedGaugeUsesNeutral35mm() {
        let gauge = StockCarouselSelection.gauge(
            onSelecting: "kodak5219", from: "kodak5207", remembered: nil
        )
        #expect(gauge == .thirtyFiveMillimetre)
    }

    @Test func tappingTheAlreadySelectedStockLeavesTheGaugeAlone() {
        // Same stock: nil means "leave the current gauge untouched" — a tap on the
        // centred card must not reset a gauge the user just dialled in.
        let gauge = StockCarouselSelection.gauge(
            onSelecting: "kodak5207", from: "kodak5207", remembered: .seventyFiveMillimetre
        )
        #expect(gauge == nil)
    }

    @Test func selectingFromNoPriorSelectionRestoresTheGauge() {
        let gauge = StockCarouselSelection.gauge(
            onSelecting: "kodak5207", from: nil, remembered: .sixteenMillimetre
        )
        #expect(gauge == .sixteenMillimetre)
    }
}
