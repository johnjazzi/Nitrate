#if os(iOS)
import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO
import CoreGraphics

/// Inline Develop surface for the D-V mode.
///
/// It chooses a clip OR a raw photo, shows an UNGRADED frame of what was picked so
/// the operator can see they selected the right thing, carries the gauge and
/// push/pull controls (the shared components the stock sheet presents), shows
/// genuine render progress while a job is pending or processing, and reports
/// completion or failure. The parent owns the stock and the shutter starts the
/// render; the gauge and push/pull here ARE the parent's, bound in.
struct DevelopPreview: View {
    let model: DevelopVideoModel
    let queue: RenderQueueViewModel
    /// The stock a bulk pick queues with; nil disables bulk (no target stock).
    var stock: FilmStockConfig? = nil
    /// Stocks offered in the bulk staging view, so a batch can be developed with
    /// a different stock than the camera is set to.
    var stockOptions: [FilmStockConfig] = []
    var onSelectStock: (FilmStockConfig) -> Void = { _ in }
    @Binding var gauge: PrintGauge
    @Binding var pushPullAutomatic: Bool
    @Binding var pushPullStops: PushPullStops
    /// Called after a change so the parent can persist the preference.
    var onControlsChanged: () -> Void = {}
    /// The exposure the parent resolved for this render, shown in the pill.
    var resolvedPushPull: PushPullExposure = .neutral

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    /// What a bulk pick is doing, so a multi-select is not silent.
    @State private var bulkStatus: String?
    @State private var preview: CGImage?
    /// The delivered render, decoded from the file the queue wrote. Separate
    /// from `preview` so the pre-render frame and the graded result can never be
    /// confused: one is the file as shot, the other is the stock applied to it.
    @State private var renderedPreview: CGImage?
    @State private var showHelp = false
    @State private var helpRefusal: String?

    var body: some View {
        ZStack {
            chooser
            if isActive, let job = activeJob {
                DevelopProgressOverlay(progress: queue.progress(for: job.id),
                                       queued: job.status == .pending)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DevelopPreviewChrome.surface)
        // One pick keeps the old step-one flow — preview, gauge, push/pull. More
        // than one skips the preview (there is only one panel to show it in) and
        // queues them all with what is selected now.
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            pickerItems = []
            if picked.count == 1 { model.select(picked[0]) } else { stageClips(picked) }
        }
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            photoPickerItems = []
            if picked.count == 1 { model.selectPhoto(picked[0]) } else { stagePhotos(picked) }
        }
        // The ungraded frame follows whatever is selected. Both are decoded from
        // the file itself, NOT through the render pipeline, so what is shown
        // before rendering is the file as shot.
        .task(id: selectedURL) {
            await loadPreview()
        }
        // The finished render is shown from the queue's own output file, so what
        // is on screen is the delivered artifact and not a re-render done for the
        // preview. A file that has already been cleaned up shows nothing.
        .task(id: renderedKey) {
            await loadRenderedPreview()
        }
        .sheet(isPresented: $showHelp) {
            DevelopMediaHelp(refusal: helpRefusal)
        }
    }

    private var renderedKey: String {
        guard let job = activeJob else { return "none" }
        // Receipt thumbnail size is part of the key: the durable thumbnail can
        // arrive after the file is gone, and the preview must then refresh.
        return "\(job.id)-\(job.status)-\(job.receipt?.thumbnailJPEG?.count ?? 0)"
            + "-\(job.outputURL?.path ?? "-")"
    }

    private func loadRenderedPreview() async {
        guard let job = activeJob, job.status == .completed else {
            renderedPreview = nil
            return
        }
        // The receipt's thumbnail is durable — it survives the local output being
        // cleaned up after delivery — so it is preferred over the file itself.
        if let receipt = job.receipt?.thumbnailJPEG,
           let image = DevelopPreviewLoader.thumbnail(from: receipt) {
            renderedPreview = image
            return
        }
        guard let url = job.outputURL else {
            renderedPreview = nil
            return
        }
        renderedPreview = await DevelopPreviewLoader.image(for: url, isPhoto: job.isPhoto == true)
    }

    /// A multi-pick STAGES the files. Nothing renders until the operator has
    /// seen them and chosen a stock, gauge and push/pull for the batch.
    private func stageClips(_ items: [PhotosPickerItem]) {
        bulkStatus = nil
        Task { @MainActor in
            let transfers: [DevelopVideoModel.TransferOperation] = items.map { item in
                { @MainActor in try await model.loadClip(from: item) }
            }
            await model.stageVideos(transfers: transfers)
            await loadBulkPreview()
        }
    }

    private func stagePhotos(_ items: [PhotosPickerItem]) {
        bulkStatus = nil
        Task { @MainActor in
            let transfers: [DevelopVideoModel.PhotoTransferOperation] = items.map { item in
                { @MainActor in try await model.loadPhoto(from: item) }
            }
            await model.stagePhotos(transfers: transfers)
            await loadBulkPreview()
        }
    }

    private func commitBulk() {
        guard let stock else { return }
        let result = model.commitBulk(stock: stock, gauge: gauge,
                                      pushPull: resolvedPushPull, queue: queue)
        bulkStatus = Self.bulkSummary(result)
        preview = nil
    }

    private func loadBulkPreview() async {
        guard let url = model.bulk.previewURL else { return }
        preview = await DevelopPreviewLoader.image(for: url, isPhoto: model.bulk.isPhotoStaging)
    }

    /// "Queued 5" or "Queued 4 · 1 skipped", because a bulk action that silently
    /// drops a file is worse than one that refuses them all.
    static func bulkSummary(_ result: DevelopVideoModel.BulkDevelopResult) -> String {
        let queued = "\(result.queued) added"
        guard !result.skipped.isEmpty else { return queued }
        return queued + " · \(result.skipped.count) skipped"
    }

    private var selectedURL: URL? {
        model.video?.url ?? model.photo?.url
    }

    private func loadPreview() async {
        guard let url = selectedURL else {
            preview = nil
            return
        }
        let isPhoto = model.photo != nil
        preview = await DevelopPreviewLoader.image(for: url, isPhoto: isPhoto)
    }

    // MARK: - Derived state

    private var activeJob: RenderJob? {
        guard let id = model.activeJobID else { return nil }
        return queue.jobs.first { $0.id == id }
    }

    private var isActive: Bool {
        guard let job = activeJob else { return false }
        return job.status == .pending || job.status == .processing
    }

    // MARK: - Content

    private var chooser: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 14) {
            if model.isLoading {
                transferState
            } else if !model.bulk.isEmpty {
                bulkState
            } else if let job = activeJob, job.status == .completed {
                completedState
            } else if let job = activeJob, job.status == .failed {
                failedState(job)
            } else {
                clipSelection
            }
            if let message = model.errorMessage, !model.isLoading {
                // Short on screen, detailed behind Why?. A refusal is the moment
                // the operator is most likely to give up, so it names the file
                // type and offers the way out in the same breath.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message)
                        .font(NitrateTypography.font(.footnote))
                        .foregroundStyle(DevelopPreviewChrome.warning)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("develop.error")
                    Button("Why?") {
                        helpRefusal = message
                        showHelp = true
                    }
                    .font(NitrateTypography.font(.footnote))
                    .foregroundStyle(DevelopPreviewChrome.orange)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("develop.error.why")
                }
            }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Everything picked in bulk, held before any of it renders.
    ///
    /// The same gauge and push/pull controls the single-file flow uses, plus the
    /// stock, so one deliberate choice covers the batch. Files that were refused
    /// are counted here rather than dropped silently.
    private var bulkState: some View {
        VStack(spacing: 12) {
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(model.bulk.count) files")
                            .font(NitrateTypography.font(.caption2))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(8)
                    }
                    .accessibilityIdentifier("develop.bulkPreview")
            }
            Text(bulkHeadline)
                .font(NitrateTypography.font(.callout))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("develop.bulkCount")
            if !model.bulk.skipped.isEmpty {
                Text("\(model.bulk.skipped.count) skipped")
                    .font(NitrateTypography.font(.caption2))
                    .foregroundStyle(DevelopPreviewChrome.warning)
            }
            stockMenu
            controlRow
            Button(action: commitBulk) {
                Text("Develop \(model.bulk.count)")
                    .font(NitrateTypography.font(.headline))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(DevelopPreviewChrome.orange, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(stock == nil || model.bulk.isEmpty)
            .accessibilityIdentifier("develop.bulkCommit")
            Button("Cancel") { model.clearBulk(); preview = nil }
                .font(NitrateTypography.font(.callout))
                .foregroundStyle(DevelopPreviewChrome.muted)
                .accessibilityIdentifier("develop.bulkCancel")
        }
    }

    private var bulkHeadline: String {
        let photos = model.bulk.photos.count
        let videos = model.bulk.videos.count
        switch (photos, videos) {
        case (let p, 0): return "\(p) photo\(p == 1 ? "" : "s") ready"
        case (0, let v): return "\(v) clip\(v == 1 ? "" : "s") ready"
        default: return "\(photos) photos · \(videos) clips ready"
        }
    }

    /// Stock choice for the batch, so a staged set is not locked to whatever the
    /// camera happens to be set to.
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
            HStack(spacing: 6) {
                Text(stock?.displayName ?? "Choose a stock")
                    .font(NitrateTypography.font(.subheadline))
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DevelopPreviewChrome.control, in: Capsule())
        }
        .accessibilityIdentifier("develop.bulkStock")
    }

    private var clipSelection: some View {
        VStack(spacing: 16) {
            // Two entry points, so the operator picks the medium first instead of
            // hunting for the right file type inside one picker.
            HStack(spacing: 10) {
                clipPicker(model.video == nil && model.photo == nil ? "Select Video" : "Change Video")
                photoPicker(model.video == nil && model.photo == nil ? "Select Photo" : "Change Photo")
            }
            // One line, and a way in to the rest. The picker cannot filter by
            // file type, so the rule is stated here rather than discovered after
            // a refusal, but a paragraph above the buttons pushes them off a
            // small screen.
            HStack(spacing: 6) {
                Text("Apple Log 2 · raw")
                    .font(NitrateTypography.font(.caption2))
                    .foregroundStyle(DevelopPreviewChrome.muted)
                Button {
                    helpRefusal = nil
                    showHelp = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(DevelopPreviewChrome.muted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("develop.help")
                .accessibilityLabel("What can I develop?")
            }
            .accessibilityIdentifier("develop.entryHint")
            if let video = model.video {
                identity(title: Self.videoTitle(video), detail: Self.videoDetail(video))
            } else if let photo = model.photo {
                identity(title: Self.photoTitle(photo), detail: photo.detailSummary)
            } else {
                Text("Choose a clip or a raw photo.")
                    .font(NitrateTypography.font(.footnote))
                    .foregroundStyle(DevelopPreviewChrome.muted)
            }

            if let preview {
                VStack(spacing: 6) {
                    // Fill the panel's width and crop the overflow. Sizing by
                    // height (`aspectRatio: .fit`) collapsed a portrait photo to
                    // a narrow column in a wide panel, which is what made this
                    // read as compressed.
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 196)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    // Say plainly that this is the file, not the look: the grade
                    // only exists after the render.
                    Text("Ungraded · as shot")
                        .font(NitrateTypography.font(.caption2))
                        .foregroundStyle(DevelopPreviewChrome.muted)
                }
                .accessibilityIdentifier("develop.preview")
            }

            if let bulkStatus {
                Text(bulkStatus)
                    .font(NitrateTypography.font(.caption))
                    .foregroundStyle(DevelopPreviewChrome.muted)
                    .accessibilityIdentifier("develop.bulkStatus")
            }

            if selectedURL != nil {
                controlRow
            }
        }
    }

    /// The same gauge and push/pull controls the stock sheet presents, bound to
    /// the parent's state so the render applies exactly what is shown here.
    private var controlRow: some View {
        HStack(alignment: .bottom, spacing: StockSheetLayout.controlSpacing) {
            GaugeControl(gauge: $gauge)
            PushPullControl(resolved: resolvedPushPull,
                            isAutomatic: $pushPullAutomatic,
                            manualStops: $pushPullStops,
                            onChange: onControlsChanged)
                .frame(maxWidth: 74)
        }
        .accessibilityIdentifier("develop.controls")
    }

    /// The identity of what was picked. A capture date and the media's own
    /// numbers, never the app's `clip_import_<UUID>.mov` working name.
    private func identity(title: String, detail: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(NitrateTypography.font(.callout))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(NitrateTypography.font(.caption).monospacedDigit())
                .foregroundStyle(DevelopPreviewChrome.muted)
                .multilineTextAlignment(.center)
        }
        .accessibilityIdentifier("develop.clipInfo")
    }

    private var transferState: some View {
        VStack(spacing: 14) {
            ProgressView().tint(DevelopPreviewChrome.orange)
            Text("Preparing clip…")
                .font(NitrateTypography.font(.callout))
                .foregroundStyle(.white)
            Button("Cancel") {
                model.cancelSelection()
                pickerItems = []
                photoPickerItems = []
            }
            .font(NitrateTypography.font(.callout))
            .foregroundStyle(DevelopPreviewChrome.orange)
            .frame(minHeight: 44)
            .accessibilityIdentifier("develop.cancel")
        }
    }

    private var completedState: some View {
        VStack(spacing: 14) {
            if let renderedPreview {
                VStack(spacing: 6) {
                    Image(decorative: renderedPreview, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 224)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("Graded · delivered file")
                        .font(NitrateTypography.font(.caption2))
                        .foregroundStyle(DevelopPreviewChrome.muted)
                }
                .accessibilityIdentifier("develop.renderedPreview")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(DevelopPreviewChrome.orange)
            }
            Text("Saved to Photos")
                .font(NitrateTypography.font(.headline))
                .foregroundStyle(.white)
                .accessibilityIdentifier("develop.saved")
            chooseAnotherActions
        }
    }

    private func failedState(_ job: RenderJob) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(DevelopPreviewChrome.orange)
            Text(job.errorMessage ?? "The render could not be completed.")
                .font(NitrateTypography.font(.callout))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("develop.failure")
            Button("Retry") { queue.retry(jobId: job.id) }
                .font(NitrateTypography.font(.headline))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(DevelopPreviewChrome.orange, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("develop.retry")
            chooseAnotherActions
        }
    }

    /// The way out of a finished or failed render: one title, then the same two
    /// entry points the panel starts with, so the next medium is a deliberate
    /// choice rather than whatever the single old button happened to open.
    private var chooseAnotherActions: some View {
        VStack(spacing: 10) {
            Text("Choose another")
                .font(NitrateTypography.font(.subheadline))
                .foregroundStyle(DevelopPreviewChrome.muted)
            HStack(spacing: 10) {
                clipPicker("Video")
                photoPicker("Photo")
            }
        }
        .accessibilityIdentifier("develop.chooseAnother")
    }

    private func clipPicker(_ title: String) -> some View {
        PhotosPicker(selection: $pickerItems, maxSelectionCount: 0, matching: .videos,
                     preferredItemEncoding: .current) {
            Label(title, systemImage: "photo.on.rectangle")
                .font(NitrateTypography.font(.headline))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(DevelopPreviewChrome.control, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(isActive)
        .accessibilityIdentifier("develop.choose")
    }

    private func photoPicker(_ title: String) -> some View {
        PhotosPicker(selection: $photoPickerItems, maxSelectionCount: 0, matching: .images,
                     preferredItemEncoding: .current) {
            Label(title, systemImage: "camera.aperture")
                .font(NitrateTypography.font(.headline))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(DevelopPreviewChrome.control, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(isActive)
        .accessibilityIdentifier("develop.choosePhoto")
    }

    /// "12 Nov 2026 at 14:03", or the only honest thing left when the file has no
    /// date: that the clip is selected.
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

/// Decodes the picked file's own first frame / thumbnail, with NO stock applied.
///
/// The grade only exists after the render, so the pre-render preview must not
/// pretend to it: this reads the file through AVFoundation or ImageIO and never
/// touches the render pipeline, the LUT or the film stages.
enum DevelopPreviewLoader {
    static let maxPixelSize: CGFloat = 1600

    static func image(for url: URL, isPhoto: Bool) async -> CGImage? {
        if isPhoto { return thumbnail(for: url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // Frame 1 rather than 0: some encoders write a black first sample.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    }

    /// Decode the receipt's stored thumbnail, so the finished render is still
    /// visible after the local output file has been cleaned up.
    static func thumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func thumbnail(for url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        // A raw's embedded preview is enough to identify the shot and is far
        // cheaper than developing it before the render.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Understated white/orange chrome shared with the rest of the app.
enum DevelopPreviewChrome {
    static let orange = SettingsControlChrome.halationOrange
    static let muted = Color.white.opacity(0.65)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.40)
    static let control = Color.white.opacity(0.10)
    static let surface = Color.black.opacity(0.85)
}
#endif
