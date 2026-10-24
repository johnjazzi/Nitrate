#!/usr/bin/env python3
"""Package the runtime fixtures the Swift test suites read from the source tree.

Apple Cloud Test runs the test-execution phase *without a source checkout*, so
any Swift test that resolves a repository-relative path through ``#filePath``
fails there. ``Tests/TestRepository.swift`` prefers a snapshot of the
allowlisted fixtures packaged into the test bundle, and falls back to the
``#filePath`` checkout for local runs; this script produces that snapshot while
the checkout still exists (invoked from a test-target build phase).

Design notes
------------
* **Explicit allowlist.** Only the files the suites actually read at runtime are
  copied. Nothing is discovered by walking the tree, so credentials, ``.git``,
  ``build``, and the user-owned ``docs/prioritization*`` files can never be
  packaged even by accident.
* **Generated, never committed.** The snapshot is written into the built test
  bundle (DerivedData / build), not into the source tree. No large LUT or grain
  asset is duplicated into Git; ``Resources/Grain`` in particular is excluded
  because the test target already bundles ``grain3d.raw`` and no test reads it
  through the repository root.
* **Fail closed.** A missing required file, a glob that matches nothing, a path
  (or symlink target) that resolves outside the checkout, an excluded identity
  reached through a symlink, an absolute or traversal token, or an output that
  overlaps the source tree aborts the run before anything is written.
* **Exact on repeat.** A small ownership manifest records the files written
  last time; files that are no longer fixtures are pruned from the snapshot,
  each file is replaced atomically, and only files we previously wrote are ever
  removed — unrelated output, media, and the source tree are never touched.
* **Deterministic.** Entries are sorted and copied byte-for-byte, so two runs
  produce an identical snapshot.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from typing import Iterable, Sequence


SNAPSHOT_DIRECTORY_NAME = "test-repository"

# Name of the ownership manifest that lives beside the packaged files. It lists
# exactly the relative paths this script wrote, so a later run can prune only
# its own stale output and never a user's unrelated files.
MANIFEST_NAME = ".package-test-fixtures-manifest.json"

# Exact files the suites read through ``TestRepository.root``. Keep this in step
# with the ``#filePath`` reads in ``Tests`` — every source-contract test that
# reads a file by relative path must be listed here.
FILE_FIXTURES: tuple[str, ...] = (
    # Render source-of-truth config and shaders.
    "Resources/stocks.json",
    "Resources/Shaders/camera-preview.metal",
    "Resources/Shaders/pipeline.metal",
    "Resources/Shaders/spatial.metal",
    "App/Resources/stocks.json",
    "App/Resources/Preview/AppleLog2ToRec709.cube",
    "App/PrivacyInfo.xcprivacy",
    "Tests/Fixtures/colorchecker-babelcolor-2006.json",
    # App sources read by source-contract tests.
    "App/Resources/Fonts/Barlow-Medium.ttf",
    "App/Resources/Fonts/barlow-OFL.txt",
    "App/Design/NitrateTypography.swift",
    "App/App.swift",
    "App/ContentView.swift",
    "App/Modules/CameraCapture/CameraHaptics.swift",
    "App/Modules/CameraCapture/CameraTopPanelLayout.swift",
    "App/Modules/CameraCapture/RecordingTallyLight.swift",
    "App/Modules/CameraCapture/CameraViewModel.swift",
    "App/Modules/CameraCapture/FocalPinchZoom.swift",
    "App/Modules/CameraCapture/RulerSlider.swift",
    "App/Modules/CameraCapture/ExposureRescueControl.swift",
    "App/Modules/CameraCapture/CameraControlBar.swift",
    "App/Modules/CameraCapture/ExposureOverlay.swift",
    "App/Modules/CameraCapture/MeteringBoxView.swift",
    "App/Modules/CameraCapture/CameraLensSelector.swift",
    "App/Modules/CameraCapture/CameraLensFace.swift",
    "App/Modules/CameraCapture/ManualFocusRuler.swift",
    "App/Modules/CameraCapture/FrameRulerPlacement.swift",
    "App/Modules/CameraCapture/FrameZoomRuler.swift",
    "App/Modules/CameraCapture/InlineManualControls.swift",
    "App/Modules/CameraCapture/CameraManualControlsFeatureFlags.swift",
    "App/Modules/CameraCapture/CameraPreviewPolicy.swift",
    "App/Modules/FilmStockLibrary/StockSamplePreview.swift",
    "App/Modules/CameraCapture/CameraPreviewRenderer.swift",
    "App/Modules/CameraCapture/CameraPreviewTap.swift",
    "App/Modules/CameraCapture/CameraSampleBufferRecorder.swift",
    "App/Modules/CameraCapture/CameraSession.swift",
    "App/Modules/CameraCapture/CameraView.swift",
    "App/Modules/CameraCapture/DebugFrameSheet.swift",
    "App/Modules/CameraCapture/RecordingTimeLCD.swift",
    "App/Modules/CameraCapture/RecordingFailureOverlay.swift",
    "App/Modules/CameraCapture/CameraRaisedButtonStyle.swift",
    "App/Modules/CameraCapture/ManualControlsOverlay.swift",
    "App/Modules/CameraCapture/ManualControlsPanel.swift",
    "App/Modules/CameraCapture/ManualControlsSurface.swift",
    "App/Modules/Purchase/PurchaseView.swift",
    "App/Modules/Purchase/SettingsSelectionRow.swift",
    "App/Modules/RenderQueue/RenderQueueViewModel.swift",
    "App/Modules/RenderQueue/QueueReceiptViews.swift",
    "App/Modules/RenderQueue/QueueSheetView.swift",
    "App/Modules/RenderQueue/PhotosLibraryOpener.swift",
    "App/Modules/VideoImport/VideoImportSheet.swift",
    "App/Modules/VideoImport/VideoImportPresentation.swift",
)

# The shipped Resolve LUT set is read as one directory (the catalogue test
# asserts all eight cubes are present), so it is packaged as a glob.
GLOB_FIXTURES: tuple[str, ...] = (
    "Resources/LUTs/*.cube",
)

# Never packaged, even if an allowlist entry matched. ``.git``, ``build`` and the
# user-owned prioritisation notes are not fixtures; the grain volume and any
# credentials must never leave the checkout.
EXCLUDED_PREFIXES: tuple[str, ...] = (
    ".git/",
    "build/",
    "docs/prioritization",
)
EXCLUDED_GLOBS: tuple[str, ...] = (
    "Resources/Grain/*",
    "App/Resources/Grain/*",
    "*.raw",
    "*credential*",
    "*.pem",
    "*.p12",
    "*.mobileprovision",
    "*.cer",
    "*.key",
    ".env",
)


class FixtureError(RuntimeError):
    """A required fixture is missing, unsafe, or excluded."""


def _normalise(relative: str) -> str:
    """Return ``relative`` as a literal, safe repo-relative path.

    The token is never repaired: leading dots are part of the identity (``.env``
    and ``.git/config`` must stay recognisable to the exclusion rules and to the
    writer), and absolute or traversal tokens are rejected outright rather than
    silently rewritten into something that happens to resolve.
    """
    if not isinstance(relative, str) or relative == "":
        raise FixtureError(f"empty fixture path: {relative!r}")
    normalized = relative.replace(os.sep, "/")
    if normalized.startswith("/"):
        raise FixtureError(f"fixture path must be relative: {relative!r}")
    if len(normalized) >= 2 and normalized[1] == ":":
        raise FixtureError(f"fixture path must not carry a drive prefix: {relative!r}")
    if any(segment in ("", ".", "..") for segment in normalized.split("/")):
        raise FixtureError(f"fixture path is not a clean relative path: {relative!r}")
    return normalized


def _is_excluded(relative: str) -> bool:
    normalized = _normalise(relative)
    if not normalized:
        return False
    for prefix in EXCLUDED_PREFIXES:
        if normalized == prefix.rstrip("/") or normalized.startswith(prefix):
            return True
    basename = normalized.rsplit("/", 1)[-1]
    for pattern in EXCLUDED_GLOBS:
        if fnmatch.fnmatch(normalized, pattern) or fnmatch.fnmatch(basename, pattern):
            return True
    return False


def _resolve_within(repo_root: Path, candidate: Path) -> Path:
    """Real path of ``candidate``, failing closed if it escapes ``repo_root``.

    A symlink that stays inside the checkout but resolves to an excluded path
    (e.g. ``App/ContentView.swift -> .env``) is rejected too: the exclusion
    rules describe identities, not just spellings.
    """
    root = Path(os.path.realpath(repo_root))
    real = Path(os.path.realpath(candidate))
    if real != root and root not in real.parents:
        raise FixtureError(f"fixture resolves outside the checkout: {candidate} -> {real}")
    if real != root:
        resolved = real.relative_to(root).as_posix()
        if _is_excluded(resolved):
            raise FixtureError(f"fixture resolves to an excluded path: {candidate} -> {resolved}")
    return real


def plan(
    repo_root: os.PathLike | str,
    file_fixtures: Sequence[str] = FILE_FIXTURES,
    glob_fixtures: Sequence[str] = GLOB_FIXTURES,
) -> list[tuple[str, Path]]:
    """Return the sorted ``(relative_path, real_source_path)`` fixtures to copy."""
    repo_root = Path(repo_root)
    if not repo_root.is_dir():
        raise FixtureError(f"repository root is not a directory: {repo_root}")

    selected: dict[str, Path] = {}

    def record(relative: str, candidate: Path) -> None:
        normalized = _normalise(relative)
        if _is_excluded(normalized):
            raise FixtureError(f"refusing to package excluded path: {normalized}")
        if not candidate.is_file():
            raise FixtureError(f"required fixture is missing: {normalized}")
        selected[normalized] = _resolve_within(repo_root, candidate)

    for relative in file_fixtures:
        record(relative, repo_root / relative)

    for pattern in glob_fixtures:
        matches = sorted(path for path in repo_root.glob(pattern) if path.is_file())
        if not matches:
            raise FixtureError(f"no files matched required pattern: {pattern}")
        for candidate in matches:
            record(candidate.relative_to(repo_root).as_posix(), candidate)

    return [(relative, selected[relative]) for relative in sorted(selected)]


def _guard_output_location(repo_root: Path, output_root: Path) -> Path:
    """Reject source overlap, but allow the normal ignored build/DerivedData.

    Validate before mkdir so a rejected destination cannot create source-tree
    directories. In-checkout output is restricted to descendants of build/.
    """
    repo_real = Path(os.path.realpath(repo_root))
    out_real = Path(os.path.realpath(output_root))
    if out_real == repo_real:
        raise FixtureError(f"output must not be the repository root: {output_root}")
    if repo_real in out_real.parents:
        relative = out_real.relative_to(repo_real)
        if len(relative.parts) < 2 or relative.parts[0] != "build":
            raise FixtureError(f"in-checkout output must be beneath build/: {output_root}")
    if out_real in repo_real.parents:
        raise FixtureError(f"output must not contain the source checkout: {output_root}")
    output_root.mkdir(parents=True, exist_ok=True)
    return out_real


def _destination_for(output_real: Path, relative: str) -> Path:
    """Destination under ``output_real``, refusing a symlinked escape."""
    destination = output_real / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    parent_real = Path(os.path.realpath(destination.parent))
    if parent_real != output_real and output_real not in parent_real.parents:
        raise FixtureError(f"refusing to write through a symlinked output path: {relative}")
    return destination


def _atomic_copy(source: Path, destination: Path) -> None:
    handle, temporary = tempfile.mkstemp(dir=str(destination.parent), prefix=".fixture-")
    os.close(handle)
    temporary = Path(temporary)
    try:
        shutil.copyfile(source, temporary)
        shutil.copymode(source, temporary)
        os.replace(temporary, destination)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _atomic_write(path: Path, text: str) -> None:
    handle, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=".manifest-")
    temporary = Path(temporary)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _read_manifest(output_real: Path) -> list[str]:
    manifest = output_real / MANIFEST_NAME
    if not manifest.is_file():
        return []
    try:
        recorded = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(recorded, list):
        return []
    return [entry for entry in recorded if isinstance(entry, str)]


def _prune_stale_owned(output_real: Path, previous: Sequence[str], keep: set[str]) -> None:
    """Delete files we previously wrote that the current snapshot no longer has.

    Only paths recorded in the ownership manifest are considered, each is
    re-validated as a clean relative path, and a path whose parent resolves
    outside the output directory is skipped. Unrelated output is never touched.
    """
    for relative in previous:
        if relative in keep:
            continue
        try:
            normalized = _normalise(relative)
        except FixtureError:
            continue
        target = output_real / normalized
        parent_real = Path(os.path.realpath(target.parent))
        if parent_real != output_real and output_real not in parent_real.parents:
            continue
        if target.is_symlink() or target.is_file():
            target.unlink()


def package(
    repo_root: os.PathLike | str,
    output_root: os.PathLike | str,
    file_fixtures: Sequence[str] = FILE_FIXTURES,
    glob_fixtures: Sequence[str] = GLOB_FIXTURES,
) -> list[str]:
    """Copy the allowlisted fixtures into ``output_root``; return the paths written.

    The snapshot is exact on repeat: files written last time but not this time
    are pruned from the ownership manifest, every file is replaced atomically,
    and only files we previously wrote are ever removed — unrelated output,
    media, and the source tree are left alone.
    """
    entries = plan(repo_root, file_fixtures, glob_fixtures)
    output_real = _guard_output_location(Path(repo_root), Path(output_root))

    previous = _read_manifest(output_real)
    written: list[str] = []
    for relative, source in entries:
        _atomic_copy(source, _destination_for(output_real, relative))
        written.append(relative)

    _prune_stale_owned(output_real, previous, set(written))
    _atomic_write(output_real / MANIFEST_NAME, json.dumps(sorted(written), indent=2) + "\n")
    return written


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Package allowlisted test fixtures into the test bundle snapshot."
    )
    parser.add_argument("--repo-root", required=True, help="source checkout root")
    parser.add_argument("--output", help="destination snapshot directory (test bundle)")
    parser.add_argument("--list", action="store_true",
                        help="print the resolved allowlist and exit without copying")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _build_parser().parse_args(list(argv) if argv is not None else None)
    try:
        if args.list:
            for relative, _ in plan(args.repo_root):
                print(relative)
            return 0
        if not args.output:
            raise FixtureError("--output is required unless --list is given")
        written = package(args.repo_root, args.output)
    except FixtureError as error:
        print(f"package-test-fixtures: {error}", file=sys.stderr)
        return 1
    print(f"package-test-fixtures: packaged {len(written)} files into {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
