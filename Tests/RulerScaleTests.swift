import Foundation
import Testing

struct RulerScaleTests {
    @Test func linearDetentsTravelTwentyFourPoints() {
        let scale = RulerScale.linear(pointsPerStep: 24 / 0.1)
        #expect(abs(scale.toPosition(0.1) - scale.toPosition(0) - 24) < 1e-9)
    }

    @Test func isoThirdStopsHaveConsistentLogarithmicTravel() {
        let scale = RulerScale.logarithmic(pointsPerStop: 72)
        for iso in [25.0, 100, 800, 6400, 25600] {
            let thirdStop = iso * pow(2, 1.0 / 3)
            #expect(abs(scale.toPosition(thirdStop) - scale.toPosition(iso) - 24) < 1e-9)
            #expect(abs(scale.fromPosition(scale.toPosition(iso)) - iso) < 1e-6)
        }
        for (low, high) in zip(ISOLadder.steps, ISOLadder.steps.dropFirst()) {
            let travel = scale.toPosition(high) - scale.toPosition(low)
            #expect(travel > 22 && travel < 26)
        }
    }

    @Test func isoSnapsAtVisualMidpointRatherThanArithmeticMidpoint() {
        let scale = RulerScale.logarithmic(pointsPerStop: 72)
        let lower = scale.toPosition(100)
        let upper = scale.toPosition(125)
        #expect(scale.nearestDetent(to: (lower + upper) / 2 + 0.01, in: [100, 125]) == 125)
        #expect(scale.nearestDetent(to: (lower + upper) / 2 - 0.01, in: [100, 125]) == 100)
    }

    @Test func snappedBindingDoesNotResetContinuousDragOrigin() {
        var drag = RulerDragState()
        #expect(drag.update(valuePosition: 100, translation: -13, bounds: 0...300) == 113)
        #expect(drag.update(valuePosition: 124, translation: -14, bounds: 0...300) == 114)
        #expect(drag.update(valuePosition: 124, translation: -36, bounds: 0...300) == 136)
        #expect(drag.update(valuePosition: 148, translation: -10, bounds: 0...300) == 110)
        drag.end()
        #expect(drag.position == nil)
        #expect(drag.update(valuePosition: 124, translation: -1, bounds: 0...300) == 125)
    }

    @Test func dragClampsAtHardwareBoundsWithoutLosingItsOrigin() {
        var drag = RulerDragState()
        #expect(drag.update(valuePosition: 100, translation: -400, bounds: 20...200) == 200)
        #expect(drag.update(valuePosition: 200, translation: 90, bounds: 20...200) == 20)
        #expect(drag.update(valuePosition: 20, translation: 0, bounds: 20...200) == 100)
    }

    @Test func isoLadderPreservesExactHardwareEndpoints() {
        let values = ISOLadder.values(in: 99.5...800.5)
        #expect(values.first == 99.5)
        #expect(values.last == 800.5)
        #expect(values.dropFirst().dropLast().allSatisfy { ISOLadder.steps.contains($0) })
        #expect(ISOLadder.values(in: 101...102) == [101, 102])
        #expect(ISOLadder.values(in: 100...100) == [100])
    }
}
