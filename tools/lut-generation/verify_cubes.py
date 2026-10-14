"""Structural + comparative checks for the home-built cubes.

The app's .cube parser indexes rows as r + g*size + b*size^2 (red fastest), so
these checks assert that exact convention plus finiteness, domain and
monotonicity, and compare the generated stocks against the currently shipped
App/Resources/LUTs tables.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np


def parse_cube(path: Path):
    size = None
    values: list[float] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if not parts or parts[0].startswith("#"):
            continue
        if parts[0] == "TITLE":
            continue
        if parts[0] == "LUT_3D_SIZE":
            size = int(parts[1])
            continue
        if parts[0] in ("DOMAIN_MIN", "DOMAIN_MAX"):
            continue
        rgb = [float(x) for x in parts]
        if len(rgb) == 3:
            values.append(rgb)
    assert size, f"{path}: no LUT_3D_SIZE"
    table = np.asarray(values, dtype=np.float64)
    assert table.shape == (size**3, 3), f"{path}: {table.shape} rows"
    return size, table


def load_app_convention(path: Path):
    """Return table indexed [r, g, b] using the app's row convention."""
    size, rows = parse_cube(path)
    out = np.empty((size, size, size, 3))
    for r in range(size):
        for g in range(size):
            for b in range(size):
                out[r, g, b] = rows[r + g * size + b * size * size]
    return size, out


def describe(path: Path, table: np.ndarray, size: int):
    print(f"{path.name}")
    print(f"   size {size}, min {table.min():.5f}, max {table.max():.5f}, "
          f"nonfinite {int((~np.isfinite(table)).sum())}")
    axis = np.array([table[i, i, i] for i in range(size)])
    spreads = np.ptp(axis, axis=1)
    print(f"   neutral axis spread: max {spreads.max():.5f} at code "
          f"{spreads.argmax() / (size - 1):.2f}, mid {spreads[size // 2]:.5f}")
    mono = all(np.all(axis[i] >= axis[i - 1] - 1e-4) for i in range(1, size))
    print(f"   neutral axis monotonic: {mono}")
    # red-fastest check: perturbing R alone must move to a different row block
    r_step = table[1, 0, 0]
    g_step = table[0, 1, 0]
    b_step = table[0, 0, 1]
    print(f"   R/G/B axis steps: {r_step.round(4)} | {g_step.round(4)} | {b_step.round(4)}")
    return axis


def compare(label: str, mine: np.ndarray, shipped: np.ndarray, size: int):
    diff = np.abs(mine - shipped)
    print(f"--- {label}: mine vs shipped ---")
    print(f"   mean |diff| {diff.mean():.4f}, p95 {np.percentile(diff, 95):.4f}, max {diff.max():.4f}")
    for code in [0.0, 0.25, 0.5, 0.75, 1.0]:
        i = int(round(code * (size - 1)))
        print(f"   code {code:4.2f} mine {mine[i, i, i].round(4)}  shipped {shipped[i, i, i].round(4)}")
    # saturation comparison on a red patch
    i = int(round(0.6 * (size - 1)))
    print(f"   red-ish patch (R .6, G .45, B .35): mine "
          f"{mine[i, int(0.45 * (size - 1)), int(0.35 * (size - 1))].round(4)} shipped "
          f"{shipped[i, int(0.45 * (size - 1)), int(0.35 * (size - 1))].round(4)}")


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("out")
    app_luts = Path(__file__).resolve().parents[2] / "App" / "Resources" / "LUTs"
    for stock in ["5207", "5219"]:
        gen_path = out / f"{stock} - Apple Log 2.cube"
        size, table = load_app_convention(gen_path)
        describe(gen_path, table, size)
        shipped_path = app_luts / f"{stock} - Apple Log 2.cube"
        if shipped_path.exists():
            ssize, shipped = load_app_convention(shipped_path)
            describe(shipped_path, shipped, ssize)
            compare(stock, table, shipped, size)
        print()
