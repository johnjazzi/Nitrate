#!/usr/bin/env python3
"""Contract tests for the illustrative stock-preview sample assets.

These are Python tests (allowed alongside the Swift suite). They run offline against the
committed JPEGs and the committed ``.cube`` LUTs -- no network, no Xcode, and no RAW
decoder: the source NEFs are build-time inputs and are not in the repository.

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
SCENE_IDS = ["neon", "forest", "harvest", "fireworks", "nightride",
             "race", "shoreline", "flyover"]

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
        self.assertEqual(self.manifest["schemaVersion"], 2)
        self.assertEqual(self.manifest["disclaimer"],
                         "Illustrative plates \u00b7 your LUT applied live")

    def test_scene_coverage(self):
        ids = [s["id"] for s in self.manifest["scenes"]]
        self.assertEqual(ids, SCENE_IDS)

    def test_every_scene_ships_one_plate(self):
        for scene in self.manifest["scenes"]:
            self.assertTrue(scene["plate"].endswith("-log.jpg"), scene["plate"])
            self.assertNotIn("previews", scene,
                             "plates ship ungraded; the app applies the stock LUT at runtime")
            self.assertTrue((STOCK_DIR / scene["plate"]).is_file())

    def test_runtime_contract_is_recorded(self):
        self.assertEqual(self.manifest["plateCount"], len(SCENE_IDS))
        self.assertIn("live", self.manifest["runtimeNote"])
        self.assertIn("live", self.manifest["disclaimer"])

    def test_lut_hashes_match_files(self):
        for sid, path in STOCK_LUTS.items():
            self.assertEqual(self.manifest["lutSHA256"][sid], GEN.source_sha256(path))
        self.assertEqual(self.manifest["neutralLutSHA256"], GEN.source_sha256(NEUTRAL_LUT))

    def test_plate_checksums_and_stats_match_files(self):
        for scene in self.manifest["scenes"]:
            stats = scene["plateStats"]
            path = STOCK_DIR / scene["plate"]
            self.assertEqual(stats["sha256"], GEN.source_sha256(path))
            self.assertLess(stats["whiteFraction"], 0.35, f"{scene['id']} plate is blown")
            self.assertGreater(stats["midtoneFraction"], 0.25, f"{scene['id']} plate is flat")
            self.assertLess(stats["roundTripMeanAbsError8bit"], 3.0,
                            f"{scene['id']}: plate does not survive the neutral round trip")

    def test_sources_are_identified_supplied_raws(self):
        for scene in self.manifest["scenes"]:
            src = scene["source"]
            self.assertIn("John Azzinaro", src["provider"])
            self.assertIn("permission", src["license"].lower())
            self.assertTrue(src["file"].lower().endswith(".nef"))
            self.assertEqual(len(src["sha256"]), 64, "source RAW must carry a content hash")
            nef = src["nef"]
            self.assertTrue(nef["camera"].startswith("NIKON"), nef)
            for key in ("exposureTime", "fNumber", "iso", "originalDate"):
                self.assertTrue(nef.get(key), f"{scene['id']}: capture metadata {key} missing")

    def test_every_shipped_plate_records_its_compression_budget(self):
        for scene in self.manifest["scenes"]:
            path = STOCK_DIR / scene["plate"]
            self.assertLess(path.stat().st_size, 90 * 1024,
                            f"{path.name} exceeds the per-plate bundle budget")
    def test_total_bundle_stays_small(self):
        total = sum(f.stat().st_size for f in STOCK_DIR.glob("*.jpg"))
        self.assertLess(total, 600 * 1024,
                        f"stock previews total {total/1024:.0f} KB; budget is 600 KB")

    def test_labelling_is_honest_not_calibration(self):
        blob = json.dumps(self.manifest).lower()
        for banned in ["calibrated", "camera original", "captured with", "apple log 2 original"]:
            self.assertNotIn(banned, blob.replace("not a camera original", ""))
        self.assertIn("illustrative", blob)
        scene = self.manifest["scenes"][0]
        self.assertIn("NOT a camera original", scene["derivation"]["plateLabel"])

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
            yield scene["id"], STOCK_DIR / scene["plate"]

    def test_size_and_format(self):
        for _sid, path in self._paths():
            with Image.open(path) as im:
                self.assertEqual(im.format, "JPEG")
                self.assertEqual(im.size, (480, 720))

    def test_images_are_present_and_not_blank(self):
        for sid, path in self._paths():
            img = _read(path)
            self.assertGreater(float(img.std()), 0.02, f"{path.name} looks flat/blank")
            palette = len(np.unique((img * 255).astype(np.uint8).reshape(-1, 3), axis=0))
            self.assertGreater(palette, MIN_PALETTE,
                               f"{path.name} only {palette} colours -> posterised/blank")

    def test_not_blown_out(self):
        for _sid, path in self._paths():
            img = _read(path)
            self.assertLess(float((img > 0.97).all(axis=-1).mean()), MAX_WHITE_FRACTION,
                            f"{path.name} is blown out")

    def test_has_meaningful_midtones(self):
        for _sid, path in self._paths():
            img = _read(path)
            m = img.mean(axis=-1)
            self.assertGreater(float(((m > 0.08) & (m < 0.94)).mean()), MIN_MIDTONE_FRACTION,
                               f"{path.name} has no midtone content")

    def test_broad_luminance_histogram(self):
        for _sid, path in self._paths():
            img = _read(path)
            with Image.open(path) as im:
                hist = np.asarray(im.convert("L").histogram(), dtype=float)
            occupied = int((hist > 0.01 * hist.sum()).sum())
            self.assertGreaterEqual(occupied, 5, f"{path.name}: only {occupied} tone bins used")

    def test_plates_total_stays_within_budget(self):
        total = sum(f.stat().st_size for f in STOCK_DIR.glob("*.jpg"))
        self.assertLess(total, 400 * 1024,
                        f"plates total {total/1024:.0f} KB; budget is 400 KB")


class DistinctnessTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(MANIFEST.read_text())
        self.plates = [_read(STOCK_DIR / s["plate"]) for s in self.manifest["scenes"]]

    def test_scenes_differ_from_each_other(self):
        for a in range(len(self.plates)):
            for b in range(a + 1, len(self.plates)):
                self.assertGreater(float(np.abs(self.plates[a] - self.plates[b]).mean()), 0.02,
                                   f"{SCENE_IDS[a]} and {SCENE_IDS[b]} plates look the same")

    def test_each_scene_carries_a_different_source_raw(self):
        files = [s["source"]["file"] for s in self.manifest["scenes"]]
        self.assertEqual(len(set(files)), len(files), "two scenes reference the same RAW")


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
