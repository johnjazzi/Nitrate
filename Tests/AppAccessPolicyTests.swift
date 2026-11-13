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
    }

    @Test func sandboxNotFoundAfterExpiryLocksPaidFeatures() {
        // Regression: TestFlight and App Review both run in `.sandbox`. It must
        // behave like production, not like an unrestricted beta.
        let state = AppAccessPolicy.evaluate(
            distribution: .sandbox,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(!state.canUsePaidFeatures)
        #expect(!state.isUnrestricted)
        #expect(!state.hasVerifiedPurchase)
    }

    @Test func sandboxDoesNotRequireAPurchaseDuringEvaluation() {
        // The twenty-day local evaluation is the same on sandbox as on production, so
        // App Review can reach the checkout without being granted free access.
        let state = AppAccessPolicy.evaluate(
            distribution: .sandbox,
            firstLaunch: reference.addingTimeInterval(-2 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(state.trialActive)
        #expect(state.canUsePaidFeatures)
        #expect(!state.isUnrestricted)
        #expect(!state.hasVerifiedPurchase)
    }

    @Test func sandboxVerifiedPurchaseUnlocksAfterExpiry() {
        let lifetime = AppAccessPolicy.evaluate(
            distribution: .sandbox,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.lifetime)])
        #expect(lifetime.hasVerifiedPurchase)
        #expect(lifetime.hasLifetimePurchase)
        #expect(lifetime.canUsePaidFeatures)

        let subscribed = AppAccessPolicy.evaluate(
            distribution: .sandbox,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.yearlySubscription, expiresIn: 5 * day)])
        #expect(subscribed.hasVerifiedPurchase)
        #expect(!subscribed.hasLifetimePurchase)
        #expect(subscribed.canUsePaidFeatures)
    }

    @Test func sandboxExpiredOrRevokedPurchaseStaysLocked() {
        let expired = AppAccessPolicy.evaluate(
            distribution: .sandbox,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.yearlySubscription, expiresIn: -day)])
        #expect(!expired.canUsePaidFeatures)

        let revoked = AppAccessPolicy.evaluate(
            distribution: .sandbox,
            firstLaunch: reference.addingTimeInterval(-30 * day),
            now: reference,
            verifiedEntitlements: [entitlement(.lifetime, revoked: true)])
        #expect(!revoked.canUsePaidFeatures)
    }

    @Test func sandboxIsProductionLikeAndCacheable() {
        #expect(AppAccessPolicy.isProductionLike(.sandbox))
        #expect(AccessDistribution.sandbox.isCacheable)
    }

    // MARK: - Production trial evaluation (local, 20 days)

    @Test func productionTrialIsTwentyDaysFromInstall() {
        #expect(AppAccessPolicy.trialDayCount == 20)
        #expect(AppAccessPolicy.trialDuration == 20 * day)

        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-3 * day - 3600),
            now: reference,
            verifiedEntitlements: [])
        #expect(state.trialActive)
        #expect(state.canUsePaidFeatures)
        #expect(state.trialDaysRemaining == 17,
                "twenty days from install, minus the three elapsed and the started hour")
    }

    @Test func productionTrialStillRunsOnDayNineteen() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-19 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(state.trialActive)
        #expect(state.trialDaysRemaining == 1)
    }

    @Test func expiredAnchorIsOutsideTheIncludedPeriod() {
        let anchor = AppAccessPolicy.expiredAnchor(now: reference)
        let state = AppAccessPolicy.evaluate(distribution: .appStore,
                                             firstLaunch: anchor,
                                             now: reference,
                                             verifiedEntitlements: [])
        #expect(!state.trialActive)
        #expect(!state.canUsePaidFeatures)
        #expect(state.trialDaysRemaining == 0)
    }

    @Test func productionTrialExpiresAfterTwentyDays() {
        let state = AppAccessPolicy.evaluate(
            distribution: .appStore,
            firstLaunch: reference.addingTimeInterval(-21 * day),
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
        // The explicit local development flag must never lock the developer out.
        let state = AppAccessPolicy.evaluate(
            distribution: .development,
            firstLaunch: reference.addingTimeInterval(-300 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(state.canUsePaidFeatures)
        #expect(state.isUnrestricted)
        #expect(!state.hasVerifiedPurchase)
    }

    @Test func developmentChannelIsNeverCachedForOtherInstalls() {
        // A cached development channel must not leak into an App Store install.
        #expect(!AccessDistribution.development.isCacheable)
    }

    @Test func offlineLaunchKeepsTheLastVerifiedChannel() {
        // A sandbox tester offline at launch must not be locked out of capture.
        #expect(AppAccessPolicy.resolvedChannel(current: .unknown, cached: .sandbox) == .sandbox)
        #expect(AppAccessPolicy.resolvedChannel(current: .unknown, cached: .appStore) == .appStore)
        // Nothing is invented when no channel was ever verified.
        #expect(AppAccessPolicy.resolvedChannel(current: .unknown, cached: nil) == .unknown)
        // A fresh verified answer always wins over the cache.
        #expect(AppAccessPolicy.resolvedChannel(current: .appStore, cached: .sandbox) == .appStore)
        #expect(AppAccessPolicy.resolvedChannel(current: .sandbox, cached: .appStore) == .sandbox)
        // Only genuine channels are worth remembering.
        #expect(AccessDistribution.sandbox.isCacheable)
        #expect(AccessDistribution.appStore.isCacheable)
        #expect(!AccessDistribution.unknown.isCacheable)
        #expect(!AccessDistribution.debug.isCacheable)
    }

    @Test func unknownFallbackNeverAcceptsANonCacheableChannel() {
        // The fallback is cacheable-only even if a caller passes something else.
        #expect(AppAccessPolicy.resolvedChannel(current: .unknown, cached: .debug) == .unknown)
        #expect(AppAccessPolicy.resolvedChannel(current: .unknown, cached: .development) == .unknown)
        #expect(AppAccessPolicy.resolvedChannel(current: .unknown, cached: .storeKitTesting) == .unknown)
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

/// The cached-channel contract: only a verified, cacheable channel is trusted,
/// and the legacy `testFlight` raw value migrates to `.sandbox`.
struct CachedDistributionTests {
    @Test func legacyTestFlightCacheMigratesToSandbox() {
        #expect(AppAccessPolicy.cachedChannel(fromPersistedRawValue: "testFlight") == .sandbox)
    }

    @Test func verifiedChannelsDecodeUnchanged() {
        #expect(AppAccessPolicy.cachedChannel(fromPersistedRawValue: "appStore") == .appStore)
        #expect(AppAccessPolicy.cachedChannel(fromPersistedRawValue: "sandbox") == .sandbox)
        #expect(AppAccessPolicy.cachedChannel(fromPersistedRawValue: nil) == nil)
        #expect(AppAccessPolicy.cachedChannel(fromPersistedRawValue: "") == nil)
    }

    @Test func cachedDebugAndDevelopmentAreRejected() {
        #expect(AppAccessPolicy.cachedChannel(fromPersistedRawValue: "debug") == nil)
        #expect(AppAccessPolicy.cachedChannel(fromPersistedRawValue: "development") == nil)
        #expect(AppAccessPolicy.cachedChannel(fromPersistedRawValue: "storeKitTesting") == nil)
        #expect(AppAccessPolicy.cachedChannel(fromPersistedRawValue: "unknown") == nil)
        #expect(AppAccessPolicy.cachedChannel(fromPersistedRawValue: "garbage") == nil)
    }
}

/// The pure channel routing seam `StoreManager.resolveDistribution` uses.
struct AccessDistributionRoutingTests {
    @Test func productionEnvironmentIsTheAppStore() {
        #expect(AppAccessPolicy.distribution(environment: .production,
                                             debugOverride: nil,
                                             localDevelopmentEnabled: false) == .appStore)
    }

    @Test func sandboxEnvironmentIsGatedSandboxNotADevelopmentGrant() {
        #expect(AppAccessPolicy.distribution(environment: .sandbox,
                                             debugOverride: nil,
                                             localDevelopmentEnabled: false) == .sandbox)
    }

    @Test func xcodeEnvironmentIsTheStoreKitTestFixture() {
        #expect(AppAccessPolicy.distribution(environment: .xcode,
                                             debugOverride: nil,
                                             localDevelopmentEnabled: false) == .storeKitTesting)
    }

    @Test func missingEnvironmentIsUnknownNeverDevelopment() {
        // Regression: a receipt-less install used to resolve `.development` and
        // unlock everything. Without the explicit flag it must stay unknown.
        #expect(AppAccessPolicy.distribution(environment: nil,
                                             debugOverride: nil,
                                             localDevelopmentEnabled: false) == .unknown)
    }

    @Test func localDevelopmentFlagGrantsDevelopmentOnlyOffProduction() {
        #expect(AppAccessPolicy.distribution(environment: nil,
                                             debugOverride: nil,
                                             localDevelopmentEnabled: true) == .development)
        #expect(AppAccessPolicy.distribution(environment: .sandbox,
                                             debugOverride: nil,
                                             localDevelopmentEnabled: true) == .development)
        // A production receipt always identifies a real customer.
        #expect(AppAccessPolicy.distribution(environment: .production,
                                             debugOverride: nil,
                                             localDevelopmentEnabled: true) == .appStore)
    }

    @Test func debugOverrideWinsAndIsNeverProvidedByRelease() {
        #expect(AppAccessPolicy.distribution(environment: .sandbox,
                                             debugOverride: .debug,
                                             localDevelopmentEnabled: false) == .debug)
        #expect(AppAccessPolicy.debugChannelOverride(isDebugBuild: false,
                                                     storeKitTestingRequested: true) == nil)
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
        // The opt-in must resolve `.storeKitTesting` directly, so the fixture
        // drives real purchases and the gated paywall is reachable.
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
        // Production and sandbox must be unaffected by the debug override, no
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
            firstLaunch: reference.addingTimeInterval(-21 * day),
            now: reference,
            verifiedEntitlements: [])
        #expect(!expired.canUsePaidFeatures)

        let purchased = AppAccessPolicy.evaluate(
            distribution: .storeKitTesting,
            firstLaunch: reference.addingTimeInterval(-21 * day),
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

/// The non-purchasable launch-pricing copy, shown only on a local development
/// build. The exact owner-approved US amounts are pinned here, and the preview
/// must never appear on a customer channel — sandbox included, because App
/// Review runs in sandbox and must reach the live checkout.
struct LaunchPricingPresentationTests {
    @Test func launchPricingIsTheExactApprovedUSAmounts() {
        #expect(LaunchPricingPresentation.yearlyPrice == "US $4.99")
        #expect(LaunchPricingPresentation.lifetimePrice == "US $9.99")
        #expect(LaunchPricingPresentation.headline == "Developer pricing preview")
    }

    @Test func previewIsShownOnlyForLocalDevelopmentBuilds() {
        #expect(LaunchPricingPresentation.preview(for: .debug) != nil)
        #expect(LaunchPricingPresentation.preview(for: .development) != nil)
        // Checkout channels show the real StoreKit price instead.
        #expect(LaunchPricingPresentation.preview(for: .appStore) == nil)
        #expect(LaunchPricingPresentation.preview(for: .sandbox) == nil)
        #expect(LaunchPricingPresentation.preview(for: .storeKitTesting) == nil)
        #expect(LaunchPricingPresentation.preview(for: .unknown) == nil)
    }

    @Test func previewVisibilityMatchesTheUnrestrictedPolicy() {
        // The preview channel set must equal the policy's unrestricted set, so
        // it can never appear on a gated production, sandbox or testing channel.
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
        let development = LaunchPricingPresentation.preview(for: .development)
        #expect(development?.yearlyPrice == "US $4.99")
        #expect(development?.lifetimePrice == "US $9.99")
        // The block must describe itself honestly: it is a developer preview in
        // a build that cannot transact, not customer pricing.
        #expect(development?.headline == "Developer pricing preview")
        #expect(development?.footnote.contains("Not purchasable") == true)
        #expect(development?.footnote.contains("stays free") == true)
    }
}
