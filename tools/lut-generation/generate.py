"""Home-built Kodak Vision3 250D / 500T -> 2383 LUTs with an Apple Log 2 input.

Grid domain: Apple Log 2 encoded code values in Apple Wide Gamut (i.e. exactly
what the iPhone records), decoded here to linear Apple Wide Gamut, converted to
CIE XYZ, then run through the Spectral Film LUT (MIT) negative+print pipeline.

Input to the generator is CIE XYZ (input_colorspace=None), so the film stages
never need an Apple-Log-aware colour library.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import colour
import numpy as np

from spectral_film_lut.film_spectral import FilmSpectral
from spectral_film_lut.utils import film_conversion
from spectral_film_lut.negative_film.kodak_5207 import KODAK_5207
from spectral_film_lut.negative_film.kodak_5219 import KODAK_5219
from spectral_film_lut.print_film.kodak_2383 import KODAK_2383

# Apple Log / Apple Log 2 transfer function constants (OpenColorIO v2.6.0,
# src/OpenColorIO/transforms/builtins/AppleCameras.cpp). Log 2 shares the curve
# with Log 1; only the primaries differ (Apple Wide Gamut vs Rec.2020).
AL_R0 = -0.05641088
AL_RT = 0.01
AL_C = 47.28711236
AL_BETA = 0.00964052
AL_GAMMA = 0.08550479
AL_DELTA = 0.69336945
AL_PT = AL_C * (AL_RT - AL_R0) ** 2

# Apple Wide Gamut primaries from the Apple Log 2 white paper (same file).
APPLE_WIDE_GAMUT = colour.RGB_Colourspace(
    "Apple Wide Gamut",
    primaries=np.array([[0.725, 0.301], [0.221, 0.814], [0.068, -0.076]]),
    whitepoint=colour.CCS_ILLUMINANTS["CIE 1931 2 Degree Standard Observer"]["D65"],
    use_derived_matrix_RGB_to_XYZ=True,
)


def apple_log_decode(code: np.ndarray) -> np.ndarray:
    """Apple Log / Log 2 code value -> linear."""
    code = np.asarray(code, dtype=np.float64)
    log_segment = np.power(2.0, (code - AL_DELTA) / AL_GAMMA) - AL_BETA
    linear_segment = np.sqrt(np.clip(code, 0.0, None) / AL_C) + AL_R0
    return np.where(code >= AL_PT, log_segment, np.where(code >= 0.0, linear_segment, AL_R0))


def build_grid(size: int) -> np.ndarray:
    """Apple Log 2 code value grid, shaped (R, G, B, 3) for colour's LUT3D."""
    axis = np.linspace(0.0, 1.0, size, dtype=np.float64)
    r, g, b = np.meshgrid(axis, axis, axis, indexing="ij")
    return np.stack([r, g, b], axis=-1)


def spectral_locus_polygon() -> np.ndarray:
    """CIE 1931 xy spectral locus, closed along the purple line."""
    cmfs = colour.MSDS_CMFS["CIE 1931 2 Degree Standard Observer"]
    xy = colour.XYZ_to_xy(cmfs.values)
    return np.vstack([xy, xy[0]])


_LOCUS = spectral_locus_polygon()
_WHITE_XY = np.array([0.3127, 0.3290])


def _inside_locus(xy: np.ndarray) -> np.ndarray:
    flat = xy.reshape(-1, 2)
    inside = np.zeros(len(flat), dtype=bool)
    for start, end in zip(_LOCUS[:-1], _LOCUS[1:]):
        crosses = (start[1] > flat[:, 1]) != (end[1] > flat[:, 1])
        if not crosses.any():
            continue
        with np.errstate(divide="ignore", invalid="ignore"):
            x_at = start[0] + (flat[:, 1] - start[1]) / (end[1] - start[1]) * (end[0] - start[0])
        inside ^= crosses & (flat[:, 0] < x_at)
    return inside.reshape(xy.shape[:-1])


def confine_to_spectral_locus(xyz: np.ndarray) -> tuple[np.ndarray, int]:
    """Pull non-physical chromaticities onto the spectral locus.

    Apple Wide Gamut's blue primary is imaginary (y = -0.076), so 49% of the
    Log 2 cube's knots decode to a colour outside the spectral locus - some with
    a negative XYZ component, others with positive XYZ but an impossible xy such
    as (0.115, 0.014). The generator's spectral upsampling is a 2D LUT over
    chromaticity and is only meaningful inside the locus; there it is unstable,
    and neighbouring knots jumped 0.83 apart (the Resolve-authored tables used
    before this step: 0.30-0.38). Confining to the locus along the white-point
    ray at constant luminance, leaving in-locus colours untouched, cut the worst
    adjacent-knot step to 0.58-0.67 and the 99.9th percentile to 0.35.
    """
    xyz = np.asarray(xyz, dtype=np.float64).copy()
    total = xyz.sum(axis=-1)
    black = np.abs(total) < 1e-12
    safe = np.where(black, 1.0, total)
    xy = xyz[..., :2] / safe[..., None]
    outside = (~_inside_locus(xy)) & ~black
    count = int(outside.sum())
    if count == 0:
        return xyz, 0
    points = xy[outside]
    direction = points - _WHITE_XY
    best_t = np.ones(len(points))
    for start, end in zip(_LOCUS[:-1], _LOCUS[1:]):
        edge = end - start
        offset = start - _WHITE_XY
        denom = direction[:, 0] * edge[1] - direction[:, 1] * edge[0]
        usable = np.abs(denom) > 1e-12
        safe_denom = np.where(usable, denom, 1.0)
        t = np.where(usable, (offset[0] * edge[1] - offset[1] * edge[0]) / safe_denom, np.inf)
        u = np.where(usable, (offset[0] * direction[:, 1] - offset[1] * direction[:, 0])
                     / safe_denom, np.inf)
        valid = usable & (t > 0) & (u >= 0) & (u <= 1)
        best_t = np.where(valid, np.minimum(best_t, t), best_t)
    confined_xy = _WHITE_XY + best_t[:, None] * 0.999 * direction
    replacement = np.empty((count, 3), dtype=np.float64)
    replacement[:, :2] = confined_xy
    replacement[:, 2] = 1.0 - confined_xy.sum(axis=-1)
    replacement *= np.maximum(total[outside], 0.0)[:, None]
    xyz[outside] = replacement
    return xyz, count


def log2_grid_to_xyz(grid: np.ndarray) -> tuple[np.ndarray, int]:
    """Apple Log 2 code values -> linear Apple Wide Gamut -> confined XYZ."""
    linear = np.clip(apple_log_decode(grid), 0.0, None)
    matrix = APPLE_WIDE_GAMUT.matrix_RGB_to_XYZ
    xyz = linear @ np.asarray(matrix, dtype=np.float64).T
    return confine_to_spectral_locus(xyz)


def load_films():
    negative = FilmSpectral(KODAK_5207)
    negative.set_color_checker()
    print_film = FilmSpectral(KODAK_2383)
    print_film.set_color_checker(negative=negative)
    return negative, print_film


def make_lut(negative_name: str, size: int, out_path: Path, oversample: bool = False,
             **overrides) -> dict:
    negative_data, print_data = {
        "250D": (KODAK_5207, KODAK_2383),
        "500T": (KODAK_5219, KODAK_2383),
    }[negative_name]
    negative = FilmSpectral(negative_data)
    negative.set_color_checker()
    print_film = FilmSpectral(print_data)
    print_film.set_color_checker(negative=negative)

    grid_size = size * 2 - 1 if oversample else size
    grid = build_grid(grid_size)
    xyz, confined = log2_grid_to_xyz(grid)

    kwargs = dict(
        mode="full",
        input_colorspace=None,
        # The iPhone records with white balance locked to the stock's own
        # temperature, so the Log 2 input is already balanced. Feeding that into
        # an illuminant-tilted calibration (e.g. 3200 K for 500T) produced a
        # strong cast on neutral tones; the pipeline's neutral reference is the
        # correct "already balanced" illuminant.
        exp_kelvin=6504,
        output_gamut="Rec. 709",
        gamma_func="Gamma 2.4",
        color_masking=negative.color_masking,
        white_clip=True,
        adx_scaling=1.0,
        upsampling_method="SFL upsampling",
        reference_negative=negative,
    )
    kwargs.update(overrides)

    start = time.time()
    table = film_conversion(xyz, negative, print_film, **kwargs)
    elapsed = time.time() - start
    if table.shape[-1] == 1:
        table = np.repeat(table, 3, axis=-1)
    table = np.asarray(table, dtype=np.float32)
    if oversample:
        # 3x3x3 median then decimate by 2, matching the generator's own
        # "oversampling" filter mode.
        from scipy.ndimage import median_filter
        filtered = np.zeros_like(table)
        for channel in range(3):
            filtered[..., channel] = median_filter(table[..., channel], size=3, mode="nearest")
        table = filtered[::2, ::2, ::2]

    lut = colour.LUT3D(table=table, name=out_path.stem)
    colour.io.write_LUT(lut, str(out_path))
    return {"table": table, "seconds": elapsed, "path": out_path,
            "kwargs": kwargs, "confined_knots": confined}


def neutral_axis(table: np.ndarray, label: str) -> None:
    size = table.shape[0]
    print(f"--- neutral axis {label} (R=G=B Log2 code -> Rec.709) ---")
    for code in [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]:
        index = int(round(code * (size - 1)))
        rgb = table[index, index, index]
        spread = float(rgb.max() - rgb.min())
        print(f"  code {code:4.2f}: {rgb[0]:.4f} {rgb[1]:.4f} {rgb[2]:.4f}  spread {spread:.5f}")


OVERSAMPLE = True

if __name__ == "__main__":
    size = int(sys.argv[1]) if len(sys.argv) > 1 else 33
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("out")
    out_dir.mkdir(parents=True, exist_ok=True)
    for stock in ["250D", "500T"]:
        path = out_dir / f"{stock} K2383 - Apple Log 2.cube"
        result = make_lut(stock, size, path, oversample=OVERSAMPLE)
        table = result["table"]
        print(f"\n=== {stock} === wrote {path} in {result['seconds']:.1f}s")
        print(f"    min {table.min():.5f} max {table.max():.5f} "
              f"nonfinite {int((~np.isfinite(table)).sum())}")
        print(f"    exp_kelvin={result['kwargs']['exp_kelvin']}")
        neutral_axis(table, stock)
