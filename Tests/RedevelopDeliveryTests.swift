import Foundation
import Testing

/// A re-develop must render AND deliver again.
///
/// The queue skips the Photos save when `outputSavedToPhotos == true`, so a
/// re-develop that failed to clear that flag would render a new file and save
/// nothing — the panel then shows the old delivered still as if nothing
/// happened. Measured at the seam: count the deliveries.
@Suite(.serialized)
struct RedevelopDeliveryTests {
    @MainActor
    @Test func redevelopingAPhotoDeliversASecondTime() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("redev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("photo_import_A.dng")
        try Data([1]).write(to: source)

        let saves = SaveCounter()
        let queue = RenderQueueViewModel(persistenceURL: folder.appendingPathComponent("q.json"),
            render: { _ in
                let out = folder.appendingPathComponent("out-\(UUID().uuidString).jpg")
                try Data([2]).write(to: out)
                return out
            }, save: { _ in saves.count += 1 })

        let id = try #require(queue.enqueuePhoto(sourceURL: source, stockId: "kodak5207", iso: 250,
                                                 gauge: .neutral, cropZoom: 1, seed: 1,
                                                 isImported: true))
        try await Self.wait { queue.jobs.first?.status == .completed }
        #expect(saves.count == 1, "the first develop delivers once")
        #expect(queue.jobs.first?.outputSavedToPhotos == true)

        let requeued = queue.redevelopPhotos(jobIds: [id], gauge: .eightMillimetre)
        #expect(requeued == 1, "the re-develop is accepted")
        try await Self.wait { queue.jobs.first?.status == .completed && queue.jobs.first?.printGauge == .eightMillimetre }

        #expect(saves.count == 2, "the re-develop must deliver again, not reuse the old save")
        #expect(queue.jobs.first?.outputSavedToPhotos == true, "and say it was saved")
    }

    @MainActor
    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for the queue")
    }

    /// Reference type: the closures are escaping and the count crosses actors.
    private final class SaveCounter: @unchecked Sendable {
        var count = 0
    }
}
