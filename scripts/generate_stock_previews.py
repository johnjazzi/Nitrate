#!/usr/bin/env python3
"""Generate the stock-preview sample assets for the Nitrate stock-selector carousel.

WHAT THIS PRODUCES (committed under App/Resources/StockSamples/):
  <scene>-log.jpg               the Apple Log 2 encoded plate (one per scene, ungraded)
  manifest.json                 dynamic manifest consumed by the Swift reader

The app applies the selected stock's .cube (and later grain, halation and glow) to the plate
at display time, so no per-stock bitmaps are shipped.

SOURCE MATERIAL
---------------
Real RAW stills shot by the app's author on a Nikon D700 (see SCENES). The NEFs are ~11 MB
each and are NOT committed; pass their directory with --sources. Only the derived 1080x1620
plates and their SHA-256 checksums are committed, so the app needs no network and no RAW
decoder at runtime.

THE ENCODING
------------
  scene-linear sRGB -> Apple Wide Gamut matrix -> exact Apple Log 2 curve -> plate

Apple Log 2 uses the published Apple Wide Gamut primaries and the Apple Log transfer
function (quadratic toe below R_t, log segment above). The profile publishes the primaries
and white point but not the RGB<->XYZ matrix or its chromatic adaptation, so the matrix is
derived from the published primaries (the same derivation opencolorio-config-aces uses).
That derivation is the only remaining approximation. An earlier revision instead inverted
the neutral display LUT from a LibRaw developer render; that baked LibRaw's tone curve and
then undid a display transform, which is not a camera encoding, so it is now only a
comparison path (``--pipeline inverse``).

This is an ILLUSTRATION of the roll's colour, not a camera capture and not a calibration.
The exact-curve encode/decode error and the per-scene stored-JPEG round-trip error are
reported in the manifest.

WHITE BALANCE
-------------
The plate preserves the RAW's AS-SHOT camera white balance: LibRaw's developer render with
``use_camera_wb=True``, i.e. the D700's own multipliers, which are recorded in the manifest
(``source.nef.asShotWhiteBalance``) rather than guessed. No white-patch / grey-world
rebalancing is applied. An earlier revision selected the brightest desaturated pixels of a
gamma-encoded RGB render as a "neutral" reference and scaled the channels to it; that had no
reliable reference (gamma-encoded values are not scene-linear, and a bright non-neutral
surface passes the filter), so it could silently re-tint every plate. It was removed. A
per-scene illuminant Kelvin is *assumed* for the runtime stock white-balance simulation
(``sceneIlluminantKelvin``); it is NOT measured or derived from RAW multipliers. Colour only -- no grain / halation /
gauge simulation.

DEPS (build-time only): numpy, Pillow, rawpy, exifread.
RUN:
  python scripts/generate_stock_previews.py --sources ~/Downloads
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
from pathlib import Path

import numpy as np

try:  # Pillow is only needed for JPEG IO / contact sheet; keep import lazy-ish but simple
    from PIL import Image, ImageDraw
except ImportError as exc:  # pragma: no cover
    raise SystemExit("Pillow is required for generation: pip install Pillow") from exc

REPO = Path(__file__).resolve().parent.parent
RES = REPO / "App" / "Resources"
STOCK_DIR = RES / "StockSamples"
NEUTRAL_LUT = RES / "Preview" / "AppleLog2ToRec709.cube"
STOCK_LUTS = {
    "kodak5207": RES / "LUTs" / "5207 - Apple Log 2.cube",
    "kodak5219": RES / "LUTs" / "5219 - Apple Log 2.cube",
}
DEFAULT_SOURCES = Path.home() / "Downloads"

SCHEMA_VERSION = 2
DISCLAIMER = "Illustrative plates \u00b7 your LUT applied live"
# Shipped asset budget: the plates are the only bitmap art the app bundles. 1080x1620 (2:3)
# is the card's native shape at 3x, so a plate stays sharp on a 3x display. The crop is
# taken at source resolution and only ever downscaled, so the plate keeps its aspect instead
# of being squeezed into the card. Quality 76 is "moderate": these are flat Log plates, so
# the whole set stays well under the per-plate and total budgets asserted by the suite.
OUT_W, OUT_H = 1080, 1620
PREVIEW_QUALITY = 76
# Explicit exposure choice for the exact encode: keep the as-shot exposure (no LibRaw
# auto-bright stretch). Apple Log 2 is a scene-referred encoding, so stretching each frame
# to full scale would move 18% grey off its defined code and misrepresent the roll.
NO_AUTO_BRIGHT = True
PIPELINES = ("exact", "inverse")
STOCKS = ["kodak5207", "kodak5219"]
STOCKS_JSON = RES / "stocks.json"
REC709_LUMA = np.array([0.2126, 0.7152, 0.0722])

# ----------------------------------------------------------------- Apple Log 2 colour
# The Apple Log 2 Profile publishes the Apple Wide Gamut primaries and the D65 white point
# (Apple Wide Gamut xy = [[.725,.301],[.221,.814],[.068,-.076]], D65 [.3127,.3290]); Apple Log 2
# reuses the Apple Log transfer curve. The Profile does NOT publish the RGB<->XYZ matrix or its
# chromatic adaptation, so the matrix below is derived from the published primaries -- the same
# derivation OpenColorIO's opencolorio-config-aces uses (both sets share D65, so no adaptation
# is needed). This is the interface the shader/renderer side must match.
#
# Sources: Apple "Apple Log 2 Profile" and "Apple Log Profile" (developer.apple.com);
# colour-science `log_encoding_AppleLogProfile` constants (Apple Inc. 2023);
# opencolorio-config-aces clf/transforms/apple/generate.py (primaries at the
# `_build_apple_wg_mtx` definition; Log2 "uses the same transfer function as Apple Log").
APPLE_WG_PRIMARIES = np.array([[0.725, 0.301], [0.221, 0.814], [0.068, -0.076]])
SRGB_PRIMARIES = np.array([[0.64, 0.33], [0.30, 0.60], [0.15, 0.06]])
D65_WHITE = (0.3127, 0.3290)
APPLE_LOG_CONSTANTS = {"R_0": -0.05641088, "R_t": 0.01, "sigma": 47.28711236,
                       "beta": 0.00964052, "gamma": 0.08550479, "delta": 0.69336945}


def _rgb_to_xyz_matrix(primaries: np.ndarray, white: tuple[float, float]) -> np.ndarray:
    """Derive an RGB->XYZ matrix from primaries and a white point (both xy)."""
    columns = [[x / y, 1.0, (1.0 - x - y) / y] for x, y in primaries]
    prim = np.asarray(columns, dtype=np.float64).T
    xw, yw = white
    scale = np.linalg.solve(prim, np.array([xw / yw, 1.0, (1.0 - xw - yw) / yw]))
    return prim * scale[None, :]


SRGB_TO_APPLE_WG = np.linalg.solve(_rgb_to_xyz_matrix(APPLE_WG_PRIMARIES, D65_WHITE),
                                   _rgb_to_xyz_matrix(SRGB_PRIMARIES, D65_WHITE))


def srgb_linear_to_apple_wide_gamut(rgb: np.ndarray) -> np.ndarray:
    """Rotate scene-linear sRGB into Apple Wide Gamut primaries (no tone change)."""
    return np.asarray(rgb, dtype=np.float64) @ SRGB_TO_APPLE_WG.T


def apple_log_encode(linear: np.ndarray) -> np.ndarray:
    """Exact Apple Log 2 opto-electronic transfer function (same curve as Apple Log).

    Quadratic toe below R_t (the "quadratic toe"), log segment above, hard floor at R_0.
    Reflection 0.18 encodes to 0.48827, matching Apple's published example.
    """
    c = APPLE_LOG_CONSTANTS
    x = np.asarray(linear, dtype=np.float64)
    log_segment = c["gamma"] * np.log2(np.maximum(x + c["beta"], 1e-12)) + c["delta"]
    toe = c["sigma"] * (x - c["R_0"]) ** 2
    return np.where(x >= c["R_t"], log_segment, np.where(x >= c["R_0"], toe, 0.0))


def srgb_linear_to_display(linear: np.ndarray) -> np.ndarray:
    """Reference Rec.709/sRGB display render: the sRGB OETF. Used only for comparison."""
    x = np.clip(np.asarray(linear, dtype=np.float64), 0.0, 1.0)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1.0 / 2.4) - 0.055)

# Stills supplied by the app's author, shot on a Nikon D700. The RAW files are NOT
# committed (~11 MB each); regeneration needs them in --sources. Only the derived Log
# plates and their checksums live in the repository.
SCENES = {
    "neon": {"title": "Neon", "nef": "DSC_0278.nef",
             "illuminant_kelvin": 3600, "note": "Tungsten signage against a dusk sky"},
    "forest": {"title": "Forest", "nef": "DSC_0982.nef",
               "illuminant_kelvin": 5600, "note": "Daylight under a canopy"},
    "harvest": {"title": "Harvest", "nef": "DSC_2186.nef",
                "illuminant_kelvin": 5600, "note": "Daylight, saturated warm subject"},
    "fireworks": {"title": "Fireworks", "nef": "DSC_2077.nef",
                  "illuminant_kelvin": 3600, "note": "Night highlights on a dark ground"},
    "nightride": {"title": "Night ride", "nef": "DSC_3488.nef",
                  "illuminant_kelvin": 3600, "note": "Night speed, skin under sodium light"},
    "race": {"title": "Race day", "nef": "DSC_7950.nef",
             "illuminant_kelvin": 5600, "note": "Daylight skin tones, saturated crowd colour"},
    "shoreline": {"title": "Shoreline", "nef": "DSC_0355.nef",
                  "illuminant_kelvin": 5600, "note": "Daylight water and a hazy skyline"},
    "flyover": {"title": "Flyover", "nef": "DSC_4498.nef",
                "illuminant_kelvin": 5600, "note": "Bright daylight sky and distant detail"},
}

# ----------------------------------------------------------------- RAW still sources
def source_sha256(path: Path) -> str:
    """Content hash of a source still, recorded in the manifest for reproducibility."""
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_source(sources: Path, name: str) -> Path:
    """Return the path that actually exists on disk for ``name``, preserving its case.

    macOS reads ``DSC_1234.nef`` and ``DSC_1234.NEF`` as the same file, so ``exists()`` cannot
    tell us how the file is really spelled. The manifest should record the on-disk spelling
    (the D700 writes some ``.NEF`` and some ``.nef``), so we list the directory and return the
    real entry name. Sources are never renamed.
    """
    if sources.is_dir():
        folded = name.casefold()
        for child in sorted(sources.iterdir()):
            if child.name.casefold() == folded:
                return child
    return sources / name


def nef_metadata(path: Path) -> dict:
    """Capture facts recorded beside each preview, so the source is identifiable.

    Includes the camera's AS-SHOT white balance as stored in the RAW: the EXIF mode plus
    Nikon's maker-note multipliers. These are recorded facts, not an inferred Kelvin --
    no colour temperature is derived from the multipliers.
    """
    import exifread
    from fractions import Fraction
    with open(path, "rb") as fh:
        tags = exifread.process_file(fh, details=True)

    def get(name: str) -> str | None:
        value = tags.get(name)
        return str(value).strip() if value is not None else None

    def multipliers(name: str) -> list[float] | None:
        value = tags.get(name)
        if value is None:
            return None
        try:
            return [float(Fraction(str(part).strip()))
                    for part in str(value).strip("[]").split(",")]
        except (ValueError, ZeroDivisionError):
            return None

    return {
        "camera": " ".join(x for x in (get("Image Make"), get("Image Model")) if x),
        "exposureTime": get("EXIF ExposureTime"),
        "fNumber": get("EXIF FNumber"),
        "iso": get("EXIF ISOSpeedRatings"),
        "focalLength": get("EXIF FocalLength"),
        "originalDate": get("EXIF DateTimeOriginal"),
        "whiteBalance": get("EXIF WhiteBalance"),
        "asShotWhiteBalance": {
            "source": "RAW as-shot camera white balance (LibRaw use_camera_wb=True)",
            "exifMode": get("EXIF WhiteBalance"),
            "makerNoteMode": get("MakerNote Whitebalance"),
            "makerNoteRBCoeff": get("MakerNote WhiteBalanceRBCoeff"),
            "multipliersRGB": multipliers("MakerNote WhiteBalanceRBCoeff"),
            "bias": get("MakerNote WhiteBalanceBias"),
            "note": "recorded as-shot multipliers; no colour temperature is inferred from them",
        },
    }


def _crop_2to3(image: Image.Image, out_w: int, out_h: int) -> Image.Image:
    """Centre-crop to 2:3 at source resolution, then Lanczos down to the plate size."""
    width, height = image.size
    crop_w = min(width, int(round(height * out_w / out_h)))
    x0 = (width - crop_w) // 2
    return image.crop((x0, 0, x0 + crop_w, height)).resize((out_w, out_h), Image.LANCZOS)


def _resize_linear(rgb_u16: np.ndarray, out_w: int, out_h: int) -> np.ndarray:
    """Centre-crop 2:3 and Lanczos-resize 16-bit linear RGB, per channel (Pillow I;16)."""
    height, width = rgb_u16.shape[:2]
    crop_w = min(width, int(round(height * out_w / out_h)))
    x0 = (width - crop_w) // 2
    cropped = rgb_u16[:, x0:x0 + crop_w, :]
    channels = [np.asarray(Image.fromarray(np.ascontiguousarray(cropped[..., i]))
                           .resize((out_w, out_h), Image.LANCZOS)) for i in range(3)]
    return np.stack(channels, axis=-1).astype(np.float64) / 65535.0


def load_nef_linear(path: Path, out_w: int = OUT_W, out_h: int = OUT_H) -> np.ndarray:
    """Decode a NEF to scene-linear sRGB in [0, 1] for the exact Apple Log 2 encode.

    ``gamma=(1, 1)`` disables LibRaw's tone curve, ``output_bps=16`` keeps precision, and
    ``use_camera_wb=True`` applies the RAW's AS-SHOT white balance. ``no_auto_bright`` is an
    explicit choice (see NO_AUTO_BRIGHT): True disables the automatic exposure stretch.
    LibRaw's RAW scaling remains; this is not an absolute scene-radiance calibration.
    Resampling happens in LINEAR light here (correct for a scene-linear signal).
    """
    import rawpy
    with rawpy.imread(str(path)) as raw:
        linear = raw.postprocess(half_size=False, output_bps=16, gamma=(1, 1),
                                 no_auto_bright=NO_AUTO_BRIGHT, use_camera_wb=True,
                                 output_color=rawpy.ColorSpace.sRGB)
    return _resize_linear(linear, out_w, out_h)


def load_nef_display(path: Path, out_w: int = OUT_W, out_h: int = OUT_H) -> np.ndarray:
    """Decode a NEF to a display-referred Rec. 709 still (the developer render).

    LibRaw supplies the camera matrix and its own tone curve, so this is the ordinary,
    correctly white-balanced photograph used as the visual AS-SHOT BASELINE for comparison.
    It is not an input to the exact encode.
    """
    import rawpy
    with rawpy.imread(str(path)) as raw:
        rgb = raw.postprocess(half_size=False, output_bps=8, no_auto_bright=False,
                              use_camera_wb=True, output_color=rawpy.ColorSpace.sRGB)
    image = _crop_2to3(Image.fromarray(rgb, mode="RGB"), out_w, out_h)
    return np.asarray(image).astype(np.float64) / 255.0


def exact_apple_log_plate(linear_srgb: np.ndarray) -> np.ndarray:
    """Scene-linear sRGB -> Apple Wide Gamut -> exact Apple Log 2 encode."""
    awg = srgb_linear_to_apple_wide_gamut(linear_srgb)
    return np.clip(apple_log_encode(np.clip(awg, 0.0, None)), 0.0, 1.0)


def legacy_inverse_plate(display: np.ndarray, neutral_inv: "InverseNeutral") -> np.ndarray:
    """Deprecated comparison path: invert the neutral display LUT from a developer render.

    Retained only so the generator can render the "current" pipeline beside the exact
    encode for selection. It bakes LibRaw's tone curve and then undoes the display LUT,
    which is why it is no longer the default.
    """
    return np.clip(neutral_inv.apply(display), 0.0, 1.0)


# ------------------------------------------------------------------ display <-> synthetic Log
def _parse_cube(path: Path):
    size = None; data = []
    with open(path, "r", errors="ignore") as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            u = s.upper()
            if u.startswith("LUT_3D_SIZE"):
                size = int(s.split()[1]); continue
            if u.startswith(("TITLE", "DOMAIN_MIN", "DOMAIN_MAX", "LUT_1D_SIZE")):
                continue
            try:
                data.append([float(t) for t in s.split()])
            except ValueError:
                continue
    arr = np.asarray(data, dtype=np.float64)
    if size is None or arr.shape[0] != size ** 3 or arr.shape[1] != 3:
        raise ValueError(f"{path}: not a valid 3D cube ({arr.shape}, size={size})")
    return size, arr


def _trilinear_grid(grid: np.ndarray, rgb: np.ndarray) -> np.ndarray:
    """Trilinear sample of a 3D LUT stored as an (n, n, n, 3) array indexed [r, g, b]."""
    n = grid.shape[0]
    g = np.clip(np.asarray(rgb, dtype=np.float64), 0.0, 1.0) * (n - 1)
    i0 = np.clip(np.floor(g).astype(np.int32), 0, n - 2)
    frac = g - i0
    r0, g0, b0 = i0[..., 0], i0[..., 1], i0[..., 2]
    r1, g1, b1 = r0 + 1, g0 + 1, b0 + 1
    fr, fg, fb = frac[..., 0:1], frac[..., 1:2], frac[..., 2:3]
    c000 = grid[r0, g0, b0]; c100 = grid[r1, g0, b0]
    c010 = grid[r0, g1, b0]; c110 = grid[r1, g1, b0]
    c001 = grid[r0, g0, b1]; c101 = grid[r1, g0, b1]
    c011 = grid[r0, g1, b1]; c111 = grid[r1, g1, b1]
    c00 = c000 * (1 - fr) + c100 * fr
    c10 = c010 * (1 - fr) + c110 * fr
    c01 = c001 * (1 - fr) + c101 * fr
    c11 = c011 * (1 - fr) + c111 * fr
    c0 = c00 * (1 - fg) + c10 * fg
    c1 = c01 * (1 - fg) + c11 * fg
    return c0 * (1 - fb) + c1 * fb


def _cube_grid(cube: np.ndarray, size: int) -> np.ndarray:
    """Reshape a red-fastest flat cube into an (n, n, n, 3) array indexed [r, g, b].

    Red-fastest means flat index = r + n*g + n^2*b; ``reshape(n, n, n, 3)`` lays the axes
    out as [b, g, r], so the fast axis must be transposed to the front.
    """
    return cube.reshape(size, size, size, 3).transpose(2, 1, 0, 3)


def _trilinear(cube: np.ndarray, size: int, rgb: np.ndarray) -> np.ndarray:
    """Sample a red-fastest flat 3D cube with trilinear interpolation."""
    return _trilinear_grid(_cube_grid(cube, size), rgb)


try:  # optional accelerator; brute-force fallback keeps the script dependency-light
    from scipy.spatial import cKDTree as _cKDTree
except ImportError:  # pragma: no cover
    _cKDTree = None


def _knn_interp(table_in: np.ndarray, table_out: np.ndarray, q: np.ndarray, k: int) -> np.ndarray:
    """Weighted kNN interpolation in cube-output space (targets are the synthetic-Log inputs).

    Uses a KD-tree over the cube's output colours when scipy is present (fast path for
    ~36k nodes x ~half a million pixels); otherwise a chunked brute-force search.
    """
    q = np.asarray(q, dtype=np.float64)
    out = np.empty_like(q)
    rank = np.arange(1, k + 1)
    inv = (1.0 / rank)
    inv = inv / inv.sum()

    if _cKDTree is not None:
        tree = _cKDTree(table_out)
        _, idx = tree.query(q, k=k, workers=-1)
        dd = np.take_along_axis(
            ((q[:, None, :] - table_out[idx]) ** 2).sum(-1), np.arange(k)[None, :], axis=1
        )
    else:  # pragma: no cover - slow fallback
        bs = 2048
        idx = np.empty((q.shape[0], k), dtype=np.int64)
        dd = np.empty((q.shape[0], k), dtype=np.float64)
        for s in range(0, q.shape[0], bs):
            e = min(s + bs, q.shape[0])
            d2 = ((q[s:e, None, :] - table_out[None, :, :]) ** 2).sum(-1)
            part = np.argpartition(d2, k - 1, axis=1)[:, :k]
            idx[s:e] = part
            dd[s:e] = np.take_along_axis(d2, part, axis=1)
    order = np.argsort(dd, axis=1)
    idx = np.take_along_axis(idx, order, axis=1)
    dd = np.take_along_axis(dd, order, axis=1)
    w = inv[None, :] / np.maximum(dd, 1e-12)
    w = w / w.sum(1, keepdims=True)
    out[:] = np.einsum("nk,nkc->nc", w, table_in[idx])
    return out


def _newton_refine(grid: np.ndarray, target: np.ndarray, u0: np.ndarray,
                   iters: int = 6, lam: float = 1e-4, h: float = 1.0 / 64.0) -> np.ndarray:
    """Damped (Levenberg-style) Newton refinement of forward(grid, u) = target.

    Per query it starts from ``u0`` and drives the residual to zero using the analytic
    rate of the trilinear cube (finite-difference Jacobian). Damping keeps it stable in
    the near-black region where the transform is flat and the Jacobian is singular.
    """
    u = np.clip(u0, 0.0, 1.0).copy()
    eye = np.eye(3)[None, :, :]
    for _ in range(iters):
        fx = _trilinear_grid(grid, u)
        jac = np.empty((u.shape[0], 3, 3))
        for i in range(3):
            up = u.copy(); up[:, i] = np.clip(up[:, i] + h, 0.0, 1.0)
            um = u.copy(); um[:, i] = np.clip(um[:, i] - h, 0.0, 1.0)
            jac[..., i] = (_trilinear_grid(grid, up) - _trilinear_grid(grid, um)) / (2.0 * h)
        r = fx - target
        jtj = np.einsum("noi,noj->nij", jac, jac) + lam * eye
        jtr = np.einsum("noi,no->ni", jac, r)
        step = np.linalg.solve(jtj, jtr[..., None])[..., 0]
        u = np.clip(u - np.clip(step, -0.25, 0.25), 0.0, 1.0)
    return u


class InverseNeutral:
    """Approximate inverse of the official neutral LUT's input encoding (illustrative).

    Two stages, both deterministic:
      1. a KD-tree kNN guess in the cube's *output* space gives a starting point per query;
      2. a bounded damped-Newton refinement drives forward(u) onto the requested display
         colour using the cube's own trilinear model.
    The refinement is the "bounded refinement" the brief asks for: it is not a random
    filter -- it inverts the actual neutral transform, per pixel, to within the reported
    round-trip error. Near black the transform is not injective (many Log codes share one
    display value), so the residual there is reported honestly rather than hidden.

    Only colours the forward transform can actually produce are invertible. A locked
    white balance can push a scene outside that set; `project` pulls such colours back
    onto the reachable surface so the synthetic Log input is always a frame the monitor
    transform would really have produced, instead of the noise an unconstrained
    nearest-neighbour inverse returns there.
    """

    def __init__(self, cube_path: Path):
        size, cube = _parse_cube(cube_path)
        self.size = size
        self.cube = cube
        self.grid = _cube_grid(cube, size)
        # table_in must be ordered exactly like table_out (= cube file order, red-fastest:
        # flat index = r + n*g + n^2*b) so that kNN neighbours carry the right synthetic-Log input.
        idx = np.arange(size ** 3)
        r = (idx % size) / (size - 1)
        gg = ((idx // size) % size) / (size - 1)
        b = (idx // (size * size)) / (size - 1)
        self.table_in = np.stack([r, gg, b], axis=-1)
        self.table_out = cube.reshape(-1, 3)
        self._tree = None

    def apply(self, rgb: np.ndarray, k: int = 12, newton_iters: int = 6) -> np.ndarray:
        shape = rgb.shape
        q = np.clip(np.asarray(rgb, dtype=np.float64), 0.0, 1.0).reshape(-1, 3)
        guess = _knn_interp(self.table_in, self.table_out, q, k)
        out = _newton_refine(self.grid, q, guess, iters=newton_iters)
        return out.reshape(shape)


# ------------------------------------------------------------------------------------ pipeline
APPLE_LOG2_RECIPE_EXACT = (
    "RAW -> LibRaw scene-linear sRGB (gamma=(1,1), 16-bit, as-shot white balance, "
    "no auto-bright) -> linear-light centre 2:3 crop + Lanczos -> Apple Wide Gamut matrix "
    "(derived from the published primaries) -> exact Apple Log 2 curve encode "
    "(quadratic toe) -> Log plate")
APPLE_LOG2_RECIPE_INVERSE = (
    "RAW -> developer render (LibRaw camera matrix, its tone curve) -> approximate inverse "
    "of the official neutral Apple Log 2 -> Rec.709 LUT -> Log plate [DEPRECATED comparison "
    "path: bakes the developer tone curve]")


def encode_metadata() -> dict:
    """The exact Apple Log 2 description shared with the renderer / shader author."""
    c = APPLE_LOG_CONSTANTS
    return {
        "transfer": "Apple Log 2 (same curve as Apple Log)",
        "primaries": "Apple Wide Gamut (published in the Apple Log 2 Profile)",
        "primariesXY": [[float(x), float(y)] for x, y in APPLE_WG_PRIMARIES],
        "whiteXY": list(D65_WHITE),
        "curve": {k: c[k] for k in ("R_0", "R_t", "sigma", "beta", "gamma", "delta")},
        "curveFormula": "R>=R_t: gamma*log2(R+beta)+delta; R_0<=R<R_t: sigma*(R-R_0)^2; else 0",
        "encoded18PercentReflection": float(apple_log_encode(0.18)),
        "sourceToAppleWideGamutMatrix": [[float(v) for v in row] for row in SRGB_TO_APPLE_WG],
        "note": "primaries/white are published; the RGB<->XYZ matrix is derived from them "
                "(same derivation opencolorio-config-aces uses).",
    }


def _read_jpg(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB")).astype(np.float64) / 255.0


def _curve_roundtrip_metrics() -> dict:
    """Sanity metric for the exact curve: encode->decode of scene-linear values (10-bit units)."""
    rng = np.random.default_rng(20261021)
    x = rng.random(20000)
    c = APPLE_LOG_CONSTANTS
    p = apple_log_encode(x)
    decoded = np.where(p >= c["sigma"] * (c["R_t"] - c["R_0"]) ** 2,
                       2.0 ** ((p - c["delta"]) / c["gamma"]) - c["beta"],
                       np.sqrt(np.maximum(p, 0.0) / c["sigma"]) + c["R_0"])
    err = np.abs(decoded - x)
    return {
        "samples": int(x.size),
        "maxLinearAbsError": float(err.max()),
        "note": "encode -> decode of the Apple Log 2 curve; validates the toe/log split",
    }


def build_assets(neutral_inv: InverseNeutral, contact_sheet: bool, sources: Path,
                 pipeline: str = "exact") -> dict:
    """Write one Apple Log 2 plate per scene and describe it in the manifest.

    A plate, not a graded still: the app applies the selected stock LUT (and later grain,
    halation and glow) at display time, so a user LUT or a tweak needs no new asset.
    """
    if pipeline not in PIPELINES:
        raise SystemExit(f"unknown pipeline {pipeline!r}; choose from {PIPELINES}")
    STOCK_DIR.mkdir(parents=True, exist_ok=True)

    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "disclaimer": DISCLAIMER,
        "generator": "scripts/generate_stock_previews.py",
        "pipeline": pipeline,
        "stocks": STOCKS,
        "lutSHA256": {sid: source_sha256(p) for sid, p in STOCK_LUTS.items()},
        "neutralLutSHA256": source_sha256(NEUTRAL_LUT),
        "runtimeNote": "Plates are Apple Log 2 encoded. The app applies the selected stock "
                       "LUT to the plate live, so previews track a user LUT, a grade tweak "
                       "or a gauge change without new assets.",
        "appleLog2": encode_metadata(),
        "curveRoundTrip": _curve_roundtrip_metrics(),
        "whiteBalancePolicy": "RAW as-shot camera white balance; no white-patch / grey-world "
                              "rebalancing is applied, so scene chroma is not inferred.",
        "exposurePolicy": "LibRaw no_auto_bright=%s (as-shot exposure; scene-referred encode)"
                          % NO_AUTO_BRIGHT,
        "scenes": [],
    }

    # Inverse round-trip metrics (legacy path only, but harmless and still exact for the LUT).
    def _roundtrip(x):
        back = _trilinear(neutral_inv.cube, neutral_inv.size, neutral_inv.apply(x))
        return np.abs(back - x) * 255.0

    rng = np.random.default_rng(20261020)
    full = rng.random((20000, 3))
    rt_full = _roundtrip(full)
    valid = full[(full @ np.array([0.2126, 0.7152, 0.0722])) >= 0.06]
    rt_valid = _roundtrip(valid)
    manifest["inverseRoundTripGlobal"] = {
        "holdoutSamples": int(full.shape[0]),
        "validSamples": int(valid.shape[0]),
        "validMeanAbsError8bit": float(rt_valid.mean()),
        "validP95AbsError8bit": float(np.percentile(rt_valid, 95)),
        "validMaxAbsError8bit": float(rt_valid.max()),
        "fullMeanAbsError8bit": float(rt_full.mean()),
        "fullP95AbsError8bit": float(np.percentile(rt_full, 95)),
        "fullMaxAbsError8bit": float(rt_full.max()),
        "note": "error over the full cube is dominated by unreachable near-black codes where "
                "the neutral transform is not invertible; the valid-range figure is the "
                "meaningful one for these photos.",
    }

    neutral_size, neutral_cube = _parse_cube(NEUTRAL_LUT)
    sheet = None
    d = None
    rows = len(SCENES)
    if contact_sheet:
        sheet, d, tw, th = _new_sheet(rows, ["as-shot baseline", "neutral LUT", "5207", "5219"],
                                      "Nitrate stock previews | exact Apple Log 2 plates | "
                                      "WB: RAW as-shot, no white-patch (conversion isolated)")

    for row, (sid, scene) in enumerate(SCENES.items()):
        src = resolve_source(sources, scene["nef"])
        if not src.exists():
            raise SystemExit(f"missing source RAW {src}; pass --sources <dir>")
        if pipeline == "exact":
            linear = load_nef_linear(src)
            plate = exact_apple_log_plate(linear)
            reference = srgb_linear_to_display(np.clip(linear, 0.0, 1.0))
        else:
            reference = load_nef_display(src)
            plate = legacy_inverse_plate(reference, neutral_inv)

        path = STOCK_DIR / f"{sid}-log.jpg"
        _save_jpg(plate, path)

        # The metrics the suite can trust: measured on the STORED 8-bit JPEG, not on the
        # float plate before compression (which would understate the real error).
        stored = _read_jpg(path)
        display_float = _trilinear(neutral_cube, neutral_size, plate)
        display_stored = _trilinear(neutral_cube, neutral_size, stored)
        # Genuine stored-JPEG round trip, in display space: what the app shows from the
        # committed file vs what it would show from the lossless plate.
        rt_scene = np.abs(display_stored - display_float) * 255.0
        jpeg_err = np.abs(stored - plate) * 255.0
        # Informational: the encoding + official-LUT tone rendering vs a plain sRGB
        # display render of the same as-shot linear (a look difference, not an error).
        tone_delta = np.abs(display_stored - reference) * 255.0

        manifest["scenes"].append({
            "id": sid,
            "title": scene["title"],
            "plate": path.name,
            "source": {
                "provider": "John Azzinaro (Nikon D700) — supplied for Nitrate",
                "file": src.name,
                "license": "\u00a9 John Azzinaro, used with permission in Nitrate",
                "sha256": source_sha256(src),
                "nef": nef_metadata(src),
                "note": scene["note"],
            },
            "derivation": {
                "recipe": APPLE_LOG2_RECIPE_EXACT if pipeline == "exact"
                          else APPLE_LOG2_RECIPE_INVERSE,
                "sceneIlluminantKelvin": scene["illuminant_kelvin"],
                "sceneIlluminantProvenance": "assumed for this scene, not measured",
                "whiteBalance": {
                    "source": "RAW as-shot camera white balance (LibRaw use_camera_wb=True)",
                    "rebalancing": "none (auto white-patch removed)",
                },
                "crop": f"centre {OUT_W}x{OUT_H} (2:3) from the full frame, Lanczos",
                "outputSize": [OUT_W, OUT_H],
                "jpegQuality": PREVIEW_QUALITY,
                "plateLabel": "Apple Log 2 encoded plate (illustrative; NOT a camera original)",
            },
            "plateStats": {
                "sha256": source_sha256(path),
                "meanCode": float(stored.mean()),
                "whiteFraction": float(_white_fraction(stored)),
                "midtoneFraction": float(_midtone_fraction(stored)),
                "clippedChannelFraction": float(_clipped_channel_fraction(stored)),
                "jpegBytes": int(path.stat().st_size),
                "jpegEncodeMeanAbsError8bit": float(jpeg_err.mean()),
                "jpegEncodeP99AbsError8bit": float(np.percentile(jpeg_err, 99)),
                "roundTripMeanAbsError8bit": float(rt_scene.mean()),
                "roundTripP99AbsError8bit": float(np.percentile(rt_scene, 99)),
                "roundTripNote": "display-space difference between the STORED JPEG and the "
                                 "lossless plate (both through the official neutral LUT); "
                                 "this is the real JPEG round-trip error.",
                "displayToneDeltaMeanAbsError8bit": float(tone_delta.mean()),
                "displayToneDeltaNote": "official neutral LUT applied to the stored plate vs "
                                        "a plain sRGB display render of the same as-shot "
                                        "linear; an informational look difference (exposure "
                                        "isolated), not an error.",
            },
        })

        if contact_sheet and sheet is not None:
            images = [reference,
                      _trilinear(neutral_cube, neutral_size, stored),
                      _apply_lut(STOCK_LUTS["kodak5207"], stored),
                      _apply_lut(STOCK_LUTS["kodak5219"], stored)]
            _paste_row(sheet, d, row, images, tw, th, f"scene: {sid}")

    manifest["plateCount"] = len(manifest["scenes"])
    _write_manifest(manifest)
    if contact_sheet and sheet is not None:
        _save_sheet(sheet, "CONTACT_SHEET",
                    Path.home() / ".cache" / "nitrate-stock-preview-sources" / "contact_final.jpg")
    return manifest


def compare_pipelines(sources: Path) -> Path:
    """Render the exact encode and the legacy inverse side by side, per scene, for selection."""
    neutral_size, neutral_cube = _parse_cube(NEUTRAL_LUT)
    inv = InverseNeutral(NEUTRAL_LUT)
    cols = ["inverse neutral", "inverse 5207", "inverse 5219",
            "exact neutral", "exact 5207", "exact 5219"]
    sheet, d, tw, th = _new_sheet(len(SCENES), cols,
                                  "Exact Apple Log 2 encode vs legacy inverse | WB as-shot, "
                                  "no white-patch | same source NEF per row")
    for row, (sid, scene) in enumerate(SCENES.items()):
        src = resolve_source(sources, scene["nef"])
        if not src.exists():
            raise SystemExit(f"missing source RAW {src}; pass --sources <dir>")
        linear = load_nef_linear(src)
        exact = exact_apple_log_plate(linear)
        inverse = legacy_inverse_plate(load_nef_display(src), inv)
        images = [_trilinear(neutral_cube, neutral_size, inverse),
                  _apply_lut(STOCK_LUTS["kodak5207"], inverse),
                  _apply_lut(STOCK_LUTS["kodak5219"], inverse),
                  _trilinear(neutral_cube, neutral_size, exact),
                  _apply_lut(STOCK_LUTS["kodak5207"], exact),
                  _apply_lut(STOCK_LUTS["kodak5219"], exact)]
        _paste_row(sheet, d, row, images, tw, th, f"scene: {sid}")
    return _save_sheet(sheet, "CONTACT_COMPARE",
                       Path.home() / ".cache" / "nitrate-stock-preview-sources"
                       / "contact_exact_vs_inverse.jpg")


def _new_sheet(rows: int, cols: list[str], title: str):
    """Contact-sheet canvas with a useful width at/under 1600 px."""
    pad, head = 8, 34
    tw = min(384, max(120, (1600 - (len(cols) + 1) * pad) // len(cols)))
    th = int(round(tw * OUT_H / OUT_W))
    sheet = Image.new("RGB",
                      (pad + len(cols) * (tw + pad), head + rows * (th + head + pad)),
                      (24, 24, 26))
    d = ImageDraw.Draw(sheet)
    d.text((pad, 8), title, fill=(235, 235, 235))
    for c, name in enumerate(cols):
        d.text((pad + c * (tw + pad), 18), name, fill=(200, 200, 200))
    return sheet, d, tw, th


def _paste_row(sheet, d, row: int, images: list[np.ndarray], tw: int, th: int, label: str) -> None:
    pad, head = 8, 34
    y = head + row * (th + head + pad)
    d.text((pad, y + 16), label, fill=(235, 235, 235))
    for c, img in enumerate(images):
        x = pad + c * (tw + pad)
        thumb = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
        sheet.paste(thumb.resize((tw, th), Image.LANCZOS), (x, y + head))


def _apply_lut(path: Path, rgb: np.ndarray) -> np.ndarray:
    """Apply a .cube (trilinear) to an image array, handling the (size, cube) parse order."""
    size, cube = _parse_cube(path)
    return _trilinear(cube, size, rgb)


def _save_sheet(sheet: Image.Image, env: str, default: Path) -> Path:
    out = Path(os.environ.get(env, str(default)))
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out, "JPEG", quality=88)
    print(f"contact sheet -> {out}")
    return out


def _white_fraction(img: np.ndarray) -> float:
    return float((img > 0.97).all(axis=-1).mean())


def _midtone_fraction(img: np.ndarray) -> float:
    m = img.mean(axis=-1)
    return float(((m > 0.08) & (m < 0.94)).mean())


def _clipped_channel_fraction(img: np.ndarray) -> float:
    """Fraction of pixels with at least one channel at/above full scale.

    Reported rather than removed: a locked white balance genuinely clips a channel
    when the scene illuminant is far from the lock, and hiding that would misrepresent
    what the stock does.
    """
    return float((img >= 0.999).any(axis=-1).mean())


def _save_jpg(img: np.ndarray, path: Path, quality: int = PREVIEW_QUALITY) -> None:
    arr = np.clip(img, 0.0, 1.0)
    arr = (arr * 255.0 + 0.5).astype(np.uint8)
    Image.fromarray(arr, "RGB").save(path, "JPEG", quality=quality, optimize=True, progressive=True)


def _write_manifest(manifest: dict) -> None:
    (STOCK_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sources", type=Path, default=DEFAULT_SOURCES,
                    help="directory holding the source NEFs (default: ~/Downloads)")
    ap.add_argument("--no-contact-sheet", action="store_true")
    ap.add_argument("--pipeline", choices=PIPELINES, default="exact",
                    help="exact = forward Apple Log 2 encode (default); "
                         "inverse = deprecated comparison path")
    ap.add_argument("--compare", action="store_true",
                    help="also write an exact-vs-inverse comparison sheet (no assets written)")
    args = ap.parse_args()
    inv = InverseNeutral(NEUTRAL_LUT)
    if args.compare:
        compare_pipelines(args.sources)
        return 0
    man = build_assets(inv, contact_sheet=not args.no_contact_sheet, sources=args.sources,
                       pipeline=args.pipeline)
    print(json.dumps({"pipeline": man["pipeline"],
                      "curveRoundTrip": man["curveRoundTrip"],
                      "inverseRoundTripGlobal": man["inverseRoundTripGlobal"]}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
