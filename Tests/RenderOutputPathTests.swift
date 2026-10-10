import Foundation
import Testing

/// Regression cover for the render-output name collision.
///
/// The output name used to be `render_<unix-seconds>.mov`, which is only
/// second-resolution. Two renders starting in the same second produced the same
/// path; AVAssetWriter refuses to overwrite and failed with "Cannot Save". The
/// queue's failure path then saved the *source* clip to Photos, so the user saw
/// a clip with no grade and no metadata and reasonably concluded the render had
/// silently broken.
@Suite("Render output paths")
struct RenderOutputPathTests {

    private static func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-output-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The exact defect: two calls with the same timestamp must not agree.
    @Test func sameSecondRendersDoNotCollide() throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let timestamp = Date(timeIntervalSince1970: 1_791_598_612)
        let names = Set(
            (0..<64).map { _ in
                PipelineRenderer.uniqueOutputURL(in: directory, now: timestamp).lastPathComponent
            }
        )

        #expect(
            names.count > 1,
            "64 renders in the same second all produced one name; a second render would fail to save"
        )
    }

    /// A name already on disk must never be handed out, even if the random
    /// suffix happens to match, because the writer cannot overwrite it.
    @Test func existingFileIsNeverReused() throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var seen: Set<String> = []
        for _ in 0..<32 {
            let url = PipelineRenderer.uniqueOutputURL(in: directory)
            #expect(!seen.contains(url.lastPathComponent), "handed out a name that was already used")
            #expect(!FileManager.default.fileExists(atPath: url.path), "handed out a path that exists")
            // Occupy it so the next call has to avoid this name too.
            try Data().write(to: url)
            seen.insert(url.lastPathComponent)
        }
        #expect(seen.count == 32)
    }

    /// The rendered file must be a `.mov` in the requested directory.
    @Test func outputStaysAMoveInTheRequestedDirectory() throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = PipelineRenderer.uniqueOutputURL(in: directory)
        #expect(url.pathExtension == "mov")
        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
    }
}
