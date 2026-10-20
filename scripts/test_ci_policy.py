#!/usr/bin/env python3
"""Policy contracts for the portable "Repository policy checks" GitHub workflow.

These are static source contracts over ``.github/workflows/policy.yml``: they
parse the YAML with a small stdlib reader (no PyYAML) and assert the migration's
invariants. A passing run proves the *file* declares the intended shape -- it is
NOT a claim that GitHub dispatched a run, that a runner was available, or that
any job actually succeeded. Only a real GitHub run proves that.

The suite pins:
  * one portable, Ubuntu-only job named "Repository policy checks" with a
    10-minute cap and no Xcode/macOS tooling;
  * read-only least-privilege permissions and stale-run cancellation;
  * the same verified checkout pin the release-version gate uses;
  * exactly the confirmed Linux-portable policy suites are executed, and the
    native-only suites (XcodeGen/plutil, Mac process/CPU semantics) are not;
  * negative controls: the release-version gate stays a separate workflow, and
    the policy workflow must not silently grow network installs or secrets.
"""

from __future__ import annotations

from pathlib import Path
import unittest


SCRIPTS = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS.parent

POLICY_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "policy.yml"
RELEASE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "release-version.yml"

# Official actions/checkout v4.3.1, the pin the release-version gate already uses.
CHECKOUT_PIN = "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5"

# Confirmed Linux-portable policy suites (stdlib + fake commands only).
REQUIRED_PORTABLE_SCRIPTS = (
    "scripts/test_release_version.py",
    "scripts/test_cloud_bootstrap.py",
    "scripts/test_package_test_fixtures.py",
    "scripts/test_ci_policy.py",
)
# Need XcodeGen/plutil (dev_identity, release_metadata) or exercise Mac
# process/CPU semantics that belong on the Cloud/native path (verify_workflow).
NATIVE_ONLY_SCRIPTS = ("test_dev_identity", "test_release_metadata", "test_verify_workflow")


# --------------------------------------------------------------------------- #
# Minimal stdlib YAML reader for the workflow subset used in this repository.
# Supports: nested block mappings, block sequences ("- "), inline flow lists
# ("[a, b]"), and literal block scalars ("key: |"). It is intentionally small:
# it reads the contract we assert on rather than implementing YAML in full.
# --------------------------------------------------------------------------- #
class YamlSubsetError(ValueError):
    pass


def _scalar(token: str):
    token = token.strip()
    if len(token) >= 2 and token[0] == token[-1] and token[0] in "\"'":
        return token[1:-1]
    if token == "true":
        return True
    if token == "false":
        return False
    if token in ("null", "~", ""):
        return None
    try:
        return int(token)
    except ValueError:
        return token


def _value(token: str):
    token = token.strip()
    if token.startswith("[") and token.endswith("]"):
        inner = token[1:-1].strip()
        return [] if not inner else [_scalar(part) for part in inner.split(",")]
    return _scalar(token)


class _Reader:
    def __init__(self, lines):
        self.lines = lines
        self.i = 0

    def _peek(self):
        while self.i < len(self.lines):
            raw = self.lines[self.i]
            stripped = raw.strip()
            if stripped == "" or stripped.startswith("#"):
                self.i += 1
                continue
            return len(raw) - len(raw.lstrip(" ")), raw
        return None, None

    def parse(self, min_indent=0):
        indent, raw = self._peek()
        if raw is None or indent < min_indent:
            return None
        if raw.strip().startswith("- "):
            return self._parse_list(indent)
        return self._parse_map(indent)

    def _parse_map(self, indent):
        result = {}
        while True:
            cur, raw = self._peek()
            if raw is None or cur < indent:
                break
            if cur > indent:
                raise YamlSubsetError(f"unexpected indent: {raw!r}")
            text = raw.strip()
            if text.startswith("- "):
                break
            key, sep, value = text.partition(":")
            if not sep:
                raise YamlSubsetError(f"expected 'key:' in {raw!r}")
            key = _scalar(key)
            value = value.strip()
            self.i += 1
            if value in ("|", ">", "|-", ">-"):
                result[key] = self._block_scalar(indent)
            elif value == "":
                result[key] = self.parse(indent + 1)
            else:
                result[key] = _value(value)
        return result

    def _parse_list(self, indent):
        items = []
        while True:
            cur, raw = self._peek()
            if raw is None or cur != indent:
                break
            text = raw.strip()
            if not text.startswith("- "):
                break
            content = text[2:].strip()
            if content == "":
                self.i += 1
                items.append(self.parse(indent + 1))
            elif ":" in content and not content.startswith(("[", '"', "'")):
                # A mapping whose first key sits on the dash line.
                self.lines[self.i] = " " * (indent + 2) + content
                items.append(self._parse_map(indent + 2))
            else:
                self.i += 1
                items.append(_value(content))
        return items

    def _block_scalar(self, parent_indent):
        collected = []
        while self.i < len(self.lines):
            raw = self.lines[self.i]
            if raw.strip() == "":
                collected.append("")
                self.i += 1
                continue
            indent = len(raw) - len(raw.lstrip(" "))
            if indent <= parent_indent:
                break
            collected.append(raw)
            self.i += 1
        non_blank = [line for line in collected if line.strip()]
        if non_blank:
            base = min(len(line) - len(line.lstrip(" ")) for line in non_blank)
            collected = [line[base:] if line.strip() else "" for line in collected]
        return "\n".join(collected).rstrip("\n")


def load_workflow(text: str):
    return _Reader(text.split("\n")).parse(0)


def run_commands(workflow: dict) -> list:
    commands = []
    for job in workflow.get("jobs", {}).values():
        for step in job.get("steps", []):
            if "run" in step:
                commands.append(step["run"])
    return commands


def checkout_steps(workflow: dict) -> list:
    steps = []
    for job in workflow.get("jobs", {}).values():
        for step in job.get("steps", []):
            if str(step.get("uses", "")).startswith("actions/checkout@"):
                steps.append(step)
    return steps


class PolicyWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert POLICY_WORKFLOW.is_file(), "policy workflow is missing"
        cls.text = POLICY_WORKFLOW.read_text()
        cls.workflow = load_workflow(cls.text)
        cls.jobs = cls.workflow["jobs"]
        cls.commands = run_commands(cls.workflow)

    def test_has_a_single_policy_job_named_for_the_gate(self):
        self.assertEqual(len(self.jobs), 1, "the automatic gate is one portable job")
        job = next(iter(self.jobs.values()))
        self.assertEqual(job["name"], "Repository policy checks")

    def test_runs_on_ubuntu_latest_with_a_ten_minute_job_cap(self):
        for job in self.jobs.values():
            self.assertEqual(job["runs-on"], "ubuntu-latest")
            self.assertEqual(int(job["timeout-minutes"]), 10,
                             "the entire job must be capped at 10 minutes")

    def test_selects_pull_requests_to_main_without_pull_request_target(self):
        triggers = self.workflow["on"]
        self.assertIn("pull_request", triggers)
        self.assertEqual(triggers["pull_request"]["branches"], ["main"])
        self.assertNotIn("pull_request_target", triggers)

    def test_is_read_only_least_privilege(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertNotIn(": write", self.text)

    def test_cancels_superseded_runs(self):
        concurrency = self.workflow["concurrency"]
        self.assertTrue(concurrency["cancel-in-progress"])
        self.assertIn("policy-", concurrency["group"])

    def test_checks_out_the_verified_pin_without_credentials(self):
        checkout = checkout_steps(self.workflow)
        self.assertEqual(len(checkout), 1, "exactly one checkout step")
        self.assertEqual(checkout[0]["uses"], CHECKOUT_PIN)
        self.assertFalse(checkout[0]["with"]["persist-credentials"])

    def test_runs_every_required_portable_script(self):
        joined = "\n".join(self.commands)
        for script in REQUIRED_PORTABLE_SCRIPTS:
            self.assertIn(script, joined, f"the gate must run {script}")

    def test_does_not_run_native_only_scripts(self):
        joined = "\n".join(self.commands)
        for script in NATIVE_ONLY_SCRIPTS:
            self.assertNotIn(script, joined,
                             f"{script} is not Linux-portable and must stay off this gate")

    def test_never_invokes_native_tooling(self):
        joined = "\n".join(self.commands).lower()
        for token in ("xcodebuild", "xcodegen", "swiftlint", "xcrun", "plutil", "ditto"):
            self.assertNotIn(token, joined, f"portable gate must not call {token!r}")

    def test_uses_no_network_installs_or_secrets(self):
        for token in ("pip install", "brew install", "apt-get install", "npm install", " secrets."):
            self.assertNotIn(token, self.text)


class MigrationControlTests(unittest.TestCase):
    """Negative controls: the release-version gate stays a separate workflow."""

    @classmethod
    def setUpClass(cls):
        assert RELEASE_WORKFLOW.is_file(), "release-version workflow is missing"
        cls.policy_text = POLICY_WORKFLOW.read_text()
        cls.release = load_workflow(RELEASE_WORKFLOW.read_text())

    def test_release_version_gate_remains_its_own_workflow(self):
        self.assertIn("release-version", self.release["jobs"])
        self.assertNotIn("release_version.py check", self.policy_text,
                         "the release-version gate must not be folded into the policy job")

    def test_policy_gate_reuses_the_same_checkout_pin_as_release_version(self):
        release_checkout = checkout_steps(self.release)
        self.assertTrue(release_checkout, "release-version must check out source")
        self.assertEqual(release_checkout[0]["uses"], CHECKOUT_PIN)


if __name__ == "__main__":
    unittest.main(verbosity=2)
