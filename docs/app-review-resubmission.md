# App Review resubmission: beta UI and missing purchases

Applies to rejection of submission `b20af7c0-0344-4a1e-ae04-0e5011dbde92`, reviewed November 10, 2026, version 1.0 (74).

## Source corrections

- Remove the shared BETA suffix from splash and Settings version text.
- Treat StoreKit sandbox as a customer checkout environment, not proof of TestFlight or an unrestricted grant. App Review also uses sandbox.
- Do not infer development access from an absent receipt. Resolve the verified AppTransaction environment; unresolved installations receive only their existing evaluation or verified purchase.
- Keep unrestricted development access behind DEBUG or the explicit local DevRelease compiler condition, never production Release.
- Load real products and verified entitlements in sandbox. Preserve the exact product IDs `com.nitrate.subscription.yearly` and `com.nitrate.lifetime`.
- Keep Restore Purchases reachable after a purchase as well as before one.

The twenty-day local evaluation, pricing, and render-only gate are unchanged. TestFlight no longer bypasses checkout; testers can use a free sandbox purchase after the evaluation. This does not grant an App Store entitlement after launch.

## Gates before upload

1. Run `python3 scripts/verify.py verify`, then `python3 scripts/verify.py device`. No build or device claim is established by pure policy tests or a typecheck.
2. Reconcile the source marketing version with the App Store Connect version being resubmitted (the rejection lists 1.0). This branch is based on main's 0.8.1 and prepared as the next patch, 0.8.2 (37); confirm the intended App Store version before replacement distribution. Follow `AGENTS.md`, regenerate, and inspect the packaged version. Xcode Cloud supplies its increasing distribution build counter; do not reuse build 74 or alter an existing archive.
3. Archive the **Nitrate / Release** scheme, not NitrateDev, DevRelease, or NitrateStoreKitTest. Inspect the built bundle ID `com.nitrate.app`, version/build, and actual UI. Neither DEBUG nor NITRATE_LOCAL_DEVELOPMENT may be active in the production archive.
4. Upload the authorized replacement and select that exact processed build in the rejected App Store version. Existing build 74 does not acquire these source changes.

## Account checks (not yet verified)

In App Store Connect, select Nitrate:

1. Under **Business**, confirm the Paid Apps Agreement is in effect and banking/tax information is complete.
2. Under **Monetization → Subscriptions**, open Nitrate Yearly. Check its product ID exactly matches `com.nitrate.subscription.yearly`, price, availability, localization and review information. Address its rejection and include it in the resubmission.
3. Under **Monetization → In-App Purchases**, do the same for Nitrate Lifetime (`com.nitrate.lifetime`, non-consumable).
4. Include both intended products with the replacement app submission. Do not delete or recreate the IDs as a troubleshooting step.
5. Keep the EULA and privacy policy links in the public app description and the Privacy Policy URL field populated. Source changes do not modify listing metadata.

## Physical-device evidence

Use the replacement **production-identity TestFlight build** for real App Store Connect sandbox products, not Nitrate Dev with a local `.storekit` fixture. Record the actual phone screen; never fabricate or splice a purchase success screen.

Before recording, verify the installed version/build in Settings. Use disposable clips. Protect any real queued footage; do not uninstall the app merely to reset purchases or the evaluation.

Capture the following; separate takes/accounts can demonstrate the two alternative paid products:

1. Begin at the Home Screen and launch Nitrate.
2. Grant permissions as applicable; record a short clip with audio, render it and show the saved result in Photos.
3. Open Settings → Pricing during the evaluation. Show real localized prices, active Yearly and Lifetime buttons, Terms/Privacy links and Restore Purchases. No BETA, Unrestricted Beta, Development Build or display-only launch-price preview should appear.
4. Complete a sandbox purchase of Nitrate Yearly. Show Apple's sheet and the app's subscription-active state afterward. Cancel an attempt separately and verify the UI remains usable.
5. With a separate sandbox account or a deliberately reset sandbox purchase history, demonstrate Nitrate Lifetime and the lifetime-unlocked state. A yearly purchase is not evidence of a lifetime purchase. Do not sign out of the device's main iCloud account; use Apple's sandbox-account controls where needed.
6. Demonstrate Restore Purchases and restored access. Distinguish restoring an existing entitlement from a purchase that never existed. Test expiry/refund with the evaluation already elapsed so evaluation access cannot mask the outcome.
7. Attach the physical-device recording(s) through App Review Information as requested in the rejection, and provide exact navigation steps. If no in-app account is required, state that rather than inventing demo credentials.

If products are missing or a purchase fails, save the exact product error, app build, phone model, iOS version and account/product state; do not claim this rejection resolved from source tests.

## Response draft — use only after the gates above pass

> We have removed the beta labels and unrestricted beta presentation from the submitted app. We corrected sandbox access handling so App Review can access the same Yearly and Lifetime purchase controls as customers, including during the evaluation period. Both products are loaded through StoreKit and use verified transactions. Restore Purchases remains available in Settings → Pricing.
>
> We have resubmitted the corrected build with Nitrate Yearly and Nitrate Lifetime and attached physical-device recordings showing the core capture/render/save workflow, successful sandbox purchases, and restore. The app does not require an in-app account. Purchase controls are located at Settings → Pricing.

Edit the draft to match what was actually verified and submitted. Do not send it before the recordings and replacement build exist.

## Apple references

- Configure In-App Purchases for review in the sandbox: https://developer.apple.com/help/app-review/before-submitting-for-review/configure-in-app-purchases/
- Troubleshooting sandbox product availability (TN3186): https://developer.apple.com/documentation/technotes/tn3186-troubleshooting-in-app-purchases-availability-in-the-sandbox
- Testing environments, including free TestFlight sandbox purchases: https://developer.apple.com/documentation/storekit/testing-at-all-stages-of-development-with-xcode-and-the-sandbox
- Review guideline 2.2: https://developer.apple.com/app-store/review/guidelines/#beta-testing
