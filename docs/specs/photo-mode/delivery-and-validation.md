# Photo delivery, recovery and validation

Companion to `spec-photo-mode.md`. The checks below are implementation acceptance requirements. They have not been executed by producing this documentation.

## Durable job contract

Introduce `PhotoJob` and a versioned photo store, separate from the existing movie-shaped `RenderJob` JSON. Names are proposed, not existing APIs. Share delivery/persistence primitives where safe, and provide one aggregate queue presentation and one shared serial GPU scheduler for photo and video work. Preserve FIFO acceptance order across ready jobs, skip blocked jobs, and let already-running work finish before switching types. Photo failure must not stop unrelated jobs.

Each photo record contains:

- Stable shot ID, capture-journal ID, creation time and schema version.
- App-relative DNG/output paths and ownership identity; re-root into the current container on launch. Reject traversal and unowned/symlinked deletion targets.
- Requested lens/zoom/orientation and separately measured source dimensions, exposure duration, aperture, ISO and available WB evidence. Unknown values stay unknown.
- Immutable photo-stock/recipe snapshot, source and LUT hashes, decoder version/settings, RAW adapter revision, working/output color contracts, gauge and grain seed.
- Snapshotted output codec/profile/quality and independent original-RAW delivery preference.
- Durable processing phase, each delivery's outcome, errors, receipt, and cleanup status. A phase transition is not persisted merely because an observable property changed.

The capture journal precedes sensor capture. A DNG not yet acknowledged by the job store is reconciled at launch into a recovery entry. If its complete recipe snapshot and validation are available, resume the intended photo job. Otherwise expose it as original-only recovery; never guess a stock or render under today's catalogue defaults.

## State and ownership table

| State/event | Required durable behavior | User-visible behavior |
|---|---|---|
| Configuring | No new accepted shot; retain previous mode rollback information. | Shutter disabled; Photo selected only after successful commit. |
| Capturing | Journal exists; delegate and generation own sensor callbacks. | Immediate press/haptic acknowledgment; capture busy indication, no fake saved state. |
| DNG received | Atomic source write, readability/metadata check, then persisted job before journal acknowledgment. | Accepted for processing only after persistence succeeds. |
| Pending/rendering | Immutable source/recipe; shared serial scheduler; generated output written atomically. | Separate queue status; next shot allowed only after sensor transaction has settled and capacity is available. |
| Saving result | Persist receipt before external delivery and persist each confirmed save afterward. | Saving remains indeterminate unless actual progress is measurable. |
| Saving original | Only when requested; independent confirmed-save flag. | Result already saved remains accurately reported if RAW delivery fails. |
| Completed | All requested confirmed saves and terminal state durable before cleanup. | Saved confirmation and general Open Photos action. |
| Render failure | Retain source, recipe and diagnostics. | Retry development or save original RAW as recovery, even when normal RAW saving is Off. |
| Permission/save failure | Retain needed output/source and any confirmed-save flags. | Explain failure, offer Retry and Settings where appropriate; no success banner. |
| Relaunch after interrupted work | Reconcile journal/store/files, reset interrupted processing to retryable work and re-root paths. | Recovered or interrupted status; no automatic deletion or invented save evidence. |
| Cleanup failure | Delivery remains completed; persist separate cleanup warning and retry unlink safely. | Never save to Photos again solely because local cleanup failed. |
| Explicit discard | Persist removal intent before deleting only exclusively owned files. | Confirmation for deleting an undelivered original; no automatic bulk discard. |

A cancellation after durable capture is not permission to delete the original. The first slice needs no render-cancel control: accepted jobs survive leaving Photo and changing mode. If later cancellation is added, it must settle to retained/recoverable media unless the user explicitly discards it.

## Photos and privacy

- Request `.addOnly` with the existing add-only usage description. Photo capture requires camera access, not microphone permission. Denied microphone access must not block Photo; this does not alter Video's audio requirements.
- Preflight add-only authorization before the first accepted shot. If denied, do not start a new capture and explain how to enable saving. Revocation or save failure after capture retains media for recovery.
- Save the finished JPEG first. If `Save original RAW` was enabled at capture, save the DNG as a separate asset. Do not create a RAW+JPEG paired asset whose Photos presentation may default to the ungraded source.
- Use file-backed `PHAssetCreationRequest` resources. Keep `shouldMoveFile = false` until confirmed saves and durable cleanup make removal safe. Do not let PhotoKit take the only recovery copy before local state records the result.
- Persist each successful Photos completion before attempting the next delivery. Retry only unconfirmed saves. Exactly-once delivery is not guaranteed across a crash after Photos commits but before local confirmation persists; surface an uncertain outcome and require an explicit retry warning rather than claiming deduplication without read access.
- Completed receipts may contain a small locally generated thumbnail and technical/render metadata. Proposed thumbnail cap: 320 pixels on the long edge. Do not keep completed full-resolution media for playback or inspect Photos to recover thumbnails.
- Preserve source capture date and available photographic EXIF accurately. Do not invent missing lens/exposure fields or copy arbitrary source metadata wholesale. Do not add location access or GPS metadata. Record film settings separately from measured capture values.
- Use the established short `nitrate: <stock> | <gauge>` caption where the supported Photos API permits it. Preserve JPEG orientation and profile through delivery. Do not add movie-specific QuickTime fields to a still file or claim DNG sensor bytes were altered to embed the film recipe.
- Keep the general Open Photos action. No exact-asset navigation, library fetches, albums, post-capture viewer or automatic review image.

## Resource limits and backgrounding

Only one sensor capture transaction may be active. After durable acceptance, permit subsequent captures without waiting for their renders. Before each shot, estimate free space for the worst-case DNG, render intermediate/output and existing queue commitments with a safety reserve. Refuse a new capture when that reservation cannot be made; do not delete pending shots to make space.

Allow one full-resolution RAW decode/render at a time across photo and video. Reuse contexts/pipelines, release GPU/decoder resources after each job, and use downsampled receipt thumbnails. Preview buffers are bounded and must not be retained across full-resolution render work. Measure peak memory and supported texture dimensions on hardware before enabling the resolution budget; tiling/downsampling requires a reviewed output-contract change if full-frame processing cannot meet it.

Suspend starting new GPU work when background execution is unavailable. Persist accepted jobs; resume on foreground/relaunch. Do not promise indefinite background rendering. Repeated captures, switching modes and memory warnings must leave durable jobs recoverable and the camera responsive.

## Proposed implementation slices

1. **P0/P1 feasibility/color gate (authorized to start):** Real Bayer DNG capture, dimension evidence, exposure-control semantics and working-space decode; restore Video. Validate adapter/color fixtures. Broad UI/queue work waits for the capture/color gates to pass. Publication and release require separate approval.
2. **Shared processing seam:** Production still renderer, immutable recipe/seed, file encoder and compatibility-specific photo catalogue. Preserve video stage order and validation.
3. **Durability/delivery:** Photo journal/store, shared scheduler, receipts, add-only saves, partial-delivery recovery and cleanup. Exercise failure injection with actual disposable files.
4. **Shooting UI:** Capability-gated P, still shutter, photo controls and independent selections; integrate the latest approved carousel/Develop layout. Add files to `project.yml` through XcodeGen.
5. **Release gate:** Full automated verification, signed development build and physical-phone acceptance. Keep P hidden in production until all gates pass; implementation approval and release approval are separate decisions.

Proposed files: `CameraPhotoCapture.swift`, `PhotoCapturePolicy.swift`, `StillRenderer.swift`, `RAWInputColorContract.swift`, `PhotoJob.swift`, `PhotoJobStore.swift` and a photo delivery adapter. These are seams, not mandatory class proliferation. Assign capture, processing and persistence ownership separately; the coordinator owns session/view wiring and shared scheduler integration.

## Automated acceptance matrix

| ID | Coverage | Required proof |
|---|---|---|
| A01 | CAP-1/8: visibility/transition | Hidden P before release; eligible/unsupported after release; taps and swipes; selected centering; VoiceOver; configuration failure/rollback; recording/finalization guards; late callbacks cannot select a stale mode. |
| A02 | CAP-2: capability | Bayer vs ProRAW format distinction; no RAW; valid dimension candidates and returned DNG bounds; unsupported lens; format changes invalidate stale capability; exercise Bayer 12-MP-class including 4032×3024 where supported. |
| A03 | CAP-2/7: capture lifecycle | Fresh request ID, one in flight, duplicate/mismatched callback, source-write failure, terminal error, timeout/late DNG, background interruption and journal acknowledgment boundary; four independent ISO/shutter states, EV only on floating values, both-locked meter-only/no mutation, finite/range rejection, mixed-mode metering without periodic auto reopening, `.speed` manual-pin prioritization, requested-vs-DNG-EXIF comparison, activeMaxExposureDuration timing/reset, long-exposure busy/timeout/cadence/restore. |
| A04 | CAP-3/4: snapshots | Stock/gauge/preference edits after capture cannot change jobs; missing old cube/decoder fails visibly; deterministic persisted seed; separate creative ISO and measured capture ISO. |
| A05 | CAP-4: color | Real DNG decode fixture plus neutral/exposure ramps; explicit primaries/transfer; finite output; negative/highlight policy; no direct linear/SDR-to-Log2-LUT path; both photo recipes; sRGB conversion rather than retagging. |
| A06 | CAP-4: encoded image | Open actual JPEG, check useful image content/profile/dimensions and orientation exactly once; verify spatial highlight effects and gauge-aware grain separately from aesthetic acceptance. |
| A07 | CAP-5/6: delivery | Add-only authorization; result-only; result+RAW; permission revoked after capture; first/second save failure; persisted partial result; ambiguous external completion; no duplicate confirmed saves on retry. |
| A08 | CAP-6: persistence | Real file/job round trips; orphan DNG; missing/invalid DNG; corrupt store quarantine; immutable snapshots; container relocation; schema migration; legacy video JSON unchanged. |
| A09 | CAP-6: cleanup | Never unlink undelivered/shared sources; completed cleanup write/unlink failure; missing-file-safe retry; receipt generated before deletion; unowned/path-traversal rejection. |
| A10 | CAP-7/8: scheduling | One shared active GPU job, ready-job FIFO, blocked-photo skip, repeated shooting backpressure, foreground recovery, Video/Develop remain usable after photo failure. |
| A11 | CAP-1/8: native UI renders | Narrow/default widths and both landscape holds; neutral preview; still aspect and focus coordinates; fixed control clearance; disabled controls; no REC timer or stock-look review in Photo; existing ISO UI/range unchanged, Photo-only shutter ruler proposal and independent Float/Lock, full RAW-format duration range, meter-only both-lock semantics. |
| A12 | CAP-8: regressions | Existing capture/Log2 input tests, movie metadata, audio sync, video WB lock, daylight exception lifetime, import output-only saves, independent selections and original-save preferences. |

Run focused RED/GREEN tests during implementation. At integration run `python3 scripts/verify.py verify`, then `python3 scripts/verify.py device` outside the sandbox. Confirm Release-optimized compilation too. Executed counts and result bundles must be recorded; source-string assertions alone do not prove pixels, actual framework saves or interaction behavior.

## Physical-device acceptance

Use the local development bundle without replacing TestFlight. The owner performs visual judgments; automation collects files and technical evidence.

1. **Capability/restoration:** Record phone/OS, physical lens, chosen format/RAW type and actual DNG dimensions. Test each available physical camera, including unsupported ones. Enter/leave P repeatedly, then record and deliver a valid Video clip and Develop an existing supported Log 2 clip.
2. **Shooting/framing:** Shoot a labeled asymmetric target in portrait and both landscape holds with focus taps and supported zoom/lens changes. Compare visible framing with the delivered image; no extra rotation, mirroring, unexplained crop or distorted aspect.
3. **Color/looks:** For each proposed photo stock shoot a neutral/color chart, skin, daylight, tungsten, mixed light, saturated color, hard highlights and low light. Keep DNG, intermediate checkpoints and JPEG for evaluation. Check neutral handling, highlight transitions, localized halation/glow and grain. Owner approval is separate from numerical invariants.
4. **Delivery/privacy:** Check Photos receives JPEG alone by default and two separate assets with RAW enabled. Inspect actual appearance, date/profile/orientation and any caption. Confirm no photo-library read prompt, location prompt or local full-resolution completed-media library.
5. **Failure/recovery:** Deny/revoke save access, interrupt after DNG write and between requested saves, relaunch, retry and inspect confirmed outcomes. Retain an unsaved original and exercise original-only recovery. Warn explicitly for uncertain external saves. Never deliberately exhaust the owner's disk; use controlled fault injection for disk failures.
6. **Responsiveness/resources:** Shoot a proposed 20-shot sequence while processing and switching eligible modes. Record peak memory, render duration, disk use and thermal state on the test device. Require no crash, lost source, unbounded growth or false saved state. This count is a test workload, not a burst/performance promise; revise resource policy if it fails.

Attach evidence to the implementation handoff: source revision, device/OS, actual formats, DNG/JPEG metadata, relevant intermediate frames, test result bundles, failures and owner visual verdict. Do not mark the feature ready from a simulator or this spec's static checks.

## Spec review validation (documentation only)

Before committing this draft: resolve all companion links; verify every CAP has intent/success and acceptance coverage; check proposed choices are labeled; cross-check current-code references; ensure no claims that tests or hardware experiments already passed; run `git diff --check`. Keep all runtime files and the user-owned `docs/prioritization.md` untouched.
