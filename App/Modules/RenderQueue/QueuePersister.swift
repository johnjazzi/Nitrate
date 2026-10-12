import Foundation

/// AD-7: JSON persistence for render jobs to survive app backgrounding.
/// Saves job metadata to renderQueue.json in app documents.
final class QueuePersister {
    private let storageURL: URL

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.storageURL = documents.appendingPathComponent("renderQueue.json")
        }
    }

    /// Save jobs array to disk.
    func save(_ jobs: [RenderJob]) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(jobs)
        try data.write(to: storageURL, options: .atomic)
    }

    /// Load jobs array from disk. Returns empty if no persisted state.
    func load() throws -> [RenderJob] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return []
        }
        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        // Decode element-wise: a single job written by an older build (or with a
        // value this build no longer understands) must not make the whole queue
        // unreadable. Unreadable entries are dropped, the rest are kept.
        return try decoder.decode([FailableJob].self, from: data).compactMap(\.job)
    }

    /// One array element that decodes to `nil` instead of throwing, so a bad
    /// entry is skipped rather than failing the whole load.
    private struct FailableJob: Decodable {
        let job: RenderJob?

        init(from decoder: Decoder) throws {
            job = try? RenderJob(from: decoder)
        }
    }

    /// Clear persisted state.
    func clear() throws {
        if FileManager.default.fileExists(atPath: storageURL.path) {
            try FileManager.default.removeItem(at: storageURL)
        }
    }
}
