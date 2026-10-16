> Independent source-review findings; severity labels below are the reviewer's initial assessment, **not the release verdict**. See [parent triage](../readiness.md) for disposition. No new runtime reproduction or security certification.

# Nitrate prelaunch correctness review — `dev` `150ca6f`

Read-only source review of the Swift/Metal app, test contracts, `project.yml`, `AGENTS.md`, and README. Security is a separate review. **No build, tests, device run, or source changes**: the supplied disk budget is ~191 MiB and `docs/prioritization.md` is user-owned/dirty. P0: none established. Severity is based on reachable behavior, not an observed device reproduction. Fixes and proposed checks below are not executed.

## Findings

### P1 — Capture is unavailable on the OS claimed as supported
- **Evidence:** `project.yml:5` sets iOS 17 deployment, `README.md:66-73` promises camera capture on iOS 26, but `App/Modules/CameraCapture/CameraSession.swift:779-785` rejects writer configuration on every OS below iOS 27. The writer-configuration failure propagates through camera setup (`CameraSession.swift:536-545`).
- **Trace/impact:** Install on iOS 26 with an otherwise eligible Apple Log 2 device → camera setup reports unsupported → no take can be recorded. This is a code/documented-compatibility contradiction; actual hardware availability still needs device confirmation.
- **Minimal fix/validation:** Implement an iOS 26-compatible capture writer without changing the Log contract, **or** change the supported minimum and README to iOS 27. Test configuration and a complete clip on the lowest advertised OS, plus explicit unsupported behavior below it.

### P1 — The seven-day trial never restricts the camera/render path
- **Evidence:** `App/App.swift:26-40` injects a `PurchaseViewModel`, but `App/ContentView.swift:141-150,216-223` enqueues renders without entitlement checks; `App/Modules/CameraCapture/CameraViewModel.swift:306-329` starts a take without one. `StoreManager.swift:19-30,101-105` computes trial state only for purchase presentation. `README.md:207-210` describes a seven-day trial followed by purchase.
- **Trace/impact:** Seven days elapse without purchase → status can display expired in Settings → recording and rendering remain available. Trial/subscription business contract is not enforced.
- **Minimal fix/validation:** Define one observable entitlement policy (trial-active or current verified purchase), initialize it before allowing record/render, and make expired controls lead to purchase/restore; do not block access to already-captured originals. Test expired, active, and purchased states through actual capture and enqueue entry points.

### P1 — A configured microphone may produce a clean, silent Release take
- **Evidence:** `CameraSession.swift:1822-1854` configures audio evidence for an attached microphone. `CameraSampleBufferRecorder.swift:675-683` rejects zero appended audio only under `#if DEBUG`; the validator's A/V checks at `:882-896` apply only when audio was appended.
- **Trace/impact:** Microphone was configured but no PCM arrives → video finalizes → Release omits the sole zero-audio failure guard → success hands a silent take to rendering. The fake-writer tests at `Tests/CameraSampleBufferRecorderTests.swift:873-906` exercise Debug-only behavior, not this Release contract.
- **Minimal fix/validation:** Put the zero-audio guard in shipping code (retaining the readable original as a reported failure); run a Release-path test and on-device no-packet/configured-mic scenario alongside intentionally video-only recording.

### P1 — Undurable queue transitions can lose jobs or repeat Photos delivery
- **Evidence:** `RenderQueueViewModel.swift:109-113,147-159` appends jobs and swallows persistence errors; `:180-216` starts processing and calls Photos even when the enqueue, processing transition, output URL, or first successful Photos outcome was not written. The deliberate persistence-failure test (`Tests/RenderQueueReliabilityTests.swift:446-465`) expects a completed in-memory job; it verifies files remain, not recovery.
- **Trace/impact:** Enqueue write fails → job renders/saves, then relaunch has no durable record. Alternatively, rendered Photos save succeeds but outcome write fails → a persisted pending/processing record can retry and save the same movie again. No exact-once guarantee is possible across a crash *inside* Photos without external reconciliation, but known local write failures need not compound it.
- **Minimal fix/validation:** Require durable enqueue before work; on a failed transition/outcome write, pause further side effects and retain local media with retryable error. Inject each save failure, reload the persister, and verify no unrecorded delivery or duplicate second save.

### P1 — Dismissing the first stock sheet can strand a completed take
- **Evidence:** On finish, `ContentView.swift:141-150` stores only one `currentSourceURL`; with no stock selected it opens the sheet but does not queue the take. `ContentView.swift:517-525,564-585` passes that ephemeral URL into the sheet; `:593-595` offers Done without enqueuing, and `:607-614` saves stock selection on dismissal. The render button (`:661-674`) is the only queue path for that take.
- **Trace/impact:** First take completes with no selected stock → tap Done instead of Render → sheet closes, first take has no queue job/Photos delivery. A later take overwrites `currentSourceURL` and auto-renders with the now-selected stock; relaunch also loses the first pending URL. Original remains on disk but is not surfaced for recovery.
- **Minimal fix/validation:** Persist a pending-capture delivery/stock-selection record or force a deliberate save/render/defer choice before dismissing, then make deferred clips discoverable. Record first take, dismiss sheet, record second, relaunch, and verify both remain actionable.

### P2 — A stalled video drain cancels and removes the accumulated take
- **Evidence:** `CameraSampleBufferRecorder.swift:568-599` freezes an audio endpoint ahead of video and schedules a five-second drain; if no quality error was latched, timeout calls `fail`. `:722-755` cancels an active writer and deletes its destination on ordinary failure. `Tests/CameraSampleBufferRecorderTests.swift:568-585` protects the current delete-on-timeout behavior, not salvage of earlier footage.
- **Trace/impact:** Stabilized video stalls after some frames while audio has advanced → stop waits five seconds → timeout discards already appended content rather than attempting a shorter finalized original. The unfinalized file is not inherently playable; the loss is from cancelling without first attempting a bounded salvage finalization.
- **Minimal fix/validation:** On stop-drain timeout, attempt bounded `finishWriting` of the accrued tracks and validate/retain a readable partial original with a warning; delete only if finalization fails. Inject delayed video with a fake writer and exercise a device stall.

### P2 — Validation-failed original delivery has no durable retry
- **Evidence:** `ContentView.swift:152-157` immediately clears `retainedOriginal`; `RenderQueueViewModel.swift:321-343` performs a separate, untracked save task, then records failure only as an in-memory banner. `Tests/RenderQueueReliabilityTests.swift:25-75` uses injected in-process saving and expects no queue job for this path.
- **Trace/impact:** A readable original fails validation, then Photos permission/save fails or the app terminates → file stays in Application Support but no persisted delivery entry or retry UI survives relaunch.
- **Minimal fix/validation:** Persist an original-only delivery request before clearing the camera handoff; expose retry independent of render eligibility. Deny Photos, relaunch, grant permission, retry, and inspect the unchanged original.

### P2 — Purchase status is grant-only and restore is not a restore request
- **Evidence:** `StoreManager.swift:19-30,96-104` only sets `isPurchased = true`, never recomputes it false from current eligible entitlements; `:33-39` only grants on updates. `PurchaseViewModel.swift:21-26,73-75` refreshes displayed state on view appearance/purchase, not on observed transaction changes. `PurchaseViewModel.swift:54-58` calls `checkStatus` but no `AppStore.sync()` and no error reporting.
- **Trace/impact:** Subscription expires/revokes while the model lives → its purchase state can stay true; a transaction update need not refresh the settings display. On a new device with an entitlement not yet locally present, tapping Restore merely re-enumerates local state and gives no explicit sync/result. This becomes more consequential once gating is wired.
- **Minimal fix/validation:** Recompute verified, current, non-revoked entitlement state on each status/update, propagate it to the view model, and invoke `AppStore.sync()` only for user-initiated restore with visible errors. Exercise renewal, expiration, revocation, and fresh-device restore with StoreKit/App Store.

### P2 — Manual-focus UI can disagree with hardware after tap or lens switch
- **Evidence:** `CameraView.swift:27-29` routes preview taps to `CameraSession.setFocusAndExposurePoint`; `CameraSession.swift:1088-1090` selects autofocus unconditionally. `ContentView.swift:58-59` retains MF selection/position across lens changes; `CameraViewModel.swift:414-447` switches device without reapplying focus; `ManualControlsPanel.swift:45-50` applies focus only on binding change.
- **Trace/impact:** Enable MF then tap preview → hardware autofocuses while MF remains lit. Or switch physical lenses in MF → new device has no committed selected MF position, but panel still says MF.
- **Minimal fix/validation:** Preserve locked manual focus on taps or explicitly reset UI to AF; on committed switch reapply supported MF to the new device or reset it. Read device focus mode/position after each interaction. `Tests/ManualControlsOverlayTests.swift:77-104` checks source wiring, not device state.

### P2 — ISO selection can drift from capture exposure during recording
- **Evidence:** ISO ruler remains editable (`CameraControlBar.swift:121-135`); `CameraViewModel.swift:474-481` updates its displayed `manualISO` optimistically, then ignores the session rejection while recording; `CameraSession.swift:1393-1396` refuses exposure changes during a take.
- **Trace/impact:** Change ISO during an active take → UI now shows the new value while captured frames keep the previous setting; subsequent lens/resume restoration may apply the previously rejected value.
- **Minimal fix/validation:** Disable ISO changes during start/record/stop or roll back the displayed selection on rejection. Move ISO during a device take, finish, switch lens, compare selected and active camera ISO.

### P2 — An older duration check can mutate the next take's state
- **Evidence:** `CameraViewModel.swift:718-733` clears `isRecording`, then awaits `checkRecordedDuration`; `:766-784` awaits AVAsset duration before setting warning text. Another start can set the next timer origin (`:306-329`), but the first completion subsequently clears it at `:749-750` and can replace current warning. Timer fallback at `:802-811` then advances in fixed increments instead of using its origin.
- **Trace/impact:** Stop take A → while its duration load is suspended start B → A's load completes → B loses timer origin and potentially gets A's shortfall warning.
- **Minimal fix/validation:** Snapshot/clear A's timer state before await and fence the async result by a take generation. Suspend the asset-duration loader in a test, start B, resume A, and assert B's origin and warning survive.

### P2 — Processing jobs have no user cancellation path
- **Evidence:** `QueueSheetView.swift:45-55` offers Remove for pending only; `RenderQueueViewModel.swift:129-136` refuses processing removal and no action cancels `worker` (`:19,180-189`). The renderer itself accepts task cancellation (`PipelineRenderer.swift:673-831`), but UI never invokes it.
- **Trace/impact:** A long render or Photos save cannot be stopped by its owner; rendering continues and delivers even after the user wants to discard it. This is an actionable missing control, not an assertion that an existing cancel button is broken.
- **Minimal fix/validation:** Add processing Cancel, terminal cancellation status, task cancellation, and partial-output cleanup while preserving original; guard render-failure fallback from treating explicit cancellation as a failed render. Cancel during GPU work and Photos delivery; relaunch and check state and library.

## Coverage inventory and unproven gaps

- **Static/runtime units present:** `RenderCLITests` include recorder fake-writer lifecycle/A-V continuity and retention, queue persistence/injected render and Photos saves, Log input/color contracts, LUT sampling, GPU grain/spatial stage, output metadata/audio/geometry, preview GPU policies, zoom/stabilization/geometry policies. `CameraDesignTests` cover SwiftUI render/source-contract geometry and design. These tests do not themselves prove the shipping color look, real mic/stabilization, Photos behavior, or StoreKit state transitions.
- **Pipeline/shaders:** `PipelineRenderer.swift:97-125` checks declared source tags before LUT; `:145-158,204-253` establishes half-float decode and tagged Rec.709 output; `:653-831` copies audio separately and uses cancellable reader/writer work; `SpatialEffectsStage.swift:75-166` and `Resources/Shaders/{pipeline,spatial,grain}.metal` implement LUT → spatial diffusion → grain. GPU spatial/grain tests exist (`Tests/SpatialEffectsTests.swift`, `GrainShadowTests.swift`, `LUTSamplingTests.swift`), but no finding here meets the reachable-defect bar. Actual decoded Apple Log 2 values, rendered color/grain appearance, device memory/thermal load on five-minute 4K clips, AAC payload/endpoints, and true HDR/SDR visual output need captured-device artifacts. The code itself calls the decoded RGBA/color conversion unverified (`PipelineRenderer.swift:143-144`).
- **Camera/control:** Unit contracts cannot replace physical camera format negotiation, lens zoom limits and press/release, focus/ISO readback, orientation in both landscape holds, frame-mode focus geometry, or stabilization A/V start/end and long-run drift. Source-string SwiftUI wiring tests do not exercise touch targets or gestures.
- **Release:** `scripts/verify.py:116-128` runs the RenderCLI scheme and Debug iOS build, not a Release archive; the separate `CameraDesign` scheme is at `project.yml:52-58`. The parent reports prior green runs of 359 RenderCLI / 43 CameraDesign tests; **this review did not rerun or verify those counts**. Release-only conditional behavior above merits explicit validation. StoreKit purchase, expiration/revocation, restore, and trial gating lack a production-path test seam in the test target (`project.yml:148-203` does not include Purchase sources).
- **Hypotheses, not findings:** Metal in-place glow composite aliases the input/output texture (`SpatialEffectsStage.swift:153-162`), but the shader reads and writes the same pixel per invocation; no cross-pixel dependence or observed failure was established. No claim of a GPU race is made. Exact-once Photos delivery across process death between external save and local receipt remains unsolved by persistence alone; reconcile against Photos if exact-once is a requirement.

## Disposition

No source paths touched. Review artifact only: `/Users/johnazzinaro/.hermes/cache/scratch/nitrate-prelaunch-code-review.md`. Prioritize launch contract (OS support, entitlement gating), Release audio evidence, media/queue durability, then camera-control state and device verification. Security findings belong to the separate security review.
