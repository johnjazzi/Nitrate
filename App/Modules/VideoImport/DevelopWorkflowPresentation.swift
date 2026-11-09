import Foundation

/// Shared presentation policy, also exercised by the platform-neutral test target.
enum DevelopWorkflowPresentation {
    enum Stage: Equatable {
        case loading, review, rendering, results, chooser
    }

    static func stage(loading: Bool, active: Bool, sourceCount: Int, resultCount: Int) -> Stage {
        if loading { return .loading }
        if active { return .rendering }
        if resultCount > 0 { return .results }
        if sourceCount > 0 { return .review }
        return .chooser
    }

    /// Queue storage order is not selection order. Missing jobs remain visible in the UI.
    static func orderedJobs(ids: [UUID], jobs: [RenderJob]) -> [RenderJob?] {
        ids.map { id in jobs.first { $0.id == id } }
    }

    struct Redevelopment: Equatable {
        let availableIDs: [UUID]
        let missingCount: Int
        var isEnabled: Bool { !availableIDs.isEmpty }
    }

    static func redevelopment(jobs: [RenderJob], requestedCount: Int) -> Redevelopment {
        let available = jobs.filter(\.hasRedevelopableSource).map(\.id)
        return Redevelopment(availableIDs: available, missingCount: max(0, requestedCount - available.count))
    }

    static func exposure(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%+.1f EV", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func captureRating(_ iso: Float?) -> String {
        guard let iso, iso.isFinite, iso > 0 else { return "—" }
        return String(format: "ISO %.0f", locale: Locale(identifier: "en_US_POSIX"), iso)
    }

    static func deliveryLabel(_ job: RenderJob) -> String {
        switch job.status {
        case .completed:
            return job.outputSavedToPhotos == true ? "Saved" : "Local only"
        case .failed: return "Failed"
        case .pending: return "Queued"
        case .processing: return "Developing…"
        case .awaitingStock: return "Choose stock"
        }
    }

    static func zoom(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(max(value, 1), 8)
    }
}

/// Every pixel-affecting setting participates in preview invalidation, including the
/// full stock value (not just its identifier). Never use this estimate as camera metering.
struct DevelopPreviewRecipe: Equatable, Sendable {
    let url: URL
    let isPhoto: Bool
    let cropZoom: Double
    let stock: FilmStockConfig
    let gauge: PrintGauge
    let pushPull: PushPullExposure
}

/// A late completion must match both the request and its generation. Re-requesting
/// an identical recipe after a selection change must not accept an earlier task.
struct DevelopPreviewFence: Sendable {
    private(set) var token = UUID()

    mutating func begin() -> UUID {
        token = UUID()
        return token
    }

    func accepts(_ candidate: UUID, cancelled: Bool) -> Bool {
        !cancelled && candidate == token
    }
}
