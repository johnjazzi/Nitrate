import Foundation
import Testing

struct RulerScaleTests {
    @Test func linearDetentsTravelTwelvePoints() {
        let scale = RulerScale.linear(pointsPerStep: RulerScale.detentTravel / 0.1)
        #expect(abs(scale.toPosition(0.1) - scale.toPosition(0) - 12) < 1e-9)
    }

    @Test func isoThirdStopsHaveConsistentLogarithmicTravel() {
        let scale = RulerScale.logarithmic(pointsPerStop: RulerScale.detentTravel * 3)
        for iso in [25.0, 100, 800, 6400, 25600] {
            let thirdStop = iso * pow(2, 1.0 / 3)
            #expect(abs(scale.toPosition(thirdStop) - scale.toPosition(iso) - 12) < 1e-9)
            #expect(abs(scale.fromPosition(scale.toPosition(iso)) - iso) < 1e-6)
        }
        for (low, high) in zip(ISOLadder.steps, ISOLadder.steps.dropFirst()) {
            let travel = scale.toPosition(high) - scale.toPosition(low)
            #expect(travel > 11 && travel < 13)
        }
    }

    @Test func evFeedbackOnlyChangesWhenCrossingADistinctDetent() {
        let scale = RulerScale.linear(pointsPerStep: RulerScale.detentTravel / 0.1)
        let detents = RulerDetents(scale: scale, range: -2...2, step: 0.1, anchor: 0)
        let selected = detents.snap(0.08)
        #expect(abs(selected - 0.1) < 1e-9)
        let echo = Double(Float(selected))
        #expect(detents.changedValue(from: echo, to: 0.11) == nil)
        #expect(detents.changedValue(from: echo, to: 0.14) == nil)
        #expect(detents.changedValue(from: echo, to: 0.16) == 0.2)
        #expect(detents.changedValue(from: echo, to: 0.04) == 0)
        #expect(abs(scale.toPosition(detents.snap(echo)) - 12) < 1e-9)
    }

    @Test func dragRendersSnappedTicksWithoutReanchoringOrRepeatedFeedback() {
        let scale = RulerScale.linear(pointsPerStep: RulerScale.detentTravel / 0.1)
        let detents = RulerDetents(scale: scale, range: -2...2, step: 0.1, anchor: 0)
        var drag = RulerDragState()
        var value = 0.0
        var changes: [Double] = []
        for translation in [-7.0, -8, -17, -19, -8, -4] {
            let position = drag.update(valuePosition: scale.toPosition(value), translation: translation, bounds: -240...240)
            if let selected = detents.changedValue(from: value, to: scale.fromPosition(position)) {
                changes.append(selected)
                value = Double(Float(selected))
            }
            let renderedPosition = scale.toPosition(detents.snap(value))
            #expect(abs(renderedPosition / 12 - (renderedPosition / 12).rounded()) < 1e-9)
        }
        #expect(changes == [0.1, 0.2, 0.1, 0])
    }

    @Test func isoFeedbackPreservesBoundsAndIgnoresFloatEchoes() {
        let range = Double(Float(99.5))...Double(Float(800.5))
        let scale = RulerScale.logarithmic(pointsPerStop: RulerScale.detentTravel * 3)
        let detents = RulerDetents(scale: scale, range: range, step: 25, anchor: 0, ladder: ISOLadder.values(in: range))
        #expect(detents.changedValue(from: 100, to: 126) == 125)
        #expect(detents.changedValue(from: Double(Float(125)), to: 126) == nil)
        #expect(detents.changedValue(from: 125, to: 99) == range.lowerBound)
        #expect(detents.changedValue(from: range.lowerBound, to: 0) == nil)
        #expect(detents.changedValue(from: 800, to: 900) == range.upperBound)
        #expect(detents.changedValue(from: range.upperBound, to: 1000) == nil)
    }

    @Test func isoSnapsAtVisualMidpointRatherThanArithmeticMidpoint() {
        let scale = RulerScale.logarithmic(pointsPerStop: RulerScale.detentTravel * 3)
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
