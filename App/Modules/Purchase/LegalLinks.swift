import Foundation

/// The public legal and support pages, linked from Settings. App Store review
/// requires the privacy policy to be reachable both in the listing metadata and
/// from inside the app, so these URLs are the in-app counterpart of the listing
/// fields.
///
/// The values are pure constants with no view or bundle dependency, so a test
/// can pin the exact addresses that are published at
/// `https://johnjazzi.github.io/Nitrate/`. The support page carries the public
/// contact address (`nitrate.camera@johnazz.dev`), so the app links to that page
/// rather than duplicating a `mailto:` route — no address is hardcoded here and
/// no mail client is opened.
enum LegalLinks {
    struct Link: Identifiable, Hashable {
        let title: String
        let url: URL
        let systemImage: String
        /// Stable hook for UI tests that reach a row inside the settings screen.
        let accessibilityID: String

        var id: String { accessibilityID }
    }

    /// The Settings access states the legal section can appear in. Every one of
    /// them renders the full set: the section is not gated on entitlement, so a
    /// locked-out user can read the policy before paying. The type exists so the
    /// "all channels keep the links" contract is testable and a future channel
    /// forces an explicit decision.
    enum Channel: String, CaseIterable, Sendable {
        /// A Debug run or a locally signed development install (unrestricted).
        case development
        /// The TestFlight beta (unrestricted).
        case beta
        /// An App Store / StoreKit-testing install inside the free trial.
        case trialActive
        /// An App Store / StoreKit-testing install whose trial has lapsed.
        case trialExpired
        /// A verified paid entitlement (subscription or lifetime).
        case purchased
    }

    static let privacy = Link(
        title: "Privacy Policy",
        url: URL(string: "https://johnjazzi.github.io/Nitrate/privacy.html")!,
        systemImage: "hand.raised",
        accessibilityID: "settings.legal.privacy"
    )

    static let terms = Link(
        title: "Terms of Use",
        url: URL(string: "https://johnjazzi.github.io/Nitrate/terms.html")!,
        systemImage: "doc.text",
        accessibilityID: "settings.legal.terms"
    )

    static let support = Link(
        title: "Support",
        url: URL(string: "https://johnjazzi.github.io/Nitrate/support.html")!,
        systemImage: "questionmark.circle",
        accessibilityID: "settings.legal.support"
    )

    /// The order shown in Settings.
    static let all: [Link] = [privacy, terms, support]

    /// The links shown for a given access channel. Always the full ordered set,
    /// on every channel: the legal and support pages must stay reachable from a
    /// paid checkout, an expired trial and a free build alike.
    static func visibleLinks(for channel: Channel) -> [Link] {
        all
    }
}
