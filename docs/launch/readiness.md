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
| L01 | P1 compatibility | `project.yml:5` targets iOS 17; README claims capture on 26; `CameraSession.swift:784–786` rejects writer setup before 27. | Choose minimum iOS 27 **or** a real tested backport. Match install target/listing/docs, and capture a complete clip on the minimum advertised OS. Do not weaken Log validation just to widen installs. |
| L02 | P1 audio integrity | `CameraSampleBufferRecorder.swift:675–683`: configured-mic/zero-audio rejection is under DEBUG; audio validation at 882–896 only runs after appended audio. | Move required-audio evidence into Release behavior, retaining readable failed takes. Test configured mic/no packets and explicitly permitted video-only cases in Release. Verify mic output attachment (`CameraSession.swift:369–380`). |
| L03 | P1 queue durability | `RenderQueueViewModel.swift:147–159,180–216` reports persistence errors but still renders/delivers. | Persist enqueue before work; pause side effects on failed durable transitions. Fault-inject writes and relaunch at delivery boundaries. Do not promise exact-once Photos saving across a crash between Apple save and local acknowledgement. |
| L04 | P1 capture discoverability | `ContentView.swift:141–150,593–613`: a first take without selected stock can leave the stock sheet via Done; only an ephemeral source URL references the take. | Persist a pending capture or require explicit render/defer/save resolution; prove two takes and relaunch leave both discoverable. |
| L05 | P1 rescue discoverability | `ContentView.swift:152–157`, `RenderQueueViewModel.swift:321–343`: retained-original handoff is cleared while an untracked async Photos save runs. | Persist original-only rescue/retry before clearing the handoff. Deny Photos, relaunch, grant access and recover the unchanged take. |
| L06 | P1 private residual media | `RenderQueueViewModel.swift:257–264,376–396`: successful production renders create three frame PNGs in Documents without a DEBUG guard. | Remove automatic Release frame dumps or make them explicit opt-in diagnostics with a retention rule. Inspect Release app storage after render/removal. |
| L07 | P1 submission/privacy preparation | No tracked app privacy manifest found; defaults, uptime and disk-capacity calls are present. | Map actual covered API uses to approved reasons, add manifest as a bundled resource, inspect privacy report/archive and validate upload. The Apple runbook contains official sources; no reason code is approved by this audit. |
| L08 | P1 commercial contract, if beta exercises purchases | Capture/render do not check purchase/trial; `StoreManager.swift:19–29,96–114` grants but does not recompute a revoked/expired state; restore only re-enumerates entitlements. | Decide beta/free/paid policy, then implement shared verified entitlement state, proper restore and expiry/revocation tests. Never gate recovery/export of already captured footage behind payment. Do not ship a paid trial contract that is only presentation. |

## Gate B — resolve before public paid launch; assess during beta

| ID | Type | Source trace / disposition |
|---|---|---|
| L09 | Manual focus state | Preview taps select autofocus (`CameraSession.swift:1082–1090`) while MF bindings persist; lens changes do not reconcile those bindings. Apply or reset focus intentionally and prove selected vs active mode on device. |
| L10 | ISO state | `CameraViewModel.swift:474–490` assigns selected ISO before a session call that rejects recording-time changes (`CameraSession.swift:1390–1407`); its callback can ignore that rejection. Disable changes during transitions or reconcile errors/readback. |
| L11 | Async take ownership | `CameraViewModel.swift:718–750,766–784` awaits duration while a new take can start, then clears shared timer state. Snapshot/clear old state before await and fence result by take generation; test a suspended old duration load while a new recording begins. |
| L12 | Prices / product availability | Purchase UI uses hardcoded fallback dollar prices while product loading can fail. Show unavailable/loading until actual localized StoreKit prices load; exercise non-USD and offline cases. |
| L13 | Media retention / storage | Queue removal removes rows, not original/output media; no explicit backup/file-protection policy found. Define visible keep/delete/export behavior, never remove the only original, and inspect locked-device access/backup behavior rather than claiming data is unencrypted. |
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
