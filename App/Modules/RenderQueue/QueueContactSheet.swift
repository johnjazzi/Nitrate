import SwiftUI

/// Pure presentation policy for the compact History contact sheet.
///
/// It owns no queue, render or persistence state: it answers how many columns a
/// width earns, which receipts the eye toggle shows, and how many cells the
/// compact detent exposes. The queue's FIFO/render order is never touched here —
/// history is only ever re-read newest-first for display.
enum QueueContactSheetLayout {
    /// The collapsed sheet: roughly a third of the screen, drag handle visible.
    static let compactFraction: CGFloat = 0.34
    /// Tight, consistent gutters; the poster does the work, not the chrome.
    static let gutter: CGFloat = 0
    static let horizontalPadding: CGFloat = 12
    /// Every receipt is the same normalized 4:3 poster.
    static let cellAspect: CGFloat = 4.0 / 3.0
    /// The narrowest cell the contact sheet accepts before it would clip a
    /// poster; three of these plus gutters still fit a supported phone width.
    static let minimumCellWidth: CGFloat = 92
    static let maximumColumns = 6
    /// Rows the collapsed detent shows before the grid scrolls.
    static let compactRowLimit = 3
    /// The contact sheet never goes below three columns on a supported phone.
    static let minimumColumns = 3

    /// At least three columns on any supported phone width, more when the
    /// width genuinely fits them.
    static func columns(forWidth width: CGFloat) -> Int {
        let usable = max(width - horizontalPadding * 2, 0)
        let fitting = Int((usable + gutter) / (minimumCellWidth + gutter))
        return min(max(fitting, minimumColumns), maximumColumns)
    }

    /// Collapsed shows a couple of rows of the SAME grid; expanded shows all.
    static func visibleCount(total: Int, expanded: Bool, columns: Int) -> Int {
        guard !expanded else { return total }
        return min(total, compactRowLimit * max(columns, minimumColumns))
    }

    static func gridColumns(forWidth width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gutter, alignment: .top),
              count: columns(forWidth: width))
    }
}

/// Which half of the history presentation the eye toggle is showing.
///
/// Presentation only. Hiding a receipt never deletes a job, an original, a
/// retained output, a Photos record or a render recipe.
enum QueueHistoryMode: String, CaseIterable, Sendable {
    case visible
    case hidden

    var showsHidden: Bool { self == .hidden }

    var toggleSymbol: String { self == .hidden ? "eye.slash" : "eye" }

    var accessibilityLabel: String {
        self == .hidden ? "Hidden history" : "Visible history"
    }

    var accessibilityValue: String {
        self == .hidden ? "Showing hidden images" : "Showing visible images"
    }

    var accessibilityHint: String {
        self == .hidden
            ? "Switches to visible history."
            : "Switches to hidden history, where images can be restored."
    }

    func toggled() -> Self { self == .hidden ? .visible : .hidden }

    /// All history by default, newest first, minus whatever the operator hid.
    /// Hidden mode is the same list filtered the other way, so restoring is
    /// possible without a second data path.
    func receipts(_ history: [RenderJob], hiddenIDs: Set<UUID>) -> [RenderJob] {
        let matching = history.filter { hiddenIDs.contains($0.id) == showsHidden }
        return matching.sorted { ($0.receipt?.recordedAt ?? $0.createdAt)
            > ($1.receipt?.recordedAt ?? $1.createdAt) }
    }
}

/// Counts for the compact active-work strip. Pure, so the wording is testable
/// without a rendered view; it never changes a job.
struct QueueActivitySummary {
    let processing: Int
    let queued: Int
    let awaitingStock: Int
    let failed: Int
    let history: Int
    let isPaused: Bool
    let hidden: Int

    init(jobs: [RenderJob], hiddenIDs: Set<UUID>, isPaused: Bool) {
        let finished = jobs.filter { $0.status == .completed || $0.status == .failed }
        processing = jobs.filter { $0.status == .processing }.count
        queued = jobs.filter { $0.status == .pending }.count
        awaitingStock = jobs.filter { $0.status == .awaitingStock }.count
        failed = finished.filter { $0.status == .failed && !hiddenIDs.contains($0.id) }.count
        history = finished.count
        self.isPaused = isPaused
        hidden = finished.filter { hiddenIDs.contains($0.id) }.count
    }

    var isEmpty: Bool { processing + queued + awaitingStock + history == 0 }

    /// One line, no storage prose: work first, then what is on the sheet.
    var text: String {
        var parts: [String] = []
        if isPaused { parts.append("Rendering paused") }
        if processing > 0 { parts.append("Processing") }
        if queued > 0 { parts.append("\(queued) queued") }
        if awaitingStock > 0 { parts.append("\(awaitingStock) awaiting stock") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "Queue needs attention" : parts.joined(separator: " · ")
    }
}

// MARK: - Compact activity strip

/// The collapsed surface's one line of live work. Tapping it is the same
/// expansion the drag handle offers, so the collapsed sheet never hides work
/// behind a gesture the operator has to discover.
struct QueueActivityStrip: View {
    let summary: QueueActivitySummary
    let isExpanded: Bool
    let expand: () -> Void

    @Environment(\.cameraControlAccent) private var accent

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 8) {
                if summary.processing > 0 {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(accent)
                } else if summary.isPaused {
                    Image(systemName: "lock.fill")
                        .font(NitrateTypography.font(.caption2))
                        .foregroundStyle(accent)
                }
                Text(summary.text)
                    .font(NitrateTypography.font(.caption2))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(NitrateTypography.font(.caption2))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, QueueContactSheetLayout.horizontalPadding)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("queue.activitySummary")
        .accessibilityLabel(summary.text)
        .accessibilityHint(isExpanded ? "Collapses History." : "Expands History to show queue details.")
    }
}
