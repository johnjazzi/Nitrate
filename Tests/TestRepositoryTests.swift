import Foundation
import Testing

/// Pins the fixture-resolution contract: the packaged snapshot wins over the
/// `#filePath` checkout, and the chosen root is a readable directory holding
/// every required fixture. A failure here means the suites would read the wrong
/// tree (or an unreadable one) rather than a test that legitimately varies.
@Suite("Test repository fixtures")
struct TestRepositoryTests {
    @Test func packagedSnapshotIsPreferredOverTheCheckout() {
        let packaged = URL(fileURLWithPath: "/tmp/packaged-snapshot")
        let checkout = URL(fileURLWithPath: "/tmp/source-checkout")
        #expect(TestRepository.resolveRoot(packaged: packaged, checkout: checkout) == packaged)
    }

    @Test func checkoutIsUsedWhenNoSnapshotIsPackaged() {
        let checkout = URL(fileURLWithPath: "/tmp/source-checkout")
        #expect(TestRepository.resolveRoot(packaged: nil, checkout: checkout) == checkout)
    }

    @Test func packagedSnapshotIsRequiredAndIsNotTheCheckout() throws {
        // The build phase must package the snapshot into this bundle. Requiring
        // it here fails the run when the packaging step is skipped, instead of
        // silently falling back to the #filePath checkout and passing anyway.
        let packaged = try #require(
            TestRepository.packagedSnapshot(),
            "The 'Package test fixtures' build phase must produce a test-repository snapshot in the test bundle")
        #expect(TestRepository.root.standardizedFileURL == packaged.standardizedFileURL,
                "A packaged snapshot must win over the #filePath checkout")
        #expect(TestRepository.root.standardizedFileURL != TestRepository.checkoutRoot.standardizedFileURL,
                "The packaged snapshot must not be the source checkout")
    }

    @Test func diagnosticArtifactsUseTemporaryStorageNotTheCheckoutOrBundle() {
        let expected = FileManager.default.temporaryDirectory.appendingPathComponent("nitrate-test-artifacts", isDirectory: true)
        #expect(TestRepository.artifactRoot.standardizedFileURL == expected.standardizedFileURL)
        #expect(!TestRepository.artifactRoot.path.hasPrefix(TestRepository.checkoutRoot.path + "/"))
        #expect(!TestRepository.artifactRoot.path.hasPrefix(TestRepository.root.path + "/"))
    }

    @Test func diagnosticArtifactDirectoryIsWritable() throws {
        let directory = TestRepository.artifactDirectory("writable-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("probe.txt")
        try Data("artifact".utf8).write(to: file)
        #expect(try Data(contentsOf: file) == Data("artifact".utf8))
    }

    @Test func resolvedRootIsAReadableDirectory() {
        let root = TestRepository.root
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        #expect(exists, "TestRepository.root must exist at \(root.path)")
        #expect(isDirectory.boolValue, "TestRepository.root must be a directory at \(root.path)")
    }

    @Test func everyRequiredFixtureIsReadable() {
        for relative in TestRepository.requiredFixturePaths {
            let url = TestRepository.root.appendingPathComponent(relative)
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "Missing required fixture \(relative) under \(TestRepository.root.path)")
            #expect((try? Data(contentsOf: url)) != nil,
                    "Required fixture \(relative) is unreadable under \(TestRepository.root.path)")
        }
    }
}
