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

/// The photo counterpart. Photos cannot filter its picker by file type either,
/// so the same rule applies: check the picked file is a raw the still renderer
/// can develop, and only then copy it into owned storage.
struct DevelopPickedPhoto: Transferable, Sendable {
    let transfer: DevelopVideoModel.DevelopPhotoTransfer

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try await PhotoImportService.validateRaw(at: received.file)
            // Keep the file's own extension. A NEF renamed to .dng would lie
            // about the container and about which decoder opened it; the render
            // path reads raw by capability, not by name.
            let receivedExtension = received.file.pathExtension.lowercased()
            let url = try await VideoImportService.copyToOwnedStorage(
                from: received.file, prefix: "photo_import",
                fileExtension: receivedExtension.isEmpty ? "dng" : receivedExtension)
            return DevelopPickedPhoto(transfer: DevelopVideoModel.DevelopPhotoTransfer(
                lease: VideoImportFileLease(url: url),
                originalFilename: received.file.lastPathComponent))
        }
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

    private func loadPhoto(from item: PhotosPickerItem) async throws -> DevelopPhotoTransfer {
        try await withCheckedThrowingContinuation { continuation in
            let progress = item.loadTransferable(type: DevelopPickedPhoto.self) { result in
                switch result {
                case .success(let picked?): continuation.resume(returning: picked.transfer)
                case .success(nil): continuation.resume(throwing: PhotoImportError.unreadable)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            attachTransferProgress(progress)
        }
    }

    private func loadClip(from item: PhotosPickerItem) async throws -> DevelopClipTransfer {
        try await withCheckedThrowingContinuation { continuation in
            let progress = item.loadTransferable(type: DevelopPickedVideo.self) { result in
                switch result {
                case .success(let picked?): continuation.resume(returning: picked.transfer)
                case .success(nil): continuation.resume(throwing: VideoImportError.unreadable)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            attachTransferProgress(progress)
        }
    }
}
#endif
