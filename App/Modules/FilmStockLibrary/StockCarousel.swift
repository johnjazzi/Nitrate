import SwiftUI

/// Pure selection rules for the stock carousel. Kept free of SwiftUI so the
/// open-centering and gauge-restore behaviour can be exercised by unit tests
/// without rendering.
enum StockCarouselSelection {
    /// Stock id the carousel centres when the sheet opens: the persisted
    /// selection when it still exists in the catalogue, otherwise the first
    /// stock. Never invents an id, so an empty catalogue stays empty.
    static func centeredId(onOpen preselected: String?, stocks: [FilmStockConfig]) -> String? {
        if let preselected, stocks.contains(where: { $0.stockId == preselected }) {
            return preselected
        }
        return stocks.first?.stockId
    }

    /// Print gauge to apply after the centred stock changes. Returns the stock's
    /// remembered gauge (or the neutral 35mm reference) only when the selection
    /// actually changes; re-selecting the stock that is already centred returns
    /// nil so the current gauge is left untouched.
    static func gauge(
        onSelecting stockId: String,
        from previousId: String?,
        remembered: PrintGauge?
    ) -> PrintGauge? {
        guard stockId != previousId else { return nil }
        return remembered ?? .thirtyFiveMillimetre
    }
}

/// Centred, snap-to-selected film-stock carousel for the stock sheet. The
/// selected stock sits in the middle at full emphasis with its neighbour peeking
/// at the edges; content margins let the first and last cards reach the centre
/// too. A single page dot under the strip marks the centred stock.
///
/// `selectedStockId` is the parent's stock id and the single source of truth.
/// The carousel owns only the scroll position; when a swipe or tap settles on a
/// new card it writes the id back through the binding, and the parent resolves
/// it. The scroll position and the binding are held equal, so opening with a
/// persisted selection centres that stock immediately, without a first-card
/// flash and without a scroll feedback loop.
struct StockCarousel: View {
    let stocks: [FilmStockConfig]
    @Binding var selectedStockId: String?

    /// Tracks the snap-aligned card; the single source of scroll truth.
    @State private var scrollPosition: String?

    private let cardWidth: CGFloat = 104
    private let cardHeight: CGFloat = 132
    private let cardSpacing: CGFloat = 16

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let sideInset = max(16, (geometry.size.width - cardWidth) / 2)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: cardSpacing) {
                        ForEach(stocks, id: \.stockId) { stock in
                            StockCarouselCard(stock: stock, isSelected: stock.stockId == selectedStockId)
                                .frame(width: cardWidth, height: cardHeight)
                                .onTapGesture { tap(stock.stockId) }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, sideInset, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $scrollPosition, anchor: .center)
                .scrollIndicators(.hidden)
                .background(well)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            .frame(height: cardHeight)

            pageDots
        }
        .sensoryFeedback(.selection, trigger: selectedStockId)
        .onAppear { center(onOpen: selectedStockId) }
        .onChange(of: stocks.map(\.stockId)) { _, _ in center(onOpen: selectedStockId) }
        .onChange(of: scrollPosition) { _, newValue in trip(newValue) }
        .onChange(of: selectedStockId) { _, newValue in follow(newValue) }
    }

    // MARK: - Sequencing

    /// Centre the carousel on the stock the sheet opened with. Compared against
    /// the current binding so a nil-then-populated catalogue still converges on
    /// the persisted selection rather than snapping to the first card.
    private func center(onOpen id: String?) {
        let target = StockCarouselSelection.centeredId(onOpen: id, stocks: stocks)
        guard let target, scrollPosition != target else { return }
        scrollPosition = target
    }

    /// A swipe settled: adopt the aligned card as the new selection. Guarded so
    /// the write-back into `selectedStockId` cannot re-enter and bounce the
    /// scroll position back.
    private func trip(_ alignedId: String?) {
        guard let alignedId,
              alignedId != selectedStockId,
              stocks.contains(where: { $0.stockId == alignedId }) else { return }
        prepareSelectionFeedback()
        selectedStockId = alignedId
    }

    /// The parent changed the selection (e.g. the sheet resolves an initial
    /// value late): follow it once, but only when the scroll has actually drifted
    /// off it, so the two never chase each other.
    private func follow(_ id: String?) {
        guard let id, id != scrollPosition else { return }
        withAnimation(.easeInOut(duration: 0.25)) { scrollPosition = id }
    }

    /// A tap on a card centres it. Tapping the stock that is already centred is a
    /// no-op: it must not recycle the scroll or reset the gauge the sheet holds.
    private func tap(_ stockId: String) {
        guard stockId != selectedStockId else { return }
        prepareSelectionFeedback()
        withAnimation(.easeInOut(duration: 0.25)) { scrollPosition = stockId }
    }

    /// The capture session's active audio route must not silence the control
    /// haptics, so enable that before the sensory-feedback modifier fires. The
    /// opt-in lives in the camera module, which the macOS test target does not
    /// compile — hence the platform gate.
    private func prepareSelectionFeedback() {
        #if os(iOS)
        CameraHaptics.prepareForCaptureFeedback()
        #endif
    }

    // MARK: - Chrome

    private var well: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color.white.opacity(0.05))
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(stocks, id: \.stockId) { stock in
                Circle()
                    .fill(stock.stockId == selectedStockId ? Color.white : Color.white.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A single card in the carousel: a rounded duotone swatch with the stock's
/// label. The centred, selected card is brighter and larger; neighbours dim and
/// shrink so the selection reads at a glance. Uses the stock's own tint
/// metadata only — no shared Mood artwork.
struct StockCarouselCard: View {
    let stock: FilmStockConfig
    let isSelected: Bool

    /// The duotone stripe swatch: five bands, primary at the top and bottom edges with two
    /// dark bands between, so a stock reads as a film canister rather than a flat chip.
    private let bandCount = 5

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    ForEach(0..<bandCount, id: \.self) { index in
                        let isPrimary = index == 0 || index == 1 || index == bandCount - 1
                        (isPrimary ? stock.primaryColor : stock.secondaryColor)
                            .frame(height: geometry.size.height / CGFloat(bandCount))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.white : Color.white.opacity(0.12),
                            lineWidth: isSelected ? 2 : 1)
            }

            HStack(spacing: 4) {
                Text(stock.lightType)
                    .font(NitrateTypography.font(size: 9))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(stock.primaryColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(stock.displayName)
                    .font(NitrateTypography.font(size: 10))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isSelected ? 0.10 : 0.03))
        )
        .scaleEffect(isSelected ? 1.0 : 0.9)
        .opacity(isSelected ? 1.0 : 0.6)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
