import SwiftUI
import UIKit
import AVKit

/// Combined storage and render queue sheet, job row and share sheet.

struct QueueSheetView: View {
    @State var viewModel: RenderQueueViewModel
    let cameraViewModel: CameraViewModel
    @Binding var isPresented: Bool
    @State private var showAll = false
    @State private var shareTarget: RenderJob?
    @State private var playbackJob: RenderJob?

    private var visibleQueuedJobs: [RenderJob] {
        viewModel.outstandingJobs
    }
    private var visibleAwaitingStock: [RenderJob] {
        viewModel.awaitingStockJobs
    }
    private var visibleHistory: [RenderJob] {
        showAll ? viewModel.historyJobs : viewModel.currentSessionResults
    }
    private var isEmpty: Bool {
        visibleQueuedJobs.isEmpty && visibleAwaitingStock.isEmpty && visibleHistory.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isPersistenceBlocked {
                    Section {
                        Button {
                            viewModel.resume()
                        } label: {
                            Label("Resume queue", systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        Text("The queue is paused because a change could not be saved. Nothing is lost; resume to retry the write.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Storage") {
                    CameraStorageSummary(
                        freeSpaceBytes: cameraViewModel.hasStorageSnapshot ? cameraViewModel.freeSpaceBytes : nil,
                        totalSpaceBytes: cameraViewModel.hasStorageSnapshot ? cameraViewModel.totalSpaceBytes : nil,
                        estimatedSeconds: estimatedRemainingSeconds
                    )
                }
                if isEmpty {
                    Section("Render queue") {
                        ContentUnavailableView(
                            "No Render Jobs",
                            systemImage: "tray",
                            description: Text("Record a video and select a film stock to start rendering.")
                        )
                    }
                } else {
                    if !visibleAwaitingStock.isEmpty {
                        Section("Awaiting stock (\(visibleAwaitingStock.count))") {
                            ForEach(visibleAwaitingStock) { job in
                                VStack(alignment: .leading, spacing: 6) {
                                    JobRow(job: job)
                                    chooseStockMenu(for: job)
                                    Button {
                                        viewModel.exportOriginal(jobId: job.id)
                                    } label: {
                                        Text("Save original").frame(minHeight: 44)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    if let current = visibleQueuedJobs.first(where: { $0.status == .processing }) {
                        Section("Processing") { JobRow(job: current, isCurrent: true) }
                    }
                    let pending = visibleQueuedJobs.filter { $0.status == .pending }
                    if !pending.isEmpty {
                        Section("Pending (\(pending.count))") {
                            ForEach(pending) { job in
                                JobRow(job: job)
                                    .swipeActions {
                                        Button("Remove", role: .destructive) {
                                            viewModel.remove(jobId: job.id)
                                        }
                                    }
                            }
                        }
                    }
                    if !visibleHistory.isEmpty {
                        Section("History (\(visibleHistory.count))") {
                            ForEach(visibleHistory) { job in
                                if job.status == .completed {
                                    Button { playbackJob = job } label: { JobRow(job: job) }
                                        .buttonStyle(.plain)
                                        .swipeActions(edge: .leading) {
                                            Button { shareVideo(job) } label: {
                                                Label("Share", systemImage: "square.and.arrow.up")
                                            }.tint(.blue)
                                        }
                                } else {
                                    VStack(alignment: .leading, spacing: 4) {
                                        JobRow(job: job)
                                        if let error = job.errorMessage {
                                            Text(error).font(.caption).foregroundStyle(.red)
                                        }
                                        if job.outputURL != nil {
                                            Button { playbackJob = job } label: {
                                                Text("View video").frame(minHeight: 44)
                                            }
                                        }
                                        Button { viewModel.retry(jobId: job.id) } label: {
                                            Text("Retry").frame(minHeight: 44)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .animation(.default, value: viewModel.jobs)
            .navigationTitle("Storage & Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(showAll ? "This session" : "Show all") { showAll.toggle() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
            .sheet(item: $shareTarget) { job in
                if let url = job.outputURL {
                    ShareSheet(items: [url])
                }
            }
            .sheet(item: $playbackJob) { job in
                if let url = job.outputURL {
                    VideoPreviewSheet(url: url, title: job.stockId, iso: job.iso)
                }
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

    private func shareVideo(_ job: RenderJob) {
        guard let url = job.outputURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
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
                        description: Text("The rendered file is no longer on disk. Re-render this job to play it again.")
                    )
                } else if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("\(title) · ISO \(Int(iso))")
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
    @Environment(\.locale) private var locale

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.stockId).font(.caption.weight(.semibold))
                Text("ISO \(Int(job.iso))").font(.caption2).foregroundStyle(.secondary)
                if job.outputSavedToPhotos == true {
                    Text(job.sourceSavedToPhotos == true ? "Rendered + original saved to Photos" : "Rendered saved to Photos")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if job.sourceSavedToPhotos == true {
                    Text("Original saved to Photos").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Text("Queued")
                    Text(job.createdAt.formatted(queuedDateFormat))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            Spacer()
            statusLabel
        }
        .padding(.vertical, 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: job.status)
    }

    private var queuedDateFormat: Date.FormatStyle {
        .dateTime
            .year()
            .month(.abbreviated)
            .day()
            .hour()
            .minute()
            .second()
            .locale(locale)
    }

    private var statusLabel: some View {
        Group {
            switch job.status {
            case .pending:   Text("Pending").font(.caption2).foregroundStyle(.secondary)
            case .processing:
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text(job.outputSavedToPhotos == true ? "Saving original" : "Rendering / saving")
                        .font(.caption2).foregroundStyle(.orange)
                }
            case .completed: Label("Done", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
            case .failed: Label("Failed", systemImage: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
            case .awaitingStock: Label("Awaiting stock", systemImage: "film").font(.caption2).foregroundStyle(.secondary)
            }
        }
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
