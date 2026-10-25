import Foundation
import Testing

struct VideoImportEntryTests {
    private func source(_ relative: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(relative),
                   encoding: .utf8)
    }

    @Test func shippingQueueHasAReachableProcessVideoAction() throws {
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        #expect(sheet.contains("Label(\"Process Video\", systemImage: \"square.and.arrow.down\")"))
        #expect(sheet.contains(".sheet(isPresented: $showVideoImport)"))
        #expect(sheet.contains("VideoImportSheet(library: library, queue: viewModel, isPresented: $showVideoImport)"))
        #expect(sheet.contains(".disabled(cameraViewModel.isRecording"))
    }

    @Test func processingSheetUsesConsistentCopy() throws {
        let sheet = try source("App/Modules/VideoImport/VideoImportSheet.swift")
        #expect(sheet.contains(".navigationTitle(\"Process Video\")"))
        #expect(sheet.contains("\"Preparing video…\""))
        #expect(!sheet.contains("\"Cancel import\""))
        #expect(!sheet.contains("Could not import"))
        #expect(!sheet.contains("could not be imported"))
    }

    @Test func cameraHasADirectDevelopModeWithoutOpeningTheQueue() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("CameraModeCarousel(selected: cameraMode.selected"))
        #expect(screen.contains("DevelopPreview(model: developModel, queue: renderQueueViewModel)"))
        #expect(!screen.contains(".sheet(isPresented: developPresented"))
        #expect(screen.contains("developModel.leaveDevelop()"))
        #expect(screen.contains("isDevelopMode: isDevelopMode"))
        #expect(screen.contains("selectionOnly: isDevelopMode"))
        #expect(screen.contains(".allowsHitTesting(!isDevelopMode)"))
        #expect(screen.contains("guard canChangeCameraMode else { return }"))
        #expect(screen.contains("CameraModeStripGeometry.frame"))
    }

    @Test func importedVideosCannotReachTheLegacyPlayer() throws {
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        #expect(sheet.contains("if job.isImportedVideo != true, let url = job.retainedOutputURL"))
        #expect(sheet.contains("guard job.isImportedVideo != true, job.retainedOutputURL != nil else { return }"))
    }
}
