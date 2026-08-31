#!/usr/bin/env bash
#
# frontend-payload.test.sh — the rule that `app/ui/tests` never reaches a customer.
#
# THE DEFECT THIS EXISTS FOR, measured on 99d508b before it was fixed. `tauri.conf.json`
# set `"frontendDist": "../ui"`, and `tauri-codegen` walks that directory with
# `WalkDir::new(&path)` filtered on nothing but `is_dir()`. So every file beneath it, at
# any depth, was brotli-compressed and embedded into the executable — including the
# thirteen directories of committed Playwright screenshots under `app/ui/tests`.
#
#   RichOS.app with frontendDist = ../ui        34,277,027 bytes
#   RichOS.app with frontendDist = ../ui-dist   13,422,371 bytes
#
# Both built by the same `cargo tauri build --bundles app` into the same target
# directory; the only difference was that one line. 20,854,656 bytes — 60.8% of the
# application — was test evidence, and `strings` found 76 asset keys of the form
# `/tests/shots-splash/material-v13.png` inside the shipped binary to prove it.
#
# WHERE THE ASSETS ACTUALLY ARE, because this was assumed wrong before it was checked.
# They are NOT in `Contents/Resources`. A produced `RichOS.app` holds exactly three
# files — `Info.plist`, `MacOS/richos-tauri`, `Resources/icon.icns` — and the entire
# frontend lives inside the executable. That matters here: no inspection of the bundle
# directory could ever have found this, which is why nothing did for as long as it stood.
#
# WHAT THIS SUITE CAN AND CANNOT DO. It cannot compile the shell — a release build of the
# webview tree does not belong in a suite that runs in seconds, and `app/scripts` is
# otherwise about codesign and the keychain. So the binary-level proof is the build.rs
# guard, which panics rather than warns and cannot be reached by a different command. What
# runs HERE is the cheap half: the configuration and the exclusion list that guard reads.
# That is the half that regresses, because it is one word in a JSON file.
#
# Cases:
#   P1  frontendDist is set at all
#   P2  frontendDist does NOT point at the source tree `../ui`
#   P3  the directory it points at is git-ignored — a staged tree is generated, not authored
#   P4  build.rs stages the frontend, on every build and not only under the Tauri CLI
#   P5  build.rs's exclusion list names `tests`
#   P6  build.rs's exclusion list names `node_modules`
#   P7  build.rs REFUSES rather than warns — every failure in the staging path is a panic
#   P8  the evidence is still in the repository: the screenshots were excluded, not deleted
#   P9  if a staged tree exists on this machine, it carries no excluded directory
#   P10 ...and it carries the product: index.html reached the staged tree
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(cd "$DIR/.." && pwd)"
CONF="$APP/src-tauri/tauri.conf.json"
BUILD_RS="$APP/src-tauri/build.rs"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# Read frontendDist with python3 rather than grep, so a reformatted config still reads
# correctly and a MISSING key is distinguishable from an empty one.
DIST="$(python3 -c '
import json,sys
c=json.load(open(sys.argv[1]))
v=c.get("build",{}).get("frontendDist")
print(v if isinstance(v,str) else "")
' "$CONF" 2>/dev/null)"

echo ""
echo "=== P. what ships as the frontend ==="

if [ -n "$DIST" ]; then
  ok "P1 tauri.conf.json sets build.frontendDist ($DIST)"
else
  bad "P1 tauri.conf.json sets build.frontendDist" \
      "missing, empty, or not a string — nothing tells Tauri what to embed"
fi

# Resolved, not string-compared: `./../ui` and `../ui/` are the same directory as `../ui`,
# and a check that missed them would be a check in name only.
resolve() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
SRC="$(resolve "$APP/ui")"
DIST_ABS="$(resolve "$APP/src-tauri/$DIST")"

if [ "$DIST_ABS" != "$SRC" ]; then
  ok "P2 frontendDist is not the source tree app/ui"
else
  bad "P2 frontendDist is not the source tree app/ui" \
      "it resolves to $SRC — every file under it, including ui/tests, is embedded in the binary"
fi

# Asked about a path INSIDE the directory, deliberately. `app/.gitignore` says `ui-dist/`
# with a trailing slash, which matches directories only — and git cannot know a path is a
# directory when it does not exist yet. Asking about the directory itself therefore
# reported NOT IGNORED on any machine that had not built, which is every fresh clone. The
# rule was right and the question was wrong.
if git -C "$APP" check-ignore -q "$DIST_ABS/index.html" 2>/dev/null; then
  ok "P3 the staged frontend directory is git-ignored"
else
  bad "P3 the staged frontend directory is git-ignored" \
      "$DIST_ABS is not ignored; a generated tree in version control drifts from its source"
fi

if grep -q '^ *stage_frontend(Path::new("tauri.conf.json"), Path::new("../ui"));' "$BUILD_RS"; then
  ok "P4 build.rs stages the frontend, so a plain cargo build cannot bypass it"
else
  bad "P4 build.rs stages the frontend" \
      "no stage_frontend call in main() — only the Tauri CLI runs beforeBuildCommand, so a" \
      "plain cargo build would face a frontendDist nothing had created"
fi

EXCL="$(sed -n 's/^const UI_NOT_SHIPPED: &\[&str\] = &\[\(.*\)\];$/\1/p' "$BUILD_RS")"
if printf '%s' "$EXCL" | grep -q '"tests"'; then
  ok "P5 the exclusion list names tests"
else
  bad "P5 the exclusion list names tests" "UI_NOT_SHIPPED is [$EXCL] — 21 MB of screenshots would ship"
fi
if printf '%s' "$EXCL" | grep -q '"node_modules"'; then
  ok "P6 the exclusion list names node_modules"
else
  bad "P6 the exclusion list names node_modules" \
      "UI_NOT_SHIPPED is [$EXCL] — app/ui/tests/README.md tells developers to npm install there"
fi

# A warning is what the icon gate does, and it is right there because artwork is worth
# waiting for. Nothing is worth waiting for here, so a warning would be the bug.
if awk '/^fn stage_frontend/,/^}/' "$BUILD_RS" | grep -q 'cargo::warning'; then
  bad "P7 the staging refuses rather than warns" \
      "stage_frontend emits a cargo::warning — a warning scrolls past and the payload still ships"
else
  ok "P7 the staging refuses rather than warns"
fi

SHOTS="$(find "$APP/ui/tests" -type d -name 'shots-*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$SHOTS" -gt 0 ]; then
  ok "P8 the screenshots are still in the repository ($SHOTS shots-* directories)"
else
  bad "P8 the screenshots are still in the repository" \
      "none found under app/ui/tests — they are evidence a reviewer checks without running anything." \
      "The rule was change what SHIPS, not what is RECORDED."
fi

# P9/P10 read a staged tree only if this machine has built one. A staged tree that exists
# and is wrong is a finding; one that does not exist yet is not evidence either way, and
# says so instead of passing.
if [ -d "$DIST_ABS" ]; then
  STOWAWAYS=""
  for name in $(printf '%s' "$EXCL" | tr -d '" ' | tr ',' ' '); do
    [ -e "$DIST_ABS/$name" ] && STOWAWAYS="$STOWAWAYS $name"
  done
  if [ -z "$STOWAWAYS" ]; then
    ok "P9 the staged tree on this machine carries no excluded directory"
  else
    bad "P9 the staged tree on this machine carries no excluded directory" \
        "found:$STOWAWAYS in $DIST_ABS"
  fi
  if [ -f "$DIST_ABS/index.html" ]; then
    ok "P10 the staged tree carries the product (index.html)"
  else
    bad "P10 the staged tree carries the product (index.html)" \
        "$DIST_ABS has no index.html — the staging excluded too much and the app renders nothing"
  fi
else
  echo "  ....  P9/P10 no staged tree at $DIST_ABS — nothing has been built on this machine yet."
  echo "        Not counted as a pass. Run: cargo build --release --manifest-path app/src-tauri/Cargo.toml"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "=== frontend-payload tests: $FAIL FAILED, $PASS passed ==="
  exit 1
fi
echo "=== frontend-payload tests: all $PASS passed ==="
