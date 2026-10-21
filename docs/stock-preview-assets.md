# Stock-preview sample assets

Illustrative preview photographs for the stock-selector carousel, plus the tooling that
regenerates them and the tests that pin their quality.

These assets exist so the carousel can show what a stock *does to a real photograph*
without shipping a camera-original shot that does not exist.

> **Honest labelling.** These are **illustrative photos** assembled from public CC0
> photographic HDRIs. The graded variants are the **real bundled colour LUTs applied to an
> illustrative synthetic Log input** — not Apple Log 2 camera originals and **not a
> calibration**. Only the colour LUT is simulated: no grain, halation or gauge.

## Files

```
App/Resources/StockSamples/
  daylight-neutral.jpg     daylight-kodak5207.jpg     daylight-kodak5219.jpg
  city-neutral.jpg         city-kodak5207.jpg         city-kodak5219.jpg
  night-neutral.jpg        night-kodak5207.jpg        night-kodak5219.jpg
  manifest.json
```

Each `<scene>-neutral.jpg` is the neutral base photo. Each `<scene>-<stockId>.jpg` is the
*same* photo pushed through that stock's bundled `.cube`. Scene/stock ids the Swift reader
should expect: scenes `daylight`, `city`, `night`; stocks `kodak5207`, `kodak5219`.

All assets are 540×810 portrait JPEGs, total well under 1 MB.

## Pipeline

```
CC0 HDRI source (Poly Haven, actual asset)
  └─ open the Radiance .hdr (own RGBE decoder, row 0 = zenith)
  └─ rectilinear (pinhole) crop   — no equirect distortion, scene stays perspective
  └─ exposure + ACES-filmic tone-map + sRGB encode  → display-space base photo
       = <scene>-neutral.jpg
  └─ base photo ─► approximate inverse of the official neutral Apple Log 2 → Rec.709 LUT
       (KD-tree kNN in the cube's output space, then bounded damped-Newton refinement
        against the cube's own trilinear model)  → illustrative synthetic Log input
  └─ synthetic Log input ─► real stock .cube, red-fastest trilinear  → <scene>-<stockId>.jpg
```

The **only** non-real step is the middle one: there are no Apple Log 2 originals for these
scenes, so we reconstruct a plausible Log-domain input by inverting the licensed neutral
transform. We do **not** guess Apple gamut primaries — the neutral LUT already encodes the
exact Apple Log 2 / Apple Wide Gamut → Rec. 709 mapping, so we invert *it* rather than
re-implement a colour science we cannot verify.

The inverse is not a random filter and not merely "lower contrast / desaturate": it is a
deterministic numerical inversion of the actual monitoring transform, refined per pixel
until `forward(inverse(x)) ≈ x` within the error reported in the manifest. Because we have
no way to know the true Log code the camera would have recorded, the result is labelled
`illustrative synthetic Log input` everywhere it appears.

## Sources (real CC0 assets, not site renders)

| scene | Poly Haven asset | licence |
|---|---|---|
| daylight | [`yellow_field`](https://polyhaven.com/a/yellow_field) | CC0 |
| city | [`urban_street_04`](https://polyhaven.com/a/urban_street_04) | CC0 |
| night | [`cobblestone_street_night`](https://polyhaven.com/a/cobblestone_street_night) | CC0 |

Poly Haven publishes HDRI captures under CC0; the per-scene `md5`/`sha256` of the exact
4k `.hdr` downloaded are recorded in `manifest.json`. Only the actual downloadable asset is
used — never a website thumbnail or example render.

Vintage-film samples (e.g. Visual Park) are deliberately **not** used.

## Regenerating

Build-time only; the app needs no network and does not regenerate these.

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install numpy Pillow          # scipy optional (faster KD-tree); brute-force fallback exists

python scripts/generate_stock_previews.py            # uses ~/.cache/nitrate-stock-preview-sources
python scripts/generate_stock_previews.py --fetch    # download the CC0 sources first
```

The generator reads the committed LUTs (`App/Resources/Preview/AppleLog2ToRec709.cube`,
`App/Resources/LUTs/5207 - Apple Log 2.cube`, `.../5219 - Apple Log 2.cube`), reproduces the
nine JPEGs and rewrites `manifest.json`. It needs no network once sources are cached and
writes nothing outside `App/Resources/StockSamples/` and the source cache.

## Tests

```sh
python -m unittest Tests/test_stock_previews   # or: python Tests/test_stock_previews.py
```

Covers: manifest schema/coverage/checksums, image non-blankness, **blown-white and midtone
fractions**, tonal spread, palette size, scene/stock distinctness, LUT axis order on an
asymmetric cube, endpoint/centre interpolation, inverse round-trip tolerance, and rectilinear
reprojection orientation. These image-quality gates exist because an early generator revision
shipped blown-white frames that a weaker suite passed.

## Manifest schema (`manifest.json`)

```jsonc
{
  "schemaVersion": 1,
  "disclaimer": "Illustrative photos · color LUT only",
  "stocks": ["kodak5207", "kodak5219"],
  "lutSHA256":        { "kodak5207": "…", "kodak5219": "…" },
  "neutralLutSHA256": "…",
  "inverseRoundTripGlobal": {
    "validMeanAbsError8bit": 0.0, "validP95AbsError8bit": 0.0, "fullMeanAbsError8bit": 0.0,
    "note": "error over the full cube is dominated by unreachable near-black codes…"
  },
  "scenes": [
    {
      "id": "daylight", "title": "Daylight",
      "neutralFile": "daylight-neutral.jpg",
      "previews": { "kodak5207": "daylight-kodak5207.jpg", "kodak5219": "daylight-kodak5219.jpg" },
      "source": {
        "provider": "Poly Haven", "assetSlug": "yellow_field",
        "sourceURL": "https://…/yellow_field_4k.hdr",
        "license": "CC0", "licenseURL": "https://polyhaven.com/license",
        "credit": "Poly Haven — yellow_field (CC0)", "md5": "…", "sha256": "…"
      },
      "derivation": {
        "recipe": "display-space base photo -> approximate inverse of official neutral LUT …",
        "cropYawDeg": 0.0, "cropPitchDeg": 0.0, "fovDeg": 68.0, "exposureEV": -0.8,
        "outputSize": [540, 810],
        "inputLabel": "illustrative synthetic Log input (NOT Apple Log 2 camera original)"
      },
      "assets": {
        "neutral":  { "file": "daylight-neutral.jpg",  "sha256": "…", "whiteFraction": 0.0, "midtoneFraction": 0.99 },
        "kodak5207":{ "file": "daylight-kodak5207.jpg","sha256": "…", "whiteFraction": 0.0, "midtoneFraction": 0.99 },
        "kodak5219":{ "file": "daylight-kodak5219.jpg","sha256": "…", "whiteFraction": 0.0, "midtoneFraction": 0.99 }
      },
      "inverseRoundTripOnScene": { "meanAbsError8bit": 0.0, "maxAbsError8bit": 0.0 }
    }
    // city, night …
  ]
}
```

The Swift reader should read `schemaVersion`, `stocks`, and per scene `id`, `title`,
`neutralFile`, `previews` (keyed by stock id). File names are dynamic; do not hard-code them.

## Known limitations

- The synthetic Log input is a reconstruction, not camera data. Colour that is genuinely
  outside the neutral transform's reachable range (very near-black display codes) cannot be
  inverted exactly because the transform is not injective there; the residual is reported in
  `inverseRoundTripGlobal` rather than hidden. It affects only the deepest shadows.
- Tone-mapping is a filmic approximation applied to a reprojected HDRI, not a captured SDR
  frame, so absolute exposure is an artistic choice, not metered.
- Grain, halation and gauge simulation are intentionally absent — those are separate pipeline
  stages and are not part of this comparison.
