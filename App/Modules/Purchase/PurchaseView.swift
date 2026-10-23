import SwiftUI

/// AD-1: Purchase/settings screen — 7-day trial, $4.99/year, $9.99 lifetime.
struct PurchaseView: View {
    @State var viewModel: PurchaseViewModel
    @Binding var showFramedPreview: Bool
    /// Live session switches owned by the camera screen. They default off and
    /// never persist across a launch; a preview or a constructor that omits them
    /// falls back to a constant `false`, so nothing here writes a preference.
    var manualFocusEnabled: Binding<Bool> = .constant(false)
    var zoomControlsEnabled: Binding<Bool> = .constant(false)
    @State private var pricingExpanded = false
    @State private var legalExpanded = false
    @AppStorage(RecordingIndicatorStyle.preferenceKey) private var recordingIndicatorStyle = RecordingIndicatorStyle.red.rawValue
    @AppStorage(CameraPreviewMode.preferenceKey) private var previewMode = CameraPreviewMode.neutral.rawValue
    @AppStorage(DeliverySettings.saveOriginalLogKey) private var saveOriginalLog = false
    @AppStorage(DeliverySettings.renderQualityKey) private var renderQuality = RenderExportQuality.high.rawValue
    @AppStorage(RecordButtonAppearance.preferenceKey) private var recordButtonAppearance = RecordButtonAppearance.classic.rawValue
#if DEBUG
    @AppStorage(DebugControlPreferences.showsDebugButtonKey) private var showsDebugButton = true
    @AppStorage(DebugControlPreferences.showsFaultButtonKey) private var showsFaultButton = true
#endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Trial status
                    trialStatusSection

                    // Preview mode
                    previewModeSection
                    exportSection

#if DEBUG
                    debugSection
#endif

                    // App info
                    appInfoSection
                    pricingDisclosure
                    legalDisclosure
                }
                .padding()
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
            if let preview = viewModel.launchPricingPreview {
                launchPricingPreview(preview)
            } else if !viewModel.isPurchased {
                purchaseOptionsSection
                // Keep terms and privacy reachable alongside checkout.
                legalLinksSection
            } else {
                purchasedBanner
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var legalDisclosure: some View {
        DisclosureGroup("Legal & Support", isExpanded: $legalExpanded) {
            legalLinksSection
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var trialStatusSection: some View {
        VStack(spacing: 8) {
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
            } else if viewModel.isBetaAccess {
                Image(systemName: "testtube.2")
                    .font(NitrateTypography.font(.largeTitle))
                    .foregroundStyle(.tint)
                Text("Unrestricted Beta")
                    .font(NitrateTypography.font(.title2).bold())
                Text("Film rendering is unlocked during the beta. No purchase or checkout is required.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if viewModel.isPurchased {
                Image(systemName: "checkmark.seal.fill")
                    .font(NitrateTypography.font(.largeTitle))
                    .foregroundStyle(.green)
                Text("Unlocked")
                    .font(NitrateTypography.font(.title2).bold())
            } else if viewModel.isTrialActive {
                Image(systemName: "clock.badge.checkmark")
                    .font(NitrateTypography.font(.largeTitle))
                    .foregroundStyle(.tint)
                Text("Free Trial")
                    .font(NitrateTypography.font(.title2).bold())
                Text("\(viewModel.daysRemaining) days remaining")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "lock.fill")
                    .font(NitrateTypography.font(.largeTitle))
                    .foregroundStyle(.secondary)
                Text("Trial Expired")
                    .font(NitrateTypography.font(.title2).bold())
                Text("Unlock film rendering to continue. Recording stays free.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The non-purchasable price information for an unrestricted channel
    /// (development/DEBUG and the TestFlight beta). It carries the owner-approved
    /// US launch amounts and states that recording stays free and the tester is
    /// not charged; there is deliberately no checkout button here, because this
    /// copy is not a fallback purchase price.
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

            // Restore purchases
            Button("Restore Purchases") {
                viewModel.restorePurchases()
            }
            .font(NitrateTypography.font(.caption))
        }
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

    private var previewModeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(NitrateTypography.font(.headline))

            SettingsControlRow(icon: "camera.filters",
                               title: "Preview Color",
                               accessibilityTitle: "Preview color",
                               help: "Recording uses Apple Log 2. Film effects are applied after recording. "
                                   + "An unavailable preview look shows a warning and falls back to Log.") {
                SettingsSelectionRow(title: "Preview Color",
                                     valueText: previewModeTitle(CameraPreviewMode.resolved(previewMode))) {
                    Picker("Preview Color", selection: Binding(
                        get: { CameraPreviewMode.resolved(previewMode) },
                        set: { previewMode = $0.rawValue })) {
                        Text("Neutral").tag(CameraPreviewMode.neutral)
                        Text("Stock LUT").tag(CameraPreviewMode.stock)
                        Text("Log").tag(CameraPreviewMode.log)
                    }
                }
            }

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
                              title: "Save Original Log to Photos",
                              accessibilityTitle: "Save Original Log",
                              help: "Saves an additional, ungraded Apple Log 2 recording to Photos and uses more storage.",
                              isOn: $saveOriginalLog)
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
    /// — a free trial, an expired trial, a paid checkout and the beta all show
    /// the same rows — so the policy is reachable without buying first. Each row
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
            Text("The FAULT button previews the recording-failure overlay. "
                 + "Same switches as the debug sheet.")
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