import Foundation

/// Owns finalized camera originals for as long as their queue jobs can recover.
struct CameraOriginalStorage {
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory ?? fileManager.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask)[0]
            .appendingPathComponent("Originals", isDirectory: true)
        self.fileManager = fileManager
    }

    func makeDestination() throws -> URL {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        return rootDirectory.appendingPathComponent("clip_\(UUID().uuidString).mov")
    }
}
