#!/usr/bin/env python3
"""Generate halation branding. Run with pinned numpy/Pillow for identical PNGs.

uv run --with numpy==2.2.6 --with pillow==11.2.1 python scripts/generate_branding.py
Tests: use the same uv prefix with python -m unittest scripts.test_generate_branding.
"""

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "App/Resources/Branding.xcassets"


def generate(output):
    """Write one grainy halation mark, its black icon, and centered launch image.

    The source mask preserves the original reel silhouette and five cutouts.
    All presentations reuse its luminous body, grain, and soft red edge spill.
    A local fixed-seed generator avoids changes from unrelated random state.
    """
    size = 1024
    y, x = np.mgrid[:size, :size].astype(np.float64)
    x = (x - (size - 1) / 2) / size
    y = (y - (size - 1) / 2) / size
    radius = np.hypot(x, y)
    angle = np.arctan2(y, x)
    mask_image = Image.open(ROOT / "scripts/branding/film-reel-mask.png").convert("L")
    mask = np.asarray(mask_image, dtype=np.float64) / 255
    soft = np.asarray(mask_image.filter(ImageFilter.GaussianBlur(5)), dtype=np.float64) / 255
    bloom = np.asarray(mask_image.filter(ImageFilter.GaussianBlur(18)), dtype=np.float64) / 255
    wide = np.asarray(mask_image.filter(ImageFilter.GaussianBlur(34)), dtype=np.float64) / 255
    # The reel stays filled; donut-like exposure shading changes its material,
    # not its geometry. Cutout centers stay dark while their edges spill red.
    rim = np.exp(-0.5 * ((radius - 0.335) / 0.075) ** 2)
    exposure = 0.87 + 0.13 * np.cos(angle + 0.7)
    body = (0.48 + 0.45 * rim) * exposure
    glow = soft * body + (1 - mask) * (0.34 * bloom + 0.06 * wide)
    grain = np.random.default_rng(1964).normal(0, 0.07, (size, size))
    alpha = np.clip(glow * (1 + grain), 0, 1)
    rgba = np.zeros((size, size, 4), dtype=np.uint8)
    rgba[:, :, 0] = 255
    rgba[:, :, 1] = np.rint(28 + 56 * rim * soft).astype(np.uint8)
    rgba[:, :, 2] = np.rint(4 + 6 * rim * soft).astype(np.uint8)
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
