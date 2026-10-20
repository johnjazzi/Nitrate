# Testing the paywall with StoreKit

The app ships an in-app seven-day evaluation of **rendering**. Recording is never
gated. To exercise the real paywall — evaluation, purchase, restore, expiry,
refund — without an App Store Connect product, run the app against the local
StoreKit configuration file at `StoreKit/Nitrate.storekit`.

## Why a dedicated scheme

`StoreManager.resolveDistribution()` short-circuits to `.debug` (unrestricted) in
every Debug build, so a normal run never reaches StoreKit and the paywall stays
invisible. To reach it, the `NitrateStoreKitTest` scheme launches a Debug build
with the launch argument `-NitrateStoreKitTesting`. `StoreManager` sees that
argument and resolves the channel straight to `AccessDistribution.storeKitTesting`,
which `AppAccessPolicy` treats exactly like the App Store (an evaluation, then a
verified purchase).

The opt-in must resolve the channel directly. The ordinary fall-through path
cannot reach the fixture: it first checks for an App Store receipt, and a Debug
build has none, so it returns `.development` — a free unlock that leaves the
paywall invisible and the fixture inert. Resolving `.storeKitTesting` directly
skips that receipt guard, while every `Product.purchase` and `Transaction` call
still goes through real StoreKit against the active configuration file. Nothing
is fabricated.

- Normal development (`Nitrate`, `NitrateDev`) never passes the argument and
  stays unrestricted — no paywall, no checkout. They still carry the fixture for
  local StoreKit runs, but without the argument it is inert: the debug unlock
  short-circuits before StoreKit is consulted.
- Release never honours the argument: the debug override is compiled out of a
  Release build, so a production receipt or an offline grant is decided by the
  store exactly as before.
- `storeKitTesting` is not cacheable, so a testing channel is never remembered as
  a real install.

The configuration lives at `StoreKit/Nitrate.storekit` and is wired into the run
actions by `project.yml`. It is kept outside `App/` deliberately: anything under
`App/` is compiled or bundled, and a test fixture must never ship in the App
Store binary.

## Products in the fixture

| Product ID | Type | Fixture price (USD) |
| --- | --- | --- |
| `com.nitrate.subscription.yearly` | Recurring subscription, `P1Y` | 5.00 |
| `com.nitrate.lifetime` | Non-consumable | 10.00 |

These are the owner-approved US base prices. The live checkout never hardcodes
them: a purchase button shows `Product.displayPrice` from StoreKit and stays
disabled until the product loads. The only fixed amounts are the non-purchasable
**US launch pricing** preview shown on unrestricted channels (normal Debug, a
development install, and the beta), which is display-only and never drives a
purchase. App Store Connect remains the source of truth for other storefronts.

These IDs must match `PaidProduct` in
`App/Modules/Purchase/AppAccessPolicy.swift`, which is pinned by
`Tests/AppAccessPolicyTests.swift`. Change both together.

## Running the flows

Run the **`NitrateStoreKitTest`** scheme in a simulator. The camera screen needs
Apple Log 2 hardware, so use **Settings** for the purchase UI. Every run must go
through this scheme — the plain `Nitrate` scheme carries no configuration file
and no argument, so it never shows the paywall.

The Debug configuration's bundle id is `com.nitrate.app.dev` (Release uses
`com.nitrate.app`). The `simctl` command below targets the Debug id.

**Evaluation active.** Delete the app, then run. The evaluation starts at first
launch and Settings shows the days remaining.

**Evaluation expired.** The anchor is `install_date` in the app's `UserDefaults`.
Write it into the past before launching (or relaunch after writing):

```sh
xcrun simctl spawn booted defaults write com.nitrate.app.dev install_date -date "2020-01-01 00:00:00 +0000"
```

Now rendering is held: capture still works, the take is durably queued, and
**Storage & Queue** shows "Rendering is paused".

**Purchase.** Tap Subscribe or Buy. The StoreKit test sheet appears; confirm.
`canUsePaidFeatures` flips and any held job renders automatically.

**Restore.** Delete the app, reinstall, and run again. The evaluation restarts
because the anchor is gone, but a purchase made under the fixture persists for
the simulator, so **Restore Purchases** returns the entitlement.

**Expiry and renewal.** Use Xcode's **Debug → StoreKit → Manage Transactions**
to expire, renew, or refund the subscription, then foreground the app.

The evaluation must already be expired for expiry/refund to be observable: a
lapsed subscription or a refunded purchase falls back to a still-active
evaluation, so access would stay unlocked. Set `install_date` past the seven-day
window (as above) *before* purchasing, then expire or refund. Access then drops
and the held render stays queued; neither deletes footage.

**Failure paths.** The fixture's `settings` block can enable failed transactions
so the error and retry UI can be exercised.

## What this does not cover

- Real App Store receipt validation. The fixture signs its own transactions.
- Sandbox behaviour, which differs from both the fixture and production.
- Anything that depends on the products existing in App Store Connect.
- The `AppTransaction.shared` / `appStoreReceiptURL` migration path, which is
  guarded by `#if DEBUG` and can only be verified against a real App Store
  install.

Those are covered by TestFlight once the products are registered.
