#if os(iOS)
import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO
import CoreGraphics

/// One staged review and durable-queue result surface for every import count and
/// retained-original re-development. The parent still owns the camera chrome.
struct DevelopPreview: View {
    let model: DevelopVideoModel
    let queue: RenderQueueViewModel
    var stock: FilmStockConfig? = nil
    var stockOptions: [FilmStockConfig] = []
    var onSelectStock: (FilmStockConfig) -> Void = { _ in }
    var onOpenResults: () -> Void = {}
    @Binding var gauge: PrintGauge
    @Binding var pushPullAutomatic: Bool
    @Binding var pushPullStops: PushPullStops
    var onControlsChanged: () -> Void = {}

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var selectionTask: Task<Void, Never>?
    @State private var renderer = DevelopFramePreviewRenderer()
    @State private var sourcePage = 0
    @State private var bulkStatus: String?
    @State private var showHelp = false
    @State private var photosOpenFailed = false

    private var resolvedPushPull: PushPullExposure {
        DevelopVideoModel.resolvedPushPull(automatic: pushPullAutomatic, stops: pushPullStops)
    }

    private var resultJobs: [RenderJob] {
        DevelopWorkflowPresentation.orderedJobs(ids: model.resultJobIDs, jobs: queue.jobs).compactMap { $0 }
    }

    private var stage: DevelopWorkflowPresentation.Stage {
        DevelopWorkflowPresentation.stage(loading: model.isLoading, active: model.hasActiveRenders,
                                          sourceCount: model.sources.count, resultCount: model.resultJobIDs.count)
    }

    private var redevelopment: DevelopWorkflowPresentation.Redevelopment {
        DevelopWorkflowPresentation.redevelopment(jobs: resultJobs, requestedCount: model.resultJobIDs.count)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                switch stage {
                case .loading: transferState
                case .review: reviewState
                case .rendering, .results: resultsState
                case .chooser: chooser
                }
                if let message = model.errorMessage, !model.isLoading {
                    Text(message)
                        .foregroundStyle(DevelopPreviewChrome.warning)
                        .font(NitrateTypography.font(.footnote))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("develop.error")
                    Button("Why?") { showHelp = true }
                        .frame(minHeight: 44)
                }
                if let bulkStatus {
                    Text(bulkStatus)
                        .font(NitrateTypography.font(.caption))
                        .foregroundStyle(DevelopPreviewChrome.muted)
                        .accessibilityIdentifier("develop.bulkStatus")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DevelopPreviewChrome.surface)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            stageClips(items)
        }
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            photoPickerItems = []
            stagePhotos(items)
        }
        .onChange(of: model.sources.map(\.id)) { _, _ in sourcePage = 0 }
        .onChange(of: gauge) { _, _ in onControlsChanged() }
        .sheet(isPresented: $showHelp) { DevelopMediaHelp(refusal: model.errorMessage) }
        .alert("Could not open Photos", isPresented: $photosOpenFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(PhotosLibraryOpener.failureMessage)
        }
    }

    private var chooser: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                photoPicker
                videoPicker
            }
            Text("Choose a raw photo or Apple Log 2 clip. Nothing develops until you review it.")
                .font(NitrateTypography.font(.footnote))
                .foregroundStyle(DevelopPreviewChrome.muted)
                .multilineTextAlignment(.center)
            Button("What can I develop?") { showHelp = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("develop.help")
        }
    }

    private var reviewState: some View {
        VStack(spacing: 12) {
            TabView(selection: $sourcePage) {
                ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                    DevelopSourcePage(source: source, stock: stock, gauge: gauge,
                                      pushPull: resolvedPushPull, renderer: renderer, active: index == sourcePage)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 380)
            Text("File \(min(sourcePage + 1, model.sources.count)) of \(model.sources.count) · Swipe to browse")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(DevelopPreviewChrome.muted)
                .accessibilityIdentifier("develop.source.position")
            if !model.bulk.skipped.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.bulk.skipped.count) files skipped")
                    ForEach(Array(model.bulk.skipped.enumerated()), id: \.offset) { _, reason in
                        Text(reason)
                    }
                }
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(DevelopPreviewChrome.warning)
                .accessibilityIdentifier("develop.bulkSkipped")
            }
            stockMenu
            controlRow
            Button("Develop \(model.sources.count)", action: develop)
                .buttonStyle(.borderedProminent)
                .tint(DevelopPreviewChrome.orange)
                .frame(minHeight: 44)
                .disabled(!model.canDevelop(stock: stock))
                .accessibilityIdentifier("develop.bulkCommit")
            Button("Cancel", action: startOver)
                .frame(minHeight: 44)
                .accessibilityIdentifier("develop.bulkCancel")
        }
    }

    private var resultsState: some View {
        VStack(spacing: 12) {
            DevelopResultsPager(ids: model.resultJobIDs, queue: queue)
            if model.hasActiveRenders {
                Text("Developing in the render queue")
                    .font(NitrateTypography.font(.callout))
                    .foregroundStyle(.white)
                // The current job's live progress remains visible even while the
                // user swipes to an already completed result in the batch.
                if let current = resultJobs.first(where: { $0.status == .processing })
                    ?? resultJobs.first(where: { $0.status == .pending }) {
                    let progress = DevelopProgressPresentation(progress: queue.progress(for: current.id),
                                                               queued: current.status == .pending)
                    Text(progress.caption)
                        .font(NitrateTypography.font(.caption).monospacedDigit())
                        .foregroundStyle(DevelopPreviewChrome.muted)
                }
            } else {
                resultActions
                if !model.sources.isEmpty {
                    Text("Some originals were not queued. Review them below and try Develop again.")
                        .foregroundStyle(DevelopPreviewChrome.warning)
                    reviewState
                }
            }
            if resultJobs.contains(where: { $0.status == .failed }) {
                Text("Some items failed. Swipe to each failed item to retry it.")
                    .font(NitrateTypography.font(.caption))
                    .foregroundStyle(DevelopPreviewChrome.warning)
            }
            if model.hasActiveRenders || resultJobs.contains(where: { $0.status == .failed }) {
                Button("View render queue", action: onOpenResults)
                    .font(NitrateTypography.font(.footnote))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("develop.queue")
            }
        }
    }

    private var resultActions: some View {
        VStack(spacing: 8) {
            Button("Develop more", action: startOver)
                .accessibilityIdentifier("develop.more")
            Button("Re-develop", action: redevelop)
                .disabled(!redevelopment.isEnabled)
                .accessibilityIdentifier("develop.redevelop")
            Button("Open Photos") {
                Task { @MainActor in photosOpenFailed = !(await PhotosLibraryOpener.open()) }
            }
            .accessibilityIdentifier("develop.openPhotos")
            if !redevelopment.isEnabled {
                Text("Originals are no longer on this device. Use Develop more to pick them again.")
                    .font(NitrateTypography.font(.caption))
                    .foregroundStyle(DevelopPreviewChrome.muted)
            } else {
                let missing = redevelopment.missingCount
                if missing > 0 {
                    Text("\(missing) originals unavailable; Re-develop reviews the remaining originals.")
                        .font(NitrateTypography.font(.caption))
                        .foregroundStyle(DevelopPreviewChrome.warning)
                }
            }
            Text("Photos opens your library, not a specific asset. Look in Recently Saved.")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(DevelopPreviewChrome.muted)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .multilineTextAlignment(.center)
    }

    private var transferState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(DevelopPreviewChrome.orange)
            Text(model.bulk.total > 0
                 ? "Reading \(min(model.bulk.read, model.bulk.total)) of \(model.bulk.total)…"
                 : "Loading originals…")
                .font(NitrateTypography.font(.callout))
                .foregroundStyle(.white)
            Button("Cancel", action: startOver)
                .frame(minHeight: 44)
                .accessibilityIdentifier("develop.cancel")
        }
    }

    private var stockMenu: some View {
        Menu {
            ForEach(stockOptions, id: \.stockId) { option in
                Button {
                    onSelectStock(option)
                } label: {
                    if option.stockId == stock?.stockId {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            Label(stock?.displayName ?? "Choose a stock", systemImage: "chevron.up.chevron.down")
                .font(NitrateTypography.font(.subheadline))
                .foregroundStyle(.white)
                .padding(12)
                .background(DevelopPreviewChrome.control, in: Capsule())
        }
        .accessibilityIdentifier("develop.bulkStock")
    }

    private var controlRow: some View {
        HStack(alignment: .bottom, spacing: StockSheetLayout.controlSpacing) {
            GaugeControl(gauge: $gauge)
            PushPullControl(resolved: resolvedPushPull, isAutomatic: $pushPullAutomatic,
                            manualStops: $pushPullStops, onChange: onControlsChanged)
                .frame(maxWidth: 74)
        }
        .accessibilityIdentifier("develop.controls")
    }

    private var videoPicker: some View {
        PhotosPicker(selection: $pickerItems, maxSelectionCount: 0, matching: .videos,
                     preferredItemEncoding: .current) {
            Label("Video", systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .disabled(model.hasActiveRenders)
        .accessibilityIdentifier("develop.choose")
    }

    private var photoPicker: some View {
        PhotosPicker(selection: $photoPickerItems, maxSelectionCount: 0, matching: .images,
                     preferredItemEncoding: .current) {
            Label("Photo", systemImage: "camera.aperture")
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .disabled(model.hasActiveRenders)
        .accessibilityIdentifier("develop.choosePhoto")
    }

    private func stageClips(_ items: [PhotosPickerItem]) {
        selectionTask?.cancel()
        bulkStatus = nil
        selectionTask = Task { @MainActor in
            let transfers: [DevelopVideoModel.TransferOperation] = items.map { item in
                { @MainActor in try await model.loadClip(from: item) }
            }
            await model.stageVideos(transfers: transfers)
        }
    }

    private func stagePhotos(_ items: [PhotosPickerItem]) {
        selectionTask?.cancel()
        bulkStatus = nil
        selectionTask = Task { @MainActor in
            let transfers: [DevelopVideoModel.PhotoTransferOperation] = items.map { item in
                { @MainActor in try await model.loadPhoto(from: item) }
            }
            await model.stagePhotos(transfers: transfers)
        }
    }

    private func develop() {
        guard let stock, model.canDevelop(stock: stock) else { return }
        let result = model.develop(stock: stock, iso: stock.defaultISO, gauge: gauge, pushPull: resolvedPushPull)
        bulkStatus = Self.bulkSummary(result)
    }

    private func startOver() {
        selectionTask?.cancel()
        selectionTask = nil
        model.startOver()
        bulkStatus = nil
        pickerItems = []
        photoPickerItems = []
    }

    private func redevelop() {
        let jobs = resultJobs
        guard redevelopment.isEnabled else { return }
        if let first = jobs.first(where: \.hasRedevelopableSource) {
            if let priorStock = stockOptions.first(where: { $0.stockId == first.stockId }) {
                onSelectStock(priorStock)
            }
            if let priorGauge = first.printGauge { gauge = priorGauge }
            // Recall the resolved recipe, not a live-meter mode that resolves
            // neutral for imports and would silently drop a captured auto pull.
            pushPullAutomatic = false
            pushPullStops = first.pushPull?.stops ?? .none
            onControlsChanged()
        }
        bulkStatus = nil
        selectionTask?.cancel()
        selectionTask = Task { @MainActor in await model.adoptExistingJobs(jobs) }
    }

    // Compatibility helpers used by existing callers and tests.
    static func bulkSummary(_ result: DevelopVideoModel.BulkDevelopResult) -> String {
        let queued = "\(result.queued) added"
        return result.skipped.isEmpty ? queued : queued + " · \(result.skipped.count) skipped"
    }

    static func videoTitle(_ video: ImportedVideo) -> String {
        video.capturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Selected clip"
    }

    static func videoDetail(_ video: ImportedVideo) -> String {
        String(format: "%.1f s", video.durationSeconds) + " · "
            + String(format: "%.2f fps", video.nominalFrameRate) + " · "
            + "\(video.pixelWidth) × \(video.pixelHeight)"
    }

    static func photoTitle(_ photo: ImportedPhoto) -> String {
        photo.capturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Selected photo"
    }
}

private struct DevelopSourceRequest: Equatable {
    let source: DevelopSource
    let recipe: DevelopPreviewRecipe?
    let active: Bool
}

private struct DevelopSourcePage: View {
    let source: DevelopSource
    let stock: FilmStockConfig?
    let gauge: PrintGauge
    let pushPull: PushPullExposure
    let renderer: DevelopFramePreviewRenderer
    let active: Bool
    @State private var frame: DevelopFramePreview?
    @State private var loadedRequest: DevelopSourceRequest?
    @State private var failure: String?
    @State private var retry = 0
    @State private var fence = DevelopPreviewFence()

    private var request: DevelopSourceRequest {
        .init(source: source, recipe: stock.map {
            DevelopPreviewRecipe(url: source.url, isPhoto: source.isPhoto, cropZoom: source.cropZoom,
                                 stock: $0, gauge: gauge, pushPull: pushPull)
        }, active: active)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                Text(source.originalFilename)
                    .font(NitrateTypography.font(.callout))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if loadedRequest == request, let frame {
                    DevelopExpandableStill(image: frame.image, label: "Graded preview of \(source.originalFilename)")
                        .frame(height: 210)
                        .accessibilityIdentifier("develop.preview")
                    Text("Center-weighted file exposure estimate: "
                         + DevelopWorkflowPresentation.exposure(frame.measuredOffsetEV))
                        .accessibilityIdentifier("develop.exposure.estimate")
                    Text(frame.captureDescription ?? "Recorded capture metadata unavailable")
                } else if loadedRequest == request, let failure {
                    Text(failure).foregroundStyle(DevelopPreviewChrome.warning)
                    Button("Retry preview") { retry += 1 }
                        .frame(minHeight: 44)
                } else if stock == nil {
                    Text("Choose a stock to preview this original.")
                        .frame(height: 210)
                } else {
                    ProgressView("Grading preview…").frame(height: 210)
                }
                if let iso = source.iso {
                    Text(DevelopWorkflowPresentation.captureRating(iso))
                        .accessibilityIdentifier("develop.exposure.captureRating")
                }
                Text("Saved capture meter offset: "
                     + DevelopWorkflowPresentation.exposure(source.capturedOffsetEV.map(Double.init)))
                Text(source.isPhoto
                     ? "Estimate relative to 18% gray, not calibrated EV100. Preview is not a saved output."
                     : "Estimate relative to 18% gray, not calibrated EV100. One video still; full export can measure highlight protection across more frames.")
            }
            .font(NitrateTypography.font(.caption))
            .foregroundStyle(DevelopPreviewChrome.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
        .task(id: request) { await load(request) }
        .task(id: retry) {
            guard retry > 0 else { return }
            await load(request)
        }
    }

    @MainActor private func load(_ requested: DevelopSourceRequest) async {
        guard requested == request, !Task.isCancelled else { return }
        let token = fence.begin()
        frame = nil
        failure = nil
        loadedRequest = nil
        guard requested.active, let recipe = requested.recipe else { return }
        do {
            // SwiftUI cancels on every recipe/source/page change; debounce knobs
            // before decoding, and fence actors that finish despite cancellation.
            try await Task.sleep(for: .milliseconds(180))
            try Task.checkCancellation()
            let rendered = try await renderer.preview(url: recipe.url, isPhoto: recipe.isPhoto,
                                                      stock: recipe.stock, gauge: recipe.gauge,
                                                      pushPull: recipe.pushPull, cropZoom: recipe.cropZoom)
            guard fence.accepts(token, cancelled: Task.isCancelled), requested == request else { return }
            frame = rendered
            loadedRequest = requested
        } catch {
            guard fence.accepts(token, cancelled: Task.isCancelled), requested == request else { return }
            failure = error.localizedDescription
            loadedRequest = requested
        }
    }
}

/// Bounded delivered-file and durable-poster decoding only. Source grading uses
/// DevelopFramePreviewRenderer, never ImageIO display thumbnails as Log input.
enum DevelopPreviewLoader {
    static let maxPixelSize: CGFloat = 1600

    static func image(for url: URL, isPhoto: Bool) async -> CGImage? {
        if isPhoto {
            return await Task.detached(priority: .userInitiated) { thumbnail(for: url) }.value
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    }

    static func thumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source)
    }

    static func thumbnail(for url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source)
    }

    private static func thumbnail(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

enum DevelopPreviewChrome {
    static let orange = SettingsControlChrome.halationOrange
    static let muted = Color.white.opacity(0.65)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.40)
    static let control = Color.white.opacity(0.10)
    static let surface = Color.black.opacity(0.85)
}
#endif
