import Foundation
import Testing

@Suite("Capture journal persistence", .serialized)
struct CaptureJournalPersistenceTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    @Test func blockedDirectoryMakesPendingFailureObservableAndRetryable() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal")
        try Data([0]).write(to: directory)
        let capture = root.appendingPathComponent("capture.dng")
        let journal = CaptureJournal(root: directory)
        var hardwareRequests = 0
        do {
            try journal.markPending(capture, mediaKind: .photo)
            hardwareRequests += 1
            Issue.record("An unwritable journal must refuse capture")
        } catch {
            #expect(error.localizedDescription.contains("retry"))
        }
        #expect(hardwareRequests == 0)
        #expect(!FileManager.default.fileExists(atPath: capture.path))
        try FileManager.default.removeItem(at: directory)
        try journal.markPending(capture, mediaKind: .photo)
        // Placeholder bytes only: this test does not qualify RAW decoding.
        try Data([1, 2, 3]).write(to: capture)
        #expect(journal.pendingHandoffs().first?.validated == false)
    }

    @Test func failedValidatedWriteKeepsPendingRecordAndOriginalAcrossRelaunch() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal")
        let capture = root.appendingPathComponent("capture.dng")
        let bytes = Data([1, 2, 3])
        let journal = CaptureJournal(root: directory)
        let policy = try #require(RenderCapturePolicy(60, sourceProfile: .hlgBT2020))
        try journal.markPending(capture, at: Date(timeIntervalSince1970: 100),
                                capturePolicy: policy, mediaKind: .photo)
        try bytes.write(to: capture)
        let marker = try #require(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first)
        let before = try Data(contentsOf: marker)
        // Deny the atomic replacement, without removing the existing marker.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        var refused = false
        do { try journal.markValidated(capture, mediaKind: .photo) }
        catch { refused = true }
        #expect(refused)
        #expect(try Data(contentsOf: marker) == before)
        #expect(try Data(contentsOf: capture) == bytes)
        let relaunched = CaptureJournal(root: directory)
        #expect(relaunched.pendingHandoffs() == [
            .init(url: capture, mediaKind: .photo, validated: false)
        ])
        #expect(relaunched.capturePolicy(for: capture) == policy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try relaunched.markValidated(capture, mediaKind: .photo)
        #expect(relaunched.pendingHandoffs().first?.validated == true)
        #expect(relaunched.capturePolicy(for: capture) == policy)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        #expect(payload["createdAt"] as? TimeInterval == 100)
        #expect(try Data(contentsOf: capture) == bytes)
    }

    @Test func unreadableMarkerIsRetainedAndDiscoveredAfterRetry() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal")
        let capture = root.appendingPathComponent("capture.dng")
        let journal = CaptureJournal(root: directory)
        try journal.markPending(capture, mediaKind: .photo)
        try Data([1]).write(to: capture)
        let marker = try #require(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path) }
        let unreadable = journal.scan()
        #expect(unreadable.handoffs.isEmpty)
        #expect(unreadable.issues.map { $0.url.resolvingSymlinksInPath() } == [marker.resolvingSymlinksInPath()])
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        #expect(journal.scan().issues.isEmpty)
        #expect(journal.pendingHandoffs().first?.url == capture)
    }

    @Test func malformedMarkerCannotBeOverwrittenOrRetiredByValidation() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal")
        let capture = root.appendingPathComponent("capture.dng")
        let journal = CaptureJournal(root: directory)
        try journal.markPending(capture, mediaKind: .photo)
        try Data([1]).write(to: capture)
        let marker = try #require(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first)
        let valid = try Data(contentsOf: marker)
        let corrupt = Data("{truncated".utf8)
        try corrupt.write(to: marker)
        #expect(journal.scan().issues.map { $0.url.resolvingSymlinksInPath() } == [marker.resolvingSymlinksInPath()])
        var refused = false
        do { try journal.markValidated(capture, mediaKind: .photo) }
        catch { refused = true }
        #expect(refused)
        #expect(try Data(contentsOf: marker) == corrupt)
        try valid.write(to: marker)
        #expect(journal.pendingHandoffs().first?.validated == false)
    }

    @Test func missingOriginalRetiresOnlyItsOwnMarker() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal")
        let journal = CaptureJournal(root: directory, sessionID: UUID())
        try journal.markPending(root.appendingPathComponent("never-written.mov"))
        // A marker from an earlier process can never receive bytes for its
        // missing original; reconciliation closes it.
        let relaunched = CaptureJournal(root: directory, sessionID: UUID())
        #expect(relaunched.pendingHandoffs().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func retryBeforeStillBytesLandCannotEraseThePendingRecord() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal")
        let capture = root.appendingPathComponent("capture.dng")
        let journal = CaptureJournal(root: directory)
        try journal.markPending(capture, mediaKind: .photo)
        // The owning process may still be writing this capture: retry keeps the
        // record and does not raise a warning about bytes that have not landed.
        #expect(journal.pendingHandoffs().isEmpty)
        #expect(journal.scan().issues.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        try Data([1]).write(to: capture)
        #expect(journal.pendingHandoffs().first?.validated == false)
    }

    @Test func duplicateMarkersReportOneIssueForOneOriginal() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal")
        let capture = root.appendingPathComponent("capture.dng")
        try Data([1]).write(to: capture)
        let writer = CaptureJournal(root: directory, sessionID: UUID())
        try writer.markPending(capture, mediaKind: .photo)
        // A pre-upgrade install also left its base-name copy of this marker.
        let legacy = ["source": capture.path, "mediaKind": "photo", "validated": false] as [String: Any]
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: directory.appendingPathComponent("capture.json"))

        let scan = CaptureJournal(root: directory, sessionID: UUID()).scan()
        #expect(scan.handoffs.isEmpty)
        #expect(scan.issues.map(\.url) == [capture],
                "Two durable references to one original must not produce duplicate rows.")
    }
}
