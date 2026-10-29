# Native preview and capture separation

Owner correction: native, unstyled camera preview in Photo and Video. Film processing applies only to saved output. Preview is not a second capture session and does not run a LUT, grain or halation renderer. Existing Video Log recording and output processing contracts remain unchanged.

## Approved shared idle architecture — October 27, 2026

The owner selected identical idle preview in both modes, with the true Apple Log 2 transition at Record. Mode selection changes capture intent only, not the idle sensor profile, preview surface, framing, color processing or exposure. Keep the existing Bayer-capable SDR graph and native preview in both idle modes. Record owns the serialized transition to the existing Log 2 recorder; Stop, failure and cancelled startup restore the shared idle graph. A capture-boundary transition is an acknowledged trade-off, not a claim of zero latency. Video controls retain recording intent where it differs from applied idle hardware. Preserve immediate recording press/tally feedback and second-tap cancellation. Do not re-encode SDR as Log, introduce a second capture session or hide interruption with a frozen frame.

Validation: mode toggles must retain the same live graph/profile and native surface; physical pinch must cross a lens boundary without overlay interception; Record/Stop must produce true Log 2 HEVC Main10 with audio and restore Bayer capture. Build and device testing are serialized with bounded compiler concurrency.

## Implementation boundary

- One serialized camera-session owner configures the physical device and outputs.
- One persistent AVCaptureVideoPreviewLayer displays the session. Photo and Video use the exact same preview rectangle, aspect-fill gravity, displayed framing and color appearance. The owner’s latest correction supersedes the native-still-aspect preview requirement; RAW capture extent remains independent. No duration-triggered blackout or preview-disable connection.
- Photo lens switches replace the Photo input/output configuration directly. They do not restore Video as an intermediate state. Validate Bayer capability and dimensions on the committed candidate graph; roll back to the prior Photo camera on failure.
- Capture owns its delegate until terminal callbacks, writes its DNG, then dispatches film development and Photos delivery independently of preview.
- Photo metering has one scheduled update, one active hardware exposure operation, latest-intent coalescing and exposure-duration-aware cadence. Meter observation must not repeatedly submit unchanged settings or reset bias on every tick. Capture/stop drain exposure and bias acknowledgments.
- Focus and metering map through the displayed crop. Aperture must use Photo exposure intent, never Video's film shutter.

## Queued development and top shutter rail — October 27, 2026

- Photo shutter is a horizontal top-preview overlay revealed by the existing Manual key. It reuses the shared ruler and immediate exposure-intent presentation; preview bounds remain unchanged.
- Captured DNGs enter the existing persistent render queue with captured stock, gauge, seed and software-crop settings. Camera ownership ends after RAW capture, independently of rendering and Photos delivery.
- Photo development uses the shared RAW decoder, Log adapter, Video LUT kernel/contrast, physical halation, glow and grain kernels. Original DNG and developed JPEG remain available locally. Default RAW exposure normalization remains explicitly uncalibrated.
- The LCD shows Photo rendering/saving activity. Its queue contains the developed image thumbnail and a full local photo preview, not a movie player or a Photos deep link.
- The clean physical CameraInteraction run executed 10 tests with zero failures: `build/photo-clean-ui-suite.log`, result bundle `Test-CameraInteraction-2026.10.27_19-03-09--0400.xcresult`. Includes horizontal drag and lock interaction, confirmed hardware exposure near one second, front capture, lens switches, bidirectional physical pinch, repeated mode selection, LCD-to-photo preview and Record/Stop-to-Photo delivery. Earlier intermittent horizontal-drag failure remains recorded; the diagnostic probe was removed before this passing run.
- Recording-start punch-in remains open: switching the shared idle graph to the recording sensor profile/stabilization can change framing. No compensation or calibration is claimed by these tests.

## Acceptance and limits

1. Unit tests execute cadence/debounce, unchanged-value deadband, long-exposure interval, capture priority and stop cancellation decisions.
2. Physical UI tests tap lens selection and Photo/Video mode controls, pinch, focus and capture. Include front camera capture/save, not selection alone.
3. Trace 1/4, 1/2 and 1 s mixed/manual exposure, rapid shutter gestures and restoration. Measure setter intervals; keep pending work bounded and retain the live exposure indicator. Passing policy tests does not establish CPU usage.
4. Inspect device screenshots and transition recording for aspect/LUT flashes. A successful mode-change callback alone is insufficient visual evidence.
5. Verify actual JPEG/DNG and Video Log HEVC Main10 with audio after Photo. Keep unverified color, recovery and full-spec work explicitly open.

## Executed evidence — October 27, 2026

- `python3 scripts/verify.py verify`: lint, 1,025 RenderCLI tests, unsigned iOS build and diff check passed. `python3 scripts/verify.py device`: signed build passed.
- Physical `CameraInteraction` suite: 4/4 passed together (rear lens selection/Video exit, front capture/save, zoom/capture/save, slow Photo capture/save/exit). Evidence: `build/native-final-ui.log` and exported attachments in `build/native-final-ui-images/`. The slow Photo screenshot shows the native framed image and no paused-preview warning; a still image does not prove frame cadence or absence of transition flashes.
- Burst trace: 60 ISO requests and 0.5 s shutter coalesced to one initial setter, requesting ISO 495; acknowledged ISO 494.15384, duration 0.499901 s. Slow RAW capture passed. Subsequent Video smoke validated hvc1 Main10 3840x2160, Log tagging and audio; A/V start skew 0.022 s, end delta 0.040 s. Evidence: `build/native-final-cadence.log`.
- The console command timed out after successful smoke messages; do not report its overall exit status as success. A subsequent normal relaunch was blocked because the phone locked.
- Front Bayer DNG validation now permits an omitted ActiveArea only when storage exactly matches usable dimensions. Padded buffers still require validated bounds. The existing front capture/save UI regression failed before this fix and passed afterwards.

Still open: direct device CPU measurement, the full 1/4–1 s gesture matrix, transition-motion inspection, double-failure lens recovery, physical aperture coverage, and RAW WB/color normalization evidence. Passing the above does not establish full Photo specification acceptance.

## White Photo renders — root cause and fix

Symptom: every developed Photo was effectively a flat, clipped image and halation/grain were invisible.

Cause: `RAWPhotoDecoder` built its `rgba16Float` destination with `descriptor.usage = [.shaderRead]` even though the decoder renders Core Image *into* that texture. Core Image could not write through the declared usage, so readback was uniform zero. Every later stage then operated on a constant: Log-2 clamped `0` to its floor, the LUT mapped a single code, and halation/grain had no spatial signal, so both looked "missing".

Fix: the destination advertises `.shaderRead, .shaderWrite, .renderTarget`, matching every other Core Image render destination in the pipeline. Measured on the real device DNG (`build/white-render.dng`):

| stage | before | after |
|---|---|---|
| RAW (linear) | min 0.0, max 0.0 | min 0.005, max 6.40 |
| Log 2 | flat 0.150 | 0.161 – 0.906 |
| graded | flat 0.117 | 0.114 – 0.897 |
| grain | flat 0.117 | 0.116 – 0.930 |

Delivered JPEG check on the same capture: mean 116/255, p5 26, p95 208, 0 % of pixels above 253 (the DNG's native decode clips 27 % of pixels at 255).

Regression coverage (`Tests/PhotoDevelopmentPipelineTests.swift`): the destination must report `.shaderWrite`/`.renderTarget` and round-trip exact linear samples; a horizontal ramp must survive with full spatial range; the existing stock/gauge/seed determinism test still applies to the developed result.

Already-developed Photo jobs keep their original DNG, so the queue offers **Re-render photo** (`QueueReceiptViews` → `RenderQueueViewModel.redevelopPhoto`). It discards only the stale JPEG + receipt and re-develops from the original without recapturing; Video jobs never expose it.

## Exposure, lifecycle and still grain — October 27, 2026

**Photo exposure was 2–5x dark.** `RAWPhotoDecoder` forced `CIRAWFilter.baselineExposure = 0`. The DNG's `BaselineExposure` is the capture's own exposure compensation; measured on real captures it is **+0.98 EV** (daylight) and **+2.49 EV** (dark room). With it honoured, mean linear RAW on the dark capture rose from 0.050 to 0.232 and the delivered JPEG from 39.6 to 92.2 (sRGB 0–255). `raw.exposure`, `shadowBias` and the boost controls stay zeroed; only `baselineExposure` is the DNG's.

**Still grain needed its own presence.** The photo path reuses the video `pass2_grain` kernel and uniforms, but video re-randomises grain per frame while a still is one static slice, and a 3024-px still loses more to any downscale than a 3840-px frame. `GrainModel.stillPresenceGain = 2.0` multiplies the gauge amplitude for stills only; the kernel's headroom budget still bounds the excursion in shadows and highlights. Measured on the dark capture: local high-frequency energy in a flat patch went 1.13 → 4.24 and the grain is plainly visible at 1:1.

**Backgrounding killed the camera.** Two separate faults:

1. `publishSharedProfile()` reported `configured = isConfigured`, which stayed true through the `.stopped` transition. The view model then believed the camera was ready, `configureAndStart` early-returned, and the idle graph was never reinstalled — the shutter existed but was disabled. A stopped graph now reports `configured = false`.
2. Any scene phase other than `.active` tore the session down. `.inactive` is transient (a permission alert, Control Center, an incoming call), and a teardown/restart in that window left the photo-exposure snapshot unpublished, so the next mode change was refused as "Shared idle camera is not ready". Only `.background` owns teardown now; `.inactive` leaves the session alone.

Device regressions: `CameraInteractionUITests.testCameraStillCapturesAfterBackgroundingAndReturning` (background → photo capture → video switch) and `testVideoModeSwitchAfterBackgroundingAndReturning`.

## Capture geometry (for reference)

- Photo: `3024x4032` DNG (ActiveArea), full 4:3 sensor, 12 MP budget (`PhotoCapturePolicy.maximumPixelCount`).
- Video: `3840x2160` (16:9), so video is a crop of the sensor's vertical field; photo keeps the full 4:3 frame. Preview framing is static and independent of both.

## Video EI, still delivery tags and the shutter face — October 27, 2026

**The app aborted on video EI.** Device crash report `2026-10-27 21:46:26`: faulting stack `reassertFrameDuration` → `_setExposureModeCustomWithLensAperture`, raising `NSInvalidArgumentException` out of the `AVCaptureDevice.activeFormat` setter. AVFoundation re-applies whatever custom exposure is installed from inside the frame-duration setters. The shared idle camera was holding the operator's Photo/video intent (a shutter and ISO chosen for a different format and rate), and that exposure is routinely invalid for the incoming Apple Log 2 format — so a plain property assignment aborted the process, with no Swift-level way to catch it. `CameraSession.applyCaptureFormat` now releases the custom exposure (back to `.continuousAutoExposure`) before touching `activeFormat`, `activeColorSpace` or the frame durations; the caller re-establishes its own mode afterwards. This is why the failure looked like "locked ISO is broken, even in auto": the abort happened while transiting into the take's format, whichever EI the operator had selected.

**One idle exposure contract.** `CameraFrameRatePolicy` now names the idle exposure in one place: `VideoExposureContract.idle(frameRate:isManualExposure:manualISO:bias:)` ⇒ `IdleExposureContract(durationSeconds: 1/48 @24 fps, 1/120 @60 fps, lockedISO: operator's ISO or nil for auto, exposureBias:)`. Leaving Photo re-asserts that contract on the shared idle graph, so the shutter returns to the film 180° value instead of keeping a photo shutter (1/4 s) — `VideoExposureContract` avoids re-deriving the same value at each call site.

**Operator command cadence is not the sensor's.** `PhotoExposureCadence.commandInterval` now drives operator writes while `measurementInterval(duration:)` still paces metering: at a 1 s shutter the rail previously waited 2.15 s for the sensor before acknowledging a change, which read as a rate limiter. Unit regression: `commandCadenceIsIndependentOfTheExposureSoASlowRailStaysResponsive`.

**Still delivery tags.** A still carries the same `com.filmemulation.*` payload as a movie, built by the one shared `RenderMovieMetadata.recipeValues(overrides:omitting:)`. A JPEG has no QuickTime keyspace, so the payload travels in Exif `UserComment` as JSON, with the consumer-visible caption and orientation keywords in IPTC, and the still's own shutter/ISO replacing the movie's nominal shutter angle and frame rate. Verified by writing the JPEG and reading it back: ImageIO persists `{Exif}` and `{IPTC}` for JPEG and **silently drops `{TIFF}`** — measured, not assumed — so the still makes no TIFF-description claim.

**Shutter face.** The capture button is a light-grey donut (`PhotoShutterFace`) sized inside the unchanged white ring: one surface tone, a rim highlight on the near lip and the shadow that lip casts into the well, so it reads as dished rather than domed. Its pixel test renders at 4x and asserts the open hole, the light-grey band, the opaque band up to the hole and the lip-to-wall shading direction; the delivery status moved off the shutter to its accessibility value.

**Device regression.** `CameraInteractionUITests.testVideoExposureIndexLocksThenSurvivesTakeAndModeSwitches` locks the video EI by long press, returns to auto, takes a real recording (the Log 2 transition that used to abort), then round-trips Photo ⇄ Video with the EI intent held. A crash fails the test outright.

## Per-camera ISO bands and the pinned shutter — October 27, 2026

**Video ISO is now capped per camera, not by the active format.** On the shared
idle graph `CameraSession.isoRange` is the *idle* format's range, and the still
format is wider than the recorder's. Measured on the device (iPhone 18 Pro,
iOS 27.2, `--dump-camera-ranges`, `build/device-trace/camera-ranges.txt`):

| Camera | Still format ISO | Apple Log 2 4K ISO |
| --- | --- | --- |
| Main (wide) | 55...12320 | 55...5280 |
| Ultra-wide | 15...3600 | 15...3600 |
| Telephoto | 15...7680 | 15...7680 |

The video ruler therefore read a top it could never reach on the main camera
(the user's report: "the top iso is different from photo mode and different
between cameras"). `CameraSession.videoISORange` resolves the band from the
eligible Apple Log 2 formats (`CameraVideoISORangePolicy` — the intersection, so
a frame-rate mode that picks a different format cannot widen it) and falls back
to the active format's range only when no Log 2 format is eligible. Consumers:
`CameraControlBar.isoSliderRange`, `CameraViewModel.clampedISO`, the video
`lockManualExposure` intent, and `restoreIdleGraphVideoExposureContract` (a held
ISO coming back from Photo is Photo's wider band and must be re-clamped).

**A pinned Photo ISO pins the shutter with it.** `DevelopmentPhotoController
.setISOLocked(_:filmShutterSeconds:)` now locks the shutter to the mode's film
standard (1/48s at 24 fps, 1/120s at 60 fps) whenever the ISO is pinned: an
operator who holds the ISO is asking for a repeatable film exposure, and the
shutter is then their only exposure control. The pin stays theirs to change,
or to unlock and float. `ContentView.showsPhotoShutterRail` surfaces the rail
whenever the ISO is pinned even with the manual panel collapsed
(`showInlineManualControls` starts false), because the rail is the only control
left; the other manual controls keep their own toggles.

**A floating shutter is a rescue, not a behaviour.** `PhotoShutterFloatPolicy`:
the shutter may only float when the pinned ISO is at an extreme of the camera's
own range — at or above `highWatermarkISO` (6400, or the camera's own top when
that is lower) or at the device floor — and the meter then cannot reach the
target EV on shutter alone. Inside the band the pinned shutter never drifts and
the unmet target is reported as `targetLimited` instead. The float stops at the
1/16s floor; anything slower is only reachable by a deliberate manual drag.

## A shutter tap always reaches the camera — October 27, 2026

The operator's report: "the shutter button to capture a photo sometimes either lags or is unclickable and I dont know why. nothing tells me why and it should never be like that it can try and fail but not prevent user from clicking".

The control is never `.disabled` and never dimmed. It has no opacity state at all: the tap is
always delivered, the capture may fail, and the failure is worded on screen
(`PhotoShutterReadiness.blockedReason`, surfaced as `photoShutterNotice`). A dead-looking
control that says nothing is worse than a refusal the operator can read.

Three mechanisms could make a healthy-looking tap do nothing, and each is now bounded:

- **`PhotoExposureCadence.setterTimeout = 1.2 s`** — a setter whose acknowledgement never
  arrives drops the in-flight flag instead of holding the next command hostage, so the shutter
  cannot stay blocked behind a stale write for the rest of the session.
- **`PhotoExposureCadence.captureTimeout = 3.0 s`** — a capture that never starts fails with a
  reason rather than waiting forever.
- **`DevelopmentPhotoController.captureToken`** — `armCaptureDeadline` records the token it was
  armed for, and consuming a pending capture invalidates it, so a superseded watchdog cannot
  fail the capture that replaced it.

`takeDevelopmentPhoto()` no longer has a silent `guard … else { return }`; every path out records
a notice. `PhotoShutterReadinessPolicy.readiness(...)` reports `.ready / .capturing /
.changingMode / .cameraNotReady`, and `attemptsCapture` is true in **all** of them — a test
asserts that, so no future state can reintroduce a refusal.

## Still grain reads as luminance, not colour — October 27, 2026

A single still inspected at 1:1 showed the shared dye-cloud term as coloured specks — no real
emulsion produces that. Video re-randomises the term every frame, so the eye averages it into
neutral grain; one still shows it raw. The term is now an explicit uniform
(`GrainUniforms.chromaAmount`, ABI 24 bytes) with `GrainModel.videoChromaAmount = 0.12` and
`GrainModel.stillChromaAmount = 0.02`.

Measured A/B through the production kernel on a flat mid-grey probe, four frames, iso 500,
grainSize 1.3 (chroma = sigma of R−B, luma = sigma of the mean; code steps):

| amount | chroma σ | luma σ | chroma/luma |
| --- | --- | --- | --- |
| 0.12 (video) | 2.24 | 7.25 | 0.31 |
| 0.02 (still) | 0.55 | 7.25 | 0.08 |

The still term is under one 8-bit code step, i.e. below the floor at which colour is readable.
The same probe on the **real device DNG** re-developed through the shipping still stages
(`05-grain.png` minus `04-graded.png`, central 400×400) gives a mono σ of 4.70 and an R−B
σ of 1.14 — but ~0.7 of that is the 8-bit quantisation floor of the difference image itself, and
the channel correlation is +0.97 (the channels move together), so the visible grain is
luminance. `stillGrainIsLuminanceDominantNotColoured` and
`stillGrainChromaIsAFractionOfTheVideoDyeCloudTerm` lock both bounds.

## Device state — October 28, 2026

`testPhotoISOLockSticksTheShutterRailAtTheFilmStandard` passed on the physical device
(`build/device-ui-iso-lock.xcresult`, 1 test, 0 failures, 16.2 s): the rail is absent until the
ISO is pinned, locking the ISO surfaces `photo.shutterRail` with the manual panel collapsed, and
`photo.shutter` stays enabled.

`NITRATE_VERIFY_JOBS=2 python3 scripts/verify.py verify` → `EXIT=0` (lint, unit tests, iOS
build, diff-check all passed; log `build/verification/20261028-03…`).

## The shutter that did nothing — root cause and fix, October 28, 2026

Operator report: "still having the shutter lag unclickable tap. its like the photos shutter is
waiting for something I guess in exposure but I cant tell whats going on".

Both halves of that sentence turned out to be true, and neither was the cause of the other.

### 1. Reproduced on the device: the taps never reached the camera

A new device UI test taps `photo.shutter` six times, 150 ms apart, then requires the control to
still be able to capture (`testPhotoShutterAnswersEveryTapInARow`). It failed: no photo, and
`build/trace-pull/tapburst-trace.txt` contained **no tap events at all** — while the XCUITest log
showed six `Synthesize event` lines for that element and the screen attachment showed a live Photo
mode with a normal-looking shutter. A tap the harness delivered, with no trace line from the
action body, is a hit-area bug.

`PhotoShutterFace` draws the donut as *stroked* rings and is marked `.allowsHitTesting(false)` so
its shading cannot steal the preview's pinch gesture. The button's hit region is therefore only its
painted pixels — the 2pt outer ring — and the donut's middle is an open, transparent hole, exactly
where an operator taps. Fix: the label declares its own round hit area (`.contentShape(Circle())`),
and the test now asserts `isHittable` as well as `isEnabled`.

After the fix the same test passes in 16.2 s and the trace records every tap end to end:

| tap | `capture-request` | `capture-terminal success` | latency |
| --- | --- | --- | --- |
| 1 | t=209985.5868 | t=209985.7859 | 0.199 s |
| 2 | t=209986.1339 | t=209986.1811 | 0.047 s |
| 3 | t=209986.6658 | t=209986.7119 | 0.046 s |
| 4 | t=209987.1661 | t=209987.2112 | 0.045 s |
| 5 | t=209987.6840 | t=209987.7396 | 0.055 s |
| 6 | t=209988.4003 | t=209988.4493 | 0.049 s |

...but the operator's build predates the donut, so his "waiting for something in exposure" had to
be found separately. It was, in the same trace.

### 2. The exposure loop could own the shutter

`capture()` deferred a tap whenever a setter was in flight (`capture-wait … pending=true`), and the
shutter-priority loop writes a correction every `commandInterval` (150 ms) — a tap had no priority
over that loop, and a dropped setter acknowledgement held it for the whole `setterTimeout`.

- `PhotoExposureCadence.captureImpatience = 0.2 s`: a waiting capture defers to the operator's own
  unwritten intent and to nothing else; past that the photo is taken with the exposure already
  installed (`capture(completion:force:)`).
- A waiting capture outranks the intent re-arm and cancels metering writes while it waits.
- `PhotoExposureCadence.captureTransactionTimeout = 8 s` and `CameraPhotoCapture.finishAfterTimeout`:
  a capture whose framework terminal callback never arrives used to leave `capturing` set **forever**
  — the shutter was dead for the rest of the session and the readiness could only say "not ready".
  The timeout now closes the transaction (the 30 s default only wrote a manifest note).

### 3. Every refusal is now readable

The status text over the shutter was removed at the operator's request, which left refusals with no
surface at all: "nothing tells me why" was literal. `ContentView` renders a transient status pill
above the control bar (never over the shutter) driven by `photoShutterNotice ?? photoDeliveryStatus`.
`takeDevelopmentPhoto()` no longer has a silent branch: an unengaged mode, a capture already in
flight, a mode transition and a not-ready camera each record a reason, and a view-model watchdog
releases the control if a completion is ever lost.

### Evidence

- `build/device-ui-tapburst.log` (failed, 6 taps, no capture) and `build/device-ui-tapburst2.log`
  (passed, 16.2 s) on `00008160-000648E83460000A`.
- `build/trace-pull/tapburst-trace.txt` (before: no tap events) and `build/trace-pull/tapburst2-trace.txt`
  (after: six complete tap→terminal chains).
- `build/tapburst-attachments/59C0EDD4-….png` (the live Photo mode the failing run left on screen).

## Photo EV is the phone's own auto exposure — October 28, 2026

Operator report: "the ev for photos always seems to be set by default too high and the shutter
isn't raising when ev is high. idk why we cant use the iphones in built systems for regular ev
compensation. and only when ISO and shutter are locked by the user change it. im fine if we rever
that have to try and keep shutter around 1/48".

Three separate mechanisms produced that, and only the third was the shutter *control*.

### The shutter was being re-pinned behind the operator

`CameraSession.mirrorVideoIntentToSharedIdle(iso:)` handed the shared ISO and compensation to the
Photo controller — and with them **Video's 180° film shutter**, as a pinned duration. It fires from
every shared-exposure write: the EV setter (`setExposureBiasEV`), the manual-ISO lock, the AE lock.
So while Photo owned the shared idle device, *any* EV change re-pinned the shutter at 1/48s and
overwrote whatever the operator had on the rail. The metering's only remaining lever was ISO, which
is why raising the compensation could not raise the shutter speed and a bright frame stayed bright.

Fix: `mirrorSharedExposureIntent(iso:)` mirrors the ISO and the compensation and deliberately not
the shutter — it composes the controller's next intent from the controller's *own* shutter lock
(`intentSnapshot.duration`). Video's film standard is a video rule; the Photo rail owns the Photo
shutter. A first entry into Photo in a session now also applies the shared compensation, which it
previously did not: the controller started at 0 EV until something happened to write the bias.

### Holding the ISO no longer holds the shutter

`setISOLocked(_:filmShutterSeconds:)` pinned the shutter to the film standard whenever the ISO was
pinned, and `PhotoShutterFloatPolicy` then only permitted the shutter to float as a *rescue* when
the pinned ISO sat at an extreme of the camera's range. Reverted: `setISOLocked(_:)` holds the
sensitivity and nothing else, and the float policy is now only a floor.

`PhotoShutterFloatPolicy` keeps `floorSeconds = 1/16s` (an auto-floated shutter never goes slower;
a manual selection still can) and loses `highWatermarkISO`, `highWatermark(in:)` and
`permitsFloat(iso:isoRange:)`. `PhotoExposurePolicy.decide` floats the shutter whenever the ISO is
held and the shutter is not, one bounded step at a time — the same shape the device's own auto
exposure has: a frame over the target raises the shutter, a frame under it lowers it.

The two locks remain independent and both explicit: a held ISO floats the shutter, a held shutter
floats the ISO, both held is fully manual, neither held is `continuousAutoExposure` with
`setExposureTargetBias` — i.e. the iPhone's own metering, which is what the operator asked for.

### Evidence

- `Tests/PhotoExposurePolicyTests.aHeldISOFloatsTheShutterToReachTheCompensation` (a frame 2 EV over
  the target raises the shutter one bounded step from the film standard; it used to return no
  correction and report `targetLimited`), `aHeldShutterIsNeverFloatedByTheISO`.
- `Tests/PhotoShutterFloatPolicyTests` trimmed to the floor rules; RenderCLI 53 tests in 6 suites.
- `UITests/CameraInteractionUITests.testPhotoISOLockSurfacesTheShutterRailAndLeavesTheShutterFree`
  (was `...SticksTheShutterRailAtTheFilmStandard`): holding the ISO surfaces the rail and the rail
  reads **Float**; one tap on it holds the shutter, which stays the operator's choice.

### Not changed

The compensation itself is still one stored preference shared by both modes
(`CameraExposureBiasPreference`, house default -1.2 EV, written by the EV control). A device that
shows a high EV on entry is showing a value the control was left at, not a default.

## The ISO that did not move — root causes and fixes, October 28, 2026

Reported: "the iso slider has so much lag in photo mode and in video mode iso
control isnt working at all. and I also got it to grey out the v or P with no
feedback n why".

Three separate mechanisms, each fixed where it lives.

### Video's manual exposure had two appliers and one of them did not exist

On the shared idle profile the ISO/EV/lock writers are deferred to Photo's
controller. That is correct *while a controller exists*, and it does exist in
Video's idle: entering the `.idle` profile installs it (`installSharedIdleOnQueue`
-> `startDevelopmentPhotoController`). The gap is every window without one — before
the first idle install, after teardown, and any tail of a transition — where the
deferral handed the intent to a `nil` controller and the write died silently. The
deferral flag was doing two jobs: "the video *writers* stand down" (preview
connection, microphone, sensor format, the 180° pin — true for the whole idle
profile) and "the *exposure* applier is Photo's controller" (true only while it
exists). They are now separate (`defersVideoExposureWrites`), and
`sharedVideoManualISO` is recorded on both paths so the take that follows still
picks up the operator's ISO.

Device evidence, pulled from `Documents/photo-exposure-trace.txt` during a real
chooser drag in Video mode:

    event=iso-deferred-to-photo ISO=1562.0 recordedISO=1562.0 controller=true expMode=2
    event=iso-deferred-to-photo ISO=1558.6 recordedISO=2000.0 controller=true expMode=3
    event=iso-deferred-to-photo ISO=1558.6 recordedISO=2500.0 controller=true
    event=iso-deferred-to-photo ISO=1558.6 recordedISO=3200.0 controller=true
    event=iso-deferred-to-photo ISO=1558.6 recordedISO=3520.0 controller=true

`expMode` moves 2 -> 3 (auto -> custom) and the device ISO follows the pinned
value, so the write does reach the camera. The corresponding UI test asserts the
*poll-fed* readout — device truth, not the chooser's own value — moves, which is
the difference between a control that works and a control that only looks like it
does: `testVideoISODragReachesTheDevice`.

### The Photo chooser was pulled out from under the finger

`presentPhotoExposure` wrote the device snapshot straight into `manualISO` on every
publish, and the ISO chooser's binding reads `manualISO`. Each snapshot therefore
yanked the ruler back to the camera's value mid-drag, so the next drag delta was
measured from a position the operator never chose: the control stuttered and read
as seconds behind the touch. This is the same contract the shutter rail already
had (`PhotoExposureIntentPresentation`), so the ISO now uses it too: the
operator's value is presented until the camera reports it back, acknowledged with
the write path's own tolerance because the device quantises ISO.

The operator's write also no longer queues behind the metering cadence: an intent
is applied at its own debounce deadline, not at
`max(intentDeadline, nextHardwareWrite)`. That throttle exists for sensor
corrections, and folding the operator's value into it delayed a value they had
already chosen behind a write they did not ask for. The setter acknowledgement
already serialises the device. Device evidence:
`testPhotoISOChooserHoldsTheOperatorValueAcrossSnapshots` drags the chooser and
requires the value to survive two seconds of snapshot traffic.

### A greyed mode row with no feedback is the bug, not the refusal

`canChangeShootingMode` is a conjunction of ten independent states and the row
went to 0.4 opacity with `.disabled` on every letter for any of them. A disabled
control cannot even report a refusal, so the operator is left tapping a grey "V"
with nothing to explain it. `CameraShootingModeGate` is now the single source of
truth for both the decision and the message, and the reason is shown above the row
while it is blocked ("Recording — stop the take to change modes", "Changing
camera…", …). Every state has its own message (asserted), because two blocked
states sharing one message is feedback the operator cannot act on.

`isChangingCaptureProfile` is a UI gate fed by the session's profile callback, and
a dropped update — the same class of loss already seen on setter acknowledgements
and capture terminals — left the row dimmed for the rest of the session. It now
has a deadline; clearing it is self-healing because a real transition sets it
again on its next update.
