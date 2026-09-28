#!/usr/bin/env bash
# import-setup.test.sh: the one-time import, against a fixture home that stands in for the
# owner's setup. Everything lives under a mktemp sandbox: a fake home with a RichOS install's
# data folder, a fake record repository, a fake Claude Code memory index and a stub
# `launchctl`. The owner's real home, ~/.claude and installed app are never read or written,
# and nothing is launched.
#
#   I1  plan only: every item is listed, nothing is written
#   I2  --go: his name and company arrive in config.json, every other key is kept, the memory
#       pointer arrives, a backup with a manifest is taken, and the result verifies
#   I3  --go again: nothing to change, NOTHING written (tree identical, one backup only)
#   I4  the backup restores the settings file byte for byte
#   I5  refuses to write while the install's app is running (its own launch record, live pid)
#   I6  a launch record left by a run that died does not block
#   I7  a usable corpus at candidate 3 outranks the record: refused; an unusable one is passed over
#   I8  a loro-root that points somewhere else is his, not the import's: refused
#   I9  no roster page in the record: refused
#   I10 launchd handing apps LORO_ROOT: refused
#   I11 an unreadable settings file is refused and left byte for byte
#   I12 no stored name and none given: refused
#   I13 the memory index is found from the operator declaration's folder, and its absence refuses
#   I14 with the pointer already in place (his Mac today) only the name is written
#
# run-tests: inputs richos/app/scripts/import-setup.test.sh richos/app/scripts/import-setup.py
# run-tests: covers richos/app/scripts/import-setup.py
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPORT="$DIR/import-setup.py"
FAILS=0; PASSES=0
ok()  { PASSES=$((PASSES + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

SBOX="$(mktemp -d "${TMPDIR:-/tmp}/import-setup-test.XXXXXX")" || exit 2
SBOX="$(cd "$SBOX" && pwd -P)"
trap 'rm -rf "$SBOX"' EXIT

# A stub launchctl: `getenv NAME` prints the value from $SBOX/launchd/NAME when that file exists.
mkdir -p "$SBOX/stubs" "$SBOX/launchd"
cat > "$SBOX/stubs/launchctl" <<EOF
#!/bin/bash
[ "\$1" = "getenv" ] && [ -f "$SBOX/launchd/\$2" ] && cat "$SBOX/launchd/\$2"
exit 0
EOF
chmod +x "$SBOX/stubs/launchctl"
export RICHOS_IMPORT_LAUNCHCTL="$SBOX/stubs/launchctl"

# fixture <name>: a home that looks like the owner's before the import.
#   - an install data folder with a config.json holding preferences and a key this import
#     does not know, and a launch record from a clean quit
#   - a record repository with wiki/, loro/ and the roster page
#   - a team folder and its Claude Code memory index
fixture() {
  local h="$SBOX/$1"
  local data="$h/Library/Application Support/com.richos.app"
  mkdir -p "$data" "$h/Library/Application Support/RichOS" "$h/record/wiki" "$h/record/loro" "$h/team"
  cat > "$data/config.json" <<'JSON'
{
  "schema_version": 1,
  "theme": "dark",
  "font_scale": 112,
  "entity": "team",
  "a_key_from_a_newer_build": {"kept": true}
}
JSON
  printf '{"schema_version":1,"installed_at":1,"starts":[1],"recent_splashes":[],"rewards_fired":{},"open_run":null}\n' > "$data/launches.json"
  printf '# Team roster\n\nFrank: devil'"'"'s advocate.\n' > "$h/record/wiki/team-roster.md"
  local enc; enc="$(printf '%s' "$h/team" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$h/.claude/projects/$enc/memory"
  printf -- '- [a memory](a.md)\n' > "$h/.claude/projects/$enc/memory/MEMORY.md"
  echo "$h"
}

# snapshot <home>: every path under it with its kind, link target, mtime and content digest.
snapshot() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
for d, dirs, files in os.walk(root):
    dirs.sort()
    for n in sorted(dirs + files):
        p = os.path.join(d, n)
        st = os.lstat(p)
        if os.path.islink(p):
            print(p, "link", os.readlink(p), st.st_mtime_ns)
        elif os.path.isdir(p):
            print(p, "dir", st.st_mtime_ns)
        else:
            print(p, "file", st.st_mtime_ns, hashlib.sha256(open(p, "rb").read()).hexdigest())
PY
}

run() { python3 "$IMPORT" "$@" > "$SBOX/out" 2>&1; echo $?; }
cfg() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$1/Library/Application Support/com.richos.app/config.json" "$2"; }
DATA_OF() { printf '%s' "$1/Library/Application Support/com.richos.app"; }
LINK_OF() { printf '%s' "$1/Library/Application Support/RichOS/loro-root"; }

echo "=== import-setup ==="

# --- I1 -------------------------------------------------------------------------------
H="$(fixture i1)"
before="$(snapshot "$H")"
rc="$(run --home "$H" --record "$H/record" --name "Pat Example" --company "Example Co" --team-folder "$H/team")"
after="$(snapshot "$H")"
if [ "$rc" = 0 ] && grep -q "PLAN ONLY: 3 change(s)" "$SBOX/out" && [ "$before" = "$after" ] \
   && grep -q "His name .*will write" "$SBOX/out" && grep -q "Memory pointer .*will write" "$SBOX/out" \
   && grep -q "Roster page in the record *ok" "$SBOX/out" && grep -q "His memory index, read in place *ok" "$SBOX/out"; then
  ok "I1 plan only lists every item and writes nothing"
else bad "I1 plan only" "rc=$rc; $(cat "$SBOX/out")"; fi

# --- I2 -------------------------------------------------------------------------------
cp "$(DATA_OF "$H")/config.json" "$SBOX/i1-config-original.json"
rc="$(run --home "$H" --record "$H/record" --name "Pat Example" --company "Example Co" --team-folder "$H/team" --go)"
link="$(readlink "$(LINK_OF "$H")" 2>/dev/null)"
backups=( "$(DATA_OF "$H")"/import-backups/* )
if [ "$rc" = 0 ] && grep -q "IMPORT DONE AND VERIFIED" "$SBOX/out" \
   && [ "$(cfg "$H" user_name)" = "Pat Example" ] && [ "$(cfg "$H" company_name)" = "Example Co" ] \
   && [ "$(cfg "$H" theme)" = "dark" ] && [ "$(cfg "$H" font_scale)" = "112" ] && [ "$(cfg "$H" entity)" = "team" ] \
   && [ "$(cfg "$H" a_key_from_a_newer_build)" = "{'kept': True}" ] \
   && [ "$link" = "$H/record" ] && [ "${#backups[@]}" = 1 ] && [ -f "${backups[0]}/manifest.json" ] \
   && cmp -s "${backups[0]}/config.json" "$SBOX/i1-config-original.json"; then
  ok "I2 --go brings name, company and memory pointer; keeps every other key; backs up first"
else bad "I2 --go" "rc=$rc link=$link backups=${#backups[@]}; $(cat "$SBOX/out")"; fi

# --- I3 -------------------------------------------------------------------------------
before="$(snapshot "$H")"
rc="$(run --home "$H" --record "$H/record" --name "Pat Example" --company "Example Co" --team-folder "$H/team" --go)"
after="$(snapshot "$H")"
backups=( "$(DATA_OF "$H")"/import-backups/* )
if [ "$rc" = 0 ] && grep -q "Nothing to change" "$SBOX/out" && [ "$before" = "$after" ] && [ "${#backups[@]}" = 1 ]; then
  ok "I3 a second run duplicates nothing and writes nothing"
else bad "I3 second run" "rc=$rc backups=${#backups[@]}; $(diff <(echo "$before") <(echo "$after")); $(cat "$SBOX/out")"; fi

# --- I4 -------------------------------------------------------------------------------
cp "${backups[0]}/config.json" "$(DATA_OF "$H")/config.json"
if cmp -s "$(DATA_OF "$H")/config.json" "$SBOX/i1-config-original.json" \
   && python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert [c["path"].endswith(("config.json","loro-root")) for c in m["changes"]] == [True, True]; assert all(c.get("undo") for c in m["changes"])' "${backups[0]}/manifest.json"; then
  ok "I4 the backup restores the settings file byte for byte; the manifest names an undo for each change"
else bad "I4 restore" "$(cat "${backups[0]}/manifest.json")"; fi

# --- I5 -------------------------------------------------------------------------------
H="$(fixture i5)"
printf '{"schema_version":1,"installed_at":1,"starts":[1],"open_run":{"started_at":1,"token":"%s"}}\n' "$$" > "$(DATA_OF "$H")/launches.json"
before="$(snapshot "$H")"
rc="$(run --home "$H" --record "$H/record" --name "Pat Example" --go)"
after="$(snapshot "$H")"
if [ "$rc" = 1 ] && grep -q "REFUSED: the app in this install is running, as process $$" "$SBOX/out" && [ "$before" = "$after" ]; then
  ok "I5 refuses while the app is running (its own launch record, a live pid) and writes nothing"
else bad "I5 running app" "rc=$rc; $(cat "$SBOX/out")"; fi

# --- I6 -------------------------------------------------------------------------------
H="$(fixture i6)"
/usr/bin/true & dead=$!; wait "$dead"
printf '{"schema_version":1,"installed_at":1,"starts":[1],"open_run":{"started_at":1,"token":"%s"}}\n' "$dead" > "$(DATA_OF "$H")/launches.json"
rc="$(run --home "$H" --record "$H/record" --name "Pat Example" --go)"
if [ "$rc" = 0 ] && grep -q "is gone; that run did not quit cleanly" "$SBOX/out" && [ "$(cfg "$H" user_name)" = "Pat Example" ]; then
  ok "I6 a launch record left by a run that died does not block"
else bad "I6 dead run" "rc=$rc; $(cat "$SBOX/out")"; fi

# --- I7 -------------------------------------------------------------------------------
H="$(fixture i7)"
mkdir -p "$H/Library/Application Support/RichOS/corpus"
rc="$(run --home "$H" --record "$H/record" --name "Pat Example" --go)"
passed_over=0
if [ "$rc" = 0 ] && grep -q "present but not a corpus, so passed over" "$SBOX/out"; then passed_over=1; fi
H="$(fixture i7b)"
mkdir -p "$H/Library/Application Support/RichOS/corpus/ceo" "$H/Library/Application Support/RichOS/corpus/companies"
before="$(snapshot "$H")"
rc="$(run --home "$H" --record "$H/record" --name "Pat Example" --go)"
after="$(snapshot "$H")"
if [ "$passed_over" = 1 ] && [ "$rc" = 1 ] && grep -q "is a usable corpus and is read BEFORE the record" "$SBOX/out" && [ "$before" = "$after" ]; then
  ok "I7 a usable candidate 3 refuses; an unusable one is passed over, as the resolver does"
else bad "I7 candidate 3" "passed_over=$passed_over rc=$rc; $(cat "$SBOX/out")"; fi

# --- I8 -------------------------------------------------------------------------------
H="$(fixture i8)"
mkdir -p "$H/other/wiki" "$H/other/loro"
ln -s "$H/other" "$(LINK_OF "$H")"
before="$(snapshot "$H")"
rc="$(run --home "$H" --record "$H/record" --name "Pat Example" --go)"
after="$(snapshot "$H")"
if [ "$rc" = 1 ] && grep -q "is his to move, not this import's" "$SBOX/out" && [ "$before" = "$after" ]; then
  ok "I8 a loro-root pointing elsewhere is refused and left alone"
else bad "I8 other pointer" "rc=$rc; $(cat "$SBOX/out")"; fi

# --- I9 -------------------------------------------------------------------------------
H="$(fixture i9)"
rm "$H/record/wiki/team-roster.md"
rc="$(run --home "$H" --record "$H/record" --name "Pat Example" --go)"
if [ "$rc" = 1 ] && grep -q "Roster page in the record *FAILED" "$SBOX/out" && [ ! -L "$(LINK_OF "$H")" ]; then
  ok "I9 no roster page: refused, nothing written"
else bad "I9 roster" "rc=$rc; $(cat "$SBOX/out")"; fi

# --- I10 ------------------------------------------------------------------------------
H="$(fixture i10)"
echo "/somewhere" > "$SBOX/launchd/LORO_ROOT"
rc="$(run --home "$H" --record "$H/record" --name "Pat Example" --go)"
rm "$SBOX/launchd/LORO_ROOT"
if [ "$rc" = 1 ] && grep -q "launchd hands every double-clicked app LORO_ROOT" "$SBOX/out" && [ ! -L "$(LINK_OF "$H")" ]; then
  ok "I10 launchd handing apps LORO_ROOT: refused"
else bad "I10 launchd" "rc=$rc; $(cat "$SBOX/out")"; fi

# --- I11 ------------------------------------------------------------------------------
H="$(fixture i11)"
printf '{"user_name": "Pat Ex' > "$(DATA_OF "$H")/config.json"
cp "$(DATA_OF "$H")/config.json" "$SBOX/i11.json"
rc="$(run --home "$H" --record "$H/record" --name "Pat Example" --go)"
if [ "$rc" = 1 ] && grep -q "is not readable JSON (line 1" "$SBOX/out" && ! grep -q "Pat Ex\"" "$SBOX/out" \
   && cmp -s "$(DATA_OF "$H")/config.json" "$SBOX/i11.json"; then
  ok "I11 an unreadable settings file is refused, its values not quoted, and left byte for byte"
else bad "I11 unreadable config" "rc=$rc; $(cat "$SBOX/out")"; fi

# --- I12 ------------------------------------------------------------------------------
H="$(fixture i12)"
rc="$(run --home "$H" --record "$H/record" --go)"
if [ "$rc" = 1 ] && grep -q "no name is stored and none was given; pass --name" "$SBOX/out"; then
  ok "I12 no stored name and none given: refused"
else bad "I12 no name" "rc=$rc; $(cat "$SBOX/out")"; fi

# --- I13 ------------------------------------------------------------------------------
H="$(fixture i13)"
printf '{"schema": 1, "entity_root": "%s"}\n' "$H/team" > "$(DATA_OF "$H")/operator.json"
rc1="$(run --home "$H" --record "$H/record" --name "Pat Example")"
out1="$(cat "$SBOX/out")"
rm -r "$H/.claude/projects"
rc2="$(run --home "$H" --record "$H/record" --name "Pat Example" --go)"
if [ "$rc1" = 0 ] && grep -q "His team in this install *ok" <<<"$out1" && grep -q "His memory index, read in place *ok" <<<"$out1" \
   && [ "$rc2" = 1 ] && grep -q "His memory index, read in place *FAILED" "$SBOX/out" && [ "$(cfg "$H" user_name)" = "None" ]; then
  ok "I13 the memory index is found from the operator declaration; its absence refuses"
else bad "I13 memory index" "rc1=$rc1 rc2=$rc2; $out1; $(cat "$SBOX/out")"; fi

# --- I14 ------------------------------------------------------------------------------
H="$(fixture i14)"
ln -s "$H/record" "$(LINK_OF "$H")"
rc="$(run --home "$H" --name "Pat Example" --go)"
if [ "$rc" = 0 ] && grep -q "Memory pointer *already there" "$SBOX/out" && [ "$(cfg "$H" user_name)" = "Pat Example" ] \
   && python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert len(m["changes"]) == 1' "$(DATA_OF "$H")"/import-backups/*/manifest.json; then
  ok "I14 with the pointer already in place, only the name is written (no --record needed)"
else bad "I14 pointer present" "rc=$rc; $(cat "$SBOX/out")"; fi

echo "import-setup: $PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
