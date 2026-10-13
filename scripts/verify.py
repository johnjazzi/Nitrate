#!/usr/bin/env python3
"""Run project lint and Xcode verification workflows."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import time
from datetime import datetime


ROOT = Path(__file__).resolve().parent.parent
PROJECT_NAME = "Nitrate"
PROJECT_FILE = ROOT / f"{PROJECT_NAME}.xcodeproj"
VERIFY_DIR = ROOT / "build" / "verification"
DERIVED_DATA = VERIFY_DIR / "DerivedData"
BUILD_LOCK = VERIFY_DIR / "build.lock"
LINT_LOCK = VERIFY_DIR / "lint.lock"
WATCH_PATHS = ("App", "CLI", "Tests", "Resources/Shaders", "project.yml", ".swiftlint.yml", "scripts/verify.py")
FINGERPRINT_CACHE: dict[Path, tuple[int, int, bytes]] = {}


def acquire_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        print(f"Another verification workflow owns {path.name}; exiting without waiting.", file=sys.stderr)
        raise SystemExit(2)
    return handle


def log_name(label: str) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    return VERIFY_DIR / f"{stamp}-{label}.log"


def run(label: str, args: list[str]) -> bool:
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    logfile = log_name(label)
    print(f"[{label}] {' '.join(args)}")
    with logfile.open("w") as output:
        try:
            result = subprocess.run(args, cwd=ROOT, stdout=output,
                                    stderr=subprocess.STDOUT, check=False)
            code = result.returncode
        except OSError as error:
            output.write(f"Could not start command: {error}\n")
            code = 127
    if code == 0:
        print(f"[{label}] passed (log: {logfile.relative_to(ROOT)})")
        return True
    print(f"[{label}] failed with exit code {code}; diagnostics (full log: {logfile.relative_to(ROOT)}):", file=sys.stderr)
    try:
        lines = logfile.read_text(errors="replace").splitlines()
    except OSError:
        lines = ["Could not read command log."]
    if not lines:
        lines = ["Command produced no output."]
    actionable = [line for line in lines if ": error:" in line or line.startswith("error:")]
    for line in (actionable or lines[-30:])[-30:]:
        print(line, file=sys.stderr)
    return False


def swiftlint() -> bool:
    executable = shutil.which("swiftlint")
    if not executable:
        print("SwiftLint is required but was not found on PATH.", file=sys.stderr)
        return False
    return run("lint", [executable, "lint", "--strict", "--quiet", "--cache-path",
                         str(VERIFY_DIR / "swiftlint-cache"), "--config", str(ROOT / ".swiftlint.yml")])


def xcodebuild(*args: str) -> list[str]:
    executable = shutil.which("xcodebuild")
    if not executable:
        print("xcodebuild was not found on PATH.", file=sys.stderr)
        raise SystemExit(127)
    return [executable, *args, "-derivedDataPath", str(DERIVED_DATA), "-quiet", "COMPILER_INDEX_STORE_ENABLE=YES"]


def generate_project() -> bool:
    executable = shutil.which("xcodegen")
    if not executable:
        print("xcodegen is required for check/verify/device and was not found on PATH.", file=sys.stderr)
        return False
    return run("xcodegen", [executable, "generate"])


def check() -> bool:
    lint_lock = acquire_lock(LINT_LOCK)
    try:
        if not swiftlint():
            return False
    finally:
        lint_lock.close()
    return compile_check()


def compile_check() -> bool:
    if not generate_project():
        return False
    return run("check", xcodebuild("-project", str(PROJECT_FILE),
                                    "-scheme", PROJECT_NAME, "-destination", "generic/platform=iOS",
                                    "build", "CODE_SIGNING_ALLOWED=NO"))


def verify() -> bool:
    if not generate_project():
        return False
    project = str(PROJECT_FILE)
    if not run("tests", xcodebuild("-project", project, "-scheme", "RenderCLI",
                                    "-destination", "platform=macOS", "test",
                                    "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=")):
        return False
    if not run("verify-build", xcodebuild("-project", project, "-scheme", PROJECT_NAME,
                                           "-destination", "generic/platform=iOS", "build",
                                           "CODE_SIGNING_ALLOWED=NO")):
        return False
    return run("diff-check", ["git", "diff", "--check"])


def device() -> bool:
    if not generate_project():
        return False
    return run("device", xcodebuild("-project", str(PROJECT_FILE),
                                     "-scheme", PROJECT_NAME, "-destination", "generic/platform=iOS",
                                     "build", "-allowProvisioningUpdates"))


def fingerprint() -> str:
    digest = hashlib.sha256()
    seen: set[Path] = set()
    for rel in WATCH_PATHS:
        path = ROOT / rel
        entries = sorted(path.rglob("*") if path.is_dir() else [path])
        for entry in entries:
            if not entry.is_file():
                continue
            seen.add(entry)
            digest.update(str(entry.relative_to(ROOT)).encode())
            try:
                metadata = entry.stat()
                cached = FINGERPRINT_CACHE.get(entry)
                if cached is None or cached[:2] != (metadata.st_mtime_ns, metadata.st_size):
                    cached = (metadata.st_mtime_ns, metadata.st_size,
                              hashlib.sha256(entry.read_bytes()).digest())
                    FINGERPRINT_CACHE[entry] = cached
                digest.update(cached[2])
            except OSError:
                digest.update(b"<unreadable>")
    for entry in FINGERPRINT_CACHE.keys() - seen:
        del FINGERPRINT_CACHE[entry]
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", choices=("lint", "check", "verify", "device", "watch"), default="check")
    mode = parser.parse_args().mode
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    if mode == "lint":
        lock = acquire_lock(LINT_LOCK)
        try:
            return 0 if swiftlint() else 1
        finally:
            lock.close()
    lock = acquire_lock(BUILD_LOCK)
    if mode == "watch":
        try:
            return watch_body()
        finally:
            lock.close()
    try:
        if mode == "check":
            okay = check()
        elif mode == "verify":
            lint_lock = acquire_lock(LINT_LOCK)
            try:
                if not swiftlint():
                    return 1
            finally:
                lint_lock.close()
            okay = verify()
        else:
            okay = device()
        return 0 if okay else 1
    finally:
        lock.close()


def watch_body() -> int:
    print("Watching App, CLI, Tests, Resources/Shaders, project.yml, .swiftlint.yml, and scripts/verify.py.")
    observed = fingerprint()
    while True:
        time.sleep(1)
        current = fingerprint()
        if current == observed:
            continue
        # Require a full quiet polling interval after the latest observed edit.
        while True:
            time.sleep(1)
            settled = fingerprint()
            if settled == current:
                break
            current = settled
        if current == observed:
            continue
        observed = current
        lint_lock = acquire_lock(LINT_LOCK)
        try:
            lint_ok = swiftlint()
        finally:
            lint_lock.close()
        check_ok = compile_check() if lint_ok else False
        if lint_ok and check_ok:
            print("Watch check passed.")


if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Stopped.")
        raise SystemExit(130)
