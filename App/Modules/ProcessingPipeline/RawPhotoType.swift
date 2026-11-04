import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What counts as a raw photo, decided once.
///
/// Three places need this answer and must never disagree: the import gate that
/// decides whether a picked file may be copied, the queue's sanity check, and
/// the Photos side that stores the original beside the develop. They used to
/// each carry their own rule — which is how the saver ended up refusing a Nikon
/// NEF that the importer had accepted and the renderer had already developed.
enum RawPhotoType {
    /// Raw extensions Apple ProRAW and the common camera makers write. Used only
    /// when ImageIO cannot identify the file at all.
    static let extensions: Set<String> = [
        "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "pef", "srw", "3fr", "fff", "iiq", "x3f"
    ]

    private static let cameraRaw = UTType("public.camera-raw-image")

    /// The file's own type, or nil when ImageIO cannot identify it.
    static func contentType(_ url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier)
    }

    /// CONTENT decides where it can speak: a JPEG renamed `.nef` is a JPEG, and a
    /// name-only check would carry it into a decode that cannot honour it.
    ///
    /// But ImageIO does not always recognise a maker's raw container, and when
    /// it says nothing we must not refuse a file the renderer can develop — so a
    /// raw NAME is accepted unless the content proves the file is some other
    /// rendered image (JPEG, HEIC, TIFF, PNG…). That is the difference between
    /// "this is known not to be raw" and "I do not know what this is".
    static func isRaw(_ url: URL) -> Bool {
        let knownRawName = extensions.contains(url.pathExtension.lowercased())
        guard let type = contentType(url) else { return knownRawName }
        if let cameraRaw, type.conforms(to: cameraRaw) { return true }
        // Identified as a rendered image: refuse, whatever it is called.
        if type.conforms(to: .image) { return false }
        // Identified as something opaque (public.data and friends): the name is
        // the only evidence available.
        return knownRawName
    }
}
