import Foundation

// MARK: - Distribution channel

/// How this installation was obtained. Resolved once from a verified StoreKit
/// `AppTransaction.environment` (or the compile-time `#if DEBUG` build) and never
/// from a user-editable preference — a defaults flag or a blanket Release bypass
/// would let a production user self-grant paid access.
///
/// Apple's documented mapping (StoreKit `AppStore.Environment`):
/// - `.production` → `.appStore` (installed from the App Store)
/// - `.sandbox`    → `.testFlight` (installed through TestFlight)
/// - `.xcode`      → `.unknown` (a local StoreKit-testing build we do not treat
///                   as a paid or beta customer)
enum AccessDistribution: String, Sendable, CaseIterable {
    case debug
    /// A locally signed build with no App Store receipt: a development install.
    /// App Store installs always carry a receipt, so this cannot unlock a real
    /// customer.
    case development
    case testFlight
    case appStore
    case unknown

    /// Only a genuinely verified install channel is worth remembering. `unknown`
    /// means the App Store could not answer, not that the app is production.
    var isCacheable: Bool { self == .testFlight || self == .appStore }
}

// MARK: - Products

/// The two paid products the app can grant. Raw values are the shipped App Store
/// product identifiers and must stay in sync with the App Store Connect record.
enum PaidProduct: String, Sendable, CaseIterable {
    case yearlySubscription = "com.nitrate.subscription.yearly"
    case lifetime = "com.nitrate.lifetime"

    /// The product a StoreKit transaction corresponds to, or `nil` for an
    /// unexpected identifier that must not grant access.
    static func expected(for productID: String) -> PaidProduct? {
        PaidProduct(rawValue: productID)
    }
}

/// A single verified current entitlement reduced to what the policy needs.
/// Produced only from `VerificationResult.verified` transactions; unverified
/// results are dropped by the StoreKit layer before reaching here.
struct VerifiedEntitlement: Equatable, Sendable {
    let productID: String
    /// Renewal/expiry instant for a subscription; `nil` for a non-expiring
    /// (lifetime) purchase.
    let expirationDate: Date?
    /// Set when the App Store revoked the purchase (refund/chargeback).
    let revocationDate: Date?

    init(productID: String, expirationDate: Date? = nil, revocationDate: Date? = nil) {
        self.productID = productID
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
    }
}

// MARK: - Result

/// The evaluated access state. `canUsePaidFeatures` is the single shared gate
/// the app uses to admit capture/render; `isBetaAccess` drives the beta banner
/// and hides the live monetization CTA.
struct AppAccessState: Equatable, Sendable {
    let canUsePaidFeatures: Bool
    let isBetaAccess: Bool
    let isUnrestricted: Bool
    let trialActive: Bool
    let trialDaysRemaining: Int
    let hasVerifiedPurchase: Bool

    static let locked = AppAccessState(
        canUsePaidFeatures: false,
        isBetaAccess: false,
        isUnrestricted: false,
        trialActive: false,
        trialDaysRemaining: 0,
        hasVerifiedPurchase: false)
}

// MARK: - Policy

/// Pure, synchronous entitlement policy. No StoreKit, no UserDefaults, no clock
/// of its own — every input is passed in so the whole decision is deterministic
/// and testable off-device.
enum AppAccessPolicy {
    static let trialDuration: TimeInterval = 7 * 24 * 60 * 60
    static let trialDayCount = 7

    /// A channel that could not be resolved this launch keeps the last verified
    /// channel. Without this, an offline TestFlight tester is locked out of
    /// capture because the App Store could not answer; a production user is
    /// unaffected because `.appStore` still requires trial or a verified buy.
    static func resolvedChannel(current: AccessDistribution,
                               cached: AccessDistribution?) -> AccessDistribution {
        current == .unknown ? (cached ?? .unknown) : current
    }

    static func evaluate(distribution: AccessDistribution,
                         firstLaunch: Date?,
                         now: Date,
                         verifiedEntitlements: [VerifiedEntitlement]) -> AppAccessState {
        let isBeta = distribution == .testFlight
        // Debug builds, genuine TestFlight betas and local development installs
        // are unrestricted. Production and unresolved channels must earn access
        // via trial or a verified buy.
        let isUnrestricted = distribution == .debug || distribution == .development || isBeta

        let hasVerifiedPurchase = verifiedEntitlements.contains { entitlement in
            guard let product = PaidProduct.expected(for: entitlement.productID),
                  entitlement.revocationDate == nil else { return false }
            if product == .yearlySubscription {
                guard let expiration = entitlement.expirationDate, expiration > now else { return false }
            } else if let expiration = entitlement.expirationDate, expiration <= now {
                return false
            }
            return true
        }

        let trialActive: Bool
        let daysRemaining: Int
        if let firstLaunch, firstLaunch <= now {
            let deadline = firstLaunch.addingTimeInterval(trialDuration)
            trialActive = now < deadline
            let remaining = deadline.timeIntervalSince(now)
            daysRemaining = remaining <= 0
                ? 0
                : min(trialDayCount, Int((remaining / (24 * 60 * 60)).rounded(.up)))
        } else if firstLaunch != nil {
            // Clock behind the recorded first launch: hold the nominal week
            // rather than granting unbounded off-clock access.
            trialActive = true
            daysRemaining = trialDayCount
        } else {
            trialActive = false
            daysRemaining = 0
        }

        return AppAccessState(
            canUsePaidFeatures: isUnrestricted || trialActive || hasVerifiedPurchase,
            isBetaAccess: isBeta,
            isUnrestricted: isUnrestricted,
            trialActive: trialActive,
            trialDaysRemaining: daysRemaining,
            hasVerifiedPurchase: hasVerifiedPurchase)
    }
}

// MARK: - Price presentation

/// StoreKit `Product.displayPrice` is the only sanctioned price string. When the
/// product has not loaded the UI shows an explicit unavailable state instead of a
/// hardcoded dollar amount that may not match the store sheet.
enum PurchasePriceText {
    static let unavailable = "Unavailable"

    static func resolved(_ displayPrice: String?) -> String? {
        guard let displayPrice,
              !displayPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return displayPrice
    }
}
