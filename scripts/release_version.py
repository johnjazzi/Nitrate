#!/usr/bin/env python3
"""Read-only release gate and explicit local version preparation.

Examples (run anywhere inside the repository):
  python3 scripts/release_version.py check --base origin/main
  python3 scripts/release_version.py prepare --base origin/main
  python3 scripts/release_version.py prepare --base origin/main --labels '["release:minor"]'
  python3 scripts/release_version.py bump-build

Labels may also come from RELEASE_LABELS_JSON (a JSON array of label names).
This tool never commits, pushes, or changes Xcode Cloud's CI build counter.
"""

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess
import sys


class ReleaseError(ValueError):
    """Invalid release metadata or policy input."""


@dataclass(frozen=True)
class Metadata:
    text: str
    version: str
    build: int
    spans: dict


def read_metadata(text):
    """Accept only the project's simple scalar version fields, never reformat YAML.

    Fail closed on noncanonical/ambiguous fields instead of pretending to be a
    general YAML parser. Both fields must occur exactly once in settings.base.
    """
    settings = list(re.finditer(r'''(?m)^["']?settings["']? *:''', text))
    if len(settings) != 1:
        raise ReleaseError("Expected exactly one root settings mapping")
    settings_tail = text[settings[0].start():].splitlines()[1:]
    base_count = 0
    for line in settings_tail:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            break
        if re.match(r'''^  ["']?base["']? *:''', line):
            base_count += 1
    if base_count != 1:
        raise ReleaseError("Expected exactly one settings.base mapping")
    fields = {}
    for key, pattern in (("MARKETING_VERSION", r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"),
                         ("CURRENT_PROJECT_VERSION", r"[1-9][0-9]*")):
        # Version overrides in flow mappings would evade a line-only scan.
        if any(re.search(rf'''[{{,][ \t]*["']?{key}["']? *:''', line.split("#", 1)[0])
               for line in text.splitlines()):
            raise ReleaseError(f"Unsupported inline {key} field; keep one scalar in settings.base")
        candidates = list(re.finditer(
            rf"(?m)^[ \t]*[\"']?{key}[\"']?\s*:", text))
        if len(candidates) != 1:
            raise ReleaseError(f"Expected exactly one {key} field")
        line_start = candidates[0].start()
        line_end = text.find("\n", line_start)
        line = text[line_start:line_end if line_end != -1 else len(text)].rstrip("\r")
        match = re.fullmatch(rf"    {key}: +(?P<quote>[\"']?)(?P<value>{pattern})(?P=quote)(?:[ \t]+#.*)?[ \t]*", line)
        if not match:
            raise ReleaseError(f"Malformed {key}: require a canonical scalar in settings.base")
        # Check the two ancestor mappings, ignoring blank/comment lines.
        ancestors = []
        for preceding in text[:line_start].splitlines():
            if not preceding.strip() or preceding.lstrip().startswith("#"):
                continue
            indent = len(preceding) - len(preceding.lstrip(" "))
            while ancestors and ancestors[-1][0] >= indent:
                ancestors.pop()
            ancestors.append((indent, preceding.strip()))
        ancestors = [entry for entry in ancestors if entry[0] < 4]
        if ancestors != [(0, "settings:"), (2, "base:")]:
            raise ReleaseError(f"{key} must be under settings.base")
        start, end = match.span("value")
        fields[key] = (match["value"], (line_start + start, line_start + end))
    return Metadata(text, fields["MARKETING_VERSION"][0],
                    int(fields["CURRENT_PROJECT_VERSION"][0]),
                    {key: entry[1] for key, entry in fields.items()})


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args],
                            text=True, capture_output=True)
    if result.returncode:
        raise ReleaseError(result.stderr.strip() or "git command failed")
    return result.stdout.strip()


def expected_version(base_version, raw_labels):
    try:
        labels = json.loads(raw_labels)
    except (ValueError, TypeError) as error:
        raise ReleaseError("Labels must be a JSON array of label names") from error
    if not isinstance(labels, list) or any(not isinstance(label, str) for label in labels):
        raise ReleaseError("Labels must be a JSON array of label names")
    release_labels = [label for label in labels if label.startswith("release:")]
    if any(label not in ("release:minor", "release:major") for label in release_labels):
        raise ReleaseError("Invalid release label; use release:minor or release:major, or no label for patch")
    if len(release_labels) > 1:
        raise ReleaseError("Conflicting or duplicate release labels")
    major, minor, patch = map(int, base_version.split("."))
    if release_labels == ["release:major"]:
        return f"{major + 1}.0.0"
    if release_labels == ["release:minor"]:
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def replace_metadata(current, version, build):
    replacements = {"MARKETING_VERSION": version, "CURRENT_PROJECT_VERSION": str(build)}
    text = current.text
    for key, (start, end) in sorted(current.spans.items(), key=lambda item: item[1][0], reverse=True):
        text = text[:start] + replacements[key] + text[end:]
    read_metadata(text)  # Validate the entire result before writing any bytes.
    return text


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name, help_text in (("check", "Read-only PR release-version validation"),
                            ("prepare", "Explicitly prepare project.yml for a release PR")):
        command = commands.add_parser(name, help=help_text)
        command.add_argument("--base", required=True, help="Trusted base commit or Git ref")
        command.add_argument("--labels", default=None, help="JSON array of PR label names")
    commands.add_parser("bump-build", help="Increment only the build for a local/manual distribution rebuild")
    args = parser.parse_args(argv)
    try:
        root = Path(git(Path.cwd(), "rev-parse", "--show-toplevel"))
        project = root / "project.yml"
        current = read_metadata(project.read_bytes().decode("utf-8"))
        if args.command == "bump-build":
            build = current.build + 1
            updated = replace_metadata(current, current.version, build)
            project.write_bytes(updated.encode("utf-8"))
            print(f"Prepared manual distribution build: {current.version} ({build}); regenerate with XcodeGen before archiving")
            return 0
        oid = git(root, "rev-parse", "--verify", "--end-of-options", args.base + "^{commit}")
        base = read_metadata(git(root, "show", oid + ":project.yml"))
        raw_labels = args.labels if args.labels is not None else os.environ.get("RELEASE_LABELS_JSON", "[]")
        expected = expected_version(base.version, raw_labels)
        if args.command == "prepare":
            build = max(current.build, base.build + 1)
            updated = replace_metadata(current, expected, build)
            if updated != current.text:
                project.write_bytes(updated.encode("utf-8"))
            print(f"Prepared release: {expected} ({build}); review and commit project.yml yourself")
            return 0
        if current.version != expected:
            raise ReleaseError(f"Expected MARKETING_VERSION {expected} from base {base.version}; found {current.version}. Run prepare with the same base and labels.")
        if current.build <= base.build:
            raise ReleaseError(f"CURRENT_PROJECT_VERSION must exceed base build {base.build}; run prepare")
        print(f"Release version valid: {current.version} ({current.build})")
        return 0
    except (ReleaseError, OSError, UnicodeError) as error:
        print(f"release-version: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
