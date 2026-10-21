# Stock-preview plates

One Apple Log 2 plate per scene, shipped **ungraded** so the app applies the selected
stock's LUT — and, next, grain, halation and glow — at display time. A user-supplied cube, a
grade tweak or a gauge change therefore needs no new asset.

> **Honest labelling.** A plate is the author's own photograph encoded with the exact Apple
> Log 2 transfer function into the published Apple Wide Gamut primaries. It is an Apple
> Log 2 *encoded* image, but **not a camera original** and **not a calibration**: no iPhone
> recorded these scenes, and the RGB↔XYZ matrix is derived from the published primaries
> rather than taken from a spec sheet.

## Files

```
App/Resources/StockSamples/
  neon-log.jpg  forest-log.jpg  harvest-log.jpg  fireworks-log.jpg
  nightride-log.jpg  race-log.jpg  shoreline-log.jpg  flyover-log.jpg
  manifest.json
```

1080×1620 (2:3, the card's native 3× shape), JPEG q76. The whole set is ~1.05 MB, and the
suite fails if a plate exceeds 384 KB or the set exceeds 1.25 MB. The source RAWs are
**not** committed (~11 MB each).

## Pipeline

```
Nikon NEF (author-supplied, see manifest `source`) with its AS-SHOT camera white balance
  └─ LibRaw scene-linear sRGB — gamma=(1,1), output_bps=16, use_camera_wb=True,
     no_auto_bright=True (automatic brightening disabled; LibRaw RAW scaling remains)
  └─ linear-light centre 2:3 crop, Lanczos to 1080x1620
  └─ Apple Wide Gamut matrix (derived from the published primaries)
  └─ exact Apple Log 2 transfer curve (quadratic toe below R_t, log segment above)
                                                          ->  <scene>-log.jpg
```

At runtime:

```
plate -> Apple Log decode -> assumed scene/stock white-balance matrix
      -> Apple Log encode -> selected stock .cube -> grain -> Rec. 709
```

`platePreviewFragment` in `Resources/Shaders/camera-preview.metal` performs the lookup with
the same convention as `cameraPreviewFragment`, so a plate and a live frame grade identically.

## The encode

Apple Log 2 uses the published **Apple Wide Gamut** primaries and the **Apple Log** transfer
curve; the two differ only in primaries (`Apple_Log_2_to_ACES2065-1` reuses
`APPLE_LOG_to_ACES`, per OpenColorIO's `opencolorio-config-aces` apple transform generator).
The published primaries and D65 white point are:

```
Apple Wide Gamut primaries (xy), D65 white (xy):
  R (0.725, 0.301)   G (0.221, 0.814)   B (0.068, -0.076)   W (0.3127, 0.3290)
```

The profile does not publish the RGB↔XYZ *matrix* or its chromatic adaptation, so this repo
derives the matrix from the primaries above — the same derivation `opencolorio-config-aces`
uses (both sets share D65, so no adaptation is applied). Scene-linear sRGB → Apple Wide Gamut:

```
  [ 0.608104  0.259353  0.132543 ]
  [ 0.062316  0.804609  0.133076 ]
  [ 0.031133  0.133756  0.835112 ]
```

This matrix is the interface the renderer/shader side must match (see `appleLog2` in the
manifest). Neutral grey maps to itself (row sums are 1), so the rotation adds no cast.

Curve constants (recorded in the manifest under `appleLog2.curve`):

```
R >= R_t :  P = gamma * log2(R + beta) + delta
R_0 <= R < R_t :  P = sigma * (R - R_0)^2      (quadratic toe)
R < R_0 :   P = 0
R_0 = -0.05641088   R_t = 0.01   sigma = 47.28711236
beta = 0.00964052   gamma = 0.08550479   delta = 0.69336945
```

18 % scene reflection encodes to **0.48827**, matching Apple's published example. The
encode/decode round trip is exact to floating-point precision (`curveRoundTrip` in the
manifest).

**Why not invert the display LUT?** An earlier revision built the plate by inverting the
neutral Apple Log 2 → Rec. 709 cube from a LibRaw developer render. That baked LibRaw's tone
curve and then undid a display transform, which is not a camera encoding, and its
pre-compression round-trip number was misleading. It survives only as a comparison path
(`scripts/generate_stock_previews.py --pipeline inverse`).

## White balance

The plate keeps the RAW's **as-shot camera white balance** (`use_camera_wb=True`); the
manifest records the D700's own multipliers under `source.nef.asShotWhiteBalance` and derives
**no** colour temperature from them. An earlier revision applied an auto white-patch
(grey-world) balance — it selected the brightest desaturated pixels of a *gamma-encoded* RGB
render as a "neutral" reference and scaled the channels to it. Gamma-encoded values are not
scene-linear and a bright non-neutral surface passes the filter, so the reference was
unreliable and could silently re-tint every plate; it was removed. The per-scene
`sceneIlluminantKelvin` is an assumption used by the runtime white-balance simulation,
not a measurement. It assumes the as-shot image has been balanced to that illuminant;
mixed lighting and a deliberately warm/cool camera setting can violate that assumption.

## What these plates are not

- Not grain, halation, glow or gauge. Those come from the app's own shaders.
- Not full-screen quality: 8-bit Log is ample for a card but will band if the preview is ever
  shown large. 16-bit plates are the upgrade path.

## Regenerating

```sh
# numpy, Pillow, rawpy, exifread (rawpy ships LibRaw; 0.22 handles current Nikon bodies)
python3 scripts/generate_stock_previews.py --sources ~/Downloads
python3 scripts/generate_stock_previews.py --sources ~/Downloads --compare   # exact vs inverse
python3 Tests/test_stock_previews.py     # contracts: manifest, quality, budgets, encode maths
```

The manifest records, per scene: the source RAW with its SHA-256 and capture metadata
(including its as-shot white balance), the crop and output recipe, the LUT hashes, and the
plate's own checksum and statistics — every statistic and error figure is measured on the
**stored JPEG**, not on the pre-compression float.
