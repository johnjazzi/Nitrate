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

# Image-quality gates (fractions of a 1080x1620 frame).
MAX_WHITE_FRACTION = 0.35      # all three channels > 0.97 -> over-exposed
MIN_MIDTONE_FRACTION = 0.25    # mean channel within 0.08..0.94
MIN_PALETTE = 500              # distinct 8-bit colours -> not posterised / blank

# Shipped-asset budgets. 1080x1620 (2:3, the card's native 3x shape) at moderate JPEG
# quality; flat Log plates compress well, so these hold with headroom.
PLATE_WIDTH, PLATE_HEIGHT = 1080, 1620
MAX_PLATE_BYTES = 384 * 1024   # per-plate bundle budget
MAX_TOTAL_BYTES = 1280 * 1024  # whole set


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

    def test_plate_stats_are_measured_on_the_stored_jpeg(self):
        """The reported statistics must come from the stored JPEG, not the pre-JPEG float.

        Decoding the committed JPEG and recomputing the same quantities from it has to
        reproduce the manifest to within a code unit. This is what stops a pre-compression
        metric (which understates real error) from being shipped as the truth.
        """
        for scene in self.manifest["scenes"]:
            stats = scene["plateStats"]
            path = STOCK_DIR / scene["plate"]
            img = _read(path)
            self.assertAlmostEqual(float(img.mean()), stats["meanCode"], delta=1.0 / 255.0,
                                   msg=f"{scene['id']}: meanCode is not from the stored JPEG")
            self.assertAlmostEqual(float((img >= 0.999).any(axis=-1).mean()),
                                   stats["whiteFraction"], delta=1e-6,
                                   msg=f"{scene['id']}: whiteFraction is not from the stored JPEG")
            self.assertEqual(int(path.stat().st_size), stats["jpegBytes"],
                             f"{scene['id']}: jpegBytes does not match the committed file")

    def test_stored_jpeg_roundtrip_and_encode_error_are_recorded(self):
        """Every plate records the error its own JPEG compression introduced, and the
        display round-trip measured *on that JPEG*."""
        for scene in self.manifest["scenes"]:
            stats = scene["plateStats"]
            for key in ("jpegEncodeMeanAbsError8bit", "jpegEncodeP99AbsError8bit",
                        "roundTripMeanAbsError8bit", "roundTripP99AbsError8bit"):
                self.assertIn(key, stats, f"{scene['id']}: {key} missing")
                self.assertTrue(math.isfinite(stats[key]), f"{scene['id']}: {key} not finite")
            # moderate quality on flat Log plates: the mean encode error stays within a few
            # code units, and the JPEG round trip stays small (a collapse in quality shows up
            # immediately here).
            self.assertLess(stats["jpegEncodeMeanAbsError8bit"], 5.0,
                            f"{scene['id']}: JPEG encode error too large for the budget")
            self.assertLess(stats["roundTripMeanAbsError8bit"], 8.0,
                            f"{scene['id']}: stored JPEG does not survive the neutral round trip")
            self.assertIn("stored", stats["roundTripNote"].lower(),
                          f"{scene['id']}: round trip must be measured on the stored JPEG")

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

    def test_as_shot_white_balance_is_recorded_not_invented(self):
        """The RAW's own as-shot WB multipliers are recorded, and no Kelvin is derived
        from them (the per-scene Kelvin is explicitly labelled assumed)."""
        for scene in self.manifest["scenes"]:
            wb = scene["source"]["nef"]["asShotWhiteBalance"]
            self.assertIn("as-shot", wb["source"].lower())
            self.assertIn("no colour temperature", wb["note"].lower())
            mult = wb.get("multipliersRGB")
            self.assertIsInstance(mult, list, f"{scene['id']}: as-shot multipliers missing")
            # Nikon's WhiteBalanceRBCoeff carries R, G, B and a second green (G2).
            self.assertIn(len(mult), (3, 4), f"{scene['id']}: unexpected multiplier count")
            self.assertTrue(all(m > 0 for m in mult), f"{scene['id']}: non-positive multiplier")
            derivation = scene["derivation"]
            self.assertEqual(derivation["sceneIlluminantProvenance"],
                             "assumed for this scene, not measured")
            self.assertEqual(derivation["whiteBalance"]["rebalancing"],
                             "none (auto white-patch removed)")

    def test_every_shipped_plate_records_its_compression_budget(self):
        for scene in self.manifest["scenes"]:
            path = STOCK_DIR / scene["plate"]
            self.assertLess(path.stat().st_size, MAX_PLATE_BYTES,
                            f"{path.name} exceeds the per-plate bundle budget")

    def test_total_bundle_stays_small(self):
        total = sum(f.stat().st_size for f in STOCK_DIR.glob("*.jpg"))
        self.assertLess(total, MAX_TOTAL_BYTES,
                        f"stock previews total {total/1024:.0f} KB; budget is "
                        f"{MAX_TOTAL_BYTES/1024:.0f} KB")

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
                self.assertEqual(im.size, (PLATE_WIDTH, PLATE_HEIGHT))

    def test_native_2to3_aspect(self):
        for _sid, path in self._paths():
            with Image.open(path) as im:
                width, height = im.size
            self.assertAlmostEqual(width / height, 2.0 / 3.0, places=4,
                                   msg=f"{path.name}: not the card's native 2:3 aspect")

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
        self.assertLess(total, MAX_TOTAL_BYTES,
                        f"plates total {total/1024:.0f} KB; budget is "
                        f"{MAX_TOTAL_BYTES/1024:.0f} KB")


class NoAutoWhitePatchTests(unittest.TestCase):
    """The removed white-patch / grey-world balance must not come back silently.

    An earlier revision picked the brightest desaturated pixels of a gamma-encoded RGB
    render as a "neutral" reference and scaled the channels to it. Gamma-encoded values are
    not scene-linear and a bright non-neutral surface passes the filter, so the reference
    was unreliable and could re-tint every plate. The plate must keep the RAW's as-shot
    white balance and the scene's own chroma.
    """

    def test_generator_has_no_white_patch_rebalancing(self):
        for name in dir(GEN):
            self.assertNotIn("white_patch", name.lower(),
                             f"generator still exposes {name}")
            self.assertNotIn("white_reference_balance", name.lower(),
                             f"generator still exposes {name}")

    def test_manifest_declares_the_no_rebalancing_policy(self):
        manifest = json.loads(MANIFEST.read_text())
        self.assertIn("no white-patch", manifest["whiteBalancePolicy"].lower())
        for scene in manifest["scenes"]:
            self.assertNotIn("whiteReference", scene["derivation"],
                             "white-patch evidence must be gone from the derivation")

    def test_encoding_preserves_scene_chroma(self):
        """A strongly tinted scene must stay tinted: no channel equalisation."""
        tint = np.array([[[0.35, 0.12, 0.05], [0.10, 0.28, 0.08]]], dtype=np.float64)
        plate = GEN.exact_apple_log_plate(tint)
        channel_means = plate[0].mean(axis=0)
        self.assertGreater(channel_means[0], channel_means[1])
        self.assertGreater(channel_means[1], channel_means[2])
        # A grey input stays grey (the transform is not applying a cast of its own).
        grey = np.full((1, 2, 3), 0.18, dtype=np.float64)
        grey_plate = GEN.exact_apple_log_plate(grey)[0]
        self.assertTrue(np.allclose(grey_plate[:, 0], grey_plate[:, 1], atol=1e-6))
        self.assertTrue(np.allclose(grey_plate[:, 1], grey_plate[:, 2], atol=1e-6))


class AppleLog2EncodeTests(unittest.TestCase):
    """The exact forward encode replaces the display-LUT inverse; pin its maths."""

    def test_linear_raw_development_disables_automatic_brightening(self):
        import rawpy
        from unittest.mock import MagicMock, patch
        raw = MagicMock()
        raw.postprocess.return_value = np.full((6, 4, 3), 12000, dtype=np.uint16)
        context = MagicMock()
        context.__enter__.return_value = raw
        with patch.object(rawpy, "imread", return_value=context):
            GEN.load_nef_linear(Path("sample.nef"), out_w=4, out_h=6)
        self.assertTrue(raw.postprocess.call_args.kwargs["no_auto_bright"],
                        "False enables automatic brightening rather than preserving exposure")

    def test_published_18_percent_reflection_lands_at_apple_code(self):
        # Apple's own white paper example: 18% reflectance encodes to ~0.4883.
        self.assertAlmostEqual(float(GEN.apple_log_encode(0.18)), 0.4882724, places=5)

    def test_curve_is_monotonic_and_bounded(self):
        x = np.linspace(0.0, 4.0, 5000)
        p = GEN.apple_log_encode(x)
        self.assertTrue(np.all(np.diff(p) >= -1e-12), "Apple Log 2 encode is not monotonic")
        self.assertGreaterEqual(float(p.min()), 0.0)
        self.assertLessEqual(float(p.max()), 1.0)

    def test_toe_floor_and_continuity(self):
        # Below R_0 the encode floors at 0; at R_t the toe and log segment agree.
        self.assertEqual(float(GEN.apple_log_encode(np.array(-0.2))), 0.0)
        c = GEN.APPLE_LOG_CONSTANTS
        left = c["sigma"] * (c["R_t"] - c["R_0"]) ** 2
        right = c["gamma"] * math.log2(c["R_t"] + c["beta"]) + c["delta"]
        self.assertAlmostEqual(left, right, places=6)

    def test_apple_wide_gamut_matrix_maps_white_to_white(self):
        # Neutral grey must stay neutral through the sRGB -> Apple Wide Gamut rotation.
        for value in (0.18, 0.5, 1.0):
            out = GEN.srgb_linear_to_apple_wide_gamut(np.array([[value, value, value]]))
            self.assertTrue(np.allclose(out, value, atol=1e-9),
                            f"grey {value} picked up a cast in Apple Wide Gamut")

    def test_manifest_records_the_exact_encode(self):
        manifest = json.loads(MANIFEST.read_text())
        meta = manifest["appleLog2"]
        self.assertIn("Apple Log 2", meta["transfer"])
        self.assertEqual(len(meta["primariesXY"]), 3)
        self.assertAlmostEqual(meta["encoded18PercentReflection"], 0.4882724, places=5)
        self.assertEqual(len(meta["sourceToAppleWideGamutMatrix"]), 3)
        self.assertLess(manifest["curveRoundTrip"]["maxLinearAbsError"], 1e-9,
                        "Apple Log 2 encode/decode round trip should be exact")


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
