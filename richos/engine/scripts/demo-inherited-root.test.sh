#!/usr/bin/env bash
#
# demo-inherited-root.test.sh -- the demo judges its own sample, whatever the
# caller's environment says.
#   R1  with RICHOS_ENTITY_ROOT inherited and pointing at a path that is not an
#       adopted engine root (the shared resolver refuses such an override rather
#       than falling through), the demo still runs to the end and exits 0
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/demo-root.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/not-an-entity"

out="$(RICHOS_ENTITY_ROOT="$T/not-an-entity" TMPDIR="$T" bash "$HERE/demo.sh" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
    ok "R1 the demo ignores an inherited RICHOS_ENTITY_ROOT"
else
    bad "R1 the demo exited $rc with an inherited RICHOS_ENTITY_ROOT" "$(printf '%s' "$out" | tail -5 | tr '\n' ' ')"
fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
