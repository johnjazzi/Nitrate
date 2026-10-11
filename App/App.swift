import SwiftUI

@main
struct FilmEmulationApp: App {
    @State private var cameraViewModel: CameraViewModel
    @State private var renderQueueViewModel: RenderQueueViewModel
    @State private var purchaseViewModel: PurchaseViewModel
    @State private var library: FilmStockLibrary
    private let stockLibraryError: String?

    init() {
        let library = FilmStockLibrary()
        var loadError: String?
        do { try library.load() }
        catch { loadError = "Stock library failed: \(error.localizedDescription)" }

        let cameraViewModel = CameraViewModel()
        _library = State(initialValue: library)
        _cameraViewModel = State(initialValue: cameraViewModel)
        _renderQueueViewModel = State(initialValue: RenderQueueViewModel())
        _purchaseViewModel = State(initialValue: PurchaseViewModel())
        stockLibraryError = loadError
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                cameraViewModel: cameraViewModel,
                library: library,
                renderQueueViewModel: renderQueueViewModel,
                purchaseViewModel: purchaseViewModel
            )
            .onAppear {
                renderQueueViewModel.library = library
                renderQueueViewModel.externalErrorMessage = stockLibraryError
                renderQueueViewModel.onAppear()
            }
        }
    }
}
