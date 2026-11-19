import Foundation
import Testing

/// The RAW half of a RAW+JPEG capture.
///
/// A Photos picker hands over one file per item, and a transferable
/// representation cannot name which resource of the asset that file should be —
/// which is why a JPEG-primary pair used to arrive as the JPEG and be refused as
/// "not a raw photo". These tests pin the choices that were missing: which
/// resource is the operator's raw original, what it is called, and when a
/// refused direct transfer is worth retrying against the library at all.
@Suite("Develop paired raw resources")
struct DevelopPhotoResourceTests {
    private static func resource(_ kind: PhotoResourceDescriptor.Kind, _ name: String,
                                 _ type: String?) -> PhotoResourceDescriptor {
        PhotoResourceDescriptor(kind: kind, filename: name, contentTypeIdentifier: type)
    }

    // MARK: - Which resource is the raw original

    /// A camera's RAW+JPEG capture in Photos: the JPEG is the asset's primary
    /// resource and the raw is its alternate. Apple documents `alternatePhoto`
    /// as the RAW in exactly this arrangement.
    @Test func aJPEGPrimaryPairKeepsItsRawInTheAlternateResource() {
        let pair = [
            Self.resource(.primaryPhoto, "IMG_4711.JPG", "public.jpeg"),
            Self.resource(.alternatePhoto, "IMG_4711.NEF", "com.nikon.raw-image"),
            Self.resource(.fullSizePhoto, "IMG_4711.JPG", "public.jpeg"),
            Self.resource(.sidecar, "", nil)
        ]

        let index = PhotoImportService.rawResourceIndex(in: pair)
        #expect(index == 1, "the alternate resource is the raw of a JPEG-primary pair")
        #expect(pair[index ?? 0].filename == "IMG_4711.NEF")
    }

    /// The regression this work exists for, stated as the two choices the picker
    /// actually has. The direct transfer only ever sees the PRIMARY resource —
    /// the `.image` representation loads it and it is a JPEG — so before this
    /// change the pair could not reach its raw at all. The resource chooser is
    /// what makes the alternate reachable.
    @Test func theDirectTransferCannotReachTheAlternateRaw() {
        let pair = [
            Self.resource(.primaryPhoto, "IMG_4711.JPG", "public.jpeg"),
            Self.resource(.alternatePhoto, "IMG_4711.NEF", "com.nikon.raw-image")
        ]

        let primaryOnly = pair.filter { $0.kind == .primaryPhoto }
        #expect(PhotoImportService.rawResourceIndex(in: primaryOnly) == nil,
                "what a transfer representation can reach holds no raw")
        #expect(PhotoImportService.rawResourceIndex(in: pair) == 1,
                "the paired raw is reachable through the asset's resources")
    }

    /// The mirror image: a raw-primary capture (Apple ProRAW, or a raw Photos
    /// already holds) keeps the raw in `photo`, and the alternate JPEG must not
    /// displace it.
    @Test func aRawPrimaryPairIgnoresTheAlternateJPEG() {
        let pair = [
            Self.resource(.primaryPhoto, "IMG_4711.DNG", "com.adobe.raw-image"),
            Self.resource(.alternatePhoto, "IMG_4711.JPG", "public.jpeg")
        ]

        #expect(PhotoImportService.rawResourceIndex(in: pair) == 0)
    }

    /// An ordinary capture has no raw to choose, so the refusal must come from
    /// the gate naming what it found rather than from a silent JPEG develop.
    @Test func anOrdinaryImageHasNoRawCandidate() {
        let rendered = [
            Self.resource(.primaryPhoto, "IMG_0001.HEIC", "public.heic"),
            Self.resource(.sidecar, "", nil)
        ]

        #expect(PhotoImportService.rawResourceIndex(in: rendered) == nil)
        #expect(rendered[0].foundLabel.contains("HEIF"),
                "the refusal names the format: \(rendered[0].foundLabel)")
        #expect(Self.resource(.primaryPhoto, "IMG_9.JPG", "public.jpeg").foundLabel.contains("JPEG"))
    }

    /// `fullSizePhoto`, `photoProxy` and `adjustmentBasePhoto` are renders of an
    /// edit or reduced copies. They are never the negative, even when their type
    /// or name would pass a raw check.
    @Test func derivativesAreNeverTheOriginal() {
        let derivatives = [
            Self.resource(.fullSizePhoto, "IMG_9.DNG", "com.adobe.raw-image"),
            Self.resource(.photoProxy, "IMG_9.NEF", "com.nikon.raw-image"),
            Self.resource(.adjustmentBasePhoto, "IMG_9.DNG", "com.adobe.raw-image")
        ]

        #expect(PhotoImportService.rawResourceIndex(in: derivatives) == nil)
    }

    /// A resource type this SDK does not name is still evidence when its name
    /// says raw — and ranks behind a known raw resource, so it cannot displace
    /// one. Naming it a candidate is not a bypass: the acquired bytes still pass
    /// `validateRaw`.
    @Test func anUnnamedResourceTypeRanksLast() {
        let unnamed = Self.resource(.unrecognized("PHAssetResourceType(rawValue: 99)"),
                                    "IMG_7.NEF", nil)
        #expect(PhotoImportService.rawResourceIndex(in: [unnamed]) == 0)

        let mixed = [
            unnamed,
            Self.resource(.primaryPhoto, "IMG_7.DNG", "com.adobe.raw-image")
        ]
        #expect(PhotoImportService.rawResourceIndex(in: mixed) == 1,
                "a known raw resource always wins")
    }

    /// The raw check asks about content first. A maker's raw type conforms to
    /// both camera-raw and image, and a JPEG cannot borrow a raw filename.
    @Test func rawContentOutranksARawFilename() {
        #expect(PhotoImportService.isRawResource(
            Self.resource(.primaryPhoto, "IMG_7.xyz", "com.adobe.raw-image")))
        #expect(PhotoImportService.isRawResource(
            Self.resource(.primaryPhoto, "IMG_7.NEF", "public.jpeg")) == false,
                "a JPEG named .NEF is not a raw resource")
        #expect(PhotoImportService.isRawResource(
            Self.resource(.alternatePhoto, "IMG_7.NEF", "com.nikon.raw-image")))
        #expect(PhotoImportService.isRawResource(
            Self.resource(.alternatePhoto, "IMG_7.NEF", "public.data")),
                "a type that says nothing leaves the name as the evidence")
    }

    // MARK: - The name the acquired file keeps

    /// The operator's own filename survives: a NEF stays a NEF, because a file
    /// renamed .dng would lie about its container.
    @Test func theAcquiredFileKeepsItsOwnName() {
        #expect(PhotoImportService.acquisitionFilename(for:
            Self.resource(.alternatePhoto, "DSC_4800.NEF", "com.nikon.raw-image")) == "DSC_4800.NEF")
        #expect(PhotoImportService.acquisitionFilename(for:
            Self.resource(.primaryPhoto, "IMG_0001.DNG", "com.adobe.raw-image")) == "IMG_0001.DNG")
        #expect(PhotoImportService.acquisitionFilename(for:
            Self.resource(.alternatePhoto, "A/B/C.ARW", "com.sony.arw-raw-image")) == "C.ARW",
                "no path components reach a filename")
    }

    /// Only a resource with no usable name is given one, and its extension comes
    /// from its content type when that type knows one.
    @Test func anUnnamedResourceIsGivenAContentTypedName() {
        #expect(PhotoImportService.acquisitionFilename(for:
            Self.resource(.primaryPhoto, "", "com.adobe.raw-image")) == "paired_raw.dng")
        #expect(PhotoImportService.acquisitionFilename(for:
            Self.resource(.primaryPhoto, "capture", "com.adobe.raw-image")) == "capture.dng")
        #expect(PhotoImportService.acquisitionFilename(for:
            Self.resource(.primaryPhoto, "", "public.data")) == "paired_raw.dng")
    }

    // MARK: - When to retry against the library

    /// Only "the system handed over nothing" and "the gate refused a rendered
    /// file" reach the library. Everything settled — cancellation, the loader's
    /// timeout, a copy or I/O failure — is surfaced instead of being retried
    /// behind a permission prompt.
    @Test func onlyARefusedOrEmptyTransferRetriesFromTheLibrary() {
        #expect(PhotoImportService.shouldRetryFromLibrary(after: nil),
                "no representation produced a file")
        #expect(PhotoImportService.shouldRetryFromLibrary(
            after: PhotoImportError.unsupported(found: "JPEG")))

        #expect(PhotoImportService.shouldRetryFromLibrary(after: CancellationError()) == false)
        #expect(PhotoImportService.shouldRetryFromLibrary(
            after: DevelopTransferLoader.TransferError.timedOut) == false)
        #expect(PhotoImportService.shouldRetryFromLibrary(
            after: VideoImportError.unreadable) == false)
        #expect(PhotoImportService.shouldRetryFromLibrary(
            after: VideoImportError.insufficientStorage) == false)
        #expect(PhotoImportService.shouldRetryFromLibrary(
            after: PhotoImportError.unreadable) == false)
        #expect(PhotoImportService.shouldRetryFromLibrary(
            after: PhotoImportError.libraryAccessDenied) == false,
                "a library refusal is not retried against the library")
    }

    // MARK: - What the operator is told

    @Test func aLibraryRefusalNamesThePrimaryPhotoNotItsSidecars() throws {
        let resources = [
            Self.resource(.sidecar, "IMG_7.MOV", "com.apple.quicktime-movie"),
            Self.resource(.primaryPhoto, "IMG_7.JPG", "public.jpeg")
        ]
        let refusal = PhotoImportService.rawResourceRefusal(in: resources)
        let message = try #require(refusal.errorDescription)
        #expect(message.contains("JPEG"))
        #expect(!message.contains("QuickTime"))
    }

    @Test func aRawEditingBaseIsNotMisreportedAsAJPEG() {
        let resources = [
            Self.resource(.primaryPhoto, "IMG_7.JPG", "public.jpeg"),
            Self.resource(.adjustmentBasePhoto, "IMG_7.NEF", "com.nikon.raw-image")
        ]
        #expect(PhotoImportService.rawResourceIndex(in: resources) == nil)
        #expect(PhotoImportService.rawResourceRefusal(in: resources) == .rawEditingBaseOnly)
        #expect(PhotoImportError.rawEditingBaseOnly.errorDescription?.contains("unedited RAW original") == true)
    }

    @Test func deniedLookupKeepsTheRenderedFormatWithoutClaimingARawExists() throws {
        for failure in [PhotoImportError.libraryAccessDenied, .libraryAccessRestricted, .assetNotInLibrary] {
            let contextual = PhotoImportService.contextualLibraryFailure(failure,
                directFailure: PhotoImportError.unsupported(found: "JPEG image"))
            let message = contextual.localizedDescription
            let reason = try #require(failure.errorDescription)
            #expect(message.hasPrefix("Photos supplied JPEG image."))
            #expect(message.contains(reason))
            #expect(!message.contains("the raw paired with this photo could not be read"))
        }
        let cancelled = PhotoImportService.contextualLibraryFailure(CancellationError(),
            directFailure: PhotoImportError.unsupported(found: "JPEG image"))
        #expect(cancelled is CancellationError)
        let unreadable = PhotoImportService.contextualLibraryFailure(PhotoImportError.unreadable,
            directFailure: PhotoImportError.unsupported(found: "JPEG image")) as? PhotoImportError
        #expect(unreadable == .unreadable)
    }

    @Test func anUnavailableCloudOriginalHasAConnectionRecoveryMessage() throws {
        let message = try #require(PhotoImportError.rawDownloadUnavailable.errorDescription)
        #expect(message.contains("iCloud"))
        #expect(message.contains("connection"))
        #expect(!PhotoImportService.shouldRetryFromLibrary(after: PhotoImportError.rawDownloadUnavailable))
    }

    /// Denial, restriction and a limited library missing the picked photo are
    /// distinct, actionable outcomes — never a silent JPEG develop, and never a
    /// bare "try again".
    @Test func everyLibraryRefusalSaysWhatToDo() throws {
        let matters: [(PhotoImportError, String)] = [
            (.libraryAccessDenied, "Settings"),
            (.libraryAccessRestricted, "restricted"),
            (.assetNotInLibrary, "limited"),
            (.selectionNotIdentified, "Pick it again")
        ]

        for (error, instruction) in matters {
            let message = try #require(error.errorDescription)
            #expect(message.contains(instruction), "\(error) should say: \(instruction) — got \(message)")
        }
    }

    /// The refusal vocabulary stays the one the panel already uses for a picked
    /// JPEG, so the fallback does not introduce a second way to say no.
    @Test func aRefusalUsesTheExistingWording() {
        #expect(PhotoImportError.unsupported(found: "JPEG image").errorDescription
                == "Not a raw photo — found JPEG image.")
    }
}
