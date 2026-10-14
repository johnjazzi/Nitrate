"""Render a synthetic test chart through LUTs so the look can be judged visually.

Test patches are authored in linear Rec.709 (a real, bounded scene gamut) and
converted to linear Apple Wide Gamut, then encoded as Apple Log 2 - i.e. exactly
the kind of signal the iPhone hands the LUT. Authoring patches directly in Apple
Wide Gamut was wrong: its blue primary has y = -0.076, so a blue-dominant AWG
triplet produces negative XYZ, which is not scene data. The first chart built
that way made every saturated blue look broken.

Lookup uses the app's row order: r + g*size + b*size^2 (red fastest).
"""

from __future__ import annotations

import sys
from pathlib import Path

import colour
import numpy as np
from PIL import Image

import generate as g
from verify_cubes import load_app_convention

AL = g

REC709_TO_XYZ = np.asarray(
    colour.RGB_COLOURSPACES["ITU-R BT.709"].matrix_RGB_to_XYZ, dtype=np.float64
)
AWG_TO_XYZ = np.asarray(AL.APPLE_WIDE_GAMUT.matrix_RGB_to_XYZ, dtype=np.float64)
XYZ_TO_AWG = np.linalg.inv(AWG_TO_XYZ)


def rec709_linear_to_awg(rec709_linear: np.ndarray) -> np.ndarray:
    xyz = np.asarray(rec709_linear, dtype=np.float64) @ REC709_TO_XYZ.T
    return xyz @ XYZ_TO_AWG.T


def apple_log_encode(linear: np.ndarray) -> np.ndarray:
    linear = np.asarray(linear, dtype=np.float64)
    log_segment = AL.AL_DELTA + AL.AL_GAMMA * np.log2(np.clip(linear + AL.AL_BETA, 1e-9, None))
    linear_segment = AL.AL_C * (linear - AL.AL_R0) ** 2
    return np.where(linear >= AL.AL_RT, log_segment, linear_segment)


# Scene patches, authored in linear Rec.709.
PATCHES = {
    "white 100": (1.0, 1.0, 1.0),
    "neutral 90": (0.9, 0.9, 0.9),
    "neutral 60": (0.6, 0.6, 0.6),
    "neutral 36": (0.36, 0.36, 0.36),
    "18% gray": (0.18, 0.18, 0.18),
    "neutral 6": (0.06, 0.06, 0.06),
    "black": (0.005, 0.005, 0.005),
    "skin light": (0.62, 0.44, 0.36),
    "skin deep": (0.20, 0.12, 0.09),
    "sky": (0.12, 0.30, 0.62),
    "foliage": (0.10, 0.22, 0.08),
    "red sat": (0.60, 0.05, 0.05),
    "green sat": (0.05, 0.60, 0.05),
    "blue sat": (0.05, 0.05, 0.60),
    "yellow sat": (0.60, 0.55, 0.05),
    "cyan sat": (0.05, 0.55, 0.60),
    "magenta sat": (0.60, 0.05, 0.55),
    "tungsten warm": (0.55, 0.30, 0.14),
    "shade cool": (0.14, 0.22, 0.40),
    "highlight": (1.6, 1.6, 1.6),
}


def patches_to_log2(patches: dict[str, tuple[float, float, float]]) -> np.ndarray:
    rec709 = np.array(list(patches.values()), dtype=np.float64)
    return apple_log_encode(rec709_linear_to_awg(rec709))


def apply_lut(table: np.ndarray, log2_rgb: np.ndarray) -> np.ndarray:
    """Trilinear lookup; table indexed [r, g, b]."""
    size = table.shape[0]
    x = np.clip(log2_rgb, 0.0, 1.0) * (size - 1)
    r, gg, b = x[..., 0], x[..., 1], x[..., 2]
    r0 = np.clip(np.floor(r).astype(int), 0, size - 2)
    g0 = np.clip(np.floor(gg).astype(int), 0, size - 2)
    b0 = np.clip(np.floor(b).astype(int), 0, size - 2)
    rf, gf, bf = r - r0, gg - g0, b - b0
    out = np.zeros(log2_rgb.shape[:-1] + (3,))
    for dr in (0, 1):
        wr = rf if dr else 1 - rf
        for dg in (0, 1):
            wg = gf if dg else 1 - gf
            for db in (0, 1):
                wb = bf if db else 1 - bf
                out += (wr * wg * wb)[..., None] * table[r0 + dr, g0 + dg, b0 + db]
    return out


def encode_gamma24(linear_rec709: np.ndarray) -> np.ndarray:
    return np.clip(linear_rec709, 0.0, 1.0) ** (1 / 2.4)


def render(lut_path: Path, out_path: Path, columns: int = 5) -> dict:
    size, table = load_app_convention(lut_path)
    names = list(PATCHES)
    cell = 56
    rows = (len(names) + columns - 1) // columns
    log2 = patches_to_log2(PATCHES)
    out = apply_lut(table, log2)

    chart = np.zeros((rows * cell, columns * cell, 3))
    encoded = (encode_gamma24(out) * 255).round().astype(np.uint8)
    for index in range(len(names)):
        row, col = divmod(index, columns)
        chart[row * cell:(row + 1) * cell, col * cell:(col + 1) * cell] = encoded[index]
    Image.fromarray(chart.astype(np.uint8)).save(out_path)

    index_of = {name: i for i, name in enumerate(names)}
    neutral = out[[index_of["18% gray"], index_of["neutral 36"],
                   index_of["neutral 60"], index_of["neutral 90"]]]
    sat = {
        key: float(out[index_of[key]].max() - out[index_of[key]].min())
        for key in ("red sat", "green sat", "blue sat", "cyan sat", "magenta sat")
    }
    return {"size": size, "neutral": neutral, "saturation": sat,
            "min": float(table.min()), "max": float(table.max()),
            "xyz_min": float(np.asarray(
                np.asarray(list(PATCHES.values())) @ REC709_TO_XYZ.T).min())}


if __name__ == "__main__":
    out_dir = Path("preview")
    out_dir.mkdir(exist_ok=True)
    app_luts = Path(__file__).resolve().parents[2] / "App" / "Resources" / "LUTs"
    source_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("out-over")
    targets = [
        ("mine 250D", source_dir / "250D K2383 - Apple Log 2.cube"),
        ("mine 500T", source_dir / "500T K2383 - Apple Log 2.cube"),
        ("shipped 250D", app_luts / "250D K2383 - Apple Log 2.cube"),
        ("shipped 500T", app_luts / "500T K2383 - Apple Log 2.cube"),
    ]
    reports = {}
    for label, path in targets:
        if not path.exists():
            print(f"skip {label}: {path} missing")
            continue
        dest = out_dir / f"{label.replace(' ', '_')}.png"
        report = render(path, dest)
        reports[label] = report
        print(f"{label}: {dest}   (min XYZ over patches {report['xyz_min']:.4f})")
        print("   neutral 18/36/60/90%: "
              + " | ".join("/".join(f"{v:.3f}" for v in row) for row in report["neutral"]))
        print("   saturation spread: "
              + ", ".join(f"{k} {v:.3f}" for k, v in report["saturation"].items()))

    images = [Image.open(out_dir / f"{label.replace(' ', '_')}.png") for label in reports]
    if images:
        width = sum(i.width for i in images) + 8 * (len(images) - 1)
        combined = Image.new("RGB", (width, max(i.height for i in images)), (16, 16, 16))
        x = 0
        for image in images:
            combined.paste(image, (x, 0))
            x += image.width + 8
        combined.save(out_dir / "comparison.png")
        print(f"\ncomparison -> {out_dir / 'comparison.png'} (order: {', '.join(reports)})")
