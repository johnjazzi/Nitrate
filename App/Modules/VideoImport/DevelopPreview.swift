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
    @State private var reviewingRemaining = false
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
        VStack(spacing: 12) {
            if reviewingRemaining, !model.sources.isEmpty, !model.hasActiveRenders {
                reviewState
            } else {
                switch stage {
                case .loading: transferState
                case .review: reviewState
                case .rendering, .results: resultsState
                case .chooser: chooser
                }
            }
            if model.errorMessage != nil, !model.isLoading {
                Button("Details", systemImage: "exclamationmark.circle") { showHelp = true }
                    .font(NitrateTypography.font(.body))
                    .foregroundStyle(DevelopPreviewChrome.warning)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("develop.error")
            }
        }
        .padding(12)
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
        .sheet(isPresented: $showHelp) {
            DevelopMediaHelp(refusal: model.errorMessage ?? (model.bulk.skipped.isEmpty
                ? nil : model.bulk.skipped.joined(separator: "\n")))
        }
        .alert("Photos unavailable", isPresented: $photosOpenFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private var chooser: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                photoPicker
                videoPicker
            }
            Button { showHelp = true } label: {
                Image(systemName: "info.circle")
                    .font(.title2)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Info")
            .accessibilityIdentifier("develop.help")
            Spacer(minLength: 0)
        }
    }

    private var reviewState: some View {
        VStack(spacing: 12) {
            HStack {
                stockMenu
                Spacer(minLength: 8)
                if !model.bulk.skipped.isEmpty {
                    Button("Skipped \(model.bulk.skipped.count)") { showHelp = true }
                        .foregroundStyle(DevelopPreviewChrome.warning)
                        .frame(minHeight: 48)
                        .accessibilityIdentifier("develop.bulkSkipped")
                }
                Button(action: startOver) {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("develop.bulkCancel")
            }
            TabView(selection: $sourcePage) {
                ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                    DevelopSourcePage(source: source, stock: stock, gauge: gauge,
                                      pushPull: resolvedPushPull, renderer: renderer, active: index == sourcePage)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.sources.count > 1 {
                Text("\(sourcePage + 1)/\(model.sources.count)")
                    .font(NitrateTypography.font(.body).monospacedDigit())
                    .foregroundStyle(DevelopPreviewChrome.muted)
                    .accessibilityIdentifier("develop.source.position")
            }
            controlRow
            Button(action: develop) {
                Text("Develop")
                    .font(NitrateTypography.font(.title3))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(DevelopPreviewChrome.orange, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .disabled(!model.canDevelop(stock: stock))
                .accessibilityIdentifier("develop.bulkCommit")
        }
    }

    private var resultsState: some View {
        VStack(spacing: 12) {
            DevelopResultsPager(ids: model.resultJobIDs, queue: queue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.hasActiveRenders {
                if !model.sources.isEmpty {
                    Button("Review remaining") { reviewingRemaining = true }
                        .font(NitrateTypography.font(.body))
                        .frame(minHeight: 48)
                }
                resultActions
            }
            if model.hasActiveRenders || resultJobs.contains(where: { $0.status == .failed }) {
                Button("Queue", action: onOpenResults)
                    .font(NitrateTypography.font(.body))
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("develop.queue")
            }
        }
    }

    private var resultActions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button("Develop more", action: startOver)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .accessibilityIdentifier("develop.more")
                Button("Re-develop", action: redevelop)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .disabled(!redevelopment.isEnabled)
                    .accessibilityHint(redevelopment.isEnabled ? "Review originals" : "Originals unavailable")
                    .accessibilityIdentifier("develop.redevelop")
                Button("Open Photos") {
                    Task { @MainActor in photosOpenFailed = !(await PhotosLibraryOpener.open()) }
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .accessibilityIdentifier("develop.openPhotos")
            }
            if redevelopment.missingCount > 0 {
                Text("Missing \(redevelopment.missingCount)")
                    .foregroundStyle(DevelopPreviewChrome.warning)
            }
        }
        .font(NitrateTypography.font(.body))
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var transferState: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            ProgressView().controlSize(.large).tint(DevelopPreviewChrome.orange)
            Text("Loading").font(NitrateTypography.font(.title2))
            if model.bulk.total > 0 {
                Text("\(min(model.bulk.read, model.bulk.total))/\(model.bulk.total)")
                    .font(NitrateTypography.font(.title3).monospacedDigit())
            }
            Button("Cancel", action: startOver)
                .font(NitrateTypography.font(.body))
                .frame(minHeight: 52)
                .accessibilityIdentifier("develop.cancel")
            Spacer(minLength: 0)
        }
    }

    private var stockMenu: some View {
        Menu {
            ForEach(stockOptions, id: \.stockId) { option in
                Button { onSelectStock(option) } label: {
                    if option.stockId == stock?.stockId {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            Label(stock?.displayName ?? "Choose stock", systemImage: "chevron.up.chevron.down")
                .font(NitrateTypography.font(.title3))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .background(DevelopPreviewChrome.control, in: Capsule())
        }
        .accessibilityIdentifier("develop.bulkStock")
    }

    private var controlRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            GaugeControl(gauge: $gauge, enlarged: true)
            PushPullControl(resolved: resolvedPushPull, isAutomatic: $pushPullAutomatic,
                            manualStops: $pushPullStops, onChange: onControlsChanged, enlarged: true)
                .frame(width: 90)
        }
        .accessibilityIdentifier("develop.controls")
    }

    private var videoPicker: some View {
        PhotosPicker(selection: $pickerItems, maxSelectionCount: 0, matching: .videos,
                     preferredItemEncoding: .current) {
            Label("Video", systemImage: "photo.on.rectangle")
                .font(NitrateTypography.font(.title2))
                .frame(maxWidth: .infinity, minHeight: 80)
        }
        .buttonStyle(.bordered)
        .disabled(model.hasActiveRenders)
        .accessibilityIdentifier("develop.choose")
    }

    private var photoPicker: some View {
        PhotosPicker(selection: $photoPickerItems, maxSelectionCount: 0, matching: .images,
                     preferredItemEncoding: .current) {
            Label("Photo", systemImage: "camera.aperture")
                .font(NitrateTypography.font(.title2))
                .frame(maxWidth: .infinity, minHeight: 80)
        }
        .buttonStyle(.bordered)
        .disabled(model.hasActiveRenders)
        .accessibilityIdentifier("develop.choosePhoto")
    }

    private func stageClips(_ items: [PhotosPickerItem]) {
        selectionTask?.cancel()
        reviewingRemaining = false
        selectionTask = Task { @MainActor in
            let transfers: [DevelopVideoModel.TransferOperation] = items.map { item in
                { @MainActor in try await model.loadClip(from: item) }
            }
            await model.stageVideos(transfers: transfers)
        }
    }

    private func stagePhotos(_ items: [PhotosPickerItem]) {
        selectionTask?.cancel()
        reviewingRemaining = false
        selectionTask = Task { @MainActor in
            let transfers: [DevelopVideoModel.PhotoTransferOperation] = items.map { item in
                { @MainActor in try await model.loadPhoto(from: item) }
            }
            await model.stagePhotos(transfers: transfers)
        }
    }

    private func develop() {
        guard let stock, model.canDevelop(stock: stock) else { return }
        reviewingRemaining = false
        _ = model.develop(stock: stock, iso: stock.defaultISO, gauge: gauge, pushPull: resolvedPushPull)
    }

    private func startOver() {
        selectionTask?.cancel()
        selectionTask = nil
        model.startOver()
        reviewingRemaining = false
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
        reviewingRemaining = false
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
    @State private var showDetails = false

    private var request: DevelopSourceRequest {
        .init(source: source, recipe: stock.map {
            DevelopPreviewRecipe(url: source.url, isPhoto: source.isPhoto, cropZoom: source.cropZoom,
                                 stock: $0, gauge: gauge, pushPull: pushPull)
        }, active: active)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if loadedRequest == request, let frame {
                    DevelopExpandableStill(image: frame.image, label: "Preview")
                        .accessibilityIdentifier("develop.preview")
                } else if loadedRequest == request, failure != nil {
                    VStack(spacing: 16) {
                        Text("Preview unavailable")
                        Button("Retry") { retry += 1 }.frame(minHeight: 48)
                    }
                } else if stock == nil {
                    Text("Choose stock")
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 16) {
                readout("Estimate", value: DevelopWorkflowPresentation.exposure(frame?.measuredOffsetEV))
                    .accessibilityIdentifier("develop.exposure.estimate")
                if let rating = source.capturedOffsetEV {
                    readout("Captured", value: DevelopWorkflowPresentation.exposure(Double(rating)))
                }
                if let iso = source.iso {
                    readout("Rated", value: DevelopWorkflowPresentation.captureRating(iso))
                        .accessibilityIdentifier("develop.exposure.captureRating")
                }
                Spacer(minLength: 0)
                Button { showDetails = true } label: {
                    Image(systemName: "info.circle").font(.title3).frame(width: 44, height: 48)
                }
                .accessibilityLabel("Details")
            }
        }
        .font(NitrateTypography.font(.body))
        .foregroundStyle(.white)
        .alert("Details", isPresented: $showDetails) {
            Button("Done", role: .cancel) {}
        } message: {
            Text(failure ?? [source.originalFilename, frame?.captureDescription].compactMap { $0 }.joined(separator: "\n"))
        }
        .task(id: request) { await load(request) }
        .task(id: retry) {
            guard retry > 0 else { return }
            await load(request)
        }
    }

    private func readout(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(NitrateTypography.font(.subheadline)).foregroundStyle(DevelopPreviewChrome.muted)
            Text(value).font(NitrateTypography.font(.title3).monospacedDigit())
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
