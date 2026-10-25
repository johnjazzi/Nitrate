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
