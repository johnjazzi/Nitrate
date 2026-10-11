import SwiftUI

/// Compact render activity control. Completion means the movie reached Photos.
struct RenderStatusButton: View {
    let viewModel: RenderQueueViewModel
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var outstandingCount: Int {
        viewModel.outstandingCount
    }

    private var failedCount: Int {
        viewModel.jobs.filter { $0.status == .failed }.count
    }

    private var hasError: Bool {
        failedCount > 0 || viewModel.rendererErrorMessage != nil
    }

    private var isComplete: Bool {
        outstandingCount == 0 && !hasError && viewModel.jobs.last?.status == .completed
            && viewModel.jobs.last?.outputSavedToPhotos == true
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if outstandingCount > 0 {
                        loadingRing
                    } else if hasError {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.red)
                    } else if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 36, height: 36)

                if outstandingCount > 1 {
                    Text("\(outstandingCount)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.purple, in: Capsule())
                        .offset(x: 10, y: -8)
                }
                if hasError && outstandingCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .background(.black, in: Circle())
                        .offset(x: -24, y: -6)
                }
            }
            .frame(minWidth: 52, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Render activity")
        .accessibilityValue(statusDescription)
        .accessibilityHint("Opens video details, errors, and retry controls")
    }

    private var loadingRing: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let rotation = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.4) / 1.4 * 360
            Circle()
                .trim(from: 0, to: 0.85)
                .stroke(
                    AngularGradient(colors: [.orange, .purple, .red, .orange], center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))
        }
    }

    private var statusDescription: String {
        if outstandingCount > 0 {
            let failures = hasError ? " A video failed; open details." : ""
            return "\(outstandingCount) videos outstanding, \(viewModel.pendingCount) waiting.\(failures)"
        }
        if hasError {
            return viewModel.rendererErrorMessage ?? "\(failedCount) videos failed. Open details to retry."
        }
        return isComplete ? "Video saved to Photos" : "No active renders"
    }
}
