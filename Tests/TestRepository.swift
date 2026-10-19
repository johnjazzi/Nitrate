import Foundation

/// Locates the repository fixtures the test suites read at runtime.
///
/// Apple Cloud Test runs the test-execution phase without a source checkout, so
/// a `#filePath`-relative read resolves to a path that does not exist there.
/// The test target's build phase (`scripts/package_test_fixtures.py`) packages
/// the allowlisted fixtures into the bundle under `test-repository/`; this
/// helper prefers that snapshot and falls back to the `#filePath` checkout for
/// local runs that skip the packaging step.
///
/// Test files must resolve repository-relative reads through `root` rather than
/// deriving a path from `#filePath` directly.
enum TestRepository {
    /// Directory name of the packaged snapshot inside the test bundle.
    static let snapshotDirectoryName = "test-repository"

    /// Directory containing the repository's allowlisted runtime fixtures.
    static let root: URL = resolveRoot()

    /// Chooses the packaged snapshot when present, otherwise the source checkout.
    static func resolveRoot(packaged: URL? = packagedSnapshot(), checkout: URL = checkoutRoot) -> URL {
        packaged ?? checkout
    }

    /// The packaged snapshot in this test target's bundle, if the build phase ran.
    static func packagedSnapshot(in bundle: Bundle = Bundle(for: BundleToken.self)) -> URL? {
        var candidates: [URL] = []
        if let url = bundle.url(forResource: snapshotDirectoryName, withExtension: nil) {
            candidates.append(url)
        }
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(snapshotDirectoryName))
        }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Resources/\(snapshotDirectoryName)"))
        candidates.append(bundle.bundleURL.appendingPathComponent(snapshotDirectoryName))

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    /// Source checkout root; this file lives at `<root>/Tests/TestRepository.swift`.
    static var checkoutRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repository root
    }

    /// Representative fixtures that must exist and be readable wherever `root`
    /// points. `TestRepositoryTests` fails closed if any is missing, so a broken
    /// snapshot or a partial checkout is reported rather than silently skipping.
    static let requiredFixturePaths: [String] = [
        "Resources/stocks.json",
        "Resources/Shaders/spatial.metal",
        "App/Resources/stocks.json",
        "App/PrivacyInfo.xcprivacy",
        "Tests/Fixtures/colorchecker-babelcolor-2006.json",
        "App/ContentView.swift"
    ]

    /// Resolves a repository-relative fixture path against the chosen root.
    static func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    private final class BundleToken {}
}
