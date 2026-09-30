#!/usr/bin/env bash
#
# lib/publication-declaration.test.sh -- the publication declaration reader
# refuses an empty numeric setting instead of accepting it.
#   D1  an empty MIN_SPEECH_LINES is BROKEN (rc 2), even when the other three
#       numeric settings hold digits
#   D2  the same for MIN_QUOTE_WORDS, CORPUS_MAX_FILES and CORPUS_MAX_BYTES
#   D3  (control) a declaration with all four numeric settings present loads
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pub-decl.XXXXXX")" && pwd -P)"
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

FULL='PRIVATE_RECORD=private
MIN_SPEECH_LINES=8
MIN_QUOTE_WORDS=10
CORPUS_MAX_FILES=4000
CORPUS_MAX_BYTES=67108864'

rc="$(load_rc "$FULL")"
if [ "$rc" = 0 ]; then ok "D3 a complete declaration loads"; else bad "D3 rc=$rc (the harness cannot load a declaration)"; fi

for key in MIN_SPEECH_LINES MIN_QUOTE_WORDS CORPUS_MAX_FILES CORPUS_MAX_BYTES; do
    body="$(printf '%s\n' "$FULL" | sed "s/^$key=.*/$key=/")"
    rc="$(load_rc "$body")"
    if [ "$rc" = 2 ]; then ok "D1/D2 empty $key is BROKEN"; else bad "D1/D2 empty $key gave rc=$rc, want 2"; fi
done

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
