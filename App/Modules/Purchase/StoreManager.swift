import Foundation
import StoreKit

/// CAP-9 / L08: StoreKit 2 purchase and verified-entitlement source.
///
/// This type owns every StoreKit call and reduces the results to the pure
/// `AppAccessPolicy` inputs (`AccessDistribution` + `[VerifiedEntitlement]`).
/// It never derives access from a user-editable flag: the distribution channel
/// comes from the App Store-signed `AppTransaction`, and purchases only count
/// when the transaction verifies against a known product.
@MainActor
final class StoreManager {
    static let yearlySubscriptionID = PaidProduct.yearlySubscription.rawValue
    static let lifetimeID = PaidProduct.lifetime.rawValue

    /// Legacy persistence key; the local 7-day evaluation window is anchored to
    /// it and kept for compatibility with installs that already recorded it.
    static let installDateKey = "install_date"

    /// The last verified install channel. Used only when this launch cannot reach
    /// the App Store, so an offline TestFlight tester is not locked out of
    /// capture. It records a StoreKit-verified fact, not a user-set preference.
    static let distributionCacheKey = "resolved_access_distribution"

    private(set) var products: [Product] = []
    /// Non-nil when the last product load failed; surfaced so the UI can show an
    /// unavailable state instead of hardcoded prices.
    private(set) var productLoadError: String?

    private var updatesTask: Task<Void, Never>?
    private var transactionHandler: (@MainActor () async -> Void)?

    // MARK: - Observation

    /// Start the app-lifetime transaction listener. Idempotent: a second call is
    /// ignored so the listener cannot be duplicated or torn down by a view.
    func startTransactionListener(_ handler: @escaping @MainActor () async -> Void) {
        guard updatesTask == nil else {
            transactionHandler = handler
            return
        }
        transactionHandler = handler
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                await self?.transactionHandler?()
            }
        }
    }

    /// Explicit teardown for app termination only. Deliberately not called when
    /// the settings screen disappears — entitlement updates are app-lifetime.
    func stopTransactionListener() {
        updatesTask?.cancel()
        updatesTask = nil
        transactionHandler = nil
    }

    // MARK: - Entitlement snapshot

    /// The distribution channel resolved from the App Store-signed app
    /// transaction, falling back to the last verified channel when the store
    /// cannot answer (offline launch).
    ///
    /// A Debug build is unrestricted by default. A Debug build launched with the
    /// explicit StoreKit-testing argument (the dedicated `NitrateStoreKitTest`
    /// scheme) is resolved straight to `.storeKitTesting` — bypassing the
    /// receipt-guard fall-through, which would otherwise return `.development`
    /// (a free unlock) because a Debug build has no App Store receipt. The real
    /// local StoreKit configuration then drives purchase and entitlement reads,
    /// so evaluation, purchase, expiry and refund can be exercised. A Release
    /// build never honours that override: the store decides, exactly as before.
    func resolveDistribution() async -> AccessDistribution {
        #if DEBUG
        if let debugOverride = AppAccessPolicy.debugChannelOverride(
            isDebugBuild: true,
            storeKitTestingRequested: StoreKitTestingLaunchMode.isRequested(
                arguments: ProcessInfo.processInfo.arguments)) {
            return debugOverride
        }
        #endif
        let current = await verifiedDistribution()
        let resolved = AppAccessPolicy.resolvedChannel(current: current, cached: cachedDistribution)
        if resolved.isCacheable {
            UserDefaults.standard.set(resolved.rawValue, forKey: Self.distributionCacheKey)
        }
        return resolved
    }

    var cachedDistribution: AccessDistribution? {
        UserDefaults.standard.string(forKey: Self.distributionCacheKey)
            .flatMap(AccessDistribution.init(rawValue:))
    }

    private func verifiedDistribution() async -> AccessDistribution {
        // A build with no App Store receipt did not come from the App Store: a
        // development install or a locally signed Release build. App Store
        // installs always carry a receipt, so this cannot unlock a real
        // customer. It is also what keeps the developer unblocked without a
        // personal subscription.
        //
        // `appStoreReceiptURL` is deprecated in iOS 18 in favour of
        // `AppTransaction.shared`, and this call is deliberately NOT migrated
        // yet. The receipt check is the only thing standing between an
        // unresolved launch and `.development`, and `.development` grants
        // unrestricted access. If `AppTransaction.shared` throws for an offline
        // App Store install as well as for a receipt-less development build,
        // collapsing the two into one `catch` would hand every offline
        // production user the paid features for free. That distinction can only
        // be verified against a real App Store install, which does not exist
        // until the app ships; `#if DEBUG` short-circuits before this code, so a
        // local build cannot exercise it either. Migrate after launch, verified.
        guard let receiptURL = Bundle.main.appStoreReceiptURL,
              FileManager.default.fileExists(atPath: receiptURL.path) else {
            return .development
        }
        do {
            switch try await AppTransaction.shared {
            case .verified(let appTransaction):
                let environment = appTransaction.environment
                if environment == .production { return .appStore }
                if environment == .sandbox { return .testFlight }
                // `.xcode` means a local StoreKit configuration file is active.
                // Exercise the real paywall rather than a free unlock.
                if environment == .xcode { return .storeKitTesting }
                return .unknown
            case .unverified:
                return .unknown
            }
        } catch {
            // App Transaction needs the App Store to answer; an offline or
            // unauthenticated launch is "unknown", not a free grant.
            return .unknown
        }
    }

    /// Verified, current entitlements reduced to the policy input. Unverified
    /// results are dropped; expiry and revocation are carried through so the
    /// pure policy can reject them.
    func verifiedEntitlements() async -> [VerifiedEntitlement] {
        var entitlements: [VerifiedEntitlement] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            entitlements.append(VerifiedEntitlement(
                productID: transaction.productID,
                expirationDate: transaction.expirationDate,
                revocationDate: transaction.revocationDate))
        }
        return entitlements
    }

    /// First-launch anchor for the local trial evaluation. Recorded once and
    /// reused; the policy treats a missing value as "no trial".
    var firstLaunchDate: Date? {
        if let stored = UserDefaults.standard.object(forKey: Self.installDateKey) as? Date {
            return stored
        }
        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.installDateKey)
        return now
    }

    // MARK: - Products

    /// Load the shipped products. A failure clears the cache and records the
    /// error so the purchase screen can offer a retry.
    func loadProducts() async {
        do {
            products = try await Product.products(for: [Self.yearlySubscriptionID, Self.lifetimeID])
            productLoadError = nil
        } catch {
            products = []
            productLoadError = error.localizedDescription
        }
    }

    /// Localized `Product.displayPrice`, or `nil` until the product has loaded.
    func displayPrice(for product: PaidProduct) -> String? {
        products.first { $0.id == product.rawValue }?.displayPrice
    }

    // MARK: - Purchase

    /// Purchase a product. Returns a real outcome; an unverified transaction
    /// throws rather than reporting success.
    func purchase(_ product: PaidProduct) async throws -> PurchaseOutcome {
        guard let storeProduct = products.first(where: { $0.id == product.rawValue }) else {
            throw PurchaseError.productNotFound
        }
        let result = try await storeProduct.purchase()
        switch result {
        case .success(.verified(let transaction)):
            await transaction.finish()
            return .purchased
        case .success(.unverified):
            throw PurchaseError.verificationFailed
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            throw PurchaseError.verificationFailed
        }
    }

    /// `AppStore.sync()` is called only for an explicit user-initiated Restore.
    func restore() async throws {
        do {
            try await AppStore.sync()
        } catch {
            throw PurchaseError.restoreFailed(error.localizedDescription)
        }
    }
}

/// The outcome of a purchase attempt. `purchased` is the only success.
enum PurchaseOutcome: Equatable {
    case purchased
    case cancelled
    case pending
}

enum PurchaseError: LocalizedError {
    case productNotFound
    case verificationFailed
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return "That product is not available right now."
        case .verificationFailed:
            return "The App Store could not verify this purchase."
        case .restoreFailed(let message):
            return "Restore failed: \(message)"
        }
    }
}
