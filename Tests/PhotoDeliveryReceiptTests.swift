import Foundation
import Testing

/// The delivery receipt decides whether a photo is added to Photos at all, so
/// what it treats as "the same file" is a behaviour, not an implementation
/// detail.
///
/// A re-develop writes a new render to the same path. A name-only key answered
/// "already saved", the queue marked the job delivered, and the new develop never
/// reached the library — reported as "re-develop does not save any more".
@Suite(.serialized)
struct PhotoDeliveryReceiptTests {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func theSameFileKeepsItsKey() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("DSC_4800.jpg")
        try Data([1, 2, 3]).write(to: url)

        #expect(DevelopmentPhotoLibrarySaver.receiptKey(for: url)
                == DevelopmentPhotoLibrarySaver.receiptKey(for: url),
                "a file nobody touched must still be recognised as delivered")
    }

    @Test func aNewRenderAtTheSamePathIsANewDelivery() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("DSC_4800.jpg")
        try Data([1, 2, 3]).write(to: url)
        let first = DevelopmentPhotoLibrarySaver.receiptKey(for: url)

        // The re-develop overwrites the delivered file: same name, new bytes.
        try Data([9, 9, 9, 9, 9]).write(to: url)
        let second = DevelopmentPhotoLibrarySaver.receiptKey(for: url)

        #expect(first != second, "a new develop must be delivered, not skipped")
    }

    @Test func aDifferentFileInTheSameFolderIsSeparate() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("A.jpg")
        let b = folder.appendingPathComponent("B.jpg")
        try Data([7]).write(to: a)
        try Data([7]).write(to: b)

        #expect(DevelopmentPhotoLibrarySaver.receiptKey(for: a)
                != DevelopmentPhotoLibrarySaver.receiptKey(for: b))
    }
}
