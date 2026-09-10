#!/usr/bin/env bash
#
# CONSTRAINT 3, PROVEN AGAINST A REAL `kill -9` MID-RUN.
#
# The claim under test: no mutant ever mutates a shipped file in place, so a run
# killed at the worst possible moment leaves the operator's live enforcement
# byte-identical AND never opened for writing.
#
# WHY MTIME AND NOT ONLY CONTENTS. A harness that mutates and restores leaves the
# contents identical and the MTIME MOVED. "Restored correctly" and "never
# touched" are different guarantees, and only the second survives `kill -9`,
# because a restore is a promise conditional on reaching the restore. The witness
# is therefore contents AND mtime -- the engine's own tree-witness standard.
#
# THE KILL MUST LAND WHILE MUTANTS ARE ACTUALLY MUTATING, or the proof is that
# nothing happens when nothing is running. So before killing, this script counts
# the in-flight worker sandboxes and checks that at least one holds a guard whose
# bytes DIFFER from the shipped guard -- i.e. a mutation is applied and live at
# the instant of the kill. That count is reported, and a run that could not
# observe one says so instead of claiming a proof it did not make.
#
# The kill goes to the whole PROCESS GROUP: a SIGKILL to the parent alone would
# let the workers finish tidily, which is the opposite of the scenario.
set -u
ENG=/Users/alex/ab/richos-wt/zach-opus-mu2/engine
SC=/private/tmp/claude-501/-Users-alex-ab-femcboost/899d5bee-2ef7-4c2b-8478-3cde1a1aecdf/scratchpad
HARNESS="${1:-scripts/hooks/guard-worktree-isolation.mutation.sh}"
GUARDBASE="${2:-guard-worktree-isolation}"
KILL_AFTER="${3:-30}"
JOBS="${4:-8}"
TMP="${TMPDIR:-/tmp}"

. "$ENG/scripts/lib/tree-witness.sh"
tw_pick_mtime "$ENG"

witness() {
    : >"$1"
    find "$ENG/scripts" "$ENG/hooks" -type f \
        \( -name '*.sh' -o -name '*.py' -o -name '*.json' \) 2>/dev/null \
        | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s\t%s\n' "$f" "$(tw_file_witness "$f")" >>"$1"
    done
}

echo "=== kill -9 proof: $HARNESS at degree $JOBS, killed after ${KILL_AFTER}s ==="
echo "witness = contents AND mtime ($(tw_mtime_available && echo 'sub-second mtime proved' || echo 'CONTENTS ONLY'))"

SHIPPED="$ENG/scripts/hooks/$GUARDBASE.sh"
SHIPPED_SUM="$(shasum -a 256 "$SHIPPED" | cut -d' ' -f1)"
witness "$SC/zach-kill9-before.txt"
echo "before: $(wc -l < "$SC/zach-kill9-before.txt" | tr -d ' ') shipped files witnessed; shipped guard sha=${SHIPPED_SUM:0:12}"

# PURGE STALE SANDBOXES FIRST. A previous killed run leaves its worker sandboxes
# behind by design — they are the only casualty — and each one is a whole engine
# copy containing EVERY guard. So a later proof that counts "sandboxes holding a
# mutated $GUARDBASE" finds the earlier run's orphans, sees them unmutated, and
# reports INCONCLUSIVE. Observed exactly that way: the WTR proof found 8 sandboxes
# and 0 mutated, and all 8 were orphans left by the WTI proof run before it.
_purged=0
for d in "$TMP"/mutant-sandbox.*; do
    [ -d "$d" ] && { rm -rf "$d"; _purged=$(( _purged + 1 )); }
done
echo "purged $_purged stale sandbox(es) from earlier runs, so the count below is this run's"

set -m
RICHOS_MUTANT_JOBS="$JOBS" /bin/bash "$ENG/$HARNESS" >"$SC/zach-kill9-run.log" 2>&1 &
PGID=$!
set +m
sleep "$KILL_AFTER"

# --- is a mutation live RIGHT NOW? -----------------------------------------
INFLIGHT=0
MUTATED=0
for d in "$TMP"/mutant-sandbox.*; do
    [ -d "$d" ] || continue
    INFLIGHT=$(( INFLIGHT + 1 ))
    g="$d/engine/scripts/hooks/$GUARDBASE.sh"
    [ -f "$g" ] || continue
    s="$(shasum -a 256 "$g" | cut -d' ' -f1)"
    [ "$s" != "$SHIPPED_SUM" ] && MUTATED=$(( MUTATED + 1 ))
done
echo "at the instant of the kill: $INFLIGHT worker sandbox(es) present, $MUTATED holding a MUTATED guard"

echo "killing pgid $PGID with SIGKILL"
kill -9 -"$PGID" 2>/dev/null || kill -9 "$PGID" 2>/dev/null || true
pkill -9 -f "$(basename "$HARNESS")" 2>/dev/null || true
sleep 3

witness "$SC/zach-kill9-after.txt"
LEFT=0
for d in "$TMP"/mutant-sandbox.*; do [ -d "$d" ] && LEFT=$(( LEFT + 1 )); done
echo "after the kill: $LEFT orphaned sandbox(es) under TMPDIR — the only casualty"

if [ "$MUTATED" -lt 1 ]; then
    echo "RESULT: INCONCLUSIVE — no mutated guard was observed in flight at the kill,"
    echo "        so this run does not prove anything about a kill DURING a mutation."
    echo "        Re-run with a longer --kill-after, or a harness with slower mutants."
    exit 2
fi

if diff -q "$SC/zach-kill9-before.txt" "$SC/zach-kill9-after.txt" >/dev/null; then
    echo "RESULT: PROVEN — $MUTATED live mutation(s) were in flight, the whole process group"
    echo "        was SIGKILLed, and every one of the $(wc -l < "$SC/zach-kill9-after.txt" | tr -d ' ') shipped engine files is"
    echo "        byte-identical AND its mtime is unchanged. A file written and restored"
    echo "        would show a MOVED MTIME here; a file written and NOT restored would"
    echo "        differ in contents."
else
    echo "RESULT: VIOLATED — the shipped tree changed across a killed run:"
    diff "$SC/zach-kill9-before.txt" "$SC/zach-kill9-after.txt" | head -40 | sed 's/^/    /'
    exit 1
fi
