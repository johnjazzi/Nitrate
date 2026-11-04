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

    var errorDescription: String? {
        switch self {
        case .unsupported(let found):
            // One clause: what it is, and that it cannot be developed. The
            // formats it *could* have been live behind the info sheet.
            return "Not a raw photo — found \(found)."
        case .unreadable:
            return "Could not read this photo. Try again."
        }
    }
}

/// Import gate for the develop panel's photo entry point.
///
/// Photos cannot filter a picker by file type, so — exactly like the Apple Log
/// video gate — the check runs on the file the system hands over: a picked image
/// is only copied into app storage once it is a raw file the still renderer can
/// decode.
enum PhotoImportService {
    /// Raw extensions Apple ProRAW and the common camera makers write. The
    /// renderer decodes with Core Image's RAW pipeline, so the gate is "is this
    /// a raw file", not "is this one specific camera's".
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "pef", "srw", "3fr", "fff", "iiq", "x3f"
    ]

    private static let rawType = UTType("public.camera-raw-image")

    /// The file's own type, or nil when ImageIO cannot identify it at all.
    private static func contentType(_ url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier)
    }

    /// True for a raw file the still renderer is expected to decode.
    ///
    /// CONTENT decides, and the name is only a fallback for a file ImageIO
    /// cannot identify: a JPEG renamed `.nef` is a JPEG, and a name check alone
    /// would carry it into a decode that cannot honour it.
    static func isRaw(_ url: URL) -> Bool {
        if let type = contentType(url), let rawType {
            return type.conforms(to: rawType)
        }
        return rawExtensions.contains(url.pathExtension.lowercased())
    }

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
