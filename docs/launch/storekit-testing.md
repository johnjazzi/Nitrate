# Testing the paywall with StoreKit

The app ships an in-app seven-day evaluation of **rendering**. Recording is never
gated. To exercise the real paywall — evaluation, purchase, restore, expiry,
refund — without an App Store Connect product, run the app against the local
StoreKit configuration file at `StoreKit/Nitrate.storekit`.

The configuration is already wired into the `Nitrate` scheme's run action by
`project.yml`, so running the scheme from Xcode uses it with no setup. It is kept
outside `App/` deliberately: anything under `App/` is compiled or bundled, and a
test fixture must never ship in the App Store binary.

## Why this works

When a StoreKit configuration file is active, `AppTransaction.shared` reports
`AppStore.Environment.xcode`. `StoreManager` maps that to
`AccessDistribution.storeKitTesting`, which `AppAccessPolicy` treats exactly like
`.appStore`: an evaluation, then a verified purchase. Without the file, a
locally signed build has no receipt and resolves to `.development`, which is
unrestricted — so the paywall is invisible. That is why the fixture is needed to
see it at all.

`storeKitTesting` is not cacheable, so a testing channel can never be remembered
as a real install.

## Products in the fixture

| Product ID | Type | Fixture price |
| --- | --- | --- |
| `com.nitrate.subscription.yearly` | Recurring subscription, `P1Y` | 4.99 |
| `com.nitrate.lifetime` | Non-consumable | 9.99 |

The fixture prices are placeholders. Real prices come from App Store Connect, and
the app never hardcodes them.

These IDs must match `PaidProduct` in
`App/Modules/Purchase/AppAccessPolicy.swift`, which is pinned by
`Tests/AppAccessPolicyTests.swift`. Change both together.

## Running the flows

Build and run the `Nitrate` scheme in a simulator. The camera screen needs Apple
Log 2 hardware, so use **Settings** for the purchase UI.

**Evaluation active.** Delete the app, then run. The evaluation starts at first
launch and Settings shows the days remaining.

**Evaluation expired.** The anchor is `install_date` in the app's
`UserDefaults`. Push it into the past and relaunch:

```sh
xcrun simctl spawn booted defaults write com.nitrate.app install_date -date "2020-01-01 00:00:00 +0000"
```

Now rendering is held: capture still works, the take is durably queued, and
**Storage & Queue** shows "Rendering is paused".

**Purchase.** Tap Subscribe or Buy. The StoreKit test sheet appears; confirm.
`canUsePaidFeatures` flips and any held job renders automatically.

**Restore.** Delete the app, reinstall, and run again. The evaluation restarts
because the anchor is gone, but a purchase made under the fixture persists for
the simulator, so **Restore Purchases** returns the entitlement.

**Expiry and renewal.** Use Xcode's **Debug → StoreKit → Manage Transactions**
to expire, renew, or refund the subscription, then foreground the app. Expiring
removes access; a refund revokes it. Neither deletes footage.

**Failure paths.** The fixture's `settings` block can enable failed transactions
so the error and retry UI can be exercised.

## What this does not cover

- Real App Store receipt validation. The fixture signs its own transactions.
- Sandbox behaviour, which differs from both the fixture and production.
- Anything that depends on the products existing in App Store Connect.

Those are covered by TestFlight once the products are registered.
