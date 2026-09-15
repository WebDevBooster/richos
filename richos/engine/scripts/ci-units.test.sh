#!/usr/bin/env bash
#
# ci-units.test.sh — the unit inventory must equal what run-all-tests.sh runs.
#
# WHAT IS PROVEN HERE, and why each case rather than a claim in a comment:
#
#   U1   The suite set this planner discovers is BYTE-IDENTICAL to
#        `run-all-tests.sh --list`. This is the load-bearing case. The two
#        readings of the inventory are deliberately separate implementations —
#        a shared helper would make them agree by construction, and then
#        nothing would notice if the sharded reading started missing a
#        directory. They agree by EXECUTION or this suite is red.
#   U2   Every discovered suite becomes exactly one unit, except the sectioned
#        one, which becomes one unit per section marker it carries.
#   U3   The section ids come from the sectioned suite's OWN markers, matching
#        its `--list`, so a section added there needs no edit here.
#   U4   Every unit appears in EXACTLY ONE shard, and every unit appears. This
#        is the property the whole sharded pass rests on.
#   U5   The plan is DETERMINISTIC: the same tree gives the same assignment
#        twice, so two runs can be diffed line by line.
#   U6   Packing is BALANCED by the measured weights, not by count — the
#        heaviest unit lands in a shard whose total is not the largest.
#   U7   A weight file entry is honored, and an unknown unit gets the default
#        rather than zero. A unit weighted zero would let the packer stack an
#        unbounded number of unmeasured suites into one shard.
#   U8   NO SILENT EMPTINESS: a tree with no suites exits 2, and a sectioned
#        suite with no readable markers exits 2 rather than degrading to one
#        whole-suite unit.
#   U9   `cmd` invokes a suite through `bash`, never by path. Several suites in
#        this tree are committed mode 644, so executing them by path exits 126
#        — the reason nobody noticed is that run-all-tests.sh also uses bash.
#   U10  The matrix is valid JSON whose length equals the declared shard count.
#   U12  A RESTRICTED inventory (--units-file) is packed by the same planner:
#        the restriction is a partition of exactly the named set, and the ids
#        outside it do not appear.
#   U13  An id in the restriction file that is not a unit is FATAL. A
#        restriction that silently dropped one would plan over less than it was
#        asked for and still exit 0, which is the failure this whole file is
#        about, wearing a diff filter.
#   U11  The matrix contains only shards that HAVE units. Asking for more
#        shards than there are units must not declare jobs with nothing in
#        them: a shard that verifies nothing must never exit 0, so such a job
#        would fail the run for having been asked for.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNITS="$SCRIPT_DIR/ci-units.sh"
RUNNER="$SCRIPT_DIR/run-all-tests.sh"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-units-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$UNITS" ] || { echo "FATAL: missing $UNITS" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

echo "=== ci-units tests ==="

# --- U1: the two readings of the inventory agree ---------------------------
if [ -f "$RUNNER" ]; then
    A="$SANDBOX/from-planner.txt"; B="$SANDBOX/from-runner.txt"
    bash "$UNITS" suites | LC_ALL=C sort > "$A"
    bash "$RUNNER" --list 2>/dev/null | LC_ALL=C sort > "$B"
    if [ -s "$A" ] && [ -s "$B" ] && diff -q "$A" "$B" >/dev/null 2>&1; then
        ok "U1   the planner's suite set is identical to run-all-tests.sh --list ($(grep -c . "$A") suites)"
    else
        bad "U1   THE TWO READINGS OF THE INVENTORY DISAGREE. A suite in one and not the other is a suite the sharded pass either never runs or runs twice:"
        diff "$B" "$A" | sed 's/^/          /' | head -20
    fi
else
    bad "U1   run-all-tests.sh is missing, so the inventory cannot be cross-checked against it"
fi

# --- U2 / U3: one unit per suite, one per section ---------------------------
SECTIONED="scripts/hooks/contract-integrity.test.sh"
N_SUITES="$(bash "$UNITS" suites | grep -c . || true)"
N_UNITS="$(bash "$UNITS" units | grep -c . || true)"
if [ -f "$ENGINE_ROOT/$SECTIONED" ]; then
    N_SECT="$(bash "$ENGINE_ROOT/$SECTIONED" --list 2>/dev/null | grep -vc '^    ' || true)"
    WANT=$(( N_SUITES - 1 + N_SECT ))
    if [ "$N_UNITS" -eq "$WANT" ]; then
        ok "U2   $N_SUITES suite(s) - 1 sectioned + $N_SECT section(s) = $N_UNITS unit(s)"
    else
        bad "U2   expected $WANT units ($N_SUITES suites, $N_SECT sections), got $N_UNITS"
    fi
    FROM_UNITS="$(bash "$UNITS" units | cut -f1 | grep "^$SECTIONED:" | sed "s|^$SECTIONED:||" | LC_ALL=C sort | tr '\n' ' ')"
    FROM_SUITE="$(bash "$ENGINE_ROOT/$SECTIONED" --list 2>/dev/null | grep -v '^    ' | LC_ALL=C sort | tr '\n' ' ')"
    if [ "$FROM_UNITS" = "$FROM_SUITE" ]; then
        ok "U3   the section ids come from the suite's own markers, not from a list here"
    else
        bad "U3   section ids differ: planner='$FROM_UNITS' suite='$FROM_SUITE'"
    fi
else
    bad "U2   the sectioned suite $SECTIONED is missing"
    bad "U3   the sectioned suite $SECTIONED is missing"
fi

# --- U4 / U5: the shard plan covers everything, exactly once, repeatably ----
for N in 1 3 12 40; do
    bash "$UNITS" shards "$N" | cut -f2 | LC_ALL=C sort > "$SANDBOX/planned.$N"
    bash "$UNITS" units | cut -f1 | LC_ALL=C sort > "$SANDBOX/all.$N"
    DUPES="$(uniq -d < "$SANDBOX/planned.$N" | grep -c . || true)"
    if diff -q "$SANDBOX/all.$N" "$SANDBOX/planned.$N" >/dev/null 2>&1 && [ "${DUPES:-0}" -eq 0 ]; then
        ok "U4   $N shard(s): every unit assigned exactly once ($(grep -c . "$SANDBOX/planned.$N"))"
    else
        bad "U4   $N shard(s): the plan is not a partition of the inventory (dupes=$DUPES)"
        diff "$SANDBOX/all.$N" "$SANDBOX/planned.$N" | sed 's/^/          /' | head -10
    fi
done
bash "$UNITS" shards 12 > "$SANDBOX/plan.a"
bash "$UNITS" shards 12 > "$SANDBOX/plan.b"
if diff -q "$SANDBOX/plan.a" "$SANDBOX/plan.b" >/dev/null 2>&1; then
    ok "U5   the plan is deterministic across invocations"
else
    bad "U5   two invocations produced different plans — two runs of the workflow cannot be compared"
fi

# --- a synthetic engine, so the remaining cases do not depend on this tree --
mk_engine() { # <root> — the minimum ci-units.sh recognizes
    local r="$1"
    mkdir -p "$r/scripts/lib" "$r/scripts/hooks"
    printf '1.0.0-test\n' > "$r/VERSION"
    cp "$UNITS" "$r/scripts/ci-units.sh"
    chmod +x "$r/scripts/ci-units.sh"
}
mk_suite() { printf '#!/usr/bin/env bash\nexit %s\n' "${2:-0}" > "$1"; chmod +x "$1"; }

# --- U6: balance follows the weights, not the count ------------------------
E="$SANDBOX/e-weights"; mk_engine "$E"
for i in 1 2 3 4 5 6; do mk_suite "$E/scripts/lib/s$i.test.sh"; done
{
    printf 'scripts/lib/s1.test.sh\t600\n'
    printf 'scripts/lib/s2.test.sh\t100\n'
    printf 'scripts/lib/s3.test.sh\t100\n'
    printf 'scripts/lib/s4.test.sh\t100\n'
    printf 'scripts/lib/s5.test.sh\t100\n'
    printf 'scripts/lib/s6.test.sh\t100\n'
} > "$E/scripts/lib/ci-unit-weights.tsv"
HEAVY_SHARD="$(bash "$E/scripts/ci-units.sh" shards 2 | awk -F'\t' '$2 == "scripts/lib/s1.test.sh" { print $1 }')"
OTHER_COUNT="$(bash "$E/scripts/ci-units.sh" shards 2 | awk -F'\t' -v s="$HEAVY_SHARD" '$1 == s' | grep -c . || true)"
if [ "${OTHER_COUNT:-0}" -eq 1 ]; then
    ok "U6   the 600 s unit gets a shard to itself while five 100 s units share the other — balanced by weight, not by count"
else
    bad "U6   the heavy unit shares its shard with $((OTHER_COUNT - 1)) other(s); packing is not weight-driven"
fi

# --- U7: weights honored, unknown units get the default not zero -----------
W1="$(bash "$E/scripts/ci-units.sh" units | awk -F'\t' '$1 == "scripts/lib/s1.test.sh" { print $4 }')"
mk_suite "$E/scripts/lib/brandnew.test.sh"
WN="$(bash "$E/scripts/ci-units.sh" units | awk -F'\t' '$1 == "scripts/lib/brandnew.test.sh" { print $4 }')"
if [ "$W1" = "600" ] && [ -n "$WN" ] && [ "$WN" != "0" ]; then
    ok "U7   a measured weight is honored (600) and an unmeasured unit costs the default ($WN), never zero"
else
    bad "U7   measured=$W1 unmeasured=$WN — an unmeasured unit weighted 0 lets the packer stack them without limit"
fi

# --- U8: no silent emptiness ----------------------------------------------
E2="$SANDBOX/e-empty"; mk_engine "$E2"
bash "$E2/scripts/ci-units.sh" units >/dev/null 2>&1
if [ "$?" -eq 2 ]; then
    ok "U8a  a tree with no suites exits 2 rather than emitting an empty inventory"
else
    bad "U8a  an engine with no suites did not exit 2 — a shard plan over zero units is green forever"
fi
E3="$SANDBOX/e-nomarkers"; mk_engine "$E3"
mk_suite "$E3/scripts/lib/ordinary.test.sh"
# the sectioned suite, present but carrying no `if _section` markers
printf '#!/usr/bin/env bash\necho no markers here\nexit 0\n' > "$E3/scripts/hooks/contract-integrity.test.sh"
bash "$E3/scripts/ci-units.sh" units >"$SANDBOX/nomarkers.out" 2>&1
RC=$?
if [ "$RC" -eq 2 ] && grep -q 'NO section markers' "$SANDBOX/nomarkers.out"; then
    ok "U8b  a sectioned suite with unreadable markers exits 2 and says so, instead of becoming one slow unit"
else
    bad "U8b  rc=$RC — a broken section parser degraded to a whole-suite unit, which hides it behind a merely slow run"
fi

# --- U9: `bash <path>`, never the path alone -------------------------------
CMD="$(bash "$UNITS" cmd "scripts/lib/leak-canary.test.sh" 2>/dev/null | tr '\t' '\n' | head -1)"
if [ "$CMD" = "bash" ]; then
    ok "U9   a unit is invoked as 'bash <suite>' — a mode-644 suite would exit 126 if run by path"
else
    bad "U9   the first argv token is '$CMD', not 'bash'; a non-executable suite will exit 126"
fi

# --- U10: the matrix is JSON of the declared length -----------------------
DECL="$(bash "$UNITS" shard-count)"
LEN="$(bash "$UNITS" matrix "$DECL" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)"
if [ "$LEN" = "$DECL" ]; then
    ok "U10  the matrix is valid JSON of exactly $DECL entries, the count the planner declares"
else
    bad "U10  matrix length '$LEN' does not match the declared shard count '$DECL' — the difference is units nothing runs"
fi

# --- U11: the matrix contains only shards that HAVE units -----------------
# Asking for more shards than there are units used to declare jobs with nothing
# in them, and a shard that verifies nothing must never exit 0 — so those jobs
# would have failed the run for having been asked for.
E4="$SANDBOX/e-sparse"; mk_engine "$E4"
mk_suite "$E4/scripts/lib/only1.test.sh"
mk_suite "$E4/scripts/lib/only2.test.sh"
M="$(bash "$E4/scripts/ci-units.sh" matrix 9 2>/dev/null)"
MLEN="$(printf '%s' "$M" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)"
if [ "$MLEN" = "2" ]; then
    ok "U11  9 shards asked for over 2 units yields a 2-entry matrix — no job is declared with nothing to run"
else
    bad "U11  matrix length '$MLEN' for 2 units over 9 shards; empty shard jobs would be declared and would fail"
fi

# --- U12 / U13: the restricted inventory ----------------------------------
# The affected gate packs the diff's units through this same planner, so the
# restriction has to be a real partition of exactly the named set.
RESTRICT="$SANDBOX/restrict.txt"
{
    bash "$UNITS" units | cut -f1 | grep -v ':' | head -5
    bash "$UNITS" units | cut -f1 | grep ':' | head -3
} > "$RESTRICT"
WANT_N="$(grep -c . "$RESTRICT" || true)"
bash "$UNITS" shards 3 --units-file "$RESTRICT" | cut -f2 | LC_ALL=C sort > "$SANDBOX/restricted.planned"
LC_ALL=C sort "$RESTRICT" > "$SANDBOX/restricted.want"
DUPES="$(uniq -d < "$SANDBOX/restricted.planned" | grep -c . || true)"
if diff -q "$SANDBOX/restricted.want" "$SANDBOX/restricted.planned" >/dev/null 2>&1 && [ "${DUPES:-0}" -eq 0 ]; then
    ok "U12  --units-file packs exactly the $WANT_N named unit(s), each once, and nothing else"
else
    bad "U12  the restricted plan is not a partition of the named set (dupes=$DUPES)"
    diff "$SANDBOX/restricted.want" "$SANDBOX/restricted.planned" | sed 's/^/          /' | head -10
fi

BAD_RESTRICT="$SANDBOX/bad-restrict.txt"
{ cat "$RESTRICT"; printf 'scripts/lib/this-unit-does-not-exist.test.sh
'; } > "$BAD_RESTRICT"
bash "$UNITS" shards 3 --units-file "$BAD_RESTRICT" > "$SANDBOX/badout" 2>&1
RC=$?
if [ "$RC" -eq 2 ] && grep -q 'which is not a unit' "$SANDBOX/badout"; then
    ok "U13  an id in the restriction that is not a unit is FATAL and is named"
else
    bad "U13  rc=$RC — an unknown id was silently dropped, so the gate would plan over less than it was asked for"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== ci-units tests: all $PASS passed ==="
    exit 0
fi
echo "=== ci-units tests: $PASS passed, $FAIL FAILED ===" >&2
exit 1
