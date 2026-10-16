import SwiftUI

@main
struct NitrateApp: App {
    @State private var cameraViewModel: CameraViewModel
    @State private var renderQueueViewModel: RenderQueueViewModel
    @State private var purchaseViewModel: PurchaseViewModel
    @State private var library: FilmStockLibrary
    private let stockLibraryError: String?
    @State private var showsStartupSplash = true
    @Environment(\.scenePhase) private var scenePhase

    private var brandingPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--branding-preview")
        #else
        false
        #endif
    }

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
            .preferredColorScheme(.dark)
            .allowsHitTesting(!showsStartupSplash)
            .accessibilityHidden(showsStartupSplash)
            .overlay {
                if showsStartupSplash {
                    StartupSplashView(isPreview: brandingPreview) {
                        showsStartupSplash = false
                    }
                }
            }
            .onAppear {
                cameraViewModel.recordingAccessAllowed = { [purchaseViewModel] in
                    purchaseViewModel.canUsePaidFeatures
                }
                purchaseViewModel.onAppLaunch()
                renderQueueViewModel.library = library
                renderQueueViewModel.externalErrorMessage = stockLibraryError
                renderQueueViewModel.onAppear()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { purchaseViewModel.onSceneActive() }
            }
        }
    }
}
