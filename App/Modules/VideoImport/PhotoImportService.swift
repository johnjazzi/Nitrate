import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// A raw photo moved into app-owned storage, ready to develop.
struct ImportedPhoto: Sendable, Equatable {
    let url: URL
    let originalFilename: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// As-shot exposure index from the DNG when it carries one; the develop then
    /// records what was actually shot instead of the stock's default.
    let iso: Float?
    let capturedAt: Date?

    /// Date · dimensions · ISO, in the order an operator reads them.
    var detailSummary: String {
        var parts: [String] = []
        if let capturedAt {
            parts.append(capturedAt.formatted(date: .abbreviated, time: .shortened))
        }
        parts.append("\(pixelWidth) × \(pixelHeight)")
        if let iso, iso > 0, iso.isFinite {
            parts.append("ISO \(Int(iso.rounded()))")
        }
        return parts.joined(separator: " · ")
    }
}

enum PhotoImportError: LocalizedError, Equatable {
    /// The picked image is not a format the still renderer can develop. `found`
    /// names what it actually is, so the panel can say why it refused.
    case unsupported(found: String)
    case unreadable
    /// Photos refused read access, so the raw paired with the picked photo could
    /// not be looked up. Only reachable from the paired-raw fallback: the direct
    /// transfer of the picked file never needs library access.
    case libraryAccessDenied
    /// Read access is withheld by policy (parental controls, MDM), not by choice.
    case libraryAccessRestricted
    /// The picked photo is not in the library this app may read — the ordinary
    /// outcome of limited access, or of a photo deleted after it was picked.
    case assetNotInLibrary
    /// The picker item carries no asset identity, so there is nothing to ask
    /// Photos about.
    case selectionNotIdentified

    var errorDescription: String? {
        switch self {
        case .unsupported(let found):
            // One clause: what it is, and that it cannot be developed. The
            // formats it *could* have been live behind the info sheet.
            return "Not a raw photo — found \(found)."
        case .unreadable:
            return "Could not read this photo. Try again."
        case .libraryAccessDenied:
            return "Photos access is off, so the raw paired with this photo could not be read. Allow access in Settings, or import the raw file itself."
        case .libraryAccessRestricted:
            return "Photos access is restricted on this device, so the raw paired with this photo could not be read."
        case .assetNotInLibrary:
            return "This photo is not available to Nitrate. If Photos access is limited to selected photos, allow this one, or allow full access in Settings."
        case .selectionNotIdentified:
            return "The picker did not identify this photo, so its paired raw could not be found. Pick it again."
        }
    }
}

/// One resource of a Photos asset, described without Photos.
///
/// The paired-raw fallback has to answer "which of these is the operator's raw
/// original". That answer — not the Photos types — is the part worth testing, so
/// it is made on this value type, which compiles anywhere. The iOS side only
/// maps `PHAssetResource` into it.
struct PhotoResourceDescriptor: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// `PHAssetResourceType.photo`: the asset's primary original.
        case primaryPhoto
        /// `PHAssetResourceType.alternatePhoto`: Apple documents this one as the
        /// RAW when the asset's primary is a JPEG — the RAW+JPEG pair.
        case alternatePhoto
        /// `PHAssetResourceType.adjustmentBasePhoto`: the pre-edit copy.
        case adjustmentBasePhoto
        /// `PHAssetResourceType.fullSizePhoto`: a processed full-size render.
        case fullSizePhoto
        /// `PHAssetResourceType.photoProxy`: a reduced proxy.
        case photoProxy
        /// Adjustment data, video or audio sidecars.
        case sidecar
        /// A resource type this SDK does not name.
        case unrecognized(String)
    }

    var kind: Kind
    var filename: String
    var contentTypeIdentifier: String?

    init(kind: Kind, filename: String, contentTypeIdentifier: String?) {
        self.kind = kind
        self.filename = filename
        self.contentTypeIdentifier = contentTypeIdentifier
    }
}

extension PhotoResourceDescriptor {
    /// What to call this resource in a refusal, in the wording the direct gate
    /// already uses, so the operator sees one vocabulary either way.
    var foundLabel: String {
        if let contentTypeIdentifier, let type = UTType(contentTypeIdentifier) {
            return type.localizedDescription ?? contentTypeIdentifier
        }
        let fileExtension = (filename as NSString).pathExtension
        return fileExtension.isEmpty ? "an unknown image" : "a .\(fileExtension.lowercased()) file"
    }
}

/// Import gate for the develop panel's photo entry point.
///
/// Photos cannot filter a picker by file type, so — exactly like the Apple Log
/// video gate — the check runs on the file the system hands over: a picked image
/// is only copied into app storage once it is a raw file the still renderer can
/// decode.
enum PhotoImportService {
    /// Raw extensions, from the one shared definition (`RawPhotoType`).
    static let rawExtensions: Set<String> = RawPhotoType.extensions

    /// True for a raw file the still renderer is expected to decode. The rule
    /// lives in `RawPhotoType` so the importer, the queue and the Photos saver
    /// cannot drift apart on it.
    static func isRaw(_ url: URL) -> Bool { RawPhotoType.isRaw(url) }

    /// The gate that actually decides: can this machine's RAW pipeline develop
    /// the file?
    ///
    /// Deliberately capability-based rather than a table of supported cameras.
    /// A per-maker list would have to be extended for every model Nikon, Sony or
    /// Canon ships, and it would still be wrong about the ones it had not seen.
    /// `CIRAWFilter` answers for all of them at once: it opens a raw container
    /// and refuses anything else, so a JPEG that reached this point by name is
    /// rejected and a brand-new NEF is accepted on the same rule.
    ///
    /// The still renderer decodes through exactly this API, so a file that
    /// passes here is a file the pipeline can actually develop — not merely one
    /// with a known extension.
    static func canDevelop(_ url: URL) -> Bool {
        // Content first: `CIRAWFilter` will open plenty of non-raw images, so
        // "it opened" is not the test.
        guard isRaw(url) else { return false }
        guard let raw = CIRAWFilter(imageURL: url) else { return false }
        // Any decoder version will do — a NEF offers its own set and never
        // "8.dng" — but a file that offers none cannot be developed at all.
        guard RAWPhotoDecoder.preferredDecoderVersion(from: raw.supportedDecoderVersions) != nil,
              raw.outputImage != nil else { return false }
        return true
    }

    /// The gate the picker runs BEFORE copying the file into app storage: a
    /// picked image is copied only once it is a raw the renderer can develop.
    static func validateRaw(at url: URL) async throws {
        _ = try await inspect(url: url)
    }

    // MARK: - The raw half of a RAW+JPEG pair

    private static let cameraRawType = UTType("public.camera-raw-image")

    /// Which resource of a picked asset holds the operator's raw original.
    ///
    /// Ranked, not filtered, because where the raw lives depends on the pair: a
    /// RAW-primary capture (Apple ProRAW, or a raw Photos already holds) keeps
    /// the raw in `photo`; a JPEG-primary capture keeps the JPEG in `photo` and
    /// the raw in `alternatePhoto`.
    ///
    /// Derivatives are never candidates: `fullSizePhoto` and `photoProxy` are a
    /// render and a reduced copy, and `adjustmentBasePhoto` is the base *before*
    /// the operator's edit — a different picture from the one they picked, and
    /// not something to develop behind their back.
    ///
    /// This only names a resource. The bytes still pass `validateRaw`, so a type
    /// this SDK cannot classify cannot carry a JPEG past the gate.
    static func rawResourceIndex(in resources: [PhotoResourceDescriptor]) -> Int? {
        var chosen: (rank: Int, index: Int)?
        for (index, resource) in resources.enumerated() {
            guard let rank = rawResourceRank(resource) else { continue }
            if let current = chosen, current.rank <= rank { continue }
            chosen = (rank, index)
        }
        return chosen?.index
    }

    private static func rawResourceRank(_ resource: PhotoResourceDescriptor) -> Int? {
        switch resource.kind {
        case .fullSizePhoto, .photoProxy, .adjustmentBasePhoto, .sidecar:
            // A render, a proxy, a pre-edit base, or not a picture at all.
            return nil
        case .primaryPhoto:
            return isRawResource(resource) ? 0 : nil
        case .alternatePhoto:
            return isRawResource(resource) ? 1 : nil
        case .unrecognized:
            // An unnamed type is still evidence when its content type or name
            // says raw; it ranks last so a known raw resource always wins.
            return isRawResource(resource) ? 2 : nil
        }
    }

    /// Is this resource itself a raw container?
    ///
    /// Same rule as `RawPhotoType.isRaw`, in the same order: a maker's raw type
    /// conforms to BOTH camera-raw and image (`com.nikon.raw-image` does), so
    /// camera-raw is asked first; a rendered type is refused whatever it is
    /// called; and only a type that says nothing at all leaves the filename as
    /// the evidence.
    static func isRawResource(_ resource: PhotoResourceDescriptor) -> Bool {
        let fileExtension = (resource.filename as NSString).pathExtension.lowercased()
        let knownRawName = rawExtensions.contains(fileExtension)
        guard let identifier = resource.contentTypeIdentifier,
              let type = UTType(identifier) else { return knownRawName }
        if let cameraRawType, type.conforms(to: cameraRawType) { return true }
        if type.conforms(to: .image) { return false }
        return knownRawName
    }

    /// The filename to give the acquired resource: the operator's own, so a NEF
    /// stays a NEF and never becomes a .dng that lies about its container.
    static func acquisitionFilename(for resource: PhotoResourceDescriptor) -> String {
        let name = (resource.filename as NSString).lastPathComponent
        let fileExtension = (name as NSString).pathExtension
        // Any named extension is kept as it is — relabelling a container to a
        // raw name would claim a format nobody verified.
        if !name.isEmpty, !fileExtension.isEmpty { return name }
        let stem = (name as NSString).deletingPathExtension
        return "\(stem.isEmpty ? "paired_raw" : stem).\(ownedExtension(for: resource))"
    }

    /// The extension to give an acquired resource that carries no usable name:
    /// what its content type says, and only then the raw container this app
    /// writes most often.
    static func ownedExtension(for resource: PhotoResourceDescriptor) -> String {
        if let identifier = resource.contentTypeIdentifier,
           let preferred = UTType(identifier)?.preferredFilenameExtension?.lowercased(),
           rawExtensions.contains(preferred) {
            return preferred
        }
        return "dng"
    }

    /// Should a failed direct transfer be retried against the selected asset's
    /// own raw resource?
    ///
    /// Only two outcomes mean "the system handed over something this panel cannot
    /// develop": no file at all (nil), and the gate refusing a rendered file. A
    /// cancellation, the loader's timeout, and a genuine copy or I/O failure are
    /// settled — retrying them would ignore the operator, or repeat the same
    /// failure behind a permission prompt for a read that cannot help.
    static func shouldRetryFromLibrary(after failure: Error?) -> Bool {
        guard let failure else { return true }
        if failure is CancellationError { return false }
        if failure is DevelopTransferLoader.TransferError { return false }
        guard let photoFailure = failure as? PhotoImportError,
              case .unsupported = photoFailure else { return false }
        return true
    }

    /// Validate, then hand back everything the panel and the render need.
    static func inspect(url: URL, originalFilename: String? = nil) async throws -> ImportedPhoto {
        try Task.checkCancellation()
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw PhotoImportError.unreadable
        }
        // A raw container the system's RAW pipeline cannot develop is refused
        // here, before the copy, whether it is a DNG or a maker's own container.
        guard isRaw(url), canDevelop(url) else {
            let found = (CGImageSourceGetType(source) as String?).map { identifier in
                UTType(identifier)?.localizedDescription ?? identifier
            } ?? (url.pathExtension.isEmpty ? "an unknown image" : "a .\(url.pathExtension.lowercased()) file")
            throw PhotoImportError.unsupported(found: found)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { throw PhotoImportError.unreadable }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.floatValue
        var capturedAt: Date?
        if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            capturedAt = formatter.date(from: text)
        }
        if capturedAt == nil {
            capturedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        return ImportedPhoto(url: url, originalFilename: originalFilename ?? url.lastPathComponent,
                             pixelWidth: width, pixelHeight: height, iso: iso, capturedAt: capturedAt)
    }
}
