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
    @State private var showsFailedOnly = false
    @State private var selectingFailed = false
    @State private var failedSelection: Set<UUID> = []
    /// Presentation filter only: visible history by default, hidden on the eye.
    @State private var historyMode: QueueHistoryMode = .visible
    @State private var shareTarget: RenderJob?
    @State private var previewJobID: UUID?
    @State private var previewFocused = false
    @State private var showsHistoryDeletion = false
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
        let mode: QueueHistoryMode = showsFailedOnly ? .visible : historyMode
        let images = mode.receipts(viewModel.historyJobs, hiddenIDs: hiddenIDs)
        return showsFailedOnly ? images.filter { $0.status == .failed } : images
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

    // MARK: - Body

    var body: some View {
        surface
        // Compact third of the screen by default; the drag handle (and the work
        // strip) reveal more rows of the same grid plus the full queue details.
        .presentationDetents([.fraction(QueueContactSheetLayout.compactFraction), .large],
                             selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(.black)
        .preferredColorScheme(.dark)
        .onChange(of: historyReceipts.map(\.id)) { oldIDs, newIDs in
            // Safety net for every other reason the displayed order changes: the
            // eye toggle, a queue reload, a batch clear. The policy continues the
            // preview to the next surviving row instead of the first one.
            let next = QueuePreviewContinuation.selection(current: previewJobID,
                                                         oldIDs: oldIDs,
                                                         newIDs: newIDs)
            if next != previewJobID { previewJobID = next }
        }
        .onAppear { cameraViewModel.updateFreeSpace() }
    }

    private var surface: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                if previewJobID != nil, isExpanded {
                    inlinePreview
                        .frame(height: previewFocused
                            ? geometry.size.height * 0.72
                            : min(geometry.size.height * 0.48, 420))
                    previewControls
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if isExpanded, !showsFailedOnly { notices }
                        if isExpanded, !showsFailedOnly { workSections }
                        if showsFailedOnly { failedControls }
                        historySection
                        if isExpanded, !showsFailedOnly { footer }
                    }
                    .padding(.bottom, isSelecting && !selection.isEmpty ? 76 : 0)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        contentWidth = width
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { bulkActionBar }
        .sheet(item: $shareTarget) { job in
            if job.isImportedVideo != true, let url = job.retainedOutputURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $showsHistoryDeletion) {
            HistoryDeletionSheet { _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    queueNotice = "Deletion is not enabled yet. No images were deleted."
                }
            }
        }
        .sheet(item: $metadataJob) { job in
            QueueReceiptMetadataView(job: job, retry: job.status == .failed ? {
                metadataJob = nil
                viewModel.retry(jobId: job.id)
            } : nil)
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

    private var inlinePreview: some View {
        let images = historyReceipts
        let index = images.firstIndex { $0.id == previewJobID } ?? 0
        let start = max(index - 1, 0)
        let end = min(index + 2, images.count)
        let activeIDs = Set(images[start..<end].map(\.id))
        return TabView(selection: $previewJobID) {
            ForEach(images) { job in
                HistoryInlinePreview(job: job, isActive: activeIDs.contains(job.id))
                    .tag(Optional(job.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { previewJobID = nil }
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel("Close image preview")
        }
        .accessibilityIdentifier("queue.inlinePreview")
    }

    private var previewControls: some View {
        HStack(spacing: 12) {
            if let job = previewJobID.flatMap({ id in historyReceipts.first { $0.id == id } }) {
                if job.presentsAsPhoto {
                    previewControl("Re-develop", symbol: "arrow.counterclockwise",
                                   enabled: canReviewOriginal(job)) { redevelop(job) }
                } else {
                    previewControl("Open Photos", symbol: "photo.on.rectangle") { openPhotos() }
                }
                Spacer(minLength: 0)
                previewControl("Metadata", symbol: "info.circle") { showMetadata(job) }
                Spacer(minLength: 0)
                if job.presentsAsPhoto {
                    previewControl("Share", symbol: "square.and.arrow.up",
                                   enabled: job.receiptActions.shareLocal) { shareVideo(job) }
                    Spacer(minLength: 0)
                }
                previewControl(hiddenIDs.contains(job.id) ? "Show image" : "Hide image",
                               symbol: hiddenIDs.contains(job.id) ? "eye" : "eye.slash") { toggleHidden(job) }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { previewFocused.toggle() }
                } label: {
                    Image(systemName: previewFocused
                        ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(NitrateTypography.font(.subheadline))
                        .frame(width: 44, height: 44)
                        .background(previewFocused ? Color.white.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel(previewFocused ? "Restore contact sheet" : "Enlarge centered preview")
                .accessibilityValue(previewFocused ? "Large preview" : "Balanced preview and contact sheet")
                .accessibilityIdentifier("queue.previewSizeToggle")
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
        .background(.black)
        .accessibilityIdentifier("queue.previewControls")
    }

    private func previewControl(_ title: String, symbol: String, enabled: Bool = true,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NitrateTypography.font(.title3))
                .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.3))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("IMAGES")
                .font(NitrateTypography.font(.caption))
                .tracking(1.6)
                .padding(.leading, 8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            visibilityToggle
            photosAction
            Button { showsHistoryDeletion = true } label: {
                Image(systemName: "trash")
                    .font(NitrateTypography.font(.subheadline))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete images")
            .accessibilityIdentifier("queue.deleteImages")
        }
        .overlay {
            GeometryReader { geometry in
                Button(action: toggleFailedFilter) {
                    Text(headerStatus)
                    .font(NitrateTypography.font(size: 10))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .frame(width: max(geometry.size.width - 3 * 44 * 2, 0), height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(summary.failed == 0 && !showsFailedOnly)
                .position(x: geometry.size.width / 2, y: 22)
                .accessibilityLabel(showsFailedOnly ? "Show all images" : "Show failed images")
                .accessibilityValue(headerStatus)
                .accessibilityIdentifier("queue.activitySummary")
            }
        }
        .padding(.horizontal, QueueContactSheetLayout.horizontalPadding)
        .frame(height: 44)
        .padding(.top, 4)
        .foregroundStyle(.white)
        .background(Color(white: 0.12))
    }

    private var headerStatus: String {
        var lines: [String] = []
        if summary.failed > 0 || showsFailedOnly { lines.append("\(summary.failed) failed") }
        let total = summary.processing + summary.queued
        if total > 0 { lines.append("\(summary.processing)/\(total) processing") }
        if summary.awaitingStock > 0 { lines.append("\(summary.awaitingStock) awaiting stock") }
        if viewModel.isPersistenceBlocked { lines.append("Queue needs attention") }
        else if summary.isPaused { lines.append("Paused") }
        return lines.joined(separator: " · ")
    }

    private var visibilityToggle: some View {
        Button {
            showsFailedOnly = false
            selectingFailed = false
            failedSelection.removeAll()
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
        VStack(alignment: .leading, spacing: 0) {
            if historyMode == .hidden {
                sectionHeader("Hidden images")
            }
            if historyReceipts.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: QueueContactSheetLayout.gridColumns(forWidth: contentWidth),
                          spacing: QueueContactSheetLayout.gutter) {
                    ForEach(shownReceipts) { job in
                        VStack(spacing: 0) {
                            receiptCell(job)
                            if showsFailedOnly {
                                Text(failedTimestamp(job))
                                    .font(NitrateTypography.font(size: 9))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 6)
                            }
                        }
                    }
                }
                if !isExpanded, historyReceipts.count > shownReceipts.count {
                    Button(action: expand) {
                        Image(systemName: "chevron.up")
                            .font(NitrateTypography.font(.caption2))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("queue.historyMore")
                    .accessibilityLabel("\(historyReceipts.count - shownReceipts.count) more images")
                    .accessibilityHint("Expands History to show every image.")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: historyMode == .hidden ? "eye.slash" : "tray")
                .font(NitrateTypography.font(.title2))
            Text(showsFailedOnly ? "No failed images" : (historyMode == .hidden ? "Nothing hidden" : "No history"))
                .font(NitrateTypography.font(.caption2))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 110)
        .accessibilityElement(children: .combine)
    }

    /// Tap previews (or toggles bulk selection); the native context menu owns
    /// long press and its dismissal, without an expanding action-grid overlay.
    private func receiptCell(_ job: RenderJob) -> some View {
        let isHidden = hiddenIDs.contains(job.id)
        let isSelected = showsFailedOnly && selectingFailed
            ? failedSelection.contains(job.id) : selection.contains(job.id)

        return QueueReceiptCard(job: job, openPhotos: openPhotos,
                                showMetadata: { metadataJob = job },
                                playLocal: { previewLocally(job) },
                                shareLocal: { shareVideo(job) },
                                redevelop: canReviewOriginal(job) ? { onRedevelop(job) } : nil,
                                contactSheet: true)
        .contentShape(Rectangle())
        .onTapGesture {
            if showsFailedOnly, selectingFailed {
                toggleFailedSelection(job.id)
            } else if isSelecting, canReviewOriginal(job) {
                toggleSelection(job)
            } else {
                previewLocally(job)
            }
        }
        .contextMenu { receiptActions(job) }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if showsFailedOnly, selectingFailed { toggleFailedSelection(job.id) }
            else if isSelecting, canReviewOriginal(job) { toggleSelection(job) }
            else { previewLocally(job) }
        }
        .accessibilityActions { receiptActions(job) }
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
            if (showsFailedOnly && selectingFailed) || (isSelecting && canReviewOriginal(job)) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(NitrateTypography.font(.title3))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if previewJobID == job.id {
                Rectangle().strokeBorder(.white.opacity(0.8), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(cellLabel(job))
        .accessibilityValue(cellValue(job))
        .accessibilityHint("Tap to preview. Touch and hold for image actions.")
    }

    // MARK: - Expanded footer

    private var failedControls: some View {
        HStack(spacing: 16) {
            Button(action: toggleFailedFilter) {
                Label("Back", systemImage: "chevron.left")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to all images")
            .accessibilityIdentifier("queue.failedBack")
            Button("Clear all") { clearFailed(Set(historyReceipts.map(\.id))) }
                .disabled(historyReceipts.isEmpty)
                .accessibilityHint("Clears failed images from visible history. Originals and Photos are unchanged.")
            Spacer(minLength: 0)
            if selectingFailed, !failedSelection.isEmpty {
                Button("Clear \(failedSelection.count)") { clearFailed(failedSelection) }
            }
            Button(selectingFailed ? "Done" : "Select") {
                selectingFailed.toggle()
                failedSelection.removeAll()
            }
        }
        .font(NitrateTypography.font(.caption))
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("queue.failedControls")
    }

    private func toggleFailedFilter() {
        previewJobID = nil
        isSelecting = false
        selection.removeAll()
        selectingFailed = false
        failedSelection.removeAll()
        showsFailedOnly.toggle()
        if showsFailedOnly { expand() }
    }

    private func toggleFailedSelection(_ id: UUID) {
        if failedSelection.contains(id) { failedSelection.remove(id) }
        else { failedSelection.insert(id) }
    }

    private func clearFailed(_ ids: Set<UUID>) {
        let currentFailures = Set(viewModel.jobs.filter { $0.status == .failed }.map(\.id))
        let doomed = ids.intersection(currentFailures)
        preparePreviewForRemoval(of: doomed)
        for id in doomed { viewModel.historyVisibility.hide(id) }
        failedSelection.subtract(ids)
    }

    private func failedTimestamp(_ job: RenderJob) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "MM/dd-HH:mm"
        return formatter.string(from: job.receipt?.recordedAt ?? job.createdAt)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if historyReceipts.contains(where: canReviewOriginal) || isSelecting {
                selectionControl
            }
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

    /// The same rows serve the native long-press menu and VoiceOver actions.
    /// They reuse existing owners and retain imported-media permissions.
    @ViewBuilder private func receiptActions(_ job: RenderJob) -> some View {
        Button { previewLocally(job) } label: {
            Label("Preview", systemImage: job.presentsAsPhoto ? "photo" : "play.circle")
        }
        .disabled(!canPreviewLocally(job))
        .accessibilityIdentifier("queue.localPreview")

        if job.presentsAsPhoto {
            Button { redevelop(job) } label: {
                Label("Re-develop", systemImage: "arrow.counterclockwise")
            }
            .disabled(!canReviewOriginal(job))
            .accessibilityIdentifier("queue.redevelopPhoto")
        }

        Button { showMetadata(job) } label: {
            Label("Metadata", systemImage: "info.circle")
        }
        .accessibilityIdentifier(QueueReceiptPresentation.metadataActionID)

        if job.presentsAsPhoto, job.receiptActions.shareLocal {
            Button { shareVideo(job) } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        if !job.presentsAsPhoto {
            Button(action: openPhotos) {
                Label("Open Photos", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier(QueueReceiptPresentation.photosActionID + ".video")
        }
        Button { toggleHidden(job) } label: {
            Label(hiddenIDs.contains(job.id) ? "Show" : "Hide",
                  systemImage: hiddenIDs.contains(job.id) ? "eye" : "eye.slash")
        }
        .accessibilityHint("Changes history visibility only. Originals and Photos are unchanged.")
        .accessibilityIdentifier(hiddenIDs.contains(job.id) ? "queue.historyShow" : "queue.historyHide")
    }

    private func redevelop(_ job: RenderJob) {
        guard canReviewOriginal(job) else { return }
        onRedevelop(job)
    }

    private func showMetadata(_ job: RenderJob) {
        metadataJob = job
    }

    private func previewLocally(_ job: RenderJob) {
        guard historyReceipts.contains(where: { $0.id == job.id }) else { return }
        // A thumbnail is a direct selection, not an animated swipe through every
        // intervening page. Finger swipes retain the pager's native animation.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            previewJobID = job.id
            detent = .large
        }
    }

    private func canPreviewLocally(_ job: RenderJob) -> Bool {
        (job.permitsLocalMedia && job.retainedOutputURL != nil)
            || (job.permitsReceiptPreview && job.receipt?.thumbnailJPEG != nil)
    }

    /// Hide/show is presentation only: it never removes the job, its original,
    /// its retained output, its Photos state or its render recipe.
    private func toggleHidden(_ job: RenderJob) {
        // Choose the successor while the row is still on screen: a pager whose
        // selected page vanishes re-seats itself on the first page, so the
        // continuation has to happen before the removal, not after it.
        preparePreviewForRemoval(of: [job.id])
        if hiddenIDs.contains(job.id) {
            viewModel.historyVisibility.show(job.id)
        } else {
            viewModel.historyVisibility.hide(job.id)
        }
    }

    /// Point the pager at the row that will survive `doomed` leaving the displayed
    /// order, so removing those pages never snaps the preview back to the first
    /// one. The choice itself belongs to `QueuePreviewContinuation`.
    private func preparePreviewForRemoval(of doomed: Set<UUID>) {
        guard previewJobID != nil else { return }
        let displayed = historyReceipts.map(\.id)
        previewJobID = QueuePreviewContinuation.selection(
            current: previewJobID,
            oldIDs: displayed,
            newIDs: displayed.filter { !doomed.contains($0) }
        )
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
        let kind = job.presentsAsPhoto ? "Photo" : "Video"
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

// MARK: - Job Row

private struct JobRow: View {
    let job: RenderJob
    var isCurrent = false
    var onDetails: () -> Void = {}

    var body: some View {
        HStack {
            Image(systemName: job.presentsAsPhoto ? "photo" : "film")
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
