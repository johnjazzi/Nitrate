# Nitrate (iOS)

A film-emulation **camera** for iPhone. It records Apple Log 2 as 10-bit HEVC at
4K, applies a film-stock look in a render afterwards, and saves the result to
Photos.

You shoot neutral. The film look comes back from the render.

## Why it exists

[mood.camera](https://mood.camera) is the reference point. Its idea is that you
pick a stock and **don't** preview it: you shoot, and the film comes back to you
later. That is a deliberate reproduction of shooting film, where you don't know
what you got until the roll is developed.

Nitrate takes the same position, for video. The monitor shows you a neutral
image, not the look. You choose the stock and the gauge, shoot, and see the
emulation when the render finishes. Debug builds add a single-frame render of
the current settings for checking the look before a shoot; shipping builds give
you no preview of it at all.

Three commitments follow from that:

- **Camera first, not an editing app.** Everything that decides the image —
  stock, gauge, exposure, white balance — is set before or during capture. There
  is no timeline, no clip browser, no grade page. Simple editing (trim,
  re-render, rearrange) is planned and deliberately not built yet. The render
  queue and the saved original Log exist so it can be added without
  re-architecting capture.
- **The original is never destroyed.** The camera writes a real Apple Log 2
  recording. The film look is a render of that file, and the Log original can be
  kept alongside the render. Nothing is baked in at capture time.
- **Real film behaviour, not a colour wash.** Halation, glow and grain are
  modelled as physical effects with per-stock geometry. Grain comes from a
  coherent multi-scale field; halation is highlight light scattering at a
  per-stock radius. Neither is a texture laid over a look-up table.

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

Apple Log 2 is the reason this is an iPhone app. It is a real log curve in a wide
gamut, shipped by Apple as a capture colour space rather than reverse-engineered,
and it is supported downstream: Final Cut applies Apple's own Log 2 LUT, and
OpenColorIO implements the transfer function that this project's LUT generator is
built on.

That matters because the emulation needs an honest starting point. A film model
of a negative and a print can only be applied to an ungraded signal; against a
look already baked into the camera it would be guesswork on top of a guess.

### Supported iPhones

| | |
|---|---|
| OS | **iOS 27 or later.** The camera's Apple Log 2 HEVC writer requires iOS 27; the install target matches that requirement |
| Aperture | **iOS 27 or later.** The variable-aperture API the app uses is not available before that, and the app reports aperture as unavailable |
| Hardware | Any device whose camera advertises an **Apple Log 2** capture format. Apple Log 2 arrived with the iPhone 17 Pro; the reference device here is an iPhone 18 Pro |
| Anything else | No Apple Log 2 format means no recording. The app fails with an explicit unsupported error instead of falling back to a baked-in look |

The app never tests for model names. It asks the hardware which formats it
declares and requires one that is 4K Apple Log 2 with a 24 fps rate among them,
so a later Pro iPhone works without a code change.

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
| Format | Apple Log 2, 10-bit HEVC Main10 (`hvc1`), 3840×2160 or 2160×3840 |
| Requirement | Apple Log 2 capture — see [Platform](#platform) for the specific iOS versions and iPhones |
| Lenses | Ultrawide, Normal (1×), Tele, Front — the device's real lenses, with the active focal length shown |
| Aperture | Per-lens, over the stops the device reports (f/1.5–f/4.0 on the reference iPhone 18 Pro) |
| Exposure | 180° shutter priority by default (shutter locked to 1/48 s, ISO meters), plus manual EV and manual ISO |
| White balance | Locked per stock — 5600 K daylight, 3200 K tungsten — so the LUT always sees the same white point |
| Stabilization | Recording-only: Off, Standard, Cinematic, Extreme (Apple extended cinematic). The preview stays independent, and the UI calls out the crop and latency |

The capture path is strict on purpose. It negotiates a ten-bit bi-planar format
the device actually advertises, and validates every sample buffer — dimensions,
pixel format, plane count, Log transfer function, colour matrix — before the
buffer reaches the writer. It fails loudly rather than writing a silently wrong
clip, and re-checks settings against the hardware instead of assuming them.

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
  with playback, sharing, retry and error detail.
- **Frame mode** fits the preview into a bounded viewfinder between the top and
  bottom control bars, with black around it, instead of leaving a thin border
  over full-screen video. Focus taps, metering coordinates and pinch zoom stay
  relative to the real preview bounds.

### Preview colour

`Settings → Preview Color` decides what the monitor shows.

| Mode | Monitor shows |
|---|---|
| **Neutral** (default) | Apple Log 2 converted to a normal-looking Rec.709 image — the framing and exposure view |
| **Stock LUT** | The selected stock's look, colour only |
| **Log** | The ungraded Apple Log 2 signal |

All three read the Log 2 signal directly, in one cached GPU look-up pass. They
are alternatives, never stacked, and the preview never runs grain, halation or
glow. Recording stays Apple Log 2 whatever the preview is doing.

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

Stocks are labelled the way the emulsion is printed on the canister: common
name, then emulsion number. The LUT file carries the emulsion number alone,
because a slash cannot go in a filename. The print stage is a fixed Kodak
Vision 2383 for both, so it is not part of the name; it is recorded in the
provenance below.

**Print gauge** is a separate axis from stock: 8mm, 16mm, 35mm, 75mm. The gauge
owns grain, both its size and its presence, and is chosen per stock. 35mm is the
neutral reference; 75mm is near grain-free.

### Render pipeline

Rendering is offline, per queued clip, through the same chain as the debug
single-frame renderer:

```
decoded frame → pass 1: LUT + output contrast
              → spatial: halation + glow
              → pass 2: grain
              → HEVC Main10 encode → Photos
```

- **Halation** builds a highlight mask once at half resolution, blurs it
  separably, then composites it back with a ring/tail balance and a red-dominant
  tint. Radius and tint are **per stock**, set from emulsion thickness and stock
  speed.
- **Glow** is a wide, low-frequency amber bloom from the same half-resolution
  mask. At that frequency half resolution looks the same and cuts bandwidth
  roughly 4× at 4K.
- **Grain** is [described below](#how-the-grain-works).

Every render writes a diagnostics manifest into the movie metadata: the recipe
(LUT, halation, glow and grain algorithm revisions and their parameters), a
per-resource SHA-256 including the LUT used, the source colour provenance, and
the stock's D/T light tag.

### Queue, export and delivery

- Serial render queue with durable state. A job survives backgrounding and
  crashes, and an interrupted job resumes rather than restarting.
- **Export settings** (`Settings → Export`): optionally save the ungraded
  original Log recording to Photos alongside the render, and choose **High**
  (60 Mbps) or **Smaller** (30 Mbps) rendered file size. Each queued job
  snapshots the preferences it was created with, so changing a setting never
  rewrites work already queued. Resolution, frame rate and the capture format
  are never affected.
- Delivery order is deliberate. The rendered movie is saved first and the
  original second, each confirmed outcome is persisted before the next attempt,
  and a partial failure retries only what is missing — an original-only retry
  never re-renders or duplicates the render.

### Settings and purchase

A seven-day evaluation of the render, then a StoreKit-managed yearly
subscription or a lifetime unlock (`com.nitrate.subscription.yearly`,
`com.nitrate.lifetime`). Prices come from StoreKit.

Recording is never gated: after the evaluation ends you can keep shooting Apple
Log, and the takes queue until the render is unlocked. This is an in-app
evaluation, not an Apple-managed introductory offer — do not describe it as a
free trial in store copy.

## How the film LUTs are made

Both shipped look-up tables are generated by this project. The full record —
sources, parameters, measurements, hashes — is in
[`docs/lut-provenance.md`](docs/lut-provenance.md).

The camera records Apple Log 2 in Apple Wide Gamut, and the table is baked over
that exact domain:

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
stock supplies size; the gauge multiplies both — 8mm ×4.0 size / ×0.50 presence,
16mm ×3.0 / ×0.40, 35mm ×1.8 / ×0.30, 75mm ×1.0 / ×0.15. **ISO does not scale
grain**; it is the exposure index only. The effective footprint is floored at
0.95, because below that the 128³ volume is undersampled and finer size yields
aliased noise rather than finer grain. 75mm's near-grain-free look comes from its
amplitude multiplier, not from pushing size into that regime.

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
target and scheme are named `Nitrate`, and the bundle identifier is
`com.nitrate.app`, matching the App Store Connect record.

One identifier still carries the older `com.filmemulation` namespace on purpose:
the `com.filmemulation.*` movie metadata keys. They are written into recorded and
rendered files, so renaming them changes the file contract rather than a label.

The iOS app target and the macOS `RenderCLI`/`RenderCLITests` targets share the
processing pipeline and film-stock sources, so the renderer is testable at 4K on
a Mac without a device.

```sh
python3 scripts/verify.py lint     # SwiftLint, fast feedback
python3 scripts/verify.py check    # incremental unsigned generic iOS build
python3 scripts/verify.py verify   # lint + RenderCLI tests + iOS build + diff check
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

- Bump `MARKETING_VERSION` for a user-visible release (currently `0.1.0`).
- Bump `CURRENT_PROJECT_VERSION` for every build.
- Pre-release builds show the stage suffix: `0.1.0 (1) · ALPHA`. Pass `stage: nil`
  to `AppVersion.current()` for a shipping build.

## Status and known limits

- **Not yet built:** any editing surface. Trim, re-render and rearrange is the
  next planned area. The hardware capture button on supported iPhones, flash
  control, and realistic gate jitter and weave are also open.
- **Recording timing:** delayed-stabilization startup and stop-boundary defects
  are fixed. All eight preview/stabilization combinations passed the unchanged
  0.12-second device checks. See [the investigation](docs/recording-av-timing.md)
  for the measurements and remaining validation limits.
- **Unverified aesthetic:** the home-built 5207 and 5219 tables pass structural,
  smoothness and GPU-sampling checks, but nobody but the author has judged how
  they look on real footage.
- **No performance or power benchmark** has been run on the preview path.
