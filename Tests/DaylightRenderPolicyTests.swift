import Foundation
import Testing
import AVFoundation

/// Render-time policy: metadata from the persisted capture policy, and the queue
/// path that carries the policy from enqueue through assignment and relaunch.
struct DaylightRenderPolicyTests {
    private func stock() throws -> FilmStockConfig {
        FilmStockConfig(stockId: "test", displayName: "Kodak 5219", category: .video,
                        lutName: "test.cube", halationStrength: 0, glowStrength: 0,
                        grainSize: 1, defaultISO: 600)
    }

    private func values(_ items: [AVMetadataItem]) -> [String: String] {
        var values: [String: String] = [:]
        for item in items {
            if let key = item.key as? String, let value = item.value as? String { values[key] = value }
        }
        return values
    }

    @Test func sixtyPolicyEmitsOneOneTwentyShutterAtOneEightyDegrees() throws {
        let config = try stock()
        let items = try RenderMovieMetadata.make(config: config, capturePolicy: RenderCapturePolicy(60))
        let map = values(items)
        #expect(map["com.filmemulation.shutter-speed"] == "1/120")
        // shutter-angle is 180 for both modes.
        #expect(map["com.filmemulation.shutter-angle"] == "180")
        #expect(map["com.filmemulation.capture-frame-rate"] == "60")
    }

    @Test func legacyNilPolicyKeepsOneFortyEightShutter() throws {
        let config = try stock()
        let items = try RenderMovieMetadata.make(config: config)
        let map = values(items)
        #expect(map["com.filmemulation.shutter-speed"] == "1/48")
        #expect(map["com.filmemulation.shutter-angle"] == "180")
    }

    @Test func twentyFourPolicyIsByteForByteTheLegacyShutter() throws {
        let config = try stock()
        let legacy = values(try RenderMovieMetadata.make(config: config))
        let twentyFour = values(try RenderMovieMetadata.make(config: config, capturePolicy: RenderCapturePolicy(24)))
        #expect(twentyFour["com.filmemulation.shutter-speed"] == "1/48")
        #expect(twentyFour["com.filmemulation.shutter-speed"] == legacy["com.filmemulation.shutter-speed"])
    }
}

@Suite("Daylight capture policy queue paths", .serialized)
@MainActor
struct DaylightCapturePolicyQueueTests {
    private func scratch() throws -> (directory: URL, source: URL, output: URL, persistence: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.mov")
        let output = directory.appendingPathComponent("rendered.mov")
        try Data([1, 2, 3]).write(to: source)
        return (directory, source, output, directory.appendingPathComponent("queue.json"))
    }

    @Test func awaitingStockCarriesPolicyAndAssignStockKeepsIt() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in files.output })

        let jobId = try #require(model.enqueueAwaitingStock(sourceURL: files.source,
                                                            capturePolicy: RenderCapturePolicy(60)))
        #expect(model.jobs.first?.capturePolicy == RenderCapturePolicy(60))
        model.assignStock(jobId: jobId, stockId: "kodak5219", iso: 600)
        #expect(model.jobs.first?.capturePolicy == RenderCapturePolicy(60))
    }

    @Test func policySurvivesRelaunchFromPersistedQueue() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let first = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in files.output })
        _ = first.enqueueAwaitingStock(sourceURL: files.source, capturePolicy: RenderCapturePolicy(60))

        let relaunched = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in files.output })
        relaunched.onAppear()
        #expect(relaunched.jobs.first?.capturePolicy == RenderCapturePolicy(60))
    }
}
