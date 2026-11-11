import Foundation

// MARK: - Distribution channel

/// How this installation was obtained. Resolved once from a verified StoreKit
/// `AppTransaction.environment` (or an explicit compile-time development
/// configuration) and never from a user-editable preference — a defaults flag or
/// a blanket Release bypass would let a production user self-grant paid access.
///
/// Apple's documented mapping (StoreKit `AppStore.Environment`):
/// - `.production` → `.appStore` (installed from the App Store)
/// - `.sandbox`    → `.sandbox` (TestFlight — and App Review's sandbox run)
/// - `.xcode`      → `.storeKitTesting` (a local StoreKit-testing build)
///
/// `.sandbox` is deliberately production-like. App Review exercises the app in
/// the sandbox environment, so a sandbox bypass replaced the paywall with a
/// non-purchasable preview and failed review under guideline 2.1(b).
enum AccessDistribution: String, Sendable, CaseIterable {
    /// A `#if DEBUG` build: unrestricted so a developer is never blocked.
    case debug
    /// A local development build, granted only by the
    /// `NITRATE_LOCAL_DEVELOPMENT` compile-time flag. A missing App Store
    /// receipt alone never resolves here.
    case development
    /// A local StoreKit configuration file is driving purchases (Xcode's
    /// `.xcode` environment). Treated exactly like the App Store so the real
    /// paywall can be exercised before any product is registered.
    case storeKitTesting
    /// A StoreKit sandbox install: TestFlight and App Review. Gated exactly like
    /// production — the local evaluation runs, then a verified purchase is
    /// required.
    case sandbox
    case appStore
    case unknown

    /// Only a genuinely verified install channel is worth remembering. `unknown`
    /// means the App Store could not answer, not that the app is production.
    var isCacheable: Bool { self == .sandbox || self == .appStore }
}

// MARK: - Debug StoreKit testing mode

/// The explicit opt-in that routes a Debug build to the real StoreKit paywall
/// instead of the free debug unlock. Only the dedicated `NitrateStoreKitTest`
/// scheme passes this launch argument; normal Debug runs and every Release build
/// never do, so development and production are all unaffected.
/// `StoreManager` resolves it straight to `AccessDistribution.storeKitTesting`.
enum StoreKitTestingLaunchMode {
    /// Launch argument added by the `NitrateStoreKitTest` scheme's run action.
    static let launchArgument = "-NitrateStoreKitTesting"

    /// True only when the exact argument is present. A near-miss such as
    /// `-NitrateStoreKitTestingOff` must not enable the mode.
    static func isRequested(arguments: [String]) -> Bool {
        arguments.contains(launchArgument)
    }
}

// MARK: - Environment input

/// StoreKit's `AppStore.Environment`, reduced to a Foundation-only input so the
/// channel routing is deterministic and testable without StoreKit.
enum StoreEnvironmentInput: String, Sendable, CaseIterable {
    case production
    case sandbox
    case xcode
    case unknown
}

// MARK: - Access-change notification

extension Notification.Name {
    /// Posted when render access becomes available (a purchase, restore or
    /// redeemed offer code). The render queue listens so work it withheld while
    /// access was missing starts immediately instead of waiting for the next
    /// app activation.
    static let nitrateRenderAccessChanged = Notification.Name("nitrate.renderAccessChanged")
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
/// the app uses to admit capture/render.
struct AppAccessState: Equatable, Sendable {
    let canUsePaidFeatures: Bool
    let isUnrestricted: Bool
    let trialActive: Bool
    let trialDaysRemaining: Int
    let hasVerifiedPurchase: Bool
    /// True only for a verified, non-revoked lifetime purchase. Drives the
    /// "unlocked forever" copy, which is false for a renewal subscription.
    let hasLifetimePurchase: Bool

    static let locked = AppAccessState(
        canUsePaidFeatures: false,
        isUnrestricted: false,
        trialActive: false,
        trialDaysRemaining: 0,
        hasVerifiedPurchase: false,
        hasLifetimePurchase: false)
}

// MARK: - Policy

/// Pure, synchronous entitlement policy. No StoreKit, no UserDefaults, no clock
/// of its own — every input is passed in so the whole decision is deterministic
/// and testable off-device.
enum AppAccessPolicy {
    /// Twenty days of film rendering from first launch, then the purchase is
    /// required to keep rendering. This is the app's own evaluation timer: it
    /// never charges, never converts to a subscription, and Apple's sheet only
    /// appears if the operator chooses to buy.
    static let trialDuration: TimeInterval = 20 * 24 * 60 * 60
    static let trialDayCount = 20

    /// The raw value an earlier build persisted for the sandbox channel. Kept so
    /// an install that already cached it migrates instead of losing its channel.
    static let legacySandboxRawValue = "testFlight"

    /// Decode a persisted channel. Only a verified, cacheable channel is ever
    /// accepted: a cached `.debug` or `.development` must never unlock a later
    /// install, and the legacy `testFlight` raw value migrates to `.sandbox`.
    static func cachedChannel(fromPersistedRawValue raw: String?) -> AccessDistribution? {
        guard let raw else { return nil }
        let migrated = raw == legacySandboxRawValue ? AccessDistribution.sandbox.rawValue : raw
        guard let channel = AccessDistribution(rawValue: migrated), channel.isCacheable else {
            return nil
        }
        return channel
    }

    /// A channel that could not be resolved this launch keeps the last verified
    /// channel. Without this, an offline sandbox tester is locked out of capture
    /// while the App Store is unreachable; a production user is unaffected
    /// because `.appStore` still requires the evaluation or a verified buy.
    /// The cache is only ever a verified, cacheable channel.
    static func resolvedChannel(current: AccessDistribution,
                                cached: AccessDistribution?) -> AccessDistribution {
        guard current == .unknown else { return current }
        guard let cached, cached.isCacheable else { return .unknown }
        return cached
    }

    /// The channel behaves like a real customer: an evaluation, then a verified
    /// purchase. Used for the App Store, StoreKit testing, and sandbox
    /// (TestFlight and App Review).
    static func isProductionLike(_ distribution: AccessDistribution) -> Bool {
        distribution == .appStore || distribution == .sandbox || distribution == .storeKitTesting
    }

    /// Pure channel routing from the resolved StoreKit environment.
    ///
    /// `debugOverride` is the compile-time Debug decision (see
    /// `debugChannelOverride`); it always wins. `localDevelopmentEnabled` is the
    /// explicit `NITRATE_LOCAL_DEVELOPMENT` compile flag, and it grants
    /// `.development` only for a build that cannot be an App Store install. A
    /// missing environment (the App Store could not answer) is `.unknown` — a
    /// receipt-less install never grants free access on its own.
    static func distribution(environment: StoreEnvironmentInput?,
                             debugOverride: AccessDistribution?,
                             localDevelopmentEnabled: Bool) -> AccessDistribution {
        if let debugOverride { return debugOverride }
        if localDevelopmentEnabled, environment != .production { return .development }
        guard let environment else { return .unknown }
        switch environment {
        case .production:
            return .appStore
        case .sandbox:
            return .sandbox
        case .xcode:
            return .storeKitTesting
        case .unknown:
            return .unknown
        }
    }

    /// The compile-time Debug channel override, made explicit and testable.
    ///
    /// A Debug build is unrestricted by default so a developer is never blocked
    /// by the paywall and no checkout is shown. A Debug build launched with the
    /// explicit StoreKit-testing argument (the dedicated `NitrateStoreKitTest`
    /// scheme) resolves straight to `.storeKitTesting`, so the real local StoreKit
    /// configuration drives every `Product.purchase` and `Transaction` call and
    /// the gated paywall becomes reachable. It must resolve directly: the
    /// fall-through path cannot reach the fixture, because a Debug build has no
    /// App Store receipt. A non-Debug build never honours the override: Release
    /// always reaches StoreKit, so production and sandbox are decided by the
    /// store exactly as before.
    static func debugChannelOverride(isDebugBuild: Bool,
                                     storeKitTestingRequested: Bool) -> AccessDistribution? {
        guard isDebugBuild else { return nil }
        return storeKitTestingRequested ? .storeKitTesting : .debug
    }

    static func evaluate(distribution: AccessDistribution,
                         firstLaunch: Date?,
                         now: Date,
                         verifiedEntitlements: [VerifiedEntitlement]) -> AppAccessState {
        // Only an explicitly compiled-in development build is unrestricted.
        // Every customer channel — including sandbox — must earn access via the
        // evaluation or a verified purchase.
        let isUnrestricted = distribution == .debug || distribution == .development

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

        let hasLifetimePurchase = verifiedEntitlements.contains { entitlement in
            guard PaidProduct.expected(for: entitlement.productID) == .lifetime,
                  entitlement.revocationDate == nil else { return false }
            if let expiration = entitlement.expirationDate, expiration <= now { return false }
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
            isUnrestricted: isUnrestricted,
            trialActive: trialActive,
            trialDaysRemaining: daysRemaining,
            hasVerifiedPurchase: hasVerifiedPurchase,
            hasLifetimePurchase: hasLifetimePurchase)
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
