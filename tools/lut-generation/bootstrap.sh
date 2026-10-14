#!/usr/bin/env bash
# Create the pinned environment this generator was run with.
#
# Clones Spectral Film LUT at the exact commit the shipped cubes were built
# from, installs it editable WITHOUT its declared dependencies (they pull the
# PyQt GUI stack, which the generator never imports), then installs the
# generator's own minimal runtime dependencies.
#
# Usage:  ./bootstrap.sh && . .venv/bin/activate
set -euo pipefail

PIN=6307a98f3cf4f2d7b6d09bab82fbf6f64356ccfe
REPO=https://github.com/JanLohse/spectral_film_lut.git

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="${HERE}/.vendor"
CLONE="${VENDOR}/spectral_film_lut"

mkdir -p "${VENDOR}"

if [ ! -d "${CLONE}/.git" ]; then
  git clone "${REPO}" "${CLONE}"
fi
git -C "${CLONE}" fetch --depth 1 origin "${PIN}"
git -C "${CLONE}" checkout --detach "${PIN}"
echo "Spectral Film LUT at $(git -C "${CLONE}" rev-parse HEAD)"

if [ ! -d "${HERE}/.venv" ]; then
  python3 -m venv "${HERE}/.venv"
fi
# shellcheck disable=SC1091
. "${HERE}/.venv/bin/activate"

python -m pip install --upgrade pip >/dev/null
python -m pip install -r "${HERE}/requirements.txt"
python -m pip install --no-deps -e "${CLONE}"

echo
echo "Ready. Now:  . ${HERE}/.venv/bin/activate && cd ${HERE} && python generate.py 33 out"
