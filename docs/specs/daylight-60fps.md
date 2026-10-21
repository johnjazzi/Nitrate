# Daylight 60 fps capture (break-glass, session-only)

Status: **implemented; automated checks passed; physical-camera validation open**.
Baseline `76a4de3`, branch `feat/daylight-60fps`.
The sections below record the reviewed design; §17 records the original delivery.
**Current UI revision:** §18 replaces the Manual-controls entry with EV-triggered rescue.

## 1. Purpose and position

Daylight 60 fps is an **emergency exposure tool**, not a creative frame-rate
mode. When the user cannot drive exposure down in daylight — sun at f/1.7 wide,
ISO already at the floor — changing the fixed shutter from `1/48 → 1/120`
(same 180° angle) reduces exposure by a factor of 2.5, roughly **1.32 stops**
at equal ISO and aperture. It is a fixed-shutter change, not an auto-exposure trick.

Three commitments bound it:

- **Session-only.** The mode never persists. Foreground camera session start is
  always 24 fps. There is no `UserDefaults` key, no stored preference, no
  "remember last choice".
- **Break glass, not a default.** It is off-screen until deliberately armed,
  warns in plain words, and reverts the moment the foreground session ends.
- **Not a cure.** It buys a modest stop, worsens motion cadence, and **does not
  replace ND**. ND remains the correct answer for a locked-off bright scene.

The default remains 24 fps, 180° (`1/48`), Apple Log 2, 4K, 10-bit HEVC, AAC
audio — unchanged in every dimension except the two this spec names.

### Source of truth for existing behaviour

Read before changing anything here: `docs/recording-av-timing.md` (recorder
boundaries, start latency, metadata angle), `docs/edge-grain-benchmark.md`
(grain kernel), `docs/prioritization.md` (top priorities — **do not edit it**),
`AGENTS.md` (project notes: do not touch WB locking, the direct RGB/red-fastest
LUT upload, or custom movie metadata semantics; XcodeGen; verification gates).

## 2. Definitions

- **Foreground camera session** — one `onSceneActive → onSceneInactive`
  lifetime of `CameraViewModel`, i.e. app foregrounded onto the camera screen
  through to backgrounding or `onDisappear`. Cold launch counts as the start of
  a fresh session.
- **Mode** — the capture frame-rate selection: `.standard24` (default) or
  `.daylight60`. It is a `CameraViewModel` value, never persisted.
- **Active take** — recorder state where `recordingStartPending`, `recordingActive`
  or `recordingFinishing` is true (`CameraSession` lines ~109/162 and the
  `isRecordingOrPending` accessor). Draining after a stop still counts as active.
- **Eligible format** — an `AVCaptureDevice.Format` that is 3840×2160, Apple Log 2,
  10-bit bi-planar 420/422 (existing `CameraCaptureFormatPolicy.Candidate` shape,
  `App/Modules/CameraCapture/CameraPolicies.swift`), **and** whose
  `videoSupportedFrameRateRanges` include 60.

## 3. Frame-rate surface to change (hardcoded 24 fps)

Every place that assumes 24 fps, and how it changes. Line numbers are baseline
`76a4de3` anchors, not patch coordinates.

| # | File / symbol | Baseline | Change |
|---|---|---|---|
| F1 | `CameraSession.applyCaptureFormat` (`CameraSession.swift` ~688-701) | `activeVideoMin/MaxFrameDuration = CMTime(1, 24)` | parameterise by mode: `CMTime(value: 1, timescale: fps)` with `fps ∈ {24, 60}` |
| F2 | `CameraCaptureFormatPolicy.appleLog2CandidateIndexes` (`CameraPolicies.swift` ~77-86) | requires `supports24FPS` | add `supports60FPS` to `Candidate`; add a 60-eligible selector; **keep** the 24 selector as-is |
| F3 | `ExposureManager` (`ExposureStateMachine.swift` 19-22) | `minShutter 1/24`, `maxShutter 1/100`, `defaultShutter 1/48` | make shutter set frame-rate aware (§5) |
| F4 | `CameraSession.filmShutterDuration` (`CameraSession.swift` 1460-1461) | `static let` `CMTime(1, 48)` | frame-rate-aware accessor: `1/48` (24) or `1/120` (60) |
| F5 | `captureMetadataItems` angle (`CameraSession.swift` 2068) | `angle = shutterSeconds * 24.0 * 360` | use active fps, not `24.0` |
| F6 | `CameraSession.captureFormatLabel` (`~2085-2090`) | derives fps from `activeVideoMinFrameDuration` | already correct once F1 sets it; keep |
| F7 | `CameraError.appleLog2NotSupported` message (`~2461`) | "4K, 24 fps camera format" | keep 24 wording for the base error; add a distinct 60 error (§7) |
| F8 | `RenderMovieMetadata.make` (`RenderDiagnostics.swift` 321) | hardcodes `"shutter-speed": "1/48", "shutter-angle": "180"` | emit from the job's persisted capture policy (§8) |
| F9 | `PipelineRenderer.processFrames` grain `frameIndex` (`PipelineRenderer.swift` 742/807/818) | increments per frame | pass a **grain index** derived from the job policy (§6); PTS append cadence unchanged |
| F10 | Recorder duration fallback (`CameraSampleBufferRecorder.swift` 518) | `fallbackDuration: CMTime(1, 24)` | parameterise from the take snapshot (1/24 or 1/60); never guess 24 for a 60fps take |

Not changed: `StartupSplashTiming.framesPerSecond = 24` (splash animation,
unrelated); `CameraStorageEstimatePolicy` (bitrate, not frame rate); WB lock, LUT
upload, `RenderInputColorContract`, delivery bitrate/quality.

## 4. Format selection, application, and reassertion

### 4.1 Eligibility (no silent downgrade)

Add to `CameraCaptureFormatPolicy.Candidate`:

```swift
let supports60FPS: Bool   // videoSupportedFrameRateRanges contains 60
```

`CameraSession.appleLog2CaptureFormats` (~703-731) computes it alongside
`supports24FPS` from `format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 60 && $0.maxFrameRate >= 60 }`.

New selector, parallel to the existing one:

```swift
static func appleLog2SixtyCandidateIndexes(in candidates: [Candidate]) -> [Int]
// width 3840 && height 2160 && supportsAppleLog2 && supports60FPS
// && (isTenBitBiPlanar420 || isTenBitBiPlanar422), 420 before 422
```

`.standard24` selection is unchanged. `.daylight60` selection uses the 60
selector. If `.daylight60` has **no** eligible format on the active device, the
take must not fall back to 24 silently: surface `CameraError.daylight60Unsupported`
(§7). Cold launch and ordinary capture never require a 60-eligible format.

### 4.2 Apply under configuration lock

`applyCaptureFormat` opens `session.beginConfiguration()`, locks the device, sets
`activeFormat`, `activeColorSpace = .appleLog2`, then sets
`activeVideoMinFrameDuration`/`activeVideoMaxFrameDuration` from the mode. Do
**not** set a frame duration the active format's ranges exclude — check first
(Apple: `activeVideoMinFrameDuration` "must be in
activeFormat.videoSupportedFrameRateRanges" and "requires configuration lock").

### 4.3 Reassertion after custom-exposure writes (required)

`setExposureModeCustom(duration:iso:completionHandler:)` can change the active
frame durations; a custom-exposure write and its completion run on AVFoundation's
own queue, not under our lock. Therefore the fix is **not** only at format
selection — re-assert the fixed durations after every custom-exposure path.

Add one guarded helper on `CameraSession`:

```swift
/// Re-assert the fixed min/max frame duration, but only when the active format
/// advertises it. Caller must already hold the device configuration lock.
private func reassertFrameDuration(on device: AVCaptureDevice) throws
```

It reads the mode's target `CMTime`, verifies it lies inside
`device.activeFormat.videoSupportedFrameRateRanges`, and writes both
`activeVideoMinFrameDuration` and `activeVideoMaxFrameDuration`. It throws a
distinct error if the target is unsupported rather than clamping silently.

Call sites (all must hold `lockForConfiguration`, all inside existing
`beginConfiguration`/`lockForConfiguration` regions):

- `applyCaptureFormat` — at F1 (primary set).
- `setExposureLocked` (`~1311-1325`) and `applyCustomExposureHoldingAperture`
  (`~1331-1351`) — after `setExposureModeCustom`, inside the same lock.
- `pinShutterToFilm` (`~1606`) and `refreshShutterPriority` — after the exposure pin.
- `startRecording` (`~1755-1840`) — after the recording exposure pin lands, before
  `beginSampleBufferRecording`, so the take starts on the asserted rate.
- Lens-switch rollback (`~966-982`) already restores prior min/max; make it restore
  the **mode's** target instead of the previous device's stale values.

If reassertion fails on the recording-start path, fail the take with the §7 error
and do not record at the wrong rate.

## 5. Fixed shutter, both manual ISO and auto ISO

At 180° the shutter tracks the frame rate: `1/48` at 24 fps, `1/120` at 60 fps.
The mode picks the fixed shutter; ISO is free (auto-metered or manually set) and
the shutter stays pinned either way — the same contract as today, only the value
moves.

`ExposureManager` (`ExposureStateMachine.swift`) becomes frame-rate aware:

```swift
enum CameraFrameRate: Int { case standard24 = 24, daylight60 = 60
    var fps: Int { rawValue }
    var shutterDenominator: Int { rawValue * 2 }   // 180°: 48 or 120
}
```

- `defaultShutter` → `1 / 48` or `1 / 120` by mode.
- Widen the manual clamp so `1/120` is reachable: `maxShutter` (fastest) must be
  `≤ 1/120`, i.e. add `minShutterFast = 1/120` for `.daylight60` (the current
  `1/100` ceiling would reject the fixed `1/120`). `minShutter` (slowest, `1/24`)
  is unchanged. Keep every value inside the device format's
  `minExposureDuration`/`maxExposureDuration` (already clamped at write sites).
- `ExposureMode.auto` and `.shutterPriority` both resolve to the mode's fixed
  shutter; `.manual(_, iso)` and `.isoPriority` keep ISO control and the same fixed
  shutter. No new exposure mode is introduced.

`CameraSession.filmShutterDuration` (F4) becomes a mode-aware accessor used by
`lockManualExposure`, `pinShutterToFilm`, `startRecording`, and
`applySelectedAperture` — all already funnel through `setExposureLocked`.

## 6. Grain cadence at half speed (`1/2` speed, 30 Hz grain)

The exported clip keeps **full 60 fps motion and per-frame PTS**: only the grain
field's temporal cadence is halved, so pairs `(2k, 2k+1)` share one grain
realization. This is an experimental aesthetic choice: 30 Hz grain over 60 Hz
motion. It is not claimed to be an industry standard or visually approved.

### 6.1 Precisely what "same grain" means

Identical **grain realization / seed**: the pair shares `frameIndex` fed to the
grain kernel, i.e. the same z-slice (`zSlice = (fmod(grainIndex,128)+0.5)/128`),
the same `frameOffset` phase, and the same sampling coordinates
(`Resources/Shaders/grain.metal` 82-110). It is **not** a guarantee of a
pixel-identical composite: the two source frames differ in content, so the
luminance-adapted `latitude`, the `edgeFactor`, the per-pixel headroom budget and
the `base` mix all differ (`grain.metal` 61-129). Only the grain *field* is shared;
the composite is not. State this in code comments and tests so nobody asserts
pixel equality.

### 6.2 Where it changes

New pure policy (place in `App/Modules/ProcessingPipeline/GrainModel.swift` or a
new `GrainPairingPolicy.swift`), unit-testable without a GPU:

```swift
enum GrainPairing: String, Codable { case perFrame, pairedAtHalfRate }

enum GrainPairingPolicy {
    /// pairedAtHalfRate: 0,0,1,1,2,2,...   perFrame: 0,1,2,3,...
    static func grainIndex(frameIndex: UInt32, pairing: GrainPairing) -> UInt32
}
```

`PipelineRenderer.processFrames` keeps `frameIndex` (used for failure injection at
`~913` and only there), and computes `grainIndex` from `pairing` to pass into
`renderFrame` → `runPass2` → `GrainUniforms.frameIndex` (`~1214`). The append path
(`videoReceiver.append(sample, presentationTime: sample PTS)`) is **not** touched:
PTS stays per-frame and motion stays 60 fps. `runPass2`'s signature is unchanged in
type (still a `UInt32`), so `GrainABITests` (20-byte struct, offsets 0/4/8/12/16)
stays valid.

`pairing` is taken from the **job's persisted capture policy** (§8), not from any
live UI.

## 7. Failure modes (fail clearly, never silent-downgrade)

New `CameraError` case(s) in `CameraSession.swift`:

- `.daylight60Unsupported(String)` — "Daylight 60 fps is unavailable on this
  device: no 4K Apple Log 2 10-bit format supports 60 fps." Shown when the user
  tries to arm the mode on an ineligible device, and when a take is attempted
  while `.daylight60` is requested but no eligible format/frame-duration exists.
- Reuse `.writerUnavailable`/`.recordingStartFailed` only for their existing
  meanings. Never silently record 24 fps when `.daylight60` was requested.

Arming is preconditioned on eligibility read from the active device at arm time
(`CameraCaptureFormatPolicy.appleLog2SixtyCandidateIndexes` against
`device.formats`); the control is disabled with an explanatory label if the device
is ineligible, so the common path never reaches a mid-take failure. A mid-take
failure (device/format changed, reassert failed) fails prominently via the
existing `failRecordingProminently` path in `CameraViewModel`.

## 8. Persisted, backwards-compatible per-job policy

Queued jobs must never read live UI and must not lose cadence after a restart.
The frame-rate decision is snapshotted at enqueue and carried in the job JSON.

`RenderJob` (`App/Modules/RenderQueue/RenderJob.swift`) gains one **optional**
field:

```swift
/// Capture policy at enqueue time. nil preserves legacy behaviour: 24 fps,
/// per-frame grain, 1/48 shutter metadata. Never read from live UI.
var capturePolicy: RenderCapturePolicy? = nil
```

```swift
/// Codable, Equatable, Sendable. Value snapshot, not a reference.
struct RenderCapturePolicy: Codable, Equatable, Sendable {
    var frameRate: Int          // 24 or 60
    var grainPairing: GrainPairing
    var shutterDenominator: Int // 48 or 120
    init?(_ frameRate: Int)     // nil unless 24 or 60; derives pairing+denominator
}
```

- **Backwards compatible.** Decoding a job written before this change yields
  `capturePolicy == nil`; `QueuePersister.load` already decodes element-wise with
  `FailableJob`, so an unknown/absent field cannot make the queue unreadable
  (`QueuePersister.swift` 24-46). `nil` → 24 fps, `perFrame`, `1/48`.
- **Set once, at enqueue.** `RenderQueueViewModel.enqueue(...)`
  (`RenderQueueViewModel.swift` 154-177) and the awaiting-stock/
  `assignStock` paths take a `capturePolicy:` parameter and store it. The single
  post-recording enqueue call site passes
  `RenderCapturePolicy(sessionSnapshot.frameRate)`. `deliveryPreferences` pattern
  (`RenderDeliveryPreferences`, `FilmStockConfig.swift` 273-294) is the model for
  adding an optional decoded-with-defaults field.
- **Read only in the renderer.** `RenderQueueViewModel.render(_:)` (~624-635)
  passes `job.capturePolicy` into `PipelineRenderer.render`, which uses it for the
  grain `pairing` (§6) and for `RenderMovieMetadata` (§F8). After a relaunch the
  job renders identically with no live state.
- Old jobs and 24 fps jobs render byte-for-byte as before (`perFrame`, `1/48`).

## 9. Runtime transition and reset (foreground session)

New `CameraFrameRatePolicy` (`App/Modules/CameraCapture/CameraFrameRatePolicy.swift`,
or extend `CameraStabilizationPolicy.swift`'s pattern):

```swift
enum CameraFrameRatePolicy {
    static func canChange(recording: Bool, starting: Bool, finishing: Bool) -> Bool
    // !recording && !starting && !finishing  — mirrors CameraStabilizationPolicy.canChange
}
```

State on `CameraViewModel`:

- `private(set) var sessionFrameRate: CameraFrameRate = .standard24` (never persisted).
- `private var pendingFrameRateReset = false`.

Rules:

1. **Arm/disarm** allowed only when `canChange(...)` is true (not recording/
   starting/finishing) — the control is enabled/disabled from the same snapshot
   the stabilizer uses.
2. **Immutable through a draining take.** Once a take is pending/active/finishing,
   the mode cannot change, including implicitly: recorders, metadata and the
   enqueued job all read the mode captured at take start.
3. **Reset on the session boundary.** `onSceneInactive` (`CameraViewModel.swift`
   144-169) and `onDisappear` reset the mode to `.standard24`. If a take is
   draining when the boundary fires, set `pendingFrameRateReset = true` instead,
   and apply the reset from `handleRecordingFinished` (740-777) once
   `isRecording`, `isStartingRecording`, `isStoppingRecording` are all false —
   so the **enqueued job keeps its captured policy** even though the live mode has
   reverted.
4. **Cold launch** starts `.standard24` (the value is initialised, never loaded).

Because the enqueue snapshot (§8) already carries the policy, the reset can be
aggressive without losing cadence.

## 10. UI: smallest coherent break-glass control

- **Placement.** One raised toggle in the manual-controls surface, reached from
  the top-toolbar manual slot (`CameraControlBar.swift`, `CameraTopPanelLayout`
  geometry, `ManualControlsPanel.swift`/`ManualControlsOverlay.swift`). New small
  view `Daylight60Control.swift` in `App/Modules/CameraCapture/`, styled with the
  existing `CameraRaisedButtonStyle`/`CameraRaisedSurface`. It is **not** on the
  shooting bar, so it cannot be hit accidentally; it is reachable **outside
  recording** (disabled the instant a take starts).
- **States.** `unavailable` (device ineligible — dimmed, reason label),
  `off` (default), `confirm` (one confirming tap showing the warning), `active`.
- **Warning copy** (shown at `confirm`, repeated on the active badge):
  "60 fps video · less cinematic motion · modest exposure headroom — not
  unlimited. ND still required."
- **Prominent active status.** While `.daylight60` is armed, a hazard badge
  ("60 fps DAYLIGHT") shows on the recording status face
  (`CameraStatusPresentation.swift` / `RecordingStatusFace.swift`) and beside the
  timer (`RecordingTimerBadge.swift`), so it is unmistakable during the take —
  consistent with the standing rule that recording-only chrome appears only while
  recording. Orientation exceptions follow the existing
  `CameraGlyphRotation`/`cameraRotatingControl` pattern.
- **Accessibility.** Distinct `accessibilityLabel`/`hint`/`value` naming the state
  and the warning, mirroring `CameraControlBar`'s exposure/stock controls.

No WB or LUT UI is touched.

## 11. Metadata

Preserve, do not re-decide:

- **Orientation/rotation** — `preferredTransform` on the writer input and the
  recording-node rotation snapshot are unchanged (`PipelineRenderer` ~245;
  `CameraSession` rotation snapshot ~1793-1798).
- **Apple Log 2 / 10-bit HEVC / audio timing** — untouched. AAC passthrough and
  the recorder boundaries in `docs/recording-av-timing.md` are not modified.
- **Capture tags** (`captureMetadataItems`, 2065-2078) — keep `shutter-speed`,
  `shutter-angle`, `capture-iso`, `capture-color-space`, `capture-format`,
  `capture-codec`. `capture-format` already reads the asserted fps (F6); the
  `shutter-angle` must use the active fps (F5). Optionally add
  `com.filmemulation.capture-frame-rate` for provenance; if added, register it in
  `RenderReceiptService.metadataKeys` (`RenderReceiptService.swift` 8-16) and the
  render allow-list — but note the capture tag set and the render tag set are
  distinct; adding to the render allow-list only if the render emits it.
- **Render tags** (`RenderMovieMetadata.make`, F8) — emit `shutter-speed`
  (`1/48`/`1/120`) and `shutter-angle` from the job's `capturePolicy`; leave every
  other render tag, `render-settings` JSON schema, and the consumer caption
  (`RenderConsumerMetadata`) unchanged. `shutter-angle` stays `180` for both modes.

## 12. Edge matrix

| # | Case | Expected |
|---|---|---|
| E1 | Device has no 60 fps Apple Log 2 10-bit 4K format | Control `unavailable` with reason; arming throws `.daylight60Unsupported`; **no** 24 fps fallback |
| E2 | 60 fps range exists only on a non-4K or non-10-bit format | Not eligible; same as E1 |
| E3 | Frame-rate changed while recording/starting/finishing | Control disabled; arm/disarm rejected by `canChange` |
| E4 | Background mid-`startRecording` (pending) | Take cancels as today; mode resets (no drain) |
| E5 | Background while a take is draining (stop already requested) | Reset deferred via `pendingFrameRateReset`; enqueued job keeps 60 fps policy |
| E6 | Relaunch after a 60 fps take was queued | Job renders 60 fps behaviour from persisted `capturePolicy`; live mode is 24 fps |
| E7 | Legacy `renderQueue.json` with no `capturePolicy` field | Decodes `nil`; renders 24 fps/`perFrame`/`1/48` exactly as before |
| E8 | 60 fps take exported | Full 60 fps PTS preserved; grain index shared per pair; metadata `1/120` and (if added) frame-rate 60 |
| E9 | A 60 fps sample arrives with no duration; recorder falls back | `fallbackDuration` timescale 24 is a fallback only; confirm it never truncates the drain — if it can, parameterise it by mode |
| E10 | User toggles mode off, then records | 24 fps, `1/48`, `perFrame` |
| E11 | Custom exposure set (manual ISO) in 60 fps mode | Shutter pinned `1/120`; min/max frame duration re-asserted under lock |
| E12 | Shutter-priority (auto ISO) re-pins in 60 fps mode | Same fixed `1/120`; frame duration re-asserted after each `setExposureModeCustom` |
| E13 | Lens switch while `.daylight60` armed, not recording | New device selected at 60; if ineligible reject the switch and restore the previous working lens/mode atomically, with an explanatory error. No implicit 24fps downgrade. |
| E14 | Arm eligible, then device becomes ineligible before take | `startRecording` fails prominently with `.daylight60Unsupported`; no wrong-rate recording |
| E15 | Fractional/rounded fps in receipt | `RenderReceipt.framesPerSecond` reads ~60; presentation (`QueueReceiptViews` 152) shows it without change |

## 13. Non-goals

- No persistence of the mode (no `UserDefaults` key, no Settings mirror).
- No 60 fps default; no automatic scene-based switching.
- No variable frame rate, no per-scene adaptation, no auto-ND.
- No WB, LUT, halation, glow, or recipe changes.
- No editing/trim/re-render UI; no timeline.
- No change to delivery bitrate/quality or `RenderDeliveryPreferences`.
- No change to the splash (`StartupSplashTiming`) or storage estimate.
- No probe executables. No edits to `docs/prioritization.md`.
- No relaxation of the recorder's timing/skew tolerances (§2 of
  `docs/recording-av-timing.md`).

## 14. Testing and build gates

Unit (Swift Testing, RenderCLI scheme; run via `python3 scripts/verify.py lint`
for quick feedback, coordinator owns `verify`/`device`):

- `CameraFrameRatePolicyTests` — `canChange` truth table over
  recording/starting/finishing; reset-on-boundary; deferred reset through a drain.
- `CameraCaptureFormatPolicy` tests (`CameraPolicyTests.swift`) — 60 selector
  accepts only 4K Apple Log 2 10-bit formats whose range includes 60; rejects
  non-60; 24 selector unchanged (existing cases at `CameraPolicyTests.swift`
  104-124 stay green).
- `ExposureManagerTests` — fixed shutter `1/120` in `.daylight60` for auto,
  shutter-priority, manual and ISO-priority; clamp allows `1/120` and still
  clamps into the device range; 24 fps values unchanged.
- `GrainPairingPolicy` tests — `0,0,1,1,2,2,…` for `pairedAtHalfRate`, identity
  for `perFrame`; `GrainABITests` layout test still passes (struct unchanged).
- `RenderJob`/`QueuePersister` tests — `capturePolicy` round-trips; legacy JSON
  with the field absent decodes `nil`; a malformed entry is still dropped without
  failing the whole load.
- `RenderMovieMetadata` tests — 60 fps job emits `shutter-speed 1/120`,
  `shutter-angle 180`, capture frame-rate 60; 24 fps job unchanged; `render-settings`
  schema unaffected.
- `RenderExportReceiptTests` — receipt around a 60 fps source still parses.
- Recorder — an E9 regression covering the duration fallback at 60 fps if the
  fallback can truncate.

Build gates at completion (coordinator, outside the sandbox):

```sh
python3 scripts/verify.py verify     # lint, RenderCLI tests, generic iOS build, git diff --check
python3 scripts/verify.py device     # signed device build, last
```

Device smoke: one 60 fps take and one 24 fps take, confirming 180° holds, the
clip reports ~60 fps, audio skew/end-delta stay within the unchanged 0.12 s
bounds, and the rendered 60 fps export shows paired grain with full motion.

## 15. Exact files / functions to touch

New:

- `App/Modules/CameraCapture/CameraFrameRatePolicy.swift` — `CameraFrameRate`,
  `CameraFrameRatePolicy.canChange`, reset semantics.
- `App/Modules/CameraCapture/Daylight60Control.swift` — the break-glass control.
- `App/Modules/ProcessingPipeline/GrainPairingPolicy.swift` (or fold into
  `GrainModel.swift`) — `GrainPairing`, `GrainPairingPolicy.grainIndex`.
- `Tests/CameraFrameRatePolicyTests.swift`, `Tests/GrainPairingPolicyTests.swift`.

Modified:

- `App/Modules/CameraCapture/CameraSession.swift` — `applyCaptureFormat`,
  `reassertFrameDuration` (new), `setExposureLocked`,
  `applyCustomExposureHoldingAperture`, `pinShutterToFilm`, lens-switch rollback,
  `startRecording`, `filmShutterDuration`, `captureMetadataItems`, `CameraError`.
- `App/Modules/CameraCapture/CameraPolicies.swift` — `Candidate.supports60FPS`,
  `appleLog2SixtyCandidateIndexes`, `appleLog2CaptureFormats` computation.
- `App/Modules/CameraCapture/ExposureStateMachine.swift` — frame-rate-aware
  shutter set and clamp.
- `App/Modules/CameraCapture/CameraViewModel.swift` — `sessionFrameRate`,
  `pendingFrameRateReset`, `onSceneInactive`, `onDisappear`,
  `handleRecordingFinished`, arm/disarm action, enqueue snapshot.
- `App/Modules/CameraCapture/CameraStatusPresentation.swift` /
  `RecordingStatusFace.swift` / `RecordingTimerBadge.swift` — active badge.
- `App/Modules/CameraCapture/ManualControlsPanel.swift` /
  `ManualControlsOverlay.swift` / `CameraTopPanelLayout.swift` — host the control.
- `App/Modules/ProcessingPipeline/PipelineRenderer.swift` — `processFrames`,
  `renderFrame`, `runPass2` call, metadata call.
- `App/Modules/ProcessingPipeline/RenderDiagnostics.swift` — `RenderMovieMetadata.make`.
- `App/Modules/RenderQueue/RenderJob.swift` — `capturePolicy` +
  `RenderCapturePolicy`.
- `App/Modules/RenderQueue/RenderQueueViewModel.swift` — `enqueue`,
  `enqueueAwaitingStock`, `assignStock`, `render`.
- `Tests/` — the suites in §14.

## 16. Review decisions and remaining device checks

Coordinator review (before implementation): these decisions override the
illustrative APIs above where they conflict.

- Exposure reduction is 2.5× / 1.32 stops, not halving / one stop.
- Paired grain is experimental; no aesthetic or industry-standard claim.
- Parameterise the recorder duration fallback by the immutable take policy now.
- An unsupported lens switch must roll back to the previous lens and mode; do
  not silently turn off the armed mode. Mode changes themselves are atomic:
  preflight capability and restore old format/exposure/output state on failure.
- Guard record, lens and mode actions while a mode transition is pending. Fence
  completion callbacks against lifecycle generations; a backgrounded transition
  must not restore 60fps on the next foreground session.
- Snapshot the policy at take start and associate it with the completed URL,
  through CameraScreen enqueue / awaiting-stock paths. Do not read current mode
  when observation of lastRecordedURL fires after reset.
- Persist a minimal constrained Codable mode rather than three independently
  mutable values if that eliminates invalid fps/shutter/grain combinations.
- Do not alter the legacy ExposureManager unless it is actually used by this
  capture path. Its standalone historical modes are not this feature.
- Keep frameIndex for diagnostics/failure injection; derive the grain index only
  at the grain call, not by halving the whole render-loop index.
- Native integration must exercise a short synthetic 60fps clip through the real
  renderer and assert output frame count, PTS cadence, metadata and audio. Pure
  policy tests alone do not prove that output stayed 60fps.
- Apple docs confirm custom exposure may alter frame durations. Reassert under
  the existing lock; ensure recording begins only after exposure is applied and
  the requested rate is verified. Do not assume callback arrival proves timing.

Remaining checks:


1. **`1/120` authorization.** The user explicitly requested it; no additional
   product sign-off is needed. Keep the legacy ExposureManager API unchanged if
   it is not on the actual hardware control path. The mode-aware capture policy
   must provide the fixed shutter for both manual and automatic ISO. Do not
   broaden unrelated legacy exposure modes merely to make this feature compile.
2. **Recorder duration fallback (E9).** Parameterise by take mode and test missing
   sample duration without weakening the existing A/V tolerances.
3. **Frame-rate reassert vs. exposure completion order.** Apple calls the
   `setExposureModeCustom` completion on its own queue; whether a reassert issued
   synchronously after the call (before the completion fires) can be overwritten by
   the completion is not yet device-verified. If it can, the reassert must move
   into the completion handler for the recording-start path.
4. **Grain pairing perceptibility.** Paired (30 Hz) grain over 60 Hz motion is the
   chosen design; the exact visual result is not yet reviewed on device — the spec
   fixes the mechanism, not a subjective pass.
5. **Apple Log 2 60 fps availability.** Whether the reference device's 4K Apple
   Log 2 format advertises a 60 fps range at all is unverified here; E1/E2 cover
   the unsupported path and the UI must degrade to `unavailable` cleanly.

## 17. Delivered implementation and validation

Implementation details superseding illustrative API choices above:

- `CameraFrameRatePolicy.swift` contains the constrained session mode, transition
  transaction seam, and bounded destination-URL policy ledger. Policy is bound
  to the original destination **before capture starts**, not reconstructed from
  the live mode or the current generation when a completion arrives.
- `RenderCapturePolicy.swift` lives under ProcessingPipeline; all fields are
  immutable and decoding rejects invalid or contradictory rate/shutter/grain
  combinations. Legacy jobs with no policy retain legacy rendering.
- Legacy `ExposureManager` is unchanged: actual hardware shutter control is in
  `CameraSession`. Both manual and auto-ISO capture use the mode's fixed shutter.
- `Daylight60Control` is embedded in the existing `ManualControlsSurface.swift`.
  Open the top-toolbar manual controls and expand them to reach it. Enabling
  requires a confirmation warning; the live timer/status face displays
  `READY · 60FPS`, `WAIT · 60FPS`, `REC · 60FPS` or `STOP · 60FPS` while armed. No preference remembers the mode across camera sessions.
- Failed mode changes restore the previous mode/format/output/exposure. Exposure
  writes participate in the transaction and cannot merely log failure then report
  success. A failed foreground reset remains pending and blocks new takes until
  resolved. Rollback negotiation failures invalidate capture rather than reviving
  stale accepted writer settings.
- `CameraSampleBufferRecorder` receives the take's frame duration. The regression
  uses genuinely missing video duration and an audio endpoint between 1/60 and
  1/24: it must wait for the second video frame. Restoring the old 1/24 fallback
  was exercised as a negative control and caused the expected assertion failure.

Executed on October 20, 2026:

- `python3 scripts/verify.py verify`: lint, repository helper tests, **548
  RenderCLI tests / 65 suites**, generic unsigned iOS build, `git diff --check`.
- Native `CameraDesign` suite: **44 tests / 5 suites** passed (including the
  armed-mode status-label regression).
- `python3 scripts/verify.py device`: signed development iOS build passed.
- Native 60fps export fixture checks real frame count and every presentation
  timestamp, ~60fps track rate, unchanged AAC payload and source bytes, and
  `1/120`/180° metadata. This is synthetic transport evidence, not real-camera or
  visual grain approval. Grain index policy tests prove pair mapping; source
  contract tests prove wiring only.

### Physical-device acceptance (still open)

The paired iPhone was reported **unavailable** by `xcrun devicectl list devices`.
No device installation, real capture, outdoor exposure test or subjective grain
approval is claimed.

1. Connect, trust and unlock the iPhone. In this worktree open `Nitrate.xcodeproj`,
   choose **Product → Scheme → NitrateDev**, choose the physical iPhone under
   **Product → Destination**, then **Product → Run**. Confirm **Nitrate Dev**, not
   the production app.
2. Open the manual controls from the top toolbar, expand, enable **Daylight 60 fps**
   and confirm. Check `READY · 60FPS` is visible. If unavailable, retain the
   explanatory message; do not substitute a lower-resolution/non-Log format.
3. With ISO at its floor in bright daylight, verify `1/120` and record moving
   detail with a clap at the beginning/end. Mode/lens controls must not change
   capture during start, recording or finish. Inspect the delivered movie/queue
   metadata for ~60fps and `1/120`; check beginning/end sound and motion normally.
4. Background during a 60fps take, return after it finishes, and confirm live
   capture is back to 24fps / `1/48`. The queued 60fps take must retain its policy.
   Repeat by backgrounding immediately after arming, then cold-launch once.
5. Compare the rendered 60fps clip with a normal 24fps clip for grain cadence,
   motion, exposure stability, and thermal/drop behavior at 4K. The paired field
   is an experiment; keep visual approval separate from the automated pass.
6. On failure, retain the original and queue metadata, note lens, stabilization,
   ISO and lifecycle sequence, and capture the visible error or device console.
   Do not delete the original to retry validation.

### Independent code review disposition

- Confirmed queue policy, paired grain indexing, capture/export metadata, legacy
  decoding, and destination-URL binding. No unsupported format downgrade added.
- The reported permanent reset lockout was not present in the reviewed final
  path: `startRecording` retries the reset before its pending guard. Nevertheless,
  invalid configuration now uses an explicit recovery error and notifies the VM
  to reconnect once, rather than claiming a transition is still in progress.
- Removed dead additions to the unused `RecordingTimerBadge`. The production
  timer lives in `RecordingStatusFace`; its mode marker is adjacent to the timer
  and preserves WAIT/REC/STOP rather than replacing those states. No duplicate
  recording overlay was introduced.
- Exposure callback ordering and settling remain real-device checks, not proven
  defects. Recording reasserts rate after exposure confirmation; a mode change
  submits the fixed shutter under the lock. No visual/physical pass is inferred
  from source-contract assertions.

## 18. EV-triggered rescue and non-scrolling Manual controls

This user-directed revision supersedes §10 and the Manual-controls placement in
§17. Capture, queue persistence, 60fps motion and paired-grain policy are unchanged.

- Offer a **Too bright?** button immediately above the EV column only when a
  valid, finite live reading is **at least 2 stops above the selected target**:
  `meteredEV - targetEV >= 2`. The target is the same as the displayed indicator:
  selected EV bias in automatic ISO, zero in manual ISO. Invalid/unavailable
  readings, underexposure and values below the threshold do not offer rescue.
- The button opens a confirmation **overlay inside the camera canvas**, never a
  system sheet or full page: the preview, toolbar and shooting bar keep their
  exact geometry and the scene stays visible behind a dim scrim (currently a 55%
  black wash). The card floats centred over the dim; tapping outside it dismisses
  without changing the mode. Explain that an **ND filter is recommended**, that
  temporary 60fps / 1/120 has **less cinematic motion**, and give the overexposure
  reason in film terms: negative stock's long shoulder used to hold a blown
  highlight, while a fixed 1/48 shutter here clips it. Explicitly confirm 60fps or
  cancel/keep 24fps. Card actions are deliberately larger than a 44pt toolbar key
  (min 52pt tall with 18pt horizontal padding) so the labels are never crowded.
  Unsupported hardware has a visible reason and no enable action. Take/transition
  gates remain in force.
- Place the button as a real, hit-testable sibling on the camera canvas, above
  the measured exposure bounds. It must not enlarge the shooting bar, resize the
  framed preview, or draw an unclickable control outside a small parent's bounds.
- The trigger disappears below the threshold even when rescue is armed. The
  existing active 60FPS status badge opens the same modal while idle so the user
  can return to 24fps without waiting for another overexposure event. Keep the
  WAIT/REC/STOP labels and disable management during a take or transition.
- Dismiss the modal when the app leaves the active scene. Mode is still
  session-only, resets at the existing boundary and never becomes a stock setting.
- Remove the old 60fps row from Manual controls. The Manual surface itself must
  have **no horizontal or vertical scrolling**, including compact/expanded modes.
  Fit controls responsively; do not hide the last row behind a clipped viewport
  or shrink touch targets merely to make a screenshot pass. Preserve zoom, focus,
  iris, stabilization and existing orientation/framed-preview contracts.

Validation before delivery:

1. Threshold tests: exact +2, just below, nonzero/negative targets, missing meter,
   NaN/infinity, over/under and manual target zero. No absolute-EV shortcut.
2. Native rescue-button/modal renders and geometry through portrait and both
   landscape holds; real hit region and no preview/shooting-bar size change.
   The confirmation is rendered as an in-canvas overlay, so its native fixture
   must show the stand-in preview still visible around the dimmed card rather
   than an opaque page.
3. Native compact/expanded Manual surfaces, including constrained viewports,
   verify full relevant control visibility with no scroll container.
4. Source wiring tests distinguish them from actual touch/device evidence.
5. Full `verify.py verify`, native CameraDesign suite and signed `verify.py device`,
   then install/read back Nitrate Dev if the connected phone permits it.

Revision verification (2026-10-20):

- Independent code review: no blocking findings. Shared bounds-preference wiring,
  selected-target semantics, explicit confirmation and active-badge return path
  were checked against the integrated source.
- `python3 scripts/verify.py verify`: passed (lint, supporting Python suites,
  RenderCLI tests, generic unsigned iOS build, diff check).
- CameraDesign native suite: **62 tests passed**, zero failures; result bundle
  `build/verification/exposure-rescue-native.xcresult`. Includes threshold policy,
  rotated rescue-button renders, modal fitting, and non-scrolling Manual surfaces.
- `python3 scripts/verify.py device`: signed build passed. Installed and read back
  **Nitrate Dev / com.nitrate.app.dev / 0.1.6 (6)** on the connected iPhone;
  launch succeeded and its process and live camera screen were observed.
- Physical bright-scene trigger/tap/confirmation and subjective grain appearance
  remain hands-on checks; native fixtures are not evidence of those interactions.
- Extremely short synthetic camera canvases with less than the compact panel's
  approximately 160pt minimum band can still clip. Tested supported phone-sized
  portrait-locked viewports fit; touch targets were not shrunk to hide this limit.

Revision note (integration with the live-only timer contract): the portrait/live
timer and its tally dot remain exclusive to a confirmed take, so the active 60 fps
badge was given an idle-only form. Below the rescue threshold — and only at idle —
`DaylightIdleBadgeGeometry` floats the same `RecordingStatusFace` (state + mode
label, no mark, no timer) centered on the stationary toolbar row in portrait and at
the physical top edge in landscape. It is a non-sizing canvas sibling, exactly like
the rescue button, so it never reserves a control slot, never hides the lens key and
never resizes the framed preview. Arming or disarming the frame rate invalidates any
in-flight focal gesture, and a pinch cannot start or continue while
`isChangingFrameRate`, so the two device-config paths cannot race.
