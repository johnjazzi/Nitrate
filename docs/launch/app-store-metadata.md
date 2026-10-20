# App Store metadata packet — owner review required

Nothing in this packet has been entered in App Store Connect or submitted. The
existing record name and bundle ID were supplied by the owner; account settings
have not been read back. Locale `en-US` is a proposal, not a verified account setting.

Pasteable field values are in `app-store-metadata.en-US.json`. This is a handoff
file, not a supported App Store Connect import format. The description is a factual
draft; the author intro remains empty. No mission, founder story, testimonial or
claim of film calibration has been supplied on the author's behalf.

## Listing fields

| Field | Proposed value | Validated length / limit |
|---|---|---|
| Name | nitrate.camera | 14 / 30 characters |
| Subtitle | Film emulation for video | 24 / 30 characters |
| Primary category | Photo & Video | Proposal |
| Secondary category | None | Proposal |
| Promotional text | See JSON | 159 / 170 characters |
| Keywords | See JSON | 84 / 100 UTF-8 bytes |
| Factual description | See JSON | 1432 / 4000 characters |

Apple documents the name/subtitle constraints in App Information and the other
text constraints in Platform Version Information. Keywords are limited in bytes,
not simply characters. Recheck the final description after adding author copy.[1][2]

The factual draft covers Apple Log 2, hardware eligibility, capture, deferred
rendering, on-device processing and the actual access model. It does not advertise
editing, live full-effect preview, cloud backup, sensor RAW, open-source licensing,
an exact film match or compatibility with every iPhone. It avoids competitor names
and film-company trademarks in search keywords.

### Owner fields intentionally unset

- Support URL: a real public page with a working contact route, not a made-up address.
- Privacy policy URL: a published policy approved by the owner.
- Terms URL / EULA selection: choose and link the actual applicable terms.
- Marketing URL: optional; omit until there is a real destination.
- Copyright: legal rights-holder text, not inferred from the developer team name.
- App Review contact, TestFlight feedback email and primary language confirmation.
- Prices, subscription availability, storefronts, content-rights declaration and
  final age-rating answers. No fabricated prices or automatic legal declarations.

Support information and policy links must be real. Apple requires the privacy
policy both in listing metadata and somewhere readily accessible inside the app.[1][5]

## Purchase localization

| Product | Type | Display name | Description |
|---|---|---|---|
| com.nitrate.subscription.yearly | Auto-renewable, 1 year | Nitrate Yearly | Film-look rendering for one year. |
| com.nitrate.lifetime | Non-consumable | Nitrate Lifetime | One-time unlock for film-look rendering. |

Display names fit within 30 characters and both descriptions fit within the
conservative 45-character IAP description limit. The final subscription-specific
fields must also be checked in its own App Store Connect form.[3]

The 3.00 / 10.00 values in `StoreKit/Nitrate.storekit` match the owner-approved
US base prices and are used for local testing; App Store Connect remains the
source of truth for every other storefront. No introductory offer is claimed or
configured by this packet.

## Review and TestFlight text

The JSON includes separate drafts for:

- App Review notes: capability requirements, capture → render → Photos steps,
  no app sign-in, production access and unrestricted TestFlight behavior.
- TestFlight description: compatible hardware, unrestricted beta, disposable footage.
- What to test: audio, permissions, orientation, controls, queue recovery and retry.

Before submitting, attach real evidence from the submitted build on supported
hardware. Do not present a simulator, a sample render or a purchase-policy unit test
as proof of the complete capture/purchase path. No demonstration video, product
review screenshot or purchase/restore sandbox result has been created in this pass.

## Privacy questionnaire worksheet — proposed, not filed

The source scan found no custom networking client, analytics SDK, advertising
integration, ML framework, external URL or in-app policy link. StoreKit handles
purchases. `PrivacyInfo.xcprivacy` declares no tracking and an empty collected-data
array; that manifest is not a substitute for completing the questionnaire.

Apple defines on-device-only processing differently from collection and says
developers need not disclose data Apple collects independently.[4]

| Area | Source behavior | Proposed answer / action |
|---|---|---|
| Photos/video/audio | Captured and processed locally; Photos add permission requested for saving | Not developer-collected through this implementation |
| Tracking/advertising | No integration found; manifest tracking is false | No tracking proposed |
| Purchases | StoreKit verification and local access state; no developer server found | Do not invent a developer subscriber database |
| Analytics/diagnostics | No third-party collector or upload found | No developer collection found in source scan |
| Support feedback | Destination and workflow not chosen | Review before final answers; submitted footage or email can change obligations |
| Photos/iCloud | App saves to the system photo library | Avoid promising that footage can never leave the phone; user-controlled Photos syncing/sharing is separate |

If support uploads, analytics, crash services or a backend are added, reassess the
answers. Approve the policy, then answer from the final binary and actual services.

## Screenshots and review assets still needed

Capture real, non-sensitive footage in the actual Release app. Suggested order:

1. Camera with stock selection and a genuine viewfinder image.
2. Stock/gauge controls.
3. Manual controls in a supported layout.
4. Storage & Queue showing a real rendering/completed state.
5. A real rendered result, with no fake before/after or invented performance number.

Use Apple's current accepted dimensions for the device family. The current large
Dynamic Island iPhone table accepts portrait 1260×2736, 1290×2796 or 1320×2868
(and their landscape reversals); confirm the slot before upload. Do not stretch a
smaller capture or fabricate camera output to fill it.[6]

**Device-family mismatch:** both inspected Release and archive Info.plists declare
`UIDeviceFamily = [1, 2]` (iPhone and iPad), while this packet describes an iPhone
camera with strict Apple Log 2 requirements. Resolve this before screenshots and
submission: either intentionally support/test iPad and supply its metadata/assets,
or make an explicitly approved iPhone-only target change. No target change was
made in this documentation pass.

## Submission risks found during metadata reconciliation

1. **Missing policy/terms links.** No external link or URL was found in the Swift
   source. Policy hosting and an accessible in-app policy link remain unfinished.
   Review subscription disclosures and applicable terms before submission.[5]
2. **Purchase wording now matches the render-only gate.** `PurchaseView.swift` no
   longer says “Unlock to continue using Nitrate” or “All features unlocked
   forever”. The paid feature is named as film rendering throughout, an annual
   subscriber is described as “subscription active” rather than permanently
   unlocked, and recording is stated to stay free. An unrestricted channel
   (development/DEBUG and the beta) shows a non-purchasable “US launch pricing”
   block instead of a checkout, with no fallback purchase price.
3. **Local StoreKit testing now resolves the paywall directly.**
   `StoreManager.resolveDistribution()` returns `.debug` before consulting
   StoreKit in a normal Debug build, so the paywall is invisible; the
   `-NitrateStoreKitTesting` opt-in now resolves straight to `.storeKitTesting`,
   bypassing the receipt guard that would otherwise return `.development`.
   Purchases and entitlements still run through real StoreKit. The remaining
   step is an actual run of that flow (build and capture the UI), which is owned
   by the coordinating agent.
4. **Evaluation policy needs review.** Earlier guidance that Apple only permits
   “free trial” to mean an introductory subscription offer was too broad. The
   guidelines also describe a non-subscription time-based-trial mechanism. That
   does not establish acceptance of this app's mixed subscription/lifetime,
   local-timer model. Use literal evaluation wording; assess the implementation
   against the applicable guidelines rather than relying on renaming it.[5]
5. **Rights remain an owner decision.** Verify film-stock names, assets, code and
   footage rights before the content-rights declaration. Do not imply endorsement.

These are open issues, not a claim that App Review has rejected the app.

## Evidence anchors in the repository

- `project.yml`: bundle ID, minimum OS, purpose strings and linked frameworks.
- `App/Modules/CameraCapture/CameraPolicies.swift`: 3840×2160, Apple Log 2,
  24 fps and ten-bit capture-format filter.
- `App/Modules/Purchase/AppAccessPolicy.swift`: product IDs, local seven-day
  duration, subscription expiry and lifetime entitlement behavior.
- `App/Modules/Purchase/StoreManager.swift`: distribution resolution and StoreKit.
- `App/Modules/Purchase/PurchaseView.swift`: user-facing purchase labels.
- `App/Modules/RenderQueue/RenderQueueViewModel.swift`: paid render job-start gate,
  original-only delivery and Photos authorization.
- `App/PrivacyInfo.xcprivacy`: tracking and required-reason declarations.
- Inspected archive: `build/verification/Nitrate.xcarchive/Products/Applications/Nitrate.app/Info.plist`.

## Handoff

Approve or replace the short listing fields and the factual description. Supply
real policy/support destinations, legal-owner/contact details and final prices.
Resolve the device-family, purchase-text and purchase-test findings before upload.
Keep author copy and authentic screenshot creation separate from this packet.

## Sources

[1] https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information
[2] https://developer.apple.com/help/app-store-connect/reference/app-information/app-information
[3] https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information
[4] https://developer.apple.com/app-store/app-privacy-details
[5] https://developer.apple.com/app-store/review/guidelines
[6] https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
