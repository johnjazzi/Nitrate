import Foundation
import Testing

/// App Store review requires the privacy policy to be reachable *inside* the
/// app, not only in the listing metadata. Settings renders the same three public
/// URLs declared here, so a typo in a constant fails this suite instead of
/// shipping as a dead link discovered at review time.
///
/// These assertions pin the model contract only. They prove the exact addresses,
/// identifiers and ordering the view reads; they do not prove that SwiftUI hands
/// the URL to the system browser (that needs the running app).
struct LegalLinksTests {
    private let privacyURL = "https://johnjazzi.github.io/Nitrate/privacy.html"
    private let termsURL = "https://johnjazzi.github.io/Nitrate/terms.html"
    private let supportURL = "https://johnjazzi.github.io/Nitrate/support.html"

    @Test func privacyPointsAtThePublishedPolicy() {
        #expect(LegalLinks.privacy.url.absoluteString == privacyURL)
        #expect(LegalLinks.privacy.title == "Privacy Policy")
    }

    @Test func termsPointsAtThePublishedTerms() {
        #expect(LegalLinks.terms.url.absoluteString == termsURL)
        #expect(LegalLinks.terms.title == "Terms of Use")
    }

    @Test func supportPointsAtThePublishedSupportPage() {
        #expect(LegalLinks.support.url.absoluteString == supportURL)
        #expect(LegalLinks.support.title == "Support")
    }

    @Test func pathsAreExactlyThePublishedPages() {
        #expect(LegalLinks.privacy.url.path == "/Nitrate/privacy.html")
        #expect(LegalLinks.terms.url.path == "/Nitrate/terms.html")
        #expect(LegalLinks.support.url.path == "/Nitrate/support.html")
    }

    @Test func everyLinkIsHTTPSOnThePublishedHost() {
        for link in LegalLinks.all {
            #expect(link.url.scheme == "https")
            #expect(link.url.host == "johnjazzi.github.io")
            #expect(link.url.path.hasPrefix("/Nitrate/"))
        }
    }

    /// The support route is the published support page, which carries the public
    /// contact address. Nothing here may open a mail client.
    @Test func noLinkIsAMailtoAddress() {
        for link in LegalLinks.all {
            #expect(link.url.scheme != "mailto")
        }
    }

    @Test func aboutShowsAllThreeLinksInOrder() {
        #expect(LegalLinks.all.map(\.title) == ["Privacy Policy", "Terms of Use", "Support"])
        #expect(LegalLinks.all.map(\.url.absoluteString) == [privacyURL, termsURL, supportURL])
    }

    /// The accessibility identifiers are the UI-test hooks, so they must be
    /// unique across the set and keep the exact spellings the tests query.
    @Test func accessibilityIdentifiersAreStableAndUnique() {
        #expect(LegalLinks.all.map(\.accessibilityID)
            == ["settings.legal.privacy", "settings.legal.terms", "settings.legal.support"])
        #expect(Set(LegalLinks.all.map(\.accessibilityID)).count == LegalLinks.all.count)
        #expect(Set(LegalLinks.all.map(\.id)).count == LegalLinks.all.count)
    }

    /// Every Settings channel — a free trial, an expired trial, a paid checkout,
    /// a development build and the TestFlight beta — shows the whole set. The
    /// section is not gated on entitlement, so a locked-out user can still read
    /// the policy before paying.
    @Test func everyAccessChannelRetainsTheFullLinkSet() {
        for channel in LegalLinks.Channel.allCases {
            #expect(LegalLinks.visibleLinks(for: channel) == LegalLinks.all)
        }
    }

    @Test func accessChannelsCoverFreeAndPaidCases() {
        #expect(Set(LegalLinks.Channel.allCases.map(\.rawValue))
            == ["development", "beta", "trialActive", "trialExpired", "purchased"])
    }
}
