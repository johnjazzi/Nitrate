import SwiftUI

@main
struct FilmEmulationApp: App {
    @State private var cameraViewModel = CameraViewModel()
    @State private var renderQueueViewModel = RenderQueueViewModel()
    @State private var purchaseViewModel = PurchaseViewModel()
    @State private var library = FilmStockLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView(
                cameraViewModel: cameraViewModel,
                library: library,
                renderQueueViewModel: renderQueueViewModel,
                purchaseViewModel: purchaseViewModel
            )
            .onAppear {
                do {
                    try library.load()
                } catch {
                    renderQueueViewModel.rendererErrorMessage = "Stock library failed: \(error.localizedDescription)"
                }
                renderQueueViewModel.library = library
                renderQueueViewModel.onAppear()
            }
        }
    }
}