#!/usr/bin/env bash
#
# lib/tree-witness.test.sh -- tw_witness_tree tells an unreadable tree from an
# empty one.
#   W1  a readable tree is witnessed, one sorted line per file
#   W2  a readable empty tree is rc 0 with no output
#   W3  a tree that cannot be traversed is rc 1, not a success with no output
#   W4  a missing root is rc 1
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/tree-witness.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tree-witness.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/full/sub" "$T/empty"
printf 'b' > "$T/full/b.txt"; printf 'a' > "$T/full/sub/a.txt"

out="$(tw_witness_tree "$T/full")"; rc=$?
if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" = "b.txt sub/a.txt " ]; then
    ok "W1 a readable tree is witnessed"; else bad "W1 rc=$rc out=$out"; fi

out="$(tw_witness_tree "$T/empty")"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok "W2 an empty tree is rc 0, no output"; else bad "W2 rc=$rc out=$out"; fi

# A stand-in `find` that fails, earlier on PATH than the real one: the traversal
# fails on an existing directory, which is exactly the case a pipeline hides.
mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/find"; chmod +x "$T/bin/find"
out="$(PATH="$T/bin:$PATH" tw_witness_tree "$T/full")"; rc=$?
if [ "$rc" = 1 ] && [ -z "$out" ]; then ok "W3 a failed traversal is rc 1"; else bad "W3 rc=$rc out=$out"; fi

tw_witness_tree "$T/nonexistent" >/dev/null; rc=$?
if [ "$rc" = 1 ]; then ok "W4 a missing root is rc 1"; else bad "W4 rc=$rc"; fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
