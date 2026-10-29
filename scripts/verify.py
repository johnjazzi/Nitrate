#!/usr/bin/env python3
"""Run project lint and Xcode verification workflows."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
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

# Opt-in CI diagnostics. Local runs keep their previous behavior: no streaming,
# `-quiet` stays on, and no watchdog. CI exports these to observe a hang instead
# of waiting out the whole job timeout.
DIAGNOSTICS_ENV = "NITRATE_VERIFY_DIAGNOSTICS"
TEST_TIMEOUT_ENV = "NITRATE_VERIFY_TEST_TIMEOUT_SECONDS"
COMMAND_TIMEOUT_ENV = "NITRATE_VERIFY_COMMAND_TIMEOUT_SECONDS"
SAMPLE_SECONDS_ENV = "NITRATE_VERIFY_SAMPLE_SECONDS"
DEFAULT_TEST_TIMEOUT_SECONDS = 600
DEFAULT_COMMAND_TIMEOUT_SECONDS = 600
DEFAULT_SAMPLE_SECONDS = 10
TIMEOUT_EXIT_CODE = 124
TERMINATE_GRACE_SECONDS = 10
SAMPLE_TARGET_LIMIT = 2


@dataclass
class CommandResult:
    label: str
    exit_code: int
    logfile: Path
    timed_out: bool = False
    timeout: float = 0.0

    @property
    def ok(self) -> bool:
        return self.exit_code == 0 and not self.timed_out


def _flag(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def diagnostics_enabled() -> bool:
    return _flag(DIAGNOSTICS_ENV)


def _env_seconds(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = float(raw)
    except ValueError:
        print(f"Ignoring non-numeric {name}={raw!r}; using {default:g}.", file=sys.stderr)
        return default
    if value < 0:
        print(f"Ignoring negative {name}={raw!r}; using {default:g}.", file=sys.stderr)
        return default
    return value


def resolve_timeout(kind: str, explicit: float | None) -> float | None:
    """Return the watchdog budget in seconds, or None to wait indefinitely."""
    if explicit is not None:
        return explicit
    if not diagnostics_enabled():
        return None
    if kind == "test":
        return _env_seconds(TEST_TIMEOUT_ENV, DEFAULT_TEST_TIMEOUT_SECONDS)
    return _env_seconds(COMMAND_TIMEOUT_ENV, DEFAULT_COMMAND_TIMEOUT_SECONDS)


def sample_seconds() -> float:
    return _env_seconds(SAMPLE_SECONDS_ENV, DEFAULT_SAMPLE_SECONDS)


def verification_diagnostics_path(logfile: Path) -> Path:
    return logfile.with_name(f"{logfile.stem}.diagnostics.txt")


def verification_sample_path(logfile: Path, pid: int) -> Path:
    return logfile.with_name(f"{logfile.stem}-{pid}.sample.txt")


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


def _emit(output, lock: threading.Lock, text: str) -> None:
    with lock:
        output.write(text)
        output.flush()
        sys.stdout.write(text)
        sys.stdout.flush()


def _process_group_members(pgid: int | None) -> list[tuple[int, int, str]]:
    """Bounded `ps` snapshot of the process group; never blocks the watchdog."""
    try:
        listing = subprocess.run(
            ["ps", "-A", "-o", "pid=,ppid=,pgid=,stat=,etime=,comm="],
            capture_output=True, text=True, timeout=5, check=False,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    members: list[tuple[int, int, str]] = []
    for line in listing.splitlines():
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        pid, ppid, group, stat, etime, command = parts
        try:
            if pgid is not None and int(group) != pgid:
                continue
        except ValueError:
            continue
        members.append((int(pid), int(ppid), f"pid={pid} ppid={ppid} pgid={group} stat={stat} etime={etime} {command}"))
    return members


def _sample_targets(members: list[tuple[int, int, str]], leader: int) -> list[tuple[int, str]]:
    parents = {pid: ppid for pid, ppid, _description in members}
    targets = [(pid, description) for pid, _ppid, description in members if pid == leader][:1]

    def descends_from_leader(pid: int) -> bool:
        visited: set[int] = set()
        while pid in parents and pid not in visited:
            if pid == leader:
                return True
            visited.add(pid)
            pid = parents[pid]
        return False

    candidates = []
    for pid, _ppid, description in members:
        if pid == leader or "stat=Z" in description:
            continue
        command = description.split(None, 5)[-1].lower()
        name = Path(command).name
        # Never spend the runner sample slot on system testmanagerd services.
        is_rendercli = name.startswith("rendercli")
        if is_rendercli or name in {"xctest", "swift-testing"} or ".xctest/" in command:
            candidates.append((not descends_from_leader(pid), not is_rendercli, pid, description))
    targets.extend((pid, description) for _unowned, _generic, pid, description in sorted(candidates))
    return targets[:SAMPLE_TARGET_LIMIT]


def _capture_samples(logfile: Path, members: list[tuple[int, int, str]], leader: int) -> list[str]:
    notes: list[str] = []
    budget = sample_seconds()
    if budget <= 0:
        notes.append("sample: skipped (budget disabled)")
        return notes
    executable = shutil.which("sample")
    if not executable:
        notes.append("sample: skipped (no `sample` on PATH)")
        return notes
    for pid, description in _sample_targets(members, leader):
        path = verification_sample_path(logfile, pid)
        try:
            result = subprocess.run([executable, str(pid), str(int(budget)), "-file", str(path)],
                           timeout=budget + 10, check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired):
            notes.append(f"sample: pid {pid} capture failed or timed out")
            continue
        if result.returncode != 0 or not path.is_file() or path.stat().st_size == 0:
            notes.append(f"sample: pid {pid} capture failed (exit {result.returncode}; no verified stack capture)")
            continue
        notes.append(f"sample: {description} -> {path.name}")
    if not notes:
        notes.append("sample: no process in group to sample")
    return notes


def _capture_and_stop(label: str, process: subprocess.Popen, logfile: Path,
                      output, lock: threading.Lock, timeout: float) -> int:
    _emit(output, lock, f"\n[verify watchdog] {label} exceeded {timeout:g}s; collecting diagnostics.\n")
    diagnostics = verification_diagnostics_path(logfile)
    # Popen(start_new_session=True) makes this PID the owned process-group ID.
    # Keep it even if the leader has exited: descendants may still own stdout.
    pgid = process.pid
    members = _process_group_members(pgid)

    lines = [
        f"label: {label}",
        f"timeout_seconds: {timeout:g}",
        f"process_group: {pgid}",
        f"process_tree ({len(members)} process(es)):",
    ]
    lines += [f"  {description}" for _pid, _ppid, description in members] or ["  (none observed)"]
    # Xcode can ask launchd to start xctest outside its own group. Read-only
    # diagnostics may inspect it, but termination below stays within our group.
    snapshot = _process_group_members(None)
    lines += ["system process snapshot (executable names only):"]
    lines += [f"  {description}" for _pid, _ppid, description in snapshot]
    lines += _capture_samples(logfile, snapshot, process.pid)
    diagnostics.write_text("\n".join(lines) + "\n")
    _emit(output, lock, f"[verify watchdog] diagnostics written to {diagnostics.name}\n")

    def group_exists() -> bool:
        # On macOS, killpg(group, 0) can report EPERM for a dying group.
        # Inspect the bounded process snapshot instead; zombies hold no pipes.
        process.poll()
        return any("stat=Z" not in description
                   for _pid, _ppid, description in _process_group_members(pgid))

    if pgid != os.getpgrp():
        _emit(output, lock, f"[verify watchdog] sending SIGTERM to process group {pgid}\n")
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + TERMINATE_GRACE_SECONDS
        while group_exists() and time.monotonic() < deadline:
            # Reap the leader, but do not confuse its exit with all children exiting.
            process.poll()
            time.sleep(0.2)
        if group_exists():
            _emit(output, lock, f"[verify watchdog] sending SIGKILL to process group {pgid}\n")
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    elif process.poll() is None:
        process.kill()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        _emit(output, lock, "[verify watchdog] process did not exit after SIGKILL\n")
    return TIMEOUT_EXIT_CODE


def _run_streaming(label: str, args: list[str], logfile: Path, timeout: float | None) -> tuple[int, bool]:
    timed_out = False
    deadline = time.monotonic() + timeout if timeout and timeout > 0 else None
    lock = threading.Lock()
    with logfile.open("w", encoding="utf-8") as output:
        try:
            process = subprocess.Popen(
                args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", bufsize=1,
                start_new_session=True,
            )
        except OSError as error:
            output.write(f"Could not start command: {error}\n")
            return 127, False

        def pump():
            assert process.stdout is not None
            for line in process.stdout:
                _emit(output, lock, line)

        reader = threading.Thread(target=pump, name=f"{label}-output", daemon=True)
        reader.start()
        wait_timeout = max(0, deadline - time.monotonic()) if deadline is not None else None
        try:
            code = process.wait(timeout=wait_timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            code = _capture_and_stop(label, process, logfile, output, lock, timeout or 0.0)
        drain_timeout = max(0, deadline - time.monotonic()) if deadline is not None and not timed_out else 10
        reader.join(timeout=drain_timeout)
        if reader.is_alive() and not timed_out:
            timed_out = True
            code = _capture_and_stop(label, process, logfile, output, lock, timeout or 0.0)
            reader.join(timeout=5)
        if reader.is_alive():
            _emit(output, lock, "[verify watchdog] output reader did not stop after process exit\n")
        elif process.stdout is not None:
            # TextIO.close can wait on a reader's lock; never call it while the
            # pump still owns a read from an inherited stdout pipe.
            process.stdout.close()
    return code, timed_out


def execute(label: str, args: list[str], *, timeout: float | None = None, kind: str = "command") -> CommandResult:
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    logfile = log_name(label)
    print(f"[{label}] {' '.join(args)}")
    effective = resolve_timeout(kind, timeout)

    if not diagnostics_enabled():
        with logfile.open("w") as output:
            try:
                result = subprocess.run(args, cwd=ROOT, stdout=output,
                                        stderr=subprocess.STDOUT, check=False)
                code = result.returncode
            except OSError as error:
                output.write(f"Could not start command: {error}\n")
                code = 127
        return CommandResult(label, code, logfile, False, effective or 0.0)

    code, timed_out = _run_streaming(label, args, logfile, effective)
    return CommandResult(label, code, logfile, timed_out, effective or 0.0)


def _print_failure_excerpt(logfile: Path) -> None:
    try:
        lines = logfile.read_text(errors="replace").splitlines()
    except OSError:
        lines = ["Could not read command log."]
    if not lines:
        lines = ["Command produced no output."]
    actionable = [line for line in lines if ": error:" in line or line.startswith("error:")]
    for line in (actionable or lines[-30:])[-30:]:
        print(line, file=sys.stderr)


def run(label: str, args: list[str], *, timeout: float | None = None, kind: str = "command") -> bool:
    result = execute(label, args, timeout=timeout, kind=kind)
    if result.ok:
        print(f"[{label}] passed (log: {result.logfile.relative_to(ROOT)})")
        return True
    if result.timed_out:
        print(f"[{label}] timed out after {result.timeout:g}s and was stopped "
              f"(log: {result.logfile.relative_to(ROOT)}):", file=sys.stderr)
    else:
        print(f"[{label}] failed with exit code {result.exit_code}; diagnostics "
              f"(full log: {result.logfile.relative_to(ROOT)}):", file=sys.stderr)
    _print_failure_excerpt(result.logfile)
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
    # Keep local verification bounded; workers must not start their own builds.
    raw_jobs = os.environ.get("NITRATE_VERIFY_JOBS", "2")
    try:
        jobs = int(raw_jobs)
        if jobs < 1:
            raise ValueError
    except ValueError:
        print("NITRATE_VERIFY_JOBS must be a positive integer.", file=sys.stderr)
        raise SystemExit(2)
    command = [executable, *args, "-jobs", str(jobs),
               f"SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS={jobs}",
               "-derivedDataPath", str(DERIVED_DATA)]
    if not diagnostics_enabled():
        command.append("-quiet")
    command.append("COMPILER_INDEX_STORE_ENABLE=YES")
    return command


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
    if not run("dev-identity-tests", [sys.executable, str(ROOT / "scripts" / "test_dev_identity.py")], kind="test"):
        return False
    if not run("release-version-tests", [sys.executable, str(ROOT / "scripts" / "test_release_version.py")], kind="test"):
        return False
    if not run("release-metadata-tests", [sys.executable, str(ROOT / "scripts" / "test_release_metadata.py")], kind="test"):
        return False
    if not run("cloud-bootstrap-tests", [sys.executable, str(ROOT / "scripts" / "test_cloud_bootstrap.py")], kind="test"):
        return False
    if not run("test-fixture-tests", [sys.executable, str(ROOT / "scripts" / "test_package_test_fixtures.py")], kind="test"):
        return False
    if not run("ci-policy-tests", [sys.executable, str(ROOT / "scripts" / "test_ci_policy.py")], kind="test"):
        return False
    if not run("verify-workflow-tests", [sys.executable, str(ROOT / "scripts" / "test_verify_workflow.py")], kind="test"):
        return False
    if not generate_project():
        return False
    project = str(PROJECT_FILE)
    if not run("tests", xcodebuild("-project", project, "-scheme", "RenderCLI",
                                    "-destination", "platform=macOS", "test",
                                    "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM="), kind="test"):
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
