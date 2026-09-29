#!/usr/bin/env bash
# cargo-target.test.sh — the scripts that read Cargo's output read it from the directory Cargo
# actually used ($CARGO_TARGET_DIR when set), resolved by ONE helper (lib/cargo-target.sh).
# Reads files and calls one shell function; nothing builds, boots or opens a window.
# run-tests: no-host-screen: reads scripts and calls a shell function; nothing is launched on any screen
# run-tests: inputs richos/app/scripts/cargo-target.test.sh richos/app/scripts/lib/cargo-target.sh richos/app/scripts/package-app.sh richos/app/scripts/make-release.sh richos/app/scripts/updater-e2e.sh richos/app/scripts/gui-boot.test.sh
# run-tests: covers richos/app/scripts/lib/cargo-target.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
check() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi
}

if [ ! -f "$here/lib/cargo-target.sh" ]; then
  echo "FAIL lib/cargo-target.sh does not exist"; exit 1
fi
. "$here/lib/cargo-target.sh"

crate="/work/app/src-tauri"
check "unset -> crate target" "$crate/target" "$(unset CARGO_TARGET_DIR; cargo_target_dir "$crate")"
check "empty -> crate target" "$crate/target" "$(CARGO_TARGET_DIR="" cargo_target_dir "$crate")"
check "absolute is used as is" "/Volumes/E1TB/caches/cargo-target" "$(CARGO_TARGET_DIR=/Volumes/E1TB/caches/cargo-target cargo_target_dir "$crate")"
check "relative resolves against the crate dir" "$crate/out" "$(CARGO_TARGET_DIR=out cargo_target_dir "$crate")"

for f in package-app.sh make-release.sh updater-e2e.sh gui-boot.test.sh; do
  if grep -q 'lib/cargo-target.sh' "$here/$f" && grep -q 'cargo_target_dir' "$here/$f"; then
    echo "ok   $f uses the shared resolver"
  else
    echo "FAIL $f does not use the shared resolver"; fail=1
  fi
  if grep -nE '(src_tauri|src-tauri)/target/' "$here/$f" | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null; then
    echo "FAIL $f still names a fixed <crate>/target/ path:"; grep -nE '(src_tauri|src-tauri)/target/' "$here/$f"; fail=1
  else
    echo "ok   $f names no fixed <crate>/target/ path"
  fi
done
exit "$fail"
