import AVFoundation
import Foundation

struct ImportedVideo: Sendable, Equatable {
    let url: URL
    let originalFilename: String
    let durationSeconds: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let nominalFrameRate: Double
}

enum VideoImportError: LocalizedError {
    case unsupported, unreadable, insufficientStorage

    var errorDescription: String? {
        switch self {
        case .unsupported: return "Choose an Apple Log 2 video."
        case .unreadable: return "This video could not be read. Try selecting it again."
        case .insufficientStorage: return "Free some storage before importing this video."
        }
    }
}

enum VideoImportService {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Originals", isDirectory: true)
    }

    /// File-backed, bounded-memory copy. The provider URL is never modified.
    static func copyToOwnedStorage(from sourceURL: URL, directory: URL? = nil) async throws -> URL {
        let destinationDirectory = directory ?? self.directory
        let operation = Task.detached(priority: .userInitiated) {
            try copyFile(from: sourceURL, directory: destinationDirectory)
        }
        return try await withTaskCancellationHandler {
            let owned = try await operation.value
            if Task.isCancelled {
                await discard(owned, directory: destinationDirectory)
                throw CancellationError()
            }
            return owned
        } onCancel: {
            operation.cancel()
        }
    }

    private static func copyFile(from source: URL, directory: URL) throws -> URL {
        try Task.checkCancellation()
        guard source.isFileURL else { throw VideoImportError.unreadable }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let fileSize = values.fileSize, fileSize > 0 else { throw VideoImportError.unreadable }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard systemPath(directory) == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw VideoImportError.unreadable
        }
        let capacity = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < Int64(fileSize) || capacity - Int64(fileSize) < 64 * 1024 * 1024 {
            throw VideoImportError.insufficientStorage
        }
        let owned = directory.appendingPathComponent("clip_import_\(UUID().uuidString).mov")
        guard manager.createFile(atPath: owned.path, contents: nil) else { throw VideoImportError.unreadable }
        var complete = false
        defer { if !complete { try? manager.removeItem(at: owned) } }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: owned)
        defer { try? output.close() }
        var copied = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            copied += chunk.count
        }
        try Task.checkCancellation()
        guard copied == fileSize else { throw VideoImportError.unreadable }
        try output.synchronize()
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var destination = owned
        try destination.setResourceValues(excluded)
        complete = true
        return owned
    }

    static func inspect(url: URL, originalFilename: String? = nil) async throws -> ImportedVideo {
        try Task.checkCancellation()
        guard url.isFileURL else { throw VideoImportError.unreadable }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0 else { throw VideoImportError.unreadable }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isReadable),
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoImportError.unreadable
        }
        let descriptions = try await track.load(.formatDescriptions)
        do { _ = try RenderInputColorProvenance.inspect(descriptions) }
        catch { throw VideoImportError.unsupported }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let upright = CGRect(origin: .zero, size: size).applying(transform)
        let width = abs(upright.width), height = abs(upright.height)
        let rate = Double(try await track.load(.nominalFrameRate))
        guard duration.isFinite, duration > 0, width.isFinite, height.isFinite,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              rate.isFinite, rate > 0 else { throw VideoImportError.unreadable }
        try Task.checkCancellation()
        return ImportedVideo(url: url, originalFilename: originalFilename ?? url.lastPathComponent,
                             durationSeconds: duration, pixelWidth: Int(width.rounded()),
                             pixelHeight: Int(height.rounded()), nominalFrameRate: rate)
    }

    /// Only our own unqueued import names can be discarded. Queue acceptance
    /// transfers ownership to the existing durable media-cleanup transaction.
    static func discard(_ ownedURL: URL, directory: URL? = nil) async {
        let root = directory ?? self.directory
        let operation = Task.detached(priority: .utility) {
            guard isOwned(ownedURL, directory: root) else { return }
            try? FileManager.default.removeItem(at: ownedURL)
        }
        await operation.value
    }

    static func isOwned(_ url: URL, directory: URL) -> Bool {
        guard url.isFileURL, !url.pathComponents.contains(".."),
              url.pathExtension == "mov", url.lastPathComponent.hasPrefix("clip_import_"),
              url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              systemPath(url) == url.resolvingSymlinksInPath().standardizedFileURL.path,
              systemPath(directory) == directory.resolvingSymlinksInPath().standardizedFileURL.path,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return true
    }

    private static func systemPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/var/") else { return path }
        return URL(fileURLWithPath: "/var").resolvingSymlinksInPath().path + path.dropFirst(4)
    }
}
