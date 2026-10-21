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
    /// Seeded from the last verified channel so a cold, offline launch does not
    /// briefly lock a beta tester out of capture while StoreKit answers.
    private var distribution: AccessDistribution
    private var firstLaunch: Date?
    private var verifiedPurchases: [VerifiedEntitlement] = []
    private var refreshGeneration: UInt64 = 0

    init() {
        distribution = storeManager.cachedDistribution ?? .unknown
    }

    // MARK: - Observable state (existing settings UI)

    var isTrialActive = false
    var isPurchased = false
    /// True only for a verified lifetime purchase. A yearly subscription is a
    /// renewal, so its copy must not claim "forever".
    var isLifetimePurchased = false
    var daysRemaining = 0
    var subscriptionPrice: String?
    var lifetimePrice: String?
    var purchaseError: String?
    /// Non-nil when StoreKit product loading failed; the UI shows unavailable.
    var productLoadError: String?

    // MARK: - Shared entitlement API

    private(set) var access = AppAccessState.locked

    /// The gate for the paid feature. Rendering the film look is what a
    /// subscription buys; recording Apple Log is always free.
    var canRender: Bool {
        // Enforce expiry at the next render attempt even if no StoreKit
        // transaction event or settings presentation occurred at the deadline.
        AppAccessPolicy.evaluate(distribution: distribution, firstLaunch: firstLaunch,
                                 now: Date(), verifiedEntitlements: verifiedPurchases).canUsePaidFeatures
    }

    var canUsePaidFeatures: Bool { canRender }

    func onSceneActive() {
        Task { await refreshEntitlements() }
    }

    /// True only for a genuine TestFlight/sandbox beta install. Drives the
    /// "unrestricted beta" banner and hides the live monetization CTA.
    var isBetaAccess: Bool { access.isBetaAccess }

    var trialDaysRemaining: Int { access.trialDaysRemaining }

    /// A build that did not come from the App Store: a normal Debug run
    /// (`.debug`) or a locally signed development install (`.development`).
    /// Both are unrestricted, so Settings labels them "Development Build"
    /// instead of a trial that never existed.
    var isDevelopmentBuild: Bool { distribution == .debug || distribution == .development }

    /// The Settings access state the legal/support section renders in. The
    /// section shows the same published links on every channel, so this only
    /// labels which state the screen is in; it never gates the links.
    var settingsChannel: LegalLinks.Channel {
        if isDevelopmentBuild { return .development }
        if isBetaAccess { return .beta }
        if isPurchased { return .purchased }
        if isTrialActive { return .trialActive }
        return .trialExpired
    }

    /// The non-purchasable US launch-pricing block, or `nil` on a checkout
    /// channel (production or the local StoreKit-testing harness) where the live
    /// StoreKit `displayPrice` belongs.
    var launchPricingPreview: LaunchPricingPreview? {
        LaunchPricingPresentation.preview(for: distribution)
    }

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
        // Resolve beta access before product loading. Unconfigured products or
        // a product-server failure must not put a TestFlight tester at checkout.
        await refreshEntitlements()
        if !isBetaAccess {
            await storeManager.loadProducts()
            productLoadError = storeManager.productLoadError
            subscriptionPrice = PurchasePriceText.resolved(storeManager.displayPrice(for: .yearlySubscription))
            lifetimePrice = PurchasePriceText.resolved(storeManager.displayPrice(for: .lifetime))
        }
    }

    private func refreshEntitlements() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let resolved = await storeManager.resolveDistribution()
        let entitlements = resolved == .testFlight || resolved == .debug
            ? [] : await storeManager.verifiedEntitlements()
        guard generation == refreshGeneration else { return }
        distribution = resolved
        firstLaunch = storeManager.firstLaunchDate
        verifiedPurchases = entitlements
        access = AppAccessPolicy.evaluate(
            distribution: resolved,
            firstLaunch: firstLaunch,
            now: Date(),
            verifiedEntitlements: entitlements)

        // Mirror into the existing settings-facing fields.
        isTrialActive = access.trialActive
        isPurchased = access.hasVerifiedPurchase
        isLifetimePurchased = access.hasLifetimePurchase
        daysRemaining = access.trialDaysRemaining

        // One line per resolution: the app has no log file, so this is how the
        // access decision is diagnosed on a device.
        print("[access] channel=\(resolved.rawValue) unrestricted=\(access.isUnrestricted) "
              + "trialActive=\(access.trialActive) trialDaysRemaining=\(access.trialDaysRemaining) "
              + "verifiedPurchases=\(entitlements.count) canUsePaidFeatures=\(access.canUsePaidFeatures)")

        subscriptionPrice = PurchasePriceText.resolved(storeManager.displayPrice(for: .yearlySubscription))
        lifetimePrice = PurchasePriceText.resolved(storeManager.displayPrice(for: .lifetime))
    }
}
