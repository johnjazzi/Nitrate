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

    /// Camera controls state
    @State private var zoomFactor: Double = 1.0
    @State private var selectedLens: CameraLens = .wide
    @State private var availableLenses: [CameraLens] = []

    /// Focus/zoom control panel — one toggle, vertical, right edge.
    @State private var showFocusControls = false
    @State private var manualFocusPosition: Double = 0.5
    @State private var isManualFocus = false
    @State private var pinchBaseZoom: Double = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            cameraLayer

            VStack(spacing: 0) {
                topBar
                    .padding(.bottom, showFramedPreview ? 8 : 0)

                Spacer()

                bottomBar
                    .padding(.top, showFramedPreview ? 8 : 0)
                    .padding(.bottom, 40)
            }

            focusZoomControlsLayer

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

            // Restore persisted stock selection
            if let lastId = library.lastSelectedStockId,
               let stock = library.videoStocks().first(where: { $0.stockId == lastId }) {
                selectedStock = stock
                currentISO = library.lastISO(for: stock.stockId)
                applyStockWhiteBalance(stock)
            }
        }
        .onChange(of: selectedStock) { _, newStock in
            if let stock = newStock {
                applyStockWhiteBalance(stock)
            }
        }
    }

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
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        // Damped (0.45) so a small pinch doesn't jump the zoom.
                        let damped = 1.0 + (value - 1.0) * 0.45
                        let target = min(max(pinchBaseZoom * damped, 1.0),
                                          Double(cameraViewModel.session.maxZoomFactor))
                        zoomFactor = target
                        Task { try? cameraViewModel.session.setZoom(CGFloat(target)) }
                    }
                    .onEnded { _ in pinchBaseZoom = zoomFactor }
            )
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            let normalizedPoint = CGPoint(
                                x: location.x / geometry.size.width,
                                y: location.y / geometry.size.height
                            )
                            // Tap-to-focus also returns to autofocus.
                            isManualFocus = false
                            Task {
                                try? cameraViewModel.session.setFocusPoint(normalizedPoint)
                                try? cameraViewModel.session.setExposurePoint(normalizedPoint)
                            }
                        }
                }
            }
    }

    // MARK: - Top Bar

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
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }

                // Import from Photos
                PhotosPicker(selection: $selectedPhotoItem, matching: .videos) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
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

                // Camera lens selector (front/ultrawide/tele/normal)
                Menu {
                    ForEach(availableLenses) { lens in
                        Button {
                            selectLens(lens)
                        } label: {
                            if lens == selectedLens {
                                Label(lens.rawValue, systemImage: "checkmark")
                            } else {
                                Text(lens.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selectedLens.systemImage)
                            .font(.caption)
                        Text(selectedLens.rawValue)
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.4))
                    .clipShape(Capsule())
                }

                // Focus + zoom controls toggle (vertical panel, right edge)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showFocusControls.toggle() }
                } label: {
                    Image(systemName: showFocusControls ? "slider.vertical.3" : "camera.filters")
                        .font(.caption)
                        .foregroundStyle(showFocusControls ? .black : .white)
                        .padding(10)
                        .background(showFocusControls ? Color.yellow : Color.black.opacity(0.4))
                        .clipShape(Circle())
                }

                Spacer()
            }

            HStack {
                Spacer()

                // Live exposure readout; ISO controls live in the focus/zoom panel.
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

    /// Vertical focus + zoom + ISO controls on the right edge (one toggle shows/hides).
    private var focusZoomControlsLayer: some View {
        HStack {
            Spacer()
            if showFocusControls {
                HStack(alignment: .top, spacing: 14) {
                    // ZOOM
                    controlColumn(title: "ZOOM", readout: String(format: "%.1fx", zoomFactor)) {
                        verticalSlider(
                            $zoomFactor,
                            range: 1.0...Double(max(cameraViewModel.session.maxZoomFactor, 1.0)),
                            step: 0.1,
                            tint: .white
                        ) { value in
                            Task { try? cameraViewModel.session.setZoom(CGFloat(value)) }
                        }
                    }

                    // FOCUS
                    controlColumn(title: "FOCUS", readout: isManualFocus ? "MF" : "AF") {
                        verticalSlider(
                            $manualFocusPosition,
                            range: 0...1,
                            step: 0.01,
                            tint: isManualFocus ? .yellow : .white.opacity(0.45)
                        ) { value in
                            guard isManualFocus else { return }
                            Task { try? cameraViewModel.session.setManualFocusPosition(Float(value)) }
                        }
                        .disabled(!isManualFocus)
                        .opacity(isManualFocus ? 1 : 0.4)

                        Button {
                            toggleManualFocus()
                        } label: {
                            Text(isManualFocus ? "AF" : "MF")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(isManualFocus ? .black : .white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isManualFocus ? Color.yellow : Color.white.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }

                    // ISO
                    controlColumn(title: "ISO", readout: "\(Int(cameraViewModel.liveISO))") {
                        verticalSlider(
                            isoBinding,
                            range: isoSliderRange,
                            step: 50,
                            tint: cameraViewModel.isManualExposure ? .yellow : .white.opacity(0.45)
                        ) { value in
                            cameraViewModel.setManualISO(Float(value))
                        }
                        .disabled(!cameraViewModel.isManualExposure)
                        .opacity(cameraViewModel.isManualExposure ? 1 : 0.4)

                        Button {
                            cameraViewModel.toggleManualExposure()
                        } label: {
                            Text(cameraViewModel.isManualExposure ? "Auto" : "Manual")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(cameraViewModel.isManualExposure ? .black : .white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(cameraViewModel.isManualExposure ? Color.yellow : Color.white.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
                .background(.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.trailing, 12)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    /// One labelled column of the vertical control panel.
    private func controlColumn<Content: View>(
        title: String,
        readout: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.7))
            content()
            Text(readout)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    /// A rotated (vertical) slider that reports changes through `action`.
    private func verticalSlider(
        _ value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        tint: Color,
        action: @escaping (Double) -> Void
    ) -> some View {
        Slider(value: value, in: range, step: step)
            .tint(tint)
            .frame(width: 140, height: 26)
            .rotationEffect(.degrees(-90))
            .frame(width: 26, height: 140)
            .onChange(of: value.wrappedValue) { _, newValue in action(newValue) }
    }

    /// Device ISO range as a Double slider range.
    private var isoSliderRange: ClosedRange<Double> {
        let range = cameraViewModel.session.isoRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    /// Binding for the manual-ISO slider.
    private var isoBinding: Binding<Double> {
        Binding(
            get: { Double(cameraViewModel.manualISO) },
            set: { cameraViewModel.setManualISO(Float($0)) }
        )
    }

    private func toggleManualFocus() {
        isManualFocus.toggle()
        Task {
            if isManualFocus {
                try? cameraViewModel.session.setManualFocusPosition(Float(manualFocusPosition))
            } else {
                try? cameraViewModel.session.resetAutoFocus()
            }
        }
    }

    private var shutterText: String {
        let seconds = cameraViewModel.liveShutterSeconds
        guard seconds > 0 else { return "1/48" }
        return "1/\(Int((1.0 / seconds).rounded()))"
    }

    private func selectLens(_ lens: CameraLens) {
        guard lens != selectedLens else { return }
        cameraViewModel.selectLens(lens) { error in
            if let error {
                cameraViewModel.errorMessage = "Camera switch failed: \(error.localizedDescription)"
            } else {
                selectedLens = lens
                zoomFactor = 1.0
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            // Left: Stock chip or stock button — fixed width for centering
            Group {
                if let stock = selectedStock {
                    stockChip(stock)
                } else {
                    bottomButton(icon: "film", label: "Stock") { showStockSheet = true }
                }
            }
            .frame(width: 90)

            recordButton.frame(maxWidth: .infinity)

            // Right: Queue button — fixed width to match left
            queueButton
                .frame(width: 90)
        }
        .frame(height: 90)
    }

    // MARK: - Stock Chip

    /// Duotone stripe card with ISO + D/T badge overlaid in black.
    /// 5 horizontal slices: 1,2,5 = primary color; 3,4 = secondary.
    private func stockChip(_ stock: FilmStockConfig) -> some View {
        Button {
            showStockSheet = true
        } label: {
            ZStack {
                // Duotone stripe card
                VStack(spacing: 0) {
                    ForEach(0..<5) { idx in
                        let isPrimary = idx == 0 || idx == 1 || idx == 4
                        (isPrimary ? stock.primaryColor : stock.secondaryColor)
                            .frame(height: 6)
                    }
                }
                .frame(width: 56, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // ISO + D/T overlay
                Text("\(Int(currentISO))\(stock.lightType)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    // MARK: - Queue Button

    private var queueButton: some View {
        VStack(spacing: 2) {
            RenderStatusButton(viewModel: renderQueueViewModel) { showQueueSheet = true }
            freeSpaceBar.frame(width: 48, height: 3)
        }
        .frame(maxWidth: .infinity)
    }

    private func bottomButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title2)
                Text(label).font(.caption2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
    }

    private var recordButton: some View {
        Button {
            if cameraViewModel.isRecording {
                cameraViewModel.stopRecording()
            } else {
                cameraViewModel.startRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(cameraViewModel.isRecording ? .red : .white)
                    .frame(width: 72, height: 72)
                if cameraViewModel.isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white)
                        .frame(width: 24, height: 24)
                } else {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 82, height: 82)
                }
            }
        }
        .disabled(cameraViewModel.isSpaceCritical && !cameraViewModel.isRecording)
        .overlay(alignment: .top) {
            if cameraViewModel.isRecording {
                Text(formatDuration(cameraViewModel.recordingDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.red.opacity(0.8))
                    .clipShape(Capsule())
                    .offset(y: -18)
            }
        }
    }

    private var freeSpaceBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.15))
                RoundedRectangle(cornerRadius: 1)
                    .fill(cameraViewModel.isSpaceCritical ? Color.red : Color.white.opacity(0.5))
                    .frame(width: max(0, geo.size.width * CGFloat(cameraViewModel.freeSpacePercent)))
            }
        }
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
    @State private var iso: Float = 400

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                stockPicker
                if localSelection != nil { isoSlider }

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
                    iso = localSelection.flatMap { library.lastISO(for: $0.stockId) } ?? 400
                }
            }
            .onDisappear {
                if let stock = localSelection {
                    selectedStock = stock
                    currentISO = iso
                    library.setSelectedStock(stock.stockId)
                    library.setISO(iso, for: stock.stockId)
                }
            }
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
                                iso = library.lastISO(for: stock.stockId)
                            }
                        )
                    }
                }
            }
        }
    }

    private var isoSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ISO: \(Int(iso))").font(.headline)
            Slider(value: $iso, in: 100...6400, step: 100)
            HStack {
                Text("100").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("6400").font(.caption).foregroundStyle(.secondary)
            }
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
                iso: iso
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
