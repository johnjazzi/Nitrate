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
    var onReturnToVideo: () -> Void = {}
    @Binding var gauge: PrintGauge
    @Binding var pushPullAutomatic: Bool
    @Binding var pushPullStops: PushPullStops
    @Binding var whiteBalance: DevelopWhiteBalance
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
            labHeader
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
            if let issue = model.errorMessage, !model.isLoading {
                HStack(spacing: 8) {
                    Text(DevelopWorkflowPresentation.issueSummary(issue))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("develop.error.summary")
                    Button("Details", systemImage: "info.circle") { showHelp = true }
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .accessibilityIdentifier("develop.error")
                }
                .font(NitrateTypography.font(.callout))
                .foregroundStyle(DevelopPreviewChrome.warning)
            }
            bottomActions
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
        .onDisappear { selectionTask?.cancel() }
        .sheet(isPresented: $showHelp) {
            DevelopMediaHelp(refusal: model.errorMessage ?? (model.bulk.skipped.isEmpty
                ? nil : model.bulk.skipped.joined(separator: "\n")))
        }
        .alert("Photos unavailable", isPresented: $photosOpenFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(PhotosLibraryOpener.failureMessage)
        }
    }

    private var chooser: some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                // Balance the Info target so the prompt itself stays centred.
                Color.clear.frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                Text("Choose what to develop")
                    .font(NitrateTypography.font(.body))
                    .foregroundStyle(DevelopPreviewChrome.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Button { showHelp = true } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Info")
                .accessibilityIdentifier("develop.help")
            }
            VStack(spacing: 12) {
                photoPicker
                videoPicker
            }
            .frame(maxWidth: 240)
            .frame(maxWidth: .infinity, alignment: .center)
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private var returnToVideoButton: some View {
        Button(action: onReturnToVideo) {
            Image(systemName: "arrow.uturn.backward")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Return to Video")
        .accessibilityIdentifier("develop.returnToVideo")
    }

    private var reviewState: some View {
        GeometryReader { proxy in
            // The picker is content, not a sheet: it stays open beneath the
            // preview. On a short panel (landscape, split view, accessibility
            // type) the stack scrolls rather than squeezing the preview to a
            // strip, and the action stays pinned so it is always reachable.
            let pageHeight = max(DevelopPreviewLayout.minimumPageHeight,
                                 proxy.size.height - DevelopPreviewLayout.pickerReservation
                                    - (model.sources.count > 1
                                        ? DevelopPreviewLayout.positionRowHeight : 0))
            VStack(spacing: 12) {
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        TabView(selection: $sourcePage) {
                            ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                                DevelopSourcePage(source: source, stock: stock, gauge: gauge,
                                                  pushPull: resolvedPushPull, renderer: renderer,
                                                  active: index == sourcePage, whiteBalance: whiteBalance)
                                    .tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: pageHeight)
                        if model.sources.count > 1 {
                            Text("\(sourcePage + 1)/\(model.sources.count)")
                                .font(NitrateTypography.font(.body).monospacedDigit())
                                .foregroundStyle(DevelopPreviewChrome.muted)
                                .accessibilityIdentifier("develop.source.position")
                        }
                        stockPicker
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The Lab heading and the current cancel/return action.
    private var labHeader: some View {
        HStack(spacing: 8) {
            Text("LAB").font(NitrateTypography.font(.title2))
            Spacer(minLength: 0)
            if !model.bulk.skipped.isEmpty {
                Button("Skipped \(model.bulk.skipped.count)") { showHelp = true }
                    .font(NitrateTypography.font(.caption))
                    .foregroundStyle(DevelopPreviewChrome.warning)
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("develop.bulkSkipped")
            }
            // Only the film chooser returns to the video: it holds no staged
            // batch, so leaving is lossless. Every other stage owns partial
            // batch state (staged, skipped, queued jobs), so the sole exit
            // there is the explicit Cancel below, which starts over.
            if stage == .chooser {
                returnToVideoButton
            } else {
                Button(action: startOver) {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("develop.bulkCancel")
            }
        }
    }

    /// The existing stock + print picker, always open below the preview and
    /// bound to the parent's one selection / gauge / push-pull owner. The
    /// wrapper carries the panel's own identifier so the picker keeps
    /// `stock.compactPicker` for the stock sheet's shared contract.
    private var stockPicker: some View {
        VStack(spacing: 0) {
            CompactStockPicker(stocks: stockOptions,
                               selectedStockId: selectedStockId,
                               gauge: $gauge,
                               resolvedPushPull: resolvedPushPull,
                               isAutomatic: $pushPullAutomatic,
                               manualStops: $pushPullStops,
                               onPushPullChange: onControlsChanged,
                               expanded: false,
                               showsSelectionSummary: false,
                               centersChoices: true,
                               whiteBalance: $whiteBalance,
                               whiteBalanceIsPhoto: model.sources.indices.contains(sourcePage)
                                   && model.sources[sourcePage].isPhoto)
        }
        // The review already scrolls, so the picker reports its real height
        // instead of nesting a second vertical scroll view inside it — that is
        // what keeps every control reachable at accessibility type sizes.
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("develop.controls")
    }

    /// A chip tap writes the parent's selection through the existing callback;
    /// this view never owns a second stock identity.
    private var selectedStockId: Binding<String?> {
        Binding(get: { stock?.stockId },
                set: { id in
                    guard let id, let option = stockOptions.first(where: { $0.stockId == id })
                    else { return }
                    onSelectStock(option)
                })
    }

    /// One bottom row across every stage. History stays at the left edge and
    /// equal flexible side slots keep the review's Develop action centred.
    private var bottomActions: some View {
        HStack(spacing: 12) {
            historyButton
                .frame(minWidth: 48, maxWidth: .infinity, alignment: .leading)
            if stage == .review || (reviewingRemaining && !model.sources.isEmpty && !model.hasActiveRenders) {
                developButton
            }
            Color.clear
                .frame(minWidth: 48, maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .frame(minHeight: 52)
    }

    private var historyButton: some View {
        Button(action: onOpenResults) {
            VStack(spacing: 2) {
                Image(systemName: "list.bullet").font(.title3)
                Text("History").font(NitrateTypography.font(.caption2))
            }
            .frame(minWidth: 48, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Queue and History")
        .accessibilityHint("Open the history contact sheet and render queue")
        .accessibilityIdentifier("develop.queue")
    }

    private var developButton: some View {
        Button(action: develop) {
            Text("Develop")
                .font(NitrateTypography.font(.title3))
                .frame(maxWidth: 160, minHeight: 52)
                .background(DevelopPreviewChrome.orange, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black)
        .disabled(!model.canDevelop(stock: stock))
        .accessibilityIdentifier("develop.bulkCommit")
    }

    private var resultsState: some View {
        VStack(spacing: 12) {
            DevelopResultsPager(ids: model.resultJobIDs, queue: queue, stocks: stockOptions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.hasActiveRenders {
                if !model.sources.isEmpty {
                    Button("Review remaining") { reviewingRemaining = true }
                        .font(NitrateTypography.font(.body))
                        .frame(minHeight: 48)
                }
                resultActions
            }
        }
    }

    private var resultActions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(action: startOver) {
                    resultActionLabel("Develop more", systemImage: "plus")
                }
                .accessibilityIdentifier("develop.more")
                Button(action: redevelop) {
                    resultActionLabel("Re-develop", systemImage: "arrow.counterclockwise")
                }
                .disabled(!redevelopment.isEnabled)
                .opacity(redevelopment.isEnabled ? 1 : 0.35)
                .accessibilityHint(redevelopment.isEnabled ? "Review originals" : "Originals unavailable")
                .accessibilityIdentifier("develop.redevelop")
                Button {
                    Task { @MainActor in photosOpenFailed = !(await PhotosLibraryOpener.open()) }
                } label: {
                    resultActionLabel("Open Photos", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("develop.openPhotos")
            }
            .buttonStyle(.plain)
            if redevelopment.missingCount > 0 {
                Text("Missing \(redevelopment.missingCount)")
                    .foregroundStyle(DevelopPreviewChrome.warning)
            }
        }
        .font(NitrateTypography.font(.body))
    }

    private func resultActionLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(NitrateTypography.font(size: 24, relativeTo: .title2))
                .accessibilityHidden(true)
            Text(title)
                .font(NitrateTypography.font(.caption))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .contentShape(Rectangle())
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

    private var videoPicker: some View {
        PhotosPicker(selection: $pickerItems, maxSelectionCount: 0, matching: .videos,
                     preferredItemEncoding: .current) {
            Label {
                Text("Video")
            } icon: {
                Image(systemName: "photo.on.rectangle")
                    .foregroundStyle(SettingsControlChrome.lightPurple.opacity(0.85))
            }
            .font(NitrateTypography.font(.headline))
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(CameraRaisedButtonStyle(faceColor: Color(white: 0.32), cornerRadius: 6))
        .foregroundStyle(.white)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(SettingsControlChrome.lightPurple.opacity(0.4), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .environment(\.cameraUIStyle, .classic)
        .disabled(model.hasActiveRenders)
        .accessibilityIdentifier("develop.choose")
    }

    private var photoPicker: some View {
        PhotosPicker(selection: $photoPickerItems, maxSelectionCount: 0, matching: .images,
                     preferredItemEncoding: .current) {
            Label {
                Text("Photo")
            } icon: {
                Image(systemName: "camera.aperture")
                    .foregroundStyle(DevelopPreviewChrome.orange.opacity(0.85))
            }
            .font(NitrateTypography.font(.headline))
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(CameraRaisedButtonStyle(faceColor: Color(white: 0.32), cornerRadius: 6))
        .foregroundStyle(.white)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(DevelopPreviewChrome.orange.opacity(0.4), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .environment(\.cameraUIStyle, .classic)
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
        _ = model.develop(stock: stock, iso: stock.defaultISO, gauge: gauge, pushPull: resolvedPushPull,
                          whiteBalance: whiteBalance)
    }

    private func startOver() {
        selectionTask?.cancel()
        selectionTask = nil
        model.startOver()
        whiteBalance = .neutral
        reviewingRemaining = false
        pickerItems = []
        photoPickerItems = []
    }

    private func redevelop() {
        let jobs = resultJobs
        guard redevelopment.isEnabled else { return }
        if let first = jobs.first(where: \.hasRedevelopableSource) {
            whiteBalance = first.developmentWhiteBalance ?? .neutral
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

/// Review-side geometry. The picker is content beneath the preview, so the
/// review states only ever decide how tall the paged contact may get: it keeps
/// a usable minimum and the stack scrolls when the panel cannot hold both.
enum DevelopPreviewLayout {
    /// Picker and surface padding with gaps. Header and bottom actions are
    /// outside the review geometry and are not reserved a second time.
    static let pickerReservation: CGFloat = 232
    /// The extra a multi-source review needs for its page position caption.
    static let positionRowHeight: CGFloat = 32
    /// The paged contact (frame plus its exposure readout) never shrinks below
    /// this; below it the review scrolls instead.
    static let minimumPageHeight: CGFloat = 160
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
    let whiteBalance: DevelopWhiteBalance
    @State private var frame: DevelopFramePreview?
    @State private var loadedRequest: DevelopSourceRequest?
    @State private var failure: String?
    @State private var retry = 0
    @State private var fence = DevelopPreviewFence()
    @State private var showDetails = false

    private var request: DevelopSourceRequest {
        .init(source: source, recipe: stock.map {
            DevelopPreviewRecipe(url: source.url, isPhoto: source.isPhoto, cropZoom: source.cropZoom,
                                 stock: $0, gauge: gauge, pushPull: pushPull, whiteBalance: whiteBalance)
        }, active: active)
    }

    var body: some View {
        VStack(spacing: 10) {
            contact
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                Text("Estimate \(DevelopWorkflowPresentation.exposure(frame?.measuredOffsetEV))")
                    .font(NitrateTypography.font(.caption))
                    .foregroundStyle(DevelopPreviewChrome.muted)
                    .accessibilityIdentifier("develop.exposure.estimate")
                Spacer(minLength: 0)
                Button { showDetails = true } label: {
                    Image(systemName: "info.circle").font(.body).frame(width: 44, height: 44)
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

    /// The same contact the queue will deliver: its black frame, the selected
    /// stock and gauge printed on the borders, and the source's own capture ISO
    /// when it is known — never the stock's fallback ISO presented as capture.
    private var contact: some View {
        ContactPreviewFrame(imageSize: frame.map { CGSize(width: $0.image.width, height: $0.image.height) },
                            stockAndGauge: "\(stock?.displayName ?? "STOCK —") · \(gauge.displayName)",
                            exposure: DevelopContactISO.caption(captureISO: source.iso,
                                                                renderISO: stock?.defaultISO),
                            date: ContactPreviewPrinting.date(source.capturedAt),
                            isVideo: !source.isPhoto,
                            metadataIdentifier: "develop.contactMetadata") {
            preview
        }
        .accessibilityIdentifier("develop.contact")
    }

    @ViewBuilder private var preview: some View {
        if loadedRequest?.source == source, let frame {
            DevelopExpandableStill(image: frame.image, label: "Preview")
                .overlay(alignment: .topTrailing) {
                    if loadedRequest != request {
                        ProgressView().padding(12)
                    }
                }
                .accessibilityIdentifier("develop.preview")
        } else if loadedRequest == request, let failure {
            VStack(spacing: 12) {
                Text("Preview unavailable")
                Text(DevelopWorkflowPresentation.issueSummary(failure))
                    .font(NitrateTypography.font(.callout))
                    .foregroundStyle(DevelopPreviewChrome.warning)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("develop.preview.issue")
                Button("Retry") { retry += 1 }.frame(minHeight: 48)
            }
        } else if stock == nil {
            Text("Choose stock")
        } else {
            ProgressView().controlSize(.large)
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
        if loadedRequest?.source != requested.source {
            frame = nil
            loadedRequest = nil
        }
        failure = nil
        guard requested.active, let recipe = requested.recipe else { return }
        do {
            // SwiftUI cancels on every recipe/source/page change; debounce knobs
            // before decoding, and fence actors that finish despite cancellation.
            try await Task.sleep(for: .milliseconds(180))
            try Task.checkCancellation()
            let rendered: DevelopFramePreview? = try await DevelopTransferLoader.load(timeout: .seconds(20)) { completion in
                let progress = Progress(totalUnitCount: 1)
                let task = Task {
                    do {
                        let image = try await renderer.preview(url: recipe.url, isPhoto: recipe.isPhoto,
                            stock: recipe.stock, gauge: recipe.gauge, pushPull: recipe.pushPull, cropZoom: recipe.cropZoom,
                            whiteBalance: recipe.whiteBalance)
                        completion(.success(image))
                    } catch {
                        completion(.failure(error))
                    }
                }
                progress.cancellationHandler = { task.cancel() }
                return progress
            }
            guard let rendered else { throw DevelopFramePreviewRenderer.PreviewError.decode }
            guard fence.accepts(token, cancelled: Task.isCancelled), requested == request else { return }
            frame = rendered
            loadedRequest = requested
        } catch {
            guard fence.accepts(token, cancelled: Task.isCancelled), requested == request else { return }
            frame = nil
            failure = error is DevelopTransferLoader.TransferError ? "Preview timeout" : error.localizedDescription
            loadedRequest = requested
        }
    }
}

/// Bounded delivered-file and durable-poster decoding only. Source grading uses
/// DevelopFramePreviewRenderer, never ImageIO display thumbnails as Log input.
enum DevelopPreviewLoader {
    static let maxPixelSize: CGFloat = 1600

    static func image(for url: URL, isPhoto: Bool) async -> CGImage? {
        // A delivered contact is always a local retained file. Never let a
        // stored absolute/remote URL turn presentation into a network read.
        guard url.isFileURL else { return nil }
        if isPhoto {
            return await Task.detached(priority: .userInitiated) { thumbnail(for: url) }.value
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // First frame, matching DevelopFramePreviewRenderer's time-zero read:
        // no tolerance before zero, and the first available frame after it.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? await generator.image(at: .zero).image
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
