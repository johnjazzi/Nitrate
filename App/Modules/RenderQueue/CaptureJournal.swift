import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Durable markers for captures that have not yet been accepted by the render
/// queue.
///
/// A take is marked before capture begins and acknowledged only after a queue
/// job for it is durably persisted. Anything still marked at launch is
/// reconciled: a video as an original-only rescue (its validation outcome is
/// unknown), a validated still as an original-only photo, and an unchecked
/// still as a visible quarantine — never an exportable photo. Markers whose
/// bytes provably can never arrive are closed instead of warned about.
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
        /// True once the capture's own validation finished — recorded by the
        /// marker upgrade, or proved by the camera's post-validation record
        /// when that upgrade failed. A still that never validated is not the
        /// operator's photo and must not be exported.
        let validated: Bool
    }

    /// A durable reference that must not be exported or silently discarded.
    /// `url` names the original, or the marker if its source cannot be read.
    struct RecoveryIssue: Identifiable, Sendable, Equatable {
        let url: URL
        let message: String
        /// False when no retry can change the outcome — the record is kept as a
        /// support reference, not as a promise that recovery can still finish.
        var retryable: Bool = true
        var id: URL { url }
    }

    struct Scan {
        var handoffs: [PendingCapture] = []
        var issues: [RecoveryIssue] = []
    }

    struct PersistenceError: LocalizedError {
        let underlying: Error
        var errorDescription: String? {
            "The capture recovery record could not be saved. Free storage if needed, then retry. "
                + "Any original already written is kept locally. (\(underlying.localizedDescription))"
        }
    }

    /// One identity per app process, shared by every journal instance the
    /// camera and the render queue construct. A marker carrying this value can
    /// still name a capture whose bytes are being written; a marker from any
    /// other process cannot, because that process is gone.
    static let processSession = UUID()

    private let root: URL
    private let fileManager: FileManager
    private let sessionID: UUID

    init(root: URL? = nil, fileManager: FileManager = .default,
         sessionID: UUID = CaptureJournal.processSession) {
        self.root = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureJournal", isDirectory: true)
        self.fileManager = fileManager
        self.sessionID = sessionID
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
                     mediaKind: MediaKind = .video, validated: Bool = false) throws {
        try write(capture, date: date, capturePolicy: capturePolicy,
              mediaKind: mediaKind, validated: validated)
    }

    /// The capture's own validation finished, so it is a deliverable file.
    /// Keeps the marker's original timestamp and capture policy.
    func markValidated(_ capture: URL, mediaKind: MediaKind) throws {
        // Do not replace an unreadable record (and lose its frozen policy).
        let existing = try requiredPayload(for: capture)
        let date = (existing["createdAt"] as? TimeInterval)
            .map(Date.init(timeIntervalSince1970:)) ?? Date()
        let policy: RenderCapturePolicy?
        do {
            if let object = existing["capturePolicy"] {
                let data = try JSONSerialization.data(withJSONObject: object)
                policy = try JSONDecoder().decode(RenderCapturePolicy.self, from: data)
            } else { policy = nil }
        } catch { throw PersistenceError(underlying: error) }
        try write(capture, date: date, capturePolicy: policy,
              mediaKind: mediaKind, validated: true)
    }

    private func write(_ capture: URL, date: Date, capturePolicy: RenderCapturePolicy?,
                       mediaKind: MediaKind, validated: Bool) throws {
        do {
            try persist(capture, date: date, capturePolicy: capturePolicy, mediaKind: mediaKind, validated: validated)
        } catch { throw PersistenceError(underlying: error) }
    }

    private func persist(_ capture: URL, date: Date, capturePolicy: RenderCapturePolicy?,
                         mediaKind: MediaKind, validated: Bool) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var payload: [String: Any] = ["source": capture.path,
                                      "createdAt": date.timeIntervalSince1970,
                                      "mediaKind": mediaKind.rawValue,
                                      "validated": validated,
                                      "session": sessionID.uuidString]
        if let capturePolicy {
            let data = try JSONEncoder().encode(capturePolicy)
            payload["capturePolicy"] = try JSONSerialization.jsonObject(with: data)
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: markerURL(for: capture), options: .atomic)
    }

    private func requiredPayload(for capture: URL) throws -> [String: Any] {
        for candidate in [markerURL(for: capture), legacyMarkerURL(for: capture)] {
            do {
                let data = try Data(contentsOf: candidate)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["source"] is String else { throw CocoaError(.fileReadCorruptFile) }
                return object
            } catch CocoaError.fileReadNoSuchFile { continue }
            catch { throw PersistenceError(underlying: error) }
        }
        throw PersistenceError(underlying: CocoaError(.fileReadNoSuchFile))
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
        scan().handoffs
    }

    /// Durable proof that a still's DNG finished the camera's own validation.
    ///
    /// The marker is written before the capture and upgraded after validation,
    /// but that upgrade can fail on its own (full storage, protected data). The
    /// camera also writes `capture.json` into the capture's own folder *after*
    /// validation. That record is trusted only when it names this exact
    /// app-owned `capture.dng`, was written after the bytes, and the file on
    /// disk still matches it byte-for-byte and decodes as the same RAW image.
    /// Anything less is an unknown DNG and is never promoted.
    enum StillEvidence {
        static let fileName = "capture.dng"
        static let manifestName = "capture.json"
        /// Statuses the camera writes only after its DNG validation block.
        private static let validatedStatuses: Set<String> =
            ["photoProcessed", "complete", "timedOutWithValidatedDNG"]
        /// Statuses that prove the capture ended without a deliverable file.
        private static let terminalFailureStatuses: Set<String> =
            ["failed", "timedOutAwaitingTerminal"]

        enum Outcome: Equatable {
            case validated
            /// The camera's own record proves validation ran and rejected it.
            case rejected
            /// No finished validation record exists.
            case unfinished
            /// The record exists but cannot be read now (protected data, I/O).
            case unreadableManifest
            /// A finished record exists but the file no longer matches it.
            case evidenceMismatch
        }

        private enum ManifestRead {
            case value([String: Any])
            case missing
            case unreadable
        }

        private static func manifest(in folder: URL) -> ManifestRead {
            let url = folder.appendingPathComponent(manifestName)
            do {
                let data = try Data(contentsOf: url)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .missing
                }
                return .value(object)
            } catch CocoaError.fileReadNoSuchFile {
                return .missing
            } catch {
                return .unreadable
            }
        }

        /// Whether the capture's own record proves it ended without a DNG.
        /// Only used when the file is already known to be absent.
        static func provesTerminalFailure(at source: URL) -> Bool {
            guard source.lastPathComponent == fileName else { return false }
            guard case .value(let manifest) = manifest(in: source.deletingLastPathComponent()),
                  let status = manifest["status"] as? String,
                  terminalFailureStatuses.contains(status),
                  manifest["dngReadable"] as? String != "true" else { return false }
            return true
        }

        static func outcome(for source: URL) -> Outcome {
            guard source.lastPathComponent == fileName else { return .evidenceMismatch }
            let folder = source.deletingLastPathComponent()
            guard !folder.path.isEmpty else { return .evidenceMismatch }
            switch manifest(in: folder) {
            case .missing:
                return .unfinished
            case .unreadable:
                return .unreadableManifest
            case .value(let manifest):
                guard let status = manifest["status"] as? String else {
                    return .unfinished
                }
                let readable = manifest["dngReadable"] as? String == "true"
                if terminalFailureStatuses.contains(status) {
                    return readable ? .unfinished : .rejected
                }
                guard validatedStatuses.contains(status) else {
                    return .unfinished
                }
                // A post-processing status normally means the DNG passed. The
                // explicit readable flag is the camera's own outcome; a false
                // value is a rejected file, not a missing record.
                guard readable else { return .rejected }
                // A validated DNG can still carry a separate processing
                // failure; never promote on that ambiguous record.
                guard manifest["failure"] == nil else { return .unfinished }
                return matches(manifest, source: source,
                               manifestURL: folder.appendingPathComponent(manifestName))
                    ? .validated : .evidenceMismatch
            }
        }

        private static func matches(_ manifest: [String: Any], source: URL, manifestURL: URL) -> Bool {
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: source.path) }
            catch { return false }
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let fileBytes = (attributes[.size] as? NSNumber)?.intValue, fileBytes > 0,
                  let fileDate = attributes[.modificationDate] as? Date,
                  let manifestAttributes = try? FileManager.default.attributesOfItem(atPath: manifestURL.path),
                  let manifestDate = manifestAttributes[.modificationDate] as? Date,
                  // The validation record must describe the bytes that are on
                  // disk now, not an earlier write in the same folder.
                  fileDate <= manifestDate,
                  manifest["dng"] as? String == fileName,
                  manifest["dngReadable"] as? String == "true",
                  let declaredBytes = (manifest["dngBytes"] as? String).flatMap(Int.init),
                  declaredBytes == fileBytes,
                  let transactionID = manifest["transactionID"] as? String, !transactionID.isEmpty,
                  let rawWidth = (manifest["rawWidth"] as? String).flatMap(Int.init),
                  let rawHeight = (manifest["rawHeight"] as? String).flatMap(Int.init),
                  let resolvedWidth = (manifest["resolvedRawWidth"] as? String).flatMap(Int.init),
                  let resolvedHeight = (manifest["resolvedRawHeight"] as? String).flatMap(Int.init),
                  rawWidth == resolvedWidth, rawHeight == resolvedHeight,
                  PhotoCapturePolicy.permitsActualDimensions(
                    PhotoCapturePolicy.Dimensions(width: rawWidth, height: rawHeight)),
                  (manifest["actualRawPixelFormat"] as? String).flatMap(Int.init).map({ $0 != 0 }) == true,
                  let fileType = manifest["actualFileType"] as? String,
                  UTType(fileType)?.conforms(to: .rawImage) == true,
                  let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  CGImageSourceGetCount(imageSource) > 0,
                  let decodedType = CGImageSourceGetType(imageSource),
                  UTType(decodedType as String)?.conforms(to: .rawImage) == true,
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == rawWidth,
                  properties[kCGImagePropertyPixelHeight] as? Int == rawHeight
            else { return false }
            return true
        }
    }

    func scan() -> Scan {
        var result = Scan()
        let names: [String]
        do { names = try fileManager.contentsOfDirectory(atPath: root.path) }
        catch CocoaError.fileReadNoSuchFile { return result }
        catch {
            result.issues = [RecoveryIssue(url: root,
                message: "Capture recovery records could not be read. Free storage if needed, then retry recovery.")]
            return result
        }
        var found: [String: (capture: PendingCapture, createdAt: Date)] = [:]
        for name in names where name.hasSuffix(".json") {
            let marker = root.appendingPathComponent(name)
            // A transient read/parse failure is not proof that the handoff is
            // stale. Keep the marker for a later reconciliation attempt.
            guard let data = try? Data(contentsOf: marker),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = object["source"] as? String else {
                result.issues.append(RecoveryIssue(url: marker,
                    message: "This recovery record cannot be read yet. It has been kept; retry recovery."))
                continue
            }
            let source = URL(fileURLWithPath: path).rebasedOntoCurrentContainer()
            let mediaKind = (object["mediaKind"] as? String).flatMap(MediaKind.init(rawValue:)) ?? .video
            // A marker written by this process may name a capture whose bytes
            // are still arriving. A marker from an earlier process can never
            // receive another byte: that process is gone.
            let markerSession = (object["session"] as? String).flatMap(UUID.init(uuidString:))
            let ownedByThisProcess = markerSession == sessionID
            // Only definite absence retires a marker. A permission/read failure
            // can be transient (for example protected data while locked).
            do { _ = try source.checkResourceIsReachable() }
            catch CocoaError.fileReadNoSuchFile {
                // A finished failure record, or a marker left by an earlier
                // process, proves no capture can still write this file. Close
                // it instead of warning about a retry that cannot happen.
                if StillEvidence.provesTerminalFailure(at: source) || !ownedByThisProcess {
                    try? fileManager.removeItem(at: marker)
                }
                // Otherwise the capture may still be in flight; keep both.
                continue
            } catch {
                result.issues.append(RecoveryIssue(url: source,
                    message: "The captured original cannot be read yet. Its recovery record is kept; retry recovery."))
                continue
            }
            let validated = object["validated"] as? Bool ?? false
            let created = (object["createdAt"] as? TimeInterval)
                .map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            var pending = PendingCapture(url: source, mediaKind: mediaKind, validated: validated)
            if mediaKind == .photo, !validated {
                switch StillEvidence.outcome(for: source) {
                case .validated:
                    // The camera's own post-validation record is the second
                    // witness the failed marker upgrade was missing. It stays
                    // durable on disk, so promotion is idempotent.
                    pending = PendingCapture(url: source, mediaKind: .photo, validated: true)
                case .rejected:
                    result.issues.append(RecoveryIssue(url: source,
                        message: "This RAW did not pass the camera's validation, so it was not added to Photos. "
                            + "The original is kept locally for support.", retryable: false))
                    continue
                case .evidenceMismatch:
                    result.issues.append(RecoveryIssue(url: source,
                        message: "This RAW no longer matches the camera's validation record, so it was not added to Photos. "
                            + "The original is kept locally for support.", retryable: false))
                    continue
                case .unreadableManifest:
                    result.issues.append(RecoveryIssue(url: source,
                        message: "The RAW's validation record cannot be read yet. The original is kept; retry recovery."))
                    continue
                case .unfinished:
                    // A capture whose validation callback may still be running
                    // stays a normal pending handoff: not enqueued, not warned
                    // about, and never retired.
                    guard !ownedByThisProcess else { break }
                    result.issues.append(RecoveryIssue(url: source,
                        message: "The RAW capture did not finish cleanly. "
                            + "The original is kept locally and is not added to Photos.", retryable: false))
                    continue
                }
            }
            // Two markers can name one capture only while an upgraded install
            // still holds a legacy-named copy, which records neither field. One
            // handoff, one entry, and the record that knows more wins.
            let key = source.standardizedFileURL.path
            if let existing = found[key], existing.capture.validated || !pending.validated { continue }
            found[key] = (pending, min(created, found[key]?.createdAt ?? created))
        }
        result.handoffs = found.values.sorted { $0.createdAt < $1.createdAt }.map(\.capture)
        // One original, one visible record: an upgraded install can still hold
        // a legacy-named copy of the same marker.
        var seen: Set<URL> = []
        result.issues = result.issues.filter { seen.insert($0.url).inserted }
        result.issues.sort { $0.url.path < $1.url.path }
        return result
    }
}
