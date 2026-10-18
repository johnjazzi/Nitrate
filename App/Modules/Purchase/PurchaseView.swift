import SwiftUI

/// AD-1: Purchase/settings screen — 7-day trial, $5/year, $10 lifetime.
struct PurchaseView: View {
    @State var viewModel: PurchaseViewModel
    @Binding var showFramedPreview: Bool
    @AppStorage(RecordingIndicatorStyle.preferenceKey) private var recordingIndicatorStyle = RecordingIndicatorStyle.red.rawValue
    @AppStorage(CameraPreviewMode.preferenceKey) private var previewMode = CameraPreviewMode.neutral.rawValue
    @AppStorage(DeliverySettings.saveOriginalLogKey) private var saveOriginalLog = false
    @AppStorage(DeliverySettings.renderQualityKey) private var renderQuality = RenderExportQuality.high.rawValue
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

                    if viewModel.isBetaAccess || viewModel.isDevelopmentAccess {
                        betaBanner
                    } else if !viewModel.isPurchased {
                        // Purchase options
                        purchaseOptionsSection
                    } else {
                        purchasedBanner
                    }

                    // Preview mode
                    previewModeSection
                    exportSection

#if DEBUG
                    debugSection
#endif

                    // App info
                    appInfoSection
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

    private var trialStatusSection: some View {
        VStack(spacing: 8) {
            if viewModel.isDevelopmentAccess {
                Image(systemName: "hammer.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("Development Build")
                    .font(.title2.bold())
                Text("This build did not come from the App Store, so every feature is unlocked. "
                     + "Customers installing from the App Store are unaffected.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if viewModel.isBetaAccess {
                Image(systemName: "testtube.2")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("Unrestricted Beta")
                    .font(.title2.bold())
                Text("Every feature is unlocked during the beta. No purchase or checkout is required.")
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
                Text("Unlock to continue using \(AppIdentity.name).")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Beta installs run without monetization: the live purchase CTA is hidden
    /// entirely so a tester is never asked to check out.
    private var betaBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "infinity.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Beta access")
                    .font(.headline)
                Text("You are testing an unrestricted beta build. All paid features are enabled and no purchase is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var purchaseOptionsSection: some View {
        VStack(spacing: 12) {
            Text("Unlock Full Access")
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
                        Text("Full access, cancel anytime")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(viewModel.subscriptionPrice ?? PurchasePriceText.unavailable)
                        .font(.body.bold())
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
                        Text("One-time purchase, forever access")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(viewModel.lifetimePrice ?? PurchasePriceText.unavailable)
                        .font(.body.bold())
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.headline)

            Picker("Preview Color", selection: Binding(
                get: { CameraPreviewMode.resolved(previewMode) },
                set: { previewMode = $0.rawValue })) {
                Text("Neutral").tag(CameraPreviewMode.neutral)
                Text("Stock LUT").tag(CameraPreviewMode.stock)
                Text("Log").tag(CameraPreviewMode.log)
            }
            Text("Neutral is the default monitor; Stock LUT uses the selected film look; Log is ungraded. Preview only, with no grain, halation, or glow. Recording stays Apple Log 2; film effects are applied after capture. If a preview LUT is unavailable, the monitor shows Log with a warning.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Recording Indicator", selection: Binding(
                get: { RecordingIndicatorStyle.resolved(recordingIndicatorStyle) },
                set: { recordingIndicatorStyle = $0.rawValue })) {
                ForEach(RecordingIndicatorStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Text("Top status lamp and elapsed timer only. WAIT means capture is not yet confirmed; REC confirms capture; STOP freezes the timer while finalizing. The physical REC button stays red.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(isOn: $showFramedPreview) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Frame Mode")
                    Text("Viewfinder-style preview with visible controls")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export").font(.headline)
            Toggle("Save Original Log to Photos", isOn: $saveOriginalLog)
            Text("Saves the ungraded original recording alongside the rendered video; uses additional storage. Not sensor RAW.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Rendered File Size", selection: exportQualityBinding) {
                ForEach(RenderExportQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            Text("High: 60 Mbps. Smaller: 30 Mbps — roughly half the video bitrate, not an exact file-size reduction; may soften grain. Resolution and frame rate are unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Changes apply only to newly queued clips, not existing jobs or retries.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("All features unlocked forever")
                .foregroundStyle(.secondary)
        }
    }

    private var appInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Label("Film emulation for iPhone video", systemImage: "movieclapper")
                Label("Apple Log + Metal GPU pipeline", systemImage: "cpu")
                Label("Kodak 250D / 5207 & 500T / 5219", systemImage: "film")
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