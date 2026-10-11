import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A monotonic mapping between a control's value and the ruler's linear travel.
///
/// `RulerSlider` lays its ticks out by scroll position, so a control that needs
/// nonlinear travel does not need a second control — it supplies a scale. This
/// keeps the ruler affordance (fixed pointer, relative drag, snapping, haptics)
/// identical no matter how the value is distributed.
struct RulerScale: Sendable {
    /// Value → scroll position, in points.
    let toPosition: @Sendable (Double) -> Double
    /// Scroll position, in points → value.
    let fromPosition: @Sendable (Double) -> Double

    /// Equal travel changes the value by a constant amount. Used by EV, where
    /// every 0.1 stop should cost the same finger movement.
    ///
    /// `pointsPerStep` matters: the ruler works in POINTS, so a scale that
    /// returned raw values would squeeze the whole range into the control.
    static func linear(pointsPerStep: Double) -> RulerScale {
        RulerScale(
            toPosition: { $0 * pointsPerStep },
            fromPosition: { $0 / pointsPerStep }
        )
    }

    /// Exponential travel: the value changes by `rate(value)` per point, where
    /// the rate grows linearly with the value itself.
    ///
    /// Two anchors are supplied rather than a single multiplier, because the
    /// useful feel is not a pure exponential: ISO needs to be fine at the
    /// bottom of its range and coarse near the top. Solving `dv/dp = a + b·v`
    /// through both anchors and integrating gives `position = ln(a + b·v)/b`.
    ///
    /// - Parameters:
    ///   - lowValue/lowRate: the anchor at the small end; `lowRate` is in value
    ///     units per point of travel.
    ///   - highValue/highRate: the anchor at the large end.
    static func exponential(
        lowValue: Double,
        lowRate: Double,
        highValue: Double,
        highRate: Double
    ) -> RulerScale {
        let slope = (highRate - lowRate) / (highValue - lowValue)
        let offset = lowRate - slope * lowValue
        return RulerScale(
            toPosition: { value in log(offset + slope * value) / slope },
            fromPosition: { position in (exp(slope * position) - offset) / slope }
        )
    }
}

/// The standard 1/3-stop ISO sequence, as used on every camera.
///
/// Only meaningful values are reachable, which is what makes the ISO ruler feel
/// like a camera instead of a numeric field: each detent is a real exposure
/// step, and each full stop (100, 200, 400…) gets a printed label.
enum ISOLadder {
    /// 1/3-stop steps from 25 to 25600.
    static let steps: [Double] = [
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640,
        800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000,
        10000, 12800, 16000, 20000, 25600
    ]

    /// Full stops — the values worth printing a label next to.
    static let fullStops: Set<Double> = [
        50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600
    ]

    /// The ladder clipped to `range`. The device's own bounds are appended when
    /// they fall between two ladder values, so the extremes of the sensor's
    /// range stay reachable instead of being rounded away.
    static func values(in range: ClosedRange<Double>) -> [Double] {
        var values = steps.filter { range.contains($0) }
        if let first = values.first, first - range.lowerBound > 1 {
            values.insert(range.lowerBound, at: 0)
        } else if values.isEmpty {
            values.append(range.lowerBound)
        }
        if let last = values.last, range.upperBound - last > 1 {
            values.append(range.upperBound)
        }
        return values
    }
}

/// A scrolling "ruler" control for values that need very fine, repeatable
/// adjustment.
///
/// Unlike `Slider`, the drag is RELATIVE: the ruler scrolls under a fixed
/// centre pointer and never maps the whole range onto the track. One `step` of
/// travel always costs `pointsPerStep` points, so a narrow window can still
/// reach a wide range — a step at a time — without the value jumping under the
/// finger.
///
/// The value is SNAPPED to whole `step`s and each detent crossing fires a
/// haptic tick, so a setting like 0.1 EV is repeatable by feel rather than by
/// reading the readout. Supplying a `scale` and/or `ladder` swaps the linear
/// spacing for an exponential one and/or a fixed set of meaningful values
/// (see `ISOLadder`).
struct RulerSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Value change per tick. Ignored for snapping when `ladder` is set.
    let step: Double
    /// Finger travel, in points, that moves the value by exactly one `step`.
    /// 4mm is roughly 24pt on a typical iPhone.
    let pointsPerStep: CGFloat
    /// Every Nth tick is a labelled major tick.
    var majorEvery: Int = 5
    /// Value that major ticks are measured from. Defaults to the range's lower
    /// bound, which keeps signed ranges like EV (-0.5, 0.0, +0.5) on round
    /// labels. Pass an explicit anchor for ranges that don't start on a round
    /// number — ISO starts at 100, so anchoring at 0 lands majors on 250/500/750.
    var majorAnchor: Double?
    /// Explicit labels, overriding `majorEvery`. Used when the labelled values
    /// are not evenly spaced from a single anchor (the ISO full stops).
    var majorValues: Set<Double> = []
    /// Formats a major tick's label. Defaults to a signed one-decimal readout.
    var tickLabel: (Double) -> String = { String(format: "%+.1f", $0) }
    /// Maps value ↔ scroll position, in points. `nil` means linear travel at
    /// `pointsPerStep` points per step (equal travel = equal change).
    var scale: RulerScale?
    /// When set, the value snaps to the nearest entry rather than to `step`
    /// multiples, and ticks are drawn at those entries. Used for value sets
    /// that are not evenly spaced (ISO's 1/3-stop ladder).
    var ladder: [Double]?
    /// Extra ticks drawn between consecutive `ladder` entries. Purely visual —
    /// snapping still lands on the ladder itself. Needed because a 1/3-stop
    /// ladder is far apart once the scale turns exponential at high ISO, and a
    /// window that can only fit one tick reads as empty.
    var ladderSubdivisions: Int = 1
    var tint: Color = .white
    /// On-screen height of the ruler window.
    var length: CGFloat = 96
    var width: CGFloat = 56

    /// Scroll position when the current drag began; the drag is measured against
    /// this so the control never "runs away" as the binding updates mid-gesture.
    @State private var dragStartPosition: Double?

    #if canImport(UIKit)
    /// Fires one tick of feedback each time the value crosses a detent.
    /// `@State` so the same generator survives view re-renders — a freshly
    /// constructed generator would not be warmed up and would tick unreliably.
    @State private var haptic = UISelectionFeedbackGenerator()
    #endif

    /// The scale actually used for layout: the caller's, or linear travel at the
    /// configured detent size.
    private var effectiveScale: RulerScale {
        scale ?? .linear(pointsPerStep: Double(pointsPerStep))
    }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(width: width, height: length)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: stepValue(by: 1)
            case .decrement: stepValue(by: -1)
            default: break
            }
        }
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        // minimumDistance 0 so the very first touch starts tracking; a tap
        // alone produces no movement and therefore no change.
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let start = dragStartPosition ?? effectiveScale.toPosition(value)
                if dragStartPosition == nil {
                    dragStartPosition = start
                    #if canImport(UIKit)
                    haptic.prepare()
                    #endif
                }
                // Dragging up (negative height) raises the position, and a
                // higher position is a higher value.
                setPosition(start - Double(gesture.translation.height))
            }
            .onEnded { _ in dragStartPosition = nil }
    }

    /// Convert a scroll position to a value, snap it, and tick if it moved.
    private func setPosition(_ position: Double) {
        setValue(effectiveScale.fromPosition(position))
    }

    /// Clamp to the range, snap to the nearest detent, and fire one haptic tick
    /// whenever the snapped value actually changes — once per detent crossed,
    /// not once per frame of the drag.
    private func setValue(_ raw: Double) {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        let snapped = snap(clamped)
        guard snapped != value else { return }
        value = snapped
        fireHaptic()
    }

    /// Move the value one detent, used by VoiceOver's adjustable action.
    private func stepValue(by direction: Double) {
        if let ladder, let index = ladder.firstIndex(where: { abs($0 - value) < 1e-6 }) {
            let next = index + Int(direction)
            guard ladder.indices.contains(next) else { return }
            value = ladder[next]
            fireHaptic()
        } else {
            setValue(value + direction * step)
        }
    }

    private func fireHaptic() {
        #if canImport(UIKit)
        haptic.selectionChanged()
        #endif
    }

    /// Nearest entry of the ladder, or the nearest whole `step` from the anchor
    /// (tolerating a tiny epsilon so 0.1-style steps don't drift). Snapping is
    /// anchored the same way as the major ticks, so a value can always land
    /// exactly on a labelled tick.
    private func snap(_ raw: Double) -> Double {
        if let ladder, !ladder.isEmpty {
            let nearest = ladder.min(by: { abs($0 - raw) < abs($1 - raw) })
            return min(max(nearest ?? raw, range.lowerBound), range.upperBound)
        }
        guard step > 0 else { return raw }
        let anchor = majorAnchor ?? range.lowerBound
        let stepCount = ((raw - anchor) / step + 1e-6).rounded()
        let snapped = anchor + stepCount * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    // MARK: - Rendering

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let centerY = size.height / 2
        let centerPosition = effectiveScale.toPosition(value)

        for tick in visibleTicks(halfHeight: Double(size.height / 2)) {
            let tickY = centerY - CGFloat(tick.position - centerPosition)
            guard tickY >= -2, tickY <= size.height + 2 else { continue }

            let tickLength = tick.isMajor ? size.width * 0.42 : size.width * 0.22
            var path = Path()
            path.move(to: CGPoint(x: size.width - tickLength, y: tickY))
            path.addLine(to: CGPoint(x: size.width, y: tickY))
            context.stroke(
                path,
                with: .color(.white.opacity(tick.isMajor ? 0.85 : 0.3)),
                lineWidth: tick.isMajor ? 1.5 : 1
            )

            if tick.isMajor {
                let label = Text(tickLabel(tick.value))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                context.draw(label, at: CGPoint(x: 0, y: tickY), anchor: .leading)
            }
        }

        // Fixed centre pointer — the ruler moves, this does not.
        var pointer = Path()
        pointer.move(to: CGPoint(x: 0, y: centerY))
        pointer.addLine(to: CGPoint(x: size.width, y: centerY))
        context.stroke(pointer, with: .color(tint), lineWidth: 2)
    }

    /// A tick to draw: its value, where it sits on the ruler, and whether it is
    /// labelled.
    private struct Tick {
        let value: Double
        let position: Double
        let isMajor: Bool
    }

    /// Ticks covering the visible window. The edges of the window are converted
    /// back to values through the scale, so this works whether the spacing is
    /// linear or exponential.
    private func visibleTicks(halfHeight: Double) -> [Tick] {
        if let ladder {
            return ladderTicks(ladder)
        }

        let centerPosition = effectiveScale.toPosition(value)
        let valueTop = effectiveScale.fromPosition(centerPosition + halfHeight)
        let valueBottom = effectiveScale.fromPosition(centerPosition - halfHeight)

        let anchor = majorAnchor ?? range.lowerBound
        guard step > 0 else { return [] }
        let firstIndex = Int(((valueBottom - anchor) / step).rounded(.down))
        let lastIndex = Int(((valueTop - anchor) / step).rounded(.up))
        // Guard against a pathological step/height combination generating a
        // million ticks; the visible window can never legitimately need more
        // than a few hundred points worth.
        guard lastIndex - firstIndex < 2000 else { return [] }

        return (firstIndex...lastIndex).compactMap { index in
            let tickValue = anchor + Double(index) * step
            guard tickValue >= range.lowerBound - 1e-9,
                  tickValue <= range.upperBound + 1e-9 else { return nil }
            return Tick(
                value: tickValue,
                position: effectiveScale.toPosition(tickValue),
                isMajor: isMajorTick(tickValue)
            )
        }
    }

    /// Ticks for a fixed value ladder, optionally with sub-ticks between the
    /// entries. Sub-ticks are interpolated GEOMETRICALLY, because the ladders
    /// this serves (ISO) are ratio-based — 1/3 stop — so the midpoint between
    /// 100 and 125 is √(100·125) ≈ 111.8, not 112.5.
    private func ladderTicks(_ ladder: [Double]) -> [Tick] {
        var ticks: [Tick] = []
        for (index, entry) in ladder.enumerated() {
            ticks.append(Tick(
                value: entry,
                position: effectiveScale.toPosition(entry),
                isMajor: isMajorValue(entry)
            ))
            guard index + 1 < ladder.count, ladderSubdivisions > 1, entry > 0 else { continue }
            let next = ladder[index + 1]
            for subdivision in 1..<ladderSubdivisions {
                let fraction = Double(subdivision) / Double(ladderSubdivisions)
                let value = entry * pow(next / entry, fraction)
                ticks.append(Tick(
                    value: value,
                    position: effectiveScale.toPosition(value),
                    isMajor: false
                ))
            }
        }
        return ticks
    }

    /// True when `tickValue` is one of the explicitly labelled values, or a
    /// multiple of `majorEvery` steps from `majorAnchor`.
    private func isMajorValue(_ tickValue: Double) -> Bool {
        if !majorValues.isEmpty {
            return majorValues.contains(tickValue)
        }
        return isMajorTick(tickValue)
    }

    /// True when `tickValue` sits exactly on a labelled major tick, measured
    /// from `majorAnchor` (or the range's lower bound) rather than from the
    /// loop index, so the labels stay on round numbers.
    private func isMajorTick(_ tickValue: Double) -> Bool {
        guard majorEvery > 0, step > 0 else { return false }
        let anchor = majorAnchor ?? range.lowerBound
        let relative = (tickValue - anchor) / step
        let nearest = relative.rounded()
        guard abs(relative - nearest) < 1e-6 else { return false }
        return Int(nearest) % majorEvery == 0
    }
}
