import SwiftUI

/// AD-1: Purchase/settings screen — 7-day trial, $5/year, $10 lifetime.
struct PurchaseView: View {
    @State var viewModel: PurchaseViewModel
    @Binding var showFramedPreview: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Trial status
                    trialStatusSection

                    if !viewModel.isPurchased {
                        // Purchase options
                        purchaseOptionsSection
                    } else {
                        purchasedBanner
                    }

                    // Preview mode
                    previewModeSection

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
            if viewModel.isPurchased {
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
                Text("Unlock to continue using FilmEmulation.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var purchaseOptionsSection: some View {
        VStack(spacing: 12) {
            Text("Unlock Full Access")
                .font(.headline)

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
                    Text(viewModel.subscriptionPrice ?? "$5.00")
                        .font(.body.bold())
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

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
                    Text(viewModel.lifetimePrice ?? "$10.00")
                        .font(.body.bold())
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            // Restore purchases
            Button("Restore Purchases") {
                viewModel.restorePurchases()
            }
            .font(.caption)
        }
    }

    // MARK: - Preview Mode

    private var previewModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.headline)

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
                Label("Kodak 250D & 500T", systemImage: "film")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.purchaseError != nil },
            set: { if !$0 { viewModel.dismissError() } }
        )
    }
}