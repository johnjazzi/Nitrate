# Stock-preview plates

One Apple Log 2 plate per scene, shipped **ungraded** so the app applies the selected
stock's LUT — and, next, grain, halation and glow — at display time. A user-supplied cube, a
grade tweak or a gauge change therefore needs no new asset.

> **Honest labelling.** A plate is the author's own photograph pushed through the inverse of
> the **licensed official** Apple Log 2 → Rec. 709 transform. It is an Apple Log 2 *encoded*
> image, but **not a camera original** and **not a calibration**: no iPhone recorded these
> scenes, and Apple's "Apple Gamut" primaries are not published, so the encoding is an
> approximation verified against real camera frames rather than derived from a spec.

## Files

```
App/Resources/StockSamples/
  neon-log.jpg  forest-log.jpg  harvest-log.jpg  fireworks-log.jpg
  nightride-log.jpg  race-log.jpg  shoreline-log.jpg  flyover-log.jpg
  manifest.json
```

480×720 (2:3), JPEG q66. The whole set is ~300 KB, and the suite fails if it exceeds 400 KB.
The source RAWs are **not** committed (~11 MB each).

## Pipeline

```
Nikon NEF (author-supplied, see manifest `source`)
  └─ LibRaw developer render — camera matrix, its tone curve, as-shot white balance
  └─ centre 2:3 crop, Lanczos to 480x720
  └─ approximate inverse of the official neutral Apple Log 2 -> Rec. 709 LUT
       (KD-tree kNN in the cube's output space + bounded damped-Newton refinement
        against the cube's own trilinear model)          ->  <scene>-log.jpg
```

At runtime:

```
plate (Apple Log 2 codes) -> selected stock .cube, red-fastest trilinear -> Rec. 709
```

`platePreviewFragment` in `Resources/Shaders/camera-preview.metal` performs the lookup with
the same convention as `cameraPreviewFragment`, so a plate and a live frame grade identically.

## Why the inverse, and how far to trust it

A plate has to be a Log image, and the only licensed, exact description of Apple Log 2 we
hold is the neutral cube. Inverting it beats guessing a gamut: measured on a **real Apple
Log 2 frame** from the app's own camera, inverting the neutral transform recovers the
camera's own codes to a **median and p95 error of 0.00** (10-bit code units; mean 0.74, from a
few unstable pixels), and a stock LUT applied to the recovered codes matches the same LUT
applied to the true codes to **0.15/255 mean**.

Per-scene round-trip error is recorded as `plateStats.roundTripMeanAbsError8bit` (0.01–0.57
on this set) and bounded by the suite.

A forward encode (RAW → Apple Log 2 directly) was attempted and abandoned: it needs the
unpublished primaries, and a primaries fit against the neutral cube did not discriminate
between candidates (residual ~39 code units) because the cube also carries Apple's tone curve.
A fit against a real frame is impossible without the same scene shot both ways.

## What these plates are not

- Not a per-stock white balance. The camera still locks white balance per stock when
  recording; a plate is one lighting condition, and the selector shows the roll's colour under
  it. Baking a cast per stock was tried and removed — it flattened bright scenes.
- Not grain, halation, glow or gauge. Those come from the app's own shaders, which is what
  makes "show the grain level" possible later.
- Not full-screen quality: 8-bit Log is ample for a card but will band if the preview is ever
  shown large. 16-bit plates are the upgrade path.

## Regenerating

```sh
# numpy, Pillow, rawpy, exifread (rawpy ships LibRaw; 0.22 handles current Nikon bodies)
python3 scripts/generate_stock_previews.py --sources ~/Downloads
python3 Tests/test_stock_previews.py     # contracts: manifest, quality, cube maths, inverse
```

The manifest records, per scene: the source RAW with its SHA-256 and capture metadata, the
crop and output recipe, the LUT hashes, and the plate's own checksum and statistics.
