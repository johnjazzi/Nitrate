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
        VStack(spacing: 8) {
            TabView(selection: $page) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    DevelopResultPage(job: jobs[index], queue: queue, active: page == index)
                        .tag(index)
                        .accessibilityIdentifier("develop.result.\(id)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 300)
            Text("Result \(min(page + 1, ids.count)) of \(ids.count) · Swipe to browse")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(DevelopPreviewChrome.muted)
                .accessibilityIdentifier("develop.result.position")
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

    private var request: DevelopResultRequest { .init(job: job, active: active) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                if let job {
                    resultImage(job)
                    Text(DevelopWorkflowPresentation.deliveryLabel(job))
                        .font(NitrateTypography.font(.callout))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if job.status == .failed {
                        Text(job.errorMessage ?? "Could not complete this item.")
                            .font(NitrateTypography.font(.caption))
                            .foregroundStyle(DevelopPreviewChrome.warning)
                            .multilineTextAlignment(.center)
                        Button("Retry this item") { queue.retry(jobId: job.id) }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("develop.result.retry")
                    }
                } else {
                    Text("This result is no longer in the queue. Open Photos to look for saved items.")
                        .foregroundStyle(DevelopPreviewChrome.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: request) { await load(request) }
    }

    @ViewBuilder private func resultImage(_ job: RenderJob) -> some View {
        if job.status == .pending || job.status == .processing {
            DevelopProgressOverlay(progress: queue.progress(for: job.id), queued: job.status == .pending)
                .frame(height: 210)
                .animation(.easeInOut(duration: 0.2), value: queue.progress(for: job.id))
                .clipped()
        } else if let image, loadedRequest == request {
            DevelopExpandableStill(image: image, label: "Developed output")
                .frame(height: 210)
                .accessibilityIdentifier("develop.result.image")
        } else if job.status == .completed {
            if loadedRequest == request {
                Text("Output preview unavailable. Open Photos to view saved results.")
                    .font(NitrateTypography.font(.caption))
                    .foregroundStyle(DevelopPreviewChrome.muted)
                    .multilineTextAlignment(.center)
                    .frame(height: 210)
            } else {
                ProgressView("Loading delivered still…")
                    .frame(height: 210)
            }
        }
    }

    @MainActor private func load(_ requested: DevelopResultRequest) async {
        guard requested == request, !Task.isCancelled else { return }
        let token = fence.begin()
        image = nil
        loadedRequest = nil
        guard requested.active, let job = requested.job, job.status == .completed else { return }
        var decoded: CGImage?
        // The actual delivered file has priority; the durable poster is a fallback,
        // never a newly graded source or a full movie retained merely for zoom.
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
