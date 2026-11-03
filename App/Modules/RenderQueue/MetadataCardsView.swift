import SwiftUI

/// A compact label-over-value card: one rounded dark group, hairline dividers
/// between rows, and tight row heights.
struct MetadataCardView: View {
    let card: MetadataCard

    /// Card surface, matching the app's dark shell rather than the system's
    /// grouped-background greys, which are too light next to the camera chrome.
    private static let fill = Color(red: 0.173, green: 0.173, blue: 0.184)
    private static let hairline = Color.white.opacity(0.09)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(card.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { divider }
                rowView(row)
            }
            if let notes = card.notes {
                if !card.rows.isEmpty { divider }
                notesView(notes)
            }
        }
        .background(Self.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(Self.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func rowView(_ row: MetadataRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(row.cells) { cell in
                cellView(cell)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func cellView(_ cell: MetadataCell) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.label)
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(cell.value)
                .font(NitrateTypography.font(.body))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cell.label): \(cell.value)")
    }

    private func notesView(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .frame(height: 132)
                .overlay(alignment: .topLeading) {
                    Text(notes)
                        .font(NitrateTypography.font(.body))
                        .foregroundStyle(.primary)
                        .padding(12)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// The metadata sheet's cards, stacked on the dark page the camera uses.
struct MetadataCardsView: View {
    let cards: [MetadataCard]
    /// Collapsed technical record, kept below the cards so the recipe and
    /// delivery evidence stay reachable without crowding the target layout.
    var details: [(label: String, value: String)] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(cards) { MetadataCardView(card: $0) }
                if !details.isEmpty { renderRecord }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var renderRecord: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(details.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(NitrateTypography.font(.caption))
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(NitrateTypography.font(.footnote))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Render record")
                .font(NitrateTypography.font(.footnote))
                .foregroundStyle(.secondary)
        }
        .tint(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 0.173, green: 0.173, blue: 0.184),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
