"""Contract tests for the reproducible halation branding assets."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image


SCRATCH = Path.home() / ".hermes/cache/scratch"


ROOT = Path(__file__).resolve().parent.parent
GENERATOR = ROOT / "scripts/generate_branding.py"


class BrandingTests(unittest.TestCase):
    def test_original_five_cutouts_remain_dark_inside_luminous_reel(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            subprocess.run([sys.executable, str(GENERATOR), "--output", directory], check=True)
            with Image.open(Path(directory) / "AppIcon.appiconset/app-icon.png") as image:
                pixels = np.asarray(image).astype(float)
            for x, y in ((512, 343), (351, 460), (673, 460), (413, 649), (611, 649)):
                with self.subTest(cutout=(x, y)):
                    self.assertLess(pixels[y-20:y+20, x-20:x+20].max(), 35,
                                    "Five original large holes must remain clear")
            for x, y in ((512, 512), (512, 220), (250, 512), (775, 512), (512, 760)):
                with self.subTest(body=(x, y)):
                    self.assertGreater(pixels[y-10:y+10, x-10:x+10, 0].mean(), 80,
                                       "Reel must have a luminous solid body, not an annulus")
            self.assertGreater(pixels[502:522, 118:128, 0].mean(), 5,
                               "Soft bloom must spill beyond the original silhouette")
            self.assertLess(pixels[512, 512, 0], pixels[512, 150, 0],
                            "Center exposure must be lower than the bright outer edge")
            self.assertGreater(pixels[:, :, 0].mean(), pixels[:, :, 1].mean() * 1.5)
            self.assertLess(pixels[:, :, 2].max(), 30)
            self.assertEqual(pixels[:40, :40].max(), 0, "Corners must be black")

    def test_shared_logo_is_deterministic_grainy_and_asymmetric(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            output = Path(directory)
            subprocess.run([sys.executable, str(GENERATOR), "--output", directory], check=True)
            logo_path = output / "HalationLogo.imageset/halation-logo.png"
            first = logo_path.read_bytes()
            with Image.open(logo_path) as image:
                logo = image.copy()
            pixels = np.asarray(logo)
            self.assertEqual(int(pixels[0, 0, 3]), 0)
            self.assertGreater(int(pixels[512, 512, 3]), 80, "Original reel center stays filled")
            self.assertGreater(int(pixels[:, :, 3].max()), 200)
            black = Image.new("RGB", logo.size)
            black.paste(logo, mask=logo.getchannel("A"))
            with Image.open(output / "AppIcon.appiconset/app-icon.png") as icon:
                np.testing.assert_array_equal(np.asarray(icon), np.asarray(black))
            red = np.asarray(black)[:, :, 0].astype(float)
            self.assertGreater(np.abs(red - np.fliplr(red)).mean(), 3)
            patch = red[220:245, 500:525]
            self.assertGreater(np.diff(patch, axis=1).std(), 5, "Glow must retain fine grain")
            self.assertGreater(np.unique(red.astype(np.uint8)).size, 150, "Glow must have soft falloff")
            expected = Image.new("RGB", (430, 932))
            small = logo.resize((240, 240), Image.Resampling.LANCZOS)
            expected.paste(small, (95, 346), small.getchannel("A"))
            with Image.open(output / "LaunchArtwork.imageset/splash-screen.png") as launch:
                np.testing.assert_array_equal(np.asarray(launch), np.asarray(expected))
            subprocess.run([sys.executable, str(GENERATOR), "--output", directory], check=True)
            self.assertEqual(first, logo_path.read_bytes())

    def test_generator_produces_required_dimensions_and_modes(self):
        self.assertTrue(GENERATOR.is_file(), "Branding generator must exist")
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            subprocess.run([sys.executable, str(GENERATOR), "--output", directory], check=True)
            for name, size, mode in (
                ("AppIcon.appiconset/app-icon.png", (1024, 1024), "RGB"),
                ("HalationLogo.imageset/halation-logo.png", (1024, 1024), "RGBA"),
                ("LaunchArtwork.imageset/splash-screen.png", (430, 932), "RGB"),
            ):
                with self.subTest(name=name), Image.open(Path(directory) / name) as image:
                    self.assertEqual(image.size, size)
                    self.assertEqual(image.mode, mode)


if __name__ == "__main__":
    unittest.main()
