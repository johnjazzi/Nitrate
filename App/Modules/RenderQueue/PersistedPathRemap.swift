import Foundation

/// iOS gives an app a fresh container directory when it is installed or updated,
/// so an absolute path written by an earlier build points at a directory that no
/// longer exists. Anything persisted across launches — queued jobs and capture
/// journal markers — is re-rooted onto the current container when it is read.
enum PersistedPathRemap {
    /// The container-relative component that follows the per-install identifier.
    private static let containerMarker = "/Application/"

    static var currentContainerRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static func rebased(_ url: URL, containerRoot: URL) -> URL {
        let path = url.path
        guard let marker = path.range(of: containerMarker) else { return url }
        let afterIdentifier = path[marker.upperBound...]
        guard let separator = afterIdentifier.firstIndex(of: "/") else { return url }
        let remainder = String(afterIdentifier[afterIdentifier.index(after: separator)...])
        guard !remainder.isEmpty else { return url }
        return containerRoot.appendingPathComponent(remainder)
    }

    static func rebasedOntoCurrentContainer(_ url: URL) -> URL {
        rebased(url, containerRoot: currentContainerRoot)
    }
}

extension URL {
    /// Re-root a persisted absolute path onto the current app container.
    func rebasedOntoCurrentContainer() -> URL {
        PersistedPathRemap.rebasedOntoCurrentContainer(self)
    }
}

extension RenderJob {
    /// Re-root this job's persisted paths onto the current app container. A job
    /// whose paths still resolve is returned unchanged.
    func rebasedOntoCurrentContainer(root: URL = PersistedPathRemap.currentContainerRoot) -> RenderJob {
        let source = PersistedPathRemap.rebased(sourceURL, containerRoot: root)
        let output = outputURL.map { PersistedPathRemap.rebased($0, containerRoot: root) }
        guard source != sourceURL || output != outputURL else { return self }
        var copy = self
        copy.sourceURL = source
        copy.outputURL = output
        return copy
    }
}
