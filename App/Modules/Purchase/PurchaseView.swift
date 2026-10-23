import SwiftUI

/// AD-1: Purchase/settings screen — 7-day trial, $4.99/year, $9.99 lifetime.
struct PurchaseView: View {
    @State var viewModel: PurchaseViewModel
    @Binding var showFramedPreview: Bool
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
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("Development Build")
                    .font(.title2.bold())
                Text("This build did not come from the App Store, so film rendering is unlocked for free. "
                     + "Customers installing from the App Store are unaffected.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if viewModel.isBetaAccess {
                Image(systemName: "testtube.2")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("Unrestricted Beta")
                    .font(.title2.bold())
                Text("Film rendering is unlocked during the beta. No purchase or checkout is required.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if viewModel.isPurchased {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("Unlocked")
                    .font(.title2.bold())
            } else if viewModel.isTrialActive {
                Image(systemName: "clock.badge.checkmark")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("Free Trial")
                    .font(.title2.bold())
                Text("\(viewModel.daysRemaining) days remaining")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Trial Expired")
                    .font(.title2.bold())
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
                .font(.headline)
            priceRow(title: "Yearly",
                     detail: "Film rendering, renews yearly",
                     price: preview.yearlyPrice, billing: "per year")
            priceRow(title: "Lifetime",
                     detail: "One-time purchase, film rendering forever",
                     price: preview.lifetimePrice, billing: "one time")
            Text(preview.footnote)
                .font(.caption)
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
                    .font(.body.bold())
                Text(detail)
                    .font(.caption)
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
            Text(amount).font(.body.bold())
            Text(billing).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var purchaseOptionsSection: some View {
        VStack(spacing: 12) {
            Text("Unlock Film Rendering")
                .font(.headline)

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
                            .font(.body.bold())
                        Text("Film rendering, cancel anytime")
                            .font(.caption)
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
                            .font(.body.bold())
                        Text("One-time purchase, film rendering forever")
                            .font(.caption)
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
            .font(.caption)
        }
    }

    /// L12: a real product-load failure is shown, never masked by a fallback
    /// price. Recovery is an explicit retry.
    private func productUnavailableNotice(detail: String) -> some View {
        VStack(spacing: 6) {
            Text("In-app purchases are unavailable")
                .font(.footnote.bold())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                viewModel.retryLoadProducts()
            }
            .font(.caption)
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
                .font(.headline)

            SettingsControlRow(title: "Preview Color",
                               accessibilityTitle: "Preview color",
                               help: "Monitor only, never recorded — film effects are applied after capture. "
                                   + "Recording stays Apple Log 2. If a preview LUT is unavailable, the "
                                   + "monitor shows Log with a warning.") {
                Picker("Preview Color", selection: Binding(
                    get: { CameraPreviewMode.resolved(previewMode) },
                    set: { previewMode = $0.rawValue })) {
                    Text("Neutral").tag(CameraPreviewMode.neutral)
                    Text("Stock LUT").tag(CameraPreviewMode.stock)
                    Text("Log").tag(CameraPreviewMode.log)
                }
                .pickerStyle(.segmented)
            }

            SettingsControlRow(title: "Recording Indicator",
                               accessibilityTitle: "Recording indicator",
                               help: "Top status lamp and elapsed timer only. WAIT: capture not yet confirmed. "
                                   + "REC: capture confirmed. STOP: timer frozen while finalizing.") {
                Picker("Recording Indicator", selection: Binding(
                    get: { RecordingIndicatorStyle.resolved(recordingIndicatorStyle) },
                    set: { recordingIndicatorStyle = $0.rawValue })) {
                    ForEach(RecordingIndicatorStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            SettingsControlRow(title: "Record button",
                               accessibilityTitle: "Record button appearance",
                               help: "Classic is raised. Modern is flat with a red outline. Both use the same "
                                   + "recording controls.") {
                Picker("Record button", selection: Binding(
                    get: { RecordButtonAppearance.resolved(recordButtonAppearance) },
                    set: { recordButtonAppearance = $0.rawValue })) {
                    ForEach(RecordButtonAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            SettingsToggleRow(title: "Frame Mode",
                              accessibilityTitle: "Frame Mode",
                              help: "Viewfinder-style preview with visible controls.",
                              isOn: $showFramedPreview)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.headline)
            SettingsToggleRow(title: "Save Original Log to Photos",
                              accessibilityTitle: "Save Original Log",
                              help: "Saves the ungraded original recording alongside the rendered video; uses "
                                  + "additional storage. Not sensor RAW.",
                              isOn: $saveOriginalLog)
            SettingsControlRow(title: "Rendered File Size",
                               accessibilityTitle: "Rendered file size",
                               help: "High: 60 Mbps. Smaller: 30 Mbps — about half the video bitrate, not an "
                                   + "exact file-size cut; may soften grain. Resolution and frame rate are "
                                   + "unchanged. Changes apply only to newly queued clips, not existing jobs "
                                   + "or retries.") {
                Picker("Rendered File Size", selection: exportQualityBinding) {
                    ForEach(RenderExportQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
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
                .font(.headline)

            ForEach(LegalLinks.visibleLinks(for: viewModel.settingsChannel)) { link in
                Link(destination: link.url) {
                    HStack {
                        Label(link.title, systemImage: link.systemImage)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
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
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Label("Film emulation for iPhone video", systemImage: "movieclapper")
                Label("Apple Log + Metal GPU pipeline", systemImage: "cpu")
                Label("Kodak 250D / 5207 & 500T / 5219", systemImage: "film")
                Label(AboutPresentation.versionLine(), systemImage: "number")
                    .accessibilityIdentifier(AboutPresentation.versionRowID)
            }
            .font(.caption)
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
                .font(.headline)
            Toggle("Show DEBUG button", isOn: $showsDebugButton)
            Toggle("Show FAULT test button", isOn: $showsFaultButton)
            Text("The FAULT button previews the recording-failure overlay. "
                 + "Same switches as the debug sheet.")
                .font(.caption)
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
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(subject)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// A short label with a trailing info button and a control beneath it. The
/// explanation is revealed inline only below the control, and only while this
/// row's own help state is expanded — each row owns its state, so expanding one
/// row leaves every other row collapsed.
private struct SettingsControlRow<Control: View>: View {
    let title: String
    let accessibilityTitle: String
    let help: String
    @ViewBuilder var control: () -> Control

    @State private var disclosure = SettingsRowHelpState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                SettingsInfoButton(subject: accessibilityTitle,
                                   isExpanded: disclosure.isExpanded,
                                   action: toggleHelp)
            }
            .frame(minHeight: 44)

            control()
                .labelsHidden()

            if disclosure.isExpanded {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggleHelp() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { disclosure.toggle() }
    }
}

/// A short label with an inline switch and a sibling info button — the button is
/// never nested inside the toggle's label. Its help is revealed below the row.
private struct SettingsToggleRow: View {
    let title: String
    let accessibilityTitle: String
    let help: String
    @Binding var isOn: Bool

    @State private var disclosure = SettingsRowHelpState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                SettingsInfoButton(subject: accessibilityTitle,
                                   isExpanded: disclosure.isExpanded,
                                   action: toggleHelp)
            }
            .frame(minHeight: 44)

            if disclosure.isExpanded {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggleHelp() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { disclosure.toggle() }
    }
}