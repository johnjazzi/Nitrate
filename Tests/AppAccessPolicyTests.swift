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
        #expect(PaidProduct.yearlySubscription.rawValue == "com.filmemulation.subscription.yearly")
        #expect(PaidProduct.lifetime.rawValue == "com.filmemulation.lifetime")
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
