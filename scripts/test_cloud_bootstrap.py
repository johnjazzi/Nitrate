#!/usr/bin/env python3
"""Behavior checks for the Xcode Cloud post-clone bootstrap (no network needed)."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "ci_scripts" / "ci_post_clone.sh"


class CloudBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nitrate-cloud-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "checkout with spaces"
        self.root.mkdir()
        (self.root / "project.yml").write_text("name: Nitrate\n")
        self.env = dict(os.environ, CI_PRIMARY_REPOSITORY_PATH=str(self.root))

    def seed_tools(self, generates_project=True):
        tools = self.root / "build" / "ci-tools"
        generator = tools / "xcodegen-2.46.0" / "xcodegen" / "bin" / "xcodegen"
        generator.parent.mkdir(parents=True)
        actions = (
            'mkdir -p Nitrate.xcodeproj/xcshareddata/xcschemes\n'
            'touch Nitrate.xcodeproj/project.pbxproj\n'
            'touch Nitrate.xcodeproj/xcshareddata/xcschemes/Nitrate.xcscheme\n'
            if generates_project else 'true\n'
        )
        generator.write_text(
            '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "Version: 2.46.0"; exit 0; fi\n'
            'printf "%s\\n" "$PWD" "$*" > bootstrap-invocation.txt\n' + actions
        )
        generator.chmod(0o755)
        linter = tools / "swiftlint-0.65.1" / "swiftlint"
        linter.parent.mkdir(parents=True)
        linter.write_text('#!/bin/sh\necho "0.65.1"\n')
        linter.chmod(0o755)

    def run_bootstrap(self):
        self.assertTrue(SCRIPT.is_file(), "Cloud needs ci_scripts/ci_post_clone.sh before dependency resolution")
        return subprocess.run(["/bin/sh", str(SCRIPT)], env=self.env,
                              cwd=self.temp.name, text=True, capture_output=True, timeout=30)

    def test_post_clone_exists_and_is_executable(self):
        self.assertTrue(SCRIPT.is_file(), "Missing post-clone script reproduces Cloud's missing-project error")
        self.assertTrue(os.access(SCRIPT, os.X_OK), "Cloud script must retain its executable mode in Git")

    def test_generates_shared_project_from_clean_checkout_and_arbitrary_directory(self):
        self.seed_tools()
        self.assertFalse((self.root / "Nitrate.xcodeproj").exists())
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "Nitrate.xcodeproj" / "project.pbxproj").is_file())
        invocation = (self.root / "bootstrap-invocation.txt").read_text()
        self.assertIn(str(self.root), invocation)
        self.assertIn("generate --spec project.yml", invocation)

    def test_missing_generated_project_fails_instead_of_claiming_success(self):
        self.seed_tools(generates_project=False)
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Nitrate.xcodeproj", result.stdout + result.stderr)

    def test_failed_download_fails_without_running_generator(self):
        commands = Path(self.temp.name) / "commands"
        commands.mkdir()
        curl = commands / "curl"
        curl.write_text('#!/bin/sh\necho "injected download failure" >&2\nexit 22\n')
        curl.chmod(0o755)
        self.env["PATH"] = str(commands) + os.pathsep + os.environ["PATH"]
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("injected download failure", result.stderr)
        self.assertFalse((self.root / "bootstrap-invocation.txt").exists())

    def test_bad_archive_checksum_fails_before_extracting_or_generating(self):
        commands = Path(self.temp.name) / "commands"
        commands.mkdir()
        curl = commands / "curl"
        curl.write_text('''#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--output" ]; then printf "tampered archive" > "$2"; exit 0; fi
    shift
done
exit 2
''')
        curl.chmod(0o755)
        self.env["PATH"] = str(commands) + os.pathsep + os.environ["PATH"]
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum", (result.stdout + result.stderr).lower())
        self.assertFalse((self.root / "bootstrap-invocation.txt").exists())

    def test_checkout_does_not_track_a_machine_local_build_link(self):
        # A build/ symlink to the developer's machine makes Cloud's first mkdir
        # fail before tool download or test execution. Check the index, not the
        # local filesystem, so an ignored local cache link remains permitted.
        result = subprocess.run(
            ["git", "ls-files", "--stage", "--", "build"], cwd=ROOT,
            text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout, "", "Build outputs or cache links must never be tracked")

    def test_generated_build_phase_can_find_bootstrapped_swiftlint(self):
        spec = (ROOT / "project.yml").read_text()
        self.assertIn('$SRCROOT/build/ci-tools/swiftlint-0.65.1', spec,
                      "Post-clone PATH does not propagate into later xcodebuild processes")


if __name__ == "__main__":
    unittest.main(verbosity=2)
