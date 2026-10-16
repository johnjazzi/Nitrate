import Foundation
import Observation

/// AD-1 / L08: `@Observable` owner of entitlement state for the app.
///
/// The app root calls `onAppLaunch()` once; it starts the app-lifetime StoreKit
/// transaction listener and performs the initial refresh. The settings screen's
/// `onAppear`/`onDisappear` remain supported but only refresh — they never stop
/// the global listener, so a background renewal, expiry or refund keeps the
/// shared gate current while the settings screen is closed.
@MainActor
@Observable
final class PurchaseViewModel {
    private let storeManager = StoreManager()
    private var didStart = false

    // MARK: - Observable state (existing settings UI)

    var isTrialActive = false
    var isPurchased = false
    var daysRemaining = 0
    var subscriptionPrice: String?
    var lifetimePrice: String?
    var purchaseError: String?
    /// Non-nil when StoreKit product loading failed; the UI shows unavailable.
    var productLoadError: String?

    // MARK: - Shared entitlement API

    private(set) var access = AppAccessState.locked

    /// The single gate the app uses to admit paid features (capture/render).
    var canUsePaidFeatures: Bool { access.canUsePaidFeatures }

    /// True only for a genuine TestFlight/sandbox beta install. Drives the
    /// "unrestricted beta" banner and hides the live monetization CTA.
    var isBetaAccess: Bool { access.isBetaAccess }

    var trialDaysRemaining: Int { access.trialDaysRemaining }

    /// Products have not loaded, so prices must render as unavailable.
    var pricesUnavailable: Bool {
        subscriptionPrice == nil && lifetimePrice == nil
    }

    // MARK: - Lifecycle

    /// Idempotent app-lifetime entry point. Safe to call more than once.
    func onAppLaunch() {
        guard !didStart else { return }
        didStart = true
        storeManager.startTransactionListener { [weak self] in
            await self?.refreshEntitlements()
        }
        Task { await loadState() }
    }

    /// Settings appearance: refresh only. Does not touch the global listener.
    func onAppear() {
        Task { await loadState() }
    }

    /// Settings dismissal: intentionally a no-op. Entitlement observation is
    /// app-lifetime and must not stop when the settings screen closes.
    func onDisappear() {}

    // MARK: - Actions

    func purchaseSubscription() {
        purchase(.yearlySubscription)
    }

    func purchaseLifetime() {
        purchase(.lifetime)
    }

    func restorePurchases() {
        Task {
            do {
                try await storeManager.restore()
                await refreshEntitlements()
            } catch {
                purchaseError = error.localizedDescription
            }
        }
    }

    /// Retry a failed product load and refresh the displayed prices.
    func retryLoadProducts() {
        Task { await loadState() }
    }

    func dismissError() {
        purchaseError = nil
    }

    // MARK: - Private

    private func purchase(_ product: PaidProduct) {
        Task {
            do {
                switch try await storeManager.purchase(product) {
                case .purchased:
                    await refreshEntitlements()
                case .pending:
                    purchaseError = "Your purchase is pending approval."
                case .cancelled:
                    break
                }
            } catch {
                purchaseError = error.localizedDescription
            }
        }
    }

    private func loadState() async {
        await storeManager.loadProducts()
        productLoadError = storeManager.productLoadError
        await refreshEntitlements()
    }

    private func refreshEntitlements() async {
        let distribution = await storeManager.resolveDistribution()
        let entitlements = await storeManager.verifiedEntitlements()
        access = AppAccessPolicy.evaluate(
            distribution: distribution,
            firstLaunch: storeManager.firstLaunchDate,
            now: Date(),
            verifiedEntitlements: entitlements)

        // Mirror into the existing settings-facing fields.
        isTrialActive = access.trialActive
        isPurchased = access.hasVerifiedPurchase
        daysRemaining = access.trialDaysRemaining

        subscriptionPrice = PurchasePriceText.resolved(storeManager.displayPrice(for: .yearlySubscription))
        lifetimePrice = PurchasePriceText.resolved(storeManager.displayPrice(for: .lifetime))
    }
}
