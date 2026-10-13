#!/usr/bin/env python3
"""Generate halation branding. Run with pinned numpy/Pillow for identical PNGs.

uv run --with numpy==2.2.6 --with pillow==11.2.1 python scripts/generate_branding.py
Tests: use the same uv prefix with python -m unittest scripts.test_generate_branding.
"""

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "App/Resources/Branding.xcassets"


def generate(output):
    """Write one grainy halation mark, its black icon, and centered launch image.

    Alpha carries the soft exposure bloom, including its dark central aperture.
    All presentations reuse this mark; no reel holes, lettering, or hard outlines.
    A local fixed-seed generator avoids changes from unrelated random state.
    """
    size = 1024
    y, x = np.mgrid[:size, :size].astype(np.float64)
    x = (x - (size - 1) / 2) / size
    y = (y - (size - 1) / 2) / size
    radius = np.hypot(x, y)
    angle = np.arctan2(y, x)
    # Slightly uneven exposure/radius keeps this photographic, not a vector ring.
    ring_radius = 0.28 + 0.004 * np.sin(3 * angle + 0.6)
    distance = radius - ring_radius
    core = np.exp(-0.5 * (distance / 0.028) ** 2)
    bloom = np.exp(-0.5 * (distance / 0.060) ** 2)
    exposure = 0.80 + 0.20 * np.cos(angle + 0.7)
    glow = (0.79 * core + 0.21 * bloom) * exposure
    # Smooth inner/outer gates make the aperture and outer canvas truly empty.
    inner = np.clip((radius - 0.13) / 0.06, 0, 1)
    outer = np.clip((0.49 - radius) / 0.06, 0, 1)
    gate = (inner * inner * (3 - 2 * inner)) * (outer * outer * (3 - 2 * outer))
    grain = np.random.default_rng(1964).normal(0, 0.09, (size, size))
    alpha = np.clip(glow * gate * (1 + grain), 0, 1)
    rgba = np.zeros((size, size, 4), dtype=np.uint8)
    rgba[:, :, 0] = 255
    rgba[:, :, 1] = np.rint(30 + 65 * core * (0.75 + 0.25 * np.cos(angle + 0.7))).astype(np.uint8)
    rgba[:, :, 2] = np.rint(3 + 7 * core).astype(np.uint8)
    rgba[:, :, 3] = np.rint(alpha * 255).astype(np.uint8)
    rgba[rgba[:, :, 3] == 0, :3] = 0
    logo = Image.fromarray(rgba)
    icon = Image.new("RGB", logo.size)
    icon.paste(logo, mask=logo.getchannel("A"))
    launch = Image.new("RGB", (430, 932))
    small = logo.resize((240, 240), Image.Resampling.LANCZOS)
    launch.paste(small, (95, 346), small.getchannel("A"))
    for name, image in (
        ("AppIcon.appiconset/app-icon.png", icon),
        ("HalationLogo.imageset/halation-logo.png", logo),
        ("LaunchArtwork.imageset/splash-screen.png", launch),
    ):
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        image.save(target, compress_level=9)
        print(target)
    contents = {
        "images": [{"filename": "halation-logo.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }
    (output / "HalationLogo.imageset/Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    generate(parser.parse_args().output)
