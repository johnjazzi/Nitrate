# LUT generation

Builds the two shipped film look-up tables from source:

| Output | Input domain | Output domain |
|---|---|---|
| `5207 - Apple Log 2.cube` | Apple Log 2 code values in Apple Wide Gamut | Rec. 709, gamma 2.4 |
| `5219 - Apple Log 2.cube` | same | same |

Named by emulsion number: 5207 is Kodak Vision3 250D (daylight), 5219 is Vision3
500T (tungsten). Both print on a fixed Kodak Vision 2383.

33³, `.cube`, red-fastest row order (`row = r + g·33 + b·33²`) — the convention
the app's parser and sampling kernel expect.

Nothing in the Xcode build or the app consumes this directory. It is here so the
tables are reproducible rather than opaque binaries. `docs/lut-provenance.md` is
the record of what was built and why; this file is how to rebuild it.

## Running it

```sh
./bootstrap.sh                 # pinned env: venv + upstream clone at the pinned commit
. .venv/bin/activate
cd tools/lut-generation

python generate.py 33 out      # writes out/5207...cube and out/5219...cube
python verify_cubes.py out     # structure, neutral axis, and a diff vs what ships
python preview.py out          # renders a synthetic chart through the tables (preview/)
```

`generate.py` takes the grid size and an output directory. It is oversampled by
default (`OVERSAMPLE = True`): it evaluates a 65³ grid, applies a 3×3×3 median
per channel, then decimates by 2, which is the upstream generator's own
oversampling filter. Both tables together take about 10 seconds.

### Expected output

A regeneration must reproduce the committed tables exactly:

```
f483e2fb151b3b4699b8d5fd1c36df9f583952941d48c0bc99dd311e574d32b5  5207 - Apple Log 2.cube
d2320ea308730f3aa5186d66691b91d4a94595806970cbb16059c2d067d4924a  5219 - Apple Log 2.cube
```

Confirm with `shasum -a 256 out/*.cube` before copying anything into the app. If
a hash differs, the tables did not change — something in the environment did.

`verify_cubes.py out` additionally checks the parser convention, finiteness,
domain and neutral-axis monotonicity, and prints the diff against whatever is
currently in `App/Resources/LUTs` (which should be exactly zero).

### Installing a regenerated table

Copy the cubes to **both** resource directories and keep them identical:

```
App/Resources/LUTs/    # the iOS app bundle
Resources/LUTs/        # the macOS render CLI's resource directory
```

The app's LUT tests then check the new table against their own CPU reference and
will fail on a bad one. Run `python3 scripts/verify.py verify`.

## Dependencies and pins

`bootstrap.sh` pins the upstream generator by commit
(`6307a98f3cf4f2d7b6d09bab82fbf6f64356ccfe`) and installs it with `--no-deps`;
`requirements.txt` pins the five packages the generator actually imports.
numpy stays on 2.2.x because numba 0.68 does not support 2.3+.

The pins are the point: a floating environment regenerates different tables.

## Method

```
Apple Log 2 code value            the cube's input axis
  → decode to linear              Apple Log transfer function
  → Apple Wide Gamut → XYZ        primaries from Apple's published profile
  → confine to the spectral locus
  → film model                    negative → print → projection
  → Rec. 709, gamma 2.4
```

Two things in that chain are deliberate and worth knowing before changing it:

1. **`exp_kelvin=6504` (the neutral reference), not the stock's own balance.**
   The film data declares 3200 K for 5219 and 5500 K for 5207, and upstream
   never reads those declarations — the illuminant is only ever a parameter. The
   camera records already white-balanced (it locks to the stock's temperature),
   so calibrating for the stock's own temperature tilted the film's sensitivity
   and put a strong cast on neutral tones. Baking at the neutral reference keeps
   the neutral axis neutral.
2. **Confining the input to the spectral locus.** Apple Wide Gamut's blue
   primary is imaginary (`y = −0.076`), so **49%** of the cube's knots decode to
   a chromaticity that cannot be produced by any real spectrum. The film model
   reconstructs a spectrum from chromaticity, which is only meaningful inside
   the locus; there its output is unstable, and neighbouring knots jumped 0.83
   apart, putting near-black holes beside bright knots in saturated blues.
   `confine_to_spectral_locus()` pulls outside chromaticities onto the locus
   along the white-point ray at constant luminance (**57%** of knots in the
   shipped tables), leaving in-locus colours bit-identical.

`generate.py` prints the confined-knot count and the neutral-axis spread for
each stock. A large spread on the neutral axis means the illuminant is fighting
the input again.

## Attribution

| Component | Source | Licence |
|---|---|---|
| Film model, film data | [Spectral Film LUT](https://github.com/JanLohse/spectral_film_lut) by Jan Lohse, pinned `6307a98` | MIT |
| Apple Log transfer function, Apple Wide Gamut primaries | [OpenColorIO](https://github.com/AcademySoftwareFoundation/OpenColorIO) v2.6.0, `AppleCameras.cpp` | BSD-3-Clause |
| Colour science | [colour-science](https://www.colour-science.org/) | BSD-3-Clause |

`ocio-apple-cameras.cpp` is a verbatim reference copy of the OpenColorIO
source the constants in `generate.py` were read from, with its SPDX header
intact. The upstream clone is not vendored — `bootstrap.sh` fetches it at the
pin into `.vendor/`, which is gitignored.
