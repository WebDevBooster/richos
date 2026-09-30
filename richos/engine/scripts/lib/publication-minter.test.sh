#!/usr/bin/env bash
#
# lib/publication-minter.test.sh -- the private-file minter prints a declaration
# its own reader accepts.
#   M1  the minted entry for a file whose name has a space loads (rc 0)
#   M2  the scanner's parser reads the name back with its space
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PB_PY="$HERE/publication-boundary.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pub-minter.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT

# load_rc <declaration-body> -> prints the rc of pb_load_declaration on a
# repository whose declaration file holds that body.
load_rc() {
    local d="$T/repo.$RANDOM"
    mkdir -p "$d"
    git init -q "$d" 2>/dev/null
    printf '%s\n' "$1" > "$d/.publication-boundary"
    ( . "$HERE/publication-boundary.sh" >/dev/null 2>&1
      pb_load_declaration "$d" >/dev/null 2>&1
      echo "$?" )
}

printf 'one two three four five six seven eight nine ten eleven twelve\n' > "$T/meeting notes.txt"
entry="$(python3 "$PB_PY" --digest "$T/meeting notes.txt" | grep '^PRIVATE_FILES=')"
rc="$(load_rc "$entry")"
if [ "$rc" = 0 ]; then ok "M1 the minted entry for a spaced name loads"; else bad "M1 rc=$rc for: $entry"; fi

got="$(python3 - "$PB_PY" "$entry" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pb", sys.argv[1])
pb = importlib.util.module_from_spec(spec); spec.loader.exec_module(pb)
value = sys.argv[2].split("=", 1)[1].strip('"')
print(pb.parse_private_files(value.split())[0][1])
PY
)"
if [ "$got" = "meeting notes.txt" ]; then ok "M2 the parser reads the spaced name back"; else bad "M2 parsed name: '$got'"; fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
