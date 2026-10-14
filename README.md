# Nitrate (iOS)

A film-emulation **camera** for iPhone. It records Apple Log 2 in 10-bit HEVC
Main10 at 4K, renders a film-stock look over it, and delivers the result to
Photos through a render queue. The look is chosen and judged on the device, at
shooting time, rather than in post.

## Why it exists

The reference point is apps like [mood.camera](https://mood.camera) — a camera
whose whole point is the look, with the interface built around picking and
seeing it. That idea, for **video**, is what this project wanted and could not
wait for. So it is built here: the film emulation is the product, not a filter
applied afterwards.

Three commitments follow from that:

- **Camera first, not an editing app.** Everything that decides the image —
  stock, gauge, exposure, white balance, halation, grain — happens before or
  during capture. There is no timeline, no clip browser, no grade page. Simple
  editing (trim, re-render, rearrange) is planned and deliberately not built
  yet; the render queue and the saved original Log exist so that it becomes
  possible without re-architecting capture.
- **The original is never destroyed.** The camera writes a real Apple Log 2
  recording; the film look is a render of that file, and the Log original can be
  kept alongside the render. Nothing is baked in at capture time.
- **Real film behaviour, not a colour wash.** Halation, glow and grain are
  modelled as physical effects with per-stock geometry — grain from a coherent
  multi-scale field, halation as highlight light scattering at a per-stock
  radius — rather than as a single look-up table with a texture over the top.

## Feature breakdown

### Capture

| | |
|---|---|
| Format | Apple Log 2, 10-bit HEVC Main10 (`hvc1`), 3840×2160 or 2160×3840 |
| Requirement | Apple Log 2 capture (iOS 26 and later, supported hardware) |
| Lenses | Ultrawide, Normal (1×), Tele, Front — actual device lenses, with the active focal length shown |
| Aperture | Per-lens aperture over the stops the device reports (f/1.5–f/4.0 on the reference iPhone 18 Pro) |
| Exposure | 180° shutter priority by default (shutter locked to 1/48 s, ISO meters), plus manual EV and manual ISO |
| White balance | Locked per stock — 5600 K daylight, 3200 K tungsten — so the LUT sees a consistent white point |
| Stabilization | Recording-only: Off, Standard, Cinematic, Extreme (Apple extended cinematic). Preview stays independent; crop and latency are called out in the UI |

The capture path is strict on purpose. It negotiates a ten-bit bi-planar format
the device actually advertises, validates every sample buffer (dimensions, pixel
format, plane count, Log transfer function, colour matrix) before it reaches the
writer, and fails loudly rather than writing a silently wrong clip. Settings are
re-validated against the hardware rather than assumed.

### Camera interface

- Portrait-locked layout with a fixed control geography. The whole control faces
  rotate to follow the physical device orientation while their positions stay
  put, so muscle memory survives rotation.
- Exposure controls use densely ticked rulers with visible detent snapping and
  selection haptics — EV at tenth-stop spacing, manual ISO at third-stop spacing.
- Auto exposure shows where it is metering, and an under/over indicator sits
  beside the exposure readout so a manual ISO change can be matched to it.
- Lens selection is a compact single button at the top right that pops a custom
  popout of raised keys inset in a well.
- A combined **Storage & Queue** sheet opens from one tap on the status LCD:
  free/used/total space and a time estimate first, queue activity and history
  below, with playback, sharing, retry and error detail.
- **Frame mode** fits the preview to a bounded viewfinder between the top and
  bottom control bars, with black around it, instead of a thin border over
  full-screen video. Focus taps, metering coordinates and pinch zoom stay
  relative to the real preview bounds.

### Preview colour

`Settings → Preview Color` selects what the monitor shows:

| Mode | Monitor shows |
|---|---|
| **Neutral** (default) | Apple Log 2 converted to a normal-looking Rec.709 image — the framing and exposure view |
| **Stock LUT** | The selected stock's look, colour only |
| **Log** | The ungraded Apple Log 2 signal |

All three consume the Log 2 signal directly, in one cached GPU look-up pass.
They are alternatives, never stacked, and the preview never runs grain, halation
or glow. Recording always stays Apple Log 2 regardless of the preview mode.

The preview is a separate, independently gated and unstabilized capture output,
so the native camera layer — which the focus and metering geometry depends on —
stays correct while recording stabilization is active. If a preview LUT or its
source is unavailable the monitor falls back to Log and says so, rather than
showing a wrong image.

### Film stocks

| Stock | Type | LUT |
|---|---|---|
| 250D K2383 | Daylight | `250D K2383 - Apple Log 2.cube` |
| 500T K2383 | Tungsten | `500T K2383 - Apple Log 2.cube` |

**Print gauge** is a separate axis from stock: 8mm, 16mm, 35mm, 75mm. The gauge
owns grain — both size (footprint) and presence (amplitude) — and is chosen per
stock. 35mm is the neutral reference; 75mm is near grain-free.

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
  separably, and composites it back with a ring/tail balance and a red-dominant
  tint. Radius and tint are **per stock** (emulsion thickness and stock speed),
  supplied by the stock's configuration.
- **Glow** is a wide, low-frequency amber bloom from the same half-resolution
  mask. Half-resolution work is visually equivalent for effects this
  low-frequency and cuts bandwidth roughly 4× at 4K.
- **Grain** is described [below](#how-the-grain-works).

Every render writes a diagnostics manifest into the movie metadata: the recipe
(LUT, halation, glow and grain algorithm revisions and their parameters), a
per-resource SHA-256 including the LUT that was used, the source colour
provenance, and the stock's D/T light tag.

### Queue, export and delivery

- Serial render queue with durable state: a job survives app backgrounding and
  crashes, and an interrupted job resumes rather than restarting.
- **Export settings** (`Settings → Export`): optionally save the ungraded
  original Log recording to Photos alongside the render; choose **High**
  (60 Mbps) or **Smaller** (30 Mbps) rendered file size. Preferences are
  snapshotted per queued job, so changing a setting never rewrites work already
  queued. Resolution, frame rate and the capture format are never affected.
- Delivery order is deliberate: the rendered movie is saved first and the
  original second, each confirmed outcome is persisted before the next attempt,
  and a partial failure retries only what is missing — an original-only retry
  never re-renders or duplicates the render.

### Settings and purchase

Seven-day trial, then a StoreKit-managed yearly subscription or a lifetime
unlock (`com.filmemulation.subscription.yearly`, `com.filmemulation.lifetime`).
Prices come from StoreKit.

## How the film LUTs are made

The two shipped look-up tables are generated by this project. The full record —
sources, parameters, measurements and hashes — is in
[`docs/lut-provenance.md`](docs/lut-provenance.md); this is the short version.

**The chain.** The camera records Apple Log 2 in Apple Wide Gamut. The table is
baked over that exact domain:

```
Apple Log 2 code value          the cube's input axis: 33³, red fastest
  → decode to linear            Apple Log transfer function
  → Apple Wide Gamut → XYZ      primaries from Apple's published profile
  → confine to the spectral locus
  → film model                  negative → print → projection
  → Rec. 709, gamma 2.4         the cube's output, matching the display tag
```

**What is open source, and where.** Nothing here re-bakes a purchased or
third-party LUT, and none of the previously shipped externally-produced tables
are distributed any more.

| Component | Source | Licence |
|---|---|---|
| Film model (negative → print → projection) | [Spectral Film LUT](https://github.com/JanLohse/spectral_film_lut) by Jan Lohse, pinned commit `6307a98` | MIT |
| Apple Log transfer function, Apple Wide Gamut primaries | [OpenColorIO](https://github.com/AcademySoftwareFoundation/OpenColorIO) v2.6.0, `AppleCameras.cpp` | BSD-3-Clause |
| Colour science and spectral handling | [colour-science](https://www.colour-science.org/) | BSD-3-Clause |
| Film data | Kodak Vision3 250D 5207 (2009), Vision3 500T 5219 (2007), Vision 2383/3383 print (1998), digitised from manufacturer datasheets by the generator project | — |

Two calibration decisions are worth stating plainly, because both are deliberate
departures from the obvious reading of the source data:

1. **The illuminant is the neutral reference, not the stock's own balance.** The
   model takes scene white balance as a parameter, and the stocks declare 3200 K
   (5219) and 5500 K (5207). Those declarations are metadata — the pipeline
   never reads them. Our recording is already white-balanced by the camera, so
   calibrating for the stock's own temperature tilted the film's sensitivity and
   produced a large cast on neutral tones. The tables are baked at the neutral
   reference instead, which is also the generator's documented default.
2. **The input is confined to the physical colour region.** Apple Wide Gamut's
   blue primary is imaginary (y = −0.076), so 49% of the cube's knots decode to
   colours outside the CIE 1931 spectral locus. The generator reconstructs a
   spectrum from chromaticity, which is only meaningful inside the locus; there,
   neighbouring knots jumped 0.83 apart in output and saturated blues developed
   near-black holes beside bright knots. Chromaticities outside the locus are
   pulled onto it along the white-point ray at constant luminance (57% of knots),
   leaving in-locus colours bit-identical.

**Rebuilding them.** The generator is checked in at
[`tools/lut-generation/`](tools/lut-generation/), with pinned dependencies and
the upstream commit it was run against. Its README has the commands, and the
hashes a regeneration must reproduce byte-for-byte.

**What this is not.** These are generated approximations of a film look. They
are not Kodak products, not Kodak-authorised, and not a colorimetric calibration
of any camera or display. "250D", "500T" and "2383" identify the emulated stocks
descriptively. The film data itself is limited by published datasheet precision,
and interlayer effects in the model are simplified.

## How the grain works

Grain is `pass2_grain`, a Metal kernel driven by a shipped 128³ noise volume
(`grain3d.raw`). The algorithm revision is recorded per render as
`coherent-multiscale-edge-amplitude-v3`.

**Coherent multi-scale field.** Two fields are sampled from the same volume at
incommensurate scales and combined — a fine field (weight 0.74) and a clump
field at the golden-ratio conjugate scale 0.381966011 (weight 0.26). The clump
term is what makes grain read as clusters of developed silver rather than
uniform per-pixel noise. A third field at scale φ (1.618033989) drives restrained
per-channel chroma variation through the vector (−0.12, 0.015, 0.12), so red and
blue deviate in opposite directions while green stays near the luminance grain.

**Temporal behaviour.** Each frame samples the volume's centre plane for its
z-slice (`(frame mod 128 + 0.5) / 128`) and applies irrational per-frame
in-plane offsets derived from a low-discrepancy sequence
(`phase = frame × 0.754877666`). The field moves every frame the way film grain
does, without pattern repetition, while avoiding the global grain "pumping" that
trilinear blending between volume planes causes as the phase drifts across
slices. A slowly varying vector displacement, sampled from the volume itself at
0.035× scale and applied at 0.22 amplitude, breaks the volume's 128-texel repeat
without introducing pixel-wise UV jumps.

**Detail prefilter.** A normalised 5-tap cross (0.5 centre, 0.125 on each
orthogonal neighbour) softens detail finer than the grain footprint before the
noise is added. All weights are positive, so constant regions are preserved
exactly and the filter cannot produce halos.

**Latitude window.** Grain is not applied uniformly. A luminance window
(`smoothstep(0.015, 0.13, luma) × (1 − smoothstep(0.78, 0.98, luma))`) fades it
out of near-black shadows and out of highlights, peaking in the mid-tones — the
way a real negative's grain structure reads in the print.

**Print gauge owns grain.** Presence is `baseAmount × gaugeAmplitude`. The stock
supplies size; the gauge multiplies both — 8mm ×4.0 size / ×0.50 presence, 16mm
×3.0 / ×0.40, 35mm ×1.8 / ×0.30, 75mm ×1.0 / ×0.15. **ISO does not scale grain**
— it is the exposure index only. The effective footprint is floored at 0.95
because below that the 128³ volume is undersampled: finer size yields aliased
noise, not finer grain. 75mm's near-grain-free look is delivered by its
amplitude multiplier, not by pushing size into that regime.

**Edge amplification.** This is what makes grain follow image structure instead
of sitting on top of it:

```metal
edgeMagnitude = length(float2(lumaRight - lumaLeft,    // central difference in x
                              lumaDown  - lumaUp));    // central difference in y
edgeFactor    = 1.0 + saturate(edgeMagnitude * 3.0) * edgeBoostMultiplier;
amount        = 0.55 * gaugeAmplitude * edgeFactor;
```

The luma gradient is a central difference on the prefiltered neighbourhood, so
it measures edge *strength* rather than contrast polarity. The gain saturates at
`edgeMagnitude ≥ 1/3`, and the shipped stocks set `edgeBoostMultiplier = 3`
(clamped to a maximum of 3 by the kernel) — so grain is up to **4× louder across
strong edges** than in flat areas, and 1× in smooth regions. Grain therefore
resolves on texture, edges and fine detail while staying quiet in skies and
shadow, which is both how film grain reads perceptually and what stops the
effect looking like a uniform overlay.

**Headroom budget.** Before applying symmetric noise the kernel computes the
worst-case excursion (`latitude × 0.23 × (amount × 1.12 + 0.004)`, from the
volume's measured [0.385, 0.615] range) and scales the per-channel excursion
down so positive grain can never push a pixel into 8-bit black. Grain cannot
crush blacks or clip highlights by construction.

## Repository

XcodeGen is the source of truth: `project.yml` defines the project, targets and
schemes, and the generated `*.xcodeproj` is gitignored. The Xcode project, app
target and scheme are named `Nitrate`; the bundle identifier
(`com.filmemulation.app`), the `com.filmemulation.*` movie metadata keys and the
StoreKit product identifiers deliberately keep the original name — they are
already shipped, and changing them would orphan existing installs, renders and
purchases.

The iOS app target and the macOS `RenderCLI`/`RenderCLITests` targets share the
processing pipeline and film-stock sources, so the renderer is testable at 4K on
a Mac without a device.

```sh
python3 scripts/verify.py lint     # SwiftLint, fast feedback
python3 scripts/verify.py check    # incremental unsigned generic iOS build
python3 scripts/verify.py verify   # lint + RenderCLI tests + iOS build + diff check
python3 scripts/verify.py device   # signed device build (run last)
```

Xcode and Metal work must run outside a sandbox. Tests cover the LUT sampling
kernel against an independent CPU reference, the full render and encode path
with real HEVC output, queue reliability and recovery, capture policies, the
exposure and grain models, and the preview policies.

## Versioning

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` are the single
source of truth. XcodeGen feeds them into the generated Info.plist, and the launch
splash renders them through `AppVersion` (`App/AppIdentity.swift`).

- Bump `MARKETING_VERSION` for a user-visible release (currently `0.1.0`).
- Bump `CURRENT_PROJECT_VERSION` for every build.
- Pre-release builds show the stage suffix: `0.1.0 (1) · ALPHA`. Pass `stage: nil`
  to `AppVersion.current()` for a shipping build.

## Status and known limits

- **Not yet built:** any editing surface. Trim, re-render and rearrange is the
  next planned area. The hardware capture button (on supported iPhones), flash
  control, and realistic gate jitter/weave are also open.
- **Open bugs:** the tracked list is `docs/camera-feedback-todo.md`. The current
  headline item is a device capture smoke that measured a 0.650 s audio/video
  end-time difference against a 0.12 s bound; it is unresolved and the bound has
  not been relaxed to hide it.
- **Unverified aesthetic:** the home-built 250D/500T tables pass structural,
  smoothness and GPU-sampling checks, but their look has not been judged on real
  footage by anyone but the author.
- **No performance or power benchmark** has been run on the preview path.
