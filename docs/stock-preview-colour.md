# Stock-preview colour path

`plate_prepare` in `Resources/Shaders/camera-preview.metal` grades a bundled Apple
Log 2 plate toward the render's white point: it decodes the plate to linear light, applies the
stock's locked white balance, and re-encodes to Apple Log 2. It runs BEFORE halation and the
stock `.cube`, so the halo scatters the light the camera's lock actually produced. The plate
then goes through the production `SpatialEffectsStage` halation, the stock `.cube` (or the
neutral monitoring cube) with the same red-fastest trilinear lookup the live capture preview
uses, and finally the gauge's grain. This note records the two transforms in the colour step
and the tests that pin them; `docs/stock-preview-effects.md` covers the effect chain.

## Apple Log 2 transfer function

The curve is Apple's published Apple Log 2 response, the same one the LUT generator
decodes with (`docs/lut-provenance.md`) and OpenColorIO 2.6 implements in
`src/OpenColorIO/transforms/builtins/AppleCameras.cpp` (constants `R0`, `Rt`, `c`, `beta`,
`gamma`, `delta`; builtin `CURVE - APPLE_LOG_to_LINEAR`).

- **Toe**: for codes below `P_t`, linear = `sqrt(code / c) + R_0` — a **square root**, so
  the two segments meet at the code `P_t = c·(Rt − R0)²`, not the `(Rt − R0)/c` a linear
  toe would use. Apple Log 2 shares Apple Log's curve and differs only in primaries.
- **Log segment**: for codes at or above `P_t`, linear = `2^((code − delta)/gamma) − beta`.
- **Encode** is the exact inverse: `c·(linear − R0)²` below `Rt`, then
  `delta + gamma·log2(linear + beta)`.

`P_t ≈ 0.20855` and `Rt = 0.01`. The shader previously used a **linear** toe and the
linear-toe threshold, which sent every plate code below ≈0.209 through the log segment and
re-encoded it near zero: an identity white balance collapsed a code of 0.2 to ≈0.0014,
crushing shadows and exaggerating whichever channel the gain favoured. The decode/encode in
the shader now matches `spatial.metal` (halation) and the generator.

## White balance

`CameraSession` locks the sensor to the selected stock's `colorTemperature` with tint 0, so
a scene lit at a different temperature records with its neutral axis displaced by the
illuminant ratio `I(scene) / I(locked)`. That ratio is a chromatic adaptation, applied as a
**full Bradford transform**, not a per-channel gain:

```
M = AppleWG→XYZ⁻¹ · Bradford(locked → scene) · AppleWG→XYZ
```

`PlateWhiteBalance.adaptation(sceneKelvin:lockedKelvin:)` builds `M`, then normalises it so
the plate's neutral keeps its luminance (the lock changes colour, not exposure). Identity
when the two temperatures agree.

The transform is conjugated into **Apple Wide Gamut** — the primaries the plates' linear
values are in (Apple Log 2 white paper; the same primaries OCIO 2.6 uses for
`APPLE_LOG-APPLEWG_to_ACES2065-1`). The previous implementation derived a diagonal gain in
linear sRGB and applied it to Apple Wide Gamut values, mixing two bases: for a 5600 K scene
on a 3200 K lock it put the neutral's red gain at ≈0.46 where the AppleWG-basis transform
gives ≈0.85, exaggerating the blue cast. This model is not a measured match to iPhone sensor gains.

## Tests

`Tests/PlatePreviewColourTests.swift` runs the shipping `plate_prepare` kernel on real Metal
textures (the kernel reads and writes 1:1, so a single row of codes isolates its own
decode/encode) and pins:

- identity white balance preserves plate codes across the toe and the log segment;
- the shader reproduces the published Apple Log 2 curve under a scalar gain;
- the two segments join without a step;
- a daylight scene on a tungsten lock reads blue and a tungsten scene on a daylight lock
  reads warm, while a matched lock does not tint;
- the adaptation is a full matrix in Apple Wide Gamut that carries the locked white onto the
  scene white, not an sRGB diagonal.

These are regression checks on the transform, **not** a colorimetric calibration of the
camera or the display, and not a claim that the plates are camera originals.
