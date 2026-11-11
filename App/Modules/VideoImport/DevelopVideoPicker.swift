#if os(iOS)
import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import Foundation

/// PhotosPicker `Transferable` for Develop.
///
/// A bounded, file-backed copy into app-owned storage through the existing
/// import service: `.movie` `FileRepresentation` only. There is no full movie
/// `Data`, no `PHAsset`, and no broad photo-library access.
struct DevelopPickedVideo: Transferable, Sendable {
    let transfer: DevelopClipTransfer

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let url = try await VideoImportService.copyToOwnedStorage(from: received.file)
            return DevelopPickedVideo(transfer: DevelopClipTransfer(
                lease: VideoImportFileLease(url: url),
                originalFilename: received.file.lastPathComponent))
        }
    }
}

/// The photo counterpart.
///
/// Two representations, RAW FIRST. A capture stored as JPEG+RAW holds both, and
/// asking for "any image" lets Photos hand over the JPEG — which the gate then
/// refuses as "not a raw photo". Declaring `public.camera-raw-image` first asks
/// for the raw resource specifically; `.image` stays as the fallback for files
/// whose type the system cannot name as a camera raw.
///
/// The copy is still validated: a file that arrives as a JPEG is refused with the
/// reason rather than developed as if it were raw.
struct DevelopPickedPhoto: Transferable, Sendable {
    let transfer: DevelopVideoModel.DevelopPhotoTransfer

    static var transferRepresentation: some TransferRepresentation {
        // `UTType.cameraRawImage` is not a declared constant in every SDK, and
        // the identifier is stable, so it is built by identifier.
        FileRepresentation(importedContentType: UTType(importedAs: "public.camera-raw-image")) { received in
            try await accept(received.file)
        }
        FileRepresentation(importedContentType: .image) { received in
            try await accept(received.file)
        }
    }

    private static func accept(_ file: URL) async throws -> DevelopPickedPhoto {
        try await PhotoImportService.validateRaw(at: file)
        // Keep the file's own extension. A NEF renamed to .dng would lie about
        // the container and about which decoder opened it; the render path reads
        // raw by capability, not by name.
        let receivedExtension = file.pathExtension.lowercased()
        let url = try await VideoImportService.copyToOwnedStorage(
            from: file, prefix: "photo_import",
            fileExtension: receivedExtension.isEmpty ? "dng" : receivedExtension)
        return DevelopPickedPhoto(transfer: DevelopVideoModel.DevelopPhotoTransfer(
            lease: VideoImportFileLease(url: url),
            originalFilename: file.lastPathComponent))
    }
}

extension DevelopVideoModel {
    /// iOS entry point: wrap the picker item in the model's transfer seam. The
    /// provider `Progress` is published so a superseded selection cancels the
    /// underlying load.
    func select(_ item: PhotosPickerItem) {
        select(transfer: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.loadClip(from: item)
        })
    }

    /// The photo seam, mirroring the clip one.
    func selectPhoto(_ item: PhotosPickerItem) {
        selectPhoto(transfer: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.loadPhoto(from: item)
        })
    }

    func loadPhoto(from item: PhotosPickerItem) async throws -> DevelopPhotoTransfer {
        let picked = try await DevelopTransferLoader.load(onStart: attachTransferProgress) { completion in
            item.loadTransferable(type: DevelopPickedPhoto.self, completionHandler: completion)
        }
        guard let picked else { throw PhotoImportError.unreadable }
        return picked.transfer
    }

    func loadClip(from item: PhotosPickerItem) async throws -> DevelopClipTransfer {
        let picked = try await DevelopTransferLoader.load(onStart: attachTransferProgress) { completion in
            item.loadTransferable(type: DevelopPickedVideo.self, completionHandler: completion)
        }
        guard let picked else { throw VideoImportError.unreadable }
        return picked.transfer
    }
}
#endif
