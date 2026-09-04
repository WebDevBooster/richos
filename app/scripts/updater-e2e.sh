#!/usr/bin/env bash
# APPLY A REAL UPDATE, END TO END, ON THIS MACHINE — and prove the signature check refuses.
#
#   app/scripts/updater-e2e.sh                 # the whole thing
#   app/scripts/updater-e2e.sh --keep          # ...and leave the workspace for inspection
#
# WHY THIS FILE IS THE DELIVERABLE AND THE CONFIGURATION IS NOT
# -------------------------------------------------------------
# RICH-TODOs row 12 said RichOS had "no updater of any kind" and that the CEO's *"automatically
# download and install whatever the user needs"* rested on zero infrastructure. Wiring
# `tauri-plugin-updater` into `Cargo.toml` and `tauri.conf.json` does not answer that: an
# updater that has never applied an update is the same zero infrastructure with more files in
# it. So this script builds 0.1.0, builds 0.1.1, serves a manifest, and makes the first
# BECOME the second — then tampers with one byte and shows the refusal.
#
# WHAT IT PROVES, in order, each as its own named case:
#
#   A  0.1.0 finds 0.1.1 through a real HTTP manifest fetch
#   B  it downloads the archive, VERIFIES the minisign signature, and installs it
#   C  the bundle on disk is now 0.1.1 — read from the INSTALLED Info.plist
#   D  the replaced bundle RUNS, and reports itself as 0.1.1 against the same manifest
#   T  a TAMPERED archive is REFUSED, with `failure.kind == "signature"`, and the installed
#      bundle is untouched afterwards
#   K  an archive signed with a DIFFERENT key is refused the same way
#
# T AND K ARE THE POINT AS MUCH AS A-D ARE. An updater that installs an unverified binary is
# worse than no updater: it is a remote-code-execution channel with a progress bar. Case T
# does not assert that the code contains a verification call; it flips a byte in the served
# artifact, leaves the good signature in place, and requires the install to FAIL.
#
# HOW THE APP IS DRIVEN, and why it is not a scripted click
# ---------------------------------------------------------
# Only a process that IS the bundle can replace the bundle — the updater resolves what to
# replace from `current_exe` (`tauri-plugin-updater-2.11.0/src/updater.rs:1424`). Driving the
# real GUI would need an Accessibility grant, which an ad-hoc bundle loses on every build that
# changes a byte — the exact failure this repository has already measured. So the app is
# launched with `RICHOS_UPDATE_SELFTEST=install`, which runs the SAME `updates::check` and
# `updates::install` functions the two Tauri commands run (`src-tauri/src/updates.rs`), after
# the SAME full boot, and prints one machine-readable line per transition. It is not a
# reimplementation with the verification left out; it is the same two calls.
#
# WHAT IS DIFFERENT FROM A SHIPPING BUILD, stated rather than buried
# ------------------------------------------------------------------
# Exactly two config keys, both passed as a `--config` overlay and both echoed by
# `package-app.sh` when it builds:
#
#   1. `version`, because the whole test is that two versions exist.
#   2. `plugins.updater.dangerousInsecureTransportProtocol: true`, because the manifest is
#      served from 127.0.0.1 over http and a RELEASE build otherwise refuses a non-https
#      endpoint outright (`tauri-plugin-updater-2.11.0/src/config.rs:validate_endpoints`).
#      That refusal is correct and is not disabled in the shipping config.
#
# The signing key, the public key, the archive format, the manifest shape, the signature
# check and the install are all the shipping ones. The transport is http instead of https,
# and that is the whole of the delta.
#
# The bundles are AD-HOC signed, because this Mac has no Developer ID certificate
# (`security find-identity -v -p codesigning` reports 0). That is orthogonal: Tauri's
# minisign verification has nothing to do with Apple codesigning, which is why the update
# path is provable today and Apple's half is not.
#
# Exit codes: 0 every case passed. 1 a case failed. 2 refused before starting.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$here/.." && pwd)"
src_tauri="$app_dir/src-tauri"

keep=""
[ "${1:-}" = "--keep" ] && keep=1

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
rule() { printf '\n%s\n' "-------------------------------------------------------------------------------"; }

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  warn "updater-e2e.sh: this applies a macOS .app update and runs on macOS only."
  warn "                (uname -s reports $(uname -s).) Refusing to report a result."
  exit 2
fi

if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
  PATH="$HOME/.cargo/bin:$PATH"; export PATH
fi
for tool in cargo python3 shasum; do
  command -v "$tool" >/dev/null 2>&1 || { warn "updater-e2e.sh: $tool is not on PATH."; exit 2; }
done
cargo tauri --version >/dev/null 2>&1 || { warn "updater-e2e.sh: the Tauri CLI is not installed (cargo install tauri-cli --version '^2')."; exit 2; }

# THE RELEASE KEY, and that is deliberate rather than careless. This harness signs an
# archive and then requires the app to INSTALL it, so the key it signs with has to be the
# one whose public half `tauri.conf.json` compiles in — a harness on its own key would
# prove an update path nobody ships. Cases T and K generate their own throwaway keys for
# exactly the artifacts that must be REFUSED.
KEY="${TAURI_SIGNING_PRIVATE_KEY_PATH:-$HOME/.richos-signing/richos-updater.key}"
if [ ! -f "$KEY" ]; then
  warn ""
  warn "updater-e2e.sh: no updater signing key at $KEY"
  warn ""
  warn "  Generate one OUTSIDE every repository:"
  warn "    cargo tauri signer generate -w \$HOME/.richos-signing/richos-updater.key -p '' --ci"
  warn "  ...and put its .pub contents in tauri.conf.json's plugins.updater.pubkey."
  warn "  app/RELEASING.md says which key ships and why."
  warn ""
  exit 2
fi
export TAURI_SIGNING_PRIVATE_KEY_PATH="$KEY"
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"

# ---------------------------------------------------------------------------
# Workspace — OUTSIDE every git worktree, deliberately. A 400 MiB bundle and a
# private key's signature do not belong anywhere `git add -A` can reach.
# ---------------------------------------------------------------------------
# `pwd -P` IS LOAD-BEARING AND WAS FOUND BY RUNNING THIS, not by reading. On macOS
# $TMPDIR is under /var/folders/..., and /var is a symlink to /private/var. Tauri's
# `StartingBinary` guard refuses to launch at all when `current_exe()` traverses a
# symlink — the app died before it could check for an update, with
#
#   "StartingBinary found current_exe() that contains a symlink on a non-allowed
#    platform: /var"
#
# which surfaced as an `install` failure and made cases T and K pass for the WRONG
# REASON: the tampered archive was "refused" by an app that had not looked at it.
# Resolving the path removes the symlink and the guard is satisfied. It is also a
# real fact about where an installed RichOS may live.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/richos-updater-e2e.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
SERVE="$WORK/serve"
INSTALLED="$WORK/installed"
LOGS="$WORK/logs"
mkdir -p "$SERVE" "$INSTALLED" "$LOGS"

SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  if [ -n "$keep" ]; then
    say ""
    say "workspace kept: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

PORT="${RICHOS_UPDATE_E2E_PORT:-8973}"
BASE="http://127.0.0.1:$PORT"
TARGET_ARCH="$(uname -m)"
case "$TARGET_ARCH" in arm64|aarch64) UPD_ARCH="aarch64" ;; x86_64) UPD_ARCH="x86_64" ;; *) UPD_ARCH="$TARGET_ARCH" ;; esac

say "RichOS updater — end to end, on this machine"
say "  workspace   : $WORK"
say "  key         : $KEY"
say "  platform    : darwin-$UPD_ARCH"
say "  manifest at : $BASE/latest.json"

INSECURE='"dangerousInsecureTransportProtocol": true'

build() { # build <version> -> leaves the bundle + artifacts in the target dir
  local version="$1" want_updater="$2"
  local overlay="{\"version\": \"$version\", \"plugins\": {\"updater\": {$INSECURE}}}"
  # `set -u` and an empty array are the classic bash trap: `"${args[@]}"` on an
  # array with no elements is an UNBOUND VARIABLE error on bash 3.2, which is the
  # bash macOS ships. The `+` expansion below is the form that survives it, and it
  # cost this script its first run.
  local args=()
  [ "$want_updater" = "1" ] && args+=(--updater)
  rule
  if [ "$want_updater" = "1" ]; then
    say "building RichOS $version (with signed update artifacts)..."
  else
    say "building RichOS $version (the bundle only — this is the one that gets updated)..."
  fi
  RICHOS_EXTRA_TAURI_CONFIG="$overlay" \
  RICHOS_UPDATE_BASE_URL="$BASE" \
  RICHOS_UPDATE_NOTES="${RICHOS_UPDATE_NOTES:-Faster launch, and the settings menu now says what version you are running.}" \
    bash "$here/package-app.sh" ${args[@]+"${args[@]}"} 2>&1 | tee "$LOGS/build-$version.log" | sed 's/^/    /'
  local code="${PIPESTATUS[0]}"
  if [ "$code" -ne 0 ]; then
    warn ""
    warn "the $version build failed (exit $code). Full log: $LOGS/build-$version.log"
    exit 1
  fi
}

BUNDLE_DIR="$src_tauri/target/release/bundle/macos"

# ---------------------------------------------------------------------------
# 1. Build the NEW version first, and take its artifacts away before building the
#    old one — both builds write to the same target directory.
# ---------------------------------------------------------------------------
build 0.1.1 1
cp "$BUNDLE_DIR/RichOS.app.tar.gz" "$SERVE/"
cp "$BUNDLE_DIR/RichOS.app.tar.gz.sig" "$SERVE/"
cp "$BUNDLE_DIR/latest.json" "$SERVE/"
NEW_BYTES="$(stat -f '%z' "$SERVE/RichOS.app.tar.gz")"
NEW_SHA="$(shasum -a 256 "$SERVE/RichOS.app.tar.gz" | awk '{print $1}')"
cp "$SERVE/RichOS.app.tar.gz" "$WORK/good.tar.gz"
cp "$SERVE/RichOS.app.tar.gz.sig" "$WORK/good.tar.gz.sig"

# ---------------------------------------------------------------------------
# 2. Build the OLD version and "install" it: a copy of the bundle, outside the
#    build tree, exactly as a customer would have it.
# ---------------------------------------------------------------------------
build 0.1.0 0
rm -rf "$INSTALLED/RichOS.app"
/usr/bin/ditto "$BUNDLE_DIR/RichOS.app" "$INSTALLED/RichOS.app"
EXE="$INSTALLED/RichOS.app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INSTALLED/RichOS.app/Contents/Info.plist")"
cp -R "$INSTALLED/RichOS.app" "$WORK/pristine-0.1.0.app"

installed_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$INSTALLED/RichOS.app/Contents/Info.plist" 2>/dev/null
}

reinstall_old() {
  rm -rf "$INSTALLED/RichOS.app"
  cp -R "$WORK/pristine-0.1.0.app" "$INSTALLED/RichOS.app"
}

# ---------------------------------------------------------------------------
# 3. Serve the manifest and the archive.
# ---------------------------------------------------------------------------
rule
say "serving $SERVE on $BASE ..."
(cd "$SERVE" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >"$LOGS/http.log" 2>&1) &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "$BASE/latest.json" >/dev/null 2>&1 && break
  sleep 0.1
done
if ! curl -fsS "$BASE/latest.json" >/dev/null 2>&1; then
  warn "the local server never answered on $BASE — is port $PORT in use?"
  warn "(set RICHOS_UPDATE_E2E_PORT to pick another.)"
  exit 1
fi
say "  manifest served:"
python3 -m json.tool "$SERVE/latest.json" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# The driver. Runs the INSTALLED bundle headless and returns its selftest lines.
# ---------------------------------------------------------------------------
run_selftest() { # run_selftest <check|install> <logname> -> exit code, output in $SELFTEST_OUT
  local mode="$1" name="$2"
  local log="$LOGS/$name.log"
  RICHOS_UPDATE_SELFTEST="$mode" \
  RICHOS_UPDATE_ENDPOINT="$BASE/latest.json" \
  RICHOS_ENTITY="${RICHOS_ENTITY:-richos}" \
    "$EXE" >"$log" 2>&1
  local code=$?
  SELFTEST_OUT="$(grep '^RICHOS-UPDATE-SELFTEST' "$log" || true)"
  SELFTEST_LOG="$log"
  return $code
}

state_of() { printf '%s\n' "$SELFTEST_OUT" | sed -n "s/.*state=\([a-zA-Z]*\).*/\1/p" | sed -n "${1}p"; }
failure_of() { printf '%s\n' "$SELFTEST_OUT" | sed -n 's/.*failure=\([a-zA-Z-]*\).*/\1/p' | tail -1; }

rule
say "CASE A-D — 0.1.0 discovers 0.1.1, verifies it, installs it, and comes back as 0.1.1"
say ""

before="$(installed_version)"
if [ "$before" = "0.1.0" ]; then
  ok "the installed bundle is 0.1.0 before anything runs"
else
  bad "the installed bundle is 0.1.0 before anything runs" "Info.plist says '$before'"
fi

run_selftest install apply
apply_code=$?
printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /'

if printf '%s\n' "$SELFTEST_OUT" | grep -q 'state=available.*available=0.1.1'; then
  ok "A  0.1.0 fetched the manifest over HTTP and found 0.1.1"
else
  bad "A  0.1.0 fetched the manifest over HTTP and found 0.1.1" "selftest said: $SELFTEST_OUT (log: $SELFTEST_LOG)"
fi

if [ "$apply_code" -eq 0 ] && printf '%s\n' "$SELFTEST_OUT" | grep -q 'state=ready'; then
  ok "B  it downloaded the archive, the signature VERIFIED, and it installed"
else
  bad "B  it downloaded the archive, the signature VERIFIED, and it installed" \
      "exit $apply_code; selftest said: $SELFTEST_OUT (log: $SELFTEST_LOG)"
fi

after="$(installed_version)"
if [ "$after" = "0.1.1" ]; then
  ok "C  the bundle ON DISK is now 0.1.1 (read from the installed Info.plist)"
else
  bad "C  the bundle ON DISK is now 0.1.1 (read from the installed Info.plist)" "Info.plist says '$after'"
fi

# D is the relaunch. The replaced bundle is STARTED AGAIN — a new process, from the bytes the
# updater put there — and asked the same question. "upToDate" from a build that a moment ago
# said "available" is the whole claim: it is running as 0.1.1, and it can say so.
run_selftest check relaunch
relaunch_code=$?
printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /'
if [ "$relaunch_code" -eq 10 ] && printf '%s\n' "$SELFTEST_OUT" | grep -q 'state=upToDate.*current=0.1.1'; then
  ok "D  the replaced bundle RELAUNCHED, runs, and reports itself as 0.1.1 and up to date"
else
  bad "D  the replaced bundle RELAUNCHED, runs, and reports itself as 0.1.1 and up to date" \
      "exit $relaunch_code; selftest said: $SELFTEST_OUT (log: $SELFTEST_LOG)"
fi

# ---------------------------------------------------------------------------
# CASE T — the signature check is load-bearing
# ---------------------------------------------------------------------------
rule
say "CASE T — one byte flipped in the served archive, the good signature left in place"
say ""

reinstall_old
python3 - "$WORK/good.tar.gz" "$SERVE/RichOS.app.tar.gz" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, "rb").read())
# Late in the file, well past the gzip header, so it is a corrupted PAYLOAD rather than an
# archive that fails to open — the point is that the SIGNATURE catches it, and it must be
# caught before anything tries to unpack it.
i = len(data) - 1024
data[i] ^= 0xFF
open(dst, "wb").write(bytes(data))
print("    flipped byte %d of %d (0x%02X -> 0x%02X)" % (i, len(data), data[i] ^ 0xFF, data[i]))
PY
TAMPER_SHA="$(shasum -a 256 "$SERVE/RichOS.app.tar.gz" | awk '{print $1}')"
say "    good sha256     : $NEW_SHA"
say "    tampered sha256 : $TAMPER_SHA"

run_selftest install tamper
tamper_code=$?
printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /'

# "IT FAILED" IS NOT ENOUGH, and the first run of this script proved why: a bug that
# stopped the app booting at all made this case pass while nothing had looked at the
# archive. So the run must have REACHED the update — found 0.1.1, and then failed.
if printf '%s\n' "$SELFTEST_OUT" | grep -q 'state=available.*available=0.1.1'; then
  if [ "$tamper_code" -ne 0 ]; then
    ok "T1 it found 0.1.1, tried it, and the install FAILED (exit $tamper_code, not 0)"
  else
    bad "T1 it found 0.1.1, tried it, and the install FAILED" "it exited 0 — an unverified binary was installed"
  fi
else
  bad "T1 it found 0.1.1, tried it, and the install FAILED" \
      "the run never reached the update at all, so this case proves nothing: $SELFTEST_OUT"
fi

if [ "$(failure_of)" = "signature" ]; then
  ok "T2 ...and it failed AS A SIGNATURE FAILURE, not as a network or unpack error"
else
  bad "T2 ...and it failed AS A SIGNATURE FAILURE, not as a network or unpack error" \
      "failure kind was '$(failure_of)'; selftest said: $SELFTEST_OUT"
fi

still="$(installed_version)"
if [ "$still" = "0.1.0" ]; then
  ok "T3 the installed bundle is UNTOUCHED — still 0.1.0"
else
  bad "T3 the installed bundle is UNTOUCHED — still 0.1.0" "Info.plist says '$still'"
fi

# ---------------------------------------------------------------------------
# CASE K — a correctly-formed signature from the wrong key
# ---------------------------------------------------------------------------
rule
say "CASE K — the archive is intact, and signed by a key this build does not trust"
say ""

WRONG_KEY="$WORK/wrong.key"
cargo tauri signer generate -w "$WRONG_KEY" -p "" --ci >/dev/null 2>&1
cp "$WORK/good.tar.gz" "$SERVE/RichOS.app.tar.gz"
(cd "$src_tauri" && cargo tauri signer sign -f "$WRONG_KEY" -p "" "$SERVE/RichOS.app.tar.gz" >/dev/null 2>&1)
python3 - "$SERVE/latest.json" "$SERVE/RichOS.app.tar.gz.sig" <<'PY'
import json, sys
manifest, sig = sys.argv[1], sys.argv[2]
doc = json.load(open(manifest))
for platform in doc["platforms"].values():
    platform["signature"] = open(sig).read().strip()
json.dump(doc, open(manifest, "w"), indent=2)
print("    manifest re-pointed at the wrong key's signature")
PY

reinstall_old
run_selftest install wrongkey
wrong_code=$?
printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /'

if printf '%s\n' "$SELFTEST_OUT" | grep -q 'state=available.*available=0.1.1' \
   && [ "$wrong_code" -ne 0 ] && [ "$(failure_of)" = "signature" ]; then
  ok "K  an archive signed by another key is refused, as a signature failure (exit $wrong_code)"
else
  bad "K  an archive signed by another key is refused, as a signature failure" \
      "exit $wrong_code, failure kind '$(failure_of)'; selftest said: $SELFTEST_OUT"
fi

still="$(installed_version)"
if [ "$still" = "0.1.0" ]; then
  ok "K2 the installed bundle is UNTOUCHED — still 0.1.0"
else
  bad "K2 the installed bundle is UNTOUCHED — still 0.1.0" "Info.plist says '$still'"
fi

# ---------------------------------------------------------------------------
rule
say "the numbers this run produced:"
say "  update archive bytes : $NEW_BYTES"
say "  update archive sha256: $NEW_SHA"
say "  tampered sha256      : $TAMPER_SHA"
say "  logs                 : $LOGS"
rule

if [ "$FAIL" -gt 0 ]; then
  say "=== updater-e2e: $FAIL FAILED, $PASS passed ==="
  exit 1
fi
say "=== updater-e2e: all $PASS passed — an update was applied, and two bad ones were refused ==="
exit 0
