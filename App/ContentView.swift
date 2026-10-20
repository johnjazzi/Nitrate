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
    @State private var showDaylightRescue = false
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var pinchBaseZoom: Double = 1.0
    @State private var pinchIsActive = false

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
                                           rotationDegrees: statusRotationDegrees,
                                           isInteractive: canManageDaylightMode) {
                        recordingStatus
                    }
                }

                // A canvas sibling, not a child painted beyond the shooting bar:
                // visibility never resizes the preview and the whole button is hittable.
                if shouldOfferDaylightRescue, let exposure = controlBounds["exposure"],
                   let rect = DaylightExposureRescueGeometry.buttonRect(
                    above: exposure, in: geometry.size, rotationDegrees: statusRotationDegrees) {
                    ExposureRescueButton(armed: cameraViewModel.sessionFrameRate == .daylight60,
                                         enabled: cameraViewModel.canChangeSessionFrameRate,
                                         action: { showDaylightRescue = true })
                        .frame(width: 92, height: 44)
                        .rotationEffect(.degrees(statusRotationDegrees))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
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

                errorOverlays
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "cameraCanvas")
            .onPreferenceChange(CameraControlBoundsPreference.self) { controlBounds = $0 }
        }
        .sheet(isPresented: $showDaylightRescue) {
            DaylightExposureRescueModal(
                armed: cameraViewModel.sessionFrameRate == .daylight60,
                available: cameraViewModel.supportsDaylight60,
                canChange: cameraViewModel.canChangeSessionFrameRate,
                onSelect: { enabled in
                    cameraViewModel.setDaylight60Enabled(enabled)
                    showDaylightRescue = false
                },
                onCancel: { showDaylightRescue = false }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
                awaitingStockJobId = renderQueueViewModel.enqueueAwaitingStock(
                    sourceURL: url, capturePolicy: cameraViewModel.capturePolicy(for: url))
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
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { showDaylightRescue = false }
        }
        .onChange(of: showSettings || showQueueSheet || showStockSheet || showDaylightRescue) { _, shown in
            if shown { cameraViewModel.endSlowZoom() }
        }
        .onChange(of: cameraViewModel.zoomSnapshot?.cameraRevision) { _, _ in
            pinchIsActive = false
            pinchBaseZoom = cameraViewModel.zoomSnapshot?.displayFactor ?? 1
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
            gauge: library.lastGauge(for: stock.stockId),
            capturePolicy: cameraViewModel.capturePolicy(for: sourceURL)
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
                   videoGravity: showFramedPreview ? .resizeAspect : .resizeAspectFill,
                   selectedStockLUTName: selectedStock?.lutName)
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: showFramedPreview ? 16 : 0))
            .overlay {
                if showFramedPreview {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 2)
                }
            }
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        guard let snapshot = cameraViewModel.zoomSnapshot else { return }
                        if !pinchIsActive {
                            pinchBaseZoom = snapshot.displayFactor
                            pinchIsActive = true
                        }
                        // Damped (0.45) so a small pinch doesn't jump the zoom.
                        let damped = 1.0 + (value - 1.0) * 0.45
                        cameraViewModel.setDisplayZoom(pinchBaseZoom * damped)
                    }
                    .onEnded { _ in
                        pinchIsActive = false
                        pinchBaseZoom = cameraViewModel.zoomSnapshot?.displayFactor ?? pinchBaseZoom
                    }
            )
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
            lensMenu
        } status: {
            recordingStatus
        } diagnostics: {
            VStack(spacing: 4) { diagnosticButtons }
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
        .buttonStyle(CameraRaisedButtonStyle())
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
        .buttonStyle(CameraRaisedButtonStyle(faceColor: showManualControls ? .yellow : Color(red: 0.16, green: 0.17, blue: 0.19)))

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
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .fixedSize()
                    .cameraUpright(in: CGSize(width: 43, height: 27))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.yellow)
                    .clipShape(Capsule())
            }
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
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .cameraUpright(in: CGSize(width: 43, height: 27))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.red)
                    .clipShape(Capsule())
            }
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

    @ViewBuilder private var recordingStatus: some View {
        if let origin = cameraViewModel.recordingTimerOrigin {
            if let stoppedAt = cameraViewModel.recordingStoppedAt {
                statusFace(text: RecordingDurationText.format(seconds: stoppedAt.timeIntervalSince(origin)))
            } else {
                TimelineView(.animation) { context in
                    statusFace(text: RecordingDurationText.format(seconds: context.date.timeIntervalSince(origin)))
                }
            }
        } else {
            statusFace(text: recordPresentation == .idle ? "--:--.--" : "00:00.00")
        }
    }

    private var statusRotationDegrees: Double {
        CameraGlyphRotation.degrees(for: orientation.deviceOrientation)
    }

    /// Same target as the live EV indicator: manual ISO targets zero; automatic
    /// ISO compares against the user's selected EV bias, not an absolute +2 EV.
    private var shouldOfferDaylightRescue: Bool {
        DaylightExposureRescuePolicy.shouldOffer(
            meteredEV: cameraViewModel.liveExposureTargetOffset,
            targetEV: cameraViewModel.isManualExposure ? 0 : cameraViewModel.liveExposureBias,
            isAvailable: cameraViewModel.hasExposureMeter)
    }

    private var canManageDaylightMode: Bool {
        cameraViewModel.sessionFrameRate == .daylight60 && cameraViewModel.canChangeSessionFrameRate
    }

    private func statusFace(text: String) -> some View {
        RecordingStatusFace(presentation: recordPresentation, text: text,
                            style: RecordingIndicatorStyle.resolved(recordingIndicatorStyle),
                            rotationDegrees: CameraGlyphRotation.degrees(for: orientation.deviceOrientation),
                            daylight60Active: cameraViewModel.sessionFrameRate == .daylight60,
                            onManageDaylight: canManageDaylightMode ? { showDaylightRescue = true } : nil)
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
            capturePolicy: currentSourceURL.flatMap { cameraViewModel.capturePolicy(for: $0) },
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

// MARK: - Stock Sheet

private struct StockSheetView: View {
    let library: FilmStockLibrary
    let renderQueueViewModel: RenderQueueViewModel
    var sourceURL: URL?
    /// When set, rendering assigns the stock to this durable awaiting entry
    /// instead of creating a second job for the same take.
    var awaitingStockJobId: UUID?
    /// The policy snapshotted for this take, read from the view model — never
    /// from the live mode, which may already have reset for the next session.
    var capturePolicy: RenderCapturePolicy?
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
                    gauge: gauge,
                    capturePolicy: capturePolicy
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
