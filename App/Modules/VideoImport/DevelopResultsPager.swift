#if os(iOS)
import SwiftUI
import CoreGraphics

struct DevelopResultsPager: View {
    let ids: [UUID]
    let queue: RenderQueueViewModel
    @State private var page = 0

    private var jobs: [RenderJob?] {
        DevelopWorkflowPresentation.orderedJobs(ids: ids, jobs: queue.jobs)
    }

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $page) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    DevelopResultPage(job: jobs[index], queue: queue, active: page == index)
                        .tag(index)
                        .accessibilityIdentifier("develop.result.\(id)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if ids.count > 1 {
                Text("\(page + 1)/\(ids.count)")
                    .font(NitrateTypography.font(.body).monospacedDigit())
                    .foregroundStyle(DevelopPreviewChrome.muted)
                    .accessibilityIdentifier("develop.result.position")
            }
        }
        .onChange(of: ids) { _, _ in page = 0 }
    }
}

private struct DevelopResultRequest: Equatable {
    let job: RenderJob?
    let active: Bool
}

private struct DevelopResultPage: View {
    let job: RenderJob?
    let queue: RenderQueueViewModel
    let active: Bool
    @State private var image: CGImage?
    @State private var loadedRequest: DevelopResultRequest?
    @State private var fence = DevelopPreviewFence()
    @State private var showDetails = false

    private var request: DevelopResultRequest { .init(job: job, active: active) }

    var body: some View {
        VStack(spacing: 10) {
            if let job {
                resultImage(job)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if job.status == .failed, let issue = job.errorMessage {
                    Text(DevelopWorkflowPresentation.issueSummary(issue))
                        .font(NitrateTypography.font(.callout))
                        .foregroundStyle(DevelopPreviewChrome.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("develop.result.issue")
                }
                HStack {
                    Text(DevelopWorkflowPresentation.deliveryLabel(job))
                        .font(NitrateTypography.font(.body))
                        .foregroundStyle(.white)
                    if job.status == .failed {
                        Spacer()
                        Button("Details") { showDetails = true }
                        Button("Retry") { queue.retry(jobId: job.id) }
                            .frame(minHeight: 48)
                            .accessibilityIdentifier("develop.result.retry")
                    }
                }
            } else {
                Text("Unavailable")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(NitrateTypography.font(.body))
        .alert("Details", isPresented: $showDetails) {
            Button("Done", role: .cancel) {}
        } message: {
            Text(job?.errorMessage ?? "Unavailable")
        }
        .task(id: request) { await load(request) }
    }

    @ViewBuilder private func resultImage(_ job: RenderJob) -> some View {
        if job.status == .pending || job.status == .processing {
            DevelopProgressOverlay(progress: queue.progress(for: job.id), queued: job.status == .pending)
                .animation(.easeInOut(duration: 0.2), value: queue.progress(for: job.id))
                .clipped()
        } else if let image, loadedRequest == request {
            DevelopExpandableStill(image: image, label: "Output")
                .accessibilityIdentifier("develop.result.image")
        } else if job.status == .completed {
            if loadedRequest == request {
                Text("Preview unavailable")
                    .foregroundStyle(DevelopPreviewChrome.muted)
            } else {
                ProgressView().controlSize(.large)
            }
        } else {
            Image(systemName: "exclamationmark.circle")
                .font(.largeTitle)
                .foregroundStyle(DevelopPreviewChrome.warning)
        }
    }

    @MainActor private func load(_ requested: DevelopResultRequest) async {
        guard requested == request, !Task.isCancelled else { return }
        let token = fence.begin()
        image = nil
        loadedRequest = nil
        guard requested.active, let job = requested.job, job.status == .completed else { return }
        var decoded: CGImage?
        if let url = job.outputURL {
            decoded = await DevelopPreviewLoader.image(for: url, isPhoto: job.isPhoto == true)
        }
        if decoded == nil, let data = job.receipt?.thumbnailJPEG {
            decoded = await Task.detached(priority: .userInitiated) {
                DevelopPreviewLoader.thumbnail(from: data)
            }.value
        }
        guard fence.accepts(token, cancelled: Task.isCancelled), requested == request else { return }
        image = decoded
        loadedRequest = requested
    }
}
#endif
