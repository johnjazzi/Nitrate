import Foundation
import Testing

@Suite("Camera original storage", .serialized)
@MainActor
struct CameraOriginalStorageTests {
    @Test func destinationsAreUniqueEvenWhenPreviousFilesExist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CameraOriginalStorage(rootDirectory: root)
        let destinations = try (0..<40).map { _ in try storage.makeDestination() }

        #expect(Set(destinations).count == destinations.count)
        for destination in destinations {
            // Compare paths, not URLs: deletingLastPathComponent() returns a
            // URL with a trailing slash, so URL equality fails against the
            // root even when the paths are identical.
            #expect(destination.deletingLastPathComponent().path == root.path)
            try Data([1]).write(to: destination)
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }
        let next = try storage.makeDestination()
        #expect(!FileManager.default.fileExists(atPath: next.path))
    }

    @Test func queuedOriginalSurvivesTemporaryDirectoryRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try CameraOriginalStorage(rootDirectory: root.appendingPathComponent("Originals"))
            .makeDestination()
        let expectedBytes = Data([7, 8, 9, 10])
        try expectedBytes.write(to: source)
        try Data([0]).write(to: temporary.appendingPathComponent("unrelated.tmp"))
        let output = root.appendingPathComponent("rendered.mov")
        try Data([4, 5, 6]).write(to: output)
        let persistence = root.appendingPathComponent("queue.json")
        let queued = RenderJob(sourceURL: source, stockId: "test", iso: 400)
        try QueuePersister(storageURL: persistence).save([queued])

        try FileManager.default.removeItem(at: temporary)
        let model = RenderQueueViewModel(persistenceURL: persistence, render: { job in
            let delivered = try Data(contentsOf: job.sourceURL)
            #expect(delivered == expectedBytes)
            return output
        }, save: { _ in })
        model.onAppear()
        for _ in 0..<200 where model.jobs.first?.status != .completed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.jobs.first?.status == .completed)
        #expect(try Data(contentsOf: source) == expectedBytes)
    }
}
