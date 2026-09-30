#!/usr/bin/env bash
# run-tests: no-host-screen: changes only links in private test fixtures
# run-tests: inputs richos/app/scripts/shared-build-cache.test.sh richos/app/scripts/shared-build-cache.sh richos/app/scripts/bin/cargo richos/app/scripts/lib/cargo_identity.py
# run-tests: covers richos/app/scripts/shared-build-cache.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:?}/cargo-cache-links.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
for checkout in alpha beta; do
  for workspace in app app/src-tauri; do
    mkdir -p "$WORK/$checkout/richos/$workspace"
    printf '[package]\nname="fixture"\nversion="0.1.0"\n[workspace]\n' > "$WORK/$checkout/richos/$workspace/Cargo.toml"
  done
done
mkdir -p "$WORK/cache/old-shared"
touch "$WORK/cache/old-shared/preserve-me"
ln -s "$WORK/cache/old-shared" "$WORK/alpha/richos/app/target"
if RICHOS_BUILD_CACHE="$WORK/cache" bash "$HERE/shared-build-cache.sh" --check "$WORK/alpha"; then
  echo 'FAIL old shared target was accepted'; exit 1
fi
for checkout in alpha beta; do
  RICHOS_BUILD_CACHE="$WORK/cache" bash "$HERE/shared-build-cache.sh" "$WORK/$checkout"
  RICHOS_BUILD_CACHE="$WORK/cache" bash "$HERE/shared-build-cache.sh" --check "$WORK/$checkout"
done
[ -f "$WORK/cache/old-shared/preserve-me" ]
count="$(find "$WORK/alpha" "$WORK/beta" -type l -name target -exec readlink '{}' \; | sort -u | wc -l | tr -d ' ')"
[ "$count" = 4 ]
echo 'PASS two checkouts and detached workspaces have four private outputs'
echo 'PASS legacy shared link migrated without deleting its cache'
