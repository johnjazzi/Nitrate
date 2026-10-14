# Neutral Apple Log 2 monitoring LUT

`AppleLog2ToRec709.cube` is a 33³ RGB/red-fastest monitoring transform baked from
OpenColorIO 2.6.0. It is **not Apple’s official LUT**, a film-stock look, or a
colorimetric calibration of the camera/display.

## Exact color contract

- Input: normalized Apple Log 2 RGB in **Apple Wide Gamut**, not Rec.2020.
- OCIO input color space: `Apple Log 2`, alias `ocio:applelog_applewg_scene`.
- Input builtin: `APPLE_LOG-APPLEWG_to_ACES2065-1`.
- Builtin config: `studio-config-v5.0.0_aces-v2.1_ocio-v2.6`.
- Display: `Rec.1886 Rec.709 - Display` (D65, Rec.709 primaries, gamma 2.4).
- View: `ACES 2.0 - SDR 100 nits (Rec.709)`.
- No creative look, exposure offset, or white-balance correction.
- Input domain: `[0,1]` per channel. RGB triplets; red varies fastest.
- Highlight rendering/gamut mapping is the standard ACES SDR output transform,
  not an invented curve or a linear color-space conversion. “Neutral” means
  no film emulation; it does not mean “no tone mapping.”

The shared Apple Log transfer function is intentional: OCIO explicitly defines
Log 2 using the Apple Wide Gamut primaries and Log 1 using Rec.2020 primaries.
A recording’s Rec.2020 YCbCr matrix does not change the input RGB primaries.
Consumers must feed decoded, correctly range-expanded Log 2 RGB, apply this LUT
once, and respect the output gamma. The 33³ bake is an approximation between
grid points, particularly near gamut boundaries; it does not prove exact
continuous-transform equivalence or correct UIKit/Core Image display management.

## Provenance and redistribution

Primary source: Academy Software Foundation OpenColorIO, release **v2.6.0**,
commit `10a43ec1df03d072ca9a9e2fb3f26e454b0900d8`:

- https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/v2.6.0/src/OpenColorIO/transforms/builtins/AppleCameras.cpp
- https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/v2.6.0/src/OpenColorIO/builtinconfigs/configs/studio-config-v5.0.0_aces-v2.1_ocio-v2.6.ocio
- https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/v2.6.0/LICENSE
- https://github.com/AcademySoftwareFoundation/OpenColorIO-Config-ACES/blob/055066194dd5545fd44e47d2449abd717657add9/LICENSE
- Python binding: https://pypi.org/project/opencolorio/2.6.0/

Both OCIO and OCIO-Config-ACES use BSD-3-Clause, permitting redistribution with
or without modification subject to notice/disclaimer retention and no
endorsement. `LICENSE.txt` retains the complete notice, conditions and disclaimer.
Distribute it with the LUT. No Apple download/license is represented as granting
rights to this bake. The official Apple developer download search redirected to
Apple sign-in; no credentials were entered and no Apple-authored LUT was copied.

Packaged asset SHA-256:

```text
831b0e32a18ceba3d93fdf0c2816c01163a67fadd48550a3276167b3b2b1e7f2
```

## Reproduction

Use Python with `opencolorio==2.6.0` (the bake used CPython 3.14.7 on macOS).
The following algorithm fully specifies the numeric table; preserve the existing
header and nine-decimal formatting to reproduce the packaged bytes.

```python
import PyOpenColorIO as ocio
assert ocio.__version__ == '2.6.0'
config = ocio.Config.CreateFromBuiltinConfig(
    'studio-config-v5.0.0_aces-v2.1_ocio-v2.6')
transform = ocio.DisplayViewTransform(
    src='Apple Log 2', display='Rec.1886 Rec.709 - Display',
    view='ACES 2.0 - SDR 100 nits (Rec.709)')
cpu = config.getProcessor(transform).getDefaultCPUProcessor()
for b in range(33):
    for g in range(33):
        for r in range(33):
            rgb = cpu.applyRGB([r / 32, g / 32, b / 32])
            print(' '.join(f'{v:.9f}' for v in rgb))
```

Reference samples, directly evaluated by that processor:

| Log input R=G=B | Output RGB (approximately achromatic) |
|---|---|
| 0.000 | 0.000000 |
| 0.250 | 0.080587 |
| 0.375 | 0.215794 |
| 0.500 | 0.402230 |
| 0.625 | 0.612850 |
| 0.750 | 0.796408 |
| 0.875 | 0.911992 |
| 1.000 | 0.967356 |

Asymmetric input `(0.5, 0.25, 0.125)` gives
`(0.406324685, 0.138296574, 0.000000000)`; `(0.125, 0.25, 0.5)` gives
`(0.000000000, 0.092437297, 0.244335920)`.

The source grid contains 35,937 triplets, all finite, with min 0 and max
1.000006318 (small numerical overshoot retained, not silently clipped). Maximum
neutral channel spread is 0.000000656. Tests allow 0.000002 neutral spread,
0.00001 sample tolerance, and 1.00001 upper bound. Neutral-axis monotonicity uses
0.000001 tolerance. Tests pin the asset hash, asymmetric red-fastest indexing,
source samples, and decreasing high-end versus middle-tone slope. These checks
are regression evidence, not a visual camera/display validation.
