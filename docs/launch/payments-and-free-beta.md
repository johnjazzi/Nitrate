# Payments and a free TestFlight beta

October 15, 2026. **Owner decision: the beta is unrestricted.** Production pricing and agreements have not been configured or accepted in App Store Connect by the agent.

## “Internal” means you

Apple's internal testers are eligible users of your App Store Connect account. As a solo developer, that can just be you installing the uploaded build once. Friends and community testers use external TestFlight; do not add them to your developer account to distribute a beta.[18][1]

This is a sanity check of Apple's processed distribution build, not a demand for employees or an internal team. Then invite a small external group after applicable beta review.[1]

## Testers do not need to pay

The intended app policy grants full access in genuine TestFlight beta distribution, without asking testers to subscribe or buy lifetime. A verified distribution/entitlement decision must distinguish beta from production: no UserDefaults switch or unconditional Release unlock. Until integrated and verified, this is implementation work in progress—not a claim about the installed build.

If you separately test purchases, TestFlight runs in Apple's sandbox; sandbox purchases do not incur charges. Sandbox transaction testing and unrestricted beta access are different things: the latter avoids checkout entirely.[14][15]

Unrestricted beta access is not a promise of a free lifetime production licence. Keep that distinction clear in invitations; decide any thank-you grant later rather than inventing a durable entitlement from a beta install. A TestFlight build expires after its testable window even if app features are unlocked.[1]

## Set up real production payments — owner checklist

You do not need a company/team just to understand this workflow; use the seller/account type you actually enrolled under. No account enrollment or identity/tax advice is inferred from local code signing.

1. In App Store Connect, open **Business** and review/sign the **Paid Apps Agreement** as Account Holder. Do not have an agent accept legal terms on your behalf.[8]
2. Enter your payout bank details and the tax information Apple requests. Banking and tax submission require the paid agreement; Apple verifies the submitted account information. Enter confidential values directly in Apple's authenticated UI, not chat.[16][17]
3. Open the **nitrate.camera** app record, bundle ID `com.nitrate.app`. The product identifiers below come from source and are **not** registered in App Store Connect.
4. If retaining lifetime access: **Monetization → In-App Purchases → + → Non-Consumable**, with product ID **`com.nitrate.lifetime`**. Set approved localizations, actual price/availability and review information. A non-consumable is the appropriate one-time non-expiring purchase type.[21]
5. If retaining the yearly option: **Monetization → Subscriptions**, create the subscription group, then product **`com.nitrate.subscription.yearly`**, duration **1 year**. Configure price, availability, localized terms and review information. Do not create a subscription solely because a source comment names a dollar price.[20]
6. Test the actual products with StoreKit sandbox: purchase, cancel/pending, restoration, expiry and refund/revocation. A UI “Restore Purchases” must make an explicit restore request and report errors; don't infer working commerce from a successful build.[15]
7. Submit the intended products for review with the required app submission. Apple requires the first auto-renewable subscription/group to accompany a new app version. Production availability is separate from a sandbox test.[20]
8. Verify production prices shown in the app come from localized StoreKit products—not hard-coded fallback dollar strings. Keep beta access separate from production entitlement handling.

## Decisions deliberately not made

- No changes to actual App Store prices. Existing source product IDs are preserved.
- No payment processor/backend is added by this plan; the app's existing digital-unlock path is StoreKit.
- No claim that the local seven-day evaluation is an Apple-managed introductory offer. Configure and test any subscription offer explicitly before calling it one.[5]
- No fees, payout dates, tax treatment or approval turnaround is promised here; consult the account's current agreement and applicable professional advice for those decisions.

## Agent vs owner

Agent: fix beta/production access handling, entitlement refresh/restore, product-load errors and honest pricing UI; prepare metadata and test cases. Owner: Apple account authorization, agreements, identity/bank/tax fields, actual price choice and publication approval. No credit-card/banking values, password or private key should be supplied in chat.

## Sources

[1] https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview
[5] https://developer.apple.com/app-store/review/guidelines
[8] https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements
[14] https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight
[15] https://developer.apple.com/help/app-store-connect/test-in-app-purchases/overview-of-testing-in-sandbox
[16] https://developer.apple.com/help/app-store-connect/manage-banking-information/enter-banking-information
[17] https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information
[18] https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers
[20] https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions
[21] https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/create-consumable-or-non-consumable-in-app-purchases
