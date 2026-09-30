#!/usr/bin/env bash
# cargo-target.test.sh — the scripts that read Cargo's output read it from the directory Cargo
# actually used ($CARGO_TARGET_DIR when set), resolved by ONE helper (lib/cargo-target.sh).
# Reads files and calls one shell function; nothing builds, boots or opens a window.
# run-tests: no-host-screen: reads scripts and calls a shell function; nothing is launched on any screen
# run-tests: inputs richos/app/scripts/cargo-target.test.sh richos/app/scripts/lib/cargo-target.sh richos/app/scripts/package-app.sh richos/app/scripts/make-release.sh richos/app/scripts/updater-e2e.sh richos/app/scripts/gui-boot.test.sh richos/app/scripts/bin/cargo richos/app/scripts/lib/cargo_identity.py richos/app/scripts/lib/cargo-cache-env.sh
# run-tests: covers richos/app/scripts/lib/cargo-target.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
if [ ! -f "$here/lib/cargo-target.sh" ]; then
  echo "FAIL lib/cargo-target.sh does not exist"; exit 1
fi
. "$here/lib/cargo-target.sh"

work="$(cd "$(mktemp -d "${TMPDIR:?}/cargo-target.XXXXXX")" && pwd -P)"
trap 'rm -rf "$work"' EXIT
crate="$work/app/src-tauri"
mkdir -p "$crate"
printf '[package]\nname="target_fixture"\nversion="0.1.0"\n' > "$crate/Cargo.toml"
for base in "$work/absolute" out; do
  target="$(unset RICHOS_CARGO_CACHE_ROOT; CARGO_TARGET_DIR="$base" cargo_target_dir "$crate")"
  expected="$base"
  case "$base" in /*) ;; *) expected="$crate/$base" ;; esac
  case "$target" in "$expected"/workspaces/*) echo "ok private namespace under $expected" ;; *) echo "FAIL unexpected target $target"; fail=1 ;; esac
done
mkdir -p "$work/other"
cp "$crate/Cargo.toml" "$work/other/Cargo.toml"
a="$(unset RICHOS_CARGO_CACHE_ROOT; CARGO_TARGET_DIR="$work/cache" cargo_target_dir "$crate")"
b="$(unset RICHOS_CARGO_CACHE_ROOT; CARGO_TARGET_DIR="$work/cache" cargo_target_dir "$work/other")"
if [ "$a" != "$b" ]; then echo "ok different workspace outputs"; else echo "FAIL workspace output collision"; fail=1; fi

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
