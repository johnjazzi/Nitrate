#!/usr/bin/env python3
"""Behavior checks for the test-fixture packager.

These drive ``scripts/package_test_fixtures.py`` against temporary fake
checkouts only. They never touch the real repository tree, never invoke Xcode,
and never require network access: the point is to prove the packager copies
exactly the allowlisted files, fails closed on anything unsafe, and produces a
byte-for-byte deterministic snapshot for the test bundle.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
import sys

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))

import package_test_fixtures as fixtures  # noqa: E402  (path setup is intentional)


class FakeCheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nitrate-fixtures-test-")
        self.addCleanup(self.temp.cleanup)
        # A directory with spaces mirrors real checkout paths and the LUT names.
        self.repo = Path(self.temp.name) / "repo with spaces"
        self.repo.mkdir()
        self.output = Path(self.temp.name) / "out"

    def write(self, relative, text="data"):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_packages_only_allowlisted_files(self):
        self.write("Resources/stocks.json", "{}")
        self.write("Resources/LUTs/a - Apple Log 2.cube", "LUT_3D_SIZE 2\n")
        self.write("App/ContentView.swift", "// source")
        self.write("secret/notes.txt", "not a fixture")

        written = fixtures.package(
            self.repo, self.output,
            file_fixtures=("Resources/stocks.json", "App/ContentView.swift"),
            glob_fixtures=("Resources/LUTs/*.cube",),
        )

        self.assertEqual(written, [
            "App/ContentView.swift",
            "Resources/LUTs/a - Apple Log 2.cube",
            "Resources/stocks.json",
        ])
        self.assertFalse((self.output / "secret" / "notes.txt").exists(),
                         "non-allowlisted files must never be packaged")

    def test_missing_required_fixture_fails_closed_without_partial_output(self):
        self.write("Resources/stocks.json", "{}")
        with self.assertRaises(fixtures.FixtureError):
            fixtures.package(
                self.repo, self.output,
                file_fixtures=("Resources/stocks.json", "App/ContentView.swift"),
                glob_fixtures=(),
            )
        self.assertFalse(self.output.exists(),
                         "a missing required file must abort before anything is written")

    def test_empty_glob_fails_closed(self):
        with self.assertRaises(fixtures.FixtureError):
            fixtures.package(
                self.repo, self.output,
                file_fixtures=(), glob_fixtures=("Resources/LUTs/*.cube",),
            )

    def test_preserves_paths_with_spaces(self):
        relative = "Resources/LUTs/500T 85A F3513DI - Apple Log 2.cube"
        self.write(relative, "LUT_3D_SIZE 2\n")

        written = fixtures.package(
            self.repo, self.output,
            file_fixtures=(), glob_fixtures=("Resources/LUTs/*.cube",),
        )

        self.assertEqual(written, [relative])
        self.assertTrue((self.output / relative).is_file())
        self.assertEqual((self.output / relative).read_text(), "LUT_3D_SIZE 2\n")

    def test_is_deterministic_across_runs(self):
        self.write("Resources/stocks.json", "{}")
        self.write("Resources/LUTs/b - Apple Log 2.cube", "b")
        self.write("Resources/LUTs/a - Apple Log 2.cube", "a")

        kwargs = dict(file_fixtures=("Resources/stocks.json",),
                      glob_fixtures=("Resources/LUTs/*.cube",))
        first = fixtures.package(self.repo, self.output / "one", **kwargs)
        second = fixtures.package(self.repo, self.output / "two", **kwargs)

        self.assertEqual(first, second)
        self.assertEqual(first, sorted(first), "packaging order must be stable")
        for relative in first:
            self.assertEqual((self.output / "one" / relative).read_bytes(),
                             (self.output / "two" / relative).read_bytes())

    def test_rejects_symlink_escaping_the_checkout(self):
        outside = Path(self.temp.name) / "outside-secret.txt"
        outside.write_text("secret")
        link = self.repo / "Resources" / "stocks.json"
        link.parent.mkdir(parents=True)
        link.symlink_to(outside)

        with self.assertRaises(fixtures.FixtureError):
            fixtures.package(self.repo, self.output,
                             file_fixtures=("Resources/stocks.json",), glob_fixtures=())

    def test_rejects_directory_symlink_escaping_the_checkout(self):
        outside = Path(self.temp.name) / "outside-luts"
        outside.mkdir()
        (outside / "a.cube").write_text("x")
        (self.repo / "Resources").mkdir()
        (self.repo / "Resources" / "LUTs").symlink_to(outside)

        with self.assertRaises(fixtures.FixtureError):
            fixtures.package(self.repo, self.output,
                             file_fixtures=(), glob_fixtures=("Resources/LUTs/*.cube",))

    def test_refuses_excluded_paths(self):
        for relative in (
            "build/thing.json",
            ".git/config",
            "docs/prioritization.md",
            "Resources/Grain/grain3d.raw",
            "App/Resources/Grain/grain3d.raw",
            "credentials/production.pem",
        ):
            with self.subTest(relative=relative):
                with self.assertRaises(fixtures.FixtureError):
                    fixtures.plan(self.repo, file_fixtures=(relative,), glob_fixtures=())

    def test_glob_never_selects_excluded_files(self):
        self.write("Resources/LUTs/a.cube", "a")
        self.write("Resources/Grain/grain3d.raw", "raw")

        written = fixtures.package(self.repo, self.output,
                                   file_fixtures=(), glob_fixtures=("Resources/LUTs/*.cube",))

        self.assertEqual(written, ["Resources/LUTs/a.cube"])
        self.assertFalse((self.output / "Resources" / "Grain").exists())

    def test_refuses_existing_excluded_dotfiles(self):
        # Negative control: exclusion must hold on files that actually exist.
        # ``.git/config`` and ``.env`` must be rejected by identity, not merely
        # because the fake checkout never created them.
        for relative in (".env", ".git/config"):
            with self.subTest(relative=relative):
                self.write(relative, "secret")
                with self.assertRaises(fixtures.FixtureError):
                    fixtures.plan(self.repo, file_fixtures=(relative,), glob_fixtures=())

    def test_rejects_traversal_and_absolute_paths(self):
        (Path(self.temp.name) / "outside.txt").write_text("secret")
        for relative in ("../outside.txt", "Resources/../../outside.txt", "/etc/passwd"):
            with self.subTest(relative=relative):
                with self.assertRaises(fixtures.FixtureError):
                    fixtures.plan(self.repo, file_fixtures=(relative,), glob_fixtures=())

    def test_rejects_symlink_to_excluded_file_inside_checkout(self):
        # A symlink that stays inside the checkout but resolves to an excluded
        # file (e.g. App/ContentView.swift -> .env) must not leak the secret.
        self.write(".env", "SECRET=1")
        link = self.repo / "App" / "ContentView.swift"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(self.repo / ".env")

        with self.assertRaises(fixtures.FixtureError):
            fixtures.package(self.repo, self.output,
                             file_fixtures=("App/ContentView.swift",), glob_fixtures=())

    def test_repackaging_prunes_stale_owned_files(self):
        self.write("Resources/LUTs/a.cube", "a")
        self.write("Resources/LUTs/b.cube", "b")
        kwargs = dict(file_fixtures=(), glob_fixtures=("Resources/LUTs/*.cube",))

        first = fixtures.package(self.repo, self.output, **kwargs)
        self.assertEqual(first, ["Resources/LUTs/a.cube", "Resources/LUTs/b.cube"])

        (self.repo / "Resources" / "LUTs" / "b.cube").unlink()
        second = fixtures.package(self.repo, self.output, **kwargs)

        self.assertEqual(second, ["Resources/LUTs/a.cube"])
        self.assertTrue((self.output / "Resources/LUTs/a.cube").is_file())
        self.assertFalse((self.output / "Resources/LUTs/b.cube").exists(),
                         "a fixture removed from the source must not linger in the snapshot")

    def test_repackaging_preserves_unrelated_output_files(self):
        self.write("Resources/stocks.json", "{}")
        self.output.mkdir(parents=True, exist_ok=True)
        unrelated = self.output / "keep-me.txt"
        unrelated.write_text("user data")
        media = self.output / "clip.mov"
        media.write_text("user media")

        for _ in range(2):
            fixtures.package(self.repo, self.output,
                             file_fixtures=("Resources/stocks.json",), glob_fixtures=())

        self.assertEqual(unrelated.read_text(), "user data",
                         "unrelated output files must never be deleted")
        self.assertEqual(media.read_text(), "user media",
                         "unrelated output media must never be deleted")

    def test_rejects_output_symlink_escape(self):
        outside = Path(self.temp.name) / "outside-dir"
        outside.mkdir()
        self.write("Resources/stocks.json", "{}")
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "Resources").symlink_to(outside)

        with self.assertRaises(fixtures.FixtureError):
            fixtures.package(self.repo, self.output,
                             file_fixtures=("Resources/stocks.json",), glob_fixtures=())
        self.assertFalse((outside / "stocks.json").exists(),
                         "no write may escape through a symlinked output path")

    def test_rejects_output_overlapping_the_checkout(self):
        self.write("Resources/stocks.json", "{}")
        for output in (self.repo, self.repo / "nested-out"):
            with self.subTest(output=output):
                with self.assertRaises(fixtures.FixtureError):
                    fixtures.package(self.repo, output,
                                     file_fixtures=("Resources/stocks.json",), glob_fixtures=())

    def test_allows_standard_derived_data_under_ignored_build_directory(self):
        self.write("Resources/stocks.json", "{}")
        output = self.repo / "build/verification/DerivedData/Build/Products/Test.xctest/Contents/Resources/test-repository"
        fixtures.package(self.repo, output, file_fixtures=("Resources/stocks.json",), glob_fixtures=())
        self.assertEqual((output / "Resources/stocks.json").read_text(), "{}")

    def test_rejected_source_output_does_not_create_directories(self):
        self.write("Resources/stocks.json", "{}")
        output = self.repo / "App/new-source-directory"
        with self.assertRaises(fixtures.FixtureError):
            fixtures.package(self.repo, output, file_fixtures=("Resources/stocks.json",), glob_fixtures=())
        self.assertFalse(output.exists())

    def test_default_allowlist_is_unique_and_never_excluded(self):
        self.assertEqual(len(fixtures.FILE_FIXTURES), len(set(fixtures.FILE_FIXTURES)))
        for relative in fixtures.FILE_FIXTURES:
            self.assertFalse(fixtures._is_excluded(relative), relative)
        for pattern in fixtures.GLOB_FIXTURES:
            self.assertTrue(pattern.endswith(".cube"), pattern)


if __name__ == "__main__":
    unittest.main(verbosity=2)
