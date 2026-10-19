import Foundation
import Testing

struct QueueReceiptPresentationTests {
    @Test func latestRenderUsesReceiptDateAndExcludesOriginalsAndPending() {
        let oldID = UUID()
        let latestID = UUID()
        let candidates = [
            QueueReceiptPresentation.Candidate(id: oldID, completed: true, originalOnly: false,
                                               createdAt: Date(timeIntervalSince1970: 500),
                                               recordedAt: Date(timeIntervalSince1970: 100)),
            QueueReceiptPresentation.Candidate(id: latestID, completed: true, originalOnly: false,
                                               createdAt: Date(timeIntervalSince1970: 50),
                                               recordedAt: Date(timeIntervalSince1970: 200)),
            QueueReceiptPresentation.Candidate(id: UUID(), completed: true, originalOnly: true,
                                               createdAt: Date(timeIntervalSince1970: 900)),
            QueueReceiptPresentation.Candidate(id: UUID(), completed: false, originalOnly: false,
                                               createdAt: Date(timeIntervalSince1970: 1000))
        ]
        #expect(QueueReceiptPresentation.latestRenderID(in: candidates) == latestID)
    }

    @Test func legacyRenderFallsBackToQueuedDate() {
        let legacy = QueueReceiptPresentation.Candidate(id: UUID(), completed: true, originalOnly: false,
                                                       createdAt: Date(timeIntervalSince1970: 200))
        #expect(QueueReceiptPresentation.latestRenderID(in: [legacy]) == legacy.id)
        #expect(QueueReceiptPresentation.latestRenderID(in: []) == nil)
    }

    @Test func unknownAndNonfiniteDetailsStayUnavailable() {
        #expect(QueueReceiptPresentation.number(nil) == "Unavailable")
        #expect(QueueReceiptPresentation.number(.nan) == "Unavailable")
        #expect(QueueReceiptPresentation.number(.infinity) == "Unavailable")
        #expect(QueueReceiptPresentation.number(-1) == "Unavailable")
        #expect(QueueReceiptPresentation.number(23.976) == "23.98")
        #expect(QueueReceiptPresentation.metadata([:], "stock-name") == "Unavailable")
        #expect(QueueReceiptPresentation.metadata(["stock-name": "Wrong key"], "stock-name") == "Unavailable")
        #expect(QueueReceiptPresentation.metadata(["com.filmemulation.stock-name": "Film"], "stock-name") == "Film")
        #expect(QueueReceiptPresentation.savedStatus(nil) == "Unknown (legacy record)")
        #expect(QueueReceiptPresentation.numericMetadata(["com.filmemulation.iso": "nan"], "iso") == "Unavailable")
        #expect(QueueReceiptPresentation.numericMetadata(["com.filmemulation.iso": "500"], "iso") == "500")
    }

    @Test func savedAndRetainedActionsAreIndependent() {
        let cleaned = QueueReceiptPresentation.Actions(savedToPhotos: true, retainedOutput: false)
        #expect(cleaned.openPhotos)
        #expect(!cleaned.playLocal && !cleaned.shareLocal)
        #expect(cleaned.metadata)
        let partial = QueueReceiptPresentation.Actions(savedToPhotos: false, retainedOutput: true)
        #expect(!partial.openPhotos)
        #expect(partial.playLocal && partial.shareLocal && partial.metadata)
        let legacy = QueueReceiptPresentation.Actions(savedToPhotos: false, retainedOutput: false)
        #expect(!legacy.openPhotos && !legacy.playLocal && !legacy.shareLocal)
        #expect(legacy.metadata)
    }

    /// Source-contract coverage only: native hit testing and handoff still need device checks.
    @Test func independentActionsAreWiredWithoutPhotosReads() throws {
        let root = TestRepository.root
        let folder = root.appendingPathComponent("App/Modules/RenderQueue")
        let views = try String(contentsOf: folder.appendingPathComponent("QueueReceiptViews.swift"), encoding: .utf8)
        let sheet = try String(contentsOf: folder.appendingPathComponent("QueueSheetView.swift"), encoding: .utf8)
        let opener = try String(contentsOf: folder.appendingPathComponent("PhotosLibraryOpener.swift"), encoding: .utf8)
        #expect(views.contains("Button(action: openPhotos) { poster }"))
        #expect(views.contains("Button(action: showMetadata)"))
        #expect(views.contains(".accessibilityIdentifier(QueueReceiptPresentation.metadataActionID)"))
        #expect(views.contains("UIImage(data: data)"))
        #expect(sheet.contains("showMetadata: { metadataJob = job }"))
        #expect(sheet.contains(".sheet(item: $metadataJob)"))
        #expect(sheet.contains(".alert(\"Could not open Photos\""))
        #expect(sheet.contains("photosOpenFailed = !(await PhotosLibraryOpener.open())"))
        #expect(opener.contains("UIApplication.shared.open(url, options: [:])"))
        #expect(!opener.contains("canOpenURL("))
        for source in [views, sheet, opener] {
            #expect(!source.contains("import Photos"))
            #expect(!source.contains("PHAsset"))
            #expect(!source.contains("AVAssetImageGenerator"))
            #expect(!source.contains("PhotosPicker"))
        }
    }

    @Test func actionsHaveDistinctStableTargetsAndMinimumTouchHeight() {
        #expect(QueueReceiptPresentation.photosActionID != QueueReceiptPresentation.metadataActionID)
        #expect(QueueReceiptPresentation.minimumActionHeight >= 44)
    }
}
