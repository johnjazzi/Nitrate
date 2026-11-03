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
    @Binding var gauge: PrintGauge
    @Binding var pushPullAutomatic: Bool
    @Binding var pushPullStops: PushPullStops
    /// Called after a change so the parent can persist the preference.
    var onControlsChanged: () -> Void = {}
    /// The exposure the parent resolved for this render, shown in the pill.
    var resolvedPushPull: PushPullExposure = .neutral

    @State private var pickerItem: PhotosPickerItem?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var preview: CGImage?

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
        .onChange(of: pickerItem) { _, item in
            if let item {
                model.select(item)
                pickerItem = nil
            }
        }
        .onChange(of: photoPickerItem) { _, item in
            if let item {
                model.selectPhoto(item)
                photoPickerItem = nil
            }
        }
        // The ungraded frame follows whatever is selected. Both are decoded from
        // the file itself, NOT through the render pipeline, so what is shown
        // before rendering is the file as shot.
        .task(id: selectedURL) {
            await loadPreview()
        }
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
        VStack(spacing: 18) {
            if model.isLoading {
                transferState
            } else if let job = activeJob, job.status == .completed {
                completedState
            } else if let job = activeJob, job.status == .failed {
                failedState(job)
            } else {
                clipSelection
            }
            if let message = model.errorMessage, !model.isLoading {
                Text(message)
                    .font(NitrateTypography.font(.footnote))
                    .foregroundStyle(DevelopPreviewChrome.warning)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("develop.error")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var clipSelection: some View {
        VStack(spacing: 16) {
            // Two entry points, so the operator picks the medium first instead of
            // hunting for the right file type inside one picker.
            HStack(spacing: 10) {
                clipPicker(model.video == nil && model.photo == nil ? "Select Video" : "Change Video")
                photoPicker(model.video == nil && model.photo == nil ? "Select Photo" : "Change Photo")
            }
            // The picker shows every image, because Photos cannot filter by file
            // type. Say up front which ones the pipeline can develop.
            Text("Video: Apple Log 2 only. Photo: raw files only — DNG, NEF, ARW, "
                 + "CR2/CR3, RAF, ORF, RW2. Anything else is refused before it is copied.")
                .font(NitrateTypography.font(.caption2))
                .foregroundStyle(DevelopPreviewChrome.muted)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("develop.entryHint")
            if let video = model.video {
                identity(title: Self.videoTitle(video), detail: Self.videoDetail(video))
            } else if let photo = model.photo {
                identity(title: Self.photoTitle(photo), detail: photo.detailSummary)
            } else {
                Text("Choose an Apple Log 2 clip or a raw photo to develop.")
                    .font(NitrateTypography.font(.footnote))
                    .foregroundStyle(DevelopPreviewChrome.muted)
            }

            if let preview {
                VStack(spacing: 6) {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    // Say plainly that this is the file, not the look: the grade
                    // only exists after the render.
                    Text("Ungraded · as shot")
                        .font(NitrateTypography.font(.caption2))
                        .foregroundStyle(DevelopPreviewChrome.muted)
                }
                .accessibilityIdentifier("develop.preview")
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
                pickerItem = nil
            }
            .font(NitrateTypography.font(.callout))
            .foregroundStyle(DevelopPreviewChrome.orange)
            .frame(minHeight: 44)
            .accessibilityIdentifier("develop.cancel")
        }
    }

    private var completedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(DevelopPreviewChrome.orange)
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
        PhotosPicker(selection: $pickerItem, matching: .videos, preferredItemEncoding: .current) {
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
        PhotosPicker(selection: $photoPickerItem, matching: .images,
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
private enum DevelopPreviewChrome {
    static let orange = SettingsControlChrome.halationOrange
    static let muted = Color.white.opacity(0.65)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.40)
    static let control = Color.white.opacity(0.10)
    static let surface = Color.black.opacity(0.85)
}
#endif
