import SwiftUI
import UIKit
import AVKit

/// The History surface: one compact contact sheet over the camera, a live work
/// strip, and the queue's existing details behind the drag handle.
///
/// It owns no queue state. `viewModel` remains the single owner of jobs,
/// outstanding work and status; `historyVisibility` is the presentation store the
/// coordinator reconciles, and this sheet only reads and toggles it. Every
/// destructive or rendering action routes to an existing owner — retry, stock
/// assignment, removal, Photos, share, and the shared Develop review.

struct QueueSheetView: View {
    @State var viewModel: RenderQueueViewModel
    let cameraViewModel: CameraViewModel
    @Binding var isPresented: Bool
    /// Load one finished develop back into the Develop panel, at step one, with
    /// the gauge and push/pull controls — the operator picks a new look there.
    var onRedevelop: (RenderJob) -> Void = { _ in }
    /// Load several originals for review; this action never starts a render.
    var onBulkRedevelop: (Set<UUID>) -> Void = { _ in }
    @State private var selection: Set<UUID> = []
    @State private var isSelecting = false
    /// Presentation filter only: visible history by default, hidden on the eye.
    @State private var historyMode: QueueHistoryMode = .visible
    /// The one receipt whose action wells are open, drawn inside this sheet.
    @State private var selectedJobID: UUID?
    @State private var shareTarget: RenderJob?
    @State private var playbackJob: RenderJob?
    @State private var metadataJob: RenderJob?
    @State private var photosOpenFailed = false
    @State private var showsStorage = false
    @State private var queueNotice: String?
    @State private var detent: PresentationDetent =
        .fraction(QueueContactSheetLayout.compactFraction)
    @State private var contentWidth: CGFloat = 0

    // MARK: - Derived presentation

    private var hiddenIDs: Set<UUID> { viewModel.historyVisibility.hiddenIDs }
    private var isExpanded: Bool { detent == .large }
    private var columns: Int { QueueContactSheetLayout.columns(forWidth: contentWidth) }
    /// All history, newest first. No Latest/Earlier split: one sheet, one grid.
    private var historyReceipts: [RenderJob] {
        historyMode.receipts(viewModel.historyJobs, hiddenIDs: hiddenIDs)
    }
    private var shownReceipts: [RenderJob] {
        let count = QueueContactSheetLayout.visibleCount(total: historyReceipts.count,
                                                        expanded: isExpanded,
                                                        columns: columns)
        return Array(historyReceipts.prefix(count))
    }
    private var pendingJobs: [RenderJob] {
        viewModel.outstandingJobs.filter { $0.status == .pending }
    }
    private var processingJob: RenderJob? {
        viewModel.outstandingJobs.first { $0.status == .processing }
    }
    private var summary: QueueActivitySummary {
        QueueActivitySummary(jobs: viewModel.jobs, hiddenIDs: hiddenIDs,
                             isPaused: viewModel.isRenderPausedForAccess)
    }
    private var selectedJob: RenderJob? {
        selectedJobID.flatMap { id in viewModel.jobs.first { $0.id == id } }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            surface
            if let job = selectedJob {
                QueueReceiptActionOverlay(
                    job: job,
                    isHidden: hiddenIDs.contains(job.id),
                    canRedevelop: canReviewOriginal(job),
                    canPreview: canPreviewLocally(job),
                    onRedevelop: { redevelop(job) },
                    onMetadata: { showMetadata(job) },
                    onPreview: { previewLocally(job) },
                    onToggleHidden: { toggleHidden(job) },
                    onClose: { closeOverlay() }
                )
                .zIndex(1)
            }
        }
        // Compact third of the screen by default; the drag handle (and the work
        // strip) reveal more rows of the same grid plus the full queue details.
        .presentationDetents([.fraction(QueueContactSheetLayout.compactFraction), .large],
                             selection: $detent)
        .presentationDragIndicator(.visible)
        .onAppear { cameraViewModel.updateFreeSpace() }
    }

    private var surface: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    QueueActivityStrip(summary: summary, isExpanded: isExpanded,
                                       expand: toggleExpansion)
                    if isExpanded { notices }
                    if isExpanded { workSections }
                    historySection
                    if isExpanded { footer }
                }
                .padding(.bottom, isSelecting && !selection.isEmpty ? 76 : 16)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    contentWidth = width
                }
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) { bulkActionBar }
        .sheet(item: $shareTarget) { job in
            if job.isImportedVideo != true, let url = job.retainedOutputURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(item: $playbackJob) { job in
            if job.isImportedVideo != true, let url = job.retainedOutputURL {
                if job.isPhoto == true {
                    PhotoPreviewSheet(url: url, title: job.receiptTitle)
                } else {
                    VideoPreviewSheet(url: url, title: job.receiptTitle, iso: job.iso)
                }
            }
        }
        .sheet(item: $metadataJob) { job in
            QueueReceiptMetadataView(job: job)
                .labelStyle(.titleAndIcon)
        }
        .sheet(isPresented: $showsStorage) {
            NavigationStack {
                CameraStorageSummary(
                    freeSpaceBytes: cameraViewModel.hasStorageSnapshot ? cameraViewModel.freeSpaceBytes : nil,
                    totalSpaceBytes: cameraViewModel.hasStorageSnapshot ? cameraViewModel.totalSpaceBytes : nil,
                    estimatedSeconds: estimatedRemainingSeconds
                )
                .padding()
                .navigationTitle("Storage")
                .toolbar {
                    Button { showsStorage = false } label: {
                        Label("Done", systemImage: "xmark").labelStyle(.iconOnly)
                    }
                }
            }
            .labelStyle(.titleAndIcon)
            .presentationDetents([.medium])
        }
        .alert("Details", isPresented: Binding(
            get: { queueNotice != nil }, set: { if !$0 { queueNotice = nil } }
        )) {
            Button("OK", role: .cancel) { queueNotice = nil }
        } message: {
            Text(queueNotice ?? "")
        }
        .alert("Could not open Photos", isPresented: $photosOpenFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(PhotosLibraryOpener.failureMessage)
        }
    }

    // MARK: - Header

    /// HISTORY on the left; eye toggle and Photos on the right, one row. No
    /// desktop toolbar, no storage copy.
    private var header: some View {
        HStack(spacing: 2) {
            Text("HISTORY")
                .font(NitrateTypography.font(.caption))
                .tracking(1.6)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if isExpanded, historyReceipts.contains(where: canReviewOriginal) || isSelecting {
                selectionControl
            }
            visibilityToggle
            photosAction
        }
        .padding(.horizontal, QueueContactSheetLayout.horizontalPadding)
        .frame(minHeight: 44)
    }

    private var visibilityToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { historyMode = historyMode.toggled() }
        } label: {
            Label(historyMode.accessibilityLabel, systemImage: historyMode.toggleSymbol)
                .labelStyle(.iconOnly)
                .font(NitrateTypography.font(.subheadline))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("queue.historyVisibility")
        .accessibilityLabel(historyMode.accessibilityLabel)
        .accessibilityValue(historyMode.accessibilityValue)
        .accessibilityHint(historyMode.accessibilityHint)
    }

    private var photosAction: some View {
        Button(action: openPhotos) {
            Label("Photos", systemImage: "photo.on.rectangle")
                .labelStyle(.iconOnly)
                .font(NitrateTypography.font(.subheadline))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Photos")
        .accessibilityHint("Opens Photos generally, not this specific render. Look in Recently Saved.")
        .accessibilityIdentifier(QueueReceiptPresentation.photosActionID + ".general")
    }

    @ViewBuilder private var selectionControl: some View {
        if isSelecting {
            Button {
                isSelecting = false
                selection.removeAll()
            } label: {
                Label("Cancel selection", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
                    .font(NitrateTypography.font(.subheadline))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("queue.selectCancel")
        } else {
            Button { isSelecting = true } label: {
                Label("Select", systemImage: "checkmark.circle")
                    .labelStyle(.iconOnly)
                    .font(NitrateTypography.font(.subheadline))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("queue.select")
        }
    }

    // MARK: - Notices (expanded only)

    @ViewBuilder private var notices: some View {
        if viewModel.isRenderPausedForAccess {
            noticeRow(symbol: "lock.fill", title: "Rendering paused",
                      detail: "Needs an active subscription. Originals are kept.") {
                queueNotice = "Rendering needs an active subscription. Your originals are kept."
            }
        }
        if viewModel.isPersistenceBlocked {
            HStack(spacing: 4) {
                Button { viewModel.resume() } label: {
                    Label("Resume queue", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Resume queue")
                Button {
                    queueNotice = "The queue could not save a change. Existing media is kept; free space if needed, then resume."
                } label: {
                    Label("Queue save problem", systemImage: "exclamationmark.triangle")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Queue save problem")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, QueueContactSheetLayout.horizontalPadding)
        }
    }

    private func noticeRow(symbol: String, title: String, detail: String,
                           explain: @escaping () -> Void) -> some View {
        Button(action: explain) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(NitrateTypography.font(.caption))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(NitrateTypography.font(.caption2))
                    Text(detail)
                        .font(NitrateTypography.font(.caption2))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "info.circle")
                    .font(NitrateTypography.font(.caption2))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill)))
            .padding(.horizontal, QueueContactSheetLayout.horizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityHint("Explains what is needed.")
    }

    // MARK: - Work sections (expanded only)

    private var workSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.awaitingStockJobs.isEmpty {
                sectionHeader("Choose stock")
                ForEach(viewModel.awaitingStockJobs) { job in
                    HStack(spacing: 4) {
                        JobRow(job: job, onDetails: { metadataJob = job })
                        chooseStockMenu(for: job)
                        Button {
                            viewModel.exportOriginal(jobId: job.id)
                        } label: {
                            Label("Save original", systemImage: "square.and.arrow.down")
                                .labelStyle(.iconOnly)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Save original")
                    }
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill)))
                    .padding(.horizontal, QueueContactSheetLayout.horizontalPadding)
                }
            }
            if let processingJob {
                sectionHeader("Processing")
                HStack {
                    JobRow(job: processingJob, isCurrent: true,
                           onDetails: { metadataJob = processingJob })
                }
                .padding(.horizontal, QueueContactSheetLayout.horizontalPadding)
            }
            if !pendingJobs.isEmpty {
                sectionHeader("Queued")
                ForEach(pendingJobs) { job in
                    HStack {
                        JobRow(job: job, onDetails: { metadataJob = job })
                        Button(role: .destructive) {
                            viewModel.remove(jobId: job.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                                .labelStyle(.iconOnly)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 4)
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.remove(jobId: job.id)
                        } label: {
                            Label("Remove from queue", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(NitrateTypography.font(.caption2))
            .tracking(1.2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, QueueContactSheetLayout.horizontalPadding)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - History grid

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if historyMode == .hidden {
                sectionHeader("Hidden receipts")
            }
            if historyReceipts.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: QueueContactSheetLayout.gridColumns(forWidth: contentWidth),
                          spacing: QueueContactSheetLayout.gutter) {
                    ForEach(shownReceipts) { job in
                        receiptCell(job)
                    }
                }
                .padding(.horizontal, QueueContactSheetLayout.horizontalPadding)
                if !isExpanded, historyReceipts.count > shownReceipts.count {
                    Button(action: expand) {
                        Text("\(historyReceipts.count - shownReceipts.count) more")
                            .font(NitrateTypography.font(.caption2))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("queue.historyMore")
                    .accessibilityLabel("\(historyReceipts.count - shownReceipts.count) more receipts")
                    .accessibilityHint("Expands History to show every receipt.")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: historyMode == .hidden ? "eye.slash" : "tray")
                .font(NitrateTypography.font(.title2))
            Text(historyMode == .hidden ? "Nothing hidden" : "No history")
                .font(NitrateTypography.font(.caption2))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 110)
        .accessibilityElement(children: .combine)
    }

    /// One contact-sheet cell: the shared receipt card in its poster layout. A
    /// tap opens the action wells; in selection mode it toggles the bulk choice
    /// instead, so the card never nests a second button.
    private func receiptCell(_ job: RenderJob) -> some View {
        let isHidden = hiddenIDs.contains(job.id)
        let isSelected = selection.contains(job.id)

        return Button {
            if isSelecting, canReviewOriginal(job) {
                toggleSelection(job)
            } else {
                openActions(for: job)
            }
        } label: {
            QueueReceiptCard(job: job, openPhotos: openPhotos,
                             showMetadata: { metadataJob = job },
                             playLocal: { previewLocally(job) },
                             shareLocal: { shareVideo(job) },
                             redevelop: canReviewOriginal(job) ? { onRedevelop(job) } : nil,
                             contactSheet: true)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if isHidden {
                Image(systemName: "eye.slash")
                    .font(NitrateTypography.font(.caption2))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSelecting, canReviewOriginal(job) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(NitrateTypography.font(.title3))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .contextMenu { receiptMenu(job) }
        .accessibilityLabel(cellLabel(job))
        .accessibilityValue(cellValue(job))
        .accessibilityHint("Opens Re-develop, Metadata, Preview and Hide.")
    }

    @ViewBuilder private func receiptMenu(_ job: RenderJob) -> some View {
        if job.receiptActions.shareLocal {
            Button { shareVideo(job) } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Button { metadataJob = job } label: {
            Label("Metadata", systemImage: "info.circle")
        }
        if canPreviewLocally(job) {
            Button { previewLocally(job) } label: {
                Label(job.isPhoto == true ? "Preview" : "Play", systemImage: "play.circle")
            }
        }
        if canReviewOriginal(job) {
            Button { onRedevelop(job) } label: {
                Label("Re-develop", systemImage: "arrow.counterclockwise")
            }
        }
        Button { toggleHidden(job) } label: {
            Label(hiddenIDs.contains(job.id) ? "Show in history" : "Hide from history",
                  systemImage: hiddenIDs.contains(job.id) ? "eye" : "eye.slash")
        }
    }

    // MARK: - Expanded footer

    private var footer: some View {
        HStack(spacing: 4) {
            Button { showsStorage = true } label: {
                Label("Storage", systemImage: "internaldrive")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Storage")
            Spacer(minLength: 0)
            Button(action: collapse) {
                Label("Collapse", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse History")
            .accessibilityIdentifier("queue.collapse")
        }
        .padding(.horizontal, QueueContactSheetLayout.horizontalPadding)
    }

    // MARK: - Bulk action

    @ViewBuilder private var bulkActionBar: some View {
        if isSelecting, !selection.isEmpty {
            Button {
                onBulkRedevelop(selection)
                isSelecting = false
                selection.removeAll()
            } label: {
                Label("Re-develop \(selection.count)", systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly)
                    .font(NitrateTypography.font(.title2))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityLabel("Re-develop \(selection.count) originals")
            .accessibilityHint("Returns the selected originals to Develop. Nothing renders until you ask.")
            .accessibilityIdentifier("queue.bulkRedevelop")
        }
    }

    private var estimatedRemainingSeconds: TimeInterval? {
        guard cameraViewModel.hasStorageSnapshot else { return nil }
        return CameraStorageEstimatePolicy.remainingSeconds(
            freeBytes: cameraViewModel.freeSpaceBytes,
            criticalReserveBytes: CameraViewModel.criticalSpaceThreshold,
            videoBitRate: DeliverySettings.averageBitRate,
            audioBitRate: DeliverySettings.aacAverageBitRate
        )
    }

    // MARK: - Actions

    private func toggleExpansion() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    private func expand() {
        withAnimation(.easeInOut(duration: 0.22)) { detent = .large }
    }

    private func collapse() {
        withAnimation(.easeInOut(duration: 0.22)) { detent = .fraction(QueueContactSheetLayout.compactFraction) }
    }

    /// The wells need room, so opening them also takes the sheet to its full
    /// detent. The receipt is selected, never re-statused.
    private func openActions(for job: RenderJob) {
        withAnimation(.easeIn(duration: 0.16)) { selectedJobID = job.id }
        if !isExpanded { expand() }
    }

    /// Clear the in-sheet overlay first, then route, so a child sheet or Develop
    /// never asks for a presentation while the overlay is still leaving.
    private func closeOverlay(then next: (() -> Void)? = nil) {
        withAnimation(.easeOut(duration: 0.16)) { selectedJobID = nil }
        guard let next else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            next()
        }
    }

    private func redevelop(_ job: RenderJob) {
        guard canReviewOriginal(job) else { return }
        closeOverlay { onRedevelop(job) }
    }

    private func showMetadata(_ job: RenderJob) {
        closeOverlay { metadataJob = job }
    }

    private func previewLocally(_ job: RenderJob) {
        guard job.isImportedVideo != true, job.retainedOutputURL != nil else { return }
        closeOverlay { playbackJob = job }
    }

    private func canPreviewLocally(_ job: RenderJob) -> Bool {
        job.permitsLocalMedia && job.retainedOutputURL != nil
    }

    /// Hide/show is presentation only: it never removes the job, its original,
    /// its retained output, its Photos state or its render recipe.
    private func toggleHidden(_ job: RenderJob) {
        if hiddenIDs.contains(job.id) {
            viewModel.historyVisibility.show(job.id)
        } else {
            viewModel.historyVisibility.hide(job.id)
        }
        closeOverlay()
    }

    private func toggleSelection(_ job: RenderJob) {
        if selection.contains(job.id) { selection.remove(job.id) } else { selection.insert(job.id) }
    }

    private func chooseStockMenu(for job: RenderJob) -> some View {
        Menu {
            if let stocks = viewModel.library?.videoStocks(), !stocks.isEmpty {
                ForEach(stocks, id: \.stockId) { stock in
                    Button(stock.displayName) {
                        viewModel.assignStock(
                            jobId: job.id,
                            stockId: stock.stockId,
                            iso: stock.defaultISO,
                            gauge: viewModel.library?.lastGauge(for: stock.stockId)
                        )
                    }
                }
            } else {
                Text("No stocks available")
            }
        } label: {
            Label("Choose stock", systemImage: "film")
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Choose stock for \(job.receiptTitle)")
    }

    private func canReviewOriginal(_ job: RenderJob) -> Bool {
        job.originalOnly != true && job.hasRedevelopableSource
            && (job.status == .completed || job.status == .failed)
    }

    private func openPhotos() {
        Task { @MainActor in
            photosOpenFailed = !(await PhotosLibraryOpener.open())
        }
    }

    private func shareVideo(_ job: RenderJob) {
        guard job.isImportedVideo != true, job.retainedOutputURL != nil else { return }
        shareTarget = job
    }

    // MARK: - Spoken receipt

    private func cellLabel(_ job: RenderJob) -> String {
        let kind = job.isPhoto == true ? "Photo" : "Video"
        let hidden = hiddenIDs.contains(job.id) ? ", hidden" : ""
        return "\(job.receiptTitle), \(kind), \(statusWord(job))\(hidden)"
    }

    private func cellValue(_ job: RenderJob) -> String {
        let day = (job.receipt?.recordedAt ?? job.createdAt)
            .formatted(date: .abbreviated, time: .shortened)
        return "\(day), ISO \(QueueReceiptPresentation.number(Double(job.iso)))"
    }

    private func statusWord(_ job: RenderJob) -> String {
        switch job.status {
        case .pending: "Pending"
        case .processing: "Processing"
        case .completed: "Completed"
        case .failed: "Failed"
        case .awaitingStock: "Awaiting stock"
        }
    }
}

// MARK: - Video Preview

/// Plays a rendered clip from the render output directory.
///
/// Playback reads the file on disk rather than the Photos library, because the
/// app only ever requests `.addOnly` Photos access and therefore cannot read
/// its own saves back out.
private struct VideoPreviewSheet: View {
    let url: URL
    let title: String
    let iso: Float

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isMissing = false

    var body: some View {
        NavigationStack {
            Group {
                if isMissing {
                    ContentUnavailableView(
                        "Render Not Found",
                        systemImage: "film.slash",
                        description: Text("This local copy is no longer available. If its save was confirmed, open Photos manually and look in Recently Saved.")
                    )
                } else if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("\(title) · Render ISO \(QueueReceiptPresentation.number(Double(iso)))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            guard FileManager.default.fileExists(atPath: url.path) else {
                isMissing = true
                return
            }
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

// MARK: - Job Row

private struct JobRow: View {
    let job: RenderJob
    var isCurrent = false
    var onDetails: () -> Void = {}

    var body: some View {
        HStack {
            Image(systemName: job.isPhoto == true ? "photo" : "film")
                .font(NitrateTypography.font(.title2))
                .frame(width: 44, height: 44)
            Spacer(minLength: 0)
            statusLabel
            Button(action: onDetails) {
                Label("Details", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
                    .font(NitrateTypography.font(.title2))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(job.receiptTitle)
        .accessibilityValue(job.createdAt.formatted(date: .abbreviated, time: .shortened))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: job.status)
    }

    private var statusLabel: some View {
        Group {
            switch job.status {
            case .pending:
                Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Pending")
            case .processing:
                ProgressView().accessibilityLabel("Processing")
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
            case .awaitingStock:
                Image(systemName: "film").foregroundStyle(.secondary).accessibilityLabel("Awaiting stock")
            }
        }
        .font(NitrateTypography.font(.title3))
        .frame(width: 44, height: 44)
        .id(job.status)
        .transition(.opacity.combined(with: .scale))
    }
}

// MARK: - Share Sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}


/// Local developed JPEG, never a RAW placeholder or a request to read Photos.
private struct PhotoPreviewSheet: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .accessibilityLabel("Rendered photo preview")
                        .accessibilityIdentifier("queue.photoFullPreview")
                } else {
                    ContentUnavailableView("Photo unavailable", systemImage: "photo",
                        description: Text("The local rendered image could not be read."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
