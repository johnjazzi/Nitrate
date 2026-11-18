#if os(iOS)
import SwiftUI
import PhotosUI
import Photos
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
/// A representation cannot name a *resource*, though, so it cannot answer for a
/// pair whose raw lives in `alternatePhoto`. That answer needs the picker item's
/// asset identifier — see `DevelopPhotoLibraryRaw`.
///
/// The copy is still validated: a file that arrives as a JPEG is reported as
/// `.notRaw` with the reason, never copied, and never developed as if it were
/// raw.
struct DevelopPickedPhoto: Transferable, Sendable {
    enum Outcome: Sendable {
        case transfer(DevelopVideoModel.DevelopPhotoTransfer)
        /// The system handed over a file this panel cannot develop. The raw half
        /// of the pair may still be in the asset, so this is a decision for the
        /// caller, not a thrown error.
        case notRaw(PhotoImportError)
    }

    let outcome: Outcome

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

    /// The one gate a picked photo passes, whichever way its file arrived:
    /// validate the bytes as raw, then copy them into app-owned storage through
    /// the existing import service.
    ///
    /// A refusal travels back as `.notRaw` rather than as a thrown error, so the
    /// fallback decision does not depend on how a provider reports errors. Real
    /// failures — cancellation, an unwritable destination — still throw.
    static func accept(_ file: URL, originalFilename: String? = nil) async throws -> DevelopPickedPhoto {
        do {
            try await PhotoImportService.validateRaw(at: file)
        } catch let refusal as PhotoImportError {
            if case .unsupported = refusal {
                return DevelopPickedPhoto(outcome: .notRaw(refusal))
            }
            throw refusal
        }
        // Keep the file's own extension. A NEF renamed to .dng would lie about
        // the container and about which decoder opened it; the render path reads
        // raw by capability, not by name.
        let receivedExtension = file.pathExtension.lowercased()
        let url = try await VideoImportService.copyToOwnedStorage(
            from: file, prefix: "photo_import",
            fileExtension: receivedExtension.isEmpty ? "dng" : receivedExtension)
        return DevelopPickedPhoto(outcome: .transfer(DevelopVideoModel.DevelopPhotoTransfer(
            lease: VideoImportFileLease(url: url),
            originalFilename: originalFilename ?? file.lastPathComponent)))
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

    /// The picked file first — permission-free, unchanged — and the paired raw
    /// only when that file is not developable.
    func loadPhoto(from item: PhotosPickerItem) async throws -> DevelopPhotoTransfer {
        var directFailure: Error?
        do {
            let picked = try await DevelopTransferLoader.load(onStart: attachTransferProgress) { completion in
                item.loadTransferable(type: DevelopPickedPhoto.self, completionHandler: completion)
            }
            switch picked?.outcome {
            case .transfer(let transfer):
                return transfer
            case .notRaw(let refusal):
                directFailure = refusal
            case nil:
                // No representation produced a file at all.
                directFailure = nil
            }
        } catch {
            directFailure = error
        }
        // `nil` and a refused rendered file are the only outcomes the selected
        // asset's own raw can answer. Cancellation, the loader's timeout and a
        // genuine copy failure are surfaced as they are.
        guard PhotoImportService.shouldRetryFromLibrary(after: directFailure) else {
            throw directFailure ?? CancellationError()
        }
        do {
            return try await DevelopPhotoLibraryRaw.load(for: item, onStart: attachTransferProgress)
        } catch {
            throw PhotoImportService.contextualLibraryFailure(error, directFailure: directFailure)
        }
    }

    func loadClip(from item: PhotosPickerItem) async throws -> DevelopClipTransfer {
        let picked = try await DevelopTransferLoader.load(onStart: attachTransferProgress) { completion in
            item.loadTransferable(type: DevelopPickedVideo.self, completionHandler: completion)
        }
        guard let picked else { throw VideoImportError.unreadable }
        return picked.transfer
    }
}

/// The Photos half of the photo import: the raw original behind an asset the
/// system handed over as a JPEG.
///
/// Apple documents a RAW+JPEG capture as `photo` + `alternatePhoto` and leaves
/// the choice of resource to `PHAssetResourceManager`; a transferable
/// representation cannot make that choice. So when the direct transfer is
/// refused as non-raw, this reads the selected asset's raw resource instead.
///
/// Scope, deliberately: one asset, by the identifier the picker returned, and
/// only after a refusal. Nothing here enumerates the library, and nothing
/// downstream of the copy reads Photos again — the preview, the render and the
/// receipt all use the app-owned lease.
enum DevelopPhotoLibraryRaw {
    @MainActor
    static func load(for item: PhotosPickerItem,
                     onStart: @escaping (Progress) -> Void = { _ in }) async throws -> DevelopVideoModel.DevelopPhotoTransfer {
        // Without an explicit photo library the picker item carries no
        // identifier at all, so there would be nothing to ask Photos about.
        guard let identifier = item.itemIdentifier, !identifier.isEmpty else {
            throw PhotoImportError.selectionNotIdentified
        }
        // A permission decision is not a network transfer: do not time out the
        // system alert or start a download after the selection was cancelled.
        try Task.checkCancellation()
        try await PhotoLibraryRawRequest.authorizeRead()
        try Task.checkCancellation()
        let picked: DevelopVideoModel.DevelopPhotoTransfer? = try await DevelopTransferLoader.load(
            timeout: .seconds(120), onStart: onStart) { completion in
            let progress = Progress(totalUnitCount: 100)
            let request = PhotoLibraryRawRequest(identifier: identifier, progress: progress,
                                                 completion: completion)
            request.begin()
            return progress
        }
        guard let picked else { throw PhotoImportError.unreadable }
        return picked
    }
}

/// One selected asset's raw resource, streamed into a temporary file and then
/// handed to the same validate-and-copy gate the direct transfer uses.
///
/// Two cancellations have to meet here: the loader's `Progress` (superseded
/// selection, 120-second timeout) and the native data request, which is the only
/// cancellation Photos offers. `requestData` returns its identifier
/// synchronously but its callbacks arrive later on a serial queue, so the
/// identifier is installed under a lock and a request cancelled before
/// installation is cancelled the moment its identifier arrives.
private final class PhotoLibraryRawRequest: @unchecked Sendable {
    private let identifier: String
    private let progress: Progress
    private let completion: @Sendable (Result<DevelopVideoModel.DevelopPhotoTransfer?, Error>) -> Void
    private let manager = PHAssetResourceManager.default()
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var stagingDirectory: URL?
    private var writer: FileHandle?
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelled = false
    private var writeFailed = false
    private var finished = false

    init(identifier: String, progress: Progress,
         completion: @escaping @Sendable (Result<DevelopVideoModel.DevelopPhotoTransfer?, Error>) -> Void) {
        self.identifier = identifier
        self.progress = progress
        self.completion = completion
        // `Progress` is KVO-compliant for `isCancelled`, which is what the
        // loader sets when the selection is superseded or the transfer times out.
        observation = progress.observe(\.isCancelled, options: [.new]) { [weak self] progress, _ in
            guard progress.isCancelled else { return }
            self?.cancel()
        }
    }

    func begin() {
        Task { @MainActor [self] in await run() }
    }

    // Keep PhotoKit resources on the same actor as the transfer loader. Only
    // streamed bytes and lock-protected request state cross callback queues.
    @MainActor
    private func run() async {
        defer { discardStaging() }
        do {
            let (resource, descriptor) = try await rawResource()
            try checkCancellation()
            let file = try makeStagingFile(for: descriptor)
            try await stream(resource)
            try checkCancellation()
            // The same gate the direct transfer uses: the bytes are validated
            // before anything is copied into app-owned storage.
            let picked = try await DevelopPickedPhoto.accept(
                file, originalFilename: PhotoImportService.acquisitionFilename(for: descriptor))
            switch picked.outcome {
            case .transfer(let transfer):
                finish(.success(transfer))
            case .notRaw(let refusal):
                // Named raw by Photos, but the bytes are not: refuse instead of
                // developing a rendered file.
                finish(.failure(refusal))
            }
        } catch {
            finish(.failure(error))
        }
    }

    /// The asset's raw resource, fetched by the one identifier the picker gave.
    @MainActor
    private func rawResource() async throws -> (PHAssetResource, PhotoResourceDescriptor) {
        try checkCancellation()
        // Fetch, never enumerate: one asset by its local identifier.
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw PhotoImportError.assetNotInLibrary
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let descriptors = resources.map { PhotoResourceDescriptor($0) }
        guard let index = PhotoImportService.rawResourceIndex(in: descriptors), index < resources.count else {
            throw PhotoImportService.rawResourceRefusal(in: descriptors)
        }
        return (resources[index], descriptors[index])
    }

    /// Read access, asked for only when it is actually needed: the direct
    /// transfer of the picked file is permission-free, so this runs behind a
    /// refusal and never at launch.
    @MainActor
    static func authorizeRead() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            // Add-only cannot read a library, so a lookup needs read-write.
            switch await PHPhotoLibrary.requestAuthorization(for: .readWrite) {
            case .authorized, .limited:
                return
            case .restricted:
                throw PhotoImportError.libraryAccessRestricted
            default:
                throw PhotoImportError.libraryAccessDenied
            }
        case .restricted:
            throw PhotoImportError.libraryAccessRestricted
        case .denied:
            throw PhotoImportError.libraryAccessDenied
        @unknown default:
            throw PhotoImportError.libraryAccessDenied
        }
    }

    private func makeStagingFile(for descriptor: PhotoResourceDescriptor) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("develop_raw_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(PhotoImportService.acquisitionFilename(for: descriptor))
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else {
            try? FileManager.default.removeItem(at: directory)
            throw PhotoImportError.unreadable
        }
        lock.lock()
        stagingDirectory = directory
        writer = handle
        lock.unlock()
        return file
    }

    /// Stream the resource to disk. No full-image `Data` is ever accumulated.
    @MainActor
    private func stream(_ resource: PHAssetResource) async throws {
        let delivered = try await DevelopTransferLoader.load(timeout: .seconds(120)) { completion in
            let options = PHAssetResourceRequestOptions()
            // An original that lives only in iCloud is still the operator's raw.
            options.isNetworkAccessAllowed = true
            options.progressHandler = { [weak self] fraction in self?.note(fraction: fraction) }
            let installed = manager.requestData(for: resource, options: options) { [weak self] chunk in
                self?.append(chunk)
            } completionHandler: { [weak self] error in
                guard let self else {
                    completion(.success(false))
                    return
                }
                closeWriter()
                if let error {
                    completion(.failure(translate(error)))
                } else {
                    completion(.success(true))
                }
            }
            install(requestID: installed)
            // The panel's own progress doubles as the cancellation lever: a
            // superseded selection or this loader's timeout cancels it, and
            // `cancel()` drops the native request.
            return progress
        }
        guard delivered == true else { throw PhotoImportError.unreadable }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        guard !cancelled, !finished, !writeFailed, let writer else {
            lock.unlock()
            return
        }
        do {
            try writer.write(contentsOf: chunk)
            lock.unlock()
        } catch {
            writeFailed = true
            lock.unlock()
            // Nothing more can be written; stop pulling bytes and let the
            // provider's completion report the failure.
            cancel()
        }
    }

    private func closeWriter() {
        lock.lock()
        let writer = self.writer
        self.writer = nil
        lock.unlock()
        try? writer?.close()
    }

    private func note(fraction: Double) {
        guard fraction.isFinite else { return }
        progress.completedUnitCount = Int64((min(max(fraction, 0), 1) * 100).rounded())
    }

    /// Native cancellation, correct even before the request identifier exists.
    private func cancel() {
        lock.lock()
        cancelled = true
        let installed = requestID
        lock.unlock()
        if let installed, installed != PHInvalidAssetResourceDataRequestID {
            manager.cancelDataRequest(installed)
        }
    }

    private func install(requestID installed: PHAssetResourceDataRequestID) {
        lock.lock()
        let stopNow = cancelled || finished
        if !stopNow { requestID = installed }
        lock.unlock()
        if stopNow, installed != PHInvalidAssetResourceDataRequestID {
            manager.cancelDataRequest(installed)
        }
    }

    private func checkCancellation() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped || progress.isCancelled { throw CancellationError() }
    }

    private func translate(_ error: Error) -> Error {
        lock.lock()
        let stopped = cancelled || progress.isCancelled
        let failedWrite = writeFailed
        lock.unlock()
        if failedWrite { return PhotoImportError.unreadable }
        if stopped { return CancellationError() }
        // Completion can carry an error after all the bytes arrived — a
        // cancelled download does — so an error is never treated as success.
        let failure = error as NSError
        guard failure.domain == PHPhotosErrorDomain,
              let code = PHPhotosError.Code(rawValue: failure.code) else { return PhotoImportError.unreadable }
        switch code {
        case .userCancelled:
            return CancellationError()
        case .accessUserDenied:
            return PhotoImportError.libraryAccessDenied
        case .accessRestricted:
            return PhotoImportError.libraryAccessRestricted
        case .networkAccessRequired, .networkError:
            return PhotoImportError.rawDownloadUnavailable
        default:
            return PhotoImportError.unreadable
        }
    }

    private func discardStaging() {
        lock.lock()
        let directory = stagingDirectory
        stagingDirectory = nil
        lock.unlock()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func finish(_ result: Result<DevelopVideoModel.DevelopPhotoTransfer?, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let observation = self.observation
        self.observation = nil
        let writer = self.writer
        self.writer = nil
        lock.unlock()
        observation?.invalidate()
        try? writer?.close()
        completion(result)
    }
}

private extension PhotoResourceDescriptor {
    /// The Photos resource → the value type the choice is made on.
    init(_ resource: PHAssetResource) {
        let kind: Kind
        switch resource.type {
        case .photo:
            kind = .primaryPhoto
        case .alternatePhoto:
            kind = .alternatePhoto
        case .adjustmentBasePhoto:
            kind = .adjustmentBasePhoto
        case .fullSizePhoto:
            kind = .fullSizePhoto
        case .photoProxy:
            kind = .photoProxy
        case .adjustmentData, .video, .audio, .fullSizeVideo, .adjustmentBaseVideo,
             .pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo:
            kind = .sidecar
        @unknown default:
            // A type this SDK does not name: kept as evidence only if its content
            // or name says raw, and validated like any other candidate.
            kind = .unrecognized("PHAssetResourceType(rawValue: \(resource.type.rawValue))")
        }
        self.init(kind: kind, filename: resource.filename ?? "",
                  contentTypeIdentifier: resource.contentType.identifier)
    }
}
#endif
