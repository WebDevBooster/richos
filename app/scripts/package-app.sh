#!/usr/bin/env bash
# Build, sign and VERIFY the RichOS desktop bundle. One command, one final line.
#
#   app/scripts/package-app.sh                     # ad-hoc signed (today's reality)
#   app/scripts/package-app.sh --sign developer-id # requires RICHOS_SIGNING_IDENTITY
#   app/scripts/package-app.sh --verify-only <path/to/RichOS.app>
#
# WHY THIS FILE EXISTS
# --------------------
# `app/src-tauri/build.rs` has carried a real, two-way-proven icon gate since the
# icon pipeline landed: it warns on an ordinary `cargo build` and PANICS when
# `RICHOS_REQUIRE_REAL_ICONS=1`. Nothing anywhere set that variable, because there
# was no bundling script — so the gate protected no release path at all and a
# bundle could still ship the placeholder set. This script is the caller the gate
# was written for. It exports RICHOS_REQUIRE_REAL_ICONS=1, and it refuses rather
# than warns.
#
# It also checks the icons BEFORE the build, so a placeholder set costs you two
# seconds instead of a full release compile. Both checks stay: the pre-flight is
# for legibility, the environment variable is the structural guarantee. If the
# pre-flight were ever deleted, `build.rs` still stops the build.
#
# SIGNING — TWO PATHS, NEITHER GUESSED
# ------------------------------------
# Which signing path runs is decided by explicit configuration and by what is
# actually on this machine. It is never inferred and never silently downgraded:
# asking for `developer-id` without a usable identity is a hard refusal, not a
# quiet fall back to ad-hoc.
#
#   adhoc         (default) — no certificate needed. WHAT IT COSTS is printed at
#                 the moment it is incurred: an ad-hoc bundle embeds no designated
#                 requirement, so macOS's privacy database (TCC) binds microphone
#                 and accessibility grants to the raw code hash. Every rebuild is a
#                 different application to macOS and both grants die. Toggling the
#                 permission in System Settings provably does not migrate a grant.
#                 Measured 2026-08-24; see richos-hq/wiki/packaging-and-signing.md.
#
#   developer-id  present, correct, and INERT until somebody supplies an identity.
#                 Requires RICHOS_SIGNING_IDENTITY naming a Developer ID Application
#                 identity that `security find-identity -v -p codesigning` actually
#                 reports. Adds the hardened runtime, a secure timestamp and the
#                 microphone entitlement. This path selects itself NEVER — not even
#                 if an identity appears on the machine — because whether to enrol
#                 with Apple at all is an open CEO decision (1.1 in
#                 richos-hq/wiki/ceo-decisions.md), and a script must not answer it
#                 by running.
#
# Notarization is opt-in on top of developer-id (RICHOS_NOTARIZE=1 plus Apple
# credentials). Without it a developer-id build is signed but NOT notarized, and
# says so — Gatekeeper still blocks a downloaded copy.
#
# WHAT IT VERIFIES AFTER THE BUILD — the artefact, not the exit code of the
# builder. The bundle exists and is executable; its signature verifies; the
# signature is the KIND that was asked for; the icon that actually shipped inside
# Contents/Resources is the icon this repository generated; and the bundled
# Info.plist carries NSMicrophoneUsageDescription (without it the app cannot ask
# for the microphone at all, and Tauri's plist merge for that key had never been
# checked by anyone).
#
# `--verify-only` runs that whole check set against a bundle built earlier, so a
# bundle can be re-checked without a rebuild.
#
# THE .app IS THE ARTEFACT THAT MATTERS. It defaults to `--bundles app` rather
# than the `"targets": "all"` in tauri.conf.json: DMG creation is a separate,
# flakier downstream step (it mounts a disk image) whose failure says nothing
# about whether the application is correct. Pass `--bundles app,dmg` when you
# want the installer too.
#
# Exit codes: 0 success. 1 the produced bundle failed verification. 2 refused
# before building (icons not shippable, or the signing configuration is not
# usable). 3 a prerequisite is missing. 4 the build itself failed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$here/.." && pwd)"
src_tauri="$app_dir/src-tauri"

sign_mode="${RICHOS_SIGN_MODE:-adhoc}"
bundles="app"
verify_only=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sign)        sign_mode="${2:-}"; shift 2 ;;
    --sign=*)      sign_mode="${1#*=}"; shift ;;
    --bundles)     bundles="${2:-}"; shift 2 ;;
    --bundles=*)   bundles="${1#*=}"; shift ;;
    --verify-only) verify_only="${2:-}"; shift 2 ;;
    --verify-only=*) verify_only="${1#*=}"; shift ;;
    -h|--help)     sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

case "$sign_mode" in
  adhoc|developer-id) ;;
  *) echo "error: --sign must be 'adhoc' or 'developer-id', got: ${sign_mode}" >&2; exit 2 ;;
esac

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Verification of a finished bundle. Shared by the build path and --verify-only,
# so the two can never drift into checking different things.
# ---------------------------------------------------------------------------
verify_bundle() {
  local app="$1" mode="$2"
  local failures=()

  if [ ! -d "$app" ]; then
    warn "  - $app does not exist or is not a bundle directory"
    return 1
  fi

  local exe_name exe
  exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
                "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [ -z "$exe_name" ]; then
    failures+=("$app/Contents/Info.plist has no CFBundleExecutable — macOS cannot launch this bundle")
  else
    exe="$app/Contents/MacOS/$exe_name"
    [ -x "$exe" ] || failures+=("Contents/MacOS/$exe_name is missing or not executable")
  fi

  # 1. The signature verifies at all. --deep so a broken sidecar or nested
  #    framework counts, --strict so a sealed-resource mismatch is not waved through.
  local cs_out
  if ! cs_out="$(codesign --verify --deep --strict --verbose=2 "$app" 2>&1)"; then
    failures+=("codesign --verify --deep --strict FAILED: $(printf '%s' "$cs_out" | tr '\n' '; ')")
  fi

  # 2. The signature is the KIND that was asked for. A developer-id run that
  #    somehow produced an ad-hoc signature must fail loudly, not pass because
  #    "it is signed".
  local desc
  desc="$(codesign -dvvv "$app" 2>&1 || true)"
  local cdhash
  cdhash="$(printf '%s\n' "$desc" | sed -n 's/^CDHash=//p' | head -1)"

  case "$mode" in
    adhoc)
      if ! printf '%s\n' "$desc" | grep -q '^Signature=adhoc'; then
        failures+=("expected an ad-hoc signature; codesign reports: $(printf '%s\n' "$desc" | grep -E '^(Signature|Authority)=' | tr '\n' '; ')")
      fi
      ;;
    developer-id)
      if ! printf '%s\n' "$desc" | grep -q '^Authority=Developer ID Application:'; then
        failures+=("expected a Developer ID Application signature; codesign reports: $(printf '%s\n' "$desc" | grep -E '^(Signature|Authority)=' | tr '\n' '; ')")
      fi
      # Hardened runtime is a notarization prerequisite, and codesign prints it as
      # a flag on the CodeDirectory line.
      if ! printf '%s\n' "$desc" | grep -qE '^CodeDirectory .*flags=.*runtime'; then
        failures+=("the hardened runtime is NOT enabled — Apple will refuse to notarize this bundle")
      fi
      if ! printf '%s\n' "$desc" | grep -q '^Timestamp='; then
        failures+=("no secure timestamp on the signature — required for notarization")
      fi
      local ents
      ents="$(codesign -d --entitlements :- --xml "$app" 2>/dev/null || true)"
      if ! printf '%s' "$ents" | grep -q 'com.apple.security.device.audio-input'; then
        failures+=("com.apple.security.device.audio-input is not in the signed entitlements — under the hardened runtime the app cannot open the microphone at all")
      fi
      ;;
  esac

  # 3. The icon that SHIPPED is the icon this repository generated. The build
  #    gate checks the source files; this checks what came out the other end,
  #    which is the only copy the CEO ever sees.
  local shipped="$app/Contents/Resources/icon.icns"
  local source_icns="$src_tauri/icons/icon.icns"
  if [ ! -f "$shipped" ]; then
    failures+=("Contents/Resources/icon.icns is missing — the bundle ships with no macOS icon")
  elif [ ! -f "$source_icns" ]; then
    failures+=("$source_icns does not exist, so the shipped icon cannot be checked against its source")
  elif ! cmp -s "$shipped" "$source_icns"; then
    failures+=("Contents/Resources/icon.icns differs from src-tauri/icons/icon.icns — the bundle is carrying an icon this repository did not generate")
  fi

  # 4. The microphone usage string survived Tauri's Info.plist merge. Flagged
  #    unverified in src-tauri/Info.plist's own comment and in the signing wiki;
  #    without it macOS never shows the permission prompt.
  local mic
  mic="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' \
           "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [ -z "$mic" ]; then
    failures+=("Contents/Info.plist has no NSMicrophoneUsageDescription — voice mode cannot even ask for the microphone")
  fi

  if [ ${#failures[@]} -gt 0 ]; then
    warn ""
    warn "FAILED — the bundle is not shippable:"
    warn ""
    local f
    for f in "${failures[@]}"; do warn "  - $f"; done
    warn ""
    return 1
  fi

  BUNDLE_CDHASH="$cdhash"
  BUNDLE_MIC="$mic"
  return 0
}

# ---------------------------------------------------------------------------
# --verify-only: re-check a bundle built earlier, no compile.
# ---------------------------------------------------------------------------
if [ -n "$verify_only" ]; then
  say "verifying an existing bundle: $verify_only"
  say "  expected signing mode: $sign_mode"
  if ! verify_bundle "$verify_only" "$sign_mode"; then
    exit 1
  fi
  say ""
  say "OK: $(basename "$verify_only") verifies — ${sign_mode} signature, cdhash ${BUNDLE_CDHASH}, shipped icon matches this repository, microphone usage string present."
  exit 0
fi

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  warn "error: this entrypoint builds the macOS bundle and runs on macOS only."
  warn "       (uname -s reports $(uname -s).) No Windows bundle has ever been"
  warn "       built for RichOS and there is no Windows signing certificate —"
  warn "       richos-hq/wiki/packaging-and-signing.md, 'Windows'."
  exit 3
fi

# cargo is frequently absent from a non-login shell's PATH even when it is
# installed. Adding its own well-known location is not a guess about signing;
# it is stated out loud when it happens.
if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
  PATH="$HOME/.cargo/bin:$PATH"
  export PATH
  say "note: cargo was not on PATH; using $HOME/.cargo/bin (source \$HOME/.cargo/env to make that permanent)"
fi

if ! command -v cargo >/dev/null 2>&1; then
  warn "error: cargo not found on PATH. Install Rust (https://rustup.rs) and re-run."
  exit 3
fi

if ! cargo tauri --version >/dev/null 2>&1; then
  warn "error: the Tauri CLI is not installed for this cargo."
  warn ""
  warn "  cargo install tauri-cli --version '^2'"
  warn ""
  exit 3
fi

if ! command -v python3 >/dev/null 2>&1; then
  warn "error: python3 not found on PATH; it runs the icon pre-flight."
  exit 3
fi

# ---------------------------------------------------------------------------
# Signing mode: resolved before the build, so a refusal costs no compile time.
# ---------------------------------------------------------------------------
identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
identity_count="$(printf '%s\n' "$identities" | sed -n 's/^ *\([0-9][0-9]*\) valid identities* found/\1/p' | tail -1)"
identity_count="${identity_count:-0}"

tauri_config_overlay=""

if [ "$sign_mode" = "developer-id" ]; then
  wanted="${RICHOS_SIGNING_IDENTITY:-}"
  if [ -z "$wanted" ]; then
    warn ""
    warn "REFUSING — --sign developer-id was requested but RICHOS_SIGNING_IDENTITY is not set."
    warn ""
    warn "  Set it to the identity string or SHA-1 of a Developer ID Application"
    warn "  certificate, exactly as 'security find-identity -v -p codesigning' prints it."
    warn ""
    warn "  This machine currently reports ${identity_count} codesigning identit(y/ies)."
    warn "  Whether to enrol with Apple at all is an open CEO decision (1.1 in"
    warn "  richos-hq/wiki/ceo-decisions.md). This script will not choose one, and"
    warn "  it will NOT quietly fall back to ad-hoc when you asked for Developer ID."
    warn ""
    exit 2
  fi
  if ! printf '%s\n' "$identities" | grep -Fq -- "$wanted"; then
    warn ""
    warn "REFUSING — RICHOS_SIGNING_IDENTITY is set to:"
    warn ""
    warn "    $wanted"
    warn ""
    warn "  but 'security find-identity -v -p codesigning' does not report it on this"
    warn "  machine (${identity_count} valid identit(y/ies) found). Signing with an identity"
    warn "  that is not there cannot work, and falling back to ad-hoc would silently"
    warn "  produce a bundle whose permissions die on the next rebuild — exactly the"
    warn "  failure Developer ID was asked for. Refusing instead."
    warn ""
    exit 2
  fi
  ents="$src_tauri/Entitlements.plist"
  if [ ! -f "$ents" ]; then
    warn "error: $ents is missing; the hardened runtime needs it for the microphone."
    exit 2
  fi
  # Applied ONLY on this path, as a config overlay, so an ordinary build and the
  # ad-hoc path are untouched by it.
  tauri_config_overlay="$(python3 - "$wanted" "$ents" <<'PY'
import json, sys
print(json.dumps({"bundle": {"macOS": {
    "signingIdentity": sys.argv[1],
    "entitlements": sys.argv[2],
    "hardenedRuntime": True,
}}}))
PY
)"
  export APPLE_SIGNING_IDENTITY="$wanted"

  if [ "${RICHOS_NOTARIZE:-}" = "1" ]; then
    missing=""
    for v in APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
      eval "val=\${$v:-}"
      [ -n "$val" ] || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
      warn ""
      warn "REFUSING — RICHOS_NOTARIZE=1 but these are unset:$missing"
      warn ""
      warn "  Notarization needs an Apple ID, an app-specific password and a Team ID."
      warn "  Refusing rather than producing a bundle that would be called notarized"
      warn "  and would not be."
      warn ""
      exit 2
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Icon pre-flight — fast and legible. build.rs is the structural guarantee.
# ---------------------------------------------------------------------------
say "RichOS packaging entrypoint"
say "  repository app dir : $app_dir"
say "  signing mode       : $sign_mode"
say "  bundle targets     : $bundles"
say ""
say "checking the app icons before building (the build gate re-checks independently)..."

if ! python3 "$here/lib/app_icons.py" verify; then
  warn ""
  warn "REFUSING TO PACKAGE — the icon set above is not shippable."
  warn ""
  warn "  A bundle built now would carry no icon, or the wrong one, at the sizes"
  warn "  named. This is the single failure this entrypoint exists to make"
  warn "  impossible, so it stops here rather than warning and continuing."
  warn ""
  warn "  Fix: app/scripts/generate-app-icons.sh /path/to/artwork.png"
  warn "  One square PNG, at least 1024x1024, transparent background."
  warn "  The artwork itself is an open CEO item (2.6) — it is not something to"
  warn "  work around with new placeholder art."
  warn ""
  exit 2
fi

# ---------------------------------------------------------------------------
# What the chosen signature costs — said at the moment it is incurred.
# ---------------------------------------------------------------------------
say ""
if [ "$sign_mode" = "adhoc" ]; then
  say "SIGNING: ad-hoc. What that costs, every time:"
  say ""
  say "  An ad-hoc bundle embeds no designated requirement, so macOS stores the raw"
  say "  code hash as the identity of every permission it grants. This build will be"
  say "  a DIFFERENT APPLICATION to macOS than the last one, so its microphone and"
  say "  accessibility grants start at zero — and toggling the switch in System"
  say "  Settings provably does not migrate a grant (measured 2026-08-24,"
  say "  richos-hq/wiki/packaging-and-signing.md). Voice mode and paste-at-cursor"
  say "  will need granting again after installing this."
  say ""
  say "  The fix is a Developer ID certificate, which is an open CEO decision (1.1)."
  say "  This script has a working --sign developer-id path waiting for it."
  if [ "$identity_count" != "0" ]; then
    say ""
    say "  LOUD NOTE: this machine reports ${identity_count} codesigning identit(y/ies), so a"
    say "  Developer ID build may now be possible. It was NOT used, because nothing"
    say "  asked for it. Re-run with --sign developer-id and RICHOS_SIGNING_IDENTITY."
  fi
else
  say "SIGNING: Developer ID — $RICHOS_SIGNING_IDENTITY"
  say "  hardened runtime + secure timestamp + $src_tauri/Entitlements.plist"
  if [ "${RICHOS_NOTARIZE:-}" = "1" ]; then
    say "  notarization: ON (Apple ID $APPLE_ID, team $APPLE_TEAM_ID)"
  else
    say "  notarization: OFF — set RICHOS_NOTARIZE=1 with APPLE_ID, APPLE_PASSWORD"
    say "  and APPLE_TEAM_ID to notarize. Without it this bundle is SIGNED BUT NOT"
    say "  NOTARIZED: Gatekeeper still blocks it on a machine that downloaded it."
  fi
fi

# ---------------------------------------------------------------------------
# Build. THIS is the line the whole file exists for.
# ---------------------------------------------------------------------------
export RICHOS_REQUIRE_REAL_ICONS=1

say ""
say "building (release) with RICHOS_REQUIRE_REAL_ICONS=1 — the icon gate is FATAL for this build..."
say ""

build_args=(tauri build --bundles "$bundles")
[ -n "$tauri_config_overlay" ] && build_args+=(--config "$tauri_config_overlay")

if ! (cd "$src_tauri" && cargo "${build_args[@]}"); then
  warn ""
  warn "the build did not complete — nothing was packaged. The output above is the reason."
  exit 4
fi

# ---------------------------------------------------------------------------
# Find and verify what was actually produced.
# ---------------------------------------------------------------------------
target_dir="${CARGO_TARGET_DIR:-$src_tauri/target}"
bundle_dir="$target_dir/release/bundle/macos"
app_bundle="$(ls -d "$bundle_dir"/*.app 2>/dev/null | head -1 || true)"

if [ -z "$app_bundle" ]; then
  warn ""
  warn "the builder exited 0 but no .app exists under $bundle_dir — refusing to"
  warn "report success for a bundle that is not there."
  exit 1
fi

say ""
say "verifying the artefact that was produced (not the builder's exit code)..."
if ! verify_bundle "$app_bundle" "$sign_mode"; then
  exit 1
fi

if [ "$sign_mode" = "adhoc" ]; then
  say ""
  say "OK: $(basename "$app_bundle") is bundled, ad-hoc signed and verified — real icons, cdhash ${BUNDLE_CDHASH}, microphone usage string present; NOT notarized, and its permission grants die on the next rebuild. Path: $app_bundle"
elif [ "${RICHOS_NOTARIZE:-}" = "1" ]; then
  say ""
  say "OK: $(basename "$app_bundle") is bundled, Developer ID signed, notarized and verified — real icons, cdhash ${BUNDLE_CDHASH}, hardened runtime, microphone entitlement and usage string present. Path: $app_bundle"
else
  say ""
  say "OK: $(basename "$app_bundle") is bundled, Developer ID signed and verified but NOT NOTARIZED — real icons, cdhash ${BUNDLE_CDHASH}, hardened runtime, microphone entitlement and usage string present; Gatekeeper will still block a downloaded copy. Path: $app_bundle"
fi
