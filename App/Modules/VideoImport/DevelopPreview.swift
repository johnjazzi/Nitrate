#if os(iOS)
import SwiftUI
import PhotosUI

/// Inline Develop surface. It is the clip chooser for the D-V mode: it chooses or
/// changes the selected clip, shows genuine render progress over the whole
/// supplied frame while a job is pending or processing, and reports completion or
/// failure.
///
/// It deliberately contains no media frames, thumbnails, `AVPlayer`, or stock
/// samples, and no stock / gauge controls or render button: the parent owns the
/// stock and gauge controls and the shutter starts the render.
struct DevelopPreview: View {
    let model: DevelopVideoModel
    let queue: RenderQueueViewModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var photoPickerItem: PhotosPickerItem?

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
            if let video = model.video {
                identity(title: Self.videoTitle(video), detail: Self.videoDetail(video))
            } else if let photo = model.photo {
                identity(title: Self.photoTitle(photo), detail: photo.detailSummary)
            } else {
                Text("Choose an Apple Log 2 clip or a raw photo to develop.")
                    .font(NitrateTypography.font(.footnote))
                    .foregroundStyle(DevelopPreviewChrome.muted)
            }
        }
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
            clipPicker("Choose Another Clip")
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
            clipPicker("Choose Another Clip")
        }
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

/// Understated white/orange chrome shared with the rest of the app.
private enum DevelopPreviewChrome {
    static let orange = SettingsControlChrome.halationOrange
    static let muted = Color.white.opacity(0.65)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.40)
    static let control = Color.white.opacity(0.10)
    static let surface = Color.black.opacity(0.85)
}
#endif
