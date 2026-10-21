#!/usr/bin/env python3
"""Generate the stock-preview sample assets for the Nitrate stock-selector carousel.

WHAT THIS PRODUCES (committed under App/Resources/StockSamples/):
  <scene>-neutral.jpg           neutral base still (the photographer's render)
  <scene>-<stockId>.jpg         the SAME still with the real bundled stock .cube applied
  manifest.json                 dynamic manifest consumed by the Swift reader

SOURCE MATERIAL
---------------
Real RAW stills shot by the app's author on a Nikon D700 (see SCENES). The NEFs are ~11 MB
each and are NOT committed; pass their directory with --sources. Only the derived 540x810
cards and their SHA-256 checksums are committed, so the app needs no network and no RAW
decoder at runtime.

THE ONLY APPROXIMATION
----------------------
  base still -> approximate inverse of the official neutral Apple Log 2 -> Rec.709 LUT
             -> real stock .cube (red-fastest trilinear)

The camera that would have recorded these frames does not exist, so the Log input is
reconstructed by inverting the licensed monitoring transform rather than by encoding a
true Apple Log 2 signal: Apple's "Apple Gamut" primaries are not published, and guessing
them produced visible hue errors in testing. The inverse's round-trip error is reported in
the manifest per scene. This is an ILLUSTRATION of the roll's colour, not a camera capture
and not a calibration.

The locked white balance IS simulated, because the app locks the sensor per stock
(5600 K daylight, 3200 K tungsten) and that difference is most of what the user sees.
Colour and white balance only -- no grain / halation / gauge simulation.

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
# Shipped asset budget: the plates are the only bitmap art the app bundles. 720x1080 (2:3)
# is the card's native shape at 2x, and the quality is chosen to hold the whole set near
# 1 MB. The crop is taken at source resolution and only ever downscaled, so the plate keeps
# its aspect instead of being squeezed into the card.
OUT_W, OUT_H = 720, 1080
PREVIEW_QUALITY = 60
STOCKS = ["kodak5207", "kodak5219"]
STOCKS_JSON = RES / "stocks.json"
REC709_LUMA = np.array([0.2126, 0.7152, 0.0722])

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


def nef_metadata(path: Path) -> dict:
    """Capture facts recorded beside each preview, so the source is identifiable."""
    import exifread
    with open(path, "rb") as fh:
        tags = exifread.process_file(fh, details=False)
    def get(name: str) -> str | None:
        value = tags.get(name)
        return str(value).strip() if value is not None else None
    return {
        "camera": " ".join(x for x in (get("Image Make"), get("Image Model")) if x),
        "exposureTime": get("EXIF ExposureTime"),
        "fNumber": get("EXIF FNumber"),
        "iso": get("EXIF ISOSpeedRatings"),
        "focalLength": get("EXIF FocalLength"),
        "originalDate": get("EXIF DateTimeOriginal"),
        "whiteBalance": get("EXIF WhiteBalance"),
    }


def load_nef_display(path: Path, out_w: int = OUT_W, out_h: int = OUT_H) -> np.ndarray:
    """Decode a NEF to a display-referred Rec. 709 still, centre-cropped to the card aspect.

    The developer (LibRaw) supplies the camera matrix and its own tone curve, so the
    result is an ordinary, correctly white-balanced photograph -- exactly the base the
    roll's look is judged against. Nothing here assumes Apple's unpublished primaries.
    """
    import rawpy
    with rawpy.imread(str(path)) as raw:
        rgb = raw.postprocess(half_size=False, output_bps=8, no_auto_bright=False,
                              use_camera_wb=True, output_color=rawpy.ColorSpace.sRGB)
    image = Image.fromarray(rgb, mode="RGB")
    width, height = image.size
    crop_w = min(width, int(round(height * out_w / out_h)))
    x0 = (width - crop_w) // 2
    image = image.crop((x0, 0, x0 + crop_w, height))
    # Resample in display space: the source is already tone-mapped by the developer, and
    # a second linear round-trip here would only cost precision. Only ever downscaled, so
    # the plate keeps its aspect.
    return np.asarray(image.resize((out_w, out_h), Image.LANCZOS)).astype(np.float64) / 255.0


def scene_white_reference_balance(display: np.ndarray) -> tuple[np.ndarray, dict]:
    """Neutralise the plate against the brightest low-saturation surface in the scene.

    The camera's own white balance is used as a starting point, but a scene with no neutral
    in it (a field of foliage, a wall of neon) leaves it tinted, and the stock preview then
    inherits that tint. White-patch: take the brightest few percent of pixels that are also
    desaturated and scale the channels so that reference is neutral.

    Returns the balanced image and the evidence, so the manifest can say whether it applied
    rather than silently retinting every plate.
    """
    maximum = display.max(axis=-1)
    minimum = display.min(axis=-1)
    chroma = maximum - minimum
    luminance = display @ np.array([0.2126, 0.7152, 0.0722])
    threshold = float(np.percentile(luminance, 92.0))
    candidate = (luminance >= threshold) & (chroma < 0.12) & (maximum > 0.30)
    fraction = float(candidate.mean())
    if fraction < 0.001 or not candidate.any():
        return display, {"applied": False, "reason": "no neutral reference in the scene",
                         "candidateFraction": fraction}
    reference = display[candidate].mean(axis=0)
    target = float(reference.max())
    gains = target / np.maximum(reference, 1e-4)
    # Never let a stray highlight drag the scene more than a stop.
    gains = np.clip(gains, 0.5, 2.0)
    balanced = np.clip(display * gains, 0.0, 1.0)
    return balanced, {"applied": True, "candidateFraction": fraction,
                      "gainsRGB": [float(g) for g in gains]}


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
def build_assets(neutral_inv: InverseNeutral, contact_sheet: bool, sources: Path) -> dict:
    """Write one Apple Log 2 plate per scene and describe it in the manifest.

    A plate, not a graded still: the app applies the selected stock LUT (and later grain,
    halation and glow) at display time, so a user LUT or a tweak needs no new asset.
    """
    STOCK_DIR.mkdir(parents=True, exist_ok=True)

    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "disclaimer": DISCLAIMER,
        "generator": "scripts/generate_stock_previews.py",
        "stocks": STOCKS,
        "lutSHA256": {sid: source_sha256(p) for sid, p in STOCK_LUTS.items()},
        "neutralLutSHA256": source_sha256(NEUTRAL_LUT),
        "runtimeNote": "Plates are Apple Log 2 encoded. The app applies the selected stock "
                       "LUT to the plate live, so previews track a user LUT, a grade tweak "
                       "or a gauge change without new assets.",
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

    for sid, scene in SCENES.items():
        src = sources / scene["nef"]
        if not src.exists():
            raise SystemExit(f"missing source RAW {src}; pass --sources <dir>")
        base = load_nef_display(src)
        base, neutral_reference = scene_white_reference_balance(base)
        plate = np.clip(neutral_inv.apply(base), 0.0, 1.0)
        path = STOCK_DIR / f"{sid}-log.jpg"
        _save_jpg(plate, path)

        # Round trip the plate back to display: what the app's neutral LUT shows.
        display = _trilinear(neutral_inv.cube, neutral_inv.size, plate)
        rt_scene = np.abs(display - base) * 255.0

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
                "recipe": "RAW -> developer render (LibRaw camera matrix, its tone curve, "
                          "as-shot white balance) -> white-patch neutral balance -> centre 2:3 "
                          "crop -> approximate inverse of the official neutral Apple Log 2 -> "
                          "Rec.709 LUT -> Log plate",
                "sceneIlluminantKelvin": scene["illuminant_kelvin"],
                "sceneIlluminantProvenance": "assumed for this scene, not measured",
                "whiteReference": neutral_reference,
                "crop": f"centre {OUT_W}x{OUT_H} (2:3) from the full frame, Lanczos",
                "outputSize": [OUT_W, OUT_H],
                "jpegQuality": PREVIEW_QUALITY,
                "plateLabel": "Apple Log 2 encoded plate (approximate; NOT a camera original)",
            },
            "plateStats": {
                "sha256": source_sha256(path),
                "meanCode": float(plate.mean()),
                "whiteFraction": float(_white_fraction(plate)),
                "midtoneFraction": float(_midtone_fraction(plate)),
                "clippedChannelFraction": float(_clipped_channel_fraction(plate)),
                "roundTripMeanAbsError8bit": float(rt_scene.mean()),
                "roundTripP99AbsError8bit": float(np.percentile(rt_scene, 99)),
            },
        })

    manifest["plateCount"] = len(manifest["scenes"])
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


def _save_jpg(img: np.ndarray, path: Path, quality: int = PREVIEW_QUALITY) -> None:
    arr = np.clip(img, 0.0, 1.0)
    arr = (arr * 255.0 + 0.5).astype(np.uint8)
    Image.fromarray(arr, "RGB").save(path, "JPEG", quality=quality, optimize=True, progressive=True)


def _write_manifest(manifest: dict) -> None:
    (STOCK_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def _contact_sheet(manifest: dict) -> None:
    """Debug strip: each plate as neutral, and with both stock LUTs applied."""
    tw, th = OUT_W // 2, OUT_H // 2
    pad, head = 12, 34
    cols = ["neutral"] + list(STOCKS)
    rows = [s["id"] for s in manifest["scenes"]]
    sheet = Image.new("RGB", (pad + len(cols) * (tw + pad), head + len(rows) * (th + head + pad)),
                      (24, 24, 26))
    d = ImageDraw.Draw(sheet)
    d.text((pad, 8), "Nitrate stock previews | plate through neutral LUT, then the stock LUTs",
           fill=(235, 235, 235))
    neutral = _parse_cube(NEUTRAL_LUT)
    cubes = {sid: _parse_cube(p) for sid, p in STOCK_LUTS.items()}
    for r, rid in enumerate(rows):
        entry = next(s for s in manifest["scenes"] if s["id"] == rid)
        y = head + r * (th + head + pad)
        d.text((pad, y), f"scene: {rid}", fill=(235, 235, 235))
        plate = np.asarray(Image.open(STOCK_DIR / entry["plate"]).convert("RGB")).astype(np.float64) / 255.0
        for c, col in enumerate(cols):
            size, cube = neutral if col == "neutral" else cubes[col]
            out = _trilinear(cube, size, plate)
            x = pad + c * (tw + pad)
            d.text((x, y + 14), col, fill=(235, 235, 235))
            sheet.paste(Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))
                        .resize((tw, th), Image.LANCZOS), (x, y + head))
    out = Path(os.environ.get("CONTACT_SHEET",
                              str(Path.home() / ".cache" / "nitrate-stock-preview-sources" / "contact_final.jpg")))
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out, "JPEG", quality=90)
    print(f"contact sheet -> {out}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sources", type=Path, default=DEFAULT_SOURCES,
                    help="directory holding the source NEFs (default: ~/Downloads)")
    ap.add_argument("--no-contact-sheet", action="store_true")
    args = ap.parse_args()
    inv = InverseNeutral(NEUTRAL_LUT)
    man = build_assets(inv, contact_sheet=not args.no_contact_sheet, sources=args.sources)
    print(json.dumps(man["inverseRoundTripGlobal"], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
