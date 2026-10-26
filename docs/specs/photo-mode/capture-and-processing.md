# Photo capture and processing contract

Companion to `spec-photo-mode.md`. Requirements describe the accepted scope and proposed implementation, not claims that these components already exist. The detailed transform and work packages are in `implementation-plan.md`.

## Current baseline and integration boundaries

Baseline: source integration `b0f1009`; verified pinch change `deaf0bf`. Feature worktree parent `feat/photo-mode` includes the docs merge. This spec does not authorize replacing that work with the baseline layout.

| Existing component | Evidence and required boundary |
|---|---|
| `App/Modules/CameraCapture/CameraModeSelection.swift` | `CameraMode.photo` exists, but `visibleModes` excludes it and selection refuses it. Replace that global visibility assumption with release gating plus runtime availability. |
| `CameraSession.swift`, `CameraViewModel.swift` | Own video session configuration and controls. Add explicit photo configuration/capture seams on the existing serialized session owner; do not assume adding a photo output to the current Log 2 configuration is sufficient. |
| `CameraPolicies.swift` | Movie validation uses 4K video assumptions. Leave those gates unchanged and introduce a photo capability policy. |
| `FilmStockLibrary/FilmStockConfig.swift`, `StockLoader.swift` | Photo category vocabulary exists. The two active catalogue entries are video recipes; no ready photo catalogue follows from the enum. Add compatible photo selection without changing historical video jobs. |
| `ProcessingPipeline/PipelineRenderer.swift` | Movie input validation is Log 2-specific. Single-frame GPU work is a reuse seam, not a DNG renderer or production still writer. Extract common stages without routing stills through the movie front door. |
| `RenderQueue/RenderJob.swift` | Contains movie trim, frame-rate/capture policy and Log-original delivery assumptions. Use a separate versioned Photo job store; do not fabricate movie fields for stills. |
| `Resources/stocks.json`, `App/Resources/stocks.json` | Keep catalogue copies byte-identical. The catalogue currently declares Rec.2020 / Apple Log 2, but generator/provenance establish actual Apple Wide Gamut / Log 2 input and Rec.709-primary gamma-2.4 output. Use the actual cube domain for photos; do not silently rewrite historical video recipes. Provenance is not measured RAW calibration. |

## Mode transition and shooting interface

1. Accept a mode-change intent only while no recording/start/stop or still-capture transaction owns configuration. Rendering alone does not block changing mode.
2. Keep the current selected mode until the session owner commits the replacement configuration and reports readiness. Disable shutter and further switches while configuring.
3. On entry to Photo, detach/gate video-specific recording outputs as necessary, select a RAW-capable format and attach `AVCapturePhotoOutput`. Re-query capability after every physical lens or format change. Do not run two competing capture sessions.
4. Failure rolls back the previous valid configuration. If rollback also fails, show an explicit unavailable state with Retry; do not display a ready shutter over a stopped session.
5. Keep independent Photo and Video stock/gauge and exposure state. On leaving Photo restore the Video policy, including its session-only daylight setting only if still valid in that same foreground session; never carry that exception into a new session.
6. Preserve the latest centered carousel layout. D–V–P order, selected lowercase title, tap/swipe/haptics, fixed preview identity and reachable touch targets remain consistent. Add Photo without reverting active Develop work.
7. Photo replaces REC with a still shutter and accessible `Take photo` label. Do not display a REC tally, elapsed movie timer, 60 fps rescue action or recording-stabilization control. Show capture and render/save activity separately.
8. Use native still aspect for the viewfinder. Map focus, metering and zoom to the actual visible still region, including letterboxing, orientation and lens changes. No implicit 2:3 crop to match older UI planning.
9. Offer only capture-capable lens/zoom choices. Preserve the current selection until a new lens commits. Unsupported lens selection must not silently switch to another camera or format.

## Capability and capture contract

Use the active capture output's `availableRawPhotoPixelFormatTypes` filtered by `AVCapturePhotoOutput.isBayerRAWPixelFormat`. Do not turn on ProRAW or assume every advertised RAW type is Bayer. Attach the output to a valid configured session before trusting its capabilities.

The owner approved a 12 MP-class budget. Proposed concrete cap: 12,192,768 pixels, including 4032×3024; do not reject that nominal-12-MP size using a 12,000,000 cutoff. Inspect the active format's `supportedMaxPhotoDimensions`, configure `AVCapturePhotoOutput.maxPhotoDimensions` during configuration, and use valid per-request dimensions. Select the largest supported candidate within the budget for the proven Bayer path. The output's dimension cap is not a promise about the returned DNG: record and validate actual RAW dimensions. If the device cannot meet the agreed capture contract, report unsupported rather than downsampling an unbounded capture and claiming the memory budget was respected.

Create fresh `AVCapturePhotoSettings` for each request. Retain its delegate by `uniqueID` until the terminal capture callback. Accept only the expected RAW resource, reject duplicate/foreign callbacks, and write DNG data atomically to an app-owned capture directory. Do not request a processed companion solely to enable Nitrate processing. Snapshot capture orientation/zoom and actual exposure/WB metadata with the request; reconcile actual returned metadata without relabeling requested values as measured.

Write a capture journal before requesting the sensor. After a readable DNG is durable, persist its immutable Photo job, then acknowledge the journal. Only then is the shot accepted for development and the sensor transaction released for another shot. A successful sensor callback alone is not durable acceptance. A journal without a valid DNG is a visible interrupted capture, not an invented recovered photo.

A timeout invalidates the request's presentation epoch but retains ownership of late callbacks until the framework's terminal event. Do not issue another request into an unresolved capture transaction. A late valid DNG is retained for recovery; it must not trigger an unrelated shutter animation or be deleted as stale UI. Backgrounding stops new requests, lets terminal callbacks settle where execution permits, and relies on durable recovery if suspended.

## Exposure, focus and white balance

- Preserve existing ISO presentation, supported range, Float/Lock semantics. Add a Photo-only shutter ruler (placement is still proposed), with independent Float/Lock state and the complete active RAW-format `minExposureDuration...maxExposureDuration` range. No arbitrary endpoints and no video frame-rate ceiling. Revalidate both controls on active-format/lens changes.
- Define all four states: ISO Float + shutter Float = photo AE plus EV; ISO Lock + shutter Float = controller holds ISO while duration floats; ISO Float + shutter Lock = controller holds duration while ISO floats; both Lock = meter-only EV indication, with no exposure mutation. EV affects only the floating variable (both-floating uses normal AE bias); with both locked, EV is display-only. `setExposureModeCustom` locks BOTH ISO and duration, so mixed states require an explicit controller that meters the floating variable while preserving the pin, coordinating metering/stabilization and avoiding periodic auto reopening/flicker. Validate finite values and active-format ranges before AVFoundation setters. Use `.speed` prioritization when honoring manual pins and compare requested settings with actual DNG EXIF. Handle long-exposure busy time, timeout, cadence, and restoration. Set `activeMaxExposureDuration` as the Photo AE ceiling after format/preset selection; restore/reset appropriately on Video transitions because format/preset changes reset it.
- Focus and aperture remain capability-gated. Never promise user-adjustable aperture on fixed-aperture cameras.
- Keep the existing video WB lock behavior untouched. For photos, snapshot the selected stock's neutral-WB policy at capture and apply the agreed neutral temperature/tint exactly once in RAW development. Do not apply capture color gains and a second look-dependent WB shift without a documented transform test.
- A photo's sensor ISO/shutter/WB, selected creative grain/gauge and recipe identity are separate fields. Do not use film-stock ISO as fabricated EXIF capture ISO.

## RAW development and color pipeline

Required pipeline:

`DNG → color-managed extended-linear sRGB → linear Apple Wide Gamut → Apple Log 2 adapter → shared linear pre-LUT halation → 5207/5219 LUT and contrast → glow → float still grain → gamma-2.4-to-sRGB conversion → JPEG`

1. Use `CIRAWFilter(imageURL:)` or an equivalent SDK-backed RAW decoder. Freeze the decoder version and supported settings in the job. Preserve DNG bytes. Read actual output extent and apply orientation exactly once.
2. Establish, by fixture evidence, the decoder's transfer, gamut, baseline exposure and WB behavior. Render to half-float buffers using an explicit color-managed context. A half-float pixel format alone says nothing about transfer or primaries. Do not assume `CIRAWFilter.outputImage` is the desired scene-linear space.
3. Disable optional sharpening, local tone mapping, contrast boosts and noise/detail enhancement where supported. Record unsupported controls and decoder defaults. RAW still requires demosaicing and may require optical/color correction; never claim Apple processing is entirely absent.
4. Define a named, versioned adapter to scene-linear Apple Wide Gamut with documented reference-white/exposure normalization and negative/highlight handling. Use the explicit linear-sRGB-to-AppleWG matrix in `implementation-plan.md`; Rec.2020 is not the generated cube's actual input gamut. Convert primaries and transfer through real math, not new metadata tags. If RAW output cannot meet this contract, stop the slice; do not pass an appearance-matched SDR image through the LUT.
5. Encode adapter output to Apple Log 2 for the existing halation entry point, which decodes, scatters in linear light and re-encodes before the LUT. This preserves the shared stage contract without adding a pre-LUT display transform. Existing shader encode/decode helpers are candidates only after their range and round-trip behavior are exercised against the photo input.
6. Run the selected compatible LUT and the current established output-contrast/glow/grain behavior. Extract shared stages; do not reorder the video pipeline or make a second incompatible interpretation of the same recipe.
7. Realize grain once using a stored per-shot seed and snapshotted print gauge/strength. Retry must reproduce the same decoded pixels within the documented decoder/GPU tolerance; an OS decoder mismatch requires a visible incompatible-retry result, not a silent new look. Photo grain scale follows output geometry and gauge, never frame-rate pairing.
8. Convert the actual LUT output (Rec.709 primaries, pure gamma 2.4) into SDR sRGB after float-output grain; include a real matching ICC/profile/tag contract. Do not substitute the piecewise Rec.709 camera transfer or attach an sRGB label without conversion. Encode JPEG at proposed quality 0.95; reopen it and verify nonblank image, dimensions, orientation and profile before saving.

## Stock readiness

The owner approved the 5207 and 5219 looks. Add two explicit photo variants of those creative recipes. Give each a distinct photo stock ID, recipe revision and RAW-adapter identity; do not reclassify existing video entries. Sharing a cube is permitted only when the adapter delivers its exact declared input and real-DNG acceptance passes for that look. A new photo recipe is not automatically color-contract `verified`.

Record cube hash, adapter revision, working-space contract, decoder version/settings, halation/glow/grain parameters, seed and output profile/quality. Persist the resolved snapshot, not just a catalogue ID that a later release may change. If a required historic asset is unavailable after update, retain the source and explain why retry is unavailable; never substitute today's LUT.

The old brief's Portra 800, Gold 200, Cinestill 50D/800T and B&W catalogue remains future work. Its claims about prebundled photo assets are not evidence. This first slice proposes shoot-and-develop automatically; the old clean-capture/apply-later concept is excluded by the current no-editor scope.

## Blocking feasibility experiment before implementation fan-out

Prove one physical lens can configure Bayer RAW, emit a readable DNG within the agreed resolution budget, decode into the declared working space, and restore a valid Log 2 recording afterward. Save source metadata, selected format, actual dimensions, decoder settings and an output color chart. Do not start broad UI/queue work on the assumption that a Log 2 format can capture RAW unchanged.

Then validate the RAW color adapter on neutral, exposure-ramp, saturated-color, highlight and real-scene fixtures. No performance or calibrated-film claim follows merely from successful encoding. Failure changes this proposal and remains a named blocker.

## Primary API references

Retrieved from Apple's documentation on October 25, 2026. These establish API contracts, not Nitrate device readiness.

- RAW capture, Bayer/ProRAW distinction and DNG file data: `https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats`
- Decoder and available control families: `https://developer.apple.com/documentation/coreimage/cirawfilter`
- Active-format dimension constraints and configuration timing: `https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotodimensions`
- Photos access-level authorization: `https://developer.apple.com/documentation/photos/phphotolibrary/requestauthorization(for:handler:)`
