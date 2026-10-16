# Subscriptions, entitlement tracking and the developer exemption

October 15, 2026.

## You do not build subscription tracking

Apple already tracks who has a subscription, and the app already reads it. There is no database, no user accounts and no server to run.

| Question | Where the answer lives |
|---|---|
| Does *this* device's Apple ID currently own the product? | StoreKit `Transaction.currentEntitlements` — Apple's signed, verified record. This is what the app reads to unlock features |
| How many subscribers, renewals, cancellations, refunds, revenue? | App Store Connect → **Subscriptions** and **Sales and Trends** reports |
| Who, by name? | Not available without your own account system. Deliberately not built |

`Transaction.currentEntitlements` is the tracking. It is signed by Apple, so a user cannot forge it, and it updates when a subscription renews, expires or is refunded — which is why the app recomputes access on every launch and foreground rather than storing a "subscribed" flag.

Do not add a receipt-validation server or a subscriber table for launch. It buys nothing that StoreKit does not already give you, and it creates a data-protection obligation you would then have to honour.

If you ever want per-person visibility — support, or your own analytics — the Apple-supported route is **App Store Server Notifications** plus a backend. That is a post-launch decision, not a launch requirement.

## What the app does now

Access is decided from the verified install channel, never from a user-editable flag:

| Channel | How it is detected | Access |
|---|---|---|
| Development | Signed locally, **no App Store receipt** | Unrestricted — the developer is never blocked |
| Debug | `#if DEBUG` build | Unrestricted |
| TestFlight | Verified StoreKit environment is `.sandbox` | Unrestricted — testers never check out |
| App Store | Verified environment is `.production` | 7-day local evaluation, then a verified, non-revoked, non-expired purchase |
| Unknown | Store cannot answer and nothing was ever verified | Falls back to the trial; never a free grant |

**Recording is never gated.** When the evaluation ends without a purchase, capture keeps working and only *rendering the film look* is held: the take is written, durably queued, and renders as soon as access returns. Nothing the user shot is ever trapped behind a paywall.

Two properties make the development exemption safe:

1. An App Store install **always** has a receipt, so a real customer cannot land in the development channel.
2. The development channel is never cached, so it cannot leak into a later App Store install on the same device.

Settings shows a **Development Build** banner when this applies, and the app prints one `[access]` line per resolution because it writes no log file:

```
[access] channel=development unrestricted=true trialActive=false trialDaysRemaining=0 verifiedPurchases=0 canUsePaidFeatures=true
```

## Known limits

- **The 7-day evaluation is local.** It is anchored to the first launch and can be reset by reinstalling. A device-side trial cannot be made tamper-proof; a real time-limited offer would need an Apple-managed introductory offer on the subscription instead.
- **Nothing here proves a real purchase works.** Purchase, renewal, expiry, refund and restore still need sandbox transactions on a device.
- **TestFlight access is not a free production licence.** A beta tester's install expires with the build; production access is separate.
- **Do not gate recovery or export of already-captured footage behind payment.** A kept-original rescue job bypasses the render gate entirely, so a lapsed user can always retrieve what they shot.
- **The trial is resettable by design.** That is the chosen trade-off for a try-before-you-subscribe model; an Apple-managed introductory offer would be tamper-proof but would require subscribing before the app could be used at all.
