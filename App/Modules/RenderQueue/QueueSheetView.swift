import SwiftUI
import UIKit
import AVKit

/// Queue sheet, job row and share sheet for the render queue.

struct QueueSheetView: View {
    @State var viewModel: RenderQueueViewModel
    @Binding var isPresented: Bool
    @State private var showAll = false
    @State private var shareTarget: RenderJob?
    @State private var playbackJob: RenderJob?

    private var visibleQueuedJobs: [RenderJob] {
        viewModel.outstandingJobs
    }
    private var visibleHistory: [RenderJob] {
        showAll ? viewModel.historyJobs : viewModel.currentSessionResults
    }
    private var isEmpty: Bool { visibleQueuedJobs.isEmpty && visibleHistory.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    ContentUnavailableView(
                        "No Render Jobs",
                        systemImage: "tray",
                        description: Text("Record a video and select a film stock to start rendering.")
                    )
                } else {
                    List {
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
                                                Button("View video") { playbackJob = job }
                                            }
                                            Button("Retry") { viewModel.retry(jobId: job.id) }
                                                .buttonStyle(.bordered)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .animation(.default, value: viewModel.jobs)
            .navigationTitle("")
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
                    Text("Rendering").font(.caption2).foregroundStyle(.orange)
                }
            case .completed: Label("Done", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
            case .failed: Label("Failed", systemImage: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
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
