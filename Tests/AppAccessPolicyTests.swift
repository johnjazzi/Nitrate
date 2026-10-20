import Foundation
import Testing

/// Pure entitlement policy tests. These exercise only Foundation types so they
/// compile into the macOS RenderCLITests target with no StoreKit or iOS-only
/// dependency. StoreKit wiring (AppTransaction/Transaction) lives in
/// `StoreManager`; the policy consumes its already-verified snapshot.
struct AppAccessPolicyTests {
    private let reference = Date(timeIntervalSince1970: 1_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func entitlement(_ product: PaidProduct,
                             expiresIn: TimeInterval? = nil,
                             revoked: Bool = false) -> VerifiedEntitlement {
        VerifiedEntitlement(
            productID: product.rawValue,
            expirationDate: expiresIn.map { reference.addingTimeInterval($0) },
            revocationDate: revoked ? reference.addingTimeInterval(-day) : nil)
    }

    @Test func shippedProductIdentifiersMatchStoreManager() {
        // Guard: the policy's product table is the same contract StoreManager buys.
        #expect(PaidProduct.yearlySubscription.rawValue == "com.nitrate.subscription.yearly")
        #expect(PaidProduct.lifetime.rawValue == "com.nitrate.lifetime")
        #expect(PaidProduct.allCases.count == 2)
    }

    // MARK: - Distribution channel

    @Test func debugBuildsAreUnrestrictedRegardlessOfTrialOrPurchase() {
        let state = AppAccessPolicy.evaluate(
            distribution: .debug,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(state.canUsePaidFeatures)
        #expect(state.isUnrestricted)
        #expect(!state.isBetaAccess)
    }

    @Test func testFlightIsBetaAccessAndNeverRequiresCheckout() {
        let state = AppAccessPolicy.evaluate(
            distribution: .testFlight,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(state.canUsePaidFeatures)
        #expect(state.isBetaAccess)
        #expect(state.isUnrestricted)
        #expect(!state.hasVerifiedPurchase)
    }

    @Test func betaAccessIsConfinedToTestFlightNotProduction() {
        let product = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(!product.isBetaAccess)
        #expect(!product.canUsePaidFeatures)
    }

    // MARK: - Production trial evaluation (local, 7 days)

    @Test func productionTrialIsActiveWithinSevenDays() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-3 * day - 3600),
            now: reference,
            verifiedEntitlements: [])
        #expect(state.trialActive)
        #expect(state.canUsePaidFeatures)
        #expect(state.trialDaysRemaining == 4)
    }

    @Test func productionTrialExpiresAfterSevenDays() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-8 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(!state.trialActive)
        #expect(!state.canUsePaidFeatures)
        #expect(state.trialDaysRemaining == 0)
    }

    @Test func trialDeadlineExactlyIsExpired() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-AppAccessPolicy.trialDuration),
            now: reference,
            verifiedEntitlements: [])
        #expect(!state.trialActive)
        #expect(state.trialDaysRemaining == 0)
    }

    @Test func clockMovingBehindFirstLaunchKeepsFullTrial() {
        // A device clock behind the recorded first launch must not grant extra
        // access beyond the nominal week.
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(2 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(state.trialActive)
        #expect(state.trialDaysRemaining == AppAccessPolicy.trialDayCount)
    }

    @Test func storeKitTestingExercisesTheRealPaywall() {
        // A local StoreKit configuration must behave like a customer, so the
        // purchase, restore and expiry flows can be tested before any product
        // is registered in App Store Connect.
        let expired = AppAccessPolicy.evaluate(
            distribution: .storeKitTesting,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(!expired.canUsePaidFeatures)
        #expect(!expired.isBetaAccess)
        #expect(!expired.isUnrestricted)

        let subscribed = AppAccessPolicy.evaluate(
            distribution: .storeKitTesting,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.yearlySubscription, expiresIn: 5 * day)])
        #expect(subscribed.canUsePaidFeatures)

        #expect(AppAccessPolicy.isProductionLike(.appStore))
        #expect(AppAccessPolicy.isProductionLike(.storeKitTesting))
        #expect(!AppAccessPolicy.isProductionLike(.development))
        #expect(!AccessDistribution.storeKitTesting.isCacheable,
                "A local testing channel must never be remembered as a real install.")
    }

    @Test func developmentBuildIsUnrestrictedWithoutASubscription() {
        // A locally signed build has no App Store receipt; the developer must
        // never be locked out of their own app.
        let state = AppAccessPolicy.evaluate(
            distribution: .development,
            firstLaunch: reference.addingTimeInterval(-300 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(state.canUsePaidFeatures)
        #expect(state.isUnrestricted)
        #expect(!state.isBetaAccess)
        #expect(!state.hasVerifiedPurchase)
    }

    @Test func developmentChannelIsNeverCachedForOtherInstalls() {
        // A cached development channel must not leak into an App Store install.
        #expect(!AccessDistribution.development.isCacheable)
    }

    @Test func offlineLaunchKeepsTheLastVerifiedChannel() {
        // A TestFlight tester offline at launch must not be locked out of capture.
        #expect(AppAccessPolicy.resolvedChannel(current: .unknown, cached: .testFlight) == .testFlight)
        #expect(AppAccessPolicy.resolvedChannel(current: .unknown, cached: .appStore) == .appStore)
        // Nothing is invented when no channel was ever verified.
        #expect(AppAccessPolicy.resolvedChannel(current: .unknown, cached: nil) == .unknown)
        // A fresh verified answer always wins over the cache.
        #expect(AppAccessPolicy.resolvedChannel(current: .appStore, cached: .testFlight) == .appStore)
        #expect(AppAccessPolicy.resolvedChannel(current: .testFlight, cached: .appStore) == .testFlight)
        // Only genuine channels are worth remembering.
        #expect(AccessDistribution.testFlight.isCacheable)
        #expect(AccessDistribution.appStore.isCacheable)
        #expect(!AccessDistribution.unknown.isCacheable)
        #expect(!AccessDistribution.debug.isCacheable)
    }

    @Test func missingFirstLaunchIsNotATrial() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: nil,
            now: reference,
            verifiedEntitlements: [])
        #expect(!state.trialActive)
        #expect(!state.canUsePaidFeatures)
    }

    // MARK: - Verified purchases

    @Test func verifiedLifetimeGrantsAccessAfterTrialExpiry() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.lifetime)])
        #expect(state.hasVerifiedPurchase)
        #expect(state.canUsePaidFeatures)
    }

    @Test func verifiedActiveSubscriptionGrantsAccess() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.yearlySubscription, expiresIn: 5 * day)])
        #expect(state.canUsePaidFeatures)
    }

    @Test func subscriptionWithoutAnExpirationCannotGrantLifetimeAccess() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.yearlySubscription)])
        #expect(!state.hasVerifiedPurchase)
        #expect(!state.canUsePaidFeatures)
    }

    @Test func expiredSubscriptionIsRejected() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.yearlySubscription, expiresIn: -day)])
        #expect(!state.canUsePaidFeatures)
        #expect(!state.hasVerifiedPurchase)
    }

    @Test func revokedTransactionIsRejected() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.lifetime, revoked: true)])
        #expect(!state.canUsePaidFeatures)
        #expect(!state.hasVerifiedPurchase)
    }

    @Test func unexpectedProductIdentifierIsIgnored() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [VerifiedEntitlement(productID: "com.example.other")])
        #expect(!state.canUsePaidFeatures)
    }

    @Test func recomputesToFalseWhenSubscriptionExpiresWithTime() {
        let entitlements = [entitlement(.yearlySubscription, expiresIn: day)]
        let before = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: entitlements)
        let after = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference.addingTimeInterval(2 * day),
            verifiedEntitlements: entitlements)
        #expect(before.canUsePaidFeatures)
        #expect(!after.canUsePaidFeatures)
    }

    @Test func refundedEntitlementNoLongerPresentLocksAccess() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(!state.canUsePaidFeatures)
    }

    @Test func unknownDistributionStillHonoursVerifiedPurchase() {
        let state = AppAccessPolicy.evaluate(
            distribution: .unknown,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.lifetime)])
        #expect(state.canUsePaidFeatures)
        #expect(!state.isBetaAccess)
    }

    @Test func unknownDistributionWithoutPurchaseOrTrialIsLocked() {
        let state = AppAccessPolicy.evaluate(
            distribution: .unknown,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(!state.canUsePaidFeatures)
    }

    @Test func defaultStateIsLocked() {
        #expect(AppAccessState.locked == AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: nil,
            now: reference,
            verifiedEntitlements: []))
    }

    // MARK: - Lifetime vs subscription copy

    @Test func verifiedLifetimePurchaseIsFlaggedForTheForeverCopy() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.lifetime)])
        #expect(state.hasLifetimePurchase)
    }

    @Test func yearlySubscriptionIsNotFlaggedAsALifetimePurchase() {
        // A renewal must not claim "unlocked forever".
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.yearlySubscription, expiresIn: 5 * day)])
        #expect(!state.hasLifetimePurchase)
    }

    @Test func revokedLifetimePurchaseIsNotFlagged() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.lifetime, revoked: true)])
        #expect(!state.hasLifetimePurchase)
    }
}

/// The Debug StoreKit-testing routing contract. The paywall is gated behind
/// `AppAccessPolicy.debugChannelOverride`, which `StoreManager.resolveDistribution`
/// consults inside `#if DEBUG`. These tests pin the routing decision and the
/// customer-like behaviour of the channel it unlocks.
struct StoreKitTestingRoutingTests {
    private let reference = Date(timeIntervalSince1970: 1_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    @Test func debugBuildWithoutTheTestingOptInIsAFreeDebugUnlock() {
        // Normal development must stay unrestricted: no paywall, no checkout.
        let override = AppAccessPolicy.debugChannelOverride(
            isDebugBuild: true, storeKitTestingRequested: false)
        #expect(override == .debug)
    }

    @Test func debugBuildWithTheTestingOptInResolvesTheStoreKitTestingChannel() {
        // The opt-in must resolve `.storeKitTesting` directly. Falling through
        // to the receipt guard would return `.development` for a Debug build
        // with no App Store receipt — a free unlock that leaves the fixture
        // inert and the paywall invisible.
        let override = AppAccessPolicy.debugChannelOverride(
            isDebugBuild: true, storeKitTestingRequested: true)
        #expect(override == .storeKitTesting)
        #expect(AppAccessPolicy.isProductionLike(.storeKitTesting))
        #expect(!AccessDistribution.storeKitTesting.isCacheable)
    }

    @Test func storeKitTestingChannelIsGatedNotAFreeUnlock() {
        // The channel the opt-in resolves is not unrestricted, so the gated
        // paywall is reachable and a purchase is required after the evaluation.
        let state = AppAccessPolicy.evaluate(
            distribution: .storeKitTesting,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(!state.isUnrestricted)
        #expect(!state.canUsePaidFeatures)
    }

    @Test func releaseBuildNeverHonoursTheDebugUnlock() {
        // Production and TestFlight must be unaffected by the debug override, no
        // matter what launch arguments are present.
        #expect(AppAccessPolicy.debugChannelOverride(
            isDebugBuild: false, storeKitTestingRequested: true) == nil)
        #expect(AppAccessPolicy.debugChannelOverride(
            isDebugBuild: false, storeKitTestingRequested: false) == nil)
    }

    @Test func storeKitTestingLaunchArgumentMatchesOnlyTheExactArgument() {
        #expect(StoreKitTestingLaunchMode.isRequested(
            arguments: ["/path/Nitrate", "-NitrateStoreKitTesting"]))
        #expect(!StoreKitTestingLaunchMode.isRequested(arguments: ["/path/Nitrate"]))
        // A near-miss must not enable the mode.
        #expect(!StoreKitTestingLaunchMode.isRequested(
            arguments: ["/path/Nitrate", "-NitrateStoreKitTestingOff"]))
    }

    @Test func storeKitTestingChannelEvaluatesThenExpiresThenPurchases() {
        // The channel the opt-in reaches behaves exactly like a real customer:
        // a live evaluation, a lock once it expires, and a verified purchase.
        let evaluation = AppAccessPolicy.evaluate(
            distribution: .storeKitTesting,
            firstLaunch: reference.addingTimeInterval(-2 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(evaluation.trialActive)
        #expect(evaluation.canUsePaidFeatures)
        #expect(!evaluation.isUnrestricted)

        let expired = AppAccessPolicy.evaluate(
            distribution: .storeKitTesting,
            firstLaunch: reference.addingTimeInterval(-8 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(!expired.canUsePaidFeatures)

        let purchased = AppAccessPolicy.evaluate(
            distribution: .storeKitTesting,
            firstLaunch: reference.addingTimeInterval(-8 * day),
            now: reference,
            verifiedEntitlements: [VerifiedEntitlement(
                productID: PaidProduct.yearlySubscription.rawValue,
                expirationDate: reference.addingTimeInterval(5 * day))])
        #expect(purchased.canUsePaidFeatures)
        #expect(purchased.hasVerifiedPurchase)
    }
}

struct PurchasePriceTextTests {
    @Test func missingPriceIsUnavailableNotAHardcodedFallback() {
        #expect(PurchasePriceText.resolved(nil) == nil)
        #expect(PurchasePriceText.resolved("") == nil)
        #expect(PurchasePriceText.resolved("   ") == nil)
    }

    @Test func localizedDisplayPricePassesThroughVerbatim() {
        #expect(PurchasePriceText.resolved("$4.99") == "$4.99")
        #expect(PurchasePriceText.resolved("¥600") == "¥600")
        #expect(PurchasePriceText.resolved("4,99 €") == "4,99 €")
    }
}

/// The non-purchasable launch-pricing copy shown on unrestricted channels. The
/// exact owner-approved US amounts are pinned here, and the preview must appear
/// for exactly the unrestricted channels — never on a checkout channel, where
/// the live StoreKit `displayPrice` belongs.
struct LaunchPricingPresentationTests {
    @Test func launchPricingIsTheExactApprovedUSAmounts() {
        #expect(LaunchPricingPresentation.yearlyPrice == "US $5.00/year")
        #expect(LaunchPricingPresentation.lifetimePrice == "US $10.00 one time")
        #expect(LaunchPricingPresentation.headline == "US launch pricing")
    }

    @Test func previewIsShownOnlyForUnrestrictedChannels() {
        // Unrestricted: normal Debug, a development install, and the beta.
        #expect(LaunchPricingPresentation.preview(for: .debug) != nil)
        #expect(LaunchPricingPresentation.preview(for: .development) != nil)
        #expect(LaunchPricingPresentation.preview(for: .testFlight) != nil)
        // Checkout channels show the real StoreKit price instead.
        #expect(LaunchPricingPresentation.preview(for: .appStore) == nil)
        #expect(LaunchPricingPresentation.preview(for: .storeKitTesting) == nil)
        #expect(LaunchPricingPresentation.preview(for: .unknown) == nil)
    }

    @Test func previewVisibilityMatchesTheUnrestrictedPolicy() {
        // The preview channel set must equal the policy's unrestricted set, so
        // it can never appear on a gated production or testing channel.
        for channel in AccessDistribution.allCases {
            let state = AppAccessPolicy.evaluate(
                distribution: channel,
                firstLaunch: nil,
                now: Date(timeIntervalSince1970: 1_000_000),
                verifiedEntitlements: [])
            #expect(LaunchPricingPresentation.isUnrestrictedChannel(channel) == state.isUnrestricted,
                    "preview visibility must match isUnrestricted for \(channel.rawValue)")
        }
    }

    @Test func previewCarriesTheExactPricesAndTheFreeRecordingNote() {
        let beta = LaunchPricingPresentation.preview(for: .testFlight)
        #expect(beta?.yearlyPrice == "US $5.00/year")
        #expect(beta?.lifetimePrice == "US $10.00 one time")
        #expect(beta?.footnote.contains("not charged") == true)
        #expect(beta?.footnote.contains("stays free") == true)

        // The development/DEBUG preview carries the same prices and the
        // no-charge, recording-stays-free note.
        let development = LaunchPricingPresentation.preview(for: .debug)
        #expect(development?.yearlyPrice == "US $5.00/year")
        #expect(development?.lifetimePrice == "US $10.00 one time")
        #expect(development?.footnote.contains("not charged") == true)
        #expect(development?.footnote.contains("stays free") == true)
    }
}
