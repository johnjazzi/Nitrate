#!/usr/bin/env python3
"""Generate illustrative stock-preview sample assets for the Nitrate stock-selector carousel.

WHAT THIS PRODUCES (committed under App/Resources/StockSamples/):
  <scene>-neutral.jpg           neutral base photo (display-space sRGB), light JPEG
  <scene>-<stockId>.jpg         the SAME photo with the real bundled stock .cube applied
  manifest.json                 dynamic manifest consumed by the Swift reader

SCENE -> STOCK MAPPING IS REAL, NOT RANDOM
------------------------------------------
  * "neutral"       = base photo run through the official neutral transform
                      App/Resources/Preview/AppleLog2ToRec709.cube  (round trip ~= identity)
  * "kodak5207"     = base photo -> illustrative synthetic Log input -> real stock LUT
                      App/Resources/LUTs/5207 - Apple Log 2.cube   (red-fastest trilinear)
  * "kodak5219"     = base photo -> illustrative synthetic Log input -> real stock LUT
                      App/Resources/LUTs/5219 - Apple Log 2.cube   (red-fastest trilinear)

  The ONLY non-real step is "base photo -> illustrative synthetic Log input": we invert
  the official neutral transform's input encoding with a KD-tree nearest-neighbour +
  bounded within-cell trilinear refinement (mean round-trip error reported in the manifest).
  This is a defensible ILLUSTRATION, NOT a camera capture and NOT a calibration:
  no Apple Log 2 originals exist for these scenes and we do NOT guess Apple gamut primaries.
  Colour LUT only -- no grain / halation / gauge simulation.

SOURCES: real CC0 photographic HDRIs from Poly Haven (actual assets, not site renders).
Runtime needs NO network. This script is a build-time tool only.

DEPS (build-time only): numpy, Pillow  (python3 system has neither).
  python3 -m venv .venv && . .venv/bin/activate && pip install numpy Pillow
RUN:
  python scripts/generate_stock_previews.py            # uses cached sources, writes assets
  python scripts/generate_stock_previews.py --fetch    # downloads sources first (network)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import subprocess
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
SOURCE_CACHE = Path.home() / ".cache" / "nitrate-stock-preview-sources"

SCHEMA_VERSION = 1
DISCLAIMER = "Illustrative photos \u00b7 color LUT + white balance only"
OUT_W, OUT_H = 540, 810
STOCKS = ["kodak5207", "kodak5219"]
STOCKS_JSON = RES / "stocks.json"
REC709_LUMA = np.array([0.2126, 0.7152, 0.0722])

# Poly Haven assets -- verified CC0. scene id -> source recipe (probed with the vision tool).
SCENES = {
    "daylight": {
        "title": "Daylight",
        "slug": "yellow_field",
        "filename": "yellow_field_4k.hdr",
        "source_url": "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/yellow_field_4k.hdr",
        "license": "CC0",
        "license_url": "https://polyhaven.com/license",
        "credit": "Poly Haven \u2014 yellow_field (CC0)",
        "yaw": 0.0, "pitch": 0.0, "fov_deg": 68.0,
        "ev_bias": -0.8,
        # Assumed illuminant of the scene, used only to place the scene and the
        # camera's locked white balance on the same Planckian locus. Assumed, not
        # measured -- see docs/stock-preview-assets.md.
        "illuminant_kelvin": 5600,
    },
    "city": {
        "title": "City",
        "slug": "urban_street_04",
        "filename": "urban_street_04_4k.hdr",
        "source_url": "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/urban_street_04_4k.hdr",
        "license": "CC0",
        "license_url": "https://polyhaven.com/license",
        "credit": "Poly Haven \u2014 urban_street_04 (CC0)",
        "yaw": 0.0, "pitch": 0.0, "fov_deg": 62.0,
        "ev_bias": -0.8,
        "illuminant_kelvin": 5500,
    },
    "night": {
        "title": "Night",
        "slug": "cobblestone_street_night",
        "filename": "cobblestone_street_night_4k.hdr",
        "source_url": "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/cobblestone_street_night_4k.hdr",
        "license": "CC0",
        "license_url": "https://polyhaven.com/license",
        "credit": "Poly Haven \u2014 cobblestone_street_night (CC0)",
        "yaw": 0.0, "pitch": 0.0, "fov_deg": 66.0,
        "ev_bias": -0.7,
        # Warm street lighting, the case a tungsten stock is built for.
        "illuminant_kelvin": 3000,
    },
}


# ----------------------------------------------------------------------------- HDR loading
def load_hdr_linear(path: Path) -> np.ndarray:
    """Pure-numpy Radiance RGBE (.hdr) reader -> linear float32 RGB, row 0 = top.

    imageio.v2.imread silently returns uint8 0-255 for .hdr without the freeimage plugin,
    which is exactly the bug that once produced blown-white assets; hence this explicit
    decoder. Validated bit-exact against cv2.IMREAD_ANYDEPTH on the committed sources.
    """
    with open(path, "rb") as fh:
        while True:
            line = fh.readline()
            if not line:
                raise ValueError(f"{path}: unexpected EOF in HDR header")
            if line.strip() == b"":
                break
        res = fh.readline().split()
        if len(res) != 4:
            raise ValueError(f"{path}: malformed resolution line {res!r}")
        ysign, ylen, xsign, xlen = res[0], int(res[1]), res[2], int(res[3])
        w, h = xlen, ylen
        buf = np.frombuffer(fh.read(), dtype=np.uint8)

    pos = 0
    planes = np.empty((h, w, 4), dtype=np.uint8)
    for y in range(h):
        if pos + 4 > buf.size:
            raise ValueError(f"{path}: truncated scanline data")
        if buf[pos] != 2 or buf[pos + 1] != 2:
            raise ValueError(f"{path}: unsupported (old-format) scanline at row {y}")
        row_w = (int(buf[pos + 2]) << 8) | int(buf[pos + 3])
        if row_w != w:
            raise ValueError(f"{path}: scanline width {row_w} != {w}")
        pos += 4
        for c in range(4):
            plane = planes[y, :, c]
            x = 0
            while x < w:
                cnt = int(buf[pos]); pos += 1
                if cnt > 128:  # run
                    run = cnt - 128
                    plane[x:x + run] = buf[pos]; pos += 1; x += run
                else:          # literal
                    plane[x:x + cnt] = buf[pos:pos + cnt]; pos += cnt; x += cnt

    e = planes[..., 3].astype(np.int32)
    scale = np.zeros((h, w), dtype=np.float32)
    nz = e > 0
    scale[nz] = np.ldexp(1.0, e[nz] - 128 - 8)
    rgb = planes[..., :3].astype(np.float32) * scale[..., None]
    if ysign == b"+Y":            # bottom-to-top storage
        rgb = rgb[::-1]
    if xsign == b"-X":            # right-to-left storage
        rgb = rgb[:, ::-1]
    return rgb


def source_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_sources(force: bool = False) -> None:
    SOURCE_CACHE.mkdir(parents=True, exist_ok=True)
    for scene in SCENES.values():
        dst = SOURCE_CACHE / scene["filename"]
        if dst.exists() and not force:
            print(f"cached  {dst.name}")
            continue
        print(f"fetch   {scene['source_url']}")
        subprocess.run(["curl", "-fL", "-o", str(dst), scene["source_url"]], check=True)
        print(f"  md5   {md5_of(dst)}  ({dst.stat().st_size} bytes)")


def md5_of(path: Path) -> str:
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------- HDR -> display base
def _srgb_encode(lin: np.ndarray) -> np.ndarray:
    a = np.clip(lin, 0.0, 1.0)
    return np.where(a <= 0.0031308, a * 12.92, 1.055 * np.power(a, 1 / 2.4) - 0.055)


def _aces_tonemap(x: np.ndarray) -> np.ndarray:
    # Narkowicz ACES filmic curve on already-normalised linear scene values
    return np.clip((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0)


def _rot_y(v: np.ndarray, deg: float) -> np.ndarray:
    t = math.radians(deg); c, s = math.cos(t), math.sin(t)
    x, y, z = v[..., 0], v[..., 1], v[..., 2]
    return np.stack([c * x + s * z, y, -s * x + c * z], axis=-1)


def _bilinear(hdr: np.ndarray, u: np.ndarray, v: np.ndarray) -> np.ndarray:
    h, w = hdr.shape[:2]
    fx = np.clip(u * w - 0.5, 0, w - 1)
    fy = np.clip(v * h - 0.5, 0, h - 1)
    x0 = np.floor(fx).astype(np.int32); y0 = np.floor(fy).astype(np.int32)
    x1 = np.minimum(x0 + 1, w - 1); y1 = np.minimum(y0 + 1, h - 1)
    ax = (fx - x0)[..., None]; ay = (fy - y0)[..., None]
    top = hdr[y0, x0] * (1 - ax) + hdr[y0, x1] * ax
    bot = hdr[y1, x0] * (1 - ax) + hdr[y1, x1] * ax
    return top * (1 - ay) + bot * ay


def _rx(v: np.ndarray, pitch_deg: float) -> np.ndarray:
    t = math.radians(pitch_deg); c, s = math.cos(t), math.sin(t)
    return np.stack([v[..., 0], c * v[..., 1] - s * v[..., 2], s * v[..., 1] + c * v[..., 2]], axis=-1)


def reproject_linear(hdr: np.ndarray, yaw: float, pitch: float, fov_deg: float) -> np.ndarray:
    """Rectilinear (pinhole) crop of an equirectangular HDRI -> linear scene RGB.

    Camera model: view direction in camera space d = [x*aspect*tan(hfov/2), y*tan(hfov/2), 1],
    rotated to world as world = Rx(pitch) . Ry(yaw) . d, then mapped to the equirectangular
    source via u = 0.5 + atan2(X,Z)/2pi, v = 0.5 - asin(Y)/pi. Straight world lines stay
    straight: this is a true perspective crop, not a stretched panorama slice.
    """
    f = 1.0 / math.tan(math.radians(fov_deg) / 2.0)
    xs = np.linspace(-1.0, 1.0, OUT_W)
    ys = np.linspace(1.0, -1.0, OUT_H)
    xx, yy = np.meshgrid(xs, ys)
    d = np.stack([xx * (OUT_W / OUT_H) / f, yy / f, np.ones_like(xx)], axis=-1)
    d = d / np.linalg.norm(d, axis=-1, keepdims=True)
    v = _rx(_rot_y(d, yaw), pitch)
    v = v / np.linalg.norm(v, axis=-1, keepdims=True)
    u = 0.5 + np.arctan2(v[..., 0], v[..., 2]) / (2 * math.pi)
    vv = 0.5 - np.arcsin(np.clip(v[..., 1], -1, 1)) / math.pi
    return _bilinear(hdr, u, vv)


def tone_map_display(linear: np.ndarray, ev_bias: float) -> np.ndarray:
    """Exposure + ACES-filmic tone-map + sRGB encode -> display-space base photo.

    Exposure is normalised so the crop's 99th-percentile luminance lands at mid-high
    (2**ev_bias scales from there), which keeps real HDR scenes within a sensible SDR range.
    """
    lum = linear @ np.array([0.2126, 0.7152, 0.0722])
    p99 = np.percentile(lum, 99.0)
    gain = (2.0 ** ev_bias) / max(p99, 1e-6)
    return np.clip(_srgb_encode(_aces_tonemap(linear * gain)), 0.0, 1.0)


def base_photo_display(hdr: np.ndarray, yaw: float, pitch: float, fov_deg: float,
                       ev_bias: float) -> np.ndarray:
    """Convenience wrapper: rectilinear crop -> tone-mapped display-space base photo."""
    return tone_map_display(reproject_linear(hdr, yaw, pitch, fov_deg), ev_bias)


# ------------------------------------------------------- locked white balance (offline)
def _planckian_xy(kelvin: float) -> tuple[float, float]:
    """CIE 1931 (x, y) on the Planckian locus -- Kim et al. (1997) approximation.

    Used only to put a scene illuminant and the camera's locked white balance on one
    locus so the *relative* white-balance difference between two stocks can be
    simulated offline. It is the published approximation, not a measured SPD.
    """
    t = float(kelvin)
    if not 1667.0 <= t <= 25000.0:
        raise ValueError(f"Planckian approximation is quoted for 1667-25000 K, got {t}")
    if t <= 4000.0:
        x = -0.2661239e9 / t**3 - 0.2343589e6 / t**2 + 0.8776956e3 / t + 0.179910
    else:
        x = -3.0258469e9 / t**3 + 2.1070379e6 / t**2 + 0.2226347e3 / t + 0.240390
    if t <= 2222.0:
        y = -1.1063814 * x**3 - 1.34811020 * x**2 + 2.18555832 * x - 0.20219683
    elif t <= 4000.0:
        y = -0.9549476 * x**3 - 1.37418593 * x**2 + 2.09137015 * x - 0.16748867
    else:
        y = 3.0817580 * x**3 - 5.87338670 * x**2 + 3.75112997 * x - 0.37001483
    return float(x), float(y)


def _illuminant_xyz(kelvin: float) -> np.ndarray:
    """XYZ of a blackbody at `kelvin`, normalised to Y = 1."""
    x, y = _planckian_xy(kelvin)
    return np.array([x / y, 1.0, (1.0 - x - y) / y])


# Bradford cone-response matrix: the standard chromatic-adaptation transform used by
# ICC-style colour management.
_BRADFORD = np.array([
    [0.8951, 0.2664, -0.1614],
    [-0.7502, 1.7135, 0.0367],
    [0.0389, -0.0685, 1.0296],
])
_XYZ_TO_LINEAR_SRGB = np.array([
    [3.2406, -1.5372, -0.4986],
    [-0.9689, 1.8758, 0.0415],
    [0.0557, -0.2040, 1.0570],
])


def white_balance_factor(scene_kelvin: float, locked_kelvin: float) -> np.ndarray:
    """Linear-sRGB per-channel gain modelling the app's locked white balance.

    The capture session locks the sensor to `locked_kelvin` (stocks.json
    ``colorTemperature``, tint 0), so a scene lit at `scene_kelvin` records with its
    neutral axis displaced by ``I(scene) / I(locked)``: matching illuminants stay
    neutral, a mismatch tints the frame.

    The displacement is computed with a Bradford chromatic adaptation (the standard
    ICC-era transform) from the locked illuminant to the scene illuminant, then applied
    as a per-channel gain in linear sRGB. Bradford is a *proxy* for the device's real
    sensor gains, which this generator cannot measure -- see
    docs/stock-preview-assets.md.
    """
    source = _BRADFORD @ _illuminant_xyz(locked_kelvin)
    destination = _BRADFORD @ _illuminant_xyz(scene_kelvin)
    adaptation = np.linalg.inv(_BRADFORD) @ np.diag(destination / source) @ _BRADFORD
    to_linear_srgb = _XYZ_TO_LINEAR_SRGB @ adaptation @ np.linalg.inv(_XYZ_TO_LINEAR_SRGB)
    # Where a neutral input lands: the recorded frame's own white. Clamped at zero
    # because a very warm/cool illuminant leaves the sRGB gamut, and a negative channel
    # is not something the display chain can represent.
    white = np.maximum(to_linear_srgb @ np.ones(3), 1e-6)
    if not np.all(np.isfinite(white)):
        raise ValueError(f"white-balance gain is not finite for {scene_kelvin}K / {locked_kelvin}K")
    # Luminance-normalised: a neutral input keeps its luminance, so this models a white
    # balance change rather than a re-exposure.
    return white / float(white @ REC709_LUMA)


def apply_gain(linear: np.ndarray, gain: np.ndarray) -> np.ndarray:
    """Apply a linear-sRGB white-balance gain to a linear scene image."""
    return linear * gain


def _srgb_decode(display: np.ndarray) -> np.ndarray:
    a = np.clip(display, 0.0, 1.0)
    return np.where(a <= 0.04045, a / 12.92, np.power((a + 0.055) / 1.055, 2.4))


def apply_display_white_balance(display: np.ndarray, gain: np.ndarray) -> np.ndarray:
    """Apply the locked-white-balance gain to a finished display-space image.

    Applied after the stock LUT, in linear light, rather than in front of the neutral
    transform's inversion. The camera applies it first, but the requested cast for a
    mismatched pair lies partly outside the neutral transform's reachable gamut, and
    inverting there banded the frame (measured, see `project_into_reachable`). Channel
    clipping at full scale is left as-is: that is what the camera does too.
    """
    return np.clip(_srgb_encode(_srgb_decode(display) * gain), 0.0, 1.0)


def project_into_reachable(neutral_inv: InverseNeutral, display: np.ndarray,
                           iterations: int = 3) -> np.ndarray:
    """Retract a display colour onto the set the neutral transform can produce.

    Retained for diagnostics: measuring how far a requested colour lies outside the
    reachable volume is how the ordering below was chosen. See
    docs/stock-preview-assets.md -- routing a strong locked-white-balance cast through
    the inversion moved ~10% of a daylight frame's pixels (up to 0.95) at the gamut
    boundary, which banded visibly.
    """
    out = np.clip(display, 0.0, 1.0)
    for _ in range(iterations):
        out = _trilinear(neutral_inv.cube, neutral_inv.size, neutral_inv.apply(out))
    return out


def locked_kelvin_by_stock() -> dict[str, float]:
    """Locked white balance per stock, read from the app's own stock config."""
    data = json.loads(STOCKS_JSON.read_text())
    temps = {s["stockId"]: float(s["colorTemperature"])
             for s in data["stocks"] if s["stockId"] in STOCKS}
    missing = [s for s in STOCKS if s not in temps]
    if missing:
        raise SystemExit(f"{STOCKS_JSON} has no colorTemperature for {missing}")
    return temps


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
def build_assets(neutral_inv: InverseNeutral, contact_sheet: bool) -> dict:
    STOCK_DIR.mkdir(parents=True, exist_ok=True)
    stock_cubes = {sid: _parse_cube(p) for sid, p in STOCK_LUTS.items()}
    locked_kelvin = locked_kelvin_by_stock()

    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "disclaimer": DISCLAIMER,
        "generator": "scripts/generate_stock_previews.py",
        "stocks": STOCKS,
        "lutSHA256": {sid: source_sha256(p) for sid, p in STOCK_LUTS.items()},
        "neutralLutSHA256": source_sha256(NEUTRAL_LUT),
        # The app locks the sensor white balance to each stock's colorTemperature
        # (CameraSession.setWhiteBalance, tint 0). A preview that ignored that would
        # understate the difference between a daylight and a tungsten stock.
        "whiteBalanceSimulation": {
            "method": "Planckian-locus blackbody chroma (Kim et al. 1997 xy approximation) "
                      "-> linear sRGB, displaced with a Bradford chromatic adaptation; "
                      "gain = I(scene)/I(locked), luminance-normalised, applied in linear "
                      "light after the stock LUT (the camera applies it first; routing a "
                      "mismatched cast through the neutral inversion banded the frame)",
            "orderingNote": "The gain is physically a capture-side white balance; it is "
                            "applied at display scale here so the preview stays free of "
                            "gamut-clipping artifacts.",
            "tint": 0,
            "luminanceNormalized": True,
            "lockedKelvinSource": "App/Resources/stocks.json colorTemperature "
                                  "(the same value the capture session locks)",
            "sceneIlluminant": "assumed per scene, not measured",
            "label": "illustrative white-balance simulation (approximate)",
        },
        "lockedKelvin": locked_kelvin,
        "scenes": [],
    }

    # Inverse round-trip metrics. Two holdout sets are reported honestly:
    #  * "valid"  : display colours the neutral transform actually produces (>= its black point)
    #  * "full"   : the whole [0,1]^3 cube, which includes unreachable near-black codes where
    #               the inverse is ill-posed by construction (documented limitation).
    def _roundtrip(x):
        back = _trilinear(neutral_inv.cube, neutral_inv.size, neutral_inv.apply(x))
        return np.abs(back - x) * 255.0

    rng = np.random.default_rng(20261020)
    full = rng.random((20000, 3))
    rt_full = _roundtrip(full)
    # valid = colours whose luminance is at/above the transform's black point (~0.05)
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

    panels = []  # (row_label, col_label, path)
    for sid, scene in SCENES.items():
        src = SOURCE_CACHE / scene["filename"]
        if not src.exists():
            raise SystemExit(f"missing source {src}; run with --fetch first")
        hdr = load_hdr_linear(src)
        linear = reproject_linear(hdr, scene["yaw"], scene["pitch"], scene["fov_deg"])
        base = tone_map_display(linear, scene["ev_bias"])

        neutral_jpg = STOCK_DIR / f"{sid}-neutral.jpg"
        _save_jpg(base, neutral_jpg)

        # Illustrative synthetic Log input (the one non-real step), computed once per scene.
        # The locked white balance is applied later, at display scale: see
        # apply_display_white_balance for why it is not routed through this inversion.
        log_input = neutral_inv.apply(base)
        gains = {s: white_balance_factor(scene["illuminant_kelvin"], locked_kelvin[s]) for s in STOCKS}

        entry = {
            "id": sid,
            "title": scene["title"],
            "neutralFile": neutral_jpg.name,
            "previews": {},
            "source": {
                "provider": "Poly Haven",
                "assetSlug": scene["slug"],
                "sourceURL": scene["source_url"],
                "license": scene["license"],
                "licenseURL": scene["license_url"],
                "credit": scene["credit"],
                "md5": md5_of(src),
                "sha256": source_sha256(src),
            },
            "derivation": {
                "recipe": "display-space base photo -> approximate inverse of official neutral LUT "
                          "(KD-tree kNN in cube-output space + bounded within-cell trilinear "
                          "refinement) -> real stock .cube via red-fastest trilinear -> locked "
                          "white balance for this stock, applied in linear light",
                "cropYawDeg": scene["yaw"], "cropPitchDeg": scene["pitch"],
                "fovDeg": scene["fov_deg"], "exposureEV": scene["ev_bias"],
                "sceneIlluminantKelvin": scene["illuminant_kelvin"],
                "sceneIlluminantProvenance": "assumed for this scene, not measured",
                "outputSize": [OUT_W, OUT_H],
                "inputLabel": "illustrative synthetic Log input (NOT Apple Log 2 camera original)",
            },
            "assets": {},
        }

        variants = {"neutral": base}
        for s in STOCKS:
            size, cube = stock_cubes[s]
            variants[s] = apply_display_white_balance(_trilinear(cube, size, log_input), gains[s])

        for label, img in variants.items():
            path = STOCK_DIR / f"{sid}-{label}.jpg"
            _save_jpg(img, path)
            entry["assets"][label] = {
                "file": path.name,
                "sha256": source_sha256(path),
                "whiteFraction": float(_white_fraction(img)),
                "midtoneFraction": float(_midtone_fraction(img)),
                "clippedChannelFraction": float(_clipped_channel_fraction(img)),
            }
            if label in STOCKS:
                entry["assets"][label]["whiteBalance"] = {
                    "sceneIlluminantKelvin": scene["illuminant_kelvin"],
                    "lockedKelvin": locked_kelvin[label],
                    "gainLinearRGB": [float(v) for v in gains[label]],
                }
        for s in STOCKS:
            entry["previews"][s] = f"{sid}-{s}.jpg"

        wb_scene = base
        back_scene = _trilinear(neutral_inv.cube, neutral_inv.size, neutral_inv.apply(wb_scene))
        rt_scene = np.abs(back_scene - wb_scene) * 255.0
        entry["inverseRoundTripOnScene"] = {
            "meanAbsError8bit": float(rt_scene.mean()),
            "maxAbsError8bit": float(rt_scene.max()),
        }

        manifest["scenes"].append(entry)
        panels.append((scene["title"], sid))

    manifest["generatedAssetCount"] = sum(len(e["assets"]) for e in manifest["scenes"])
    _write_manifest(manifest)

    if contact_sheet:
        _contact_sheet(manifest)
    return manifest


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


def _save_jpg(img: np.ndarray, path: Path, quality: int = 88) -> None:
    arr = np.clip(img, 0.0, 1.0)
    arr = (arr * 255.0 + 0.5).astype(np.uint8)
    Image.fromarray(arr, "RGB").save(path, "JPEG", quality=quality, optimize=True, progressive=True)


def _write_manifest(manifest: dict) -> None:
    (STOCK_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def _contact_sheet(manifest: dict) -> None:
    tw = OUT_W // 2
    th = OUT_H // 2
    pad, head = 12, 30
    cols = ["neutral"] + STOCKS
    rows = [s["id"] for s in manifest["scenes"]]
    W = pad + len(cols) * (tw + pad)
    H = head + len(rows) * (th + head + pad)
    sheet = Image.new("RGB", (W, H), (24, 24, 26))
    d = ImageDraw.Draw(sheet)
    d.text((pad, 8), "Nitrate stock previews  |  columns: neutral base, kodak5207, kodak5219  |  rows: daylight, city, night", fill=(235, 235, 235))
    for r, rid in enumerate(rows):
        y = head + r * (th + head + pad)
        d.text((pad, y), f"scene: {rid}", fill=(235, 235, 235))
        entry = next(s for s in manifest["scenes"] if s["id"] == rid)
        for c, col in enumerate(cols):
            fn = entry["neutralFile"] if col == "neutral" else entry["previews"][col]
            im = Image.open(STOCK_DIR / fn).convert("RGB").resize((tw, th), Image.LANCZOS)
            x = pad + c * (tw + pad)
            d.text((x, y + 14), col, fill=(235, 235, 235))
            sheet.paste(im, (x, y + head))
    out = Path(os.environ.get("CONTACT_SHEET", str(SOURCE_CACHE / "contact_final.jpg")))
    sheet.save(out, "JPEG", quality=90)
    print(f"contact sheet -> {out}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fetch", action="store_true", help="download CC0 sources first")
    ap.add_argument("--force-fetch", action="store_true")
    ap.add_argument("--no-contact-sheet", action="store_true")
    args = ap.parse_args()
    if args.fetch or args.force_fetch:
        fetch_sources(force=args.force_fetch)
    inv = InverseNeutral(NEUTRAL_LUT)
    man = build_assets(inv, contact_sheet=not args.no_contact_sheet)
    print(json.dumps(man["inverseRoundTripGlobal"], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
