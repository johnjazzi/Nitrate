# Halation, diffusion, and how a file is measured

Three things decide what a highlight does: the **onsets** decide which light
bleeds, the **reference** decides how much strength a given excess buys, and the
**stock** decides how much of that strength to apply. Diffusion is separate: the
**gauge** owns its radius, because radius is physical.

Everything below is scene-linear and pre-LUT.

## The five numbers, and who owns each

| number | owner | file | what it does |
|---|---|---|---|
| `redOnsetStops` / `greenOnsetStops` / `blueOnsetStops` | engine | `SpatialEffectsStage` | light below these does not bleed; red first, then green, then blue |
| `halationReferenceStops` | engine | `SpatialEffectsStage` | the superwhite that reaches **full** contribution, stills and takes alike |
| `halationStrength` | stock | `Resources/stocks.json` | how strong the effect is at full contribution |
| `halationRadiusFraction` | stock | `Resources/stocks.json` | how far the halo spreads (fraction of half-width) |
| `halationTint` | stock | `Resources/stocks.json` | per-layer weighting; red strongest |
| `stillHalationScale` | stock | `Resources/stocks.json` | share of strength a held frame uses |
| `diffusionPreset` / `diffusionAmount` | gauge | `Resources/gauges.json` | radius (px @ 1080p wide) and mix |
| `stillDiffusionScale` | stock | `Resources/stocks.json` | share of the diffusion mix a still uses |

## The ramp is authored in stops; a lift moves the frame

All four numbers are stops above diffuse white:

```
redOnset    -1.415   0.375x diffuse white
greenOnset  -0.415   0.75x
blueOnset   +0.585   1.5x
reference   +3.322   10x, inside Apple Log 2's ~12x recorded range
```

The mask reads ONE frame, and `frameWhiteStops` says where that frame's own 1.0
sits relative to the delivered picture:

```
frameWhiteStops = SystemExposureScheme.captureStops + sceneLiftStops
```

A take is captured a stop under the picture it delivers, so its mask frame sits at
−1; a still's `sceneLiftStops` is the raw decode's own `BaselineExposure`, on top
of that same −1. A layer's trigger, expressed in the mask frame, is
`2^(onset + frameWhiteStops)`.

That one additive offset is the whole of the difference between the paths. A lift
moves the FRAME while the onsets stay authored, so the trigger moves by exactly the
lift and the halo lands on the same scene light however the file was exposed — a
still and a take of one scene grade alike. Nothing here is a scale, and nothing
reads the file.

A still used to be measured instead — the reference was a share of the file's own
p99.99 — on the reasoning that a single-exposure raw clips at its own white and
would never reach 10x. It does not, but the measurement made the ramp depend on
the brightest pixels of that particular file: for a fused ProRAW the anchor landed
near 0.7× white against a take's 10×, so a still began to glow well before the
video shot beside it. Whole-frame blooming orange stills were the visible form of
that. The thresholds were then scaled by the decode lift to compensate; the frame
offset replaces that scale too, so the file reaches neither the ramp's shape nor
its position. The measured headroom survives only where it belongs, as the
push/pull hold's ceiling.

What a still does differently is strength and diffusion, not threshold:
`stillHalationScale` and `stillDiffusionScale` in `Resources/stocks.json`.

`RenderCLI --raw-headroom <files|dirs>` still prints each file's measured ceiling.
That number now feeds the push/pull hold (`halationCeiling`) only.

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
8mm   radius35  0.35
16mm  radius16  0.21
35mm  radius4   0.14
75mm  bypass    -
```

The ladder (multi-scale) is bounded by `DiffusionPlan.minLevelKernelSigma`: a
level whose kernel is narrower than one of its own texels is a nearest filter, and
bilinear upsampling of that is the flat-topped disc a highlight used to get. Small
radii therefore run one direct separable pass.

## Changing something

- Halo too strong/weak on **everything**: `halationStrength` in `stocks.json`.
- Where the halo reaches full strength, stills and takes together:
  `halationReferenceStops` in `SpatialEffectsStage` (lower saturates sooner).
- Which light bleeds at all: `redOnsetStops` / `greenOnsetStops` /
  `blueOnsetStops` in `SpatialEffectsStage` (the debug sheet can move them live).
- Halo strength on **stills alone**: `stillHalationScale`.
- Softness: `diffusionAmount` per gauge in `gauges.json`.
- Radius: `filterGain` in `DiffusionPhysics` — not the gauges.

## What holds these in tests

- `HalationReferenceTests` — the reference rule: one absolute stopped point,
  reachable inside the recorded range, with no measurement able to move it.
- `SpatialEffectsTests.aPullDarkensTheHaloWithTheFrame` — the video pull lands
  before the emulsion and the halo follows it.
- `DiffusionHighlightProfileTests` — a highlight scatters smoothly, no plateau.
- `everyLadderLevelIsAWideEnoughKernel` — no ladder level is a nearest filter.
