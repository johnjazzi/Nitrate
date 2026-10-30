import SwiftUI

/// Single camera screen with stock/queue sheets and a settings gear.
/// Toggle "Frame Mode" in Settings to show a viewfinder-style preview.
/// Never destroys the CameraView — orientation and frame mode use the same view.
struct ContentView: View {
    @State var cameraViewModel: CameraViewModel
    let library: FilmStockLibrary
    let renderQueueViewModel: RenderQueueViewModel
    let purchaseViewModel: PurchaseViewModel
    /// App-owned, so the launch counter and cue state live once per process.
    let stockSelectorHint: StockSelectorHintModel

    @State private var showStockSheet = false
    @State private var showQueueSheet = false
    @State private var cameraMode = CameraModeSelection()
    /// A mode refusal the row's own gate cannot express (an unavailable shared idle
    /// camera, a failed profile switch). Shown with the row and cleared shortly after.
    @State private var modeRefusalNotice: String?
    @State private var modeRefusalTask: Task<Void, Never>?
    /// Photo is available on the registered production and development
    /// identities in every configuration. The policy reads the bundle identity,
    /// not `#if DEBUG`, so the TestFlight build offers the same mode.
    private var photoModeAvailable: Bool {
        DevelopmentPhotoFeature.isAvailableForCurrentBundle()
    }
    @State private var developModel: DevelopVideoModel
    @State private var showSettings = false
    @State private var showDaylightRescue = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("showFramedPreview") private var showFramedPreview = false
    @AppStorage(RecordingIndicatorStyle.preferenceKey) private var recordingIndicatorStyle = RecordingIndicatorStyle.red.rawValue
    @AppStorage(CameraControlAdjustment.preferenceKey) private var cameraControlAdjustment = CameraControlAdjustment.defaultValue.rawValue
    @State private var controlBounds: [String: CGRect] = [:]
    @State private var currentSourceURL: URL?
    /// The durable awaiting-stock entry created for the current take, if any.
    @State private var awaitingStockJobId: UUID?
    /// Shown briefly when a take never started.
    @State private var showsRecordingFailure = false
    @State private var failureFlashGeneration = 0
    @State private var failureDetail: String?
    /// Latched on the first time the stock selector is shown this launch, so the
    /// discovery cue is skipped for the rest of the launch.
    @State private var stockSelectorOpenedThisLaunch = false

    /// Persisted stock selection — survives across recordings.
    @State private var selectedStock: FilmStockConfig?
    @State private var currentISO: Float = 400

    init(cameraViewModel: CameraViewModel, library: FilmStockLibrary,
         renderQueueViewModel: RenderQueueViewModel, purchaseViewModel: PurchaseViewModel,
         stockSelectorHint: StockSelectorHintModel) {
        self.cameraViewModel = cameraViewModel
        self.library = library
        self.renderQueueViewModel = renderQueueViewModel
        _developModel = State(initialValue: DevelopVideoModel(queue: renderQueueViewModel))
        self.purchaseViewModel = purchaseViewModel
        self.stockSelectorHint = stockSelectorHint
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
    /// Live manual-focus stops surfaced on the in-frame ruler. Session-local:
    /// never persisted across a launch, and owned by the focus gesture code.
    @State private var focusStops: [ManualFocusStop] = []
    /// Session-local Settings switches; both default off and never persist
    /// across a launch. Zoom Controls keeps the focal-length ruler and its
    /// hold arrows on screen; Manual Focus shares `isManualFocus` with the
    /// panel's AF/MF key.
    @State private var zoomControlsEnabled = false
    /// The master switch for the new in-frame manual controls: the toolbar's
    /// manual key toggles every in-frame control (both rails and the inline
    /// button stack) together. Off by default and session-local. Hiding them
    /// stops a live zoom ramp but never resets the hardware manual focus,
    /// aperture or stabilization, nor the session focus stops.
    @State private var showInlineManualControls = false

#if DEBUG
    /// User-owned debug switch that reopens the legacy manual-controls pop-up
    /// panel instead of the in-frame master controls. Mirrored in Settings so
    /// the discovery path is never stranded, and always resolved off in a
    /// Release build.
    @AppStorage(CameraManualControlsFeatureFlags.legacyManualControlsKey)
    private var legacyManualControlsStored = CameraManualControlsFeatureFlags.legacyManualControlsDefault
#endif

#if DEBUG
    /// Frozen frame + live tuning sheet (DEBUG builds only).
    @State private var debugFrameViewModel: DebugFrameViewModel?
    /// Set by the debug sheet's "Preview stock outline" button; the sheet's
    /// onDismiss fires the one-shot outline once the sheet is fully gone, so the
    /// outline is never painted behind the sheet.
    private enum DebugTest { case stockOutline, fault }
    @State private var pendingDebugTest: DebugTest?
    /// Hint decision snapshot frozen when the debug sheet opened, shown there.
    @State private var debugHintDiagnostics: StockSelectorHintDiagnostics?
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
                    .opacity(isDevelopMode ? 0 : 1)
                    .allowsHitTesting(!isDevelopMode)

                if isDevelopMode {
                    let rect = previewRect(in: geometry)
                    DevelopPreview(model: developModel, queue: renderQueueViewModel)
                        .frame(width: rect.width, height: rect.height)
                        .clipShape(RoundedRectangle(cornerRadius: showFramedPreview ? 16 : 0))
                        .position(x: rect.midX, y: rect.midY)
                }

                VStack(spacing: 0) {
                    topBar
                        .disabled(isDevelopMode)
                        .opacity(isDevelopMode ? 0.3 : 1)
                        .background(controlMeasurement("top"))

                    Spacer()

                    controlBar(horizontalInset: controlBarHorizontalInset(in: geometry))
                        .padding(.bottom, 8)
                        .background(controlMeasurement("bottom"))
                }

                if let bottom = controlBounds["bottom"],
                   let slot = CameraModeStripGeometry.frame(
                    controls: bottom, canvasWidth: geometry.size.width,
                    horizontalInset: controlBarHorizontalInset(in: geometry)) {
                    CameraModeCarousel(selected: cameraMode.selected, enabled: canChangeCameraMode,
                                       rotationDegrees: statusRotationDegrees, onSelect: selectCameraMode,
                                       photoAvailable: photoModeAvailable)
                        .frame(width: slot.width, height: slot.height)
                        .position(x: slot.midX, y: slot.midY)
                        // A dimmed row that cannot say why is the bug, not the
                        // refusal: the letters are disabled, so they can never
                        // explain themselves on a tap. The reason is shown while
                        // the row is blocked, and any refusal the row cannot gate
                        // shows itself here for a moment.
                        .overlay(alignment: .top) {
                            if let reason = cameraViewModel.shootingModeBlockedReason ?? modeRefusalNotice {
                                modeStatusCapsule(reason)
                                    .offset(y: -30)
                            }
                        }
                }

                if let top = controlBounds["top"], let bottom = controlBounds["bottom"] {
                    RecordingStatusOverlay(viewport: geometry.size, toolbarBottom: top.maxY, controlsTop: bottom.minY,
                                           rotationDegrees: statusRotationDegrees,
                                           isInteractive: canManageDaylightMode && !isPhotoMode) {
                        if isPhotoMode { EmptyView() } else { recordingStatus }
                    }
                }

                // Below the threshold the rescue trigger is gone, but an armed
                // session must still have a visible way back to 24 fps. This is
                // the same status face in its idle-armed form: no dot, no timer,
                // and a non-sizing sibling so it reserves no toolbar slot, never
                // hides the lens key and cannot resize the preview.
                if !isDevelopMode, !isPhotoMode, !shouldOfferDaylightRescue, recordPresentation == .idle,
                   cameraViewModel.sessionFrameRate == .daylight60,
                   let top = controlBounds["top"], let bottom = controlBounds["bottom"],
                   let badge = DaylightIdleBadgeGeometry.rect(
                    viewport: geometry.size, toolbarBottom: top.maxY, controlsTop: bottom.minY,
                    rotationDegrees: statusRotationDegrees) {
                    statusFace(text: "")
                        .position(x: badge.midX, y: badge.midY)
                }

                // In-frame rulers, bounded by the live preview intersected with
                // the space between the toolbar and the shooting bar. They read
                // no measured size of their own, so they cannot resize the
                // preview while they appear and disappear. Drawn before the
                // manual panel, so an open panel sits above the focus ruler.
                if let bounds = frameRulerBounds(in: geometry) {
                    if isPhotoMode, showsPhotoShutterRail,
                       let exposure = cameraViewModel.photoExposureSnapshot {
                        let rect = FrameRulerPlacementGeometry.photoShutterRect(
                            inFrame: bounds, orientationDegrees: statusRotationDegrees,
                            excluding: controlBounds["diagnostic"])
                        if !rect.isNull {
                            PhotoShutterControl(snapshot: exposure,
                                setDuration: cameraViewModel.setPhotoShutterDuration,
                                setLocked: cameraViewModel.setPhotoShutterLocked, width: rect.width)
                                .id(cameraViewModel.activeLens)
                                .disabled(cameraViewModel.isPhotoCaptureBusy || cameraViewModel.isChangingFrameRate)
                                .frame(width: rect.width, height: rect.height)
                                .clipped()
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }
                    if legacyManualControlsEnabled {
                        // Legacy fallback (debug flag on): the committed
                        // in-frame rulers, each shown by its own Settings
                        // switch, are preserved unchanged.
                        if isManualFocus {
                            let rect = FrameRulerPlacementGeometry.rect(
                                inFrame: bounds, edge: .right,
                                thickness: FrameRulerPlacementGeometry.focusThickness,
                                orientationDegrees: statusRotationDegrees)
                            if !rect.isNull {
                                FrameRulerSlot(rect: rect, rotationDegrees: statusRotationDegrees) {
                                    ManualFocusRuler(lensPosition: $manualFocusPosition,
                                                     enabled: canUseManualFocusRuler,
                                                     stops: $focusStops)
                                }
                            }
                        }
                        if zoomControlsEnabled {
                            let rect = FrameRulerPlacementGeometry.rect(
                                inFrame: bounds, edge: .left,
                                thickness: FrameRulerPlacementGeometry.zoomThickness,
                                orientationDegrees: statusRotationDegrees)
                            if !rect.isNull {
                                FrameRulerSlot(rect: rect, rotationDegrees: statusRotationDegrees) {
                                    FrameZoomRuler(
                                        millimeters: pinchIsActive ? pinchFocalLength
                                                                   : cameraViewModel.currentFocalLengthMM,
                                        enabled: canUseZoomControls,
                                        revision: cameraViewModel.zoomSnapshot?.cameraRevision ?? 0,
                                        begin: { cameraViewModel.beginSlowZoom($0) },
                                        end: cameraViewModel.endSlowZoom(revision:),
                                        step: cameraViewModel.stepDisplayZoom,
                                        availableFocalRange: cameraViewModel.focalLengthRulerRange)
                                }
                            }
                        }
                    } else if showInlineManualControls {
                        // Default layout: zoom rail on the physical left, the
                        // manual-focus rail with its button stack on the
                        // physical right, revealed together by the master key.
                        inlineFrameRulers(in: bounds)
                    }
                }

                if showManualControls, legacyManualControlsEnabled, !isDevelopMode,
                   let top = controlBounds["top"], let bottom = controlBounds["bottom"] {
                    ManualControlsOverlay(viewport: geometry.size, toolbarBottom: top.maxY, controlsTop: bottom.minY,
                                          excluding: RecordingStatusOverlayGeometry.rect(
                                            viewport: geometry.size, toolbarBottom: top.maxY, controlsTop: bottom.minY,
                                            rotationDegrees: statusRotationDegrees),
                                          expanded: manualControlsExpanded,
                                          rotationDegrees: statusRotationDegrees) {
                        ManualControlsPanel(
                            cameraViewModel: cameraViewModel,
                            manualFocusPosition: $manualFocusPosition,
                            isManualFocus: manualFocusBinding,
                            expanded: $manualControlsExpanded,
                            landscape: abs(statusRotationDegrees) == 90,
                            zoomControlsEnabled: $zoomControlsEnabled,
                            onDismiss: {
                                cameraViewModel.endSlowZoom()
                                withAnimation(.easeInOut(duration: 0.2)) { showManualControls = false }
                            }
                        )
                    }
                    .transition(.opacity)
                }

                // A canvas sibling, not a child painted beyond the shooting bar:
                // visibility never resizes the preview and the whole button is hittable.
                // Photo and Develop keep the rescue hidden: neither has a scene the
                // daylight control can act on, so it must not take their space.
                if !isDevelopMode, !isPhotoMode, shouldOfferDaylightRescue, let exposure = controlBounds["exposure"],
                   let rect = DaylightExposureRescueGeometry.buttonRect(
                    above: exposure, in: geometry.size, rotationDegrees: statusRotationDegrees,
                    excluding: daylightRescueExclusion(in: geometry)) {
                    ExposureRescueButton(armed: cameraViewModel.sessionFrameRate == .daylight60,
                                         enabled: cameraViewModel.canChangeSessionFrameRate,
                                         action: { showDaylightRescue = true })
                        .frame(width: 92, height: 44)
                        .rotationEffect(.degrees(statusRotationDegrees))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                // Preserved pinch behaviour: with Zoom Controls off the ruler
                // still appears only while a pinch is live, in its original
                // stationary slot above the shooting bar.
                if pinchIsActive, !zoomControlsEnabled, let bottom = controlBounds["bottom"] {
                    FocalLengthRuler(millimeters: pinchFocalLength)
                        .frame(width: max(0, geometry.size.width - 32))
                        .position(x: geometry.size.width / 2, y: max(34, bottom.minY - 42))
                }

                if !showFramedPreview, let top = controlBounds["top"] {
                    RecordingTallyLight(isRecording: recordPresentation.showsLiveChrome)
                        .position(x: geometry.size.width - 24, y: top.maxY + 20)
                }

                debugControlsOverlay(in: geometry)
                    .disabled(isDevelopMode)
                    .opacity(isDevelopMode ? 0.3 : 1)

                errorOverlays
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "cameraCanvas")
            .onPreferenceChange(CameraControlBoundsPreference.self) { controlBounds = $0 }
        }
        // An in-camera overlay, not a sheet: the preview, toolbar and shooting bar
        // keep their exact geometry and the scene stays visible behind the dim.
        .overlay {
            if showDaylightRescue {
                DaylightExposureRescueOverlay(
                    armed: cameraViewModel.sessionFrameRate == .daylight60,
                    available: cameraViewModel.supportsDaylight60,
                    canChange: cameraViewModel.canChangeSessionFrameRate,
                    onSelect: { enabled in
                        cameraViewModel.setDaylight60Enabled(enabled)
                        withAnimation(.easeOut(duration: 0.18)) { showDaylightRescue = false }
                    },
                    onCancel: { withAnimation(.easeOut(duration: 0.18)) { showDaylightRescue = false } }
                )
            }
        }
        .sheet(isPresented: $showStockSheet) { stockSheet }
        .sheet(isPresented: $showQueueSheet) { queueSheet }
        .sheet(isPresented: $showSettings) {
            PurchaseView(viewModel: purchaseViewModel, showFramedPreview: $showFramedPreview,
                         manualFocusEnabled: manualFocusBinding,
                         zoomControlsEnabled: zoomControlsSetting,
                         legacyManualControlsEnabled: legacyManualControlsSetting,
                         cameraControlSupported: cameraViewModel.supportsCameraControl)
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
            cameraViewModel.onPhotoCaptured = { source, stock, gauge, seed, crop in
                renderQueueViewModel.enqueuePhoto(sourceURL: source, stockId: stock,
                    iso: cameraViewModel.photoExposureSnapshot?.iso ?? cameraViewModel.liveISO,
                    gauge: gauge, cropZoom: crop, seed: seed)
            }
            availableLenses = cameraViewModel.session.availableLenses
            if !availableLenses.contains(selectedLens) {
                selectedLens = availableLenses.first ?? .wide
            }
            if let selectedStock {
                cameraViewModel.developmentPhotoStockID = selectedStock.stockId
                applyStockWhiteBalance(selectedStock)
            }
            stockSelectorHint.update(stockHintInputs)
        }
        .onChange(of: selectedStock) { _, newStock in
            // A new reference moves what the estimate is compared with.
            stockSelectorHint.resetMismatch()
            if let stock = newStock {
                cameraViewModel.developmentPhotoStockID = stock.stockId
                applyStockWhiteBalance(stock)
            }
        }
        .onChange(of: stockHintInputs) { _, inputs in
            stockSelectorHint.update(inputs)
        }
        .onChange(of: showStockSheet) { _, shown in
            // Opening the selector once skips the discovery cue for the launch.
            if shown { stockSelectorOpenedThisLaunch = true }
        }
        .onChange(of: showManualControls) { _, shown in
            if !shown { cameraViewModel.endSlowZoom() }
        }
        .onChange(of: manualFocusPosition) { _, value in
            // The single hardware write for a focus change: the panel track and
            // the in-frame ruler both mutate `manualFocusPosition`, and only a
            // live manual focus reaches the lens.
            guard isManualFocus else { return }
            cameraViewModel.session.setManualFocusPosition(Float(value))
        }
        .onChange(of: zoomControlsEnabled) { _, enabled in
            // Turning the overlay off cancels any live ramp it started.
            if !enabled { cameraViewModel.endSlowZoom() }
        }
        .onChange(of: captureBusy) { _, busy in
            // A take or a frame-rate/lens transition owns the device: stop the
            // arrows' ramp rather than let it race the reconfigure.
            if busy { cameraViewModel.endSlowZoom() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                focusReadGeneration &+= 1
                showDaylightRescue = false
                cameraViewModel.endSlowZoom()
            }
        }
        .onChange(of: showSettings || showQueueSheet || showStockSheet || showDaylightRescue) { _, shown in
            if shown { cameraViewModel.endSlowZoom() }
        }
        .onChange(of: cameraViewModel.activeLens) { _, lens in
            // A lens change invalidates any sustained estimate and any ramp.
            cameraViewModel.endSlowZoom()
            stockSelectorHint.resetMismatch()
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
        shippingBody.sheet(item: $debugFrameViewModel, onDismiss: firePendingDebugTest) { viewModel in
            DebugFrameSheet(
                viewModel: viewModel,
                onPreviewStockOutline: { pendingDebugTest = .stockOutline },
                onPreviewFault: { pendingDebugTest = .fault },
                hintDiagnostics: debugHintDiagnostics)
        }
    }

    /// Fire the requested one-shot preview only after the sheet has fully
    /// dismissed, so the whole-well outline is never painted behind the sheet.
    private func firePendingDebugTest() {
        guard let test = pendingDebugTest else { return }
        pendingDebugTest = nil
        guard scenePhase == .active else { return }
        switch test {
        case .stockOutline:
            stockSelectorHint.update(stockHintInputs)
            stockSelectorHint.beginDebugPreview()
        case .fault:
            showDebugFault()
        }
    }

    private func showDebugFault() {
        guard recordPresentation == .idle else { return }
        failureDetail = "Debug preview — no recording was attempted."
        flashRecordingFailure()
    }

    /// Frozen hint snapshot for the debug sheet, captured live at the same moment
    /// the sheet opens. It never mutates the hint's rules, launch count, white
    /// balance, exposure or selected stock.
    private func stockHintDiagnosticsSnapshot() -> StockSelectorHintDiagnostics {
        stockSelectorHint.debugDiagnostics(
            estimatedKelvin: cameraViewModel.neutralSceneKelvin,
            estimateCapturedAt: cameraViewModel.neutralSceneCapturedAt,
            referenceKelvin: selectedStock?.colorTemperature)
    }

    /// Capture one frame from the live camera and open the debug sheet on it.
    private func openDebugFrame() {
        guard let stock = selectedStock else {
            cameraViewModel.errorMessage = "Select a film stock before opening the debug frame."
            return
        }
        let gauge = library.lastGauge(for: stock.stockId) ?? .neutral
        let debugConfig = stock.overridingGauge(gauge)
        cameraViewModel.captureDebugFrame { buffer in
            guard let buffer else {
                cameraViewModel.errorMessage = "Debug frame capture failed — is the camera running?"
                return
            }
            debugHintDiagnostics = stockHintDiagnosticsSnapshot()
            debugFrameViewModel = DebugFrameViewModel(frame: buffer, config: debugConfig,
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

    // MARK: - Manual Focus & Zoom Rulers

    /// Whether the legacy manual-controls pop-up panel may be mounted. The flag
    /// is debug-only: a Release build resolves it false even if a device still
    /// carries the preference from a debug install.
    private var legacyManualControlsEnabled: Bool {
        // Photo uses the current manual surface so its Shutter Control toggle
        // remains reachable even when the legacy Video fallback was selected.
        if isPhotoMode { return false }
        #if DEBUG
        return CameraManualControlsFeatureFlags.resolvedLegacyManualControls(
            stored: legacyManualControlsStored, isDebugBuild: true)
        #else
        return false
        #endif
    }

    /// Whether the Photo shutter rail is mounted.
    ///
    /// The rail is not only a manual-panel control: pinning the ISO pins the
    /// shutter with it (the film standard, 1/48s), and the shutter is then the
    /// operator's only exposure control — so it sticks on its own even when the
    /// manual panel is collapsed. The other manual controls keep their own
    /// toggles.
    private var showsPhotoShutterRail: Bool {
        guard isPhotoMode else { return false }
        if showInlineManualControls { return true }
        return cameraViewModel.photoExposureSnapshot?.isoLocked == true
    }

    /// The toolbar's manual key reads as active while either presentation is
    /// showing: the legacy pop-up under the debug flag, otherwise the in-frame
    /// master block.
    private var manualControlsActive: Bool {
        legacyManualControlsEnabled ? showManualControls : showInlineManualControls
    }

    /// The Settings Zoom Controls row. In the default presentation it drives the
    /// same visible state as the toolbar key — enabling it reveals the whole
    /// in-frame block and disabling it hides the block — while under the debug
    /// flag it keeps its committed, independent switch.
    private var zoomControlsSetting: Binding<Bool> {
        Binding(
            get: { legacyManualControlsEnabled ? zoomControlsEnabled : showInlineManualControls },
            set: { newValue in
                if legacyManualControlsEnabled {
                    zoomControlsEnabled = newValue
                } else {
                    setInlineManualControlsShown(newValue)
                }
            }
        )
    }

    /// The debug-only Settings switch that reopens the legacy panel. It writes
    /// the user-owned flag the resolver reads; Release builds see a constant.
    private var legacyManualControlsSetting: Binding<Bool> {
        #if DEBUG
        $legacyManualControlsStored
        #else
        .constant(false)
        #endif
    }

    /// Show or hide the in-frame master controls. Turning them on also lights
    /// the Settings Zoom Controls switch so the discovery row never disagrees
    /// with the screen; turning them off stops a live zoom ramp but leaves the
    /// hardware manual focus, aperture, stabilization and the session focus
    /// stops exactly as they were chosen.
    private func setInlineManualControlsShown(_ shown: Bool) {
        guard shown != showInlineManualControls else { return }
        showInlineManualControls = shown
        zoomControlsEnabled = shown
        if !shown { cameraViewModel.endSlowZoom() }
    }

    /// The live aperture readout for the in-frame controls: the actual hardware
    /// aperture, never a stored or optimistic value.
    private var apertureReadout: String {
        cameraViewModel.liveAperture.map { String(format: "f/%.1f", $0) } ?? "N/A"
    }

    /// Aperture can change only on a variable-aperture lens and only while the
    /// active format is settled, matching the view model's own guard.
    private var canChangeAperture: Bool {
        cameraViewModel.canSelectAperture && !cameraViewModel.isChangingFrameRate
    }

    /// The default in-frame block: the zoom rail on the physical left, and the
    /// manual-focus rail with the inline button stack on the physical right.
    /// Both rails draw at 80% of their 44pt slot, inset flush to the preview
    /// edge, while the slot keeps the full 44pt tap footprint. The button stack
    /// keeps its three 44pt controls reserved even in autofocus, where the rail
    /// renders grey and disabled instead of forcing the lens into manual focus.
    @ViewBuilder
    private func inlineFrameRulers(in bounds: CGRect) -> some View {
        let zoomRect = FrameRulerPlacementGeometry.rect(
            inFrame: bounds, edge: .left,
            thickness: FrameRulerPlacementGeometry.zoomThickness,
            orientationDegrees: statusRotationDegrees)
        if !zoomRect.isNull {
            FrameRulerSlot(rect: zoomRect, rotationDegrees: statusRotationDegrees) {
                FrameZoomRuler(
                    millimeters: pinchIsActive ? pinchFocalLength
                                               : cameraViewModel.currentFocalLengthMM,
                    enabled: canUseZoomControls,
                    revision: cameraViewModel.zoomSnapshot?.cameraRevision ?? 0,
                    begin: { cameraViewModel.beginSlowZoom($0) },
                    end: cameraViewModel.endSlowZoom(revision:),
                    step: cameraViewModel.stepDisplayZoom,
                    availableFocalRange: cameraViewModel.focalLengthRulerRange,
                    visualWidth: FrameRulerPlacementGeometry.rulerVisualThickness)
            }
        }
        let focusRect = FrameRulerPlacementGeometry.rect(
            inFrame: bounds, edge: .right,
            thickness: FrameRulerPlacementGeometry.focusThickness,
            orientationDegrees: statusRotationDegrees)
        if !focusRect.isNull {
            FrameRulerSlot(rect: focusRect, rotationDegrees: statusRotationDegrees) {
                VStack(spacing: 4) {
                    ManualFocusRuler(lensPosition: $manualFocusPosition,
                                     enabled: canUseManualFocusRuler && isManualFocus,
                                     stops: $focusStops,
                                     visualWidth: FrameRulerPlacementGeometry.rulerVisualThickness)
                        .frame(maxHeight: .infinity)
                    InlineManualControls(
                        manualFocus: manualFocusBinding,
                        apertureReadout: apertureReadout,
                        apertureStops: cameraViewModel.apertureStops,
                        selectedAperture: cameraViewModel.selectedLensAperture,
                        canChangeAperture: canChangeAperture,
                        setAperture: { cameraViewModel.setLensAperture($0) },
                        stabilization: cameraViewModel.recordingStabilization,
                        canChangeStabilization: cameraViewModel.canSetRecordingStabilization,
                        selectStabilization: { cameraViewModel.setRecordingStabilization($0) },
                        isPhotoMode: isPhotoMode)
                        .frame(width: 44, height: 140)
                        .background(controlMeasurement("inlineManual"))
                }
            }
        }
    }

    /// Reserve the visible manual surface, not the full camera canvas, so the
    /// contextual rescue button can stay clear without resizing either surface.
    private func daylightRescueExclusion(in geometry: GeometryProxy) -> CGRect? {
        if legacyManualControlsEnabled {
            guard showManualControls,
                  let top = controlBounds["top"], let bottom = controlBounds["bottom"] else { return nil }
            return ManualControlsOverlayGeometry.rect(
                viewport: geometry.size, toolbarBottom: top.maxY, controlsTop: bottom.minY,
                excluding: RecordingStatusOverlayGeometry.rect(
                    viewport: geometry.size, toolbarBottom: top.maxY, controlsTop: bottom.minY,
                    rotationDegrees: statusRotationDegrees),
                expanded: manualControlsExpanded, rotationDegrees: statusRotationDegrees)
        }
        guard showInlineManualControls else { return nil }
        return controlBounds["inlineManual"]
    }

    /// The panel's AF/MF key and the Settings switch share one state, and every
    /// change runs through the same flow so the hardware lock and the readback
    /// can never disagree.
    private var manualFocusBinding: Binding<Bool> {
        Binding(get: { isManualFocus }, set: { setManualFocusEnabled($0) })
    }

    /// Enable or disable manual focus. Enabling first reads the lens's current
    /// position on the session queue and only locks it when the device supports
    /// custom lens positions; the lens never jumps to a stored default. An
    /// unsupported lens stays on autofocus, honestly reported.
    private func setManualFocusEnabled(_ enabled: Bool) {
        focusReadGeneration &+= 1
        guard enabled != isManualFocus else { return }
        guard enabled else {
            isManualFocus = false
            cameraViewModel.session.resetAutoFocus()
            return
        }
        // Enabling manual focus is also a discovery path for the in-frame
        // block: reveal the master so the newly locked focus has a rail. It
        // never forces aperture or stabilization on.
        if !legacyManualControlsEnabled { setInlineManualControlsShown(true) }
        guard scenePhase == .active, !cameraViewModel.isSwitchingCameraLens else { return }
        let request = focusReadGeneration
        cameraViewModel.session.readManualFocusSnapshot(includeCurrentPosition: true) { snapshot in
            guard request == focusReadGeneration, scenePhase == .active,
                  !cameraViewModel.isSwitchingCameraLens else { return }
            guard snapshot.isSupported, let position = snapshot.lensPosition else { return }
            // Set the position before the flag: the position observer only
            // writes while manual focus is on, so the explicit lock below is
            // the single hardware write for this enable.
            manualFocusPosition = Double(position)
            isManualFocus = true
            cameraViewModel.session.setManualFocusPosition(position, expectedRevision: snapshot.cameraRevision)
        }
    }

    private var captureBusy: Bool {
        cameraViewModel.isStartingRecording || cameraViewModel.isRecording
            || cameraViewModel.isStoppingRecording || cameraViewModel.isChangingFrameRate
            || cameraViewModel.isSwitchingCameraLens
    }

    private var canUseManualFocusRuler: Bool {
        scenePhase == .active
    }

    /// Controlled zoom arrows remain usable during recording. Lifecycle,
    /// transitions, unavailable snapshots and covering sheets still block them;
    /// pinch zoom retains the stricter captureBusy gate.
    private var canUseZoomControls: Bool {
        scenePhase == .active && !cameraViewModel.isPhotoCaptureBusy && !cameraViewModel.isStartingRecording
            && !cameraViewModel.isStoppingRecording && !cameraViewModel.isChangingFrameRate
            && !cameraViewModel.isSwitchingCameraLens && cameraViewModel.zoomSnapshot != nil
            && !showSettings && !showQueueSheet && !showStockSheet && !showDaylightRescue
    }

    /// The bounded region a ruler may occupy: the live preview rectangle clipped
    /// to the space between the toolbar and the shooting bar. Pure geometry
    /// from the measured control bounds, never the ruler's own size, so a ruler
    /// cannot feed back into the preview frame.
    private func frameRulerBounds(in geometry: GeometryProxy) -> CGRect? {
        guard !isDevelopMode, let top = controlBounds["top"], let bottom = controlBounds["bottom"] else { return nil }
        let preview = previewRect(in: geometry)
        guard preview.width > 0, preview.height > 0 else { return nil }
        let safe = CGRect(x: 0, y: top.maxY, width: geometry.size.width,
                          height: max(0, bottom.minY - top.maxY))
        let bounds = preview.intersection(safe)
        return bounds.isNull || bounds.isEmpty ? nil : bounds
    }

    private func cameraLayer(in rect: CGRect) -> some View {
        // One structural identity in both modes: no camera lifecycle transition.
        CameraView(viewModel: cameraViewModel,
                   videoGravity: .resizeAspectFill,
                   selectedStockLUTName: isPhotoMode ? nil : selectedStock?.lutName,
                   previewEnabled: !isDevelopMode,
                   developmentPhotoPreview: isPhotoMode)
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: showFramedPreview ? 16 : 0))
            .overlay {
                if showFramedPreview {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showFramedPreview {
                    RecordingTallyLight(isRecording: recordPresentation.showsLiveChrome)
                        .padding(12)
                }
            }
            .contentShape(Rectangle())
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
                .opacity(recordPresentation.showsLiveChrome ? 0 : 1)
                .allowsHitTesting(!recordPresentation.showsLiveChrome)
                .accessibilityHidden(recordPresentation.showsLiveChrome)
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
                .background(controlMeasurement("diagnostic"))
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
                .font(NitrateTypography.font(.title3))
                .foregroundStyle(.white)
                .cameraUpright()
                .frame(width: 44, height: 44)
        }
        .buttonStyle(CameraRoundButtonStyle())
    }

    private var manualButton: some View {
        Button {
            if legacyManualControlsEnabled {
                // Legacy debug path: the manual key reopens the old pop-up.
                withAnimation(.easeInOut(duration: 0.2)) { showManualControls.toggle() }
            } else {
                // Default path: the manual key toggles every in-frame control
                // — both rulers and the inline button stack — together.
                withAnimation(.easeInOut(duration: 0.2)) {
                    setInlineManualControlsShown(!showInlineManualControls)
                }
            }
        } label: {
            Image(systemName: "slider.vertical.3")
                .font(NitrateTypography.font(.title3))
                .foregroundStyle(manualControlsActive ? .black : .white)
                .cameraUpright()
                .frame(width: 44, height: 44)
        }
        .buttonStyle(CameraRoundButtonStyle(faceColor: manualControlsActive ? SettingsControlChrome.halationOrange : nil))
        .accessibilityLabel("Manual controls")
        .accessibilityValue(manualControlsActive ? "Expanded" : "Collapsed")

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
                    .font(NitrateTypography.font(size: 10))
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
                showDebugFault()
            } label: {
                Text("FAULT")
                    .font(NitrateTypography.font(size: 10))
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

    /// The timer and tally acknowledge the accepted tap, before capture confirms.
    /// Idle and finalizing render nothing; cancellation and failure return to idle.
    @ViewBuilder private var recordingStatus: some View {
        if recordPresentation.showsLiveChrome {
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

    /// Meter readings use neutral scene EV in native AE and custom exposure alike.
    /// Compare against the requested compensation regardless of which leg is held.
    private var shouldOfferDaylightRescue: Bool {
        DaylightExposureRescuePolicy.shouldOffer(
            meteredEV: cameraViewModel.liveExposureTargetOffset,
            targetEV: cameraViewModel.liveExposureBias,
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
        .disabled(cameraViewModel.isPhotoCaptureBusy || cameraViewModel.isSwitchingCameraLens || cameraViewModel.isChangingFrameRate)
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

    /// The screen's live inputs to the hint. The estimate fields are published
    /// only while the hint can still fire, so once the cue is done (or the launch
    /// is ineligible) the outline stops recomputing.
    private var stockHintInputs: StockSelectorHintInputs {
        let armed = stockSelectorHint.isArmed
        return StockSelectorHintInputs(
            isActive: isStockHintActive,
            isSelectorOpened: stockSelectorOpenedThisLaunch,
            tick: armed ? cameraViewModel.hintTick : 0,
            estimateKelvin: armed ? cameraViewModel.neutralSceneKelvin : nil,
            estimateCapturedAt: armed ? cameraViewModel.neutralSceneCapturedAt : nil,
            referenceKelvin: armed ? selectedStock?.colorTemperature : nil)
    }

    /// True only while the camera is usable and idle and nothing is covering it.
    /// Any modal, sheet, fault, warning or in-flight take/transition pauses the
    /// hint's active clock and clears its sustained condition.
    private var isStockHintActive: Bool {
        guard !isDevelopMode else { return false }
        guard scenePhase == .active else { return false }
        guard !cameraViewModel.isStartingRecording,
              !cameraViewModel.isRecording,
              !cameraViewModel.isStoppingRecording,
              !cameraViewModel.isChangingFrameRate,
              !cameraViewModel.isSwitchingCameraLens else { return false }
        guard cameraViewModel.hasExposureMeter else { return false }
        guard !showStockSheet, !showQueueSheet, !showSettings,
              !showDaylightRescue, !showManualControls, !showsRecordingFailure else { return false }
        guard cameraViewModel.errorMessage == nil, cameraViewModel.recordingWarning == nil else { return false }
        #if DEBUG
        if debugFrameViewModel != nil { return false }
        #endif
        return true
    }

    /// Two-row bottom stack (selector row + action row). Lives in its own file
    /// (`CameraControlBar.swift`) so this screen stays inside the file limit.
    ///
    /// `horizontalInset` lines the bar's outer LCD/stock and exposure edges up
    /// with the framed viewfinder's side edges; the immersive preview keeps its
    /// established 16pt margin.
    private func controlBar(horizontalInset: CGFloat) -> some View {
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
            },
            showsStockHint: stockSelectorHint.isCueVisible,
            horizontalInset: horizontalInset,
            isDevelopMode: isDevelopMode,
            developCanRender: developModel.canRender(stock: selectedStock, queue: renderQueueViewModel),
            developIsBusy: developIsBusy,
            onDevelopRender: {
                guard let stock = selectedStock else { return }
                let gauge = library.lastGauge(for: stock.stockId) ?? .neutral
                _ = developModel.render(stock: stock, iso: currentISO, gauge: gauge, queue: renderQueueViewModel)
            },
            isPhotoMode: isPhotoMode,
            photoStatus: photoDeliveryStatus,
            onPhotoCapture: {
                let gauge = selectedStock.flatMap { library.lastGauge(for: $0.stockId) } ?? .neutral
                cameraViewModel.takeDevelopmentPhoto(gauge: gauge)
            },
            photoExposure: cameraViewModel.photoExposureSnapshot,
            onPhotoISO: { cameraViewModel.setManualISO($0) },
            onPhotoISOLock: { cameraViewModel.toggleISOLock(currentISO: cameraViewModel.liveISO) },
            onPhotoDuration: cameraViewModel.setPhotoShutterDuration,
            hardwareCaptureEnabled: hardwareCaptureEnabled,
            onPhotoShutterLock: cameraViewModel.togglePhotoShutterLock
        )
        .onChange(of: cameraHardwareControlsVisible, initial: true) { _, _ in updateCameraHardwareControls() }
        .onChange(of: cameraControlAdjustment) { _, _ in updateCameraHardwareControls() }
        .onDisappear {
            cameraViewModel.updateCameraHardwareControls(
                adjustment: CameraControlAdjustment(persistedValue: cameraControlAdjustment), enabled: false)
        }
    }

    /// Hardware must not consume capture events behind a sheet or in Develop.
    private var cameraHardwareControlsVisible: Bool {
        guard cameraViewModel.supportsCameraControl, scenePhase == .active, !isDevelopMode,
              !showSettings, !showQueueSheet, !showStockSheet,
              !showDaylightRescue, !showManualControls else { return false }
#if DEBUG
        if debugFrameViewModel != nil || pendingDebugTest != nil { return false }
#endif
        return true
    }

    private var hardwareCaptureEnabled: Bool {
        guard cameraHardwareControlsVisible else { return false }
        // A second full press must still stop a take or cancel its startup.
        if cameraViewModel.isRecording || cameraViewModel.isStartingRecording { return true }
        // A fault or a full disk is not a capture transition: it still disarms.
        guard !showsRecordingFailure, cameraViewModel.errorMessage == nil,
              !cameraViewModel.isSpaceCritical else { return false }
        // Keep the platform interaction armed while handling a Photo full press.
        // The live model still refuses a second still through its busy gate.
        if cameraViewModel.isPhotoCaptureBusy { return true }
        return cameraViewModel.canChangeShootingMode
    }

    private func updateCameraHardwareControls() {
#if DEBUG
        if CommandLine.arguments.contains("--trace-camera-control") {
            CameraControlDiagnostics.record("visibility visible=\(cameraHardwareControlsVisible) "
                + "captureEnabled=\(hardwareCaptureEnabled) scene=\(scenePhase) "
                + "runtimeEnabled=\(cameraViewModel.canAcceptHardwareCapture) "
                + "profileChanging=\(cameraViewModel.isChangingCaptureProfile)")
        }
#endif
        cameraViewModel.updateCameraHardwareControls(
            adjustment: CameraControlAdjustment(persistedValue: cameraControlAdjustment),
            enabled: cameraHardwareControlsVisible)
    }

    private var canChangeCameraMode: Bool {
        scenePhase == .active && cameraViewModel.canChangeShootingMode && !captureBusy && !cameraViewModel.isPhotoCaptureBusy && !cameraViewModel.isChangingFrameRate
            && !cameraViewModel.isSwitchingCameraLens && !showStockSheet && !showQueueSheet
            && !showSettings && !showDaylightRescue
    }

    private var photoDeliveryStatus: String? {
        if cameraViewModel.isPhotoCaptureBusy { return cameraViewModel.photoCaptureStatus }
        guard let id = cameraViewModel.photoRenderJobID,
              let job = renderQueueViewModel.jobs.first(where: { $0.id == id }) else {
            return cameraViewModel.photoCaptureStatus
        }
        switch job.status {
        case .pending: return "Photo queued for development"
        case .processing:
            return renderQueueViewModel.progress(for: id)?.phase == .saving ? "Saving photo to Photos…" : "Developing photo…"
        case .completed: return job.outputSavedToPhotos == true ? "Photo saved to Photos" : "Photo developed"
        case .failed: return "Original kept locally · photo development failed"
        case .awaitingStock: return "Choose a photo stock"
        }
    }

    private var isPhotoMode: Bool { cameraMode.selected == .photo }
    private var isDevelopMode: Bool { cameraMode.selected == .develop }

    private var developIsBusy: Bool {
        guard let id = developModel.activeJobID,
              let job = renderQueueViewModel.jobs.first(where: { $0.id == id }) else { return false }
        return job.status == .pending || job.status == .processing
    }

    /// Say why a mode change was refused, where the operator is looking.
    private func showModeRefusal(_ text: String) {
        modeRefusalNotice = text
        modeRefusalTask?.cancel()
        modeRefusalTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if modeRefusalNotice == text { modeRefusalNotice = nil }
        }
    }

    private func selectCameraMode(_ mode: CameraMode) {
        guard canChangeCameraMode else { return }
        guard CameraMode.visibleModes(photoAvailable: photoModeAvailable).contains(mode),
              mode != cameraMode.selected else { return }
        if mode == .photo {
            cameraViewModel.setDevelopmentPhotoMode(true) { result in
                guard case .success = result else {
                    if case .failure(let error) = result,
                       (error as? CameraError)?.isPhotoCapabilityRefusal == true {
                        showModeRefusal("Photo isn't available on this camera")
                    } else {
                        showModeRefusal("Photo needs the shared camera, which is not ready")
                    }
                    return
                }
                _ = cameraMode.select(.photo, enabled: true, photoAvailable: photoModeAvailable)
                developModel.leaveDevelop()
            }
            return
        }
        if cameraMode.selected == .photo {
            cameraViewModel.setDevelopmentPhotoMode(false) { result in
                guard case .success = result else {
                    showModeRefusal("The camera is still finishing the photo mode change")
                    return
                }
                _ = cameraMode.select(mode, enabled: true, photoAvailable: photoModeAvailable)
                if mode == .video { developModel.leaveDevelop() }
            }
            return
        }
        guard cameraMode.select(mode, enabled: true, photoAvailable: photoModeAvailable) else { return }
        // Develop shares the video graph, so its commits land here; the photo
        // transitions reset from the camera model once their graph commits.
        cameraViewModel.resetFocusAreaToCenter()
        if mode == .video {
            developModel.leaveDevelop()
        } else {
            cameraViewModel.endSlowZoom()
            pinchIsActive = false
        }
    }

    /// The shooting bar's horizontal margin. In Frame Mode it aligns the bar's
    /// outer LCD/stock and exposure edges with the viewfinder's side edges, read
    /// from the same preview rectangle the camera layer uses, clamped so the row
    /// never overlaps. The immersive preview, and the first frame before the
    /// control bounds exist, keep the established 16pt margin.
    ///
    /// Pure geometry only: the value never reads capture state or the
    /// orientation glyph rotation, and the bar's measured height — the only
    /// dimension the preview reads — never depends on it, so deriving the inset
    /// cannot feed back into the preview.
    private func controlBarHorizontalInset(in geometry: GeometryProxy) -> CGFloat {
        guard showFramedPreview else { return CameraControlGeometry.defaultHorizontalInset }
        let preview = previewRect(in: geometry)
        guard preview.width > 0 else { return CameraControlGeometry.defaultHorizontalInset }
        return CameraControlGeometry.controlBarHorizontalInset(
            previewEdgeInset: preview.minX, canvasWidth: geometry.size.width)
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
            // Photo keeps nothing floating over the shutter. A refusal or a
            // delayed delivery is reported through `errorMessage`, which the camera
            // already shows, so the frame above the button stays clear.
            if showsRecordingFailure {
                RecordingFailureOverlay(detail: failureDetail)
                    .transition(.opacity)
            }
        }
    }

    /// The mode row's own status face, the same capsule the photo strip uses.
    private func modeStatusCapsule(_ status: String) -> some View {
        statusCapsule(status, identifier: "camera.modeStatus")
    }

    private func statusCapsule(_ status: String, identifier: String) -> some View {
        Text(status)
            .foregroundStyle(.white)
            .font(NitrateTypography.font(.caption))
            .cameraUpright()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.72))
            .clipShape(Capsule())
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(status)
            .padding(.horizontal, 16)
            .allowsHitTesting(false)
    }

    private func cameraErrorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                .cameraUpright()
            Text(message).foregroundStyle(.white).font(NitrateTypography.font(.caption))
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
            Text(message).foregroundStyle(.white).font(NitrateTypography.font(.caption))
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
            sourceURL: isDevelopMode ? nil : currentSourceURL,
            awaitingStockJobId: isDevelopMode ? nil : awaitingStockJobId,
            capturePolicy: isDevelopMode ? nil : currentSourceURL.flatMap { cameraViewModel.capturePolicy(for: $0) },
            isPresented: $showStockSheet,
            selectedStock: $selectedStock,
            currentISO: $currentISO,
            selectionOnly: isDevelopMode
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
    var selectionOnly = false

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

                        if let url = sourceURL, !selectionOnly {
                            renderButton(sourceURL: url)
                        } else if !selectionOnly {
                            Text("Record a video to render.")
                                .font(NitrateTypography.font(.caption))
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
            Text("Print Gauge").font(NitrateTypography.font(.headline))
            Picker("Print Gauge", selection: $gauge) {
                ForEach(PrintGauge.allCases, id: \.self) { gauge in
                    Text(gauge.displayName).tag(gauge)
                }
            }
            .pickerStyle(.segmented)
            Text("Gauge sets grain size and presence (8mm coarse → 75mm near grain-free).")
                .font(NitrateTypography.font(.caption))
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
