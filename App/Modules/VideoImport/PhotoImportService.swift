import Foundation
import CoreGraphics
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
            return "This image is not a raw photo the pipeline can develop "
                + "(found \(found)). Choose a DNG."
        case .unreadable:
            return "This photo could not be read. Try selecting it again."
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

    /// True for a raw file the still renderer is expected to decode.
    static func isRaw(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) { return true }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String? else { return false }
        return UTType(type)?.conforms(to: UTType("public.camera-raw-image") ?? .image) == true
            && UTType(type)?.identifier != UTType.heic.identifier
            && UTType(type)?.identifier != UTType.jpeg.identifier
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
        guard isRaw(url) else {
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
