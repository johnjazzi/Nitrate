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

// MARK: - Receipt action wells

/// The single receipt's actions: a compact square 2×2 of wells with a corner
/// close. It is drawn inside the History sheet rather than presented as a second
/// sheet, so the queue behind it never has to be dismissed for a child sheet to
/// open — the sheet's owner clears this overlay before routing.
struct QueueReceiptActionOverlay: View {
    let job: RenderJob
    let isHidden: Bool
    let canRedevelop: Bool
    let canPreview: Bool
    var onShare: (() -> Void)? = nil
    var onOpenPhotos: (() -> Void)? = nil
    let onRedevelop: () -> Void
    let onMetadata: () -> Void
    let onPreview: () -> Void
    let onToggleHidden: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                header
                wells
            }
            .padding(14)
            .frame(maxWidth: 340)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .padding(20)
        }
        .accessibilityIdentifier("queue.receiptActions")
        .transition(.opacity)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.receiptTitle)
                    .font(NitrateTypography.font(.caption))
                    .lineLimit(2)
                Text(dateLine)
                    .font(NitrateTypography.font(.caption2))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let onShare {
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .font(NitrateTypography.font(.caption))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share image")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(NitrateTypography.font(.caption))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close image actions")
            .accessibilityIdentifier("queue.receiptActions.close")
        }
    }

    private var wells: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
            if job.presentsAsPhoto {
                well("Re-develop", symbol: "arrow.counterclockwise",
                     enabled: canRedevelop,
                     unavailableHint: "The retained original is no longer available.",
                     hint: "Returns the original to Develop for preview, gauge and push/pull before rendering.",
                     identifier: "queue.redevelopPhoto",
                     action: onRedevelop)
            } else {
                well("Photos", symbol: "photo.on.rectangle",
                     enabled: onOpenPhotos != nil,
                     unavailableHint: "Photos cannot be opened.",
                     hint: "Opens Photos generally. Find the saved video in Recently Saved.",
                     identifier: QueueReceiptPresentation.photosActionID + ".video",
                     action: { onOpenPhotos?() })
            }
            well("Metadata", symbol: "info.circle",
                 enabled: true,
                 unavailableHint: "",
                 hint: "Shows the image metadata for \(job.receiptTitle).",
                 identifier: QueueReceiptPresentation.metadataActionID,
                 action: onMetadata)
            well("Preview", symbol: job.presentsAsPhoto ? "photo" : "play.circle",
                 enabled: canPreview,
                 unavailableHint: "The local rendered copy is no longer available.",
                 hint: "Opens the local rendered copy, not Photos.",
                 identifier: "queue.localPreview",
                 action: onPreview)
            well(isHidden ? "Show" : "Hide",
                 symbol: isHidden ? "eye" : "eye.slash",
                 enabled: true,
                 unavailableHint: "",
                 hint: isHidden
                     ? "Restores this image to the visible history. Nothing is deleted."
                     : "Removes this image from the visible history but keeps it in the queue.",
                 identifier: isHidden ? "queue.historyShow" : "queue.historyHide",
                 action: onToggleHidden)
        }
    }

    private func well(_ title: String, symbol: String, enabled: Bool,
                      unavailableHint: String, hint: String,
                      identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: symbol)
                            .font(NitrateTypography.font(.title3))
                        Text(title)
                            .font(NitrateTypography.font(.caption2))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.55))
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill)))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(enabled ? title : "\(title) unavailable")
        .accessibilityHint(enabled ? hint : unavailableHint)
        .accessibilityIdentifier(identifier)
    }

    private var dateLine: String {
        (job.receipt?.recordedAt ?? job.createdAt)
            .formatted(date: .abbreviated, time: .shortened)
    }
}
