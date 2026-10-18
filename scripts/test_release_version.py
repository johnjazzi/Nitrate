#!/usr/bin/env python3
"""Release-policy tests; all writes and commits stay in temporary repositories."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).with_name("release_version.py")
WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/release-version.yml"
FIXTURE = '''name: Fixture
settings:
  base:
    # Keep comments, quotes, unrelated values and whitespace.
    MARKETING_VERSION: "1.2.3"  # release
    CURRENT_PROJECT_VERSION: '7' # build
    SWIFT_VERSION: "6.0"
targets: {}
'''


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release-version-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.project = self.repo / "project.yml"
        self.project.write_text(FIXTURE)
        self.git("init", "--quiet")
        self.git("add", "project.yml")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "--quiet", "-m", "base")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, text=True,
                              capture_output=True, check=True)

    def run_helper(self, command, *args, labels=None):
        env = os.environ.copy()
        env.pop("RELEASE_LABELS_JSON", None)
        if labels is not None:
            env["RELEASE_LABELS_JSON"] = json.dumps(labels)
        return subprocess.run([sys.executable, str(HELPER), command, *args],
                              cwd=self.repo, env=env, text=True, capture_output=True)

    def test_prepare_exact_patch_minor_major_and_idempotence(self):
        for labels, expected in (([], "1.2.4"), (["release:minor"], "1.3.0"),
                                 (["release:major"], "2.0.0")):
            with self.subTest(labels=labels):
                self.project.write_bytes(FIXTURE.replace("\n", "\r\n").encode())
                result = self.run_helper("prepare", "--base", self.base, labels=labels)
                self.assertEqual(result.returncode, 0, result.stderr)
                wanted = FIXTURE.replace('"1.2.3"', f'"{expected}"').replace("'7'", "'8'")
                self.assertEqual(self.project.read_bytes(), wanted.replace("\n", "\r\n").encode())
                result = self.run_helper("prepare", "--base", self.base, labels=labels)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.project.read_bytes(), wanted.replace("\n", "\r\n").encode())
                result = self.run_helper("check", "--base", self.base, labels=labels)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.base)

    def test_conflicting_or_invalid_labels_do_not_write(self):
        for labels in (["release:major", "release:minor"], ["release:patch"],
                       ["release:minor", "release:minor"], [2], {"name": "release:minor"}):
            with self.subTest(labels=labels):
                result = self.run_helper("prepare", "--base", self.base, labels=labels)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("label", result.stderr.lower())
                self.assertEqual(self.project.read_text(), FIXTURE)

    def test_cli_labels_override_environment_and_allow_unrelated_names(self):
        result = self.run_helper("prepare", "--base", self.base, "--labels",
                                 '["bug", "release:major"]', labels=["release:minor"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"2.0.0"', self.project.read_text())

    def test_bump_build_changes_only_build_even_without_base(self):
        for build in (8, 9):
            result = self.run_helper("bump-build")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.project.read_text(), FIXTURE.replace("'7'", f"'{build}'"))
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.base)

    def test_prepare_preserves_higher_manual_build_and_repairs_old_build(self):
        for current, expected in ((30, 30), (2, 8)):
            with self.subTest(current=current):
                self.project.write_text(FIXTURE.replace("'7'", f"'{current}'"))
                result = self.run_helper("prepare", "--base", self.base)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"'{expected}'", self.project.read_text())

    def test_check_rejects_unbumped_mismatch_and_unadvanced_build(self):
        for version, build in (("1.2.3", "8"), ("1.2.5", "8"), ("1.3.0", "8"),
                               ("1.2.4", "7"), ("1.2.4", "6")):
            with self.subTest(version=version, build=build):
                text = FIXTURE.replace("1.2.3", version).replace("'7'", f"'{build}'")
                self.project.write_text(text)
                result = self.run_helper("check", "--base", self.base)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.project.read_text(), text)

    def test_invalid_metadata_fails_without_writing(self):
        invalid = [
            FIXTURE.replace("1.2.3", version)
            for version in ("1.2", "01.2.3", "1.2.03", "v1.2.3", "1.2.3-beta", "-1.2.3", "1.2.3.4")
        ] + [
            FIXTURE.replace("'7'", build)
            for build in ("'0'", "'07'", "'-1'", "'7.0'", "no", "'7\"", "[]")
        ] + [
            FIXTURE.replace('    MARKETING_VERSION: "1.2.3"  # release\n', ""),
            FIXTURE + '    MARKETING_VERSION: "1.2.3"\n',
            FIXTURE + '    "MARKETING_VERSION": "1.2.3"\n',
            FIXTURE + '    CURRENT_PROJECT_VERSION: "7"\n',
            FIXTURE.replace("settings:", "wrong:"),
            FIXTURE.replace("  base:", "  wrong:"),
            FIXTURE.replace("  base:", "  base: {}\n  base:"),
            "settings: {}\n" + FIXTURE,
            FIXTURE.replace('    MARKETING_VERSION: "1.2.3"', '    MARKETING_VERSION: ["1.2.3"]'),
            FIXTURE.replace("    CURRENT_PROJECT_VERSION", "\tCURRENT_PROJECT_VERSION"),
            FIXTURE.replace('"1.2.3"  # release', '1.2.3#not-a-comment'),
            FIXTURE + 'overrides: {MARKETING_VERSION: "9.9.9"}\n',
        ]
        for index, text in enumerate(invalid):
            with self.subTest(case=index):
                self.project.write_text(text)
                result = self.run_helper("prepare", "--base", self.base)
                self.assertNotEqual(result.returncode, 0, text)
                self.assertEqual(self.project.read_text(), text)

    def test_invalid_base_and_shell_metacharacters_fail_safely(self):
        for base in ("missing-ref", "--help", "HEAD; touch INJECTED", "$(touch INJECTED)"):
            with self.subTest(base=base):
                result = self.run_helper("prepare", "--base=" + base)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.project.read_text(), FIXTURE)
                self.assertFalse((self.repo / "INJECTED").exists())

    def test_check_rejects_conflicting_labels_and_malformed_json(self):
        result = self.run_helper("check", "--base", self.base,
                                 "--labels", '["release:minor", "release:major"]')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("label", result.stderr.lower())
        result = self.run_helper("prepare", "--base", self.base, "--labels", "not-json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("JSON", result.stderr)

    def test_unquoted_fields_preserve_spaces_comments_and_no_final_newline(self):
        text = FIXTURE.replace('"1.2.3"', "1.2.3").replace("'7'", "7").rstrip("\n")
        self.project.write_text(text)
        result = self.run_helper("prepare", "--base", self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.project.read_text(), text.replace("1.2.3", "1.2.4").replace(": 7 #", ": 8 #"))

    def test_malformed_trusted_base_is_rejected_before_writes(self):
        self.project.write_text(FIXTURE.replace("1.2.3", "invalid"))
        self.git("add", "project.yml")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "--quiet", "-m", "malformed metadata")
        self.project.write_text(FIXTURE)
        result = self.run_helper("prepare", "--base", "HEAD")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MARKETING_VERSION", result.stderr)
        self.assertEqual(self.project.read_text(), FIXTURE)

    def test_labels_with_shell_syntax_remain_data(self):
        labels = ["bug; touch INJECTED", '$(touch INJECTED)', 'quote"\nnewline']
        result = self.run_helper("prepare", "--base", self.base, labels=labels)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"1.2.4"', self.project.read_text())
        self.assertFalse((self.repo / "INJECTED").exists())

    def test_check_accepts_exact_patch_and_is_read_only(self):
        prepared = FIXTURE.replace('"1.2.3"', '"1.2.4"').replace("'7'", "'8'")
        self.project.write_text(prepared)
        result = self.run_helper("check", "--base", self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.project.read_text(), prepared)
        self.assertIn("1.2.4 (8)", result.stdout)


class WorkflowContractTests(unittest.TestCase):
    """Static workflow contracts, not a claim that GitHub dispatched a run."""

    def setUp(self):
        self.assertTrue(WORKFLOW.is_file(), "release-version workflow is missing")
        self.workflow = WORKFLOW.read_text()

    def test_only_pull_requests_targeting_main_are_selected(self):
        self.assertIn("  pull_request:\n    branches: [main]\n", self.workflow)
        self.assertNotIn("pull_request_target:", self.workflow)
        self.assertIn("if: github.event.pull_request.base.ref == 'main'", self.workflow)
        for event in ("opened", "reopened", "synchronize", "ready_for_review", "labeled", "unlabeled"):
            self.assertIn(event, self.workflow.split("types: [", 1)[1].split("]", 1)[0])

    def test_read_only_full_history_checkout_uses_verified_release_pin(self):
        self.assertIn("permissions:\n  contents: read", self.workflow)
        self.assertNotIn(": write", self.workflow)
        self.assertIn("actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5", self.workflow)
        self.assertIn("fetch-depth: 0", self.workflow)
        self.assertIn("persist-credentials: false", self.workflow)
        self.assertIn("ref: ${{ github.event.pull_request.head.sha }}", self.workflow)

    def test_labels_are_environment_json_never_shell_interpolation(self):
        self.assertIn("RELEASE_LABELS_JSON: ${{ toJSON(github.event.pull_request.labels.*.name) }}", self.workflow)
        self.assertIn("RELEASE_BASE_SHA: ${{ github.event.pull_request.base.sha }}", self.workflow)
        self.assertIn('python3 scripts/release_version.py check --base "$RELEASE_BASE_SHA"', self.workflow)
        self.assertIn("python3 scripts/test_release_version.py -v", self.workflow)
        for line in self.workflow.splitlines():
            if "run:" in line:
                self.assertNotIn("${{", line)
        self.assertNotIn("pip install", self.workflow)
        self.assertNotIn(" secrets.", self.workflow)
        self.assertNotIn("git push", self.workflow)


if __name__ == "__main__":
    unittest.main()
