# Nitrate (iOS)

A film-emulation **camera** for iPhone. It records native 10-bit HEVC in
Apple Log 2, or HDR HLG BT.2020 on devices without Apple Log support, applies a
film-stock look afterwards, and saves the SDR Rec.709 result to Photos. Capture
is native 2K open gate or UHD, depending on the camera's available formats.

You shoot neutral. The film look comes back from the render.

## Highlights

- **2K open gate, on by default.** Nitrate records the sensor's native **4:3**
  readout — 1920×1440, 10-bit 4:2:2 Apple Log 2 or 4:2:0 HLG, at 24 or 60 fps
  where supported — instead of
  cropping to 16:9 and throwing the top and bottom away. Nothing is squeezed: the
  frame is the full sensor height, so the same take can be reframed vertical or
  widescreen in post. Switch to UHD 16:9 (3840×2160) in Settings → Capture
  Format. Open gate is the default where available; otherwise the app uses UHD
  if supported. Settings lists only formats supported by the current camera,
  source profile and frame rate, rather than offering an unsupported choice.
- **Full film emulation, not a preset.** The stock is a negative/print or reversal
  LUT generated from a spectral model, and it is only part of the look: halation bleeds light from
  the highlights, glow blooms the graded highlights, and grain is a real
  volumetric plate. None of it is a filter over a finished image.
- **Non-destructive development.** Open gate changes what is recorded, not
  what is kept — the Apple Log 2 or HDR HLG original stays intact during
  development and every look is a render of it. Enable saving the original to
  Photos to retain it after successful delivery and temporary-file cleanup.

## Why it exists

[mood.camera](https://mood.camera) is the reference point. Its idea is that you
pick a stock and **don't** preview it: you shoot, and the film comes back to you
later. That is a deliberate reproduction of shooting film, where you don't know
what you got until the roll is developed.

Nitrate keeps the full film development separate from capture. The monitor can
show a neutral image, stock colour only, or the ungraded source; it does not run
the complete halation, glow and grain chain. You choose the stock and gauge,
shoot, and see the full emulation when the render finishes. Debug builds also
provide a single-frame render for checking the complete look.

Three commitments follow from that:

- **A focused workflow.** Choose a film stock, capture a take, and render to
  Photos. Develop applies the same rendering to an Apple Log 2 video selected
  through the system picker.
- **Non-destructive development.** The camera writes an ungraded Apple Log 2 or
  HDR HLG recording. The film look is a separate render, and the original can be
  saved alongside it. Nothing is baked in at capture time; owned temporary
  movies are removed only after required deliveries are confirmed.
- **Real film behaviour, not a colour wash.** Halation, glow and grain are
  modelled as physical effects with per-stock geometry. Grain comes from a
  coherent multi-scale field; halation is highlight light scattering at a
  per-stock radius. Neither is a texture laid over a look-up table.

## Our scope promise

**Nitrate will never add trimming, timelines, projects, or editing adjustments.**

Choose **D** below the shutter to open Develop, then **choose a clip → choose a
stock and gauge → press Render → save to Photos**. Storage & Queue shows jobs
and saved results; clip selection lives in Develop.

Video import in Develop accepts **Apple Log 2 only**. HLG support applies to
recordings made by Nitrate; it does not admit HLG or Apple Log 1 imports. Watch
finished videos in Photos.

Develop accesses only the video selected through the system Photos picker,
without requesting photo-library read permission. Saving uses add-only Photos
access. The original video remains unchanged.

This scope applies to future releases as well.

## Privacy

Everything runs on the device: capture through AVFoundation, preview and render
through Metal. The app contains no analytics, no network client and no machine
learning frameworks, and there are no external URLs in its source.

**Generative AI tools never touch your images or videos.** Nothing in the app
generates, alters or "enhances" your footage, and none of it is used to train
anything.

Your media never leaves the phone. The only network access in the app is Apple's
StoreKit, for purchases. The only data the app touches is the camera, the
microphone, and the photo library when you ask it to save.

## Platform

### Why iPhone

Apple Log 2 defines the emulation's input domain. It is a real log curve in a wide
gamut, shipped by Apple as a capture colour space rather than reverse-engineered,
and it is supported downstream: Final Cut applies Apple's own Log 2 LUT, and
OpenColorIO implements the transfer function that this project's LUT generator is
built on. On iPhones without either Apple Log profile, native HLG BT.2020 capture
is converted into that same input domain before the existing film pipeline.
The shipped LUT cubes are unchanged.

That matters because the emulation needs an honest starting point. A film model
of a negative and a print can only be applied to an ungraded signal; against a
look already baked into the camera it would be guesswork on top of a guess.

### Supported iPhones

| | |
|---|---|
| OS | **iOS 27 or later.** The install target and capture implementation require it |
| Aperture | **iOS 27 or later.** The variable-aperture API the app uses is not available before that, and the app reports aperture as unavailable |
| Apple Log 2 | A camera advertising a matching native ten-bit Apple Log 2 format uses the existing Log 2 path |
| Non-Log HLG | Only devices advertising **neither Apple Log 1 nor Apple Log 2** may use native video-range **10-bit 4:2:0 HLG BT.2020** (`x420`). The measured older device is an iPhone 14 Pro on iOS 27.3; other models require their own capability checks |
| Apple Log 1 only | **Unsupported.** A device with Log 1 but without Log 2 is not eligible for the HLG path |
| Open gate | Needs native **1920×1440**, 4:2:2 Apple Log 2 or 4:2:0 HLG, at the requested frame rate. No UHD crop substitutes for open gate |
| No matching format | The Capture Format row is unavailable. The app does not invent a UHD option or silently record a different live selection |

The app checks advertised capabilities at runtime, not once during installation
and not against model names. It inspects both Apple Log profiles to choose the
permitted source path, then matches native dimensions, ten-bit layout and FPS.
Settings availability follows the active camera and frame rate. A missing or
stale preference is clamped to an available default; an explicit live request
that cannot be applied is refused with a notice rather than silently downgraded.

See [older-device support](docs/older-device-support.md) for the colour contract,
measured hardware evidence and remaining physical-device validation.

### Android

I have no plans to build one. The emulation is portable in principle — the look
is a 33³ cube, the effects are specified above, and the bake is plain Python — but
the capture path is Apple's (there is no Apple Log 2 on Android) and the render
kernels are Metal.

A port would be welcome. Note though that **this repository carries no licence
yet**, so the code is currently all rights reserved: an undecided thing rather
than a refusal, but ask before shipping anything derived from it.

## Feature breakdown

### Capture

| | |
|---|---|
| Format | **Open gate 2K (default where available):** 1920×1440 native 4:3, or **UHD 16:9:** 3840×2160 — ten-bit HEVC Main10 (`hvc1`), plus their portrait forms |
| Source | Apple Log 2, or native 4:2:0 HDR HLG BT.2020 on eligible non-Log devices — see [Platform](#platform) |
| Frame rate | **24FPS** or **60FPS**, only where the selected native format supports it; 120 fps is disabled in the current build configurations |
| Lenses | Ultrawide, Normal (1×), Tele, Front — the device's real lenses, with the active focal length shown |
| Aperture | Per-lens, over the stops the device reports (f/1.5–f/4.0 on the reference iPhone 18 Pro) |
| Exposure | 180° shutter priority by default (shutter locked to 1/48 s, ISO meters), plus manual EV and manual ISO |
| White balance | Locked per stock — 5600 K daylight negatives, 5500 K Ektachrome, 3200 K tungsten — so the LUT always sees the same white point |
| Stabilization | Recording-only: Off, Standard, Cinematic, Extreme (Apple extended cinematic). The preview stays independent, and the UI calls out the crop and latency |
| Light | Flash/lamp controls, subject to the active camera's hardware and thermal limits |

The capture path is strict on purpose. It negotiates a ten-bit bi-planar format
the device actually advertises, and validates every sample buffer — dimensions,
pixel format, plane count, source-specific transfer/primaries and colour matrix —
before the buffer reaches the writer. It fails loudly rather than writing a silently wrong
clip, and re-checks settings against the hardware instead of assuming them.

### Photo

Photo mode is enabled in the current Debug, DevRelease and Release
configurations. It captures Bayer RAW from a supported lens and develops a
separate JPEG through the shared film pipeline and queue. Saving the original
RAW to Photos is optional and independent of saving video originals. A lens
without Bayer RAW cannot take a Photo; Video remains a separate capability.
See [development and release builds](docs/development.md) for the configuration
switch and shared-camera behaviour.

### Camera interface

- Portrait-locked layout with fixed control positions. The control faces rotate
  to follow the physical device orientation while their positions stay put, so
  muscle memory survives rotation.
- Exposure runs on densely ticked rulers with visible detent snapping and
  selection haptics: EV at tenth-stop spacing, manual ISO at third-stop spacing.
- Auto exposure shows where it is metering. An under/over indicator beside the
  exposure readout gives a manual ISO change something to match.
- Lens selection is one button at the top right that opens a popout of raised
  keys inset in a well.
- **Storage & Queue** is a single sheet opened by one tap on the status LCD:
  space and remaining-time estimate first, queue activity and history below,
  with render progress, saved history, metadata, retry and error detail.
- **Frame mode** fits the preview into a bounded viewfinder between the top and
  bottom control bars, with black around it, instead of leaving a thin border
  over full-screen video. Focus taps, metering coordinates and pinch zoom stay
  relative to the real preview bounds.

### Preview colour

`Settings → Preview Color` decides what the monitor shows.

| Mode | Monitor shows |
|---|---|
| **Neutral** (default) | The permitted camera source converted to a normal-looking Rec.709 image — the framing and exposure view |
| **Stock LUT** | The selected stock's look, colour only |
| **Log** | The ungraded source view: Apple Log 2 on the Log path, HLG on the non-Log path |

Neutral and Stock LUT each use one monitoring LUT, never stacked. Native HLG
passes through the shared HLG-to-Apple-Wide-Gamut/Log-2 input adapter before
that LUT. The preview never runs grain, halation or glow. Monitoring does not
change the source profile recorded to the original.

The preview is a separate, independently gated, unstabilized capture output.
That keeps the native camera layer correct — the focus and metering geometry
depends on it — while recording stabilization is active. If a preview LUT or its
source is missing, the monitor falls back to Log and says so rather than showing
a wrong image.

### Film stocks

| Stock | Type | LUT |
|---|---|---|
| 250D / 5207 | Daylight | `5207 - Apple Log 2.cube` |
| 500T / 5219 | Tungsten | `5219 - Apple Log 2.cube` |
| EC 100D | Daylight, ISO 100, reversal | `Ektachrome 100D - Apple Log 2.cube` |

The two negative stocks use a fixed Kodak Vision 2383 print stage. EC 100D
is a direct positive-reversal model, without a 2383 print, and uses 5500 K
daylight balance. Its selector card is yellow with a blue stripe. The existing
negative-stock cubes are unchanged. See [LUT provenance](docs/lut-provenance.md).

Touch and hold any stock card for half a second to open its description; a
confirmation haptic acknowledges the info action. Viewing information does not
select that card or change the gauge. Tap still selects; swipe still scrolls.
VoiceOver exposes a separate **Stock info** action.

**Print gauge** is a separate axis from stock: 8mm, 16mm, 35mm, 75mm. The gauge
owns grain, both its size and its presence, and is chosen per stock. 35mm is the
neutral reference; 75mm is near grain-free.

### Render pipeline

Rendering is offline, per queued clip, through the same chain as the debug
single-frame renderer:

```
Apple Log 2 ───────────────────────┐
native HLG → shared input adapter ┴→ Apple Wide Gamut / Log 2
                    → scene-linear push/pull and highlight hold
                    → halation: decode → add scattered linear light → re-encode
                    → pass 1: stock LUT + output contrast
                    → spatial: glow
                    → pass 2: grain
                    → SDR Rec.709 HEVC encode → Photos
```

- **HLG input** is range-expanded from native ten-bit YCbCr, decoded with the
  scene-referred inverse HLG OETF, normalized so nominal 75% HLG white maps to
  scene-linear 1.0, gamut-converted from BT.2020 to Apple Wide Gamut, then encoded
  into the existing Log 2 LUT domain. This is a declared exposure convention,
  not camera calibration or a display tone map. The saved original remains HDR;
  film delivery remains SDR Rec.709.
- **Push/pull** applies the chosen fixed-stop development adjustment before
  halation and the stock LUT, with highlight hold. The render recipe records it.
- **Halation** decodes the prepared Apple Log 2 frame into scene-linear light
  and extracts per-channel energy above highlight thresholds. Three
  half-resolution Gaussian blurs spread red widest, green less, and blue least.
  Their contributions are added to the **linear source**, including its core,
  then re-encoded to Apple Log 2. The stock LUT grades source and scattered
  light together; halation is not a separate display-space overlay. Base radius,
  strength and channel weights are **per stock**. Bundled gauge multipliers
  retain 8mm/16mm strength, use 45% on 35mm and 20% on 75mm. The debug radius
  slider covers 0.0005–0.0030 in 0.0001 increments.
- **Glow** keeps its separate graded-luminance mask and wide amber bloom. It
  does not use the scene-linear halation mask.
- **Grain** is [described below](#how-the-grain-works).

The halation model is **physically informed, not a calibrated film simulation**.
Its channel thresholds are 0.75×, 1.5× and 3× decoded diffuse white; radius
multipliers are 1.8×, 1× and 0.5× the stock's base radius. Channel energy is divided
by a 10× excess reference before stock weights and strength are applied,
starting earlier with a gentler ramp. Stills retain their measured-headroom
anchor, with its share and floor also raised 25%. These are starting values for device tuning, not measured emulsion properties. Halation
addition is scene-linear and pre-LUT, with no background-dependent shadow gate;
final colour and highlight rolloff come from the same stock LUT as the source.
Passing GPU tests establishes the operation order and numerical behaviour, not
an aesthetic match to film or a physical-device performance result.

Every render writes a diagnostics manifest into the movie metadata: the recipe
(LUT, halation, glow and grain algorithm revisions and their parameters), a
per-resource SHA-256 including the LUT used, the source colour provenance, and
the stock's D/T light tag.

### Queue, export and delivery

- Serial render queue with durable state. A job survives backgrounding and
  crashes, and an interrupted job resumes rather than restarting.
- **Export settings** (`Settings → Export`): optionally save the ungraded
  original recording (Apple Log 2 or HDR HLG) to Photos alongside the render,
  and choose **High** (60 Mbps) or **Smaller** (30 Mbps) rendered file size. Each queued job
  snapshots the preferences it was created with, so changing a setting never
  rewrites work already queued. Resolution, frame rate and the capture format
  are never affected.
- Delivery order is deliberate. The rendered movie is saved first and the
  original second, each confirmed outcome is persisted before the next attempt,
  and a partial failure retries only what is missing — an original-only retry
  never re-renders or duplicates the render after its confirmation is durable.
  A crash between a Photos save and recording that result can still cause a
  duplicate on retry; the app does not read the library to reconcile that gap.
- **Latest render and history:** keep a locally derived JPEG poster (at most
  320 pixels on its longest edge and 64 KiB) and a compact technical render
  record. **Metadata** shows the recorded file properties and render settings;
  unknown historic details stay unavailable rather than using today's recipe.
- After required Photos deliveries and terminal queue state are durably saved,
  Nitrate removes its owned temporary source/output movies. Failed or partial
  deliveries, shared files still needed by another job, and legacy completed
  entries without a receipt are retained. Cleanup failure never repeats a
  confirmed Photos save.
- **Open Photos** is a best-effort general library handoff, not a link to a
  specific video or album. If opening fails, the app shows manual guidance for
  Photos' Recently Saved collection. Export access remains **add-only**; queue
  thumbnails and metadata never read the Photos library. Automatic album
  management is not implemented.

### Settings and purchase

A seven-day evaluation of the render, then a StoreKit-managed yearly
subscription or a lifetime unlock (`com.nitrate.subscription.yearly`,
`com.nitrate.lifetime`). Prices come from StoreKit.

Recording is never gated by purchase: after the evaluation ends you can keep
shooting on a supported capture path, and takes queue until the render is
unlocked. This is an in-app evaluation, not an Apple-managed introductory offer — do not describe it as a
free trial in store copy.

## How the film LUTs are made

Both shipped look-up tables are generated by this project. The full record —
sources, parameters, measurements, hashes — is in
[`docs/lut-provenance.md`](docs/lut-provenance.md).

The table is baked over Apple Log 2 in Apple Wide Gamut. Native HLG recordings
are adapted into that domain; the same unmodified cubes serve both paths:

```
Apple Log 2 code value          the cube's input axis: 33³, red fastest
  → decode to linear            Apple Log transfer function
  → Apple Wide Gamut → XYZ      primaries from Apple's published profile
  → confine to the spectral locus
  → film model                  negative → print → projection
  → Rec. 709, gamma 2.4         the cube's output, matching the display tag
```

Nothing here re-bakes a purchased or third-party LUT, and none of the
externally-produced tables that used to ship are distributed any more.

| Component | Source | Licence |
|---|---|---|
| Film model (negative → print → projection) | [Spectral Film LUT](https://github.com/JanLohse/spectral_film_lut) by Jan Lohse, pinned commit `6307a98` | MIT |
| Apple Log transfer function, Apple Wide Gamut primaries | [OpenColorIO](https://github.com/AcademySoftwareFoundation/OpenColorIO) v2.6.0, `AppleCameras.cpp` | BSD-3-Clause |
| Colour science and spectral handling | [colour-science](https://www.colour-science.org/) | BSD-3-Clause |
| Film data | Kodak Vision3 250D 5207 (2009), Vision3 500T 5219 (2007), Vision 2383/3383 print (1998), digitised from manufacturer datasheets by the generator project | — |

Two calibration decisions are deliberate departures from the obvious reading of
that source data:

1. **The illuminant is the neutral reference, not the stock's own balance.** The
   model takes scene white balance as a parameter, and the stocks declare 3200 K
   (5219) and 5500 K (5207). Those declarations are metadata that the pipeline
   never reads. The camera already white-balances the recording, so calibrating
   for the stock's own temperature tilted the film's sensitivity and put a large
   cast on neutral tones. The tables are baked at the neutral reference instead,
   which is also the generator's documented default.
2. **The input is confined to the physically producible colours.** Apple Wide
   Gamut's blue primary is imaginary (y = −0.076), so 49% of the cube's knots
   decode to chromaticities outside the CIE 1931 spectral locus. The model
   reconstructs a spectrum from chromaticity, which is only meaningful inside
   the locus; there, neighbouring knots jumped 0.83 apart and saturated blues
   grew near-black holes beside bright knots. Outside chromaticities are pulled
   onto the locus along the white-point ray at constant luminance (57% of knots),
   leaving in-locus colours bit-identical.

The generator is checked in at [`tools/lut-generation/`](tools/lut-generation/)
with pinned dependencies, the upstream commit it was run against, and the hashes
a regeneration has to reproduce byte-for-byte.

These are generated approximations of a film look. They are not Kodak products,
not Kodak-authorised, and not a colorimetric calibration of any camera or
display. "5207", "5219" and "2383" are Kodak emulsion numbers, used here
descriptively. The film data is limited by published datasheet precision, and
interlayer effects in the model are simplified.

## How the grain works

Grain is `pass2_grain`, a Metal kernel driven by a shipped 128³ noise volume
(`grain3d.raw`). Each render records the revision
`coherent-multiscale-edge-amplitude-v3`.

**Coherent multi-scale field.** Two fields come from the same volume at
incommensurate scales: a fine field at weight 0.74, and a clump field at the
golden-ratio conjugate scale 0.381966011 at weight 0.26. The clump term is what
makes grain read as clusters of developed silver rather than uniform per-pixel
noise. A third field at scale φ (1.618033989) drives restrained per-channel
chroma variation through the vector (−0.12, 0.015, 0.12), so red and blue
deviate in opposite directions while green stays near the luminance grain.

**Temporal behaviour.** Each frame takes its z-slice from the volume's centre
plane (`(frame mod 128 + 0.5) / 128`) and applies irrational per-frame in-plane
offsets from a low-discrepancy sequence (`phase = frame × 0.754877666`). The
field moves every frame the way film grain does, without repeating a pattern.
Blending trilinearly between volume planes was rejected: it changes the realized
RMS as the phase drifts and makes the whole image pump. A slowly varying vector
displacement, sampled from the volume at 0.035× scale and applied at 0.22
amplitude, breaks the volume's 128-texel repeat without pixel-wise UV jumps.

**Detail prefilter.** A normalised 5-tap cross (0.5 centre, 0.125 on each
orthogonal neighbour) softens detail finer than the grain footprint before the
noise is added. Every weight is positive, so constant regions are preserved
exactly and the filter cannot halo.

**Latitude window.** Grain is not applied uniformly. A luminance window
(`smoothstep(0.015, 0.13, luma) × (1 − smoothstep(0.78, 0.98, luma))`) fades it
out of near-black shadows and out of highlights, peaking in the mid-tones, the
way a real negative's grain reads in the print.

**The print gauge owns grain.** Presence is `baseAmount × gaugeAmplitude`. The
stock supplies size; the gauge multiplies both — 8mm ×4.0 size / ×0.55 presence,
16mm ×2.025 / ×0.396, 35mm ×0.9 / ×0.36, 75mm ×0.5 / ×0.165, with `baseAmount`
0.55. On the size axis 8mm keeps the footprint it had before this tuning, 16mm
keeps three quarters of it, 35mm halves it, and 75mm asks for half and is pinned
to the 0.95 floor. Presence sits 10% above the previous ladder for 8mm, 16mm and
75mm; 35mm sits ~33% above it, because halving its footprint put card-size grain
16% below one 8-bit display step (measured sigma 0.003386 against
1/255 = 0.003922) and the extra presence is what keeps a 35mm preview card
visibly grained at the new size. **ISO does not scale grain**; it is the exposure
index only.

**The ladder is configuration, not code.** Those multipliers ship in
`gauges.json`: `App/Resources/gauges.json` for the App, the byte-identical
`Resources/gauges.json` for RenderCLI, and both are bundled into the tests that
read the model. `PrintGauge.sizeMultiplier` and `amplitudeMultiplier` only read
that document, so re-tuning a gauge is a JSON edit — keep the two copies equal;
the grain tests assert it. The schema is typed and validated: a duplicated gauge,
a gauge with no entry, an unknown id, an unsupported `schemaVersion`, or a
multiplier that is not finite and positive is rejected, never defaulted.

The effective footprint is clamped to `0.95…16.0`, unchanged by this tuning:
below ~1.0 the 128³ volume is undersampled and finer size yields aliased noise
rather than finer grain. That bound is also why the finest gauge cannot reach
exactly half its previous footprint — 75mm asks for 0.575 and 0.65 on the two
shipped stocks and is held at 0.95 (73–83% of the previous 1.15 and 1.3).
75mm's near-grain-free look still comes from its amplitude multiplier, not from
pushing size into that regime.

**Edge amplification** is what makes grain follow image structure instead of
sitting on top of it:

```metal
edgeMagnitude = length(float2(lumaRight - lumaLeft,    // central difference in x
                              lumaDown  - lumaUp));    // central difference in y
edgeFactor    = 1.0 + saturate(edgeMagnitude * 3.0) * edgeBoostMultiplier;
amount        = 0.55 * gaugeAmplitude * edgeFactor;
```

The gradient is a central difference on the prefiltered neighbourhood, so it
measures edge *strength*, not contrast polarity. The gain saturates at
`edgeMagnitude ≥ 1/3`, and the shipped stocks set `edgeBoostMultiplier = 3`
(clamped to 3 by the kernel). Grain is therefore up to **4× louder across strong
edges** than in flat areas, and 1× in smooth regions: loud on texture, edges and
fine detail, quiet in skies and shadow. That is both how film grain reads and
what stops it looking like a uniform overlay.

**Headroom budget.** Before adding symmetric noise the kernel computes the
worst-case excursion (`latitude × 0.23 × (amount × 1.12 + 0.004)`, from the
volume's measured [0.385, 0.615] range) and scales the per-channel excursion
down, so positive grain can never push a pixel into 8-bit black. Grain cannot
crush blacks or clip highlights by construction.

## Repository

XcodeGen is the source of truth: `project.yml` defines the project, targets and
schemes, and the generated `*.xcodeproj` is gitignored. The Xcode project, app
target and primary scheme are named `Nitrate`. Release uses `com.nitrate.app`,
matching the App Store Connect record. Local Debug and DevRelease builds use
`com.nitrate.app.dev` (**Nitrate Dev**) with a separate container, so installing
a development build does not replace the production app.

One identifier still carries the older `com.filmemulation` namespace on purpose:
the `com.filmemulation.*` movie metadata keys. They are written into recorded and
rendered files, so renaming them changes the file contract rather than a label.

The iOS app target and the macOS `RenderCLI`/`RenderCLITests` targets share the
processing pipeline and film-stock sources, so the renderer is testable at 4K on
a Mac without a device.

```sh
python3 scripts/verify.py lint     # SwiftLint, fast feedback
python3 scripts/verify.py check    # lint + unsigned Debug/Release iOS builds
python3 scripts/verify.py verify   # lint + policy/RenderCLI tests + both builds + diff check
python3 scripts/verify.py device   # signed device build (run last)
```

Xcode and Metal work must run outside a sandbox. The tests cover the LUT
sampling kernel against an independent CPU reference, the full render and encode
path with real HEVC output, queue reliability and recovery, the capture,
exposure, grain and preview policies, and the film-stock catalogue.

## Versioning

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` are the single
source of truth. XcodeGen feeds them into the generated Info.plist, and the
launch splash renders them through `AppVersion` (`App/AppIdentity.swift`).

- This minor-release candidate is **0.7.0 (33)**, based on **0.6.2 (32)**.
  Preparing the release PR does not mean it has been distributed.
- Advance `MARKETING_VERSION` for each release PR into `main` (a patch increment
  by default unless a larger increment is explicitly requested).
- Increment `CURRENT_PROJECT_VERSION` for each new archive intended for
  distribution, including rebuilds. Ordinary local Debug builds do not bump it.
- `AppVersion.stage` (`App/AppIdentity.swift`) is the single source of truth for
  the stage suffix. It is `.beta` while the app is distributed through
  TestFlight; set it to `nil` for an App Store release. The launch splash and
  Settings → About both render `AppVersion.current()`, so they cannot disagree.

## Status and known limits

- **Implemented:** Apple Log 2 video import, Photo on Bayer-RAW-capable lenses,
  native open-gate capture, 24/60 fps selection, push/pull, flash/lamp controls and
  hardware capture events. Each remains subject to its hardware requirements.
- **HLG release verification:** 1,485 automated tests passed for the 0.7.0
  candidate rebased on 0.6.2, along with Debug, Release and signed device builds.
  Earlier iPhone 14 Pro captures verified native 24 fps Open Gate and UHD HLG
  originals and SDR film renders; the older-GPU LUT filtering fix was visually
  accepted. The 0.6.1 integration and corrected Develop panel were installed on
  the 14 Pro. Other phones and the remaining lens/FPS/audio matrix still require
  physical validation; advertised capability is not a completed device test.
- **Open work:** realistic gate jitter and weave, plus the remaining physical
  validation listed in [older-device support](docs/older-device-support.md).
- **Recording timing:** delayed-stabilization startup and stop-boundary defects
  are fixed. All eight preview/stabilization combinations passed the unchanged
  0.12-second device checks. See [the investigation](docs/recording-av-timing.md)
  for the measurements and remaining validation limits.
- **Unverified aesthetic:** the home-built 5207 and 5219 tables pass structural,
  smoothness and GPU-sampling checks, but nobody but the author has judged how
  they look on real footage.
- **No performance or power benchmark** has been run on the preview path.
