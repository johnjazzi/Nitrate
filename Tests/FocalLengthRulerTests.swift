import Foundation
import Testing

struct FocalLengthRulerTests {
    @Test func majorTicksFireOnCrossingNotOnApproachOrStationaryEcho() {
        #expect(!FocalLengthRulerScale.crossesMajorTick(from: 25, to: 34))
        #expect(FocalLengthRulerScale.crossesMajorTick(from: 34, to: 35))
        #expect(!FocalLengthRulerScale.crossesMajorTick(from: 35, to: 35))
        #expect(!FocalLengthRulerScale.crossesMajorTick(from: 35, to: 36))
        #expect(FocalLengthRulerScale.crossesMajorTick(from: 36, to: 35))
        #expect(FocalLengthRulerScale.crossesMajorTick(from: 150, to: 13))
        #expect(!FocalLengthRulerScale.crossesMajorTick(from: .nan, to: 24))
    }

    @Test func rulerCentersCurrentFocalAndKeepsAdjacentLabelsSeparated() {
        #expect(FocalLengthRulerScale.offset(millimeters: 24, selected: 24) == 0)
        #expect(FocalLengthRulerScale.offset(millimeters: 13, selected: 24) < 0)
        #expect(FocalLengthRulerScale.offset(millimeters: 150, selected: 24) > 0)
        #expect(FocalLengthRulerScale.offset(millimeters: 110, selected: 96) >= 24)
    }

    // MARK: - Controlled-zoom ruler range

    /// The ruler's fixed landmarks are the pinch ruler's, unchanged: the
    /// stationary `FocalLengthRuler`, `crossesMajorTick` and the pinch tests all
    /// keep their exact values.
    @Test func controlledRulerPreservesFixedPinchLandmarks() {
        #expect(FrameZoomRulerScale.fixedLandmarks == CameraFocalZoomPolicy.majorTicks)
        #expect(FocalLengthRulerScale.majorTicks == CameraFocalZoomPolicy.majorTicks)
        #expect(FrameZoomRulerScale.majorTicks(in: 13...150) == [13, 24, 35, 50, 75, 96, 110, 150])
    }

    /// The range converter anchors on the tier base and the real display
    /// multiplier, exactly like the live readout, so a telephoto ceiling is
    /// 1536 mm, a wide ceiling is 384 mm and a multiplier other than 1 converts
    /// correctly.
    @Test func availableRangeConvertsByTierAndDisplayMultiplier() throws {
        let telephoto = try #require(CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: 1, maximumDisplayFactor: 16, multiplier: 1, tier: .telephoto))
        #expect(abs(telephoto.lowerBound - 96) < 0.001)
        #expect(abs(telephoto.upperBound - 1536) < 0.001)

        let wide = try #require(CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: 1, maximumDisplayFactor: 16, multiplier: 1, tier: .wide))
        #expect(abs(wide.lowerBound - 24) < 0.001)
        #expect(abs(wide.upperBound - 384) < 0.001)

        let wideDefaultCeiling = try #require(CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: 1, maximumDisplayFactor: 5, multiplier: 1, tier: .wide))
        #expect(abs(wideDefaultCeiling.upperBound - 120) < 0.001)

        let multiplierTwo = try #require(CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: 2, maximumDisplayFactor: 32, multiplier: 2, tier: .telephoto))
        #expect(abs(multiplierTwo.lowerBound - 96) < 0.001)
        #expect(abs(multiplierTwo.upperBound - 1536) < 0.001)
    }

    @Test func availableRangeRefusesInvalidInput() {
        #expect(CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: 0, maximumDisplayFactor: 16, multiplier: 1, tier: .wide) == nil)
        #expect(CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: -1, maximumDisplayFactor: 16, multiplier: 1, tier: .wide) == nil)
        #expect(CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: .nan, maximumDisplayFactor: 16, multiplier: 1, tier: .wide) == nil)
        #expect(CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: 1, maximumDisplayFactor: .infinity, multiplier: 1, tier: .wide) == nil)
        #expect(CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: 1, maximumDisplayFactor: 16, multiplier: 0, tier: .wide) == nil)
        // Inverted bounds (max below min after conversion) are refused too.
        #expect(CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: 16, maximumDisplayFactor: 1, multiplier: 1, tier: .wide) == nil)
    }

    /// The controlled range marks its endpoints and the round increments above
    /// 150, and every tick is inside the live range — no falsely-available value.
    @Test func majorTicksCoverEndpointAndIncrementsAbove150OnlyWithinRange() {
        let telephoto = FrameZoomRulerScale.majorTicks(in: 96...1536)
        #expect(telephoto.first == 96)
        #expect(telephoto.last == 1536)
        #expect(telephoto.contains(200))
        #expect(telephoto.contains(400))
        #expect(telephoto.contains(800))
        #expect(telephoto.contains { $0 > 150 },
                "the controlled ruler must reach past the old fixed 150 mm ceiling")
        #expect(telephoto.allSatisfy { $0 >= 96 && $0 <= 1536 })
        #expect(!telephoto.contains(13), "an unreachable ultrawide landmark must not appear")

        let wide = FrameZoomRulerScale.majorTicks(in: 24...384)
        #expect(wide.first == 24)
        #expect(abs((wide.last ?? 0) - 384) < 0.001, "the exact non-round endpoint must be marked")
        #expect(wide.contains(250))
        #expect(wide.contains(350))
        #expect(wide.allSatisfy { $0 >= 24 && $0 <= 384 })
    }

    /// A moving log scale centred at 400 keeps a marked current neighbourhood
    /// and the endpoint legible.
    @Test func movingScaleAt400KeepsNeighbourhoodAndEndpoint() {
        let range = 96.0...1536.0
        let majors = FrameZoomRulerScale.majorTicks(in: range)
        #expect(majors.contains(400))
        let labelled = FrameZoomRulerScale.labelledTicks(majors)
        #expect(labelled.contains(400))
        #expect(labelled.last == 1536, "the far endpoint must stay readable")
        #expect(labelled.contains { FrameZoomRulerScale.pixelGap(from: $0, to: 400) <= 128 },
                "a labelled tick must sit within one octave of the centred value")
    }

    /// Every generated array is finite, inside the range, ascending, unique and
    /// capped, including for an implausibly wide but finite range.
    @Test func extremeInputsCannotOverflowOrLeaveTickGenerationUnbounded() {
        #expect(CameraFocalZoomPolicy.availableFocalLengthRange(
            minimumDisplayFactor: 1, maximumDisplayFactor: .greatestFiniteMagnitude,
            multiplier: .leastNormalMagnitude, tier: .telephoto) == nil)
        #expect(FrameZoomRulerScale.resolvedRange(currentMM: .greatestFiniteMagnitude,
                                                 available: nil) == 13...150)
        let extreme = Double.greatestFiniteMagnitude
        #expect(FrameZoomRulerScale.minorTicks(in: extreme...extreme).count <= 128)
        #expect(FrameZoomRulerScale.minorTicks(in: 1...10_000).count <= 128)
    }

    @Test func generatedTickArraysAreBoundedAndInRange() {
        let ranges: [ClosedRange<Double>] = [13...150, 96...1536, 24...384, 150...800, 400...400, 1...100_000]
        for range in ranges {
            let majors = FrameZoomRulerScale.majorTicks(in: range)
            let minors = FrameZoomRulerScale.minorTicks(in: range)
            for ticks in [majors, minors] {
                #expect(!ticks.isEmpty || range.lowerBound == range.upperBound)
                #expect(ticks.count <= FrameZoomRulerScale.maximumTickCount)
                #expect(ticks.allSatisfy { $0.isFinite && $0 >= range.lowerBound && $0 <= range.upperBound })
                #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $0.0 < $0.1 }, "ticks must ascend")
            }
            #expect(majors.first == range.lowerBound)
            #expect(majors.last == range.upperBound)
        }
    }

    /// Label collision guard: adjacent readouts never crowd, and both endpoints
    /// survive.
    @Test func labelledTicksKeepEndpointsAndAvoidCollisions() {
        let crowded: [Double] = [350, 384, 400]
        let labels = FrameZoomRulerScale.labelledTicks(crowded)
        #expect(labels.first == 350)
        #expect(labels.last == 400)
        #expect(labels.count <= crowded.count)
        for (a, b) in zip(labels, labels.dropFirst()) {
            #expect(FrameZoomRulerScale.pixelGap(from: a, to: b) >= 20
                        || (a == labels.first && b == labels.last))
        }
    }

    /// Without a live range the ruler still bounds the rail around a finite
    /// current value past 150 rather than rendering blank; the fixed 13…150
    /// window is unchanged for the pinch landmarks.
    @Test func resolvedRangeFallsBackAroundCurrentValueBeyondFixedWindow() {
        #expect(FrameZoomRulerScale.resolvedRange(currentMM: 50, available: nil) == 13...150)
        #expect(FrameZoomRulerScale.resolvedRange(currentMM: 150, available: nil) == 13...150)
        #expect(FrameZoomRulerScale.resolvedRange(currentMM: .nan, available: nil) == 13...150)

        for current in [350.0, 384.0, 400.0] {
            let range = FrameZoomRulerScale.resolvedRange(currentMM: current, available: nil)
            #expect(range.lowerBound <= current && current <= range.upperBound)
            #expect(range.lowerBound.isFinite && range.upperBound.isFinite)
            #expect(range.upperBound <= current * 2 + 0.001)
            // A finite fallback range must yield visible marks near the value.
            let majors = FrameZoomRulerScale.majorTicks(in: range)
            #expect(majors.contains { FrameZoomRulerScale.pixelGap(from: $0, to: current) <= 128 },
                    "the fallback rail must mark the current neighbourhood at \(current)mm")
        }

        let live = 96.0...1536.0
        #expect(FrameZoomRulerScale.resolvedRange(currentMM: 400, available: live) == live)
    }
}
