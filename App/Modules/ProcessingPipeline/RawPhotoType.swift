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

    /// Snap judgement from the first bytes, before any decoder is asked.
    ///
    /// This exists to FAIL FAST. Photos hands over a full copy of what was
    /// picked, so a 40 MB HEIC was being written to app storage and then handed
    /// to `CIRAWFilter` before anyone could say "that is not a raw". A JPEG, HEIC,
    /// PNG or WebP announces itself in its first eight bytes, so the refusal
    /// costs a 16-byte read instead of a decode.
    ///
    /// Returns true only when the file is definitely a rendered image. A raw
    /// container (TIFF-based: DNG, NEF, ARW, CR2/CR3, RAF…) returns false, and
    /// anything this cannot classify returns nil and falls through to ImageIO.
    static func isDefinitelyRenderedImage(_ url: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16), data.count >= 4 else { return nil }
        let bytes = [UInt8](data)

        func matches(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            guard bytes.count >= offset + signature.count else { return false }
            return Array(bytes[offset..<(offset + signature.count)]) == signature
        }

        if matches([0xFF, 0xD8, 0xFF]) { return true }                       // JPEG
        if matches([0x89, 0x50, 0x4E, 0x47]) { return true }                 // PNG
        if matches(Array("GIF8".utf8)) { return true }                       // GIF
        if matches(Array("BM".utf8)) { return true }                         // BMP
        if matches(Array("8BPS".utf8)) { return true }                       // PSD
        if matches(Array("RIFF".utf8)), matches(Array("WEBP".utf8), at: 8) { return true }
        // ISO base media: HEIF/HEIC/AVIF from the camera roll.
        if matches(Array("ftyp".utf8), at: 4) {
            let brand = String(decoding: bytes[8..<min(12, bytes.count)], as: UTF8.self)
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis"].contains(brand) {
                return true
            }
        }
        // TIFF-based container: every raw this app develops is one of these.
        if matches([0x49, 0x49, 0x2A, 0x00]) || matches([0x4D, 0x4D, 0x00, 0x2A]) { return false }
        return nil
    }

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
        // Cheapest test first: a JPEG renamed .nef is refused here, in one small
        // read, without touching a decoder.
        if isDefinitelyRenderedImage(url) == true { return false }
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
