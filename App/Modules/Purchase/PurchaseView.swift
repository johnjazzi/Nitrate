import SwiftUI

/// AD-1: Purchase/settings screen — 20-day evaluation, $4.99/year, $9.99 lifetime.
struct PurchaseView: View {
    @State var viewModel: PurchaseViewModel
    @Binding var showFramedPreview: Bool
    /// Live session switches owned by the camera screen. They default off and
    /// never persist across a launch; a preview or a constructor that omits them
    /// falls back to a constant `false`, so nothing here writes a preference.
    var manualFocusEnabled: Binding<Bool> = .constant(false)
    var zoomControlsEnabled: Binding<Bool> = .constant(false)
    /// Debug-only switch that reopens the legacy manual-controls pop-up panel.
    /// Writes the user-owned feature flag the camera screen resolves; a Release
    /// build resolves that flag false whatever this holds, so the constant
    /// default keeps previews and shipping builds inert.
    var legacyManualControlsEnabled: Binding<Bool> = .constant(false)
    /// Whether this phone has a physical Camera Control button. Defaults false so
    /// a preview or a constructor that omits it never offers a setting the
    /// hardware cannot honour; the camera screen passes
    /// `cameraViewModel.supportsCameraControl`.
    var cameraControlSupported = false
    /// Supplied by the active camera owner at the current session rate.
    var availableCaptureFormats: [CaptureFormat] = []
    var stockLibrary: FilmStockLibrary? = nil
    @State private var pricingExpanded = false
    @State private var legalExpanded = false
    @AppStorage(RecordingIndicatorStyle.preferenceKey) private var recordingIndicatorStyle = RecordingIndicatorStyle.red.rawValue
    @AppStorage(DeliverySettings.saveOriginalLogKey) private var saveOriginalLog = false
    @AppStorage(DeliverySettings.saveOriginalRAWToPhotosKey) private var saveOriginalRAWToPhotos = false
    @AppStorage(DeliverySettings.renderQualityKey) private var renderQuality = RenderExportQuality.high.rawValue
    @AppStorage(DeliverySettings.deliveryFramingKey) private var deliveryFraming = DeliveryFraming.defaultValue.rawValue
    @AppStorage(CaptureFormat.preferenceKey) private var captureFormat = CaptureFormat.defaultValue.rawValue
    /// The stored capture format clamped to what this phone can deliver, so a
    /// default of open gate reads as UHD on hardware without that format.
    private var effectiveCaptureFormat: CaptureFormat {
        CaptureFormat.clamped(captureFormat, to: availableCaptureFormats)
    }

    /// Open gate records 4:3, so the delivery-framing row has nothing to crop.
    private var isOpenGateCapture: Bool { effectiveCaptureFormat.isOpenGate }
    @AppStorage(RecordButtonAppearance.preferenceKey) private var recordButtonAppearance = RecordButtonAppearance.classic.rawValue
    /// The Camera Control slide target. Stored as its raw string so the camera
    /// screen reads the same value this picker writes; an absent or unrecognised
    /// value resolves to Zoom, exactly like the camera screen's own resolution.
    @AppStorage(CameraControlAdjustment.preferenceKey) private var cameraControlAdjustment = CameraControlAdjustment.defaultValue.rawValue
    @AppStorage(MeteringIndicatorPreferences.showsIndicatorKey) private var showsMeteringIndicator = MeteringIndicatorPreferences.defaultShowsIndicator
    /// The persisted Camera Tips switch the camera screen reads to gate its
    /// unsolicited advisory cues. ON by default; camera errors, faults, recording
    /// failures, storage warnings and live status are never affected.
    @AppStorage(CameraHintPreferences.showsAdvisoryTipsKey)
    private var showsAdvisoryTips = CameraHintPreferences.defaultShowsAdvisoryTips
#if DEBUG
    @AppStorage(DebugControlPreferences.showsDebugButtonKey) private var showsDebugButton = true
    @AppStorage(DebugControlPreferences.showsFaultButtonKey) private var showsFaultButton = true
#endif

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        // Access status, and the way to the purchase options.
                        trialStatusSection(revealPricing: {
                            pricingExpanded = true
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(Self.pricingAnchor, anchor: .top)
                            }
                        })

                        // Preview mode
                        previewModeSection
                        filmStocksSection
                        exportSection

#if DEBUG
                        debugSection
#endif

#if NITRATE_LOCAL_DEVELOPMENT || NITRATE_EVALUATION_TOOLS
                        // A DevRelease build is a release configuration, so
                        // DEBUG is off and the Debug panel above does not exist.
                        // Local-only developer actions live in their own section.
                        developmentSection
#endif

                        // App info
                        appInfoSection
                        pricingDisclosure
                            .id(Self.pricingAnchor)
                        legalDisclosure
                    }
                    .padding()
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                viewModel.onAppear()
            }
            .onDisappear {
                viewModel.onDisappear()
            }
            .alert("Purchase Error", isPresented: errorBinding) {
                Button("OK") { viewModel.dismissError() }
            } message: {
                Text(viewModel.purchaseError ?? "")
            }
        }
    }

    // MARK: - Subviews

    private var pricingDisclosure: some View {
        DisclosureGroup("Pricing", isExpanded: $pricingExpanded) {
#if DEBUG || NITRATE_LOCAL_DEVELOPMENT
            if let preview = viewModel.launchPricingPreview {
                launchPricingPreview(preview)
            } else {
                customerPricingContent
            }
#else
            customerPricingContent
#endif
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var customerPricingContent: some View {
        if !viewModel.isPurchased {
            purchaseOptionsSection
            legalLinksSection
        } else {
            purchasedBanner
            accountActionsRow
        }
    }

    private var legalDisclosure: some View {
        DisclosureGroup("Legal & Support", isExpanded: $legalExpanded) {
            legalLinksSection
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Anchor the status card scrolls to when it offers the purchase options.
    private static let pricingAnchor = "settings.pricing"

    /// Access status at the top of Settings: how long rendering is included, or
    /// that it is unlocked, plus the one action that matters from here.
    private func trialStatusSection(revealPricing: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
#if DEBUG || NITRATE_LOCAL_DEVELOPMENT
            if viewModel.isDevelopmentBuild {
                Image(systemName: "hammer.fill")
                    .font(NitrateTypography.font(.largeTitle))
                    .foregroundStyle(.tint)
                Text("Development Build")
                    .font(NitrateTypography.font(.title2).bold())
                Text("This build did not come from the App Store, so film rendering is unlocked for free. "
                     + "Customers installing from the App Store are unaffected.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                // The customer card stays visible so the evaluation count and the
                // route to checkout can be checked on a local build that never
                // gates rendering.
                customerTrialStatusContent(revealPricing: revealPricing)
            } else {
                customerTrialStatusContent(revealPricing: revealPricing)
            }
#else
            customerTrialStatusContent(revealPricing: revealPricing)
#endif
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func customerTrialStatusContent(revealPricing: @escaping () -> Void) -> some View {
        if viewModel.isPurchased {
            unlockedStatus
        } else if viewModel.isTrialActive {
            Image(systemName: "clock.badge.checkmark")
                .font(NitrateTypography.font(.largeTitle))
                .foregroundStyle(.tint)
            Text(daysRemainingTitle)
                .font(NitrateTypography.font(.title2).bold())
            // Literal: this period is included, it does not turn into a
            // subscription by itself, and nothing is charged when it ends.
            Text("Film rendering is included. No charge, and nothing starts a subscription.")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            purchaseOptionsButton(revealPricing: revealPricing)
        } else if viewModel.isDevelopmentBuild {
            // A local build never gates rendering, so a lapsed evaluation is not
            // a paused state here.
            unlockedStatus
        } else {
            Image(systemName: "lock.fill")
                .font(NitrateTypography.font(.largeTitle))
                .foregroundStyle(.secondary)
            Text("Rendering paused")
                .font(NitrateTypography.font(.title2).bold())
            Text("Recording stays free. Unlock film rendering to develop what you shoot.")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            purchaseOptionsButton(revealPricing: revealPricing)
        }
    }

    private var unlockedStatus: some View {
        Group {
            Image(systemName: "checkmark.seal.fill")
                .font(NitrateTypography.font(.largeTitle))
                .foregroundStyle(.green)
            Text("Unlocked")
                .font(NitrateTypography.font(.title2).bold())
        }
    }

    private var daysRemainingTitle: String {
        let days = max(1, viewModel.daysRemaining)
        return days == 1 ? "Last day included" : "\(days) days included"
    }

    private func purchaseOptionsButton(revealPricing: @escaping () -> Void) -> some View {
        Button(action: revealPricing) {
            Text("See purchase options")
                .font(NitrateTypography.font(.footnote).weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("settings.purchaseOptions")
        .padding(.top, 4)
    }

#if DEBUG || NITRATE_LOCAL_DEVELOPMENT
    /// The non-purchasable price information for a local development build
    /// (DEBUG or `NITRATE_LOCAL_DEVELOPMENT`). It carries the owner-approved US
    /// launch amounts and states that recording stays free and the build is not
    /// charged; there is deliberately no checkout button here, because this copy
    /// is not a fallback purchase price. Every customer channel — including
    /// sandbox (TestFlight and App Review) — renders the live checkout instead.
    private func launchPricingPreview(_ preview: LaunchPricingPreview) -> some View {
        VStack(spacing: 10) {
            Text(preview.headline)
                .font(NitrateTypography.font(.headline))
            priceRow(title: "Yearly",
                     detail: "Film rendering, renews yearly",
                     price: preview.yearlyPrice, billing: "per year")
            priceRow(title: "Lifetime",
                     detail: "One-time purchase, film rendering forever",
                     price: preview.lifetimePrice, billing: "one time")
            Text(preview.footnote)
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("launch-pricing-preview")
    }

    private func priceRow(title: String, detail: String, price: String, billing: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NitrateTypography.font(.body).bold())
                Text(detail)
                    .font(NitrateTypography.font(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            priceAmount(price, billing: billing)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

#endif

    private func priceAmount(_ amount: String, billing: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(amount).font(NitrateTypography.font(.body).bold())
            Text(billing).font(NitrateTypography.font(.caption)).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var purchaseOptionsSection: some View {
        VStack(spacing: 12) {
            Text("Unlock Film Rendering")
                .font(NitrateTypography.font(.headline))

            if let loadError = viewModel.productLoadError {
                productUnavailableNotice(detail: loadError)
            } else if viewModel.pricesUnavailable {
                productUnavailableNotice(detail: "Prices are still loading from the App Store.")
            }

            // Yearly subscription
            Button(action: viewModel.purchaseSubscription) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Yearly")
                            .font(NitrateTypography.font(.body).bold())
                        Text("Film rendering, cancel anytime")
                            .font(NitrateTypography.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    priceAmount(viewModel.subscriptionPrice ?? PurchasePriceText.unavailable,
                                billing: "per year")
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.subscriptionPrice == nil)

            // Lifetime
            Button(action: viewModel.purchaseLifetime) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lifetime")
                            .font(NitrateTypography.font(.body).bold())
                        Text("One-time purchase, film rendering forever")
                            .font(NitrateTypography.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    priceAmount(viewModel.lifetimePrice ?? PurchasePriceText.unavailable,
                                billing: "one time")
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.lifetimePrice == nil)

            accountActionsRow
        }
    }

    /// Restore keeps a reinstall or a second device in sync; redemption accepts
    /// an Apple offer code. Both are always shown on a checkout channel so a
    /// customer with an existing grant or a code is never stuck at the paywall.
    private var accountActionsRow: some View {
        HStack(spacing: 16) {
            Button("Restore Purchases") {
                viewModel.restorePurchases()
            }
            Button("Redeem Code") {
                viewModel.redeemOfferCode()
            }
        }
        .font(NitrateTypography.font(.caption))
    }

    /// L12: a real product-load failure is shown, never masked by a fallback
    /// price. Recovery is an explicit retry.
    private func productUnavailableNotice(detail: String) -> some View {
        VStack(spacing: 6) {
            Text("In-app purchases are unavailable")
                .font(NitrateTypography.font(.footnote).bold())
            Text(detail)
                .font(NitrateTypography.font(.caption2))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                viewModel.retryLoadProducts()
            }
            .font(NitrateTypography.font(.caption))
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Preview Mode

    @ViewBuilder private var filmStocksSection: some View {
        if let library = stockLibrary {
            VStack(alignment: .leading, spacing: 12) {
                Text("Film Stocks")
                    .font(NitrateTypography.font(.headline))
                ForEach(library.stocks, id: \.stockId) { stock in
                    SettingsToggleRow(icon: "film", title: stock.displayName,
                                      accessibilityTitle: stock.displayName,
                                      help: "Show this stock in film stock pickers.",
                                      isOn: Binding(
                                        get: { library.isStockVisible(stock.stockId) },
                                        set: { library.setStockVisible($0, for: stock.stockId) }))
                        .disabled(stock.category == .video && library.isStockVisible(stock.stockId)
                                  && library.videoStocks().count == 1)
                }
                Text("Keep at least one stock enabled.")
                    .font(NitrateTypography.font(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var previewModeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(NitrateTypography.font(.headline))

            Text("Native camera preview. Film processing is applied only to saved output.")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)

            SettingsControlRow(icon: "record.circle",
                               title: "Recording Indicator",
                               accessibilityTitle: "Recording indicator",
                               help: "Sets the appearance of the status light and timer. "
                                   + "The timer starts when recording is confirmed.") {
                SettingsSelectionRow(title: "Recording Indicator",
                                     valueText: RecordingIndicatorStyle.resolved(recordingIndicatorStyle).title) {
                    Picker("Recording Indicator", selection: Binding(
                        get: { RecordingIndicatorStyle.resolved(recordingIndicatorStyle) },
                        set: { recordingIndicatorStyle = $0.rawValue })) {
                        ForEach(RecordingIndicatorStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                }
            }

            SettingsControlRow(icon: "button.programmable",
                               title: "Record button",
                               accessibilityTitle: "Record button appearance",
                               help: "Choose a raised or flat record button.") {
                SettingsSelectionRow(title: "Record button",
                                     valueText: RecordButtonAppearance.resolved(recordButtonAppearance).title) {
                    Picker("Record button", selection: Binding(
                        get: { RecordButtonAppearance.resolved(recordButtonAppearance) },
                        set: { recordButtonAppearance = $0.rawValue })) {
                        ForEach(RecordButtonAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                }
            }

            SettingsToggleRow(icon: "viewfinder",
                              title: "Frame Mode",
                              accessibilityTitle: "Frame Mode",
                              help: "Frames the preview with space for camera controls.",
                              isOn: $showFramedPreview)

            SettingsToggleRow(icon: "scope",
                              title: "Manual Focus",
                              accessibilityTitle: "Manual focus",
                              help: "Locks the lens at its current position and shows a manual focus ruler along the right edge of the frame.",
                              isOn: manualFocusEnabled)

            SettingsToggleRow(icon: "arrow.up.left.and.arrow.down.right",
                              title: "Zoom Controls",
                              accessibilityTitle: "Zoom controls",
                              help: "Keeps the focal length ruler on screen and adds hold arrows for a controlled zoom.",
                              isOn: zoomControlsEnabled)

            // The whole feature — Settings row, slide and full press — exists
            // only on a phone with a physical Camera Control button.
            if cameraControlSupported {
                SettingsControlRow(icon: "hand.tap",
                                   title: "Camera Control",
                                   accessibilityTitle: "Camera control",
                                   help: "A full press captures a photo, or starts and stops a recording. "
                                       + "On supported iPhones a light press and slide adjusts the selected control. "
                                       + "Off turns off that slide adjustment only — a full press still captures.") {
                    SettingsSelectionRow(title: "Camera Control",
                                         valueText: cameraControlBinding.wrappedValue.title) {
                        Picker("Camera Control", selection: cameraControlBinding) {
                            ForEach(CameraControlAdjustment.allCases) { adjustment in
                                Text(adjustment.title).tag(adjustment)
                            }
                        }
                    }
                }
            }

            SettingsToggleRow(icon: "circle.dashed",
                              title: "Metering Indicator",
                              accessibilityTitle: "Metering indicator",
                              help: "Shows a circle at the selected metering point.",
                              isOn: $showsMeteringIndicator)

            SettingsToggleRow(icon: "lightbulb",
                              title: "Camera Tips",
                              accessibilityTitle: "Camera tips",
                              help: "Shows brief advice while you shoot, such as when the scene is too bright "
                                  + "or the selected stock may be off. Camera errors, warnings and recording "
                                  + "status always show.",
                              isOn: $showsAdvisoryTips)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Display name for the preview monitor mode. `CameraPreviewMode` carries no
    /// title (the display text lives in the picker), so the chip resolves it here
    /// rather than editing the camera-capture enum.
    private func previewModeTitle(_ mode: CameraPreviewMode) -> String {
        switch mode {
        case .neutral: "Neutral"
        case .stock: "Stock LUT"
        case .log: "Log"
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(NitrateTypography.font(.headline))
            SettingsToggleRow(icon: "square.and.arrow.down",
                              title: "Save Original Video to Photos",
                              accessibilityTitle: "Save Original Video",
                              help: "Saves an additional, ungraded original (Apple Log 2 or HDR HLG) to Photos and uses more storage.",
                              isOn: $saveOriginalLog)
            SettingsToggleRow(icon: "camera.raw",
                              title: "Save Original RAW to Photos",
                              accessibilityTitle: "Save Original RAW",
                              help: "Saves each photo's unprocessed DNG to Photos as a second item next to the developed JPEG "
                                  + "and uses more storage. Your choice applies to photos added to the queue afterward.",
                              isOn: $saveOriginalRAWToPhotos)
            SettingsControlRow(icon: "camera.aperture",
                               title: "Capture Format",
                               accessibilityTitle: "Capture format",
                               help: "UHD 16:9 records 3840x2160, the shipping widescreen capture. "
                                   + "Open Gate 2K records 1920x1440 in native 4:3 with the full "
                                   + "sensor height — it is not cropped from 16:9 — and is only "
                                   + "offered when the active camera and frame rate expose a native 10-bit "
                                   + "format: 4:2:2 Apple Log 2, or x420 HLG on cameras without Apple Log. "
                                   + "Film delivery is SDR Rec.709. Applies to videos recorded afterwards.") {
                SettingsSelectionRow(title: "Capture Format",
                                     valueText: availableCaptureFormats.isEmpty ? "Unavailable" : effectiveCaptureFormat.title) {
                    Picker("Capture Format", selection: Binding(
                        get: { effectiveCaptureFormat },
                        set: { captureFormat = $0.rawValue })) {
                        ForEach(availableCaptureFormats, id: \.rawValue) { format in
                            Text(format.title).tag(format)
                        }
                    }
                }
            }
            .disabled(availableCaptureFormats.isEmpty)
            SettingsControlRow(icon: "rectangle.inset.filled",
                               title: "Delivery Framing",
                               accessibilityTitle: "Delivery framing",
                               help: "16:9 delivers the full recorded frame. 4:3 crops the sides of the "
                                   + "rendered video to a centred 4:3 frame (2880x2160 from a 3840x2160 "
                                   + "recording). The original recording is never cropped. "
                                   + "Your choice applies to videos added to the queue afterward.") {
                SettingsSelectionRow(title: "Delivery Framing",
                                     valueText: isOpenGateCapture
                                         ? "Whole frame (open gate)"
                                         : (DeliveryFraming(rawValue: deliveryFraming)
                                            ?? DeliveryFraming.defaultValue).title) {
                    Picker("Delivery Framing", selection: Binding(
                        get: { DeliveryFraming(rawValue: deliveryFraming) ?? DeliveryFraming.defaultValue },
                        set: { deliveryFraming = $0.rawValue })) {
                        ForEach(DeliveryFraming.allCases, id: \.rawValue) { framing in
                            Text(framing.title).tag(framing)
                        }
                    }
                    // Open gate is already 4:3, so a delivery crop would do
                    // nothing. Offering a control that changes no pixels is
                    // worse than saying the frame is whole.
                    .disabled(isOpenGateCapture)
                }
            }
            SettingsControlRow(icon: "arrow.up.arrow.down.circle",
                               title: "Rendered File Size",
                               accessibilityTitle: "Rendered file size",
                               help: "High uses 60 Mbps; Smaller uses 30 Mbps and can soften grain. "
                                   + "Resolution and frame rate stay the same. "
                                   + "Your choice applies to videos added to the queue afterward.") {
                SettingsSelectionRow(title: "Rendered File Size",
                                     valueText: exportQualityBinding.wrappedValue.title) {
                    Picker("Rendered File Size", selection: exportQualityBinding) {
                        ForEach(RenderExportQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var exportQualityBinding: Binding<RenderExportQuality> {
        Binding(get: { RenderExportQuality(rawValue: renderQuality) ?? .high },
                set: { renderQuality = $0.rawValue })
    }

    /// The Camera Control row edits the stored raw string through the enum, so an
    /// absent or unrecognised value shows (and keeps) Zoom instead of an empty chip.
    private var cameraControlBinding: Binding<CameraControlAdjustment> {
        Binding(get: { CameraControlAdjustment(persistedValue: cameraControlAdjustment) },
                set: { cameraControlAdjustment = $0.rawValue })
    }

    private var purchasedBanner: some View {
        HStack {
            Image(systemName: "infinity.circle.fill")
                .foregroundStyle(.green)
            Text(viewModel.isLifetimePurchased
                 ? "Film rendering unlocked forever"
                 : "Film rendering unlocked — subscription active")
                .foregroundStyle(.secondary)
        }
    }

    /// The published privacy, terms and support pages. Rendered on every channel
    /// — a free trial, an expired trial and a paid checkout all show the same
    /// rows — so the policy is reachable without buying first. Each row
    /// is a real tappable `Link` with a 44pt target, not a caption-sized label.
    private var legalLinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Legal & Support")
                .font(NitrateTypography.font(.headline))

            ForEach(LegalLinks.visibleLinks(for: viewModel.settingsChannel)) { link in
                Link(destination: link.url) {
                    HStack {
                        Label(link.title, systemImage: link.systemImage)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(NitrateTypography.font(.footnote))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier(link.accessibilityID)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var appInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(NitrateTypography.font(.headline))

            VStack(alignment: .leading, spacing: 4) {
                Label("Film emulation for iPhone video", systemImage: "movieclapper")
                Label("Apple Log + Metal GPU pipeline", systemImage: "cpu")
                Label("Kodak 250D / 5207 & 500T / 5219", systemImage: "film")
                Label(AboutPresentation.versionLine(), systemImage: "number")
                    .accessibilityIdentifier(AboutPresentation.versionRowID)
            }
            .font(NitrateTypography.font(.caption))
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

#if DEBUG
    /// Mirrors the switches in the debug sheet. They live here too because the
    /// debug sheet is reachable only from the DEBUG button: without this, turning
    /// that button off would leave no way to turn it back on.
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug")
                .font(NitrateTypography.font(.headline))
            Toggle("Show DEBUG button", isOn: $showsDebugButton)
            Toggle("Show FAULT test button", isOn: $showsFaultButton)
            Toggle("Legacy Manual Controls", isOn: legacyManualControlsEnabled)
            Text("The FAULT button previews the recording-failure overlay. "
                 + "Same switches as the debug sheet.")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)
            Text("Shows the previous manual panel for comparison.")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
#endif

#if NITRATE_LOCAL_DEVELOPMENT || NITRATE_EVALUATION_TOOLS
    /// Local-only developer actions. A DevRelease build is a release
    /// configuration (no DEBUG), so these cannot live in `debugSection`, and
    /// nothing here is compiled into a distribution Release.
    private var developmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Development")
                .font(NitrateTypography.font(.headline))
            Button("Restart evaluation") {
                viewModel.restartEvaluation()
            }
            Text("Clears the install anchor so the twenty-day evaluation starts again on this device.")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)
            Button("Expire evaluation") {
                viewModel.expireEvaluation()
            }
            Text("Moves the install anchor past the deadline, so captures arrive without render access.")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
#endif

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.purchaseError != nil },
            set: { if !$0 { viewModel.dismissError() } }
        )
    }
}

// MARK: - Compact settings rows

/// One settings row's information disclosure. Extracted from the view so the
/// collapsed default and the "an info tap only reveals this row's help"
/// semantics are explicit and testable. It carries no persisted preference and
/// is never consulted when a setting changes.
private struct SettingsRowHelpState: Equatable {
    private(set) var isExpanded = false

    mutating func toggle() { isExpanded.toggle() }
}

/// Trailing info button. Carries a >=44pt touch target, a subject-named
/// VoiceOver label and an Expanded/Collapsed value. Its action only reveals the
/// row's help text — it never changes the setting.
private struct SettingsInfoButton: View {
    let subject: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(NitrateTypography.font(.body))
                .foregroundStyle(SettingsControlChrome.lightPurple)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(subject)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// A settings row: a leading icon and label, a trailing control, then a trailing
/// info button. The explanation is revealed inline only below the control, and
/// only while this row's own help state is expanded — each row owns its state,
/// so expanding one row leaves every other row collapsed.
private struct SettingsControlRow<Control: View>: View {
    let icon: String
    let title: String
    let accessibilityTitle: String
    let help: String
    @ViewBuilder var control: () -> Control

    @State private var disclosure = SettingsRowHelpState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                SettingsRowLabel(icon: icon, title: title)
                Spacer(minLength: 8)
                control()
                    .labelsHidden()
                SettingsInfoButton(subject: accessibilityTitle,
                                   isExpanded: disclosure.isExpanded,
                                   action: toggleHelp)
            }
            .frame(minHeight: 44)

            if disclosure.isExpanded {
                Text(help)
                    .font(NitrateTypography.font(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggleHelp() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { disclosure.toggle() }
    }
}

/// A settings row for a binary setting: a leading icon and label, the compact
/// custom switch, then a sibling info button — the button is never nested inside
/// the toggle's label. Its help is revealed below the row.
private struct SettingsToggleRow: View {
    let icon: String
    let title: String
    let accessibilityTitle: String
    let help: String
    @Binding var isOn: Bool

    @State private var disclosure = SettingsRowHelpState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                SettingsRowLabel(icon: icon, title: title)
                Spacer(minLength: 8)
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                SettingsInfoButton(subject: accessibilityTitle,
                                   isExpanded: disclosure.isExpanded,
                                   action: toggleHelp)
            }
            .frame(minHeight: 44)

            if disclosure.isExpanded {
                Text(help)
                    .font(NitrateTypography.font(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggleHelp() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { disclosure.toggle() }
    }
}