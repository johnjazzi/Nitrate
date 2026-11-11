import SwiftUI

/// Info-only state: deliberately has no selection, gauge, or scroll binding.
struct StockInfoPresentation {
    private(set) var stock: FilmStockConfig?
    private(set) var feedbackTrigger = 0

    mutating func present(_ stock: FilmStockConfig) {
        self.stock = stock
        feedbackTrigger += 1
    }

    mutating func dismiss() {
        stock = nil
    }
}

extension FilmStockConfig {
    var stockInfoBalance: String { lightType == "D" ? "Daylight" : "Tungsten" }

    var stockInfoMetadata: String {
        "ISO \(defaultISO.formatted(.number.precision(.fractionLength(0)))) · \(stockInfoBalance)"
    }

    var stockInfoDescription: String {
        if let description = stockDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }
        return "\(displayName) is configured for ISO \(defaultISO.formatted(.number.precision(.fractionLength(0)))) "
            + "with \(stockInfoBalance.lowercased()) white balance."
    }
}

struct StockInfoView: View {
    let stock: FilmStockConfig
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .font(NitrateTypography.font(.body).weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(Color.white.opacity(0.10), in: Capsule())
            }
            ScrollView {
                StockInfoContent(stock: stock)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .foregroundStyle(.white)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The production sheet's readable content, separate from the native scroll host
/// so host ImageRenderer tests can exercise the actual text and chrome.
struct StockInfoContent: View {
    let stock: FilmStockConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(stock.displayName)
                .font(NitrateTypography.font(.title2).weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text(stock.stockInfoMetadata)
                .font(NitrateTypography.font(.subheadline))
                .foregroundStyle(.white.opacity(0.7))
            Text(stock.stockInfoDescription)
                .font(NitrateTypography.font(.body))
                .foregroundStyle(.white.opacity(0.9))
                .lineSpacing(4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
