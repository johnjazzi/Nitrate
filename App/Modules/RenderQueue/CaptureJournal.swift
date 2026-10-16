import Foundation

/// Durable markers for captures that have not yet been accepted by the render
/// queue.
///
/// A take is marked before capture begins and acknowledged only after a queue
/// job for it is durably persisted. Anything still marked at launch is
/// reconciled as an original-only rescue — it is never rendered, because the
/// take's validation outcome is unknown.
///
/// This closes the window where the camera had written a readable file into
/// `Originals/` but the process died before any queue entry existed.
struct CaptureJournal {
    private let root: URL
    private let fileManager: FileManager

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.root = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureJournal", isDirectory: true)
        self.fileManager = fileManager
    }

    /// Marker names come from the capture's own unique file name, so marking the
    /// same destination twice is idempotent and the marker stays short.
    private func markerURL(for capture: URL) -> URL {
        root.appendingPathComponent(capture.deletingPathExtension().lastPathComponent + ".json")
    }

    /// Record that a capture has started. Safe to call repeatedly.
    func markPending(_ capture: URL, at date: Date = Date()) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let payload: [String: Any] = ["source": capture.path,
                                      "createdAt": date.timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: markerURL(for: capture), options: .atomic)
    }

    /// The queue has durably accepted this capture; the marker is no longer needed.
    func acknowledge(_ capture: URL) {
        try? fileManager.removeItem(at: markerURL(for: capture))
    }

    /// Captures still marked whose file exists, oldest first. A marker whose file
    /// never landed (a cancelled or failed take) is retired here.
    func pendingCaptures() -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var found: [(url: URL, createdAt: Date)] = []
        for name in names where name.hasSuffix(".json") {
            let marker = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: marker),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = object["source"] as? String else {
                try? fileManager.removeItem(at: marker)
                continue
            }
            let source = URL(fileURLWithPath: path).rebasedOntoCurrentContainer()
            guard fileManager.fileExists(atPath: source.path) else {
                try? fileManager.removeItem(at: marker)
                continue
            }
            let created = (object["createdAt"] as? TimeInterval)
                .map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            found.append((source, created))
        }
        return found.sorted { $0.createdAt < $1.createdAt }.map(\.url)
    }
}
