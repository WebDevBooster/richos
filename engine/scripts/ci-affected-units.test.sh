#!/usr/bin/env bash
#
# ci-affected-units.test.sh — the diff-to-unit mapping, and the premise it rests on.
#
# WHAT IS PROVEN:
#
#   A1   A changed suite selects itself.
#   A2   A changed file selects the sibling suite named after it.
#   A3   A changed file selects every suite that NAMES its basename. This is the
#        rule that carries the mapping.
#   A4   A change under the sectioned suite selects only the SECTIONS whose own
#        bodies mention the name, not all of them — the whole point of --only.
#   A5   THE PREMISE, RE-DERIVED RATHER THAN TRUSTED: every file under
#        scripts/hooks/ is named by at least one suite. The mapping is only
#        sufficient while that holds, so this case fails the moment it stops
#        holding, in the same run that makes it stop.
#   A6   A changed EXECUTABLE that no suite names is reported, and with --strict
#        it FAILS. An unmapped executable is the dangerous case: the gate would
#        otherwise certify the push against an empty set.
#   A7   Prose and data that no suite names map to nothing WITHOUT failing —
#        that is correct for a docs-only diff, and it is announced rather than
#        left implicit.
#   A8   A path outside engine/ selects nothing here: app/ and tools/ have their
#        own workflows.
#   A9   The output is sorted and deduplicated, so a file named by six suites
#        does not produce six copies of one unit.
#
# A NOTE ON THE FIXTURES FOR A6 AND A7: the invented file names are assembled
# from fragments at runtime rather than written as literals. Written out, they
# would appear in THIS file, `grep -lF` would find this suite naming them, and
# the "unmapped" cases would map — which is what happened on the first attempt,
# and is a fair demonstration that rule 3 works.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AFF="$SCRIPT_DIR/ci-affected-units.sh"
UNITS="$SCRIPT_DIR/ci-units.sh"
SECTIONED="scripts/hooks/contract-integrity.test.sh"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-affected-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$AFF" ] || { echo "FATAL: missing $AFF" >&2; exit 1; }

echo "=== ci-affected-units tests ==="

aff() { bash "$AFF" "$@" 2>"$SANDBOX/err"; }

# --- A1 --------------------------------------------------------------------
OUT="$(aff --paths engine/scripts/lib/leak-canary.test.sh)"
if printf '%s\n' "$OUT" | grep -qxF 'scripts/lib/leak-canary.test.sh'; then
    ok "A1   a changed suite selects itself"
else
    bad "A1   got: $OUT"
fi

# --- A2 --------------------------------------------------------------------
OUT="$(aff --paths engine/scripts/lib/leak-canary.sh)"
if printf '%s\n' "$OUT" | grep -qxF 'scripts/lib/leak-canary.test.sh'; then
    ok "A2   a changed file selects the sibling suite named after it"
else
    bad "A2   got: $OUT"
fi

# --- A3 --------------------------------------------------------------------
# run-all-tests.sh is named by run-all-tests.test.sh and by others; the point is
# that the mapping finds a suite that merely MENTIONS the basename.
OUT="$(aff --paths engine/scripts/run-all-tests.sh)"
if printf '%s\n' "$OUT" | grep -qxF 'scripts/run-all-tests.test.sh'; then
    ok "A3   a changed file selects suites that name its basename"
else
    bad "A3   got: $OUT"
fi

# --- A4 --------------------------------------------------------------------
# guard-model-ceiling.sh is asserted by the sectioned suite's MC and MC6
# sections. The mapping must select those and not all 24.
if [ -f "$ENGINE_ROOT/scripts/hooks/guard-model-ceiling.sh" ]; then
    OUT="$(aff --paths engine/scripts/hooks/guard-model-ceiling.sh)"
    N_SEC_SELECTED="$(printf '%s\n' "$OUT" | grep -c "^$SECTIONED:" || true)"
    N_SEC_TOTAL="$(bash "$UNITS" units | cut -f1 | grep -c "^$SECTIONED:" || true)"
    if [ "${N_SEC_SELECTED:-0}" -gt 0 ] && [ "${N_SEC_SELECTED:-0}" -lt "${N_SEC_TOTAL:-0}" ]; then
        ok "A4   one guard selects $N_SEC_SELECTED of $N_SEC_TOTAL sections, not all of them"
    else
        bad "A4   selected $N_SEC_SELECTED of $N_SEC_TOTAL sections — a per-guard change should not cost the whole suite"
    fi
else
    bad "A4   scripts/hooks/guard-model-ceiling.sh is missing, so section narrowing cannot be shown"
fi

# --- A5: THE PREMISE ------------------------------------------------------
# The mapping is sufficient only while every hook is named by some suite. That
# was measured once, on 2026-09-10, at 96 of 96. Measuring it once is not the
# same as it staying true, so it is re-derived here on every run.
UNNAMED=0
UNNAMED_NAMES=""
SUITE_LIST="$SANDBOX/suites.txt"
bash "$UNITS" suites > "$SUITE_LIST"
while IFS= read -r h; do
    [ -n "$h" ] || continue
    b="$(basename "$h")"
    hit=0
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        if grep -qF -- "$b" "$ENGINE_ROOT/$s" 2>/dev/null; then hit=1; break; fi
    done < "$SUITE_LIST"
    if [ "$hit" -eq 0 ]; then
        UNNAMED=$((UNNAMED + 1))
        UNNAMED_NAMES="$UNNAMED_NAMES $b"
    fi
done < <(find "$ENGINE_ROOT/scripts/hooks" -maxdepth 1 -type f -name '*.sh' ! -name '*.test.sh' 2>/dev/null | LC_ALL=C sort)
N_HOOKS="$(find "$ENGINE_ROOT/scripts/hooks" -maxdepth 1 -type f -name '*.sh' ! -name '*.test.sh' 2>/dev/null | grep -c . || true)"
if [ "$UNNAMED" -eq 0 ] && [ "${N_HOOKS:-0}" -gt 0 ]; then
    ok "A5   all $N_HOOKS hook(s) are named by at least one suite — the premise the diff mapping rests on still holds"
else
    bad "A5   $UNNAMED of $N_HOOKS hook(s) are named by NO suite:$UNNAMED_NAMES"
    printf '          A diff touching one of those selects nothing, so the required gate would certify\n'
    printf '          the push against an empty set. Give it a suite, or make a suite name it.\n'
fi

# --- A6: an unmapped executable ------------------------------------------
# A path that does not exist and that nothing names: `.sh` is enough to classify
# it as executable machinery, so this case needs no file on disk.
#
# THE NAMES ARE ASSEMBLED AT RUNTIME, and that is not a flourish. The first
# version of these two cases spelled the invented file names out as literals,
# and both cases failed — because THIS FILE then contained those literals, so
# `grep -lF <basename>` correctly found a suite naming them and the paths were
# not unmapped at all. The mapping worked; the fixture was self-referential. So
# the basenames below exist only as concatenations and appear in no file.
GHOST_SH="engine/scripts/hooks/zz$(printf '%s' '-nobody-names-')probe.sh"
GHOST_MD="engine/docs/zz$(printf '%s' '-untested-')note.md"

OUT="$(aff --paths "$GHOST_SH" || true)"
if grep -q 'named by NO suite' "$SANDBOX/err"; then
    ok "A6a  an unmapped executable is reported by name"
else
    bad "A6a  an unmapped executable was not reported"; sed 's/^/          /' "$SANDBOX/err"
fi
bash "$AFF" --paths "$GHOST_SH" --strict >/dev/null 2>&1
if [ "$?" -eq 1 ]; then
    ok "A6b  --strict FAILS on an unmapped executable rather than certifying the push against nothing"
else
    bad "A6b  --strict did not fail on an unmapped executable"
fi

# --- A7: prose maps to nothing, and says so ------------------------------
OUT="$(aff --paths "$GHOST_MD" --strict || true)"
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$(printf '%s' "$OUT" | grep -v '^$' || true)" ] \
   && grep -q 'NOTHING TO RUN' "$SANDBOX/err"; then
    ok "A7   prose maps to nothing, exits 0, and announces it rather than leaving it implicit"
else
    bad "A7   rc=$RC out='$OUT'"; sed 's/^/          /' "$SANDBOX/err"
fi

# --- A8: outside the engine ----------------------------------------------
OUT="$(aff --paths app/src/main.rs,tools/thing.py || true)"
if [ -z "$(printf '%s' "$OUT" | grep -v '^$' || true)" ]; then
    ok "A8   paths outside engine/ select nothing — app/ and tools/ have their own workflows"
else
    bad "A8   got: $OUT"
fi

# --- A9: sorted and unique ----------------------------------------------
OUT="$(aff --paths engine/scripts/lib/leak-canary.sh,engine/scripts/lib/leak-canary.test.sh)"
DUPES="$(printf '%s\n' "$OUT" | grep -v '^$' | LC_ALL=C sort | uniq -d | grep -c . || true)"
SORTED="$(printf '%s\n' "$OUT" | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')"
ASIS="$(printf '%s\n' "$OUT" | grep -v '^$' | tr '\n' ' ')"
if [ "${DUPES:-0}" -eq 0 ] && [ "$SORTED" = "$ASIS" ]; then
    ok "A9   the unit list is sorted and deduplicated"
else
    bad "A9   dupes=$DUPES sorted='$SORTED' as-is='$ASIS'"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== ci-affected-units tests: all $PASS passed ==="
    exit 0
fi
echo "=== ci-affected-units tests: $PASS passed, $FAIL FAILED ===" >&2
exit 1
