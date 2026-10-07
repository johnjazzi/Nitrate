import Foundation

/// AD-7: JSON persistence for render jobs to survive app backgrounding.
/// Saves job metadata to renderQueue.json in app documents.
final class QueuePersister {
    private let storageURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageURL = documents.appendingPathComponent("renderQueue.json")
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
        return try decoder.decode([RenderJob].self, from: data)
    }

    /// Clear persisted state.
    func clear() throws {
        if FileManager.default.fileExists(atPath: storageURL.path) {
            try FileManager.default.removeItem(at: storageURL)
        }
    }
}