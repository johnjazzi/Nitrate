import Foundation
import Testing

struct VideoImportServiceTests {
    private func fixture() throws -> (root: URL, source: URL, staging: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("provider.mov")
        try Data(repeating: 0x61, count: 2_100_000).write(to: source)
        return (root, source, root.appendingPathComponent("Originals"))
    }

    @Test func stagingCopiesAFileAndDiscardNeverChangesTheProviderOriginal() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owned = try await VideoImportService.copyToOwnedStorage(from: f.source, directory: f.staging)
        #expect(owned != f.source && owned.lastPathComponent.hasPrefix("clip_import_"))
        #expect(VideoImportService.isOwned(owned, directory: f.staging))
        #expect(try Data(contentsOf: owned) == Data(contentsOf: f.source))
        #expect(try owned.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        await VideoImportService.discard(f.source, directory: f.staging)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        await VideoImportService.discard(owned, directory: f.staging)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test func preCancelledCopyLeavesNoStagedFile() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let copy = Task { try await VideoImportService.copyToOwnedStorage(from: f.source, directory: f.staging) }
        copy.cancel()
        await #expect(throws: CancellationError.self) { try await copy.value }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: f.staging.path)) ?? []
        #expect(leftovers.isEmpty && FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test func discardRefusesSymbolicLinksAndCameraOriginals() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.staging, withIntermediateDirectories: true)
        let alias = f.staging.appendingPathComponent("clip_import_alias.mov")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.source)
        let camera = f.staging.appendingPathComponent("clip_camera.mov")
        try Data([1]).write(to: camera)
        #expect(!VideoImportService.isOwned(alias, directory: f.staging))
        await VideoImportService.discard(alias, directory: f.staging)
        await VideoImportService.discard(camera, directory: f.staging)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        #expect(FileManager.default.fileExists(atPath: alias.path))
        #expect(FileManager.default.fileExists(atPath: camera.path))
    }

    @Test func copyRejectsSymbolicSourcesAndStagingDirectories() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sourceAlias = f.root.appendingPathComponent("alias.mov")
        try FileManager.default.createSymbolicLink(at: sourceAlias, withDestinationURL: f.source)
        await #expect(throws: (any Error).self) {
            try await VideoImportService.copyToOwnedStorage(from: sourceAlias, directory: f.staging)
        }
        try FileManager.default.createDirectory(at: f.staging, withIntermediateDirectories: true)
        let directoryAlias = f.root.appendingPathComponent("alias-directory")
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: f.staging)
        await #expect(throws: (any Error).self) {
            try await VideoImportService.copyToOwnedStorage(from: f.source, directory: directoryAlias)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path).isEmpty)
    }

    @Test func unreadableAndMissingInputsCannotBeSelected() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: (any Error).self) { try await VideoImportService.inspect(url: f.source) }
        let missing = f.root.appendingPathComponent("missing.mov")
        await #expect(throws: (any Error).self) { try await VideoImportService.inspect(url: missing) }
        #expect(FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test func abandonedLeaseDiscardsOnlyItsOwnedCopy() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owned = try await VideoImportService.copyToOwnedStorage(from: f.source, directory: f.staging)
        var lease: VideoImportFileLease? = VideoImportFileLease(url: owned, directory: f.staging)
        #expect(lease?.url == owned)
        lease = nil
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: owned.path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test func durableQueueHandoffKeepsTheOwnedFile() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owned = try await VideoImportService.copyToOwnedStorage(from: f.source, directory: f.staging)
        var lease: VideoImportFileLease? = VideoImportFileLease(url: owned, directory: f.staging)
        lease?.transferToQueue()
        lease = nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: f.source.path))
    }
}
