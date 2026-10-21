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
        CameraHaptics.prepareForCaptureFeedback()
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

        #if DEBUG
        // Development-only halation timing harness; runs only when launched
        // with `-halation-benchmark` and prints to stdout.
        if HalationDeviceBenchmark.isRequested {
            Task.detached { HalationDeviceBenchmark.run() }
        }
        #endif
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
                // Rendering the film look is the paid feature; recording never is.
                renderQueueViewModel.renderAllowed = { [purchaseViewModel] in
                    purchaseViewModel.canRender
                }
                purchaseViewModel.onAppLaunch()
                renderQueueViewModel.library = library
                renderQueueViewModel.externalErrorMessage = stockLibraryError
                renderQueueViewModel.onAppear()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    CameraHaptics.prepareForCaptureFeedback()
                    purchaseViewModel.onSceneActive()
                    renderQueueViewModel.renderAccessDidChange()
                }
            }
        }
    }
}
