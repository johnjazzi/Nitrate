import Foundation

/// Monotonic value ↔ ruler position mapping, measured in points.
struct RulerScale: Sendable {
    let toPosition: @Sendable (Double) -> Double
    let fromPosition: @Sendable (Double) -> Double

    /// Points per value unit; the ruler divides its detent travel by `step`.
    static func linear(pointsPerStep: Double) -> RulerScale {
        RulerScale(
            toPosition: { $0 * pointsPerStep },
            fromPosition: { $0 / pointsPerStep }
        )
    }

    /// Equal exposure ratios have equal travel. At 72pt per stop, a nominal
    /// 1/3-stop ISO detent travels 24pt, regardless of the starting ISO.
    /// Printed camera ISO values are rounded, so their spacing is near 24pt.
    static func logarithmic(pointsPerStop: Double) -> RulerScale {
        RulerScale(
            toPosition: { log2($0) * pointsPerStop },
            fromPosition: { pow(2, $0 / pointsPerStop) }
        )
    }

    /// Snap in visual position space, not numeric ISO space, so crossing the
    /// midpoint between ticks always changes the selected detent.
    func nearestDetent(to position: Double, in ladder: [Double]) -> Double? {
        ladder.min { abs(toPosition($0) - position) < abs(toPosition($1) - position) }
    }
}

/// Keeps total gesture translation anchored to the original (unsnapped) start.
/// The rendered position stays continuous even when the binding crosses ticks.
struct RulerDragState {
    private var startPosition: Double?
    private(set) var position: Double?

    mutating func update(
        valuePosition: Double,
        translation: Double,
        bounds: ClosedRange<Double>
    ) -> Double {
        let start = startPosition ?? valuePosition
        startPosition = start
        let next = min(max(start - translation, bounds.lowerBound), bounds.upperBound)
        position = next
        return next
    }

    mutating func end() {
        startPosition = nil
        position = nil
    }
}

/// Standard rounded 1/3-stop ISO detents, plus the active sensor's exact bounds.
enum ISOLadder {
    static let steps: [Double] = [
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640,
        800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000,
        10000, 12800, 16000, 20000, 25600
    ]

    static let fullStops: Set<Double> = [
        50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600
    ]

    static func values(in range: ClosedRange<Double>) -> [Double] {
        var values = steps.filter { range.contains($0) }
        if values.first != range.lowerBound {
            values.insert(range.lowerBound, at: 0)
        }
        if values.last != range.upperBound {
            values.append(range.upperBound)
        }
        return values
    }
}
