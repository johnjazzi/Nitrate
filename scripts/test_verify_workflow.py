#!/usr/bin/env python3
"""Behavior checks for CI verification diagnostics and the test watchdog.

The tests drive ``scripts/verify.py`` with short-lived fake commands only.
They never invoke Xcode, SwiftLint, or ``sample``, and the timeout case only
signals a process group created by the test itself.
"""

from __future__ import annotations

import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

import verify  # noqa: E402  (path setup is intentional for direct execution)


class VerifyCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nitrate-verify-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.verify_dir = self.root / "build" / "verification"
        root_patch = mock.patch.object(verify, "ROOT", self.root)
        dir_patch = mock.patch.object(verify, "VERIFY_DIR", self.verify_dir)
        root_patch.start()
        dir_patch.start()
        self.addCleanup(root_patch.stop)
        self.addCleanup(dir_patch.stop)
        env_patch = mock.patch.dict(os.environ, {
            verify.DIAGNOSTICS_ENV: "1",
            verify.TEST_TIMEOUT_ENV: "5",
            verify.COMMAND_TIMEOUT_ENV: "5",
            verify.SAMPLE_SECONDS_ENV: "0",
        })
        env_patch.start()
        self.addCleanup(env_patch.stop)

    def logs(self) -> list[Path]:
        return sorted(self.verify_dir.glob("*.log"))

    def run_captured(self, label, args, **kwargs):
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            okay = verify.run(label, args, **kwargs)
        return okay, captured.getvalue()

    def test_streams_output_live_and_retains_full_log(self):
        script = (
            "import sys\n"
            "print('first-line')\n"
            "print('second-line', file=sys.stderr)\n"
            "raise SystemExit(0)\n"
        )
        okay, streamed = self.run_captured("stream-test", [sys.executable, "-c", script], kind="test")
        self.assertTrue(okay)
        self.assertIn("first-line", streamed)
        self.assertIn("second-line", streamed)
        log = self.logs()[0].read_text()
        self.assertIn("first-line", log)
        self.assertIn("second-line", log)

    def test_streams_before_the_child_exits(self):
        acknowledgement = self.root / "stream-observed"
        script = (
            "import pathlib,time\n"
            "print('EARLY_READY', flush=True)\n"
            f"ack = pathlib.Path({str(acknowledgement)!r})\n"
            "deadline = time.monotonic() + 2\n"
            "while not ack.exists() and time.monotonic() < deadline: time.sleep(0.01)\n"
            "raise SystemExit(0 if ack.exists() else 6)\n"
        )

        class ObservedStream(io.StringIO):
            def write(self, text):
                if text == "EARLY_READY\n":
                    acknowledgement.write_text("received while child is running")
                return super().write(text)

        with contextlib.redirect_stdout(ObservedStream()):
            result = verify.execute("live-stream-test", [sys.executable, "-c", script], kind="test")
        self.assertTrue(result.ok, "The child waits for its output to be streamed before exiting")
        self.assertTrue(acknowledgement.exists())

    def test_propagates_exact_nonzero_exit_status(self):
        result = verify.execute("exit-test", [sys.executable, "-c", "raise SystemExit(7)"], kind="test")
        self.assertEqual(result.exit_code, 7)
        self.assertFalse(result.timed_out)
        self.assertFalse(result.ok)
        okay, _ = self.run_captured("exit-test", [sys.executable, "-c", "raise SystemExit(7)"], kind="test")
        self.assertFalse(okay)

    def test_timeout_stops_process_tree_and_cannot_report_pass(self):
        pidfile = self.root / "child.pid"
        script = (
            "import subprocess, sys, time\n"
            "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])\n"
            f"open({str(pidfile)!r}, 'w').write(str(child.pid))\n"
            "time.sleep(120)\n"
        )
        started = time.monotonic()
        result = verify.execute("timeout-test", [sys.executable, "-c", script],
                                timeout=0.75, kind="test")
        elapsed = time.monotonic() - started
        self.assertTrue(result.timed_out)
        self.assertEqual(result.exit_code, verify.TIMEOUT_EXIT_CODE)
        self.assertNotEqual(result.exit_code, 0)
        self.assertLess(elapsed, 15, "watchdog must not wait for the full sleep")
        self.assertFalse(verify.run("timeout-test", [sys.executable, "-c", script],
                                    timeout=0.75, kind="test"),
                         "a timed-out command must never be reported as passing")
        child_pid = int(pidfile.read_text())
        deadline = time.monotonic() + 5
        while True:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                self.fail(f"child process {child_pid} survived the watchdog")
            time.sleep(0.05)
        # The test's own process must be intact: only the new group is signalled.
        os.kill(os.getpid(), 0)

    def test_timeout_kills_stubborn_child_even_after_group_leader_exits(self):
        pidfile = self.root / "stubborn.pid"
        child_code = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(3)"
        script = (
            "import subprocess,sys,time\n"
            f"child = subprocess.Popen([sys.executable, '-c', {child_code!r}])\n"
            f"open({str(pidfile)!r}, 'w').write(str(child.pid))\n"
            "time.sleep(30)\n"
        )
        started = time.monotonic()
        with mock.patch.object(verify, "TERMINATE_GRACE_SECONDS", 0.2):
            result = verify.execute("stubborn-test", [sys.executable, "-c", script], timeout=0.5, kind="test")
        self.assertTrue(result.timed_out)
        self.assertFalse(result.ok)
        self.assertLess(time.monotonic() - started, 2,
                        "The leader exiting must not skip SIGKILL of surviving group members")

    def test_child_holding_stdout_cannot_outlive_the_command_deadline(self):
        script = (
            "import subprocess,sys\n"
            "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(3)'])\n"
        )
        started = time.monotonic()
        with mock.patch.object(verify, "TERMINATE_GRACE_SECONDS", 0.2):
            result = verify.execute("orphan-output-test", [sys.executable, "-c", script], timeout=0.5)
        self.assertTrue(result.timed_out, "The deadline includes descendants keeping the output pipe open")
        self.assertFalse(result.ok)
        self.assertLess(time.monotonic() - started, 2)

    def test_stack_sample_filename_matches_the_artifact_upload_glob(self):
        import fnmatch
        sample = verify.verification_sample_path(Path("test.log"), 123)
        self.assertTrue(fnmatch.fnmatch(sample.name, "*.sample.txt"),
                        "Captured samples must match the workflow's artifact pattern")

    def test_timeout_retains_bounded_diagnostics_evidence(self):
        result = verify.execute("evidence-test", [sys.executable, "-c", "import time; time.sleep(30)"],
                                timeout=0.4, kind="test")
        self.assertTrue(result.timed_out)
        diagnostics = verify.verification_diagnostics_path(result.logfile)
        self.assertTrue(diagnostics.is_file(), "timeout must leave a diagnostics record")
        text = diagnostics.read_text()
        self.assertIn("timeout", text.lower())
        self.assertIn("process", text.lower())
        self.assertIn("watchdog", result.logfile.read_text().lower())

    def test_quiet_flag_only_disappears_in_diagnostics_mode(self):
        with mock.patch.object(verify.shutil, "which", return_value="/usr/bin/xcodebuild"):
            with mock.patch.dict(os.environ, {verify.DIAGNOSTICS_ENV: "0"}):
                local = verify.xcodebuild("-project", "Example.xcodeproj")
            with mock.patch.dict(os.environ, {verify.DIAGNOSTICS_ENV: "1"}):
                ci = verify.xcodebuild("-project", "Example.xcodeproj")
        self.assertIn("-quiet", local)
        self.assertNotIn("-quiet", ci)
        self.assertEqual(local[-1], "COMPILER_INDEX_STORE_ENABLE=YES")
        self.assertEqual(ci[-1], "COMPILER_INDEX_STORE_ENABLE=YES")

    def test_default_budgets_are_bounded_and_local_mode_has_no_timeout(self):
        with mock.patch.dict(os.environ, {verify.DIAGNOSTICS_ENV: "1"}, clear=True):
            self.assertEqual(verify.resolve_timeout("test", None), 600)
            self.assertEqual(verify.resolve_timeout("command", None), 1800)
        with mock.patch.dict(os.environ, {verify.DIAGNOSTICS_ENV: "0"}, clear=False):
            self.assertIsNone(verify.resolve_timeout("test", None))

    def test_invalid_or_negative_budget_falls_back_to_default(self):
        with mock.patch.dict(os.environ, {
            verify.DIAGNOSTICS_ENV: "1",
            verify.TEST_TIMEOUT_ENV: "not-a-number",
        }, clear=False):
            self.assertEqual(verify.resolve_timeout("test", None), 600)
        with mock.patch.dict(os.environ, {
            verify.DIAGNOSTICS_ENV: "1",
            verify.TEST_TIMEOUT_ENV: "-5",
        }, clear=False):
            self.assertEqual(verify.resolve_timeout("test", None), 600)


class WorkflowPolicyTests(unittest.TestCase):
    workflow = (REPO_ROOT / ".github" / "workflows" / "xcode.yml").read_text()

    def test_enables_opt_in_diagnostics_with_ten_minute_test_budget(self):
        self.assertIn('NITRATE_VERIFY_DIAGNOSTICS: "1"', self.workflow)
        self.assertIn('NITRATE_VERIFY_TEST_TIMEOUT_SECONDS: "600"', self.workflow)
        self.assertIn("python3 scripts/verify.py verify", self.workflow)

    def test_uploads_diagnostics_on_always_without_unbounded_bundles(self):
        self.assertIn("if: always()", self.workflow)
        self.assertIn("build/verification/*.diagnostics.txt", self.workflow)
        self.assertIn("build/verification/*.sample.txt", self.workflow)
        self.assertIn("build/verification/partial-xcresult.txt", self.workflow)
        self.assertNotIn("DerivedData/**", self.workflow)
        self.assertNotIn(".xcresult\n", self.workflow)

    def test_job_timeout_leaves_room_but_is_not_the_test_budget(self):
        self.assertIn("timeout-minutes: 30", self.workflow)

    def test_verify_wires_the_diagnostics_test_script(self):
        source = (REPO_ROOT / "scripts" / "verify.py").read_text()
        self.assertIn("test_verify_workflow.py", source)
        self.assertIn('kind="test"', source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
