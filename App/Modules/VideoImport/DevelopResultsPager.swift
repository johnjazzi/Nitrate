#if os(iOS)
import SwiftUI
import CoreGraphics

/// Explicit ISO provenance. The selected render ISO is a stock fallback, so it
/// is printed as RENDER ISO and never as if the capture had rated it.
enum DevelopContactISO {
    static func caption(captureISO: Float?, renderISO: Float?) -> String {
        if let capture = positive(captureISO) {
            return "CAPTURE ISO \(Int(capture.rounded()))"
        }
        if let render = positive(renderISO) {
            return "RENDER ISO \(Int(render.rounded()))"
        }
        return "ISO —"
    }

    private static func positive(_ iso: Float?) -> Float? {
        guard let iso, iso.isFinite, iso > 0 else { return nil }
        return iso
    }
}

// MARK: - Result pager

struct DevelopResultsPager: View {
    let ids: [UUID]
    let queue: RenderQueueViewModel
    /// The parent's catalogue, used only to print a stock's display name when
    /// the receipt has not recorded one yet.
    var stocks: [FilmStockConfig] = []
    @State private var page = 0

    private var jobs: [RenderJob?] {
        DevelopWorkflowPresentation.orderedJobs(ids: ids, jobs: queue.jobs)
    }

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $page) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    DevelopResultPage(job: jobs[index], queue: queue, stocks: stocks,
                                      active: page == index)
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
    let stocks: [FilmStockConfig]
    let active: Bool
    @State private var image: CGImage?
    @State private var loadedRequest: DevelopResultRequest?
    @State private var fence = DevelopPreviewFence()
    @State private var showDetails = false

    private var request: DevelopResultRequest { .init(job: job, active: active) }

    var body: some View {
        VStack(spacing: 10) {
            contact
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let job, job.status == .failed, let issue = job.errorMessage {
                Text(DevelopWorkflowPresentation.issueSummary(issue))
                    .font(NitrateTypography.font(.callout))
                    .foregroundStyle(DevelopPreviewChrome.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("develop.result.issue")
            }
            if let job {
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
            }
        }
        .font(NitrateTypography.font(.body))
        .alert("Details", isPresented: $showDetails) {
            Button("Done", role: .cancel) {}
        } message: {
            Text(job?.errorMessage ?? "Unavailable")
        }
        .task(id: request) { await load(request) }
        .onDisappear {
            // A pager keeps its pages alive; the decoded contact does not
            // outlive the presentation that shows it.
            image = nil
            loadedRequest = nil
            _ = fence.begin()
        }
    }

    /// The authoritative contact values: the receipt's own record first, then
    /// the job's stored recipe, and the source capture ISO only when it is
    /// genuinely known.
    private var contact: some View {
        ContactPreviewFrame(imageSize: image.map { CGSize(width: $0.width, height: $0.height) }
                                ?? job?.receipt.flatMap { receipt in
                                    guard let width = receipt.pixelWidth, let height = receipt.pixelHeight else { return nil }
                                    return CGSize(width: width, height: height)
                                },
                            stockAndGauge: "\(stockCaption) · \(gaugeCaption)",
                            exposure: DevelopContactISO.caption(captureISO: job?.sourceCaptureISO,
                                                                renderISO: job?.iso),
                            frameRate: job?.presentsAsPhoto == false
                                ? "\(ReceiptMetadataCards.frameRate(job?.receipt?.framesPerSecond)) FPS" : nil,
                            date: ContactPreviewPrinting.date(job?.receipt?.recordedAt),
                            isVideo: job?.presentsAsPhoto == false,
                            metadataIdentifier: "develop.result.contact") {
            if let job {
                resultImage(job)
            } else {
                Text("Unavailable")
                    .font(NitrateTypography.font(.body))
                    .foregroundStyle(DevelopPreviewChrome.muted)
            }
        }
        .accessibilityIdentifier("develop.result.contact")
    }

    private var stockCaption: String {
        guard let job else { return "STOCK —" }
        let recorded = job.receipt?.metadata["com.filmemulation.stock-name"] ?? ""
        if !recorded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return recorded.uppercased()
        }
        if let stock = stocks.first(where: { $0.stockId == job.stockId }) {
            return stock.displayName.uppercased()
        }
        return job.stockId.isEmpty ? "STOCK —" : job.stockId.uppercased()
    }

    private var gaugeCaption: String {
        guard let job else { return "GAUGE —" }
        if let recorded = job.receipt?.metadata["com.filmemulation.print-gauge"],
           let gauge = PrintGauge(rawValue: recorded) {
            return gauge.displayName.uppercased()
        }
        return (job.printGauge ?? PrintGauge.neutral).displayName.uppercased()
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
