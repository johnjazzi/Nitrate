import Foundation
import Testing

@Suite("Owned render media cleanup")
struct RenderMediaCleanupTests {
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
