# Nitrate launch readiness

Reviewed source: `150ca6f` (`dev`). Review completed October 15, 2026. **Verdict: not ready for external TestFlight or App Store submission yet.** This is a source-level assessment, not a new device certification or a percent-complete estimate.

## Deliverables

- [Independent security/privacy review](audits/security-review.md)
- [Independent correctness review](audits/code-review.md)
- [mood.camera evidence and proposed GTM experiments](mood-camera-research.md)
- [Low-input launch operations](operations.md)
- [Apple/TestFlight release runbook](apple-release-runbook.md)
- [README layout and authentic-asset handoff](readme-layout-and-assets.md)

## What the audits do and do not establish

Two independent reviewers inspected the production source and relevant tests. The coordinator re-read the main OS/audio/StoreKit/queue/first-stock/duration/ISO/frame-export traces. Original reports retain their provisional severity labels; this page supersedes those labels for release triage.

The security review's “Critical” OS finding is a **compatibility/release blocker**, not a demonstrated critical security exploit. Duplicate privacy/reliability findings are not additional security vulnerabilities. No remote exploit or secret exposure was established by these source reviews; that does not establish their absence. No new build, device reproduction, penetration test, Release archive inspection or App Store validation was performed during the audits. Prior 359 RenderCLI / 43 CameraDesign green runs predate these reviews and do not clear the newly identified gaps.

## Gate A — fix or resolve before external beta

| ID | Priority / type | Source evidence at reviewed SHA | Required disposition and proof |
|---|---|---|---|
| L01 | P1 compatibility | **Fixed (narrow iOS 27).** Deployment target raised to 27, README updated, and the Release app's `MinimumOSVersion` verified as 27.0. A physical capture on a minimum-OS device is still outstanding. |
| L02 | P1 audio integrity | **Fixed in source.** Required-audio evidence is unconditional, the mic is only reported configured once the audio output attaches (input rolled back otherwise), and a mic enabled in Settings after launch is re-attached. A Release on-device silent-take check is still outstanding. |
| L03 | P1 queue durability | **Fixed.** Enqueue is persisted before render/Photos; a failed transition pauses side effects, returns the job to pending and keeps media. `resume()` retries the write and a confirmed Photos save is not repeated. A corrupt queue file is quarantined aside and persistence continues, so it can no longer brick the app. |
| L04 | P1 capture discoverability | **Fixed.** A take without a selected stock is durably queued `awaitingStock` before the sheet opens, keeps its delivery preferences, and stays discoverable/resumable (Choose stock / Save original) after Done, a second take or a relaunch. `enqueue` reuses an existing awaiting entry for the same source instead of duplicating it. |
| L05 | P1 rescue discoverability | **Fixed.** A validation-failed original is durably queued original-only (never rendered, reason retained) and the camera handoff is cleared only after acceptance; a failed Photos save survives restart with retry. A capture journal now also rescues a take whose process died before any queue entry existed. |
| L06 | P1 private residual media | **Fixed.** Automatic frame-PNG dumping is removed; only an injected diagnostics hook runs. |
| L07 | P1 submission/privacy preparation | No tracked app privacy manifest found; defaults, uptime and disk-capacity calls are present. | Map actual covered API uses to approved reasons, add manifest as a bundled resource, inspect privacy report/archive and validate upload. The Apple runbook contains official sources; no reason code is approved by this audit. |
| L08 | P1 commercial contract | **Fixed for the intended beta.** Access comes from a verified StoreKit environment: TestFlight and Debug builds are unrestricted with no checkout, production requires a verified, non-revoked, non-expired purchase or the local 7-day evaluation. Capture admission is gated; recovery and export of captured footage are not. Real sandbox/App Store transaction testing is still outstanding. |

## Gate B — resolve before public paid launch; assess during beta

| ID | Type | Source trace / disposition |
|---|---|---|
| L09 | Manual focus state | **Fixed in source.** Taps no longer autofocus while MF is committed, a committed position is reapplied or dropped on lens change, and `ContentView` reads the session snapshot back to reconcile the MF binding. On-device confirmation is outstanding. |
| L10 | ISO state | **Fixed.** Changes are refused before mutating during any recording transition, and a rejected change reconciles back to the last accepted value. |
| L11 | Async take ownership | **Fixed.** Timer state is snapshotted and cleared before the await, and the duration verdict is fenced by take generation. |
| L12 | Prices / product availability | Purchase UI uses hardcoded fallback dollar prices while product loading can fail. Show unavailable/loading until actual localized StoreKit prices load; exercise non-USD and offline cases. |
| L13 | Media retention / storage | **Partly addressed.** Nothing deletes a source on queue-row removal, and queued paths are re-rooted onto the current container so an app update no longer orphans them. A visible retention/delete policy and backup/file-protection review remain. |
| L14 | Parser hardening | Bundled LUT parser permits unbounded positive size and unchecked size products (`PipelineRenderer.swift:577–615`). Bound/validate dimensions, counts and finite values; current bundled-only reachability makes this low external attack exposure, not a demonstrated remote exploit. |
| L15 | Cancel UX | Renderer supports cancellation but processing queue has no user cancel action. Product decision: add safe cancellation or clearly disclose the beta limitation. A new cancel path must not trigger failed-render automatic export. |

## Investigate / product decisions — not automatic bug fixes

| ID | Topic | Disposition |
|---|---|---|
| L16 | Failure rescue saves original to Photos despite normal original-save setting being Off | Source confirmed (`RenderQueueViewModel.swift:281–305,327–343`), but this is **previously intentional media-rescue behavior**, not an unexplained upload. The setting may govern ordinary successful delivery, not rescue. Choose/document the contract or ask before rescue export while retaining a durable in-app copy. Do not remove the rescue without a replacement recovery path. Photos sync is controlled by the user's library; no app-operated third-party upload was established. |
| L17 | Hard recording faults cancel unfinalized output | Source confirmed (`CameraSampleBufferRecorder.swift:722–755`); whether a particular interrupted file could have been finalized/readable is **not demonstrated**. Investigate bounded salvage with a concrete fault fixture before changing recorder lifecycle. Distinguish already finalized readable originals (retained today) from a failed live writer. Do not advertise “original never destroyed” as an unconditional guarantee. |
| L18 | Repository licence / public copy | `gh repo view` reports no general licence. Choose licensing; confirm upstream notices/content rights. This is not a security vulnerability. README replacements wait for author copy and verified support/privacy claims. |

## Recommended execution batches

1. **Release contract:** decide OS minimum and beta/paid scope; recover build headroom with approval. No more capture-format or feature scope expansion.
2. **Shipping integrity:** L02, L03, L04, L05, L06, L07. Isolated worker ownership; tests-first commits; parent runs integration, Release, real device and retry/relaunch evidence.
3. **State/purchases:** L08–L12; split camera vs StoreKit ownership. Run explicit sandbox transaction scenarios; don't let UI tests substitute for real StoreKit/Photos behavior.
4. **Recovery/privacy controls:** L13, decisions L16/L17, defensive parser L14. Treat cancellation L15 as a deliberate product scope choice, not an assumed emergency.
5. **Internal TestFlight:** processed distribution build, actual Release behavior, permission/error/storage/interruption matrix and paid/free policy checked.
6. **External pilot:** small eligible cohort and real owner-shot demonstrations; widen only after the operations gates pass. App Store publication follows the beta, not the source audit.

## Owner inputs (one decision batch)

- Minimum OS: recommended narrow **iOS 27** first release, unless iOS 26 support is important enough to fund and test a backport. This is a proposal, not a change made.
- Commercial policy: free beta vs testing paid trial now; final launch yearly/lifetime/free choice and approved prices.
- Rescue export: retain automatic Photos rescue with explicit disclosure vs consent-first rescue with durable in-app retry.
- Developer/App Store Connect account state, support contact, privacy-page hosting, licence choice.
- Founder copy and one authentic footage batch; no generated why/mission text.

## Current execution limits

At dispatch the machine had 191 MiB free; a later check showed about 1.7 GiB. Both are insufficient headroom for a dependable new archive workflow. No files were deleted and no new builds were attempted by reviewers. Account membership, App Store app record, products, agreements, distribution signing and actual upload acceptance remain uninspected. The runbook is prepared; **TestFlight is not live** and no outreach/publication happened.
