#!/usr/bin/env bash
#
# brief-scope.test.sh — the suite for brief-scope.py and guard-brief-scope.sh.
#
# EVERYTHING RUNS IN A SANDBOX. The operator's real state
# ($CLAUDE_CONFIG_DIR/state/workspaces) is never read and never written:
# RICHOS_WORKSPACES_DIR is redirected into a mktemp directory for the whole run,
# and every repository is a fixture made by this file.
#
# THE ACCEPTANCE CASE IS THE REAL ROUND-9 BRIEF, byte for byte, read from
# richos-hq at the commit that carries it. A suite that tests this mechanism on
# a brief written to be caught is a suite that proves nothing — the whole claim
# is that it would have stopped the round that was actually dispatched.
#
# Exit 0 only when every case passes.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/brief-scope.py"
GUARD="$HERE/hooks/guard-brief-scope.sh"

PASS=0; FAIL=0
ok()   { printf '      ok   %s\n' "$1"; PASS=$((PASS+1)); }
# Two spaces after FAIL: the shared mutation harness matches "FAIL  <case id>",
# and a one-space line makes every mutant report "red, but not at the named case".
bad()  { printf '      FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '           %s\n' "$(printf '%s' "$2" | head -c 900 | tr '\n' '|')"; FAIL=$((FAIL+1)); }
want() { # <label> <expected-rc> <expected-substring-or-empty> <actual-rc> <actual-out>
    if [ "$2" != "$4" ]; then bad "$1  (wanted exit $2, got $4)" "$5"; return; fi
    if [ -n "$3" ] && ! printf '%s' "$5" | grep -q -- "$3"; then
        bad "$1  (exit right, but the output never says '$3')" "$5"; return
    fi
    ok "$1"
}

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/brief-scope.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT
export RICHOS_WORKSPACES_DIR="$T/state/workspaces"
mkdir -p "$RICHOS_WORKSPACES_DIR"

# --- a fixture repository and a fixture spec --------------------------------
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email webdevbooster@gmail.com; git -C "$REPO" config user.name "Alex Booster"
echo one >"$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm one
TIP="$(git -C "$REPO" rev-parse main)"

SPEC="$T/spec.md"
{
  echo "# fixture spec"
  for i in $(seq 1 14); do echo "$i. **point $i.**"; done
} >"$SPEC"

cat >"$RICHOS_WORKSPACES_DIR/integration.json" <<JSON
{"current": {"$REPO": "fx-001"},
 "works": {"fx-001": {"id": "fx-001", "repo": "$REPO", "branch": "main",
                      "recorded_at": "2026-09-14T00:00:00Z", "source": "recorded",
                      "corrections": [], "why": "fixture"}}}
JSON

VERDICT="$T/state/verdict.json"

# A run of the harness, in the harness's own output shape. Args: list of red points.
mklog() { # <outfile> <red point numbers...>
    local out="$1"; shift
    local reds=" $* "
    : >"$out"
    echo "=== C0  the harness's own self-check ===" >>"$out"
    echo "  PASS  C0  the harness's own self-check" >>"$out"
    local nred=0
    for i in $(seq 1 14); do
        if printf '%s' "$reds" | grep -q " $i "; then
            echo "  FAIL  C$i  point $i  (1 sub-assertion(s) red)" >>"$out"
            nred=$((nred+1))
        else
            echo "  PASS  C$i  point $i" >>"$out"
        fi
    done
    echo "CHECKS RUN: 15  RED: $nred" >>"$out"
    echo "FOURTEEN: $((14-nred)) green, $nred red · self-check: green" >>"$out"
}

record_verdict() { # <base sha> <red points...>
    local base="$1"; shift
    mklog "$T/run.txt" "$@"
    python3 "$LIB" verdict --from-log "$T/run.txt" --base "$base" --out "$VERDICT" >/dev/null
}

payload() { # <brief file> -> a PreToolUse[Agent] envelope on stdout
    python3 - "$1" "$REPO" <<'PY'
import json,sys
brief=open(sys.argv[1],encoding='utf-8',errors='replace').read()
print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Agent","cwd":sys.argv[2],
                  "tool_input":{"name":"zach-opus-t1","prompt":brief}}))
PY
}

run_check() { # <brief file> -> sets RC and OUT
    payload "$1" >"$T/payload.json"
    OUT="$(python3 "$LIB" check "$T/payload.json" 2>&1)"; RC=$?
}

echo "=== 1  the default everywhere: a body of work with no recorded spec is SILENT ==="
printf 'do some work\nno anchors here at all\n' >"$T/plain.md"
record_verdict "$TIP" 2 9
run_check "$T/plain.md"
want "S1 no spec recorded -> exit 0, nothing printed" 0 "" "$RC" "$OUT"
[ -z "$OUT" ] || bad "S1b it printed something on a body of work it does not govern" "$OUT"
[ -z "$OUT" ] && ok "S1b it printed nothing"

echo ""
echo "=== 2  once the spec is recorded, the anchor is required ==="
python3 "$LIB" record-spec "$REPO" --spec "$SPEC" --points 14 --verdict "$VERDICT" >/dev/null
run_check "$T/plain.md"
want "S2 a brief with no serves: line is refused" 2 "NO-ANCHOR" "$RC" "$OUT"
want "S2b the refusal names what is still red" 2 "point 2, point 9" "$RC" "$OUT"

echo ""
echo "=== 3  a brief anchored to a RED point passes, and one anchored to a GREEN point does not ==="
# `design: open` because point 2 is red in verdict after verdict in the cases
# below, and §6 requires a retry item to say who chooses the mechanism. Every
# one of these cases is about staleness, regression or convergence, so the
# disposition is there to keep them testing what they were written to test.
printf 'serves: point 2 - the thing that is broken\ndesign: open\n' >"$T/red.md"
run_check "$T/red.md"
want "S3 anchored to a red point -> allowed" 0 "point 2 named" "$RC" "$OUT"

printf 'serves: point 5 - something that already works\n' >"$T/green.md"
run_check "$T/green.md"
want "S4 anchored to a green point -> SPEC-SATISFIED" 2 "SPEC-SATISFIED" "$RC" "$OUT"
want "S4b the refusal carries the CEO's question" 2 "measures complete" "$RC" "$OUT"

printf 'serves: point 2 - broken\nserves: point 5 - already works\n' >"$T/mixed.md"
run_check "$T/mixed.md"
want "S5 a green item riding along with a red one is refused on its own" 2 "GREEN-ITEM" "$RC" "$OUT"
want "S5b and the refusal says the rest is dispatchable" 2 "riding along" "$RC" "$OUT"
printf 'serves: point 2 - broken\n' >"$T/dropped.md"
run_check "$T/dropped.md"
want "S5c dropping the rider dispatches the rest" 0 "point 2 named" "$RC" "$OUT"

echo ""
echo "=== 4  the ways out, and the ways not out ==="
printf 'serves: point 5 - already works\nscope-ceo-word: he said carry on, 2026-09-14\n' >"$T/hatch.md"
run_check "$T/hatch.md"
want "S6 the CEO's word releases a green anchor" 0 "on the CEO's word" "$RC" "$OUT"

printf 'scope: fx-002\nserves: point 2 - broken\n' >"$T/rename.md"
run_check "$T/rename.md"
want "S7 renaming the body of work is refused, not a way out" 2 "WRONG-WORK" "$RC" "$OUT"

printf 'serves: point 99 - a point he never wrote\n' >"$T/nosuch.md"
run_check "$T/nosuch.md"
want "S8 a point the spec does not have is refused" 2 "NO-SUCH-POINT" "$RC" "$OUT"

printf 'a brief that quotes another brief:\n\n```\nserves: point 2 - broken\n```\n' >"$T/fenced.md"
run_check "$T/fenced.md"
want "S9 a serves: line inside a fenced block is an example, not an anchor" 2 "NO-ANCHOR" "$RC" "$OUT"

echo ""
echo "=== 5  the spec is the anchor, so a spec that moved invalidates everything ==="
cp "$SPEC" "$T/spec.bak"
echo "15. **a point he added today.**" >>"$SPEC"
run_check "$T/red.md"
want "S10 an edited spec refuses every dispatch until it is re-recorded" 2 "SPEC-CHANGED" "$RC" "$OUT"
cp "$T/spec.bak" "$SPEC"
run_check "$T/red.md"
want "S10b restoring the recorded text makes it silent again" 0 "point 2" "$RC" "$OUT"

echo ""
echo "=== 6  the measurement must be current ==="
echo two >"$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm two
run_check "$T/red.md"
want "S11 a verdict older than the branch tip is refused" 2 "VERDICT-STALE" "$RC" "$OUT"
TIP2="$(git -C "$REPO" rev-parse main)"
record_verdict "$TIP2" 2 9
run_check "$T/red.md"
want "S11b re-measuring at the tip clears it" 0 "point 2" "$RC" "$OUT"

echo ""
echo "=== 7  THE SERIES: a regression ends the round, and a loop ends the series ==="
# history so far: (2,9) at TIP, (2,9) at TIP2.  Now a round that fixes 2 and breaks 7.
echo three >"$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm three
TIP3="$(git -C "$REPO" rev-parse main)"
record_verdict "$TIP3" 9 7
run_check "$T/red.md"
want "S12 a point that was green and is now red refuses everything" 2 "REGRESSED" "$RC" "$OUT"
want "S12b it names the point that went backwards" 2 "Point 7" "$RC" "$OUT"
printf 'serves: point 9 - broken\nscope-ceo-word: carry on, he said so\n' >"$T/hatch2.md"
run_check "$T/hatch2.md"
want "S12c only the CEO's word releases a regression" 0 "" "$RC" "$OUT"

# A stalled series: three rounds, red count never falls.
rm -f "$VERDICT" "$VERDICT.history.jsonl"
record_verdict "$TIP3" 2 9 7
echo four >"$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm four
TIP4="$(git -C "$REPO" rev-parse main)"
record_verdict "$TIP4" 2 9 7
echo five >"$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm five
TIP5="$(git -C "$REPO" rev-parse main)"
record_verdict "$TIP5" 2 9 7
run_check "$T/red.md"
want "S13 three rounds that did not reduce the red count refuse the fourth" 2 "NOT-CONVERGING" "$RC" "$OUT"
want "S13b the refusal shows the series" 2 "3 -> 3 -> 3" "$RC" "$OUT"

# A converging series is never refused: 3 -> 2 -> 1.
rm -f "$VERDICT" "$VERDICT.history.jsonl"
record_verdict "$TIP3" 2 9 7
record_verdict "$TIP4" 2 9
record_verdict "$TIP5" 2
run_check "$T/red.md"
want "S14 POSITIVE CONTROL: a falling red count is never refused" 0 "point 2" "$RC" "$OUT"

echo ""
echo "=== 8  the guard carries the refusal to the host ==="
payload "$T/green.md" >"$T/payload.json"
rm -f "$VERDICT" "$VERDICT.history.jsonl"; record_verdict "$TIP5" 2
GOUT="$(bash "$GUARD" <"$T/payload.json" 2>&1)"; GRC=$?
want "S15 the guard exits 2 and prints the refusal" 2 "SPEC-SATISFIED" "$GRC" "$GOUT"
payload "$T/red.md" >"$T/payload.json"
GOUT="$(bash "$GUARD" <"$T/payload.json" 2>&1)"; GRC=$?
want "S16 the guard is silent on a dispatchable brief" 0 "" "$GRC" "$GOUT"
[ -z "$GOUT" ] && ok "S16b and prints nothing" || bad "S16b it printed" "$GOUT"
GOUT="$(printf '' | bash "$GUARD" 2>&1)"; GRC=$?
want "S17 an empty payload is exit 0, never a refusal of its own inability" 0 "" "$GRC" "$GOUT"
GOUT="$(printf '{"tool_name":"Bash","tool_input":{}}' | bash "$GUARD" 2>&1)"; GRC=$?
want "S18 a non-Agent tool call is untouched" 0 "" "$GRC" "$GOUT"

# THE TYPE-Z CASE. This guard shipped unable to find its own library and took a
# quiet exit 0; every library-level case still passed. A guard that cannot run
# must say so, or it is indistinguishable from a guard that found nothing.
mkdir -p "$T/broken/hooks"
sed 's|\$HERE/\.\./brief-scope\.py|$HERE/../nowhere/brief-scope.py|' "$GUARD" >"$T/broken/hooks/g.sh"
payload "$T/green.md" >"$T/payload.json"
GOUT="$(bash "$T/broken/hooks/g.sh" <"$T/payload.json" 2>&1)"; GRC=$?
want "S18b a guard that cannot find its library exits 0 but is AUDIBLE" 0 "did NOT run" "$GRC" "$GOUT"

echo ""
echo "=== 9  ACCEPTANCE: the real round-9 brief, byte for byte ==="
R9="/Users/alex/ab/richos-hq/docs/plans/round9-brief-2026-09-13.md"
if [ -f "$R9" ]; then
    # The state round 9 was dispatched into, as round 9's own brief states it:
    # "the fourteen read 14 green, 0 red". Recorded here from a run in that shape.
    rm -f "$VERDICT" "$VERDICT.history.jsonl"
    record_verdict "$(git -C "$REPO" rev-parse main)"      # no arguments: 14 green, 0 red
    run_check "$R9"
    want "S19 THE ROUND-9 BRIEF IS REFUSED" 2 "NO-ANCHOR" "$RC" "$OUT"
    want "S19b and the refusal says nothing is red" 2 "every point is green" "$RC" "$OUT"

    # And with the anchor its author would have had to write for its one item
    # that touches the spec at all — item 2, which is about point 2:
    { echo "scope: fx-001"; echo "serves: point 2 - a codex/ ref deleted by an agent is restored"; cat "$R9"; } >"$T/r9-anchored.md"
    run_check "$T/r9-anchored.md"
    want "S20 anchored to point 2, it is refused because point 2 is recorded green" 2 "SPEC-SATISFIED" "$RC" "$OUT"
    want "S20b and it hands over the CEO's question" 2 "measures complete" "$RC" "$OUT"

    # THE HONEST HALF: if point 2 had been recorded RED, this mechanism lets the
    # whole of round 9 item 2 through, prescribed design and all. Nothing here
    # reads a design.
    rm -f "$VERDICT" "$VERDICT.history.jsonl"
    record_verdict "$(git -C "$REPO" rev-parse main)" 2
    run_check "$T/r9-anchored.md"
    want "S21 THE MISS, ASSERTED: with point 2 red, round 9 item 2 passes untouched" 0 "point 2 named" "$RC" "$OUT"
else
    bad "S19 the round-9 brief is not at $R9" "acceptance case could not run"
fi

echo ""
echo "=== 10  §6 WHO CHOOSES THE MECHANISM — the retry rule and the counter-stamp ==="
# A point is ON RETRY when it was red in the PREVIOUS recorded verdict and is red
# still. That is arithmetic over a ledger the lead does not author, and it is the
# CEO's own scoping clause — "prescribed design (in cases where finding new design
# options is the objective)" — turned into a fact instead of a reading of prose.

rm -f "$VERDICT" "$VERDICT.history.jsonl"
record_verdict "$TIP5" 2 9
record_verdict "$TIP5" 2 9

printf 'serves: point 2 - the thing that is broken\n' >"$T/retry-bare.md"
run_check "$T/retry-bare.md"
want "S22 a retry item with no design: line is REFUSED" 2 "DESIGN-UNDECLARED" "$RC" "$OUT"
want "S22b the refusal quotes the CEO's scoping clause" 2 "FINDING NEW DESIGN OPTIONS" "$RC" "$OUT"
want "S22c and it claims only what it measured, never 'a round was spent'" 2 "NOT claim a round was spent" "$RC" "$OUT"

printf 'serves: point 2 - the thing that is broken\ndesign: open\n' >"$T/retry-open.md"
run_check "$T/retry-open.md"
want "S23 design: open is accepted" 0 "design: open on point 2" "$RC" "$OUT"

printf 'serves: point 2 - x\ndesign: spec point 2\n' >"$T/retry-spec.md"
run_check "$T/retry-spec.md"
want "S24 design: spec point <N> is accepted" 0 "the CEO's own point 2" "$RC" "$OUT"

printf 'serves: point 2 - x\ndesign: spec point 99\n' >"$T/retry-spec99.md"
run_check "$T/retry-spec99.md"
want "S25 a disposition naming a point the spec lacks is refused" 2 "DESIGN-NOT-A-DISPOSITION" "$RC" "$OUT"

printf 'serves: point 2 - x\ndesign: record the lead own windows\n' >"$T/retry-presc.md"
run_check "$T/retry-presc.md"
want "S26 a prescription written INTO the disposition line is not one of the three" 2 "DESIGN-NOT-A-DISPOSITION" "$RC" "$OUT"

printf 'serves: point 2 - x\ndesign: ceo-word: he said build it this way, 2026-09-14\n' >"$T/retry-ceo.md"
run_check "$T/retry-ceo.md"
want "S27 design: ceo-word: is accepted and echoed for the log" 0 "on the CEO's word" "$RC" "$OUT"

# A point red for the FIRST time is NOT on retry: nothing has failed to move yet,
# and a brief that carries a starting approach is doing its job. This is the
# clause's own boundary and it is asserted, not assumed.
rm -f "$VERDICT" "$VERDICT.history.jsonl"
record_verdict "$TIP5" 2 9
run_check "$T/retry-bare.md"
want "S28 BOUNDARY: a first-time-red point needs no disposition" 0 "point 2" "$RC" "$OUT"

# A GREEN point is never on retry, so §6 never fires on one — the green clauses
# own that case and must keep owning it.
rm -f "$VERDICT" "$VERDICT.history.jsonl"
record_verdict "$TIP5" 9
record_verdict "$TIP5" 9
run_check "$T/retry-bare.md"
want "S29 BOUNDARY: a green point is refused as SPEC-SATISFIED, not for its design" 2 "SPEC-SATISFIED" "$RC" "$OUT"

# THE COUNTER-STAMP. Not a refusal and not a report: it changes the instruction the
# agent receives, on the only copy there is, and the lead cannot remove it.
rm -f "$VERDICT" "$VERDICT.history.jsonl"
record_verdict "$TIP5" 2 9
record_verdict "$TIP5" 2 9
STAMPED="$(python3 "$LIB" annotate "$T/retry-open.md" --repo "$REPO" 2>/dev/null)"
if printf '%s' "$STAMPED" | grep -q "no sentence in this brief is binding on your design"; then
    ok "S30 design: open appends the counter-stamp to the dispatched text"
else
    bad "S30 design: open appends the counter-stamp to the dispatched text" "$STAMPED"
fi
if printf '%s' "$STAMPED" | grep -q "^serves: point 2"; then
    ok "S30b and the brief itself is left intact above it"
else
    bad "S30b and the brief itself is left intact above it" "$STAMPED"
fi
UNSTAMPED="$(python3 "$LIB" annotate "$T/retry-open.md" --repo "" 2>/dev/null)"
if [ "$UNSTAMPED" = "$(cat "$T/retry-open.md")" ]; then
    ok "S30c a brief with nothing on retry is byte-identical after annotate"
else
    bad "S30c a brief with nothing on retry is byte-identical after annotate" "$UNSTAMPED"
fi

# THE ACCEPTANCE CASE FOR §6, and it is the one S21 records as the miss: the REAL
# round-9 brief, anchored to point 2, with point 2 red in two consecutive
# verdicts. S21 keeps asserting that a FIRST-time-red point lets it through; this
# asserts that once the measurement has failed to move, the same brief is refused
# until it says whose design it is carrying.
if [ -f "$R9" ]; then
    rm -f "$VERDICT" "$VERDICT.history.jsonl"
    record_verdict "$(git -C "$REPO" rev-parse main)" 2
    record_verdict "$(git -C "$REPO" rev-parse main)" 2
    run_check "$T/r9-anchored.md"
    want "S31 THE ROUND-9 BRIEF, on a retry, is REFUSED for its undeclared design" 2 "DESIGN-UNDECLARED" "$RC" "$OUT"
    want "S31b and the refusal names round 9's own reviewer-authored prescription" 2 "adversarial reviewer's own" "$RC" "$OUT"

    # And the honest half of §6, asserted so it cannot quietly become a claim of
    # coverage: a lead who writes `design: open` and prescribes anyway is NOT
    # refused. Nothing here reads the prose, so the prescription in the body
    # survives; what it no longer carries is unchallenged authority.
    { echo "design: open"; cat "$T/r9-anchored.md"; } >"$T/r9-open.md"
    run_check "$T/r9-open.md"
    want "S32 THE RESIDUE, ASSERTED: design: open + a prescription in the body still passes" 0 "design: open on point 2" "$RC" "$OUT"
else
    bad "S31 the round-9 brief is not at $R9" "acceptance case could not run"
fi

echo ""
echo "=== brief-scope tests: $PASS passed, $FAIL failed ==="

# --- THE MUTATION HARNESS ---------------------------------------------------
# Every green case above is evidence of nothing until it has been watched going
# red for its own reason. The harness is invoked from here so that the runner
# which discovers *.test.sh runs it too.
MUT_RC=0
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$HERE/brief-scope.mutation.sh" ] \
   && [ "${BRIEF_SCOPE_SKIP_MUTANTS:-0}" != 1 ]; then
    echo ""
    echo "=== running the mutation harness ==="
    bash "$HERE/brief-scope.mutation.sh"; MUT_RC=$?
fi

[ "$FAIL" -eq 0 ] && [ "$MUT_RC" -eq 0 ]
