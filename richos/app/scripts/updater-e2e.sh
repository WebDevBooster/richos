#!/usr/bin/env bash
# APPLY A REAL UPDATE, END TO END, ON THIS MACHINE — and prove the signature check refuses.
#
#   richos/app/scripts/updater-e2e.sh                 # the whole thing
#   richos/app/scripts/updater-e2e.sh --keep          # ...and leave the workspace for inspection
#
# Builds isolated 0.1.0 and 0.1.1 fixture bundles, serves a local update manifest
# and exercises the shipping download, staging and normal startup activation code.
#
# A: 0.1.0 discovers 0.1.1 through a real HTTP manifest fetch.
# B: download verifies the minisign signature and stages the next launch.
# C: the current bundle stays 0.1.0 with a durable prepared receipt.
# D: the next ordinary launch activates and runs 0.1.1 before the fixture runtime.
# T/K: tampering or a different signing key is refused as a signature failure,
#      preserving the current bundle.
# R: THE WAY BACK. From 0.1.1, "Go back" fetches v0.1.0's OWN immutable manifest from
#    a fixture release directory laid out exactly as a published one
#    (`releases/download/<tag>/latest.json`, two version tags and a moving channel
#    tag), verifies its signature through the same download, stages it, and the next
#    ordinary launch runs 0.1.0 again. A tampered v0.1.0 archive is refused the same
#    way case T's is — going back is not a hole in the signature story. And once back,
#    the way back is CLOSED (it would be a step up) while the way forward is open.
#
# RICHOS_UPDATE_SELFTEST invokes the same updates::check and updates::install
# functions as the Tauri commands. HOME and the user application destination are
# isolated. No vendor installation fallback or administrator authorization is used.
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
TEST_HOME="$WORK/home"
INSTALLED="$TEST_HOME/Applications"
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
# A PRISTINE COPY OF THE MANIFEST, because case K rewrites `$SERVE/latest.json` in
# place to point at the wrong key's signature and case R needs the real one.
cp "$SERVE/latest.json" "$WORK/good-latest.json"

# ---------------------------------------------------------------------------
# 2. Build the OLD version and "install" it: a copy of the bundle, outside the
#    build tree, exactly as a customer would have it.
# ---------------------------------------------------------------------------
build 0.1.0 1
# THE EARLIER TAG'S OWN ARTIFACTS, which is what case R needs and what a published
# release actually carries: `nightly.py::finish` uploads `latest.json` to the
# per-version release as well as to the rolling channel release, and NIGHTLY.md states
# existing tags and artifacts are never overwritten. Until this build carried
# `--updater` there was no signed 0.1.0 archive at all, and a rollback test would have
# had nothing to fetch.
cp "$BUNDLE_DIR/RichOS.app.tar.gz" "$WORK/old.tar.gz"
cp "$BUNDLE_DIR/RichOS.app.tar.gz.sig" "$WORK/old.tar.gz.sig"
cp "$BUNDLE_DIR/latest.json" "$WORK/old-latest.json"
rm -rf "$INSTALLED/RichOS.app"
/usr/bin/ditto "$BUNDLE_DIR/RichOS.app" "$INSTALLED/RichOS.app"
EXE="$INSTALLED/RichOS.app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INSTALLED/RichOS.app/Contents/Info.plist")"
cp -R "$INSTALLED/RichOS.app" "$WORK/pristine-0.1.0.app"

installed_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$INSTALLED/RichOS.app/Contents/Info.plist" 2>/dev/null
}

reinstall_old() {
  rm -rf "$INSTALLED/RichOS.app" "$INSTALLED/.richos-updater"
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
run_selftest() { # run_selftest <check|install|rollback> <logname> [endpoint] -> exit code, output in $SELFTEST_OUT
  local mode="$1" name="$2" endpoint="${3:-$BASE/latest.json}"
  local log="$LOGS/$name.log"
  HOME="$TEST_HOME" \
  RICHOS_UPDATE_SELFTEST="$mode" \
  RICHOS_UPDATE_ENDPOINT="$endpoint" \
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
say "CASE A-D — 0.1.0 discovers 0.1.1, verifies it, stages it, and opens next time as 0.1.1"
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
  ok "B  it downloaded the archive, the signature VERIFIED, and it staged the next launch"
else
  bad "B  it downloaded the archive, the signature VERIFIED, and it staged the next launch" \
      "exit $apply_code; selftest said: $SELFTEST_OUT (log: $SELFTEST_LOG)"
fi

after="$(installed_version)"
if [ "$after" = "0.1.0" ] && [ -f "$INSTALLED/.richos-updater/prepared.json" ]; then
  ok "C  the current bundle stays 0.1.0 and a durable update is staged"
else
  bad "C  the current bundle stays 0.1.0 and a durable update is staged" "Info.plist says '$after'"
fi

# D is the next ordinary launch. Startup activates the staged bundle under the
# session lease and execs its exact verified executable before the selftest runtime.
run_selftest check relaunch
relaunch_code=$?
printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /'
if [ "$relaunch_code" -eq 10 ] && [ "$(installed_version)" = "0.1.1" ] && printf '%s\n' "$SELFTEST_OUT" | grep -q 'state=upToDate.*current=0.1.1'; then
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
# CASE R — THE WAY BACK OFF A BAD RELEASE
#
# The CEO runs the nightly as his daily driver. Before this the only documented way
# off a bad one was NIGHTLY.md's "install a stable version at least as new as the
# nightly" — by hand, from a browser, on the machine he was trying to use.
#
# THE FIXTURE RELEASE DIRECTORY IS THE SHAPE A PUBLISHED ONE HAS, not a convenient
# one. `nightly.py::finish` uploads `latest.json` to the per-version release as well
# as to the rolling channel release, so every published nightly carries its own
# immutable signed manifest under its own tag:
#
#   serve/releases/download/nightly/latest.json    <- the moving channel tag
#   serve/releases/download/v0.1.1/latest.json     <- and the archive it names
#   serve/releases/download/v0.1.0/latest.json     <- the earlier tag, still there
#
# `updates::previous_manifest_url` derives the middle segment from the endpoint in
# force, which is why the layout has to be real: a flat directory would have proved a
# rule the product does not use.
# ---------------------------------------------------------------------------
rule
say "CASE R — from 0.1.1, go back to 0.1.0 through the same signature-verified download"
say ""

REL="$SERVE/releases/download"
mkdir -p "$REL/nightly" "$REL/v0.1.0" "$REL/v0.1.1"
cp "$WORK/good.tar.gz" "$REL/v0.1.1/RichOS.app.tar.gz"
cp "$WORK/good.tar.gz.sig" "$REL/v0.1.1/RichOS.app.tar.gz.sig"
cp "$WORK/old.tar.gz" "$REL/v0.1.0/RichOS.app.tar.gz"
cp "$WORK/old.tar.gz.sig" "$REL/v0.1.0/RichOS.app.tar.gz.sig"

# The manifests are the ones `package-app.sh` emitted, with only the announced URL
# moved to where this layout actually serves the bytes. The SIGNATURE is untouched:
# it covers the archive, and the archive is byte-identical to the one it was made
# from — which is the point, because a re-signed fixture would prove nothing.
retarget() { # retarget <src manifest> <dst manifest> <url>
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
src, dst, url = sys.argv[1:4]
doc = json.load(open(src))
for platform in doc["platforms"].values():
    platform["url"] = url
json.dump(doc, open(dst, "w"), indent=2)
PY
}
retarget "$WORK/good-latest.json" "$REL/v0.1.1/latest.json" "$BASE/releases/download/v0.1.1/RichOS.app.tar.gz"
retarget "$WORK/good-latest.json" "$REL/nightly/latest.json"  "$BASE/releases/download/v0.1.1/RichOS.app.tar.gz"
retarget "$WORK/old-latest.json"  "$REL/v0.1.0/latest.json"   "$BASE/releases/download/v0.1.0/RichOS.app.tar.gz"
CHANNEL="$BASE/releases/download/nightly/latest.json"

# Get this installation to where the CEO's is: on 0.1.1, having ARRIVED there through
# an update. A hand-placed 0.1.1 has no publication history and no way back, which is
# itself a stated limit of the feature — so the setup has to be the real path.
reinstall_old
run_selftest install prepare-back "$CHANNEL" >/dev/null 2>&1 || true
run_selftest check prepare-back-relaunch "$CHANNEL" >/dev/null 2>&1 || true
if [ "$(installed_version)" = "0.1.1" ]; then
  ok "R0 the installation arrived at 0.1.1 through a real update, so it has a history"
else
  bad "R0 the installation arrived at 0.1.1 through a real update" \
      "Info.plist says '$(installed_version)' (log: $LOGS/prepare-back-relaunch.log)"
fi

# ---- R1: a tampered EARLIER archive is refused exactly as a tampered newer one is ---
cp "$WORK/old.tar.gz" "$WORK/old-good-copy.tar.gz"
python3 - "$WORK/old.tar.gz" "$REL/v0.1.0/RichOS.app.tar.gz" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, "rb").read())
i = len(data) - 1024
data[i] ^= 0xFF
open(dst, "wb").write(bytes(data))
print("    flipped byte %d of %d in the v0.1.0 archive" % (i, len(data)))
PY

run_selftest rollback back-tamper "$CHANNEL"
back_tamper_code=$?
printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /'

# "IT FAILED" IS NOT ENOUGH, for the same reason case T states it: the run must have
# REACHED the rollback — found a way back to 0.1.0 — and then failed on the signature.
if printf '%s\n' "$SELFTEST_OUT" | grep -q 'back=0.1.0'; then
  if [ "$back_tamper_code" -ne 0 ] && [ "$(failure_of)" = "signature" ]; then
    ok "R1 it found the way back to 0.1.0, tried it, and REFUSED the tampered archive as a signature failure (exit $back_tamper_code)"
  else
    bad "R1 it found the way back to 0.1.0 and refused the tampered archive" \
        "exit $back_tamper_code, failure kind '$(failure_of)'; selftest said: $SELFTEST_OUT"
  fi
else
  bad "R1 it found the way back to 0.1.0 and refused the tampered archive" \
      "the run never resolved a way back, so this case proves nothing: $SELFTEST_OUT"
fi

still="$(installed_version)"
if [ "$still" = "0.1.1" ]; then
  ok "R2 the installed bundle is UNTOUCHED — still 0.1.1"
else
  bad "R2 the installed bundle is UNTOUCHED — still 0.1.1" "Info.plist says '$still'"
fi

# ---- R3: the real thing ------------------------------------------------------------
cp "$WORK/old-good-copy.tar.gz" "$REL/v0.1.0/RichOS.app.tar.gz"
run_selftest rollback back "$CHANNEL"
back_code=$?
printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /'

if [ "$back_code" -eq 0 ] && printf '%s\n' "$SELFTEST_OUT" | grep -q 'state=ready.*rollback=true'; then
  ok "R3 it fetched v0.1.0's own manifest, the signature VERIFIED, and it staged the way back"
else
  bad "R3 it fetched v0.1.0's own manifest, the signature VERIFIED, and it staged the way back" \
      "exit $back_code; selftest said: $SELFTEST_OUT (log: $SELFTEST_LOG)"
fi

after="$(installed_version)"
if [ "$after" = "0.1.1" ] && [ -f "$INSTALLED/.richos-updater/rollback.json" ]; then
  ok "R4 the running bundle is still 0.1.1 and the downgrade is AUTHORIZED but not yet applied"
else
  bad "R4 the running bundle is still 0.1.1 and the downgrade is authorized but not applied" \
      "Info.plist says '$after'; rollback.json present: $([ -f "$INSTALLED/.richos-updater/rollback.json" ] && echo yes || echo no)"
fi

# ---- R5: the next ordinary launch is the one that moves ----------------------------
run_selftest check back-relaunch "$CHANNEL"
back_relaunch_code=$?
printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /'
boot_line="$(grep '^\[richos\] rollback activated' "$SELFTEST_LOG" || true)"

if [ "$(installed_version)" = "0.1.0" ] && printf '%s\n' "$SELFTEST_OUT" | grep -q 'current=0.1.0'; then
  ok "R5 the next ordinary launch RELAUNCHED into 0.1.0 and reports itself as 0.1.0"
else
  bad "R5 the next ordinary launch RELAUNCHED into 0.1.0" \
      "Info.plist says '$(installed_version)'; selftest said: $SELFTEST_OUT (log: $SELFTEST_LOG)"
fi

# THE BOOT LINE NAMES BOTH VERSIONS AND WHICH WAY IT WENT. A record that says only
# what is now installed cannot tell a rollback from an update after the fact, and
# "which one did this Mac just do" is the first question asked when a nightly is bad.
if printf '%s\n' "$boot_line" | grep -q 'rollback activated: 0.1.1 -> 0.1.0'; then
  ok "R6 the boot line says WHICH WAY it went and between which versions: $boot_line"
else
  bad "R6 the boot line says which way it went and between which versions" \
      "found: '${boot_line:-nothing}' (log: $SELFTEST_LOG)"
fi

# The way FORWARD is still open — going back is not a trap.
if [ "$back_relaunch_code" -eq 0 ] && printf '%s\n' "$SELFTEST_OUT" | grep -q 'state=available.*available=0.1.1'; then
  ok "R7 ...and 0.1.1 is still offered, so going back is reversible by an ordinary update"
else
  bad "R7 0.1.1 is still offered after going back" \
      "exit $back_relaunch_code; selftest said: $SELFTEST_OUT"
fi

# ---- R8: and the way BACK is now closed, because it would be a step UP --------------
run_selftest rollback back-again "$CHANNEL"
back_again_code=$?
printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /'
if [ "$back_again_code" -eq 13 ] && printf '%s\n' "$SELFTEST_OUT" | grep -q 'back=-'; then
  ok "R8 there is no second way back: the version this copy came from is NEWER, and it says so instead of stepping up (exit $back_again_code)"
else
  bad "R8 there is no second way back from 0.1.0" \
      "exit $back_again_code; selftest said: $SELFTEST_OUT (log: $SELFTEST_LOG)"
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
