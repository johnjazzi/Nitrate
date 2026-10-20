#!/bin/sh
# Xcode Cloud runs this AFTER xcodebuild, for each action.
#
# Coverage rationale: the RenderCLI TEST action only compiles for macOS, so on
# its own it no longer proves the iOS app still compiles. This hook restores that
# coverage by linting and compiling the iOS app without signing.
#
# Apple documents a test action as two phases: the first builds test products
# with `xcodebuild build-for-testing` (source code available), the second runs
# them with `xcodebuild test-without-building` (source code NOT available).
# CI_XCODEBUILD_ACTION names the phase, so the work runs only during
# build-for-testing; every other action (build/analyze/archive, and the
# test-without-building phase) exits immediately.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY=${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$SCRIPT_DIR")}
cd "$REPOSITORY"

ACTION=${CI_XCODEBUILD_ACTION:-}
if [ "$ACTION" != "build-for-testing" ]; then
    printf 'Cloud post-xcodebuild: CI_XCODEBUILD_ACTION=%s; skipping lint and iOS build\n' "${ACTION:-unset}"
    exit 0
fi

# The source checkout must be present in this phase. If it is not, fail loudly
# instead of silently dropping the iOS coverage the required check used to have.
if [ ! -f project.yml ]; then
    printf 'Cloud post-xcodebuild: source checkout missing at %s; cannot lint or build iOS\n' "$REPOSITORY" >&2
    exit 1
fi

# ci_post_clone.sh installed these tools into the ignored build directory and
# generated Nitrate.xcodeproj. A post-clone script's exported PATH does not carry
# into later independent processes, so re-add it here.
TOOLS="$REPOSITORY/build/ci-tools"
export PATH="$TOOLS/xcodegen-2.46.0/xcodegen/bin:$TOOLS/swiftlint-0.65.1:$PATH"

# Stream output live and watchdog each command, as the retired native job did, so
# a hang is stopped with evidence instead of running out the whole action budget.
export NITRATE_VERIFY_DIAGNOSTICS=1

# The same check the native job ran for its lint and unsigned generic iOS build.
python3 scripts/verify.py check
