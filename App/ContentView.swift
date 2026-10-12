import SwiftUI
import PhotosUI

/// Single camera screen with stock/queue sheets and a settings gear.
/// Toggle "Frame Mode" in Settings to show a viewfinder-style preview.
/// Never destroys the CameraView — orientation and frame mode use the same view.
struct ContentView: View {
    @State var cameraViewModel: CameraViewModel
    let library: FilmStockLibrary
    let renderQueueViewModel: RenderQueueViewModel
    let purchaseViewModel: PurchaseViewModel

    @State private var showStockSheet = false
    @State private var showQueueSheet = false
    @State private var showSettings = false
    @State private var showFramedPreview = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var currentSourceURL: URL?

    /// Persisted stock selection — survives across recordings.
    @State private var selectedStock: FilmStockConfig?
    @State private var currentISO: Float = 400

    init(cameraViewModel: CameraViewModel, library: FilmStockLibrary,
         renderQueueViewModel: RenderQueueViewModel, purchaseViewModel: PurchaseViewModel) {
        self.cameraViewModel = cameraViewModel
        self.library = library
        self.renderQueueViewModel = renderQueueViewModel
        self.purchaseViewModel = purchaseViewModel
        let stock = library.lastSelectedStockId.flatMap { id in
            library.videoStocks().first { $0.stockId == id }
        }
        _selectedStock = State(initialValue: stock)
        _currentISO = State(initialValue: stock?.defaultISO ?? 400)
        _selectedLens = State(initialValue: cameraViewModel.activeLens)
    }

    /// Camera controls state
    @State private var zoomFactor: Double = 1.0
    @State private var selectedLens: CameraLens
    @State private var availableLenses: [CameraLens] = []

    /// Pinch-zoom baseline (ISO/EV controls live in `CameraControlBar`).
    @State private var pinchBaseZoom: Double = 1.0

    /// Manual zoom/focus pop-over. ISO lives in the control bar instead.
    @State private var showManualControls = false
    @State private var manualFocusPosition: Double = 0.5
    @State private var isManualFocus = false

#if DEBUG
    /// Frozen frame + live tuning sheet (DEBUG builds only).
    @State private var debugFrameViewModel: DebugFrameViewModel?
#endif

    var body: some View {
        #if DEBUG
        debugEnabledBody
        #else
        shippingBody
        #endif
    }

    /// The shipping camera screen. Kept as its own property so the DEBUG build
    /// can wrap it with the debug single-frame sheet without duplicating it.
    private var shippingBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            cameraLayer

            VStack(spacing: 0) {
                topBar
                    .padding(.bottom, showFramedPreview ? 8 : 0)

                if showManualControls {
                    ManualControlsPanel(
                        cameraViewModel: cameraViewModel,
                        zoomFactor: $zoomFactor,
                        manualFocusPosition: $manualFocusPosition,
                        isManualFocus: $isManualFocus,
                        onDismiss: { withAnimation(.easeInOut(duration: 0.2)) { showManualControls = false } }
                    )
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.5 }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                exposureIndicator

                controlBar
                    .padding(.top, showFramedPreview ? 8 : 0)
                    .padding(.bottom, 20)
            }

            errorOverlays
        }
        .sheet(isPresented: $showStockSheet) { stockSheet }
        .sheet(isPresented: $showQueueSheet) { queueSheet }
        .sheet(isPresented: $showSettings) {
            PurchaseView(viewModel: purchaseViewModel, showFramedPreview: $showFramedPreview)
        }
        .onChange(of: cameraViewModel.lastRecordedURL) { _, newURL in
            guard let url = newURL else { return }
            currentSourceURL = url

            // Auto-render: skip stock sheet if already selected
            if let stock = selectedStock {
                enqueueRender(sourceURL: url, stock: stock)
            } else {
                showStockSheet = true
            }
        }
        .onAppear {
            availableLenses = cameraViewModel.session.availableLenses
            if !availableLenses.contains(selectedLens) {
                selectedLens = availableLenses.first ?? .wide
            }
            if let selectedStock { applyStockWhiteBalance(selectedStock) }
        }
        .onChange(of: selectedStock) { _, newStock in
            if let stock = newStock {
                applyStockWhiteBalance(stock)
            }
        }
    }

#if DEBUG
    /// Shipping screen plus the debug single-frame sheet, presented only when the
    /// DEBUG button captures a frame.
    private var debugEnabledBody: some View {
        shippingBody.sheet(item: $debugFrameViewModel) { viewModel in
            DebugFrameSheet(viewModel: viewModel)
        }
    }

    /// Capture one frame from the live camera and open the debug sheet on it.
    private func openDebugFrame() {
        guard let stock = selectedStock else {
            cameraViewModel.errorMessage = "Select a film stock before opening the debug frame."
            return
        }
        cameraViewModel.captureDebugFrame { buffer in
            guard let buffer else {
                cameraViewModel.errorMessage = "Debug frame capture failed — is the camera running?"
                return
            }
            debugFrameViewModel = DebugFrameViewModel(frame: buffer, config: stock)
        }
    }
#endif

    // MARK: - Helpers

    private func enqueueRender(sourceURL: URL, stock: FilmStockConfig) {
        renderQueueViewModel.enqueue(
            sourceURL: sourceURL,
            stockId: stock.stockId,
            iso: currentISO
        )
    }

    /// Lock the camera's white balance to the selected stock's color
    /// temperature (daylight 5600K / tungsten 3200K) so the Apple Log → LUT
    /// transform sees a consistent per-stock white point.
    private func applyStockWhiteBalance(_ stock: FilmStockConfig) {
        cameraViewModel.session.setWhiteBalance(temperatureKelvin: stock.colorTemperature)
    }

    // MARK: - Camera Layer

    private var cameraLayer: some View {
        CameraView(viewModel: cameraViewModel)
            .ignoresSafeArea()
            .clipShape(RoundedRectangle(cornerRadius: showFramedPreview ? 16 : 0))
            .padding(.horizontal, showFramedPreview ? 8 : 0)
            .overlay {
                if showFramedPreview {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.25), lineWidth: 2)
                        .padding(.horizontal, 8)
                }
            }
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        // Damped (0.45) so a small pinch doesn't jump the zoom.
                        let damped = 1.0 + (value - 1.0) * 0.45
                        let target = min(max(pinchBaseZoom * damped, 1.0),
                                          Double(cameraViewModel.session.maxZoomFactor))
                        zoomFactor = target
                        cameraViewModel.session.setZoom(CGFloat(target))
                    }
                    .onEnded { _ in pinchBaseZoom = zoomFactor }
            )
    }

    // MARK: - Top Bar

    /// Active stock lives in the control bar's selector row; the top toolbar
    /// owns app settings, imports and the live exposure readout.
    private var topBar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 12) {
                // Settings
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                }
                .buttonStyle(CameraRaisedButtonStyle())

                // Import from Photos
                PhotosPicker(selection: $selectedPhotoItem, matching: .videos) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                }
                .buttonStyle(CameraRaisedButtonStyle())
                .onChange(of: selectedPhotoItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let importURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("imported_\(UUID().uuidString).mov") {
                            try data.write(to: importURL)
                            currentSourceURL = importURL
                            if let stock = selectedStock {
                                enqueueRender(sourceURL: importURL, stock: stock)
                            } else {
                                showStockSheet = true
                            }
                        }
                        selectedPhotoItem = nil
                    }
                }

                // Manual zoom/focus pop-over over the preview.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showManualControls.toggle() }
                } label: {
                    Image(systemName: "slider.vertical.3")
                        .font(.title2)
                        .foregroundStyle(showManualControls ? .black : .white)
                        .padding(12)
                }
                .buttonStyle(CameraRaisedButtonStyle(faceColor: showManualControls ? .yellow : Color(red: 0.16, green: 0.17, blue: 0.19)))

#if DEBUG
                // Debug single-frame tuning (grain / halation / glow). Debug
                // builds only; opens a sheet over a frozen live frame.
                Button {
                    openDebugFrame()
                } label: {
                    Text("DEBUG")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.yellow)
                        .clipShape(Capsule())
                }
#endif

                Spacer()
            }

            HStack {
                Spacer()

                // Live exposure readout; ISO/EV controls live in the selector row.
                Text("ISO \(Int(cameraViewModel.liveISO)) · \(shutterText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.4))
                    .clipShape(Capsule())
                    .padding(.trailing, 16)
            }
        }
        .padding(.leading, 16)
        .padding(.top, 8)
    }

    private var shutterText: String {
        let seconds = cameraViewModel.liveShutterSeconds
        guard seconds > 0 else { return "1/48" }
        return "1/\(Int((1.0 / seconds).rounded()))"
    }

    private func selectLens(_ lens: CameraLens) {
        guard lens != selectedLens else { return }
        cameraViewModel.selectLens(lens) { error in
            // The view model follows committed session changes, including a
            // successful earlier switch followed by a later request failure.
            selectedLens = cameraViewModel.activeLens
            if let error {
                cameraViewModel.errorMessage = "Camera switch failed: \(error.localizedDescription)"
            } else {
                zoomFactor = 1.0
            }
        }
    }

    // MARK: - Control Bar

    /// Two-row bottom stack (selector row + action row). Lives in its own file
    /// (`CameraControlBar.swift`) so this screen stays inside the file limit.
    private var controlBar: some View {
        CameraControlBar(
            cameraViewModel: cameraViewModel,
            renderQueueViewModel: renderQueueViewModel,
            availableLenses: availableLenses,
            selectedLens: selectedLens,
            selectedStock: selectedStock,
            currentISO: currentISO,
            onSelectLens: { selectLens($0) },
            onShowQueueSheet: { showQueueSheet = true },
            onShowStockSheet: { showStockSheet = true },
            formatDuration: { formatDuration($0) }
        )
    }

    // MARK: - Exposure Indicator

    /// Under/over exposure indicator: the live metered EV against the target,
    /// about two thirds of the screen width, sitting just above the control
    /// rows. In manual ISO the target is 0 EV (the user dials ISO, not bias).
    private var exposureIndicator: some View {
        ExposureIndicatorView(
            meteredEV: cameraViewModel.liveExposureTargetOffset,
            targetEV: cameraViewModel.isManualExposure ? 0 : cameraViewModel.liveExposureBias,
            isManual: cameraViewModel.isManualExposure,
            isAvailable: cameraViewModel.hasExposureMeter
        )
        .containerRelativeFrame(.horizontal) { width, _ in width * 0.66 }
        .padding(.bottom, 10)
    }

    // MARK: - Error Overlays

    private var errorOverlays: some View {
        Group {
            if let error = cameraViewModel.errorMessage {
                VStack {
                    cameraErrorBanner(error)
                    Spacer()
                }
            }
            if let renderError = renderQueueViewModel.rendererErrorMessage {
                VStack {
                    Spacer()
                    renderErrorBanner(renderError)
                        .padding(.bottom, 140)
                }
            }
        }
    }

    private func cameraErrorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).foregroundStyle(.white).font(.caption)
            Spacer()
            Button(action: cameraViewModel.dismissError) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(12)
        .background(.black.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func renderErrorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).foregroundStyle(.white).font(.caption)
            Spacer()
            Button {
                renderQueueViewModel.rendererErrorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(12)
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    // MARK: - Sheets

    private var stockSheet: some View {
        StockSheetView(
            library: library,
            renderQueueViewModel: renderQueueViewModel,
            sourceURL: currentSourceURL,
            isPresented: $showStockSheet,
            selectedStock: $selectedStock,
            currentISO: $currentISO
        )
    }

    private var queueSheet: some View {
        QueueSheetView(
            viewModel: renderQueueViewModel,
            isPresented: $showQueueSheet
        )
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%d:%02d", min, sec)
    }
}

// MARK: - Stock Sheet

private struct StockSheetView: View {
    let library: FilmStockLibrary
    let renderQueueViewModel: RenderQueueViewModel
    var sourceURL: URL?
    @Binding var isPresented: Bool
    @Binding var selectedStock: FilmStockConfig?
    @Binding var currentISO: Float

    @State private var stocks: [FilmStockConfig] = []
    @State private var localSelection: FilmStockConfig?
    @State private var gauge: PrintGauge = .thirtyFiveMillimetre

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                stockPicker
                if localSelection != nil { gaugePicker }

                if let url = sourceURL {
                    renderButton(sourceURL: url)
                } else {
                    Text("Record a video to render.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Film Stock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
            .onAppear {
                stocks = library.videoStocks()
                if localSelection == nil {
                    localSelection = selectedStock ?? stocks.first
                    gauge = localSelection.flatMap { library.lastGauge(for: $0.stockId) } ?? .thirtyFiveMillimetre
                }
                currentISO = localSelection?.defaultISO ?? 400
                persistPreferences()
            }
            .onDisappear {
                if let stock = localSelection {
                    selectedStock = stock
                    currentISO = stock.defaultISO
                    library.setSelectedStock(stock.stockId)
                    library.setGauge(gauge, for: stock.stockId)
                }
            }
            .onChange(of: localSelection) { _, _ in persistPreferences() }
        }
    }

    private var stockPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Stock").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(stocks, id: \.stockId) { stock in
                        DuotoneStockCard(
                            stock: stock,
                            isSelected: localSelection?.stockId == stock.stockId,
                            action: {
                                localSelection = stock
                                currentISO = stock.defaultISO
                                gauge = library.lastGauge(for: stock.stockId) ?? .thirtyFiveMillimetre
                            }
                        )
                    }
                }
            }
        }
    }

    private func persistPreferences() {
        guard let stock = localSelection else { return }
        library.setSelectedStock(stock.stockId)
        library.setGauge(gauge, for: stock.stockId)
    }

    private var gaugePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Print Gauge").font(.headline)
            Picker("Print Gauge", selection: $gauge) {
                ForEach(PrintGauge.allCases, id: \.self) { gauge in
                    Text(gauge.displayName).tag(gauge)
                }
            }
            .pickerStyle(.segmented)
            Text("Gauge sets grain size and presence (8mm coarse → 75mm near grain-free).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func renderButton(sourceURL: URL) -> some View {
        Button {
            guard let stock = localSelection else {
                renderQueueViewModel.rendererErrorMessage = "Select a film stock first."
                return
            }
            renderQueueViewModel.enqueue(
                sourceURL: sourceURL,
                stockId: stock.stockId,
                iso: stock.defaultISO,
                gauge: gauge
            )
            isPresented = false
        } label: {
            HStack {
                Image(systemName: "play.rectangle.fill")
                Text("Render with \(localSelection?.displayName ?? "Stock")")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Duotone Stock Card

private struct DuotoneStockCard: View {
    let stock: FilmStockConfig
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Duotone swatch
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        ForEach(0..<5) { index in
                            let isPrimary = index == 0 || index == 1 || index == 4
                            (isPrimary ? stock.primaryColor : stock.secondaryColor)
                                .frame(height: geo.size.height / 5.0)
                        }
                    }
                }
                .frame(width: 48, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? .white : .clear, lineWidth: 2)
                }

                Text(stock.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .lineLimit(1)

                Text(stock.lightType)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(isSelected ? stock.primaryColor : .secondary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(width: 72)
        }
    }
}
