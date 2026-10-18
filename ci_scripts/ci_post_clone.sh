#!/bin/sh
# Xcode Cloud runs this BEFORE resolving packages or invoking xcodebuild.
# project.yml remains authoritative; Nitrate.xcodeproj is intentionally untracked.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY=${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$SCRIPT_DIR")}
cd "$REPOSITORY"

if [ ! -f project.yml ]; then
    printf 'Cloud bootstrap: project.yml missing in %s\n' "$REPOSITORY" >&2
    exit 1
fi

TOOLS="$REPOSITORY/build/ci-tools"
XCODEGEN_DIR="$TOOLS/xcodegen-2.46.0"
SWIFTLINT_DIR="$TOOLS/swiftlint-0.65.1"
mkdir -p "$TOOLS/downloads"

install_archive() {
    name=$1
    url=$2
    checksum=$3
    destination=$4
    archive="$TOOLS/downloads/$name.zip"
    if [ ! -f "$archive" ]; then
        curl --fail --location --retry 3 --output "$archive" "$url"
    fi
    # Digests are pinned to the upstream GitHub release assets, not downloaded
    # from the same connection at build time. Never execute an unverified tool.
    if ! printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check; then
        printf 'Cloud bootstrap: %s archive checksum verification failed\n' "$name" >&2
        exit 1
    fi
    mkdir -p "$destination"
    ditto -x -k "$archive" "$destination"
}

if [ ! -x "$XCODEGEN_DIR/xcodegen/bin/xcodegen" ]; then
    install_archive xcodegen-2.46.0 \
        https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip \
        4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806 \
        "$XCODEGEN_DIR"
fi
if [ ! -x "$SWIFTLINT_DIR/swiftlint" ]; then
    install_archive swiftlint-0.65.1 \
        https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip \
        c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0 \
        "$SWIFTLINT_DIR"
fi

export PATH="$XCODEGEN_DIR/xcodegen/bin:$SWIFTLINT_DIR:$PATH"
if [ "$(xcodegen --version)" != 'Version: 2.46.0' ]; then
    printf 'Cloud bootstrap: unexpected XcodeGen version\n' >&2
    exit 1
fi
if [ "$(swiftlint version)" != '0.65.1' ]; then
    printf 'Cloud bootstrap: unexpected SwiftLint version\n' >&2
    exit 1
fi
command -v python3 >/dev/null

xcodegen generate --spec project.yml
if [ ! -f Nitrate.xcodeproj/project.pbxproj ] ||
   [ ! -f Nitrate.xcodeproj/xcshareddata/xcschemes/Nitrate.xcscheme ]; then
    printf 'Cloud bootstrap: Nitrate.xcodeproj or shared Nitrate scheme was not generated\n' >&2
    exit 1
fi
printf 'Cloud bootstrap ready: Nitrate.xcodeproj, XcodeGen 2.46.0, SwiftLint 0.65.1\n'
