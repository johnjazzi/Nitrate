import Foundation
import StoreKit
import UIKit

/// CAP-9 / L08: StoreKit 2 purchase and verified-entitlement source.
///
/// This type owns every StoreKit call and reduces the results to the pure
/// `AppAccessPolicy` inputs (`AccessDistribution` + `[VerifiedEntitlement]`).
/// It never derives access from a user-editable flag: the distribution channel
/// comes from the App Store-signed `AppTransaction`, and purchases only count
/// when the transaction verifies against a known product. A missing receipt is
/// not evidence of anything — it must never unlock paid features.
@MainActor
final class StoreManager {
    static let yearlySubscriptionID = PaidProduct.yearlySubscription.rawValue
    static let lifetimeID = PaidProduct.lifetime.rawValue

    /// Legacy persistence key; the local 20-day evaluation window is anchored to
    /// it and kept for compatibility with installs that already recorded it.
    static let installDateKey = "install_date"

    /// The last verified install channel. Used only when this launch cannot reach
    /// the App Store. It records a StoreKit-verified channel (`.sandbox` or
    /// `.appStore`), never a user-set preference or a development unlock.
    static let distributionCacheKey = "resolved_access_distribution"

    /// True only when this binary was compiled for local development
    /// (`NITRATE_LOCAL_DEVELOPMENT`, set by the DevRelease configuration) or as a
    /// Debug build. No App Store or TestFlight submission contains the flag, so
    /// neither can resolve `.development`.
    static var localDevelopmentEnabled: Bool {
        #if DEBUG || NITRATE_LOCAL_DEVELOPMENT
        return true
        #else
        return false
        #endif
    }

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
    /// A Debug build resolves through the compile-time override (unrestricted, or
    /// the StoreKit-testing fixture when requested). A Release build asks StoreKit
    /// and maps the verified environment; a sandbox environment — TestFlight and
    /// App Review — stays gated exactly like production.
    func resolveDistribution() async -> AccessDistribution {
        // Local modes must not wait for StoreKit or trigger account prompts.
        // Neither bypass is compiled into the production Release configuration.
        if let debugOverride = debugDistributionOverride { return debugOverride }
        if Self.localDevelopmentEnabled { return .development }
        let environment = await storeEnvironment()
        let current = AppAccessPolicy.distribution(
            environment: environment,
            debugOverride: debugDistributionOverride,
            localDevelopmentEnabled: Self.localDevelopmentEnabled)
        let resolved = AppAccessPolicy.resolvedChannel(current: current, cached: cachedDistribution)
        if resolved.isCacheable {
            UserDefaults.standard.set(resolved.rawValue, forKey: Self.distributionCacheKey)
        }
        return resolved
    }

    /// The Debug-only compile-time decision. `nil` in every non-Debug build, so a
    /// release submission can never honour a launch argument.
    private var debugDistributionOverride: AccessDistribution? {
        #if DEBUG
        return AppAccessPolicy.debugChannelOverride(
            isDebugBuild: true,
            storeKitTestingRequested: StoreKitTestingLaunchMode.isRequested(
                arguments: ProcessInfo.processInfo.arguments))
        #else
        return nil
        #endif
    }

    /// The last verified, cacheable channel, or `nil`. A cached `.debug` or
    /// `.development` is rejected outright, and the legacy `testFlight` raw value
    /// is rewritten to `.sandbox` when it is read.
    var cachedDistribution: AccessDistribution? {
        let raw = UserDefaults.standard.string(forKey: Self.distributionCacheKey)
        guard let cached = AppAccessPolicy.cachedChannel(fromPersistedRawValue: raw) else {
            return nil
        }
        if raw != cached.rawValue {
            UserDefaults.standard.set(cached.rawValue, forKey: Self.distributionCacheKey)
        }
        return cached
    }

    /// The verified StoreKit environment, or `nil` when the App Store could not
    /// answer. It always attempts `AppTransaction.shared`; there is no receipt
    /// check, because a missing receipt must not decide access either way.
    private func storeEnvironment() async -> StoreEnvironmentInput? {
        do {
            switch try await AppTransaction.shared {
            case .verified(let appTransaction):
                switch appTransaction.environment {
                case .production:
                    return .production
                case .sandbox:
                    return .sandbox
                case .xcode:
                    return .xcode
                default:
                    return .unknown
                }
            case .unverified:
                return nil
            }
        } catch {
            // App Transaction needs the App Store to answer; an offline or
            // unauthenticated launch is unresolved, not a free grant.
            return nil
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

    /// Present Apple's offer-code redemption sheet. StoreKit owns the sheet and
    /// creates the transaction; the caller refreshes entitlements once it
    /// returns. The iOS 27 `from:options:` form replaces the deprecated
    /// `in: UIWindowScene` overload, so this walks to the presented controller.
    /// A nil host is a real failure rather than a silent no-op.
    func presentOfferCodeRedeemSheet() async throws {
        guard let host = Self.offerCodeHostController() else {
            throw PurchaseError.offerCodeUnavailable
        }
        _ = try await AppStore.presentOfferCodeRedeemSheet(from: host)
    }

    private static func offerCodeHostController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
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
    case offerCodeUnavailable

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return "That product is not available right now."
        case .verificationFailed:
            return "The App Store could not verify this purchase."
        case .restoreFailed(let message):
            return "Restore failed: \(message)"
        case .offerCodeUnavailable:
            return "Offer code redemption is unavailable right now. Try again from Settings."
        }
    }
}
