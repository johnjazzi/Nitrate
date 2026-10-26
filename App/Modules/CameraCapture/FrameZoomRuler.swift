import SwiftUI

/// The in-frame vertical zoom ruler the live Zoom toggle shows in place of the
/// old bottom strip. It is authored in the upright portrait axis — a 44pt
/// column — so `FrameRulerSlot` can carry it to the physical left edge in every
/// hold while its glyphs stay readable.
///
/// Everything is bounded by the granted slot and clipped, so no intrinsic width
/// can overflow the column, and the cosmetic rail never takes hits: only the two
/// hold arrows are interactive, so the preview underneath the rail still
/// receives its own taps.
///
/// The tick values are drawn from `FrameZoomRulerScale`, which spans the real
/// controlled range the slow-zoom ramp can reach — not a fixed 13…150 — so a
/// telephoto at 400 mm or an endpoint past 150 mm still has a marked rail.
///
/// The arrows reuse `ZoomHoldControl`, the same begin/end/revision protocol as
/// the manual panel's hold keys, so release, drag-off and a revision change
/// cancel the ramp identically.
struct FrameZoomRuler: View {
    let millimeters: Double
    let enabled: Bool
    let revision: UInt64
    let begin: (CameraZoomDirection) -> Void
    let end: (UInt64) -> Void
    let step: (CameraZoomDirection) -> Void
    /// The real focal-length window the active lens can render, converted from
    /// the session's published display-factor bounds by
    /// `CameraFocalZoomPolicy.availableFocalLengthRange`. Optional with a `nil`
    /// default so the render fixtures that predate the controlled range still
    /// construct the ruler; a `nil` range falls back to a bounded neighbourhood
    /// of `millimeters` instead of a blank rail.
    var availableFocalRange: ClosedRange<Double>? = nil

    /// The width of the drawn rail. The ruler keeps its 44pt column for the
    /// hold arrows; the visible rail is inset inside that column, flush to the
    /// frame's physical left edge, so the drawn rail can be narrowed without
    /// moving the arrows or shrinking their tap targets. The 44pt default
    /// preserves the existing fixtures.
    var visualWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 6) {
            arrow(.out, symbol: "chevron.up", label: "Zoom out")
            rail
                .frame(width: visualWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
            arrow(.in, symbol: "chevron.down", label: "Zoom in")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .clipped()
    }

    private func arrow(_ direction: CameraZoomDirection, symbol: String, label: String) -> some View {
        ZoomHoldControl(symbol: symbol, label: label, enabled: enabled, revision: revision,
                        begin: { begin(direction) }, end: end, step: { step(direction) })
    }

    private var rail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.45))
            Canvas { context, size in
                let center = size.height / 2
                let range = FrameZoomRulerScale.resolvedRange(currentMM: millimeters,
                                                             available: availableFocalRange)
                let majors = FrameZoomRulerScale.majorTicks(in: range)
                let labelled = Set(FrameZoomRulerScale.labelledTicks(majors))
                for value in FrameZoomRulerScale.minorTicks(in: range) {
                    let y = center + FocalLengthRulerScale.offset(millimeters: value, selected: millimeters)
                    guard y >= 0, y <= size.height else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: 5, y: y))
                    context.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1)
                }
                for value in majors {
                    let y = center + FocalLengthRulerScale.offset(millimeters: value, selected: millimeters)
                    guard y >= 8, y <= size.height - 8 else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: 10, y: y))
                    context.stroke(path, with: .color(.white), lineWidth: 1)
                    guard labelled.contains(value), value < 1_000_000 else { continue }
                    context.draw(Text("\(Int(value.rounded()))")
                        .font(NitrateTypography.font(size: 9))
                        .foregroundStyle(.white),
                        at: CGPoint(x: size.width * 0.62, y: y))
                }
                var index = Path()
                index.move(to: CGPoint(x: 0, y: center))
                index.addLine(to: CGPoint(x: size.width, y: center))
                context.stroke(index, with: .color(.yellow), lineWidth: 2)
            }
            Text(readout)
                .font(NitrateTypography.font(size: 9))
                .foregroundStyle(.yellow)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(.black.opacity(0.65), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zoom focal length")
        .accessibilityValue(readout)
    }

    /// A finite focal readout; non-finite — or implausibly large — input shows a
    /// dash rather than trapping on `Int(_:)`.
    private var readout: String {
        guard millimeters.isFinite, millimeters > 0, millimeters < 1_000_000 else { return "—" }
        return "\(Int(millimeters.rounded()))mm"
    }
}

/// Pure tick math for the in-frame vertical zoom ruler.
///
/// The rail's pixels are a log scale: `FocalLengthRulerScale.offset` is
/// `log2(mm / selected) * 128`, so tick *values* may span the whole controlled
/// range (13 mm…1536 mm on a telephoto) while only a few land inside the granted
/// column. This type publishes the finite, bounded value arrays the view draws.
///
/// Everything here is bounded by construction: the arrays are assembled from a
/// small fixed landmark table plus the two validated range endpoints, never by
/// iterating an unbounded user value, so a runaway display factor can neither
/// trap `Int(_:)` nor grow an array without limit.
enum FrameZoomRulerScale {
    /// Shared pinch landmarks through 400 mm. The controlled ruler also adds
    /// landmarks outside this window when the active lens supports them.
    static let fixedLandmarks: [Double] = CameraFocalZoomPolicy.majorTicks

    /// Nice round focal lengths above the fixed landmarks, for the controlled
    /// range the slow-zoom ramp actually reaches: a 16x telephoto ceiling on the
    /// 96 mm base is 1536 mm, and a 16x wide ceiling on 24 mm is 384 mm. Values
    /// outside the live range are filtered out, so no tick claims an unreachable
    /// focal length.
    static let extendedLandmarks: [Double] = [175, 200, 250, 300, 350, 400,
                                              500, 600, 800, 1000, 1250, 1500]

    /// Hard cap on any generated tick array. The landmark table keeps the real
    /// count far below this; the cap is a measured guard against an unexpectedly
    /// wide (but finite) range.
    static let maximumTickCount = 128

    /// The window the ruler should draw.
    ///
    /// A valid available range is used as-is. Otherwise the ruler falls back to
    /// the fixed pinch landmarks, and — for a finite current value beyond that
    /// fixed window — to a bounded neighbourhood of it, so the readout never
    /// renders an empty rail.
    static func resolvedRange(currentMM: Double, available: ClosedRange<Double>?) -> ClosedRange<Double> {
        if let available, isUsable(available) { return available }
        guard currentMM.isFinite, currentMM > 0, currentMM < 1_000_000 else { return fixedLower...fixedUpper }
        if currentMM <= fixedUpper { return fixedLower...fixedUpper }
        return max(fixedUpper, currentMM / 2)...(currentMM * 2)
    }

    /// The marked, labelled landmarks inside `range`, plus both exact endpoints,
    /// sorted and de-duplicated. Endpoints are always present so a non-round
    /// ceiling (e.g. a 384 mm or 1536 mm maximum) is still marked and readable.
    static func majorTicks(in range: ClosedRange<Double>) -> [Double] {
        guard isUsable(range) else { return fixedLandmarks }
        let lower = range.lowerBound
        let upper = range.upperBound
        var ticks: [Double] = []
        for value in fixedLandmarks where value > lower && value < upper { ticks.append(value) }
        for value in extendedLandmarks where value > lower && value < upper { ticks.append(value) }
        ticks.append(lower)
        ticks.append(upper)
        return dedupedAndCapped(ticks.sorted())
    }

    /// Minor ticks between the landmarks. The step is chosen from the span so a
    /// 13…150 pinch rail keeps its familiar 5 mm minors while a controlled range
    /// coarsens to 10 or 25 mm, which keeps the log-spaced marks legible. Major
    /// landmarks are excluded (the view draws those). Bounded: the step never
    /// produces more than `maximumTickCount * 4` candidates, and an implausibly
    /// wide range falls back to the major landmarks alone.
    static func minorTicks(in range: ClosedRange<Double>) -> [Double] {
        guard isUsable(range) else { return [] }
        let lower = range.lowerBound
        let upper = range.upperBound
        let span = upper - lower
        let step: Double = span <= 150 ? 5 : (span <= 400 ? 10 : 25)
        guard step > 0 else { return [] }
        // Compare in `Double` before converting: a huge but finite span must not
        // overflow `Int(_:)`.
        let ratio = span / step
        guard ratio.isFinite, ratio <= Double(maximumTickCount * 4) else {
            return majorTicks(in: range)
        }
        let candidateCount = Int(ratio.rounded(.down)) + 2
        guard candidateCount > 0, candidateCount <= maximumTickCount * 4 else {
            return majorTicks(in: range)
        }
        let majorKeys = Set(majorTicks(in: range).map(quantized))
        var ticks: [Double] = []
        let start = (lower / step).rounded(.up) * step
        for index in 0..<candidateCount {
            let value = start + Double(index) * step
            guard value.isFinite, value <= upper + 0.0001 else { break }
            if let last = ticks.last, value <= last { continue }
            if !majorKeys.contains(quantized(value)) { ticks.append(value) }
            if ticks.count >= maximumTickCount { break }
        }
        return ticks
    }

    /// The major ticks whose text labels are at least `minimumGapPoints` apart on
    /// the log rail, so adjacent readouts (e.g. 350, 384, 400) cannot collide.
    /// The first and last ticks — the range endpoints — are always kept; a
    /// crowded interior label is dropped in preference to the endpoint.
    static func labelledTicks(_ ticks: [Double], minimumGapPoints: Double = 20) -> [Double] {
        guard ticks.count > 1 else { return ticks }
        var kept: [Double] = [ticks[0]]
        for tick in ticks.dropFirst() {
            if let last = kept.last, pixelGap(from: last, to: tick) >= minimumGapPoints {
                kept.append(tick)
            }
        }
        let endpoint = ticks[ticks.count - 1]
        if kept.last != endpoint {
            while kept.count > 1, let last = kept.last,
                  pixelGap(from: last, to: endpoint) < minimumGapPoints {
                kept.removeLast()
            }
            kept.append(endpoint)
        }
        return kept
    }

    /// The rail's pixel distance between two focal lengths: the magnitude of the
    /// shared log offset (`|log2(a / b)| * 128`). Infinite for unusable input.
    static func pixelGap(from a: Double, to b: Double) -> Double {
        guard a.isFinite, b.isFinite, a > 0, b > 0 else { return .infinity }
        return abs(FocalLengthRulerScale.offset(millimeters: a, selected: b))
    }

    private static let fixedLower: Double = CameraFocalZoomPolicy.minimumFocalLengthMM
    private static let fixedUpper: Double = CameraFocalZoomPolicy.maximumFocalLengthMM

    private static func isUsable(_ range: ClosedRange<Double>) -> Bool {
        range.lowerBound.isFinite && range.upperBound.isFinite
            && range.lowerBound > 0 && range.upperBound >= range.lowerBound
    }

    private static func quantized(_ value: Double) -> Double {
        (value * 1000).rounded()
    }

    private static func dedupedAndCapped(_ sorted: [Double]) -> [Double] {
        var result: [Double] = []
        for value in sorted where value.isFinite {
            if let last = result.last, abs(last - value) < 0.0005 { continue }
            result.append(value)
        }
        guard result.count > maximumTickCount else { return result }
        // Keep the endpoints and thin the interior evenly; never drop a bound.
        let spacing = Double(result.count - 1) / Double(maximumTickCount - 1)
        return (0..<maximumTickCount).map { index in
            result[Int((Double(index) * spacing).rounded())]
        }
    }
}
