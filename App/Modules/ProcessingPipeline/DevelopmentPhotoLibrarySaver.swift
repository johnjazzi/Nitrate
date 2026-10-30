import CryptoKit
import Foundation
import Photos

/// Saves an already-written photo resource without moving or deleting its local copy.
actor DevelopmentPhotoLibrarySaver {
    static let shared = DevelopmentPhotoLibrarySaver()

    struct SaveEvidence: Sendable {
        let localIdentifier: String
    }

    enum SaveError: Error, LocalizedError {
        case invalidDNG
        case authorizationDenied
        case alreadySaved(localIdentifier: String)
        case previousAttemptUncertain
        case receiptUnavailable
        case photoLibrary(Error)

        var errorDescription: String? {
            switch self {
            case .invalidDNG: return "The photo resource is missing, empty, or not a supported image file."
            case .authorizationDenied: return "Photo Library add-only access was not granted."
            case .alreadySaved: return "This capture was already saved to Photos."
            case .previousAttemptUncertain: return "A previous save may have completed; automatic retry was prevented."
            case .receiptUnavailable: return "Could not persist the durable Photos-save receipt."
            case .photoLibrary(let error): return error.localizedDescription
            }
        }
    }

    private enum ReceiptState: Codable {
        case pending
        case confirmed(localIdentifier: String)
    }

    private struct Receipt: Codable {
        var captures: [String: ReceiptState] = [:]
    }

    private let receiptURL: URL

    init(receiptURL: URL? = nil) {
        if let receiptURL {
            self.receiptURL = receiptURL
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Nitrate", isDirectory: true)
            self.receiptURL = directory.appendingPathComponent("development-photo-library-receipt.json")
        }
    }

    /// Returns only evidence from the Photos creation completion; local media remains in place.
    func save(originalDNG url: URL) async -> Result<SaveEvidence, SaveError> {
        guard ["dng", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
            return .failure(.invalidDNG)
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let resolvedStatus: PHAuthorizationStatus
        if status == .notDetermined {
            resolvedStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            resolvedStatus = status
        }
        guard resolvedStatus == .authorized || resolvedStatus == .limited else {
            return .failure(.authorizationDenied)
        }

        // Capture folder IDs survive app-container relocation after reinstall.
        let identity = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
        let key = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        var receipt: Receipt
        do {
            receipt = try loadReceipt()
        } catch {
            return .failure(.receiptUnavailable)
        }
        switch receipt.captures[key] {
        case .confirmed(let identifier): return .failure(.alreadySaved(localIdentifier: identifier))
        case .pending: return .failure(.previousAttemptUncertain)
        case nil: break
        }

        receipt.captures[key] = .pending
        do {
            try persist(receipt)
        } catch {
            return .failure(.receiptUnavailable)
        }

        do {
            let identifier = try await createAsset(from: url)
            // The actor can save another capture while Photos is awaited.
            receipt = try loadReceipt()
            receipt.captures[key] = .confirmed(localIdentifier: identifier)
            try persist(receipt)
            return .success(SaveEvidence(localIdentifier: identifier))
        } catch let error as SaveError {
            return .failure(error)
        } catch {
            // Keep pending after submission: completion may be ambiguous and retry could duplicate.
            return .failure(.photoLibrary(error))
        }
    }

    private func createAsset(from url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let identifierBox = PlaceholderIdentifierBox()
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                identifierBox.identifier = request.placeholderForCreatedAsset?.localIdentifier
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: url, options: options)
            } completionHandler: { success, error in
                if success, let identifier = identifierBox.identifier {
                    continuation.resume(returning: identifier)
                } else {
                    continuation.resume(throwing: error ?? SaveError.previousAttemptUncertain)
                }
            }
        }
    }

    private final class PlaceholderIdentifierBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        var identifier: String? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }
    }

    private func loadReceipt() throws -> Receipt {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return Receipt() }
        return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
    }

    private func persist(_ receipt: Receipt) throws {
        try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: receiptURL, options: .atomic)
    }
}
