import Foundation
import SwiftUI

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
/// spacing for a nonlinear one and/or a fixed set of meaningful values
/// (see `ISOLadder`).
struct RulerSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Value change per tick. Ignored for snapping when `ladder` is set.
    let step: Double
    /// Finger travel, in points, that moves the value by exactly one `step`.
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
    /// Optional decorative ticks between detents; default is one tick per
    /// reachable value, matching the EV ruler.
    var ladderSubdivisions: Int = 1
    var tint: Color = .white
    /// On-screen height of the ruler window.
    var length: CGFloat = 96
    var width: CGFloat = 56

    enum Orientation { case vertical, horizontal }
    var orientation: Orientation = .vertical
    /// Mirrors the drag sense so the tick strip travels with the finger, as a
    /// camera dial turns. Defaults off, preserving every existing ruler.
    var reversesDrag: Bool = false

    @State private var drag = RulerDragState()
    @State private var feedbackTrigger = 0
#if os(iOS)
    @Environment(\.cameraDeviceOrientation) private var deviceOrientation
#endif

    /// The scale actually used for layout: the caller's, or linear travel at the
    /// configured detent size.
    private var effectiveScale: RulerScale {
        scale ?? .linear(pointsPerStep: Double(pointsPerStep) / (step > 0 ? step : 1))
    }

    private var detents: RulerDetents {
        RulerDetents(scale: effectiveScale, range: range, step: step,
                     anchor: majorAnchor ?? range.lowerBound, ladder: ladder)
    }

    private var selectedPosition: Double {
        effectiveScale.toPosition(detents.snap(value))
    }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(width: orientation == .horizontal ? length : width,
               height: orientation == .horizontal ? width : length)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .sensoryFeedback(.selection, trigger: feedbackTrigger)
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
                // Dragging up (negative height) raises the position, and a
                // higher position is a higher value. Horizontal rulers mirror
                // that unless the caller asks for the dial sense.
                let travel = RulerDragDirection(
                    horizontal: orientation == .horizontal,
                    reversed: reversesDrag
                ).travel(width: Double(gesture.translation.width),
                         height: Double(gesture.translation.height))
                let position = drag.update(
                    valuePosition: effectiveScale.toPosition(value),
                    translation: travel,
                    bounds: effectiveScale.toPosition(range.lowerBound)...effectiveScale.toPosition(range.upperBound)
                )
                setPosition(position)
            }
            .onEnded { _ in drag.end() }
    }

    /// Convert a scroll position to a value, snap it, and tick if it moved.
    private func setPosition(_ position: Double) {
        setValue(effectiveScale.fromPosition(position))
    }

    /// Clamp to the range, snap to the nearest detent, and fire one haptic tick
    /// whenever the selected detent changes, not once per frame or Float echo.
    private func setValue(_ raw: Double) {
        guard let snapped = detents.changedValue(from: value, to: raw) else { return }
        value = snapped
        fireHaptic()
    }

    /// Move the value one detent, used by VoiceOver's adjustable action.
    private func stepValue(by direction: Double) {
        if let ladder,
           let nearest = effectiveScale.nearestDetent(to: effectiveScale.toPosition(value), in: ladder),
           let index = ladder.firstIndex(of: nearest) {
            let next = index + Int(direction)
            guard ladder.indices.contains(next) else { return }
            setValue(ladder[next])
        } else {
            setValue(value + direction * step)
        }
    }

    private func fireHaptic() {
#if os(iOS)
        CameraHaptics.prepareForCaptureFeedback()
#endif
        feedbackTrigger &+= 1
    }

    // MARK: - Rendering

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        if orientation == .horizontal {
            drawHorizontal(in: &context, size: size)
            return
        }
        let centerY = size.height / 2
        let centerPosition = selectedPosition

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
                    .font(NitrateTypography.font(size: 8))
                    .foregroundStyle(.white.opacity(0.7))
                drawLabel(label, in: context, tickY: tickY)
            }
        }

        // Fixed centre pointer — the ruler moves, this does not.
        var pointer = Path()
        pointer.move(to: CGPoint(x: 0, y: centerY))
        pointer.addLine(to: CGPoint(x: size.width, y: centerY))
        context.stroke(pointer, with: .color(tint), lineWidth: 2)
    }

    private func drawHorizontal(in context: inout GraphicsContext, size: CGSize) {
        for tick in visibleTicks(halfHeight: Double(size.width / 2)) {
            let x = size.width / 2 + CGFloat(tick.position - selectedPosition)
            guard x >= -2, x <= size.width + 2 else { continue }
            let tickLength = tick.isMajor ? size.height * 0.42 : size.height * 0.22
            var path = Path()
            path.move(to: CGPoint(x: x, y: size.height - tickLength))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(.white.opacity(tick.isMajor ? 0.85 : 0.3)),
                           lineWidth: tick.isMajor ? 1.5 : 1)
            if tick.isMajor {
                context.draw(Text(tickLabel(tick.value))
                    .font(NitrateTypography.font(size: 8))
                    .foregroundStyle(.white.opacity(0.7)),
                    at: CGPoint(x: x, y: 8), anchor: .center)
            }
        }
        var pointer = Path()
        pointer.move(to: CGPoint(x: size.width / 2, y: 0))
        pointer.addLine(to: CGPoint(x: size.width / 2, y: size.height))
        context.stroke(pointer, with: .color(tint), lineWidth: 2)
    }

    /// Turn only the label about its original centre. Tracks, pointer, detents
    /// and gesture coordinates remain in the portrait control's coordinates.
    private func drawLabel(_ label: Text, in context: GraphicsContext, tickY: CGFloat) {
        let resolved = context.resolve(label)
        let size = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
#if os(iOS)
        let degrees = CameraGlyphRotation.degrees(for: deviceOrientation)
#else
        let degrees: Double = 0
#endif
        let fit = abs(degrees) == 90 && size.width > 0 && size.height > 0
            ? min(1, min(size.width / size.height, size.height / size.width)) : 1
        var glyphContext = context
        // Original .leading anchor places the label centre at half its width.
        glyphContext.translateBy(x: size.width / 2, y: tickY)
        glyphContext.rotate(by: .degrees(degrees))
        glyphContext.scaleBy(x: fit, y: fit)
        glyphContext.draw(resolved, at: .zero, anchor: .center)
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

        let centerPosition = selectedPosition
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
