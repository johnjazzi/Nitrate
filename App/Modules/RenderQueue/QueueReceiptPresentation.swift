import Foundation

/// Local receipt presentation only; never consults the Photos library or current stock catalog.
enum QueueReceiptPresentation {
    static let unavailable = "Unavailable"
    static let minimumActionHeight: CGFloat = 44
    static let photosActionID = "queue.openPhotos"
    static let metadataActionID = "queue.metadata"

    struct Candidate {
        let id: UUID
        let completed: Bool
        let originalOnly: Bool
        let createdAt: Date
        var recordedAt: Date?
    }

    static func latestRenderID(in candidates: [Candidate]) -> UUID? {
        candidates.filter { $0.completed && !$0.originalOnly }.max {
            ($0.recordedAt ?? $0.createdAt) < ($1.recordedAt ?? $1.createdAt)
        }?.id
    }

    struct Actions {
        let openPhotos: Bool
        let playLocal: Bool
        let shareLocal: Bool
        let metadata = true

        init(savedToPhotos: Bool, retainedOutput: Bool) {
            openPhotos = savedToPhotos
            playLocal = retainedOutput
            shareLocal = retainedOutput
        }
    }

    static func number(_ value: Double?, suffix: String = "") -> String {
        guard let value, value.isFinite, value >= 0 else { return unavailable }
        return value.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .grouping(.never).precision(.fractionLength(0...2))) + suffix
    }

    static func metadata(_ values: [String: String], _ suffix: String) -> String {
        text(values["com.filmemulation." + suffix])
    }

    static func numericMetadata(_ values: [String: String], _ suffix: String) -> String {
        number(values["com.filmemulation." + suffix].flatMap(Double.init))
    }

    static func text(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unavailable
        }
        return value
    }

    static func savedStatus(_ saved: Bool?) -> String {
        switch saved {
        case true: "Saved"
        case false: "Not confirmed saved"
        case nil: "Unknown (legacy record)"
        }
    }
}
