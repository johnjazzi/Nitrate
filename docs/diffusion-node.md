# Lens diffusion node

A diffusion ("mist") filter scatters a fraction of the light on its way through
the glass, so the frame reads softer and highlights carry a halo. The node is
`SpatialEffectsStage.applyHalation(..., diffusion:)` and it runs in
**scene-linear light before the stock LUT**, in front of the emulsion — the same
domain as halation, and physically before it.

## Order

```
diffusion (scene-linear) → halation (scene-linear) → LUT + contrast → glow → grain
```

The diffusion blend happens first inside `spatial_halation_apply`, then the
per-layer halation energy is added, then the frame is re-encoded to Apple Log 2
**once**. Both effects share the prepare pass (`spatial_scene_prepare` writes the
halation mask and the linear scene from one decode), so enabling diffusion costs
the blur passes and nothing else.

## Radius ladder

Radii are authored in pixels at a **1080p-wide frame** and scale with the real
frame, so a preset keeps its size relative to the picture. `sigma = radius / 2`.

| Preset     | Radius @1080p | Gauge that owns it | Behaviour |
|------------|---------------|--------------------|-----------|
| `radius8`  | 8 px          | 8mm                | rendered  |
| `radius16` | 16 px         | 16mm               | rendered  |
| `radius35` | 35 px         | 35mm               | rendered  |
| `radius75` | 75 px         | 75mm               | **bypassed** |

`radius75` is registered so the ladder can be compared end to end, but it
renders nothing: the node returns its input texture untouched, allocating no
scratch. `off` and an amount of 0 are likewise exact pass-throughs.

## Ownership

Diffusion is a property of the **print format**, not of the emulsion, so the
print gauge owns it — exactly like grain size and presence:

- `PrintGauge.diffusionPreset` is the radius the format implies;
- `gauges.json` authors that gauge's `diffusionAmount` (validated: the preset
  must match its gauge, the amount must be in `0...1`);
- `FilmStockConfig.effectiveDiffusion` uses a stock-authored `diffusion` object
  when present, otherwise the gauge's;
- the DEBUG sheet re-seeds its diffusion dials when the gauge changes.

The shipped amounts are **0 for every gauge**, so the node ships wired but
silent: no delivered render changes until an amount is authored in
`gauges.json` (both `Resources/` and `App/Resources/` copies) or dialled in the
debug sheet.

## Why a pyramid instead of a wide kernel

A direct separable Gaussian at sigma 8.75 (the 35 preset at 1080p) needs ~27
taps per axis per pass, and the tap count grows with resolution. Instead
`DiffusionPlan` builds a **Gaussian mixture over a pyramid**:

- level `k` is the scene downsampled `k` octaves and blurred with one small
  separable kernel — the same kernel at every level, because the plan divides
  the target sigma by the ladder depth;
- the level weights carry the mixture's variance, so the aggregate response is
  the requested wide Gaussian rather than a sum of unrelated blurs;
- the ladder depth (1–4) is chosen per frame by a per-pixel cost model, so more
  reach at 4K is bought with an extra octave, not with more taps.

Per level the cost is `2 × taps` fetches weighted by that level's area, plus one
downsample: the 35 preset at 1080p resolves to 3 levels at 9 taps per axis,
which is roughly the cost of a small blur at full working resolution.

## Verification

`Tests/DiffusionTests.swift` pins, with real GPU output:

- the realized radius tracks the authored preset (8/16/35) at 1080p;
- 4K does not scale the tap count, it deepens the ladder, and the 1080p-relative
  radius is preserved;
- scatter is **neutral** outside a white block (halation is red-dominant — the
  two must not be confused);
- local contrast falls, and the block core is pulled toward the surround without
  being flattened into it;
- a uniform field survives the ladder exactly (catches a mis-normalized kernel);
- wider presets reach further, and the response falls monotonically away from
  the source (catches blocky pyramid seams);
- `off`, `radius75` and amount 0 hand back the input texture object itself;
- diffusion composes with halation instead of replacing it;
- every gauge owns its radius, the shipped document is identical in both copies,
  and every shipped amount is 0.

## Tuning it

DEBUG → single frame → **Diffusion**: pick a radius preset, drag the amount, and
read the resolved radius, sigma, level count and taps per axis for that frame.
The sheet's render time covers the whole pipeline; per-pass GPU timing would
need a device benchmark like `HalationDeviceBenchmark`.
