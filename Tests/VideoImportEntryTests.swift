import Foundation
import Testing

struct VideoImportEntryTests {
    private func source(_ relative: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(relative),
                   encoding: .utf8)
    }

    @Test func developIsTheOnlyVideoEntryAndTheQueueHasNoLegacyImportAction() throws {
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        #expect(!sheet.contains("Process Video"))
        #expect(!sheet.contains("showVideoImport"))
        #expect(!sheet.contains("VideoImportSheet"))
        #expect(!sheet.contains("videoImport.open"))
    }

    @Test func cameraHasADirectDevelopModeWithoutOpeningTheQueue() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("CameraModeCarousel(selected: cameraMode.selected"))
        // Inline in the camera screen, not a modal sheet. The panel is built in
        // an extracted `developPanel` property (its closures and bindings blew the
        // type checker's budget inline), so match the construction, not a line.
        #expect(screen.contains("DevelopPreview("))
        #expect(screen.contains("model: developModel"))
        #expect(screen.contains("queue: renderQueueViewModel"))
        #expect(!screen.contains(".sheet(isPresented: developPresented"))
        #expect(screen.contains("developModel.leaveDevelop()"))
        #expect(screen.contains("isDevelopMode: isDevelopMode"))
        #expect(screen.contains("selectionOnly: isDevelopMode"))
        #expect(screen.contains(".allowsHitTesting(!isDevelopMode)"))
        // A refused mode tap answers with the reason rather than returning
        // silently: the dimmed row has no standing banner to explain itself.
        #expect(!screen.contains("guard canChangeCameraMode else { return }"))
        #expect(screen.contains("explainBlockedModeTap()"))
        #expect(screen.contains("CameraModeStripGeometry.frame"))
    }

    @Test func importedVideosCannotReachTheLegacyPlayer() throws {
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        #expect(sheet.contains("if job.isImportedVideo != true, let url = job.retainedOutputURL"))
        #expect(sheet.contains("guard job.isImportedVideo != true, job.retainedOutputURL != nil else { return }"))
    }
}
