#!/usr/bin/env python3
"""Contract tests for the illustrative stock-preview sample assets.

These are Python tests (allowed alongside the Swift suite). They run offline against the
committed JPEGs and the committed ``.cube`` LUTs -- no network, no Xcode.

Run:
    python3 -m venv .venv && . .venv/bin/activate && pip install numpy Pillow scipy
    python -m unittest Tests/test_stock_previews.py
    # or simply:
    python Tests/test_stock_previews.py

Why the image-quality tests exist: an earlier generator revision shipped blown-white
images (a bad HDR loader returned 0-255 uint8) and every "passing" test missed it. The
tests below therefore pin the *photographic* properties of the assets -- blown-white
fraction, midtone fraction, tonal spread, palette size -- and the correctness of the LUT
maths, so that regression cannot recur silently.
"""
from __future__ import annotations

import importlib.util
import json
import math
import tempfile
import unittest
from pathlib import Path

import numpy as np

try:
    from PIL import Image
except ImportError as exc:  # pragma: no cover
    raise SystemExit("Pillow is required to run these tests: pip install Pillow") from exc

REPO = Path(__file__).resolve().parents[1]
STOCK_DIR = REPO / "App" / "Resources" / "StockSamples"
MANIFEST = STOCK_DIR / "manifest.json"
NEUTRAL_LUT = REPO / "App" / "Resources" / "Preview" / "AppleLog2ToRec709.cube"
STOCK_LUTS = {
    "kodak5207": REPO / "App" / "Resources" / "LUTs" / "5207 - Apple Log 2.cube",
    "kodak5219": REPO / "App" / "Resources" / "LUTs" / "5219 - Apple Log 2.cube",
}
SCENE_IDS = ["daylight", "city", "night"]

# Image-quality gates (fractions of a 540x810 frame).
MAX_WHITE_FRACTION = 0.35      # all three channels > 0.97 -> over-exposed
MIN_MIDTONE_FRACTION = 0.25    # mean channel within 0.08..0.94
MIN_PALETTE = 500              # distinct 8-bit colours -> not posterised / blank


def _load_generator():
    spec = importlib.util.spec_from_file_location(
        "generate_stock_previews", REPO / "scripts" / "generate_stock_previews.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


GEN = _load_generator()


def _read(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB")).astype(np.float64) / 255.0


class ManifestContractTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(MANIFEST.read_text())

    def test_schema_and_disclaimer(self):
        self.assertEqual(self.manifest["schemaVersion"], 1)
        self.assertEqual(self.manifest["disclaimer"], "Illustrative photos \u00b7 color LUT only")

    def test_scene_coverage(self):
        ids = [s["id"] for s in self.manifest["scenes"]]
        self.assertEqual(ids, SCENE_IDS)

    def test_every_scene_covers_every_stock(self):
        for scene in self.manifest["scenes"]:
            self.assertEqual(set(scene["previews"]), set(STOCK_LUTS),
                             f"{scene['id']} must preview every current stock")

    def test_all_referenced_files_exist(self):
        for scene in self.manifest["scenes"]:
            for name in [scene["neutralFile"], *scene["previews"].values()]:
                self.assertTrue((STOCK_DIR / name).is_file(), f"missing asset {name}")

    def test_lut_hashes_match_files(self):
        for sid, path in STOCK_LUTS.items():
            self.assertEqual(self.manifest["lutSHA256"][sid], GEN.source_sha256(path))
        self.assertEqual(self.manifest["neutralLutSHA256"], GEN.source_sha256(NEUTRAL_LUT))

    def test_asset_checksums_match_files(self):
        for scene in self.manifest["scenes"]:
            for meta in scene["assets"].values():
                path = STOCK_DIR / meta["file"]
                self.assertEqual(meta["sha256"], GEN.source_sha256(path),
                                 f"{meta['file']} checksum drift")

    def test_sources_are_real_cc0_with_urls(self):
        for scene in self.manifest["scenes"]:
            src = scene["source"]
            self.assertEqual(src["license"], "CC0")
            self.assertTrue(src["sourceURL"].startswith("https://"))
            self.assertTrue(src["licenseURL"].startswith("https://"))
            self.assertEqual(len(src["sha256"]), 64)
            self.assertEqual(len(src["md5"]), 32)

    def test_labelling_is_honest_not_calibration(self):
        blob = json.dumps(self.manifest).lower()
        for banned in ["calibrated", "camera original", "captured with", "apple log 2 original"]:
            self.assertNotIn(banned, blob.replace("not apple log 2 camera original", ""))
        self.assertIn("illustrative", blob)
        scene = self.manifest["scenes"][0]
        self.assertIn("illustrative synthetic Log input", scene["derivation"]["inputLabel"])

    def test_inverse_roundtrip_metric_present(self):
        rt = self.manifest["inverseRoundTripGlobal"]
        for key in ["validMeanAbsError8bit", "validP95AbsError8bit", "fullMeanAbsError8bit"]:
            self.assertIn(key, rt)
            self.assertTrue(math.isfinite(rt[key]))


class ImageQualityTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(MANIFEST.read_text())

    def _paths(self):
        for scene in self.manifest["scenes"]:
            for label, meta in scene["assets"].items():
                yield scene["id"], label, STOCK_DIR / meta["file"]

    def test_size_and_format(self):
        for _sid, _label, path in self._paths():
            with Image.open(path) as im:
                self.assertEqual(im.format, "JPEG")
                self.assertEqual(im.size, (540, 810))

    def test_images_are_present_and_not_blank(self):
        for sid, label, path in self._paths():
            img = _read(path)
            self.assertGreater(float(img.std()), 0.02, f"{path.name} looks flat/blank")
            palette = len(np.unique((img * 255).astype(np.uint8).reshape(-1, 3), axis=0))
            self.assertGreater(palette, MIN_PALETTE,
                               f"{path.name} only {palette} colours -> posterised/blank")

    def test_not_blown_out(self):
        for _sid, _label, path in self._paths():
            img = _read(path)
            white = float((img > 0.97).all(axis=-1).mean())
            self.assertLess(white, MAX_WHITE_FRACTION,
                            f"{path.name}: {white:.3f} of pixels are blown white")

    def test_has_meaningful_midtones(self):
        for _sid, _label, path in self._paths():
            img = _read(path)
            m = img.mean(axis=-1)
            mid = float(((m > 0.08) & (m < 0.94)).mean())
            self.assertGreater(mid, MIN_MIDTONE_FRACTION,
                               f"{path.name}: only {mid:.3f} midtone pixels")

    def test_broad_luminance_histogram(self):
        # a real photo occupies most of the tonal range, not one or two narrow spikes
        for _sid, _label, path in self._paths():
            m = _read(path).mean(axis=-1)
            hist, _ = np.histogram(m, bins=10, range=(0.0, 1.0))
            occupied = int((hist > 0.01 * m.size).sum())
            self.assertGreaterEqual(occupied, 6, f"{path.name}: only {occupied}/10 tone bins used")

    def test_neutral_photos_read_as_photographs(self):
        # the neutral base must be sensible BEFORE any inverse/stock step
        for scene in self.manifest["scenes"]:
            img = _read(STOCK_DIR / scene["neutralFile"])
            white = float((img > 0.97).all(axis=-1).mean())
            self.assertLess(white, MAX_WHITE_FRACTION, f"{scene['id']} neutral blown out")
            self.assertGreater(float(img.std()), 0.05, f"{scene['id']} neutral lacks contrast")


class DistinctnessTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(MANIFEST.read_text())

    def _scene(self, sid):
        return next(s for s in self.manifest["scenes"] if s["id"] == sid)

    def test_scenes_differ_from_each_other(self):
        neutrals = [_read(STOCK_DIR / self._scene(s)["neutralFile"]) for s in SCENE_IDS]
        for i in range(len(neutrals)):
            for j in range(i + 1, len(neutrals)):
                self.assertGreater(float(np.abs(neutrals[i] - neutrals[j]).mean()), 0.05,
                                   f"scenes {SCENE_IDS[i]}/{SCENE_IDS[j]} look the same")

    def test_stocks_differ_from_neutral_and_each_other(self):
        for sid in SCENE_IDS:
            sc = self._scene(sid)
            neutral = _read(STOCK_DIR / sc["neutralFile"])
            a = _read(STOCK_DIR / sc["previews"]["kodak5207"])
            b = _read(STOCK_DIR / sc["previews"]["kodak5219"])
            self.assertGreater(float(np.abs(a - neutral).mean()), 0.01,
                               f"{sid}: 5207 preview indistinguishable from neutral")
            self.assertGreater(float(np.abs(b - neutral).mean()), 0.01,
                               f"{sid}: 5219 preview indistinguishable from neutral")
            self.assertGreater(float(np.abs(a - b).mean()), 0.005,
                               f"{sid}: 5207 and 5219 previews identical")


class CubeMathsTests(unittest.TestCase):
    """Axis order, endpoints and interpolation -- the parts a wrong LUT would break."""

    def _write_cube(self, size, fn):
        lines = [f"LUT_3D_SIZE {size}"]
        for b in range(size):
            for g in range(size):
                for r in range(size):  # red fastest
                    rr, gg, bb = r / (size - 1), g / (size - 1), b / (size - 1)
                    v = fn(rr, gg, bb)
                    lines.append(f"{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}")
        tmp = Path(tempfile.mkdtemp()) / "asym.cube"
        tmp.write_text("\n".join(lines) + "\n")
        return tmp

    def test_axis_order_asymmetric_cube(self):
        # distinct, asymmetric per-channel behaviour: R keeps r, G inverts g, B halves b
        path = self._write_cube(3, lambda r, g, b: (r, 1.0 - g, 0.5 * b))
        size, cube = GEN._parse_cube(path)
        self.assertEqual(size, 3)
        self.assertTrue(np.allclose(GEN._trilinear(cube, size, np.array([1.0, 0.0, 0.0])), [1, 1, 0]))
        self.assertTrue(np.allclose(GEN._trilinear(cube, size, np.array([0.0, 1.0, 0.0])), [0, 0, 0]))
        self.assertTrue(np.allclose(GEN._trilinear(cube, size, np.array([0.0, 0.0, 1.0])), [0, 1, 0.5]))
        self.assertTrue(np.allclose(GEN._trilinear(cube, size, np.array([1.0, 1.0, 1.0])), [1, 0, 0.5]))

    def test_endpoints_and_centre_interpolation(self):
        # identity cube: interpolation of a linear function must be exact everywhere
        path = self._write_cube(4, lambda r, g, b: (r, g, b))
        size, cube = GEN._parse_cube(path)
        for q in ([0, 0, 0], [1, 1, 1], [0.5, 0.5, 0.5], [0.3, 0.6, 0.9]):
            self.assertTrue(np.allclose(GEN._trilinear(cube, size, np.array(q)), q, atol=1e-6),
                            f"identity cube interpolation wrong at {q}")

    def test_centre_averages_on_coarse_cube(self):
        # 2^3 cube of exact node values -> the centre is the mean of 8 nodes
        path = self._write_cube(2, lambda r, g, b: (r, 1.0 - r if g > 0.5 else r, b))
        size, cube = GEN._parse_cube(path)
        centre = GEN._trilinear(cube, size, np.array([0.5, 0.5, 0.5]))
        self.assertTrue(np.allclose(centre, [0.5, 0.5, 0.5], atol=1e-6))

    def test_real_luts_parse_and_apply(self):
        for path in [NEUTRAL_LUT, *STOCK_LUTS.values()]:
            size, cube = GEN._parse_cube(path)
            self.assertEqual(size, 33)
            self.assertEqual(cube.shape, (33 ** 3, 3))
            out = GEN._trilinear(cube, size, np.array([[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]]))
            self.assertTrue(np.all(np.isfinite(out)))
            self.assertTrue(np.all(out >= 0) and np.all(out <= 1))


class InverseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.inv = GEN.InverseNeutral(NEUTRAL_LUT)

    def test_output_is_finite_and_in_range(self):
        q = np.random.default_rng(1).random((5000, 3))
        out = self.inv.apply(q)
        self.assertTrue(np.all(np.isfinite(out)))
        self.assertGreaterEqual(float(out.min()), 0.0)
        self.assertLessEqual(float(out.max()), 1.0)

    def test_roundtrip_on_reachable_colours(self):
        # colours the neutral transform actually produces must come back close
        log_in = np.random.default_rng(2).random((4000, 3))
        display = GEN._trilinear(self.inv.cube, self.inv.size, log_in)
        err = np.abs(GEN._trilinear(self.inv.cube, self.inv.size, self.inv.apply(display))
                     - display) * 255.0
        self.assertLess(float(err.mean()), 12.0, "inverse round-trip too coarse")
        self.assertLess(float(np.percentile(err, 90)), 25.0)

    def test_known_colors(self):
        # specific sample colours used by the manifest metric -- stable across runs
        for q in ([0.2, 0.2, 0.2], [0.5, 0.5, 0.5], [0.8, 0.8, 0.8], [0.6, 0.3, 0.3]):
            x = np.array(q)
            back = GEN._trilinear(self.inv.cube, self.inv.size, self.inv.apply(x))
            self.assertLess(float(np.abs(back - x).max()) * 255.0, 20.0, f"bad inverse at {q}")

    def test_monotonic_for_neutral_grey(self):
        greys = np.linspace(0.1, 1.0, 20)[:, None].repeat(3, axis=1)
        out = self.inv.apply(greys)[:, 0]
        self.assertTrue(np.all(np.diff(out) > -1e-6), "inverse not monotonic on grey ramp")


class ReprojectionTests(unittest.TestCase):
    def test_rectilinear_crop_is_upright(self):
        # an HDRI with a bright band just above the horizon must render it at the TOP
        h = np.zeros((64, 128, 3))
        h[20:32, :, :] = 1.0  # above-horizon band; below-horizon rows stay dark
        img = GEN.reproject_linear(h, 0.0, 0.0, 70.0)
        top = img[: img.shape[0] // 3].mean()
        bottom = img[-img.shape[0] // 3:].mean()
        self.assertGreater(top, bottom, "crop is vertically flipped")

    def test_crop_has_no_equirect_distortion(self):
        # a source meridian (vertical line) must stay a straight vertical line in the crop;
        # a stretched panorama slice would curve it.
        h = np.zeros((64, 128, 3))
        h[:, 70, :] = 1.0  # u ~= 0.55 -> ~18 deg longitude, inside the ~42 deg crop
        img = GEN.reproject_linear(h, 0.0, 0.0, 60.0)
        prof = img.mean(axis=2)
        band = img.shape[0] // 5
        cols = [int(np.argmax(prof[i * band:(i + 1) * band].mean(axis=0))) for i in range(5)]
        self.assertLess(max(cols) - min(cols), 2, "vertical line curves in crop -> equirect distortion")


if __name__ == "__main__":
    unittest.main(verbosity=2)
