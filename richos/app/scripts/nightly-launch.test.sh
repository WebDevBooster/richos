#!/usr/bin/env bash
# nightly-launch.test.sh — the nightly launcher, against a fake home, fake ZIPs and stub
# `open`/`ps`/`launchctl`. Nothing is unpacked outside a mktemp sandbox, nothing reads or
# writes the operator's home, and nothing is launched: `open` is a stub that records its
# arguments and pretends a process started.
# run-tests: no-host-screen: `open` is RICHOS_NIGHTLY_OPEN, a stub written under mktemp that records its arguments; no app is started
# run-tests: inputs richos/app/scripts/nightly-launch.test.sh richos/app/scripts/nightly-launch.sh
# run-tests: covers richos/app/scripts/nightly-launch.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH="$DIR/nightly-launch.sh"
FAILS=0; PASSES=0
ok()  { PASSES=$((PASSES + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

[ "$(uname -s)" = "Darwin" ] || { echo "nightly-launch.test.sh: macOS only (ditto, PlistBuddy, open)"; exit 2; }

SBOX="$(mktemp -d "${TMPDIR:-/tmp}/nightly-launch-test.XXXXXX")" || exit 2
SBOX="$(cd "$SBOX" && pwd -P)"
trap 'rm -rf "$SBOX"' EXIT

# ---------------------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------------------
STUBS="$SBOX/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/open" <<'EOF'
#!/bin/bash
# Records every argument, one per line, then "starts" the app by adding a ps row.
printf '%s\n' "$@" > "$STUB_STATE/open.args"
[ -n "${STUB_OPEN_FAIL:-}" ] && { echo "stub open: refused" >&2; exit 1; }
app=""; prev=""
for a in "$@"; do [ "$prev" = "-a" ] && app="$a"; prev="$a"; done
[ -n "${STUB_OPEN_NOPROC:-}" ] || printf '4242 1 %s/Contents/MacOS/richos-tauri\n' "$app" >> "$STUB_STATE/ps.rows"
exit 0
EOF
cat > "$STUBS/ps" <<'EOF'
#!/bin/bash
# `ps -axo pid=` or `ps -axo pid=,ppid=,comm=`, from the rows file.
touch "$STUB_STATE/ps.rows"
case "$*" in
  *comm=*) cat "$STUB_STATE/ps.rows" ;;
  *) cut -d' ' -f1 "$STUB_STATE/ps.rows" ;;
esac
EOF
cat > "$STUBS/launchctl" <<'EOF'
#!/bin/bash
[ "$1" = "getenv" ] && [ "$2" = "CLAUDE_CONFIG_DIR" ] && [ -n "${STUB_LAUNCHD_CCD:-}" ] && echo "$STUB_LAUNCHD_CCD"
exit 0
EOF
chmod +x "$STUBS"/*

# make_zip <out.zip> <version> [bundle-id] [extra-top-level-file]
make_zip() {
  local out="$1" version="$2" id="${3:-com.richos.app}" extra="${4:-}" d
  d="$(mktemp -d "$SBOX/zip.XXXXXX")"
  mkdir -p "$d/RichOS.app/Contents/MacOS"
  printf '#!/bin/sh\n' > "$d/RichOS.app/Contents/MacOS/richos-tauri"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $id" \
    -c "Add :CFBundleShortVersionString string $version" \
    -c "Add :RichOSSourceCommit string c0ffee$version" \
    "$d/RichOS.app/Contents/Info.plist" >/dev/null
  if [ -n "$extra" ]; then
    printf 'x\n' > "$d/$extra"
    ( cd "$d" && /usr/bin/zip -qr "$out" RichOS.app "$extra" )
  else
    /usr/bin/ditto -c -k --keepParent "$d/RichOS.app" "$out"
  fi
  rm -rf "$d"
}

# new_home <name>: a fake account home with everything the sign-in needs, a daily
# driver's ~/myrichos beside it holding one file, and a record the daily driver reads.
new_home() {
  local h="$SBOX/$1"
  mkdir -p "$h/.claude" "$h/Library/Keychains" "$h/.local/bin" "$h/myrichos" \
           "$h/record/wiki" "$h/record/loro" "$h/Library/Application Support/RichOS"
  printf '{"oauthAccount":"fixture"}\n' > "$h/.claude.json"
  printf '#!/bin/sh\n' > "$h/.local/bin/claude"
  printf 'daily driver data\n' > "$h/myrichos/keep.txt"
  ln -s "$h/record" "$h/Library/Application Support/RichOS/loro-root"
  printf '%s' "$h"
}

ZIPS="$SBOX/zips"; mkdir -p "$ZIPS"
make_zip "$ZIPS/v1.zip" "1.2.0-nightly.20260921.25"
make_zip "$ZIPS/v2.zip" "1.2.0-nightly.20260924.1"
make_zip "$ZIPS/wrongid.zip" "1.2.0-nightly.20260921.25" "com.example.other"
make_zip "$ZIPS/extra.zip" "1.2.0-nightly.20260921.25" "com.richos.app" "README.txt"
printf 'not a zip\n' > "$ZIPS/notzip.zip"

# run <home> <args...>: the launcher under test, with every seam pointed at the sandbox.
# Output in $OUT, exit code in $RC. TMPDIR is a sandbox directory so its cleanup is visible.
run() {
  local h="$1"; shift
  export STUB_STATE="$h.state"; mkdir -p "$STUB_STATE" "$SBOX/tmp"
  OUT="$(env -u CLAUDE_CONFIG_DIR \
      RICHOS_NIGHTLY_TEST_REAL_HOME="$h" \
      RICHOS_NIGHTLY_OPEN="$STUBS/open" RICHOS_NIGHTLY_PS="$STUBS/ps" \
      RICHOS_NIGHTLY_LAUNCHCTL="$STUBS/launchctl" RICHOS_NIGHTLY_WAIT_SECONDS="${WAIT:-3}" \
      TMPDIR="$SBOX/tmp" \
      bash "$LAUNCH" "$@" 2>&1)"
  RC=$?
}
quit_app() { : > "$1.state/ps.rows"; }   # the stub app "quits"
expect_refusal() {  # <case> <needle>
  if [ "$RC" -ne 2 ]; then bad "$1" "exit $RC, expected 2: $OUT"
  elif ! grep -qF -- "$2" <<<"$OUT"; then bad "$1" "refusal does not say '$2': $OUT"
  else ok "$1"; fi
}
tmp_clean() {  # <case>
  if [ -n "$(ls -A "$SBOX/tmp" 2>/dev/null)" ]; then bad "$1" "scratch left behind: $(ls -A "$SBOX/tmp")"; else ok "$1"; fi
}

# ---------------------------------------------------------------------------------------
# L1 — a newborn folder a, from a ZIP
# ---------------------------------------------------------------------------------------
H="$(new_home h1)"; F="$H/myrichos-nightly-a"
run "$H" a "$ZIPS/v1.zip"
if [ "$RC" -ne 0 ]; then bad "L1 folder a starts from a ZIP" "exit $RC: $OUT"; else ok "L1 folder a starts from a ZIP"; fi
grep -q '^slot=a version=1.2.0-nightly.20260921.25 commit=c0ffee1.2.0-nightly.20260921.25 pid=4242$' <<<"$OUT" \
  && ok "L1 prints the slot, the version, the commit and the pid of the started app" \
  || bad "L1 prints the slot, the version, the commit and the pid of the started app" "$OUT"
[ -d "$F/RichOS.app/Contents/MacOS" ] && ok "L1 the app is unpacked into the folder" || bad "L1 the app is unpacked into the folder" "$(ls -la "$F")"
M="$F/nightly-launch.txt"
if grep -qx 'version=1.2.0-nightly.20260921.25' "$M" 2>/dev/null \
   && grep -qx "zip_sha256=$(shasum -a 256 "$ZIPS/v1.zip" | cut -d' ' -f1)" "$M"; then
  ok "L1 the folder records the version and the ZIP's digest"
else bad "L1 the folder records the version and the ZIP's digest" "$(cat "$M" 2>&1)"; fi
[ "$(stat -f %Lp "$F")" = "700" ] && [ "$(stat -f %Lp "$F/home")" = "700" ] \
  && ok "L1 the folder and its home are private (0700), as the updater's ancestor check wants" \
  || bad "L1 the folder and its home are private (0700)" "$(stat -f '%Lp %N' "$F" "$F/home")"
LINKS_OK=1
for pair in ".claude:$H/.claude" "Library/Keychains:$H/Library/Keychains" ".local/bin/claude:$H/.local/bin/claude"; do
  l="${pair%%:*}"; t="${pair#*:}"
  [ -L "$F/home/$l" ] && [ "$(readlink "$F/home/$l")" = "$t" ] || { LINKS_OK=0; bad "L1 home/$l links to $t" "$(ls -la "$F/home/$l" 2>&1)"; }
done
[ "$LINKS_OK" = 1 ] && ok "L1 ~/.claude, ~/Library/Keychains and ~/.local/bin/claude are linked from the folder's home"
if [ -f "$F/home/.claude.json" ] && [ ! -L "$F/home/.claude.json" ] && cmp -s "$F/home/.claude.json" "$H/.claude.json"; then
  ok "L1 ~/.claude.json is COPIED, not linked"
else bad "L1 ~/.claude.json is COPIED, not linked" "$(ls -la "$F/home/.claude.json" 2>&1)"; fi
[ ! -e "$F/memory" ] && [ ! -e "$F/home/Library/Application Support/RichOS/loro-root" ] \
  && ok "L1 folder a is a newborn: no memory folder, no memory pointer" \
  || bad "L1 folder a is a newborn" "$(ls -la "$F" "$F/home/Library/Application Support/RichOS" 2>&1)"
A="$H.state/open.args"
if [ "$(sed -n 1p "$A")" = "-n" ] && [ "$(sed -n 2p "$A")" = "-a" ] && [ "$(sed -n 3p "$A")" = "$F/RichOS.app" ]; then
  ok "L1 opens a NEW instance of the folder's own app through LaunchServices"
else bad "L1 opens a NEW instance of the folder's own app" "$(head -3 "$A")"; fi
ENV_OK=1
for want in "HOME=$F/home" "CFFIXED_USER_HOME=$F/home" "RICHOS_ACTIVATION=regular" "DISABLE_AUTOUPDATER=1" \
            "LORO_CORPUS=" "LORO_ROOT=" "RICHOS_ENGINE_DIR=" "RICHOS_ENGINE_ROOT=" "RICHOS_CLAUDE_BIN="; do
  grep -qxF -- "$want" "$A" || { ENV_OK=0; bad "L1 the app is started with $want" "$(tr '\n' ' ' < "$A")"; }
done
[ "$ENV_OK" = 1 ] && ok "L1 HOME and CFFIXED_USER_HOME are the folder's home; activation regular; claude pinned; LORO_* and the engine overrides are EMPTY"
if grep -E '^(RICHOS_ENGINE_DIR|RICHOS_ENGINE_ROOT|LORO_CORPUS|LORO_ROOT|RICHOS_CLAUDE_BIN)=.' "$A" >/dev/null; then
  bad "L1 no engine, memory or claude override carries a value" "$(grep -E '^(RICHOS_ENGINE|LORO_|RICHOS_CLAUDE)' "$A")"
else ok "L1 no engine, memory or claude override carries a value, so the pinned engine is the only one the nightly can boot"; fi
grep -q '^CLAUDE_CONFIG_DIR' "$A" && bad "L1 CLAUDE_CONFIG_DIR is never passed" "$(grep CLAUDE_CONFIG_DIR "$A")" \
  || ok "L1 CLAUDE_CONFIG_DIR is never passed"
grep -qx -- "--stdout" "$A" && grep -q "^$F/logs/" "$A" && ok "L1 the app's output goes to the folder's own logs/" \
  || bad "L1 the app's output goes to the folder's own logs/" "$(tr '\n' ' ' < "$A")"
[ "$(cat "$H/myrichos/keep.txt")" = "daily driver data" ] && [ "$(ls -A "$H/myrichos")" = "keep.txt" ] \
  && ok "L1 ~/myrichos beside it is untouched (a sibling name is not inside it)" \
  || bad "L1 ~/myrichos beside it is untouched" "$(ls -la "$H/myrichos")"
tmp_clean "L1 the launcher's scratch is gone after it exits"

# ---------------------------------------------------------------------------------------
# L2 — a second start while it runs; the same ZIP again after it quit
# ---------------------------------------------------------------------------------------
touch "$F/RichOS.app/sentinel"
run "$H" a "$ZIPS/v1.zip"
expect_refusal "L2 a second start while the folder's app runs is refused (one writer per data)" "already running"
quit_app "$H"
printf 'changed\n' > "$H/.claude.json"
run "$H" a "$ZIPS/v1.zip"
if [ "$RC" -eq 0 ] && [ -e "$F/RichOS.app/sentinel" ]; then
  ok "L2 the same ZIP again starts the app already there, without unpacking it again"
else bad "L2 the same ZIP again starts the app already there" "exit $RC, sentinel $( [ -e "$F/RichOS.app/sentinel" ] && echo kept || echo gone): $OUT"; fi
grep -qx changed "$F/home/.claude.json" && ok "L2 ~/.claude.json is copied afresh at every start" \
  || bad "L2 ~/.claude.json is copied afresh at every start" "$(cat "$F/home/.claude.json")"
quit_app "$H"

# ---------------------------------------------------------------------------------------
# L3/L4 — another version: refused, then --replace keeps the data
# ---------------------------------------------------------------------------------------
BEFORE_MARKER="$(cat "$M")"
run "$H" a "$ZIPS/v2.zip"
expect_refusal "L3 a folder holding another version is refused without --replace" "holds 1.2.0-nightly.20260921.25"
[ "$(cat "$M")" = "$BEFORE_MARKER" ] && [ -e "$F/RichOS.app/sentinel" ] \
  && ok "L3 the refusal changed nothing: same app, same record" || bad "L3 the refusal changed nothing" "$(cat "$M")"
mkdir -p "$F/home/Library/Application Support/com.richos.app"
printf 'conversation\n' > "$F/home/Library/Application Support/com.richos.app/data.txt"
run "$H" a "$ZIPS/v2.zip" --replace
if [ "$RC" -eq 0 ] && grep -qx 'version=1.2.0-nightly.20260924.1' "$M" && [ ! -e "$F/RichOS.app/sentinel" ]; then
  ok "L4 --replace swaps the app and records the new version"
else bad "L4 --replace swaps the app and records the new version" "exit $RC: $OUT / $(cat "$M")"; fi
[ "$(cat "$F/home/Library/Application Support/com.richos.app/data.txt" 2>/dev/null)" = "conversation" ] \
  && ok "L4 --replace keeps the folder's data" || bad "L4 --replace keeps the folder's data" "data gone"
quit_app "$H"
mkdir -p "$F/home/Applications/RichOS.app/Contents"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.2.0-nightly.20260930.1" "$F/home/Applications/RichOS.app/Contents/Info.plist" >/dev/null
run "$H" a "$ZIPS/v1.zip" --replace
grep -q 'updated itself to 1.2.0-nightly.20260930.1' <<<"$OUT" \
  && ok "L4 --replace says so when the folder's own updater installed a different version" \
  || bad "L4 --replace warns about the updater's copy" "$OUT"
quit_app "$H"
run "$H" status
if grep -q 'unpacked: 1.2.0-nightly.20260921.25' <<<"$OUT" && grep -q 'updated in place to: 1.2.0-nightly.20260930.1' <<<"$OUT" \
   && grep -q 'running: no' <<<"$OUT"; then
  ok "L4 status shows what folder a holds, what it updated itself to, and that it is not running"
else bad "L4 status shows what folder a holds" "$OUT"; fi

# ---------------------------------------------------------------------------------------
# L5/L6 — ZIPs that are not a nightly
# ---------------------------------------------------------------------------------------
H="$(new_home h5)"
run "$H" a "$ZIPS/nope.zip"
expect_refusal "L5 a missing ZIP is refused" "no such ZIP"
[ ! -e "$H/myrichos-nightly-a" ] && ok "L5 ...and nothing was created" || bad "L5 nothing was created" "$(ls -la "$H")"
run "$H" a
expect_refusal "L5 no ZIP at all is refused" "name the nightly ZIP"
run "$H" a "$ZIPS/notzip.zip"
expect_refusal "L6 a file that is not a zip is refused" "not a readable zip"
run "$H" a "$ZIPS/extra.zip"
expect_refusal "L6 a zip holding more than RichOS.app is refused" "holds more than RichOS.app"
run "$H" a "$ZIPS/wrongid.zip"
expect_refusal "L6 an app that is not com.richos.app is refused" "com.example.other"
[ ! -e "$H/myrichos-nightly-a" ] && ok "L6 ...and none of them created the folder" || bad "L6 none created the folder" "$(ls -la "$H")"
run "$H" c "$ZIPS/v1.zip"
expect_refusal "L6 a folder other than a or b is refused" "a or b"
tmp_clean "L6 refusals leave no scratch behind"

# ---------------------------------------------------------------------------------------
# L7 — a folder this launcher did not make
# ---------------------------------------------------------------------------------------
H="$(new_home h7)"; mkdir -p "$H/myrichos-nightly-a"; printf 'his\n' > "$H/myrichos-nightly-a/notes.txt"
run "$H" a "$ZIPS/v1.zip" --replace
expect_refusal "L7 a folder holding files this launcher did not put there is refused, even with --replace" "did not put there"
[ "$(ls -A "$H/myrichos-nightly-a")" = "notes.txt" ] && ok "L7 ...and its contents are untouched" || bad "L7 contents untouched" "$(ls -A "$H/myrichos-nightly-a")"

# ---------------------------------------------------------------------------------------
# L8 — anything under ~/myrichos
# ---------------------------------------------------------------------------------------
H="$(new_home h8)"
cp "$ZIPS/v1.zip" "$H/myrichos/v1.zip"
run "$H" a "$H/myrichos/v1.zip"
expect_refusal "L8 a ZIP under ~/myrichos is refused" "under ~/myrichos"
mkdir -p "$H/myrichos/nightly"; ln -s "$H/myrichos/nightly" "$H/myrichos-nightly-a"
run "$H" a "$ZIPS/v1.zip"
expect_refusal "L8 a folder that is a symlink into ~/myrichos is refused" "under ~/myrichos"
[ -z "$(ls -A "$H/myrichos/nightly")" ] && ok "L8 ...and nothing was written into ~/myrichos" || bad "L8 nothing written into ~/myrichos" "$(ls -A "$H/myrichos/nightly")"
rm "$H/myrichos-nightly-a"
ln -s "$H/myrichos" "$H/linked-daily"
run "$H" a "$H/linked-daily/v1.zip"
expect_refusal "L8 a ZIP reached through a symlink to ~/myrichos is refused" "under ~/myrichos"
printf '# roster\n' > "$H/myrichos/roster.md"
run "$H" b "$ZIPS/v1.zip" --roster "$H/myrichos/roster.md"
expect_refusal "L8 a roster page under ~/myrichos is refused" "under ~/myrichos"
[ "$(cat "$H/myrichos/keep.txt")" = "daily driver data" ] && ok "L8 the daily driver's folder still holds exactly its own file" \
  || bad "L8 the daily driver's folder is untouched" "$(ls -la "$H/myrichos")"

# ---------------------------------------------------------------------------------------
# L9 — folder b and the roster page
# ---------------------------------------------------------------------------------------
H="$(new_home h9)"; F="$H/myrichos-nightly-b"
run "$H" b "$ZIPS/v1.zip"
expect_refusal "L9 folder b without a roster page in the record is refused, naming the page" "wiki/team-roster.md"
[ ! -e "$H.state/open.args" ] && ok "L9 ...and nothing was started" || bad "L9 nothing was started" "$(cat "$H.state/open.args")"
printf '# Team roster\nFrank: devil'"'"'s advocate.\n' > "$H/record/wiki/team-roster.md"
run "$H" b "$ZIPS/v1.zip"
if [ "$RC" -eq 0 ] && cmp -s "$F/memory/wiki/team-roster.md" "$H/record/wiki/team-roster.md" && [ -d "$F/memory/loro" ]; then
  ok "L9 folder b carries the roster page from the record the daily driver reads, in a record-shaped memory folder"
else bad "L9 folder b carries the roster page" "exit $RC: $OUT / $(ls -laR "$F/memory" 2>&1 | head)"; fi
P="$F/home/Library/Application Support/RichOS/loro-root"
[ -L "$P" ] && [ "$(readlink "$P")" = "$F/memory" ] && ok "L9 folder b's memory pointer names its own memory folder, never the record" \
  || bad "L9 folder b's memory pointer names its own memory folder" "$(ls -la "$P" 2>&1)"
[ "$(readlink "$H/Library/Application Support/RichOS/loro-root")" = "$H/record" ] \
  && ok "L9 the daily driver's own pointer is unchanged" || bad "L9 the daily driver's pointer is unchanged" "$(ls -la "$H/Library/Application Support/RichOS")"
quit_app "$H"
printf '# other roster\n' > "$SBOX/other-roster.md"
run "$H" b --again --roster "$SBOX/other-roster.md"
[ "$RC" -eq 0 ] && cmp -s "$F/memory/wiki/team-roster.md" "$SBOX/other-roster.md" \
  && ok "L9 --roster names another page, and --again restarts folder b without a ZIP" || bad "L9 --roster and --again" "exit $RC: $OUT"
quit_app "$H"
run "$H" a "$ZIPS/v1.zip" --roster "$SBOX/other-roster.md"
expect_refusal "L9 --roster on folder a is refused (a newborn carries no memory)" "folder a is a newborn"

# ---------------------------------------------------------------------------------------
# L10/L11 — the sign-in's preconditions
# ---------------------------------------------------------------------------------------
H="$(new_home h10)"
export STUB_STATE="$H.state"; mkdir -p "$STUB_STATE"
OUT="$(CLAUDE_CONFIG_DIR=/somewhere RICHOS_NIGHTLY_TEST_REAL_HOME="$H" RICHOS_NIGHTLY_OPEN="$STUBS/open" \
  RICHOS_NIGHTLY_PS="$STUBS/ps" RICHOS_NIGHTLY_LAUNCHCTL="$STUBS/launchctl" TMPDIR="$SBOX/tmp" \
  bash "$LAUNCH" a "$ZIPS/v1.zip" 2>&1)"; RC=$?
expect_refusal "L10 CLAUDE_CONFIG_DIR in this shell is refused" "CLAUDE_CONFIG_DIR is set in this shell"
STUB_LAUNCHD_CCD=/elsewhere; export STUB_LAUNCHD_CCD
run "$H" a "$ZIPS/v1.zip"
unset STUB_LAUNCHD_CCD
expect_refusal "L10 CLAUDE_CONFIG_DIR in launchd's environment is refused" "launchctl getenv"
for piece in .claude.json Library/Keychains .local/bin/claude .claude; do
  H="$(new_home "h11-$(echo "$piece" | tr '/.' '__')")"
  rm -rf "$H/$piece"
  run "$H" a "$ZIPS/v1.zip"
  expect_refusal "L11 a missing ~/$piece is refused by name" "$H/$piece does not exist"
done

# ---------------------------------------------------------------------------------------
# L12 — --again with nothing there; open refusing; no process appearing
# ---------------------------------------------------------------------------------------
H="$(new_home h12)"
run "$H" a --again
expect_refusal "L12 --again on an empty folder is refused" "holds no nightly yet"
STUB_OPEN_FAIL=1; export STUB_OPEN_FAIL
run "$H" a "$ZIPS/v1.zip"
unset STUB_OPEN_FAIL
expect_refusal "L12 macOS refusing to open the app is reported" "macOS refused to open"
STUB_OPEN_NOPROC=1; export STUB_OPEN_NOPROC
WAIT=1 run "$H" a "$ZIPS/v1.zip"
unset STUB_OPEN_NOPROC
expect_refusal "L12 no app process appearing is reported, with the log to read" "logs/"
tmp_clean "L12 the launcher's scratch is gone after every refusal"

# ---------------------------------------------------------------------------------------
# L13 — run from a shell whose HOME is not the account's (e.g. from inside a nightly)
# ---------------------------------------------------------------------------------------
# No test seam: the real account home is READ (dscl, read-only) and the launcher must stop
# before it touches anything, because HOME is a sandbox path that is nobody's account home.
OUT="$(env -u RICHOS_NIGHTLY_TEST_REAL_HOME HOME="$SBOX/not-a-home" RICHOS_NIGHTLY_OPEN="$STUBS/open" \
  RICHOS_NIGHTLY_PS="$STUBS/ps" RICHOS_NIGHTLY_LAUNCHCTL="$STUBS/launchctl" TMPDIR="$SBOX/tmp" \
  bash "$LAUNCH" a "$ZIPS/v1.zip" 2>&1)"; RC=$?
expect_refusal "L13 a HOME that is not the account's home is refused before anything is written" "Run this from your own shell"

echo ""
echo "nightly-launch.test.sh: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
