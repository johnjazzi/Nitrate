# Getting Nitrate into the App Store

October 15, 2026. Ordered so each step only needs the previous one. Nothing here has been done for you: no app record was created, no agreement accepted, no price chosen, no build uploaded.

Official sources for every Apple step are listed at the end.

## Blocker — there is no distribution certificate

A Release archive was produced and inspected. The blocker is outside the repository:

- This machine holds two code-signing identities, `Developer ID Application` and `Apple Development`, and **no Apple Distribution certificate**. An App Store upload requires one.
- `xcodebuild archive` therefore produced an archive signed with **Apple Development**, carrying `get-task-allow = true` under an `iOS Team Provisioning Profile: *`.

That archive is not uploadable as it stands, but the reason is the missing certificate, not a build-setting mistake. A development-signed archive is the normal result of archiving locally without a distribution certificate, and the **App Store export re-signs it** — `xcodebuild -exportArchive` with the App Store Connect method, or Xcode Organizer → Distribute App. Do not hand the archive to Transporter directly.

Creating a distribution certificate is an account-level change, so it has not been done. Xcode offers to create one the first time you distribute, or you can create it in the developer portal under Certificates, Identifiers & Profiles. Once it exists, export and re-check that `get-task-allow` is gone from the exported build.

Everything else about the archive inspected clean: bundle `com.nitrate.app`, version `0.1.0` build `1`, minimum iOS `27.0`, arm64 only, `PrivacyInfo.xcprivacy` present, LUTs, grain and `stocks.json` bundled, and no debug-only entry points in the binary.

## Step 0 — The record already exists

The App Store Connect record is **nitrate.camera**, bundle ID **`com.nitrate.app`**, so the code must use exactly that identifier — an upload whose bundle ID differs from the record is rejected. `project.yml` has been set to `com.nitrate.app` and the built `Info.plist` verified.

An earlier identifier, `com.filmemulation.app`, appears throughout the history and is still used by the `com.filmemulation.*` movie metadata keys. It is not published: an App Store lookup for it returns no app. If an unused App ID for it sits in the developer portal, deleting it is optional housekeeping.

Do not create a second app record. An identifier that has shipped can never be reused for a different app.

## Step 1 — Account and agreements (Account Holder only)

1. Confirm your Apple Developer Program membership is active.
2. In App Store Connect → **Business**, review and sign the current **Paid Apps Agreement** if you intend to sell the subscription or lifetime unlock. You cannot add banking or tax details before this is signed.[8]
3. Add your **banking** information and complete the **tax** forms. Apple verifies what you submit; these are payout details, not app configuration.[16][17]

Enter these yourself, in Apple's authenticated UI. Do not send bank details, tax IDs, passwords or keys through chat.

If you are not selling yet, you can still ship a free app — skip the agreement and the two purchase products, and the access policy will treat every production user as being on the local 7-day evaluation.

## Step 2 — Create the app record

In App Store Connect → **Apps** → **+** → **New App**:[3]

| Field | Value |
|---|---|
| Platform | iOS |
| Name | `nitrate.camera` (already registered) |
| Primary language | Your language |
| Bundle ID | `com.nitrate.app` |
| SKU | Any internal ID, e.g. `nitrate-ios-001`. Never shown to users |
| User access | Full access |

## Step 3 — App privacy (required)

1. **Privacy policy URL is required for every app.** Host your policy at a public URL and enter it under **App privacy → Privacy Policy**. A user privacy choices URL is optional.[4][5]
2. Complete the **App Privacy** questionnaire. Answer from what the app actually does. The reviewed code has no analytics, no network client of its own, no machine-learning frameworks, and no third-party SDKs — its only network use is Apple's StoreKit. Do not claim "no data collected" for Apple services you did not examine.
3. Keep the in-app privacy link: the guidelines require an accessible policy link inside the app as well as in the listing.[5]
4. The app ships a `PrivacyInfo.xcprivacy` declaring the required-reason APIs it uses (user defaults, boot time, disk space, file timestamps) with the approved reasons for each.[6]

## Step 4 — Listing metadata

| Item | Notes |
|---|---|
| Category | Photo & Video |
| Age rating | Complete the questionnaire honestly |
| Content rights | You own or have rights to everything in the app |
| Support URL | Required — a page with a contact route |
| Marketing URL | Optional |
| Description / keywords / subtitle | Yours to write |

**Screenshots:** at least one set for the required iPhone size class, captured from the actual app. App previews are optional and must show real behaviour.[12] Capture from the device or a simulator — do not invent dimensions, and confirm the current required sizes in App Store Connect when you upload.

## Step 5 — Export compliance

When you upload, App Store Connect asks about encryption. Answer truthfully for the binary you actually built: this app implements no cryptography of its own and links no crypto library; its only secure traffic is Apple's StoreKit. Read the questions rather than assuming the exemption applies, and record the answer you gave.

## Step 6 — Products (only if you are selling)

Lifetime unlock — **Monetization → In-App Purchases → + → Non-Consumable**, product ID `com.nitrate.lifetime`.[21]

Yearly subscription — **Monetization → Subscriptions → create a subscription group → Create**, product ID `com.nitrate.subscription.yearly`, duration **1 year**.[20]

For each: reference name, localized display name and description, price, availability, and review information. Note that **your first auto-renewable subscription must be submitted with a new app version**, and the price/duration cannot be changed after submission.[20]

Test the products with a sandbox account before relying on them; sandbox purchases do not incur charges.[15]

**Create these identifiers exactly as written.** App Store Connect will not let you change or delete a product identifier once the product exists — you can only stop selling it. The IDs above are the single source of truth in `PaidProduct` (`App/Modules/Purchase/AppAccessPolicy.swift`), pinned by a test; if you register something different, change the code and that test in the same commit.

## Step 7 — Build and upload

Before uploading, test the paywall locally against the StoreKit fixture in
`StoreKit/Nitrate.storekit` — see `storekit-testing.md`. It exercises evaluation,
purchase, restore, expiry and refund without any product existing in App Store
Connect, and it is the only way to see the paywall before a real App Store build,
because a development install is deliberately unrestricted.

```sh
cd ~/projects/untitled-ios-film-emulation-app
xcodegen generate
```

Then in Xcode: select the **Nitrate** scheme, destination **Any iOS Device (arm64)**, and **Product → Archive**. In the Organizer, **Validate App** first, then **Distribute App → App Store Connect → Upload**.[10]

Before each upload, increment `CURRENT_PROJECT_VERSION` in `project.yml` — the build string must be unique per upload.[2]

Current values: `MARKETING_VERSION` 0.1.0, `CURRENT_PROJECT_VERSION` 1, minimum iOS 27.

Note that Apple's current requirements state uploads must be built with Xcode 26 / the iOS 26 SDK or later; your installed Xcode 27 clears that floor, but re-check the requirements page at submission time.[9]

## Step 8 — TestFlight first

1. After the build processes, it appears under **TestFlight**.[1]
2. Complete **Test Information**: beta description, what to test, and a feedback email.[1]
3. **Internal testing:** add yourself — internal testers are users of your own App Store Connect account, so as a solo developer that is just you. Up to 100 are allowed.[18]
4. **External testing:** add testers or a public link. The **first build of an app goes to Beta App Review** before external testers can install it; builds remain testable for up to 90 days.[1]
5. TestFlight purchases run in Apple's sandbox. Because Nitrate grants unrestricted access in a genuine TestFlight install, testers are never asked to check out at all.[14]

## Step 9 — Submit for review

1. Select the processed build for the version.
2. Fill in **App Review Information**: contact details, and notes explaining that the camera requires a device advertising an Apple 4K/24 Apple Log 2 capture format on iOS 27+. Never tell reviewers that unsupported hardware will work.
3. Attach the products you want reviewed with this version.
4. Submit. The status moves to **Waiting for Review**; reply to any reviewer message from the submission page.[11]

## Step 10 — Release

Choose **manually release this version** so approval is separated from publication: after approval the version sits at **Pending Developer Release** until you release it, and it can take up to 24 hours to appear on the store.[13]

After it is live, verify the listing, a real purchase or restore, and one full capture → render → Photos save on production.

## What I can do versus what only you can do

**I can:** prepare and check metadata, keep the build reproducible, write release notes, prepare review notes, and run verification and archives.

**Only you can:** accept agreements, enter banking and tax details, choose names and prices, approve the privacy policy, and press upload, submit and release.

## Sources

[1] https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview
[2] https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds
[3] https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app
[4] https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy
[5] https://developer.apple.com/app-store/review/guidelines
[6] https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
[8] https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements
[9] https://developer.apple.com/news/upcoming-requirements
[10] https://developer.apple.com/documentation/Xcode/distributing-your-app-for-beta-testing-and-releases?changes=l_6
[11] https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/overview-of-publishing-your-app-on-the-app-store
[12] https://developer.apple.com/app-store/app-previews
[13] https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option
[14] https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight
[15] https://developer.apple.com/help/app-store-connect/test-in-app-purchases/overview-of-testing-in-sandbox
[16] https://developer.apple.com/help/app-store-connect/manage-banking-information/enter-banking-information
[17] https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information
[18] https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers
[20] https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions
[21] https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/create-consumable-or-non-consumable-in-app-purchases
