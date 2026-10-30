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
            clipPicker(model.video == nil ? "Choose Clip" : "Change Clip")
            if let video = model.video {
                VStack(spacing: 4) {
                    Text(video.originalFilename)
                        .font(NitrateTypography.font(.callout))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(technicalSummary(video))
                        .font(NitrateTypography.font(.caption))
                        .foregroundStyle(DevelopPreviewChrome.muted)
                }
                .accessibilityIdentifier("develop.clipInfo")
            } else {
                Text("Choose an Apple Log 2 clip to develop.")
                    .font(NitrateTypography.font(.footnote))
                    .foregroundStyle(DevelopPreviewChrome.muted)
            }
        }
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

    private func technicalSummary(_ video: ImportedVideo) -> String {
        "\(video.pixelWidth) × \(video.pixelHeight) · "
            + String(format: "%.1f s", video.durationSeconds) + " · "
            + String(format: "%.2f fps", video.nominalFrameRate)
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
