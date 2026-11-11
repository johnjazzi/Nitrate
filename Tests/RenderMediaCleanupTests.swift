import Foundation
import Testing

@Suite("Owned render media cleanup")
struct RenderMediaCleanupTests {
    @Test func retainedSourceFlagIsOptionalAndBothMediaTypesRequireNonemptyRegularOriginals() throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_import_original.mov", in: fixture.sources)
        var video = RenderJob(sourceURL: source, stockId: "test", iso: 400)
        let legacyData = try JSONEncoder().encode(video)
        let legacy = try JSONDecoder().decode(RenderJob.self, from: legacyData)
        #expect(legacy.retainsDevelopmentSource == nil)
        #expect(legacy.hasRedevelopableSource)
        #expect(!legacy.hasRedevelopableOriginal, "the old API remains photo-only")
        video.retainsDevelopmentSource = true
        video.sourceOriginalFilename = "take.mov"
        video.sourceCapturedOffsetEV = 1.25
        #expect(try JSONDecoder().decode(RenderJob.self, from: JSONEncoder().encode(video)) == video)
        var photo = video
        photo.isPhoto = true
        #expect(photo.hasRedevelopableOriginal)
        try Data().write(to: source)
        #expect(!video.hasRedevelopableSource)
        #expect(!photo.hasRedevelopableOriginal)
        try FileManager.default.removeItem(at: source)
        #expect(!video.hasRedevelopableSource)
        var directory = video
        directory.sourceURL = fixture.sources
        #expect(!directory.hasRedevelopableSource)
    }

    @Test func developmentPhotoRemovalNeedsExplicitOptInAndOwnedDirectPath() throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let raw = try fixture.movie("photo_import_owned.nef", in: fixture.sources)
        let jpeg = try fixture.movie("photo_import_owned.jpg", in: fixture.sources)
        let unrelated = try fixture.movie("holiday.nef", in: fixture.sources)
        let outside = try fixture.movie("photo_import_outside.dng", in: fixture.root)
        let link = fixture.sources.appendingPathComponent("photo_import_link.dng")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(try !fixture.cleaner.removeIfOwned(raw))
        #expect(try !fixture.cleaner.removeIfOwned(jpeg))
        #expect(try !fixture.cleaner.removeIfOwned(unrelated, includeDevelopmentPhoto: true))
        #expect(try !fixture.cleaner.removeIfOwned(outside, includeDevelopmentPhoto: true))
        #expect(try !fixture.cleaner.removeIfOwned(link, includeDevelopmentPhoto: true))
        #expect(try fixture.cleaner.removeIfOwned(raw, includeDevelopmentPhoto: true))
        #expect(try fixture.cleaner.removeIfOwned(jpeg, includeDevelopmentPhoto: true))
        #expect(try fixture.cleaner.removeIfOwned(raw, includeDevelopmentPhoto: true))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func onlyDirectOwnedRegularMoviesAreRemoved() throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_owned.mov", in: fixture.sources)
        let output = try fixture.movie("render_owned.mov", in: fixture.outputs)
        let unrelated = try fixture.movie("holiday.mov", in: fixture.outputs)
        let outside = try fixture.movie("render_outside.mov", in: fixture.root)
        let nested = fixture.outputs.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedMovie = try fixture.movie("render_nested.mov", in: nested)
        let symlink = fixture.outputs.appendingPathComponent("render_link.mov")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let directory = fixture.outputs.appendingPathComponent("render_directory.mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for url in [source, output, unrelated, outside, nestedMovie, symlink, directory] {
            _ = try fixture.cleaner.removeIfOwned(url)
        }
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        for url in [unrelated, outside, nestedMovie, symlink, directory] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(try fixture.cleaner.removeIfOwned(output))
    }

    @Test func symlinkedRootAndTraversalAreRejected() throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let outside = try fixture.movie("render_other.mov", in: fixture.root)
        let traversal = URL(fileURLWithPath: fixture.outputs.path + "/../render_other.mov")
        #expect(try !fixture.cleaner.removeIfOwned(traversal))
        let link = fixture.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outputs)
        let movie = try fixture.movie("render_keep.mov", in: fixture.outputs)
        let cleaner = RenderMediaCleanup(sourceRoot: fixture.sources, outputRoot: link)
        #expect(try !cleaner.removeIfOwned(link.appendingPathComponent(movie.lastPathComponent)))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: movie.path))
    }
}

struct ExportCleanupFixture {
    let root: URL
    let sources: URL
    let outputs: URL
    var cleaner: RenderMediaCleanup { RenderMediaCleanup(sourceRoot: sources, outputRoot: outputs) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sources = root.appendingPathComponent("Originals")
        outputs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
    }

    func movie(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
