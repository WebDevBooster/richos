#!/usr/bin/env bash
#
# Reproducible build of our open-wispr dictation HUD patch.
#
# Clones open-wispr at the audited commit (7ab4e62 = v0.43.0), applies
# tools/open-wispr-hud/dictation-hud.patch, runs the test suite, builds a
# release binary, and bundles OpenWispr.app — WITHOUT installing over the
# CEO's live install or touching the running service. The final swap +
# service restart is a deliberate manual step (see README.md "Apply"),
# because it triggers the live permission / paste-at-cursor gates.
#
# Usage:
#   tools/open-wispr-hud/build.sh [workdir]
#
# Output: <workdir>/open-wispr/OpenWispr.app  and  .build/release/open-wispr
#
set -euo pipefail

AUDITED_COMMIT="7ab4e62e8f182f3ecc2116e1094a1eb4416a248f"
REPO="https://github.com/human37/open-wispr.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="${SCRIPT_DIR}/dictation-hud.patch"
WORKDIR="${1:-$(mktemp -d)}"
SRC="${WORKDIR}/open-wispr"

echo "==> Work dir:  ${WORKDIR}"
echo "==> Patch:     ${PATCH}"
echo "==> Base:      ${AUDITED_COMMIT} (open-wispr v0.43.0, audited)"

# Prefer the local Homebrew source cache if present (identical, offline);
# fall back to the public GitHub remote.
CACHE="${HOME}/Library/Caches/Homebrew/open-wispr--git"
if [ -d "${CACHE}/.git" ]; then
  echo "==> Cloning from local Homebrew cache"
  git clone -q "${CACHE}" "${SRC}"
else
  echo "==> Cloning from ${REPO}"
  git clone -q "${REPO}" "${SRC}"
fi

cd "${SRC}"
git checkout -q "${AUDITED_COMMIT}"
echo "==> Checked out $(git rev-parse HEAD)"

echo "==> Applying HUD patch"
git apply --check "${PATCH}"
git apply "${PATCH}"

echo "==> Running tests (must be green before shipping)"
swift test

echo "==> Building release"
swift build -c release --disable-sandbox

echo "==> Bundling OpenWispr.app"
BUILD_VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo 0.43.0)-hud"
bash scripts/bundle-app.sh .build/release/open-wispr OpenWispr.app "${BUILD_VERSION}"

echo
echo "==> Done."
echo "    App bundle : ${SRC}/OpenWispr.app"
echo "    Binary     : ${SRC}/.build/release/open-wispr"
echo
echo "    NOT installed. To apply over the current install, see README.md 'Apply'."
