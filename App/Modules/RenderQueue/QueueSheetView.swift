import SwiftUI
import UIKit
import AVKit

/// Combined storage and render queue sheet, job row and share sheet.

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
    @State private var showAll = false
    @State private var shareTarget: RenderJob?
    @State private var playbackJob: RenderJob?
    @State private var metadataJob: RenderJob?
    @State private var photosOpenFailed = false
    @State private var showsStorage = false
    @State private var queueNotice: String?

    private var latestRender: RenderJob? {
        let candidates = viewModel.jobs.map {
            QueueReceiptPresentation.Candidate(id: $0.id, completed: $0.status == .completed,
                                               originalOnly: $0.originalOnly == true,
                                               createdAt: $0.createdAt, recordedAt: $0.receipt?.recordedAt)
        }
        let id = QueueReceiptPresentation.latestRenderID(in: candidates)
        return viewModel.jobs.first { $0.id == id }
    }

    private var visibleQueuedJobs: [RenderJob] {
        viewModel.outstandingJobs
    }
    private var visibleAwaitingStock: [RenderJob] {
        viewModel.awaitingStockJobs
    }
    private var visibleHistory: [RenderJob] {
        let history = showAll ? viewModel.historyJobs : viewModel.currentSessionResults
        return history.filter { $0.id != latestRender?.id }
    }
    private var isEmpty: Bool {
        visibleQueuedJobs.isEmpty && visibleAwaitingStock.isEmpty && visibleHistory.isEmpty && latestRender == nil
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isRenderPausedForAccess {
                    Button {
                        queueNotice = "Rendering needs an active subscription. Your originals are kept."
                    } label: {
                        Label("Rendering paused", systemImage: "lock.fill").frame(minHeight: 44)
                    }
                }
                if viewModel.isPersistenceBlocked {
                    HStack {
                        Button { viewModel.resume() } label: {
                            Label("Resume queue", systemImage: "arrow.clockwise").frame(width: 44, height: 44)
                        }
                        Button {
                            queueNotice = "The queue could not save a change. Existing media is kept; free space if needed, then resume."
                        } label: {
                            Label("Details", systemImage: "exclamationmark.triangle").frame(width: 44, height: 44)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                if let latestRender {
                    Section {
                        HStack(spacing: 10) {
                            if isSelecting, canReviewOriginal(latestRender) {
                                selectionToggle(for: latestRender)
                            }
                            receiptCard(for: latestRender, prominent: true)
                        }
                    } header: {
                        Label("Latest render", systemImage: "star")
                    }
                }
                if isEmpty {
                    Image(systemName: "tray")
                        .font(NitrateTypography.font(size: 44))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .accessibilityLabel("No render jobs")
                } else {
                    if !visibleAwaitingStock.isEmpty {
                        Section {
                            ForEach(visibleAwaitingStock) { job in
                                HStack {
                                    JobRow(job: job, onDetails: { metadataJob = job })
                                    chooseStockMenu(for: job)
                                    Button {
                                        viewModel.exportOriginal(jobId: job.id)
                                    } label: {
                                        Label("Save original", systemImage: "square.and.arrow.down")
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        } header: {
                            Label("Awaiting stock", systemImage: "film")
                        }
                    }
                    if let current = visibleQueuedJobs.first(where: { $0.status == .processing }) {
                        Section {
                            JobRow(job: current, isCurrent: true, onDetails: { metadataJob = current })
                        } header: {
                            Label("Processing", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    let pending = visibleQueuedJobs.filter { $0.status == .pending }
                    if !pending.isEmpty {
                        Section {
                            ForEach(pending) { job in
                                JobRow(job: job, onDetails: { metadataJob = job })
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            viewModel.remove(jobId: job.id)
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                            }
                        } header: {
                            Label("Pending", systemImage: "clock")
                        }
                    }
                    if !visibleHistory.isEmpty {
                        Section {
                            ForEach(visibleHistory) { job in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 10) {
                                        if isSelecting, canReviewOriginal(job) {
                                            selectionToggle(for: job)
                                        }
                                        receiptCard(for: job)
                                    }
                                    if job.status == .failed {
                                        Button { viewModel.retry(jobId: job.id) } label: {
                                            Label("Retry", systemImage: "arrow.clockwise")
                                                .frame(width: 44, height: 44)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        } header: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
            }
            .labelStyle(.iconOnly)
            .animation(.default, value: viewModel.jobs)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Image(systemName: "clock.arrow.circlepath").accessibilityLabel("History")
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    if isSelecting {
                        Button {
                            isSelecting = false
                            selection.removeAll()
                        } label: {
                            Label("Cancel", systemImage: "xmark").frame(width: 44, height: 44)
                        }
                    } else {
                        Button { showAll.toggle() } label: {
                            Label(showAll ? "This session" : "Show all", systemImage: showAll ? "clock" : "clock.badge.checkmark")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityValue(showAll ? "All history" : "This session")
                        Button { showsStorage = true } label: {
                            Label("Storage", systemImage: "internaldrive").frame(width: 44, height: 44)
                        }
                        Button(action: openPhotos) {
                            Label("Open Photos", systemImage: "photo.on.rectangle").frame(width: 44, height: 44)
                        }
                        .accessibilityIdentifier(QueueReceiptPresentation.photosActionID + ".general")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelecting {
                        Image(systemName: "checkmark.circle.fill")
                            .accessibilityLabel("\(selection.count) selected")
                    } else if visibleHistory.contains(where: canReviewOriginal)
                        || latestRender.map(canReviewOriginal) == true {
                        Button { isSelecting = true } label: {
                            Label("Select", systemImage: "checkmark.circle").frame(width: 44, height: 44)
                        }
                        .accessibilityIdentifier("queue.select")
                    }
                    Button { isPresented = false } label: {
                        Label("Done", systemImage: "xmark").frame(width: 44, height: 44)
                    }
                }
            }
            .labelStyle(.iconOnly)
            // Bulk action lives at the bottom, where a thumb is, and only while
            // something is selected: a disabled bar would be permanent chrome.
            .safeAreaInset(edge: .bottom) {
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
                    .accessibilityIdentifier("queue.bulkRedevelop")
                }
            }
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
        .onAppear { cameraViewModel.updateFreeSpace() }
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
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private func receiptCard(for job: RenderJob, prominent: Bool = false) -> some View {
        QueueReceiptCard(job: job, prominent: prominent, openPhotos: openPhotos,
                         showMetadata: { metadataJob = job },
                         playLocal: {
                             guard job.isImportedVideo != true, job.retainedOutputURL != nil else { return }
                             playbackJob = job
                         }, shareLocal: { shareVideo(job) },
                         redevelop: canReviewOriginal(job) ? { onRedevelop(job) } : nil)
    }

    private func canReviewOriginal(_ job: RenderJob) -> Bool {
        job.originalOnly != true && job.hasRedevelopableSource
            && (job.status == .completed || job.status == .failed)
    }

    /// Tap target that adds or removes a finished develop from the bulk selection.
    private func selectionToggle(for job: RenderJob) -> some View {
        Button {
            if selection.contains(job.id) { selection.remove(job.id) } else { selection.insert(job.id) }
        } label: {
            Image(systemName: selection.contains(job.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selection.contains(job.id) ? .primary : .secondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selection.contains(job.id) ? "Deselect" : "Select")
        .accessibilityIdentifier("queue.selectRow")
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

import UIKit

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
