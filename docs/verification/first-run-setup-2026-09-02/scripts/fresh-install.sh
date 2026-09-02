#!/usr/bin/env bash
# A FRESH INSTALL, SET UP, AND THEN BOOTED — the deliverable, end to end.
#
#   fresh-install.sh <work-dir>
#
# A HOME that has never seen RichOS, nothing installed, no engine anywhere. It builds the
# engine release asset, pins its digest INTO the binary, drives Anthropic's own installer for
# Claude Code, installs the engine, and then boots the app under that HOME with `cwd = /` and
# an environment holding nothing but HOME and PATH — the GUI condition — and prints the real
# boot line.
#
# WHAT IS REAL HERE AND WHAT IS STOOD IN FOR, said before the output rather than after it:
#
#   REAL  Anthropic's installer, downloaded over https by `/usr/bin/curl` from
#         https://claude.ai/install.sh and run unmodified. The `claude` binary it fetches —
#         the whole ~200 MB of it — arrives over the real network.
#   REAL  the signature check on what it installed, `codesign --verify --strict -R` against
#         Anthropic's designated requirement, offline.
#   REAL  the engine pin, compiled in; the SHA-256 check; `/usr/bin/tar`; the shape and
#         version checks; the atomic swap; the `INSTALLED-FROM` stamp.
#   REAL  the boot: a bundle outside the repository, `cwd = /`, `env -i`.
#   STOOD IN FOR  **the engine asset's HTTPS transport, and only that.** The release does not
#         exist: `WebDevBooster/richos` is private today and §18 sequences the license — and
#         therefore the repository going public, and therefore its Releases — last. A run
#         against the pinned URL is a 404, which IS exercised, for real, against the real
#         host, in `failure-paths.sh`. So the bytes come from the file
#         `make-engine-asset.sh` just produced, and everything downstream of the fetch is the
#         shipping code.
#
# THE CEO'S MACHINE IS NOT TOUCHED. His engine pointer, his loro-root and every file under
# `com.richos.app` are fingerprinted before and after and diffed. Nothing here reads or
# writes any of them.
set -uo pipefail

WORK="${1:?usage: fresh-install.sh <work-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
APP_DIR="$REPO/app"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

rm -rf "$WORK"; mkdir -p "$WORK"
SIM="$WORK/home"; mkdir -p "$SIM"

echo "=== HIS STATE, BEFORE — read only ==="
his_state > "$WORK/his-state-before.txt"
sed -n '1,6p' "$WORK/his-state-before.txt" | sed 's/^/  /'
echo

# ---------------------------------------------------------------------------------------
# 1. The release asset, and the pin
# ---------------------------------------------------------------------------------------
echo "=== 1. building the engine release asset (deterministic; --check runs it twice) ==="
"$APP_DIR/scripts/make-engine-asset.sh" --check --out "$WORK/asset" \
    | grep -E "version|bytes|sha256|IDENTICAL|files|engine/" | sed 's/^/  /'
ASSET="$(ls "$WORK/asset"/richos-engine-*.tar.gz)"
# shellcheck source=/dev/null
. "$WORK/asset/engine-pin.env"
echo
echo "  pin compiled into the build below:"
echo "    RICHOS_ENGINE_VERSION=$RICHOS_ENGINE_VERSION"
echo "    RICHOS_ENGINE_URL=$RICHOS_ENGINE_URL"
echo "    RICHOS_ENGINE_SHA256=$RICHOS_ENGINE_SHA256"

echo
echo "=== 2. building the demo and the app WITH the pin ==="
# `crates/richos-core/build.rs` declares rerun-if-env-changed for these three, so this is a
# real rebuild and not a cache hit carrying a stale digest.
( cd "$APP_DIR" && "$CARGO" build -q -p richos-core --example setup_demo --offline ) || exit 1
( cd "$APP_DIR/src-tauri" && "$CARGO" build -q --bin richos-tauri --offline ) || exit 1
DEMO="$APP_DIR/target/debug/examples/setup_demo"
BIN="$APP_DIR/src-tauri/target/debug/richos-tauri"

APP="$WORK/RichOS.app"
EXE="$(assemble_bundle "$APP" "$BIN")"
echo "  bundle: $APP (Contents/Resources holds $(ls "$APP/Contents/Resources" | wc -l | tr -d ' ') file(s) — no engine)"

echo
echo "=== 3. a HOME that has never seen RichOS ==="
find "$SIM" -mindepth 1 | head
echo "  (empty)"

# ---------------------------------------------------------------------------------------
# 4. The install itself — REAL Claude Code, REAL engine verification
# ---------------------------------------------------------------------------------------
echo
echo "=== 4. detect, then install. Environment: HOME and PATH, and nothing else. ==="
/usr/bin/env -i \
    HOME="$SIM" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    RICHOS_ENGINE_ASSET_FILE="$ASSET" \
    "$DEMO" --install
rc=$?
echo "(exit $rc)"
[ $rc -eq 0 ] || { echo "INSTALL DID NOT COMPLETE — stopping here rather than booting over it"; exit $rc; }

echo
echo "=== what is on disk now, under the throwaway HOME ==="
find "$SIM" -maxdepth 5 -not -path "*/engine/*" -not -path "*/claude/*" -not -path "*/.claude/*" | sort | sed "s|$SIM|<HOME>|" | sed 's/^/  /'
echo "  engine files: $(find "$SIM/Library/Application Support/RichOS/engine" -type f | wc -l | tr -d ' ')"
echo "  --- the freshness stamp, inside the artifact ---"
sed 's/^/    /' "$SIM/Library/Application Support/RichOS/engine/INSTALLED-FROM"
echo "  --- the claude Anthropic's installer put there ---"
ls -l "$SIM/.local/bin/claude" | sed 's/^/    /'

# ---------------------------------------------------------------------------------------
# 5. THE BOOT — the line this whole pass exists to produce
# ---------------------------------------------------------------------------------------
echo
echo "=== 5. BOOT: cwd = /, environment holds nothing but HOME and PATH ==="
LOG="$WORK/boot-after-setup.log"
boot_and_capture "$EXE" "$SIM" "$LOG" "NO COMPUTE LEASE|compute lease attached" 60
echo
echo "--- THE BOOT LINE ---"
grep -E "engine directory:|first-run setup:|compute lease attached|NO COMPUTE LEASE|binary:|engine:|cause :" "$LOG"
echo
echo "--- the whole boot ---"
grep -E "^\[richos\]" "$LOG" | head -40

kill_ours "$EXE"
echo
residue "$EXE"

echo
echo "=== HIS STATE, AFTER ==="
his_state > "$WORK/his-state-after.txt"
if diff -u "$WORK/his-state-before.txt" "$WORK/his-state-after.txt" > "$WORK/his-state.diff"; then
    echo "  BYTE-IDENTICAL. $(grep -c '^[0-9a-f]\{64\}' "$WORK/his-state-after.txt" | tr -d ' ') file(s) fingerprinted under com.richos.app, diff empty."
    sed -n '1,6p' "$WORK/his-state-after.txt" | sed 's/^/  /'
else
    echo "  HIS STATE DIFFERS — read his-state.diff"
    cat "$WORK/his-state.diff"
fi

echo
echo "=== cleaning up this run ==="
du -sh "$SIM" 2>/dev/null | sed 's/^/  throwaway HOME: /'
rm -rf "$SIM"
echo "  throwaway HOME removed"
