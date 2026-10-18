# Nitrate: TestFlight → App Store

Prepared October 15, 2026. This is a submission runbook, not evidence that an upload or Apple review has happened. Recheck Apple's linked requirements at upload time. No App Store Connect account or app record has been inspected in this session.

## Current repository evidence

- Reviewed base: `150ca6f` on `dev`.
- `project.yml`: bundle `com.nitrate.app`; development team `U43C6BCZFS`; version `0.1.0`; build `1`; deployment target **iOS 27**; archive configuration Release.
- Local Xcode reports 27.0. A signed development build is not a distribution archive or successful App Store validation.
- Required capture format is checked at runtime; additionally `CameraSession.swift:784–786` refuses writer setup below **iOS 27**, despite the install target of 17 and current README's capture claim of 26. Resolve minimum OS or a tested backport before recruiting testers; runtime format detection alone does not clear this mismatch.
- No tracked `PrivacyInfo.xcprivacy`, general project LICENSE, distribution export configuration, or release automation was found in the initial file inventory. Separate audit reports determine remediation; absence of a file alone is not a completed compliance assessment.
- StoreKit source identifiers: `com.nitrate.subscription.yearly`, `com.nitrate.lifetime`. These are **not yet registered** in App Store Connect; availability, prices, agreements and review status are unknown.
- Disk at initial prelaunch inspection: 191 MiB free. Do not archive or upload until space has been recovered and verified.

## Gate 0 — owner decisions and access

Owner-only / approval required:

- [ ] Confirm an active Apple Developer Program account, seller identity and the intended App Store Connect team. Local signing does not prove this.
- [ ] Confirm whether an app record already exists for the unchanged bundle ID. Do not create a duplicate or rename the identifier.
- [ ] Account Holder accepts current agreements; decide territories and business setup. Paid distribution requires the relevant commercial setup; verify its state in Business rather than assuming it from development signing.[3][8]
- [ ] Confirm support email, public privacy-policy location and support-page location.
- [ ] Confirm monetization, actual prices, and what the local seven-day evaluation means. Do not describe a local app timer as an Apple-managed subscription offer without configuring and testing that offer.[5]
- [ ] Choose the repository licence deliberately. Public source currently has no general licence; do not advertise reuse rights before a licence decision.
- [ ] Supply founder/mission copy and approve actual sample-footage use. These are not generated launch claims.

## Gate 1 — release candidate readiness

Agent work, with explicit evidence:

- [ ] Triage independent security and correctness reports; block external testing on unresolved critical/high issues affecting media, entitlement or privacy correctness.
- [ ] Reconcile device/OS support with runtime capture requirements; make unsupported hardware explicit in the listing and tester instructions.
- [ ] Implement and package a truthful privacy manifest for any covered APIs actually used. `UserDefaults`, uptime and disk-space API usages require classification against Apple's required-reason list; select allowed reasons from actual use, not copied boilerplate.[6]
- [ ] Review data handling including Apple services, Photos/iCloud choices, logs and tester feedback. Prepare App Privacy answers; do not infer “Data Not Collected” solely from the absence of a custom network client.[4]
- [ ] Add an accessible in-app privacy-policy link and prepare public policy/support pages. Apple requires a privacy policy URL in App Store Connect and an accessible policy link in the app.[4][5]
- [ ] Test real StoreKit purchase, cancellation, restore, refund/revocation and expired entitlement in sandbox. Verify products and prices against the account. For a subscription, substantiate ongoing value and communicate terms.[5]
- [ ] Confirm Release excludes test entry points/forced grants and any private debug content; inspect the actual archive, not only Debug behavior.
- [ ] Run full tests, native UI tests, strict lint, Release archive validation and the physical-device checklist below. Save head SHA, results, device/OS and artifact identity.
- [ ] Increment the build number for each new upload. A build string uniquely identifies the uploaded build; do not keep reusing `1`.[2]
- [ ] Recheck current SDK/upload requirements. Apple's current requirements page states Xcode 26 / iOS 26 SDK or later for applicable uploads since April 28, 2026; installed Xcode 27 clears that version floor, not all submission checks.[9]

Do not run an upload automatically from this document. Once account and disk prerequisites are cleared: regenerate from `project.yml`, archive scheme Nitrate in Release for generic iOS, use Xcode Organizer Validate/Distribute → App Store Connect, then verify processing status in the exact app record.[2][10]

## Gate 2 — internal TestFlight first

1. Create or inspect the iOS app record (name, primary language, bundle ID and SKU); use the existing record if present.[3]
2. Upload and wait for processing. Resolve export-compliance questions according to the actual binary; do not set an encryption exemption blindly.[1][2]
3. Enter beta description, what to test, feedback email and review contact/instructions.[1]
4. Use a small internal group for the owner and any legitimate App Store Connect collaborators. Internal testing supports up to 100 eligible account users; do not grant strangers account roles simply to bypass external review.[1]
5. Install the processed TestFlight build and verify its version/build on-device. The installed development build is not this gate.

## Gate 3 — controlled external TestFlight

- Submit the external-testing build for Beta App Review and wait for approval as applicable. The first external build is reviewed; do not promise a fixed review turnaround.[1]
- Start with **10–20 compatible-device testers** as a proposed cohort, not an Apple limit. Invite personally before publishing an unrestricted link.
- Apple supports up to 10,000 external testers; builds are testable for up to 90 days. Treat those as ceilings/expiry, not a recruitment goal.[1]
- Give every tester the protocol below. Collect TestFlight feedback plus a short opt-in check-in; never request confidential footage by default.
- New build: identify changed behavior, retain a reproducible bug log, and verify installation after processing. Pause expansion if a media-safety regression occurs.

### Tester protocol (real device)

Use disposable footage first. Record OS, device, app build and available space with every defect.

- [ ] Deny/regrant camera, microphone and Photos permissions; confirm recovery and clear instructions.
- [ ] Capture short and multi-minute clips, front/rear available lenses, both landscape holds and portrait; inspect saved orientation and audio.
- [ ] Check stabilization modes, start/stop/cancel and audio sync; preserve originals on failed validation/render/delivery.
- [ ] Exercise background/foreground, interruption, screen locking and queue recovery without deleting media.
- [ ] Test render → Photos, optional original delivery, partial save failure and retry; check no unexpected duplicates or lost originals.
- [ ] Dismiss a render error, finish a later successful render and confirm the old banner stays dismissed; a genuinely new failure must still alert.
- [ ] Tele zoom shows its actual minimum and up to 16×, wide stays at 5×; hold/release, slider and pinch agree. Hardware limits can lower the maximum.
- [ ] Try storage warnings, a safely constrained low-storage case, heat and long sessions; note render time and battery impact without claiming benchmarks from one run.
- [ ] Test restore/expiry/refund and trial behavior under the intended beta entitlement policy. TestFlight purchases run in Apple's sandbox; explain the testing behavior to testers rather than implying a real charge.[14]
- [ ] Confirm UI remains usable at supported text sizes and VoiceOver; do not substitute image fixtures for touch/accessibility testing.

### Proposed exit criteria before widening beta

These are project decisions, not measured results: zero known lost/corrupted originals; zero open P0/P1 issues; every blocking-path matrix case passed; at least two successful record→render→Photos sessions per retained tester; top reproducible issues resolved and retested. Track counts and failures, not only positive testimonials.

## Gate 4 — App Store submission

- [ ] Final author-written name/subtitle/description/keywords; verified support, pricing and privacy facts.
- [ ] Screenshots from the actual supported app and allowed device classes; optional preview shows actual product behavior. Apple's app-preview page explains device-specific capture and submission; confirm the live screenshot specification in App Store Connect rather than inventing dimensions (the linked upload help page returned a not-found page during this research).[12]
- [ ] Category, age-rating questionnaire, content rights, territory/availability and export compliance completed truthfully.
- [ ] Privacy responses and public policy/support URLs verified; subscription/lifetime products configured, submitted and tested as needed.[4][5]
- [ ] Review notes explain required hardware/capture capabilities, permission flow, purchase/restore and how to exercise rendering. Never promise reviewers unsupported hardware will work.
- [ ] Choose an approved processed build, submit for App Review and resolve any questions.[11]
- [ ] Prefer **manual release** for the first launch so approval is separated from publication. Verify the live listing, purchase/restore and first production capture after release.[13]

## Deliberate approval boundaries

Agent can prepare metadata fields, deterministic build steps, asset checklists, release notes, draft outreach and bug summaries. Owner supplies legal/account answers, accepts agreements, approves prices/licence and authentic copy/footage. No upload, external tester invitation, outreach send, spend or App Store publication has been authorized by this runbook alone.

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
