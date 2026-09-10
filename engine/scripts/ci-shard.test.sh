#!/usr/bin/env bash
#
# ci-shard.test.sh — the verdict rules, and the coverage proof, by execution.
#
# EVERY CASE HERE RUNS AGAINST A SYNTHETIC ENGINE built in a sandbox, not
# against this tree. That is deliberate: the properties being proven are about
# a shard that runs FEWER units than it was given, a section whose scoping
# stopped applying, a known-red entry that outlived its defect. None of those
# can be arranged in the real tree without breaking it, and a property that can
# only be proven by breaking production is a property nobody proves.
#
# WHAT IS PROVEN:
#
#   S1   A suite unit is green at exit 0.
#   S2   A SECTION unit is green at exit 3, which is that suite's deliberate
#        scoped-green code.
#   S3   A section unit that exits 0 is a FAILURE, reported as SCOPE-LOST. Exit
#        0 from a scoped invocation means the --only selector did not apply, so
#        the unit ran something other than what its id says — the one thing a
#        scoped run must never be able to claim.
#   S4   An empty selection is REFUSED (exit 2) unless --allow-empty is given.
#        A shard that verifies nothing must never exit 0.
#   S5   A unit id that is not in the inventory is fatal, not skipped.
#   S6   KNOWN-RED: a declared failing unit does not fail the job, and its
#        expiry and reason are printed.
#   S7   THE NEGATIVE CONTROL: a declared unit that PASSES fails the job. Without
#        this the table outlives its defects and becomes a permanent skip list.
#   S8   An entry past its expiry fails the job even while still failing.
#   S9   A receipt is written per unit, carrying the unit id, the verdict, the
#        duration and the COMMIT.
#   S10  --verify-receipts passes when the receipts union to the plan.
#   S11  --verify-receipts FAILS and NAMES the unit when one is missing — the
#        dropped-shard case, which is the whole reason receipts exist.
#   S12  --verify-receipts FAILS when the receipts carry two different commits.
#   S13  --verify-receipts FAILS when a unit has two receipts.
#   S14  --verify-receipts FAILS on an empty receipt set rather than certifying
#        a plan against nothing.
#   S15  A unit that writes outside its sandbox is caught and named, so the
#        leak canary is not lost by sharding. This is the 2026-09-05
#        escalations.test.sh finding, which run-all-tests.sh catches per suite;
#        splitting the pass must not silently drop it.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-shard-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in ci-shard.sh ci-units.sh lib/ci-receipts.py lib/leak-canary.sh lib/tree-witness.sh; do
    [ -f "$ENGINE_ROOT/scripts/$f" ] || { echo "FATAL: missing scripts/$f" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

echo "=== ci-shard tests ==="

# ---------------------------------------------------------------------------
# a synthetic engine: the minimum ci-shard.sh + ci-units.sh recognize
# ---------------------------------------------------------------------------
mk_engine() { # <root>
    local r="$1"
    mkdir -p "$r/scripts/lib" "$r/scripts/hooks"
    printf '1.0.0-test\n' > "$r/VERSION"
    for f in ci-shard.sh ci-units.sh; do
        cp "$ENGINE_ROOT/scripts/$f" "$r/scripts/$f"; chmod +x "$r/scripts/$f"
    done
    for f in ci-receipts.py leak-canary.sh tree-witness.sh; do
        cp "$ENGINE_ROOT/scripts/lib/$f" "$r/scripts/lib/$f"
    done
    # The sectioned suite, with two real `if _section` markers, so the section
    # units are discovered the same way they are in the real tree. `--only`
    # exits 3 when green and 1 when its selected section fails, mirroring the
    # contract that matters here.
    cat > "$r/scripts/hooks/contract-integrity.test.sh" <<'SECTIONED'
#!/usr/bin/env bash
set -uo pipefail
# The markers have to be REAL: `ci-units.sh` reads section ids with
#   awk '/^if _section [A-Za-z0-9_.-]+; then$/ ...'
# so the `then` must end the line, exactly as it does in the shipped suite. A
# one-line `if _section x; then :; fi` shape parses as bash and is invisible to
# that awk, which is a fixture that silently tests nothing.
_section() { return 1; }
SEL=""
if [ "${1:-}" = "--list" ]; then printf 'alpha\nbeta\n'; exit 0; fi
[ "${1:-}" = "--only" ] && SEL="${2:-}"
if _section alpha; then
    :
fi  # _section
if _section beta; then
    :
fi  # _section
[ -n "$SEL" ] || exit 0
[ "${SECTION_FAILS:-}" = "$SEL" ] && exit 1
[ "${SECTION_EXITS_ZERO:-}" = "$SEL" ] && exit 0
exit 3
SECTIONED
    chmod +x "$r/scripts/hooks/contract-integrity.test.sh"
}
mk_suite() { printf '#!/usr/bin/env bash\nexit %s\n' "${2:-0}" > "$1"; chmod +x "$1"; }

E="$SANDBOX/engine"; mk_engine "$E"
mk_suite "$E/scripts/lib/green.test.sh" 0
mk_suite "$E/scripts/lib/red.test.sh" 1
SH="$E/scripts/ci-shard.sh"

run_shard() { # captures stdout+stderr to $SANDBOX/out, echoes the rc
    local out="$SANDBOX/out"
    bash "$SH" "$@" > "$out" 2>&1
    printf '%s' "$?"
}

# --- S1 / S2 ---------------------------------------------------------------
RC="$(run_shard --only-units scripts/lib/green.test.sh)"
if [ "$RC" = "0" ] && grep -q 'PASS' "$SANDBOX/out"; then
    ok "S1   a suite unit is green at exit 0"
else
    bad "S1   rc=$RC"; sed 's/^/          /' "$SANDBOX/out"
fi
RC="$(run_shard --only-units 'scripts/hooks/contract-integrity.test.sh:alpha')"
if [ "$RC" = "0" ] && grep -q 'PASS' "$SANDBOX/out"; then
    ok "S2   a section unit is green at exit 3, that suite's scoped-green code"
else
    bad "S2   rc=$RC"; sed 's/^/          /' "$SANDBOX/out"
fi

# --- S3: the scoping stopped applying --------------------------------------
SECTION_EXITS_ZERO=alpha
export SECTION_EXITS_ZERO
RC="$(run_shard --only-units 'scripts/hooks/contract-integrity.test.sh:alpha')"
unset SECTION_EXITS_ZERO
if [ "$RC" = "1" ] && grep -q 'SCOPE-LOST\|scoped run exited 0' "$SANDBOX/out"; then
    ok "S3   a scoped section that exits 0 FAILS as SCOPE-LOST — it ran something other than its id"
else
    bad "S3   rc=$RC — exit 0 from a scoped run was accepted, so a selector that stopped matching reads as green"
    sed 's/^/          /' "$SANDBOX/out"
fi

# --- S4: emptiness ---------------------------------------------------------
: > "$SANDBOX/empty-units.txt"
RC="$(run_shard --units-file "$SANDBOX/empty-units.txt")"
if [ "$RC" = "2" ] && grep -q 'no units selected' "$SANDBOX/out"; then
    ok "S4a  an empty selection exits 2 — a shard that verifies nothing never exits 0"
else
    bad "S4a  rc=$RC on an empty selection"
fi
RC="$(run_shard --units-file "$SANDBOX/empty-units.txt" --allow-empty)"
if [ "$RC" = "0" ] && grep -q 'Nothing was verified' "$SANDBOX/out"; then
    ok "S4b  --allow-empty exits 0 but SAYS nothing was verified"
else
    bad "S4b  rc=$RC with --allow-empty"
fi

# --- S5: an unknown unit is fatal -----------------------------------------
RC="$(run_shard --only-units scripts/lib/does-not-exist.test.sh)"
if [ "$RC" = "2" ] && grep -q 'is not a unit' "$SANDBOX/out"; then
    ok "S5   a unit id absent from the inventory is fatal, never silently skipped"
else
    bad "S5   rc=$RC for an unknown unit id"
fi

# --- S6 / S7 / S8: the known-red table ------------------------------------
KR="$E/scripts/lib/ci-known-red.tsv"
FUTURE="$(python3 -c 'import datetime; print((datetime.date.today() + datetime.timedelta(days=30)).isoformat())')"
PAST="$(python3 -c 'import datetime; print((datetime.date.today() - datetime.timedelta(days=1)).isoformat())')"

printf 'scripts/lib/red.test.sh\t2026-01-01\t%s\tdeadbeef\tC1 C2\tbecause the contract moved\n' "$FUTURE" > "$KR"
RC="$(run_shard --only-units scripts/lib/red.test.sh)"
if [ "$RC" = "0" ] && grep -q 'KNOWN-RED' "$SANDBOX/out" && grep -q 'because the contract moved' "$SANDBOX/out"; then
    ok "S6   a declared failing unit is KNOWN-RED, does not fail the job, and prints its reason and expiry"
else
    bad "S6   rc=$RC"; sed 's/^/          /' "$SANDBOX/out"
fi

printf 'scripts/lib/green.test.sh\t2026-01-01\t%s\tdeadbeef\tC1\tstale entry\n' "$FUTURE" > "$KR"
RC="$(run_shard --only-units scripts/lib/green.test.sh)"
if [ "$RC" = "1" ] && grep -q 'declares this unit red and it PASSED' "$SANDBOX/out"; then
    ok "S7   NEGATIVE CONTROL: a declared unit that PASSES fails the job, so the table cannot outlive its defect"
else
    bad "S7   rc=$RC — a stale known-red row was tolerated, which is how a skip list becomes permanent"
    sed 's/^/          /' "$SANDBOX/out"
fi

printf 'scripts/lib/red.test.sh\t2026-01-01\t%s\tdeadbeef\tC1\texpired tolerance\n' "$PAST" > "$KR"
RC="$(run_shard --only-units scripts/lib/red.test.sh)"
if [ "$RC" = "1" ] && grep -q 'EXPIRED' "$SANDBOX/out"; then
    ok "S8   an entry past its expiry fails the job — the tolerance was time-boxed when it was granted"
else
    bad "S8   rc=$RC on an expired entry"; sed 's/^/          /' "$SANDBOX/out"
fi
rm -f "$KR"

# --- S9: receipts ---------------------------------------------------------
R="$SANDBOX/receipts"
mkdir -p "$R"
bash "$SH" --only-units scripts/lib/green.test.sh --receipt "$R/a.jsonl" >/dev/null 2>&1
if [ -s "$R/a.jsonl" ] && python3 - "$R/a.jsonl" <<'PY'
import json, sys
rec = json.loads(open(sys.argv[1]).readline())
need = {"unit", "rc", "expected_rc", "verdict", "seconds", "shard", "shards", "sha"}
sys.exit(0 if need <= set(rec) and rec["unit"] == "scripts/lib/green.test.sh" else 1)
PY
then
    ok "S9   a receipt carries the unit, the verdict, the duration and the commit"
else
    bad "S9   the receipt is missing or malformed"; cat "$R/a.jsonl" 2>/dev/null | sed 's/^/          /'
fi

# --- S10..S14: the coverage proof -----------------------------------------
# The full plan for this synthetic engine, run for real, then mutilated.
rm -rf "$R"; mkdir -p "$R"
bash "$SH" --receipt "$R/all.jsonl" >/dev/null 2>&1 || true
bash "$SH" --verify-receipts "$R" > "$SANDBOX/out" 2>&1
RC=$?
if [ "$RC" != "0" ]; then
    # red.test.sh is genuinely red here, so declare it and re-take the baseline
    printf 'scripts/lib/red.test.sh\t2026-01-01\t%s\tdeadbeef\tC1\tred by design in this fixture\n' "$FUTURE" > "$KR"
    rm -rf "$R"; mkdir -p "$R"
    bash "$SH" --receipt "$R/all.jsonl" >/dev/null 2>&1
    bash "$SH" --verify-receipts "$R" > "$SANDBOX/out" 2>&1
    RC=$?
fi
if [ "$RC" = "0" ] && grep -q 'planned unit(s) ran, all green' "$SANDBOX/out"; then
    ok "S10  --verify-receipts passes when the receipts union to the whole plan at one commit"
else
    bad "S10  rc=$RC"; sed 's/^/          /' "$SANDBOX/out"
fi

# S11 — the dropped shard: drop one unit's receipt
DROPPED="$(head -1 "$R/all.jsonl" | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["unit"])')"
python3 - "$R/all.jsonl" "$DROPPED" <<'PY'
import json, sys
path, drop = sys.argv[1], sys.argv[2]
keep = [l for l in open(path) if l.strip() and json.loads(l)["unit"] != drop]
open(path, "w").writelines(keep)
PY
bash "$SH" --verify-receipts "$R" > "$SANDBOX/out" 2>&1
RC=$?
if [ "$RC" = "1" ] && grep -qF "$DROPPED" "$SANDBOX/out" && grep -q 'have NO receipt' "$SANDBOX/out"; then
    ok "S11  a missing receipt FAILS and NAMES the unit ($DROPPED) — the dropped-shard case"
else
    bad "S11  rc=$RC — a unit nothing ran was not detected, so twelve green jobs would certify a partial pass"
    sed 's/^/          /' "$SANDBOX/out"
fi

# S12 — two commits
rm -rf "$R"; mkdir -p "$R"
bash "$SH" --receipt "$R/all.jsonl" >/dev/null 2>&1
python3 - "$R/all.jsonl" <<'PY'
import json, sys
path = sys.argv[1]
lines = [json.loads(l) for l in open(path) if l.strip()]
lines[0]["sha"] = "0000000000000000000000000000000000000000"
with open(path, "w") as fh:
    for rec in lines:
        fh.write(json.dumps(rec, sort_keys=True, separators=(",", ":")) + "\n")
PY
bash "$SH" --verify-receipts "$R" > "$SANDBOX/out" 2>&1
RC=$?
if [ "$RC" = "1" ] && grep -q 'did not all verify the SAME commit' "$SANDBOX/out"; then
    ok "S12  receipts from two different commits FAIL — a union across two trees certifies neither"
else
    bad "S12  rc=$RC on mixed commits"; sed 's/^/          /' "$SANDBOX/out"
fi

# S13 — a duplicated unit
rm -rf "$R"; mkdir -p "$R"
bash "$SH" --receipt "$R/all.jsonl" >/dev/null 2>&1
head -1 "$R/all.jsonl" > "$R/dupe.jsonl"
bash "$SH" --verify-receipts "$R" > "$SANDBOX/out" 2>&1
RC=$?
if [ "$RC" = "1" ] && grep -q 'more than one receipt' "$SANDBOX/out"; then
    ok "S13  a unit with two receipts FAILS — either the packing overlapped or a receipt was collected twice"
else
    bad "S13  rc=$RC on a duplicated receipt"; sed 's/^/          /' "$SANDBOX/out"
fi

# S14 — nothing at all
rm -rf "$R"; mkdir -p "$R"
bash "$SH" --verify-receipts "$R" > "$SANDBOX/out" 2>&1
RC=$?
if [ "$RC" = "1" ] && grep -q 'NO receipts at all' "$SANDBOX/out"; then
    ok "S14  an empty receipt set FAILS rather than certifying the plan against nothing"
else
    bad "S14  rc=$RC on an empty receipt directory"; sed 's/^/          /' "$SANDBOX/out"
fi
rm -f "$KR"

# --- S15: the leak canary survives sharding -------------------------------
# A suite that writes into the directory the runner was started from is exactly
# the 2026-09-05 escalations.test.sh finding. run-all-tests.sh catches it per
# suite; sharding must not lose that.
LEAKDIR="$SANDBOX/leak-cwd"
mkdir -p "$LEAKDIR"
cat > "$E/scripts/lib/leaky.test.sh" <<'LEAKY'
#!/usr/bin/env bash
printf 'residue a stranger will have to explain\n' > "./leaked-fixture.txt"
exit 0
LEAKY
chmod +x "$E/scripts/lib/leaky.test.sh"
( cd "$LEAKDIR" && bash "$SH" --only-units scripts/lib/leaky.test.sh > "$SANDBOX/out" 2>&1 )
RC=$?
if [ "$RC" = "1" ] && grep -q 'outside its sandbox' "$SANDBOX/out"; then
    ok "S15  a unit that writes outside its sandbox is caught and named — the canary is not lost by sharding"
else
    bad "S15  rc=$RC — the per-unit leak canary did not fire"; sed 's/^/          /' "$SANDBOX/out"
fi
rm -f "$E/scripts/lib/leaky.test.sh"

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== ci-shard tests: all $PASS passed ==="
    exit 0
fi
echo "=== ci-shard tests: $PASS passed, $FAIL FAILED ===" >&2
exit 1
