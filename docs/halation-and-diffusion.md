# Halation, diffusion, and how a file is measured

Three things decide what a highlight does: the **knees** decide which light
bleeds, the **reference** decides how much strength a given excess buys, and the
**stock** decides how much of that strength to apply. Diffusion is separate: the
**gauge** owns its radius, because radius is physical.

Everything below is scene-linear and pre-LUT.

## The five numbers, and who owns each

| number | owner | file | what it does |
|---|---|---|---|
| `redKnee` / `greenKnee` / `blueKnee` | engine | `SpatialEffectsStage` | light below these does not bleed; red first, then green, then blue |
| `referenceSuperwhite` | engine | `SpatialEffectsStage` | superwhite that reaches **full** contribution for video |
| `stillAnchorShare` / `stillAnchorFloorWhite` | engine | `SpatialEffectsStage` | where a **still** reaches full contribution |
| `halationStrength` | stock | `Resources/stocks.json` | how strong the effect is at full contribution |
| `halationRadiusFraction` | stock | `Resources/stocks.json` | how far the halo spreads (fraction of half-width) |
| `halationTint` | stock | `Resources/stocks.json` | per-layer weighting; red strongest |
| `stillHalationScale` | stock | `Resources/stocks.json` | share of strength a held frame uses |
| `diffusionPreset` / `diffusionAmount` | gauge | `Resources/gauges.json` | radius (px @ 1080p wide) and mix |
| `stillDiffusionScale` | stock | `Resources/stocks.json` | share of the diffusion mix a still uses |

## Video vs still: the one thing that differs

A take is locked to its shutter. A raw photo clips at its own white.

```
video : reference = referenceSuperwhite × 2^lift            (8x, authored for Apple Log 2)
still : reference = clamp(headroom × stillAnchorShare,  floor,  authored)
                    where headroom = p99.99 of the configured decode, peak channel
```

`lift` is the decode's own lift (`BaselineExposure` + the still base exposure), and
**both** the knees and the reference scale by it, so a lifted still is measured
against the same scene it came from.

Why the split: across 35 DSLR raws (29 Nikon D700 NEF, 6 Sony NEX-6 ARW) the
brightest 0.01 % of pixels sat at 0.5–3.7× white while the reference was 8× — so
halation ran at 7–48 % of its range and read faint. A fused ProRAW carries more
(4.7× at p99.99, 12× at max); Apple Log 2 is designed for ~12×.

`RenderCLI --raw-headroom <files|dirs>` prints exactly these numbers per file.

## Push/pull is a scene-light change, not a grade

Both takes and stills apply the exposure in `spatial_expose`, in front of the
emulsion, so halation and diffusion are measured against the light the film
receives. `runLUTPass` only grades: its exposure buffers stay bound and pinned to
neutral, so a stale kernel signature cannot apply a second gain.

The curve HOLDS truly clipped highlights instead of dragging them down with the
flat gain. For negative stops, `spatial_hold_weight` fades the gain to none at the source's clip
ceiling, so a highlight with no scene detail left to recover stays white and
keeps halating at full intensity, while everything below it still exposes. A
debug-sheet frame measures its own ceiling, so the preview shows the curve the
render will apply.

Positive stops use a monotone bounded rational shoulder below the ceiling:
`linear * gain / (1 + (gain - 1) * linear / ceiling)`. At/above the ceiling they
are identity; an invalid ceiling falls back to flat gain. Unlike a pull below
its hold region, a positive push does not preserve full flat midtone gain: it
approaches that gain near black. The signed-black direction clamp is retained.

Disabling halation and diffusion does not disable exposure. `applyHalation`
returns the source unchanged only when both spatial effects are off and
`exposureStops` is zero.

The ceiling is MEASURED, because "truly clipped" is a property of the scene, not
of the encoding:

- **Still**: the file's own headroom (p99.99 of the peak channel).
- **Take**: eight frames sampled across the render range, every pixel's peak
  channel, p99.99 pooled (`PushPullTransfer.measuredHighlightCeiling`), floored at
  diffuse white so an underlit take still gets a plain pull.
- Apple Log 2's ~12× is only the fallback, for a source that cannot be sampled.

Measured ceilings run far below 12× in practice — a hazy sky tops out near 3×
white — and anchoring the hold at 12× there let a −3 stop pull take that sky down
to an eighth of its light, into the stock's cast instead of film's white.

## Diffusion

The gauge owns the radius because a diffuser is a physical filter: radius comes
from `DiffusionPhysics` (20 µm scatter × negative width × `filterGain`), and the
per-gauge amounts are taste.

```
8mm   radius35  0.50
16mm  radius16  0.30
35mm  radius4   0.20
75mm  bypass    -
```

The ladder (multi-scale) is bounded by `DiffusionPlan.minLevelKernelSigma`: a
level whose kernel is narrower than one of its own texels is a nearest filter, and
bilinear upsampling of that is the flat-topped disc a highlight used to get. Small
radii therefore run one direct separable pass.

## Changing something

- Halo too strong/weak on **everything**: `halationStrength` in `stocks.json`.
- Halo too strong/weak on **DSLR stills only**: `stillAnchorShare` (halves the
  anchor to double the effect), then `stillAnchorFloorWhite` if the share is not
  biting.
- Halo on stills vs video: `stillHalationScale`.
- Softness: `diffusionAmount` per gauge in `gauges.json`.
- Radius: `filterGain` in `DiffusionPhysics` — not the gauges.

## What holds these in tests

- `HalationReferenceTests` — the reference rule: video constant, still anchored,
  floor, cap, non-finite fallback.
- `SpatialEffectsTests.aPullDarkensTheHaloWithTheFrame` — the video pull lands
  before the emulsion and the halo follows it.
- `DiffusionHighlightProfileTests` — a highlight scatters smoothly, no plateau.
- `everyLadderLevelIsAWideEnoughKernel` — no ladder level is a nearest filter.
