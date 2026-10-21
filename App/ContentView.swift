import SwiftUI

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
    @AppStorage("showFramedPreview") private var showFramedPreview = false
    @AppStorage(RecordingIndicatorStyle.preferenceKey) private var recordingIndicatorStyle = RecordingIndicatorStyle.red.rawValue
    @State private var controlBounds: [String: CGRect] = [:]
    @State private var currentSourceURL: URL?
    /// The durable awaiting-stock entry created for the current take, if any.
    @State private var awaitingStockJobId: UUID?
    /// Shown briefly when a take never started.
    @State private var showsRecordingFailure = false
    @State private var failureFlashGeneration = 0
    @State private var failureDetail: String?

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
    @State private var selectedLens: CameraLens
    @State private var availableLenses: [CameraLens] = []

    /// Pinch-zoom baseline (ISO/EV controls live in `CameraControlBar`).
    @State private var pinchIsActive = false
    @State private var pinchFocalLength = 24.0

    /// Physical orientation source for the `.cameraUpright()` chrome modifier.
    /// Every icon/text glyph in the camera UI rotates to stay readable in
    /// landscape while its layout position is unchanged.
    @State private var orientation = CameraOrientationObserver.shared

    /// Manual zoom/focus pop-over with a live exposure readout.
    @State private var showManualControls = false
    @AppStorage("camera.manualControlsExpanded") private var manualControlsExpanded = false
    @State private var manualFocusPosition: Double = 0.5
    @State private var isManualFocus = false
    @State private var focusReadGeneration: UInt64 = 0

#if DEBUG
    /// Frozen frame + live tuning sheet (DEBUG builds only).
    @State private var debugFrameViewModel: DebugFrameViewModel?
    /// Whether the debug affordances are on the screen. Mirrored in the debug
    /// sheet and in Settings, so hiding the DEBUG button cannot strand the menu
    /// that turns it back on.
    @AppStorage(DebugControlPreferences.showsDebugButtonKey) private var showsDebugButton = true
    @AppStorage(DebugControlPreferences.showsFaultButtonKey) private var showsFaultButton = true
#endif

    var body: some View {
        #if DEBUG
        debugEnabledBody
            .environment(\.cameraDeviceOrientation, orientation.deviceOrientation)
        #else
        shippingBody
            .environment(\.cameraDeviceOrientation, orientation.deviceOrientation)
        #endif
    }

    /// The shipping camera screen. Kept as its own property so the DEBUG build
    /// can wrap it with the debug single-frame sheet without duplicating it.
    private var shippingBody: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                cameraLayer(in: previewRect(in: geometry))

                VStack(spacing: 0) {
                    topBar
                        .background(controlMeasurement("top"))

                    Spacer()

                    controlBar
                        .padding(.bottom, 8)
                        .background(controlMeasurement("bottom"))
                }

                if let top = controlBounds["top"], let bottom = controlBounds["bottom"] {
                    RecordingStatusOverlay(viewport: geometry.size, toolbarBottom: top.maxY, controlsTop: bottom.minY,
                                           rotationDegrees: statusRotationDegrees) {
                        recordingStatus
                    }
                }

                if showManualControls, let top = controlBounds["top"], let bottom = controlBounds["bottom"] {
                    ManualControlsOverlay(viewport: geometry.size, toolbarBottom: top.maxY, controlsTop: bottom.minY,
                                          excluding: RecordingStatusOverlayGeometry.rect(
                                            viewport: geometry.size, toolbarBottom: top.maxY, controlsTop: bottom.minY,
                                            rotationDegrees: statusRotationDegrees),
                                          expanded: manualControlsExpanded,
                                          rotationDegrees: statusRotationDegrees) {
                        ManualControlsPanel(
                            cameraViewModel: cameraViewModel,
                            manualFocusPosition: $manualFocusPosition,
                            isManualFocus: $isManualFocus,
                            expanded: $manualControlsExpanded,
                            landscape: abs(statusRotationDegrees) == 90,
                            onDismiss: {
                                cameraViewModel.endSlowZoom()
                                withAnimation(.easeInOut(duration: 0.2)) { showManualControls = false }
                            }
                        )
                    }
                    .transition(.opacity)
                }

                if pinchIsActive, let bottom = controlBounds["bottom"] {
                    FocalLengthRuler(millimeters: pinchFocalLength)
                        .frame(width: max(0, geometry.size.width - 32))
                        .position(x: geometry.size.width / 2, y: max(34, bottom.minY - 42))
                }

                if !showFramedPreview, let top = controlBounds["top"] {
                    RecordingTallyLight(isRecording: recordPresentation == .recording)
                        .position(x: geometry.size.width - 24, y: top.maxY + 20)
                }

                debugControlsOverlay(in: geometry)

                errorOverlays
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "cameraCanvas")
            .onPreferenceChange(CameraControlBoundsPreference.self) { controlBounds = $0 }
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
                // Durably queue the take before the sheet is shown, so leaving the
                // sheet (Done/swipe), a second take, or a relaunch cannot strand it.
                awaitingStockJobId = renderQueueViewModel.enqueueAwaitingStock(sourceURL: url)
                showStockSheet = true
            }
        }
        .onChange(of: cameraViewModel.retainedOriginal) { _, newValue in
            // A take that failed validation is never rendered. It is durably
            // queued original-only, and the handoff is only cleared once that
            // entry is recorded — otherwise a failed Photos save or a relaunch
            // would lose the take.
            guard let newValue else { return }
            if renderQueueViewModel.enqueueOriginalOnly(sourceURL: newValue.url, reason: newValue.reason) {
                cameraViewModel.clearRetainedOriginal()
            }
        }
        .onChange(of: cameraViewModel.recordingFailureToken) { _, token in
            guard token > 0 else { return }
            failureDetail = cameraViewModel.recordingFailureDetail
            flashRecordingFailure()
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
        .onChange(of: showManualControls) { _, shown in
            if !shown { cameraViewModel.endSlowZoom() }
        }
        .onChange(of: showSettings || showQueueSheet || showStockSheet) { _, shown in
            if shown { cameraViewModel.endSlowZoom() }
        }
        .onChange(of: cameraViewModel.activeLens) { _, lens in
            selectedLens = lens
            focusReadGeneration &+= 1
            let focusRequest = focusReadGeneration
            cameraViewModel.session.readManualFocusSnapshot { snapshot in
                guard focusRequest == focusReadGeneration else { return }
                if !snapshot.isSupported {
                    isManualFocus = false
                } else if isManualFocus, let position = snapshot.lensPosition {
                    manualFocusPosition = Double(position)
                }
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
            debugFrameViewModel = DebugFrameViewModel(frame: buffer, config: stock,
                                                      stocks: library.videoStocks())
        }
    }
#endif

    // MARK: - Helpers

    private func enqueueRender(sourceURL: URL, stock: FilmStockConfig) {
        renderQueueViewModel.enqueue(
            sourceURL: sourceURL,
            stockId: stock.stockId,
            iso: currentISO,
            gauge: library.lastGauge(for: stock.stockId)
        )
    }

    /// Lock the camera's white balance to the selected stock's color
    /// temperature (daylight 5600K / tungsten 3200K) so the Apple Log → LUT
    /// transform sees a consistent per-stock white point.
    private func applyStockWhiteBalance(_ stock: FilmStockConfig) {
        cameraViewModel.session.setWhiteBalance(temperatureKelvin: stock.colorTemperature)
    }

    // MARK: - Camera Layer

    private func controlMeasurement(_ name: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: CameraControlBoundsPreference.self,
                                   value: [name: geometry.frame(in: .named("cameraCanvas"))])
        }
    }

    private func previewRect(in geometry: GeometryProxy) -> CGRect {
        if showFramedPreview {
            // Keep the camera alive but hidden until both control bounds exist;
            // a persisted framed launch must not flash behind the controls.
            guard let top = controlBounds["top"], let bottom = controlBounds["bottom"] else {
                return .zero
            }
            return FramedPreviewLayout.previewRect(
                in: CGRect(origin: .zero, size: geometry.size),
                topControlsBottom: CameraTopPanelGeometry.framingBottom(toolbarBottom: top.maxY,
                                                                         rotationDegrees: statusRotationDegrees),
                bottomControlsTop: bottom.minY
            )
        }
        // Match the immersive preview's old ignored-safe-area extent without
        // letting an ignoresSafeArea modifier enlarge the framed preview too.
        let insets = geometry.safeAreaInsets
        return CGRect(x: -insets.leading, y: -insets.top,
                      width: geometry.size.width + insets.leading + insets.trailing,
                      height: geometry.size.height + insets.top + insets.bottom)
    }

    private func cameraLayer(in rect: CGRect) -> some View {
        // One structural identity in both modes: no camera lifecycle transition.
        CameraView(viewModel: cameraViewModel,
                   videoGravity: .resizeAspectFill,
                   selectedStockLUTName: selectedStock?.lutName)
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: showFramedPreview ? 16 : 0))
            .overlay {
                if showFramedPreview {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showFramedPreview {
                    RecordingTallyLight(isRecording: recordPresentation == .recording)
                        .padding(12)
                }
            }
            .modifier(FocalPinchZoom(camera: cameraViewModel, isActive: $pinchIsActive, millimeters: $pinchFocalLength))
            .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Top Bar

    /// Active stock lives in the control bar's selector row; the top toolbar
    /// owns app settings, manual controls and the active lens menu.
    private var topBar: some View {
        CameraTopPanel(statusInToolbar: abs(statusRotationDegrees) != 90) {
            settingsButton
        } manual: {
            manualButton
        } lens: {
            // The lens keeps the rightmost first-row slot except while a take is
            // live: the timer then owns that row in portrait — but centered on
            // the toolbar, not right-aligned into the lens slot — and in
            // landscape the slot stays hidden while the timer floats on the
            // physical edge. Either way the toolbar height never changes.
            lensMenu
                .opacity(recordPresentation == .recording ? 0 : 1)
                .allowsHitTesting(recordPresentation != .recording)
                .accessibilityHidden(recordPresentation == .recording)
        } status: {
            recordingStatus
        } diagnostics: {
            // The DEBUG/FAULT rail does not belong to the measured top bar: its
            // height used to reserve toolbar space and shrink the framed preview.
            // It renders in a non-sizing sibling overlay instead (see
            // `debugControlsOverlay`), while this fifth slot stays concrete.
            EmptyView()
        }
    }

    /// DEBUG/FAULT render in a non-sizing sibling overlay on the full camera
    /// canvas, outside the measured top bar. They keep their real round 44pt
    /// buttons and their actions, so they stay tappable, yet they never reserve
    /// a toolbar height or shrink the framed preview. The rail sits at its
    /// historic spot: just below the stationary key row, inset 16pt from the
    /// leading edge of the canvas.
    @ViewBuilder private func debugControlsOverlay(in geometry: GeometryProxy) -> some View {
        if let top = controlBounds["top"] {
            VStack(alignment: .leading, spacing: 4) { diagnosticButtons }
                .padding(.leading, 16)
                .padding(.top, top.maxY)
                .frame(width: geometry.size.width, height: geometry.size.height,
                       alignment: .topLeading)
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .cameraUpright()
                .frame(width: 44, height: 44)
        }
        .buttonStyle(CameraRoundButtonStyle())
    }

    private var manualButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showManualControls.toggle() }
        } label: {
            Image(systemName: "slider.vertical.3")
                .font(.title3)
                .foregroundStyle(showManualControls ? .black : .white)
                .cameraUpright()
                .frame(width: 44, height: 44)
        }
        .buttonStyle(CameraRoundButtonStyle(faceColor: showManualControls ? .yellow : nil))

    }

    @ViewBuilder private var diagnosticButtons: some View {
#if DEBUG
        // Debug single-frame tuning (grain / halation / glow). Debug
        // builds only; opens a sheet over a frozen live frame.
        if showsDebugButton {
            Button {
                openDebugFrame()
            } label: {
                Text("DEBUG")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .fixedSize()
                    .cameraUpright()
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(CameraRoundButtonStyle(faceColor: .yellow))
        }

        // Preview the "recording never started" treatment without provoking a
        // real failure. It lives here rather than inside the debug sheet
        // because the overlay renders on the camera screen, which a presented
        // sheet would cover.
        if showsFaultButton {
            Button {
                failureDetail = "Debug preview — no recording was attempted."
                flashRecordingFailure()
            } label: {
                Text("FAULT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .cameraUpright()
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(CameraRoundButtonStyle(faceColor: .red))
        }
#endif
    }

    private var recordPresentation: RecordButtonPresentation {
        RecordButtonPresentationPolicy.presentation(
            isRecording: cameraViewModel.isRecording,
            isStarting: cameraViewModel.isStartingRecording,
            isStopping: cameraViewModel.isStoppingRecording
        )
    }

    /// The timer and its tally dot exist only for a confirmed take. Idle,
    /// starting and finalizing render nothing at all — no placeholder, no dot.
    @ViewBuilder private var recordingStatus: some View {
        if recordPresentation == .recording {
            if let origin = cameraViewModel.recordingTimerOrigin {
                if let stoppedAt = cameraViewModel.recordingStoppedAt {
                    statusFace(text: RecordingDurationText.format(seconds: stoppedAt.timeIntervalSince(origin)))
                } else {
                    TimelineView(.animation) { context in
                        statusFace(text: RecordingDurationText.format(seconds: context.date.timeIntervalSince(origin)))
                    }
                }
            } else {
                statusFace(text: "00:00.00")
            }
        }
    }

    private var statusRotationDegrees: Double {
        CameraGlyphRotation.degrees(for: orientation.deviceOrientation)
    }

    private func statusFace(text: String) -> some View {
        RecordingStatusFace(presentation: recordPresentation, text: text,
                            style: RecordingIndicatorStyle.resolved(recordingIndicatorStyle),
                            rotationDegrees: CameraGlyphRotation.degrees(for: orientation.deviceOrientation))
    }

    private var lensMenu: some View {
        CameraLensSelector(
            availableLenses: availableLenses,
            selectedLens: selectedLens,
            onSelectLens: selectLens
        )
    }

    private func selectLens(_ lens: CameraLens) {
        guard lens != selectedLens else { return }
        focusReadGeneration &+= 1
        let focusRequest = focusReadGeneration
        cameraViewModel.selectLens(lens) { error in
            // The view model follows committed session changes, including a
            // successful earlier switch followed by a later request failure.
            selectedLens = cameraViewModel.activeLens
            if let error {
                cameraViewModel.errorMessage = "Camera switch failed: \(error.localizedDescription)"
            }
            cameraViewModel.session.readManualFocusSnapshot { snapshot in
                guard focusRequest == focusReadGeneration, !cameraViewModel.isSwitchingCameraLens else { return }
                if !snapshot.isSupported {
                    isManualFocus = false
                } else if isManualFocus, let position = snapshot.lensPosition {
                    manualFocusPosition = Double(position)
                }
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
            selectedStock: selectedStock,
            currentISO: currentISO,
            selectedGauge: selectedStock.flatMap { library.lastGauge(for: $0.stockId) } ?? .neutral,
            onShowQueueSheet: { showQueueSheet = true },
            onShowStockSheet: {
                // Opened directly (not from a fresh take): nothing to resume.
                awaitingStockJobId = nil
                showStockSheet = true
            }
        )
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
            if showsRecordingFailure {
                RecordingFailureOverlay(detail: failureDetail)
                    .transition(.opacity)
            }
        }
    }

    private func cameraErrorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                .cameraUpright()
            Text(message).foregroundStyle(.white).font(.caption)
                .cameraUpright()
            Spacer()
            Button(action: cameraViewModel.dismissError) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
                    .cameraUpright()
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
                .cameraUpright()
            Text(message).foregroundStyle(.white).font(.caption)
                .cameraUpright()
            Spacer()
            Button {
                renderQueueViewModel.dismissRendererError()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
                    .cameraUpright()
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
            awaitingStockJobId: awaitingStockJobId,
            isPresented: $showStockSheet,
            selectedStock: $selectedStock,
            currentISO: $currentISO
        )
    }

    private var queueSheet: some View {
        QueueSheetView(
            viewModel: renderQueueViewModel,
            cameraViewModel: cameraViewModel,
            isPresented: $showQueueSheet
        )
    }

    // MARK: - Helpers

    /// Flash the failure treatment, then take it away: it is an attention grab,
    /// not something the user has to dismiss.
    private func flashRecordingFailure() {
        failureFlashGeneration &+= 1
        let generation = failureFlashGeneration
        withAnimation(.easeIn(duration: 0.08)) { showsRecordingFailure = true }
        Task { @MainActor in
            // Hold for the whole animation: cutting it short mid-cycle is what made
            // the first version look like a fast strobe.
            try? await Task.sleep(for: .seconds(RecordingFailureOverlay.flashDuration + 0.4))
            guard generation == failureFlashGeneration else { return }
            withAnimation(.easeOut(duration: 0.25)) { showsRecordingFailure = false }
        }
    }
}

private struct CameraControlBoundsPreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - Stock Sheet

private struct StockSheetView: View {
    let library: FilmStockLibrary
    let renderQueueViewModel: RenderQueueViewModel
    var sourceURL: URL?
    /// When set, rendering assigns the stock to this durable awaiting entry
    /// instead of creating a second job for the same take.
    var awaitingStockJobId: UUID?
    @Binding var isPresented: Bool
    @Binding var selectedStock: FilmStockConfig?
    @Binding var currentISO: Float

    @State private var stocks: [FilmStockConfig] = []
    @State private var localSelection: FilmStockConfig?
    @State private var gauge: PrintGauge = .thirtyFiveMillimetre

    var body: some View {
        NavigationStack {
            // The example preview is tall, so the sheet scrolls vertically:
            // a short phone at 320pt can still reach the gauge and Render.
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(spacing: 20) {
                        StockSamplePreview(stock: localSelection ?? stocks.first, gauge: gauge)
                            .frame(maxWidth: .infinity)

                        if !stocks.isEmpty { stockCarousel }

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
                }
            }
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
            .onChange(of: gauge) { _, _ in persistPreferences() }
        }
    }

    private var stockCarousel: some View {
        StockCarousel(stocks: stocks, selectedStockId: selectedStockIdBinding)
    }

    /// The carousel and the sheet share one selection: the carousel writes the
    /// id of the stock it centred through the binding, and the sheet resolves it
    /// back to a config (ISO + remembered gauge).
    private var selectedStockIdBinding: Binding<String?> {
        Binding(
            get: { localSelection?.stockId },
            set: { newValue in
                guard let newValue, let stock = stocks.first(where: { $0.stockId == newValue }) else { return }
                select(stock)
            }
        )
    }

    /// Adopt a stock as the local selection. ISO follows the stock; the remembered
    /// gauge is only restored when the selection actually changes, so re-tapping
    /// the centred stock never resets a gauge the user dialled in.
    private func select(_ stock: FilmStockConfig) {
        let previous = localSelection
        localSelection = stock
        currentISO = stock.defaultISO
        if let restored = StockCarouselSelection.gauge(
            onSelecting: stock.stockId,
            from: previous?.stockId,
            remembered: library.lastGauge(for: stock.stockId)
        ) {
            gauge = restored
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
                renderQueueViewModel.reportRenderError("Select a film stock first.")
                return
            }
            if let jobId = awaitingStockJobId {
                // Resume the durable entry created for this take.
                renderQueueViewModel.assignStock(
                    jobId: jobId,
                    stockId: stock.stockId,
                    iso: stock.defaultISO,
                    gauge: gauge
                )
            } else {
                renderQueueViewModel.enqueue(
                    sourceURL: sourceURL,
                    stockId: stock.stockId,
                    iso: stock.defaultISO,
                    gauge: gauge
                )
            }
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
