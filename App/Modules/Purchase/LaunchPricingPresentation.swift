import Foundation

// MARK: - Launch pricing presentation

/// The non-purchasable price information shown on a local development build — a
/// normal Debug run or a `NITRATE_LOCAL_DEVELOPMENT` install — where there is no
/// live checkout. Every customer channel, including sandbox (TestFlight and App
/// Review), shows the localized StoreKit `Product.displayPrice` so the price
/// always matches the store sheet.
struct LaunchPricingPreview: Equatable, Sendable {
    let headline: String
    let yearlyPrice: String
    let lifetimePrice: String
    let footnote: String
}

/// Pure, testable source of the launch price copy.
///
/// These are the owner-approved US launch amounts and are deliberately NOT a
/// fallback checkout price: they are display-only. A real purchase always reads
/// `Product.displayPrice` from StoreKit, and a checkout button stays disabled
/// until the product has loaded, so this copy can never stand in for a missing
/// store price.
enum LaunchPricingPresentation {
    /// The explicit label for the local preview. It names itself a developer
    /// preview because it can only appear on a build that cannot transact: real
    /// prices always come from `Product.displayPrice` at checkout.
    static let headline = "Developer pricing preview"
    /// The exact, owner-approved US amounts. Rendering is the paid feature.
    static let yearlyPrice = "US $4.99"
    static let lifetimePrice = "US $9.99"

    /// True only for a local development build, which is unrestricted without a
    /// purchase. Production, sandbox and StoreKit testing are checkout channels
    /// and must show the real StoreKit price instead.
    static func isUnrestrictedChannel(_ distribution: AccessDistribution) -> Bool {
        distribution == .debug || distribution == .development
    }

    /// The non-purchasable price block for a local development build, or `nil`
    /// for a checkout channel where the live StoreKit price belongs.
    static func preview(for distribution: AccessDistribution) -> LaunchPricingPreview? {
        guard isUnrestrictedChannel(distribution) else { return nil }
        return LaunchPricingPreview(
            headline: headline,
            yearlyPrice: yearlyPrice,
            lifetimePrice: lifetimePrice,
            footnote: "Not purchasable in this build. Recording stays free.")
    }
}
