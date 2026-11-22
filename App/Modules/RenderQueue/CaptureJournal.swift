import CryptoKit
import Foundation

/// Durable markers for captures that have not yet been accepted by the render
/// queue.
///
/// A take is marked before capture begins and acknowledged only after a queue
/// job for it is durably persisted. Anything still marked at launch is
/// reconciled: a video as an original-only rescue (its validation outcome is
/// unknown), a validated still as an original-only photo, and an incomplete
/// still as nothing at all — an unfinished DNG is never presented as a photo.
///
/// This closes the window where the camera had written a readable file into
/// `Originals/` (or a still into its capture folder) but the process died
/// before any queue entry existed.
struct CaptureJournal {
    /// What the marked capture is. Recorded before the file is written, so a
    /// reconciliation never has to guess from the file extension.
    enum MediaKind: String, Sendable {
        case video, photo
    }

    /// One capture still awaiting durable queue acceptance.
    struct PendingCapture: Sendable, Equatable {
        let url: URL
        let mediaKind: MediaKind
        /// True only once the capture's own validation finished. A still that
        /// never validated is not the operator's photo and must not be exported.
        let validated: Bool
    }

    private let root: URL
    private let fileManager: FileManager

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.root = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureJournal", isDirectory: true)
        self.fileManager = fileManager
    }

    /// Marker names come from the capture's own path, so marking the same
    /// destination twice is idempotent and two handoffs in flight can never
    /// overwrite each other. A digest keeps the name short and path-safe: the
    /// still capture folders all end in `capture.dng`, so a plain base name
    /// would collapse every in-flight still onto one marker.
    private func markerURL(for capture: URL) -> URL {
        let identity = capture.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest + ".json")
    }

    /// Markers written before the path digest existed were named after the
    /// file's base name. Reading scans the directory, so those still decode;
    /// acknowledging removes both names so an upgraded marker cannot linger.
    private func legacyMarkerURL(for capture: URL) -> URL {
        root.appendingPathComponent(capture.deletingPathExtension().lastPathComponent + ".json")
    }

    /// Record that a capture has started. Safe to call repeatedly.
    ///
    /// - Parameter mediaKind: recorded before the file exists so a later
    ///   reconciliation knows how the capture must be delivered.
    /// - Parameter validated: false until the capture's own validation passed.
    func markPending(_ capture: URL, at date: Date = Date(), capturePolicy: RenderCapturePolicy? = nil,
                     mediaKind: MediaKind = .video, validated: Bool = false) {
        write(capture, date: date, capturePolicy: capturePolicy,
              mediaKind: mediaKind, validated: validated)
    }

    /// The capture's own validation finished, so it is a deliverable file.
    /// Keeps the marker's original timestamp and capture policy.
    func markValidated(_ capture: URL, mediaKind: MediaKind) {
        let existing = payload(for: capture)
        let date = (existing?["createdAt"] as? TimeInterval)
            .map(Date.init(timeIntervalSince1970:)) ?? Date()
        write(capture, date: date, capturePolicy: capturePolicy(for: capture),
              mediaKind: mediaKind, validated: true)
    }

    private func write(_ capture: URL, date: Date, capturePolicy: RenderCapturePolicy?,
                       mediaKind: MediaKind, validated: Bool) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var payload: [String: Any] = ["source": capture.path,
                                      "createdAt": date.timeIntervalSince1970,
                                      "mediaKind": mediaKind.rawValue,
                                      "validated": validated]
        if let capturePolicy, let data = try? JSONEncoder().encode(capturePolicy),
           let policy = try? JSONSerialization.jsonObject(with: data) {
            payload["capturePolicy"] = policy
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: markerURL(for: capture), options: .atomic)
    }

    private func payload(for capture: URL) -> [String: Any]? {
        for candidate in [markerURL(for: capture), legacyMarkerURL(for: capture)] {
            guard let data = try? Data(contentsOf: candidate),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            return object
        }
        return nil
    }

    /// The queue has durably accepted this capture; the marker is no longer needed.
    func acknowledge(_ capture: URL) {
        try? fileManager.removeItem(at: markerURL(for: capture))
        let legacy = legacyMarkerURL(for: capture)
        if legacy != markerURL(for: capture) { try? fileManager.removeItem(at: legacy) }
    }

    func capturePolicy(for capture: URL) -> RenderCapturePolicy? {
        guard let object = payload(for: capture),
              let policy = object["capturePolicy"],
              let encoded = try? JSONSerialization.data(withJSONObject: policy) else { return nil }
        return try? JSONDecoder().decode(RenderCapturePolicy.self, from: encoded)
    }

    /// Captures still marked whose file exists, oldest first. A marker whose file
    /// never landed (a cancelled or failed take) is retired here.
    func pendingCaptures() -> [URL] {
        pendingHandoffs().map(\.url)
    }

    /// Captures still marked whose file exists, with the media kind and
    /// validation outcome recorded before the file was written.
    ///
    /// Entries written before those fields existed decode as video and
    /// unvalidated, which is exactly how they were reconciled until now.
    func pendingHandoffs() -> [PendingCapture] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var found: [String: (capture: PendingCapture, createdAt: Date)] = [:]
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
            let mediaKind = (object["mediaKind"] as? String).flatMap(MediaKind.init(rawValue:)) ?? .video
            let validated = object["validated"] as? Bool ?? false
            let created = (object["createdAt"] as? TimeInterval)
                .map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            let pending = PendingCapture(url: source, mediaKind: mediaKind, validated: validated)
            // Two markers can name one capture only while an upgraded install
            // still holds a legacy-named copy, which records neither field. One
            // handoff, one entry, and the record that knows more wins.
            let key = source.standardizedFileURL.path
            if let existing = found[key], existing.capture.validated || !validated { continue }
            found[key] = (pending, min(created, found[key]?.createdAt ?? created))
        }
        return found.values.sorted { $0.createdAt < $1.createdAt }.map(\.capture)
    }
}
