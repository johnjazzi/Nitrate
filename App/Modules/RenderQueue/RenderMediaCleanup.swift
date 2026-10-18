import Foundation

/// Narrow deletion capability. A false result means the URL was not proven owned;
/// it does NOT mean that its media was removed. No recursive deletion is allowed.
struct RenderMediaCleanup {
    let sourceRoot: URL
    let outputRoot: URL
    private let remove: (URL) throws -> Void

    init(sourceRoot: URL? = nil, outputRoot: URL? = nil,
         remove: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        let manager = FileManager.default
        self.sourceRoot = sourceRoot ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Originals", isDirectory: true)
        self.outputRoot = outputRoot ?? manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.remove = remove
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Darwin may spell the sandbox /var/... while its physical root is
    /// /private/var/.... Resolve that system-owned alias only, not user-created
    /// symlinks anywhere within or above our owned media directories.
    private static func systemPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/var/") else { return path }
        return URL(fileURLWithPath: "/var").resolvingSymlinksInPath().path + path.dropFirst(4)
    }

    /// Missing owned movies count as cleaned, including after a crash between
    /// unlink and the cleanup-state write. Symlinks and directories never do.
    func removeIfOwned(_ url: URL) throws -> Bool {
        guard url.isFileURL, !url.pathComponents.contains(".."),
              url.pathExtension == "mov" else { return false }
        let normalized = url.standardizedFileURL
        let parent = normalized.deletingLastPathComponent()
        let matchesSource = parent.path == sourceRoot.standardizedFileURL.path
            && normalized.lastPathComponent.hasPrefix("clip_")
        let matchesOutput = parent.path == outputRoot.standardizedFileURL.path
            && normalized.lastPathComponent.hasPrefix("render_")
        guard matchesSource || matchesOutput,
              Self.systemPath(normalized) == Self.canonicalPath(normalized),
              Self.systemPath(parent) == Self.canonicalPath(parent) else { return false }
        do {
            let values = try normalized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        } catch CocoaError.fileReadNoSuchFile {
            return true
        }
        try remove(normalized)
        return !FileManager.default.fileExists(atPath: normalized.path)
    }
}
