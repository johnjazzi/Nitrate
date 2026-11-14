import CoreGraphics
import Foundation

/// Layout contract for the stock picker's two height states.
///
/// The picker is CONTENT, not a sheet. Collapsed it stacks three quiet rows — a
/// strip of coloured stock chips, the selected stock's name and metadata, then
/// the print gauge and the push/pull pill side by side. At the compact content
/// width (320pt, a 340–380pt detent minus its padding) the whole stack is 214pt,
/// so it sits inside a short detent without a scroll view.
///
/// Expanded, the same stack stays exactly as it is and the stock sample preview
/// is added above it, taking the height that is left over — never a share of the
/// sheet, so a taller sheet grows the preview and not the controls.
///
/// Kept free of SwiftUI so the split can be checked at every phone width
/// without rendering — and so the file still compiles into the macOS render
/// target, which globs this directory.
enum CompactStockPickerLayout {
    /// Content width the layout is designed against: a 340–380pt detent minus
    /// the sheet's own horizontal padding.
    static let compactContentWidth: CGFloat = 320

    /// Gap between the three stacked rows.
    static let rowSpacing: CGFloat = 10

    // MARK: - Stock chips

    /// Height of the chip strip. A 44pt film face plus two caption lines and
    /// its padding; the view scales this with Dynamic Type rather than clipping.
    static let stockRowHeight: CGFloat = 100
    /// One chip: the duotone face centred over the stock name.
    static let stockChipWidth: CGFloat = 94
    static let stockChipSpacing: CGFloat = 8
    static let chipCornerRadius: CGFloat = 10

    /// Width three shipped video stocks occupy in the strip. Narrower than the
    /// compact content width, so the full catalogue is visible without a swipe
    /// and the strip only scrolls when the catalogue actually grows.
    static func stockRowWidth(stockCount: Int) -> CGFloat {
        guard stockCount > 0 else { return 0 }
        return CGFloat(stockCount) * stockChipWidth
            + CGFloat(stockCount - 1) * stockChipSpacing
    }

    // MARK: - Selected stock

    /// One headline line: the selected stock's name, with its ISO and light
    /// type trailing. Never wraps, so the row cannot push the controls down.
    static let nameRowHeight: CGFloat = 24

    // MARK: - Gauge + push/pull

    /// Gap between the gauge and the pill.
    static let controlSpacing: CGFloat = 10
    /// The gauge takes the larger share: four segments have to stay legible.
    /// Capped so it does not stretch into a wall of segments on a wide detent.
    static let preferredGaugeWidth: CGFloat = 200
    /// Four segments at ~38pt still read "16".
    static let minimumGaugeWidth: CGFloat = 152
    /// The pill is one short reading, pinned so it never widens with its word.
    static let pushPullWidth: CGFloat = 74
    /// Caption plus the 48pt enlarged control, for both cells.
    static let controlHeight: CGFloat = 70

    struct ControlWidths: Equatable {
        var gauge: CGFloat
        var pushPull: CGFloat
        /// What the two cells plus their gap occupy.
        var total: CGFloat
    }

    /// Split `width` into the gauge and the pill. Mirrors the view, which lets
    /// the gauge flex up to `preferredGaugeWidth`, pins the pill to
    /// `pushPullWidth` and spaces them by `controlSpacing`: the gauge gives
    /// ground first, the pill never does.
    ///
    /// Below `minimumGaugeWidth + pushPullWidth + controlSpacing` (236pt) the
    /// row is wider than its content area; that only happens on a detent
    /// narrower than any phone, where the vertical Dynamic Type fallback is
    /// already in play.
    static func controlWidths(forContentWidth width: CGFloat) -> ControlWidths {
        let width = width.isFinite ? width : compactContentWidth
        let gauge = min(max(width - pushPullWidth - controlSpacing, minimumGaugeWidth),
                        preferredGaugeWidth)
        return ControlWidths(gauge: gauge,
                             pushPull: pushPullWidth,
                             total: gauge + pushPullWidth + controlSpacing)
    }

    // MARK: - Heights

    /// The three rows plus their two gaps, at default text size.
    static var sideBySideContentHeight: CGFloat {
        stockRowHeight + rowSpacing + nameRowHeight + rowSpacing + controlHeight
    }

    /// The Dynamic Type fallback: the gauge and the pill stacked, each full
    /// width. Taller than a compact detent on purpose — that content is read
    /// inside a scroll view rather than clipped.
    static var stackedContentHeight: CGFloat {
        stockRowHeight + rowSpacing + nameRowHeight + rowSpacing
            + controlHeight + controlSpacing + controlHeight
    }

    /// The most the side-by-side content may occupy and still fit a compact
    /// detent without scrolling.
    static let maximumContentHeight: CGFloat = 260

    // MARK: - Expanded state

    /// The sample preview's own height at default type: the plate row (375) plus
    /// its page dots and two-line disclaimer, with a little slack. The expanded
    /// picker gives the preview this much or more, so the plate is never cropped
    /// into a sliver; when the sheet has less room than this plus the controls,
    /// the whole picker scrolls instead of either cropping a control or
    /// squeezing the plate.
    static let preferredPreviewHeight: CGFloat = 448

    /// The expanded split: the preview takes everything left once the caller's
    /// reserved control stack is taken out. The reservation is an ESTIMATE of
    /// the stack at the current text size, not a measurement — it exists to
    /// allocate the preview, and `fits` only reports whether that allocation
    /// reached `preferredPreviewHeight`. It is not a clipping guarantee: the
    /// expanded view always scrolls, so a stack that grows past the estimate
    /// stays reachable instead of being cropped.
    static func expandedPreview(forAvailableHeight height: CGFloat,
                                reservedContentHeight: CGFloat) -> (height: CGFloat, fits: Bool) {
        let remaining = height - reservedContentHeight - rowSpacing
        return (height: max(remaining, preferredPreviewHeight),
                fits: remaining >= preferredPreviewHeight)
    }
}

#if os(iOS)
import SwiftUI

/// The stock picker, as content only, in two height states of one component.
///
/// Collapsed it is the minimal camera's short picker: a strip of coloured stock
/// chips, the selected stock's name, then the enlarged print gauge and push/pull
/// pill side by side. Expanded — the sheet's large detent — the SAME stack gains
/// the stock sample preview above it and nothing else changes: same chips, same
/// name, same two controls, same selection. Collapsing takes the preview away
/// without touching the selection, the gauge, the push/pull rung or Auto.
///
/// It owns no state. The stock list, the selected id, the gauge and the
/// push/pull preference all belong to the parent sheet (`StockSheetView`), which
/// keeps the single selection / persistence / render path: a chip tap writes
/// `selectedStockId` and nothing else, and the parent's existing `select` routes
/// it to the remembered gauge, ISO and push/pull. Gauge and push/pull are the
/// shared `GaugeControl` and `PushPullControl` — not copies of them — so the
/// ladder, the Auto state and the accessibility contract exist once.
///
/// Type is the operator's own: at accessibility sizes the controls stop sharing
/// a row and the whole content moves into a scroll view, so nothing is clipped
/// to hold the compact shape.
struct CompactStockPicker: View {
    let stocks: [FilmStockConfig]
    @Binding var selectedStockId: String?
    @Binding var gauge: PrintGauge
    /// The exposure the render will apply, resolved by the parent against the
    /// live meter. Read-only here.
    let resolvedPushPull: PushPullExposure
    @Binding var isAutomatic: Bool
    @Binding var manualStops: PushPullStops
    /// Called after a push/pull change so the parent persists the preference.
    var onPushPullChange: () -> Void
    /// Whether the sheet is at its large detent. It reveals the sample preview
    /// above the same stack; it never adds a second set of controls.
    var expanded = false

    @Environment(\.cameraControlAccent) private var controlAccent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The chip strip grows with the caption it carries, so a large text size
    /// gets a taller chip rather than a clipped name.
    @ScaledMetric(relativeTo: .caption2) private var stockRowHeight: CGFloat =
        CompactStockPickerLayout.stockRowHeight

    private var selectedStock: FilmStockConfig? {
        guard let selectedStockId else { return nil }
        return stocks.first { $0.stockId == selectedStockId }
    }

    var body: some View {
        Group {
            if expanded { expandedContent } else { compactContent }
        }
        .accessibilityIdentifier("stock.compactPicker")
    }

    // MARK: - The two height states

    /// Collapsed: the three quiet rows, no preview, no scroll at default type.
    @ViewBuilder private var compactContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView(.vertical) { controlStack }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
        } else {
            controlStack
        }
    }

    /// Expanded: the selected stock's sample above the same stack, always in a
    /// vertical scroll view so the gauge and the pill stay reachable. The
    /// preview is allocated what the reserved stack leaves over; that
    /// reservation is an ESTIMATE of the stack at the current chip scale, not a
    /// measurement of the laid-out controls, so it never proves they fit. When
    /// larger type grows the real stack past the estimate the content scrolls
    /// rather than cropping a control.
    private var expandedContent: some View {
        GeometryReader { proxy in
            let gap = CompactStockPickerLayout.rowSpacing
            // An estimate used only to size the preview's bounded frame. It
            // makes no claim that the stack fits: the scroll view is what keeps
            // the controls reachable.
            let reserved = stockRowHeight + gap
                + CompactStockPickerLayout.nameRowHeight + gap
                + CompactStockPickerLayout.controlHeight
            let split = CompactStockPickerLayout.expandedPreview(forAvailableHeight: proxy.size.height,
                                                                reservedContentHeight: reserved)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: gap) {
                    preview.frame(height: split.height).clipped()
                    controlStack
                }
                .frame(width: proxy.size.width, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
    }

    /// The selected stock at the live gauge and the resolved push/pull — the
    /// same values the render will apply, read from the parent's one selection.
    private var preview: some View {
        StockSamplePreview(stock: selectedStock,
                           gauge: gauge,
                           pushPullStops: resolvedPushPull.stops.stops)
            .frame(maxWidth: .infinity)
    }

    /// The one stack both states share: chips, selected name, gauge + push/pull.
    private var controlStack: some View {
        VStack(alignment: .leading, spacing: CompactStockPickerLayout.rowSpacing) {
            stockRow
            selectionRow
            controls
        }
    }

    // MARK: - Stock chips

    @ViewBuilder private var stockRow: some View {
        if stocks.isEmpty {
            Text("No stocks available")
                .font(NitrateTypography.font(.footnote))
                .foregroundStyle(.secondary)
                .frame(height: stockRowHeight, alignment: .leading)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: CompactStockPickerLayout.stockChipSpacing) {
                    ForEach(stocks, id: \.stockId) { stock in
                        chip(for: stock)
                    }
                }
                // A hairline of inset so the selected chip's border is not
                // clipped by the scroll view's edge.
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
            .frame(height: stockRowHeight)
        }
    }

    private func chip(for stock: FilmStockConfig) -> some View {
        let isSelected = stock.stockId == selectedStockId
        return Button {
            // The only write this view makes to the selection. The parent
            // resolves it through the existing `select`, which restores the
            // stock's remembered gauge and push/pull.
            selectedStockId = stock.stockId
        } label: {
            CompactStockChip(stock: stock, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("stock.choice.\(stock.stockId)")
        .accessibilityLabel(stock.displayName)
        .accessibilityValue(stock.stockInfoMetadata)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Selected stock

    /// One line: the name in the resolved accent, the stock's own ISO and light
    /// type trailing. Selecting is already said by the chip's border, so the
    /// name does not repeat a checkmark or a second badge.
    private var selectionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(selectedStock?.displayName ?? "Choose a stock")
                .font(NitrateTypography.font(.headline))
                .foregroundStyle(selectedStock == nil ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(controlAccent))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            if let stock = selectedStock {
                Text(stock.stockInfoMetadata)
                    .font(NitrateTypography.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(minHeight: CompactStockPickerLayout.nameRowHeight, alignment: .leading)
    }

    // MARK: - Gauge and push / pull

    @ViewBuilder private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Stacked, full width: at accessibility sizes a shared row would
            // squeeze the gauge's four segments and the pill's reading.
            VStack(alignment: .leading, spacing: CompactStockPickerLayout.controlSpacing) {
                GaugeControl(gauge: $gauge, enlarged: true)
                pushPullControl
            }
        } else {
            HStack(alignment: .bottom, spacing: CompactStockPickerLayout.controlSpacing) {
                GaugeControl(gauge: $gauge, enlarged: true)
                    .frame(maxWidth: CompactStockPickerLayout.preferredGaugeWidth,
                           alignment: .leading)
                pushPullControl
                    .frame(width: CompactStockPickerLayout.pushPullWidth)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The shared pill: the ladder, the Auto rung and the persistence callback
    /// all belong to it, never to this view.
    private var pushPullControl: some View {
        PushPullControl(resolved: resolvedPushPull,
                        isAutomatic: $isAutomatic,
                        manualStops: $manualStops,
                        onChange: onPushPullChange,
                        enlarged: true)
    }
}

/// One stock chip: the shipped duotone face with its ISO and light-type badge
/// over the stock's name, on a flat plate.
///
/// Its only emphasis is the resolved accent on the selected chip's border and
/// plate: the stock's own colours stay untouched, so a tungsten stock does not
/// read as chosen just because the accent happens to be green.
private struct CompactStockChip: View {
    let stock: FilmStockConfig
    let isSelected: Bool

    @Environment(\.cameraControlAccent) private var controlAccent

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CompactStockPickerLayout.chipCornerRadius,
                         style: .continuous)
    }

    var body: some View {
        VStack(spacing: 6) {
            CameraFilmStockFace(primary: stock.primaryColor,
                                secondary: stock.secondaryColor,
                                isoLight: "\(Int(stock.defaultISO))\(stock.lightType)")
                .accessibilityHidden(true)
            Text(stock.displayName)
                .font(NitrateTypography.font(.caption2))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(width: CompactStockPickerLayout.stockChipWidth)
        .frame(maxHeight: .infinity)
        .background(shape.fill(isSelected ? controlAccent.opacity(0.14)
                                         : Color.white.opacity(0.04)))
        .overlay {
            shape.strokeBorder(isSelected ? controlAccent : Color.white.opacity(0.12),
                               lineWidth: isSelected ? 1.5 : 0.5)
        }
        .contentShape(shape)
    }
}
#endif
