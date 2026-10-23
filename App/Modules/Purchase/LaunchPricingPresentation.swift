import Foundation

// MARK: - Launch pricing presentation

/// The non-purchasable price information shown on unrestricted channels — a
/// normal Debug run, a local development install, and the TestFlight beta —
/// where there is no live checkout. Production (`.appStore`) and the local
/// StoreKit-testing channel (`.storeKitTesting`) never use this copy: they show
/// the localized StoreKit `Product.displayPrice` so the price always matches the
/// store sheet.
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
    /// The explicit label required for the free preview.
    static let headline = "US launch pricing"
    /// The exact, owner-approved US amounts. Rendering is the paid feature.
    static let yearlyPrice = "US $4.99"
    static let lifetimePrice = "US $9.99"

    /// True only for a channel that is unrestricted without a purchase: normal
    /// Debug, a local development install, and the TestFlight beta. Production
    /// and the local StoreKit-testing channel are checkout channels and must
    /// show the real StoreKit price instead.
    static func isUnrestrictedChannel(_ distribution: AccessDistribution) -> Bool {
        distribution == .debug || distribution == .development || distribution == .testFlight
    }

    /// The non-purchasable price block for an unrestricted channel, or `nil` for
    /// a checkout channel where the live StoreKit price belongs.
    static func preview(for distribution: AccessDistribution) -> LaunchPricingPreview? {
        guard isUnrestrictedChannel(distribution) else { return nil }
        let footnote: String
        switch distribution {
        case .testFlight:
            footnote = "Beta testers are not charged. Recording stays free."
        default:
            footnote = "This build is not charged. Recording stays free."
        }
        return LaunchPricingPreview(
            headline: headline,
            yearlyPrice: yearlyPrice,
            lifetimePrice: lifetimePrice,
            footnote: footnote)
    }
}
