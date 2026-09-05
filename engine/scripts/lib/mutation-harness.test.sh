#!/usr/bin/env bash
#
# mutation-harness.test.sh — A MUTATION HARNESS MUST NOT BE ABLE TO LEAVE THE
# SHIPPED ENGINE MODIFIED, WHATEVER KILLS IT.
#
# ===========================================================================
# THE DEFECT THIS PINS
# ===========================================================================
# On 2026-09-05 an engineer working in this repository saw the SHIPPED
# guard-worktree-isolation.sh — the spawn gate — sitting in a live tree with
# its clause-6 comparison flipped from `-gt` to `-lt`: the model-tier gate
# enforcing the exact inverse of the CEO's ceiling, refusing upgrades and
# waving downgrades through. It was a mutant from that guard's own mutation
# harness, which mutated the shipped file in place and restored it with
#
#     trap 'restore; rm -f "$BAK"' EXIT
#
# That run finished, so the guard went back. AN `EXIT` TRAP IS A PROMISE
# CONDITIONAL ON EXITING: it does not survive `kill -9`, an OOM kill, a power
# cut, or a terminal that goes away. And `~/.claude/richos-engine` is a symlink
# to the main checkout, so the file at risk is the operator's live enforcement.
# Both affected harnesses are invoked by contract-integrity.test.sh, so the
# window was open on every CI verify, not only on a hand-run harness.
#
# ===========================================================================
# HOW IT IS PROVEN HERE, AND WHY IT IS NOT A SIMULATION
# ===========================================================================
# A test that "simulates a crash" by returning early proves nothing about a
# crash. So this suite actually sends `kill -9` to the harness's PROCESS GROUP
# while a mutation is live, and then looks at the file.
#
# It runs the same kill twice, against two synthetic harnesses that differ ONLY
# in the mechanism:
#   OLD SHAPE — mutate the shipped file, restore in an EXIT trap. This is the
#               NEGATIVE CONTROL, and it has to come out DAMAGED. If it did
#               not, this suite could not detect damage at all and its verdict
#               on the new shape would be worthless.
#   NEW SHAPE — mutate a copy from mutation_sandbox_engine. Must come out
#               UNTOUCHED, in contents AND mtime.
#
# AND THE CONTROL IS CHECKED FOR *WHY* IT FAILS, not merely that it does. Each
# case asserts that a mutation was OBSERVED LIVE before the kill, and that the
# process was really dead after it. Without those, "untouched" for the new
# shape would be satisfied by killing it before it did anything — which is
# exactly the wrong-reason pass this project keeps finding. That is not a
# hypothetical here either: the first hand-run of this experiment on
# 2026-09-05 killed the real isolation harness at 240s, during its baseline
# suite run, before any mutation existed. It reported "untouched" and proved
# nothing.
#
# WHAT THIS SUITE DOES NOT COVER, by name:
#   - It does not run the two REAL harnesses to completion under a kill. The
#     isolation harness needs about 320s before its first mutation exists, and
#     a suite that costs six minutes to make one assertion gets skipped. The
#     real harnesses carry that proof themselves, at run time, as their M99
#     case — which asserts the shipped guard's contents AND mtime across their
#     whole run, and which runs every time they do.
#   - Section 4 below is therefore a STRUCTURAL check on those two files, and
#     a structural check is a proxy. It is named as one rather than counted as
#     the kill proof.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t mutation-harness-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '          %s\n' "$2"; FAIL=$((FAIL + 1)); }

# shellcheck source=tree-witness.sh
. "$ENGINE_ROOT/scripts/lib/tree-witness.sh"
tw_pick_mtime "$SANDBOX"

echo "=== mutation-harness: a kill -9 must not damage the shipped engine ==="

# ---------------------------------------------------------------------------
# 0. The witness this suite depends on must itself be able to see a rewrite.
#    If it cannot, every verdict below is "no difference detected" for the
#    wrong reason, and section 1's control would fail to fail.
# ---------------------------------------------------------------------------
PROBE="$SANDBOX/witness-probe"
printf 'original\n' > "$PROBE"
W1="$(tw_file_witness "$PROBE")"
printf 'mutated!\n' > "$PROBE"
W2="$(tw_file_witness "$PROBE")"
if [ "$W1" != "$W2" ]; then
    ok "0a  the witness sees a content change — so a 'no change' verdict below means something"
else
    bad "0a  the witness sees a content change" "tw_file_witness returned '$W1' for both, so nothing below can detect damage"
fi
printf 'original\n' > "$PROBE"
W3="$(tw_file_witness "$PROBE")"
if tw_mtime_available; then
    if [ "$W3" != "$W1" ]; then
        ok "0b  and it sees a RESTORE: identical bytes written back still move the witness, so 'never opened for writing' is a checkable claim"
    else
        bad "0b  the witness sees a restore" "identical bytes written back gave the same witness even though an mtime was available; 'never touched' and 'put back' would be indistinguishable"
    fi
else
    ok "0b  no sub-second mtime format proved itself here, so this run can only check CONTENTS: 'never touched' and 'written and restored' are indistinguishable, and that is stated rather than assumed"
fi

# ---------------------------------------------------------------------------
# The shared fixture: a fake engine with a fake guard, and a marker line that
# a "mutation" removes. Nothing here is the real engine.
# ---------------------------------------------------------------------------
FAKE_ENG="$SANDBOX/fake-engine"
mkdir -p "$FAKE_ENG/scripts/hooks" "$FAKE_ENG/scripts/lib" "$FAKE_ENG/hooks"
printf 'PROTECTED_PATHS="app"\n' > "$FAKE_ENG/orchestration.config"
printf '0.0.0-fixture\n' > "$FAKE_ENG/VERSION"
cp "$ENGINE_ROOT/scripts/lib/mutation-harness.sh" "$FAKE_ENG/scripts/lib/"
cp "$ENGINE_ROOT/scripts/lib/tree-witness.sh" "$FAKE_ENG/scripts/lib/"
FAKE_GUARD="$FAKE_ENG/scripts/hooks/fake-guard.sh"
cat > "$FAKE_GUARD" <<'GUARDEOF'
#!/usr/bin/env bash
# A stand-in for a shipped guard. THE_LOAD_BEARING_LINE below is what a
# mutant removes, so its absence is unambiguous damage.
THE_LOAD_BEARING_LINE=1
exit 0
GUARDEOF
GUARD_PRISTINE="$(cat "$FAKE_GUARD")"

# run_and_kill <harness-path> — start it in its own process group, wait until a
# mutation is observably live SOMEWHERE, kill -9 the group, confirm death.
# Sets: RK_SAW_SHIPPED, RK_SAW_SANDBOX, RK_DEAD.
run_and_kill() {
    local harness="$1" deadline pid
    RK_SAW_SHIPPED=0; RK_SAW_SANDBOX=0; RK_DEAD=0
    set -m
    bash "$harness" >"$SANDBOX/harness.out" 2>&1 &
    pid=$!
    set +m
    deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        kill -0 "$pid" 2>/dev/null || break
        if ! grep -q THE_LOAD_BEARING_LINE "$FAKE_GUARD" 2>/dev/null; then RK_SAW_SHIPPED=1; break; fi
        if [ -f "$SANDBOX/mutation-was-applied" ]; then RK_SAW_SANDBOX=1; break; fi
        sleep 0.05
    done
    kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    kill -0 "$pid" 2>/dev/null || RK_DEAD=1
}

# ---------------------------------------------------------------------------
# 1. THE NEGATIVE CONTROL: the old shape, killed mid-mutation, MUST be damaged.
# ---------------------------------------------------------------------------
OLD="$SANDBOX/old-shape.sh"
cat > "$OLD" <<OLDEOF
#!/usr/bin/env bash
set -uo pipefail
GUARD="$FAKE_GUARD"
BAK="\$(mktemp)"
cp "\$GUARD" "\$BAK"
restore() { cp "\$BAK" "\$GUARD"; }
trap 'restore; rm -f "\$BAK"' EXIT
grep -v THE_LOAD_BEARING_LINE "\$BAK" > "\$GUARD"
sleep 120
OLDEOF
W_BEFORE="$(tw_file_witness "$FAKE_GUARD")"
run_and_kill "$OLD"
if [ "$RK_SAW_SHIPPED" -eq 1 ]; then
    ok "1a  the control had a LIVE mutation in the shipped file when the kill was sent — it was not killed before it did anything"
else
    bad "1a  the control was killed mid-mutation" "no mutation was observed before the kill, so 1b cannot be attributed to the kill"
fi
if [ "$RK_DEAD" -eq 1 ]; then
    ok "1b  and kill -9 really killed it — this is a crash, not an early return dressed as one"
else
    bad "1b  the control process is dead" "it survived kill -9, so its EXIT trap may simply not have run yet"
fi
if grep -q THE_LOAD_BEARING_LINE "$FAKE_GUARD" 2>/dev/null; then
    bad "1c  THE CONTROL MUST COME OUT DAMAGED" "the old shape was killed mid-mutation and the shipped file is intact. This suite therefore cannot detect the damage it exists to detect, and its verdict in section 2 is worthless"
else
    ok "1c  DAMAGED, as it must be: the EXIT trap did not survive kill -9 and the shipped file is still mutated — this is the 2026-09-05 defect, reproduced"
fi
# Put the fixture back by hand; the harness could not.
printf '%s\n' "$GUARD_PRISTINE" > "$FAKE_GUARD"

# ---------------------------------------------------------------------------
# 2. THE NEW SHAPE: same kill, same moment, shipped file untouched.
# ---------------------------------------------------------------------------
NEW="$SANDBOX/new-shape.sh"
cat > "$NEW" <<NEWEOF
#!/usr/bin/env bash
set -uo pipefail
. "$FAKE_ENG/scripts/lib/mutation-harness.sh"
mutation_sandbox_engine "$FAKE_ENG"
G="\$MUT_SANDBOX_ENGINE/scripts/hooks/fake-guard.sh"
trap 'rm -rf "\$MUT_SANDBOX_DIR"' EXIT
grep -v THE_LOAD_BEARING_LINE "\$G" > "\$G.tmp" && mv "\$G.tmp" "\$G"
grep -q THE_LOAD_BEARING_LINE "\$G" || : > "$SANDBOX/mutation-was-applied"
sleep 120
NEWEOF
W_BEFORE="$(tw_file_witness "$FAKE_GUARD")"
rm -f "$SANDBOX/mutation-was-applied"
run_and_kill "$NEW"
if [ "$RK_SAW_SANDBOX" -eq 1 ]; then
    ok "2a  the new shape had a LIVE mutation in its SANDBOX when the kill was sent — so 2c is not the free pass you get by killing early"
else
    bad "2a  the new shape was killed mid-mutation" "no sandbox mutation was observed before the kill, so 'untouched' below proves nothing: it is what killing it before it started would also give"
fi
if [ "$RK_DEAD" -eq 1 ]; then
    ok "2b  and kill -9 really killed it — no EXIT trap ran"
else
    bad "2b  the new-shape process is dead" "it survived kill -9"
fi
W_AFTER="$(tw_file_witness "$FAKE_GUARD")"
if ! grep -q THE_LOAD_BEARING_LINE "$FAKE_GUARD" 2>/dev/null; then
    bad "2c  the shipped file is UNTOUCHED" "it was mutated: the new shape is writing to the shipped tree after all"
elif [ "$W_AFTER" != "$W_BEFORE" ]; then
    bad "2c  the shipped file is UNTOUCHED" "contents survived but the witness moved ($W_BEFORE -> $W_AFTER): it was opened for writing, and a kill in a narrower window could still have damaged it"
elif tw_mtime_available; then
    ok "2c  UNTOUCHED — contents AND mtime identical across a kill -9 that landed on a live mutation: the shipped file was never opened for writing"
else
    ok "2c  UNTOUCHED — contents identical across a kill -9 that landed on a live mutation. No sub-second mtime proved itself here, so this run cannot also rule out a write-and-restore; named rather than glossed"
fi

# ---------------------------------------------------------------------------
# 3. THE SANDBOX BUILDER REFUSES A SOURCE THAT IS NOT AN ENGINE.
#    A harness carrying on against an empty sandbox would report every mutant
#    "caught" by a guard that is not there — green over nothing, again.
# ---------------------------------------------------------------------------
EMPTY="$SANDBOX/not-an-engine"
mkdir -p "$EMPTY"
if ( . "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"; mutation_copy_engine "$SANDBOX/dest-a" "$EMPTY" ) 2>/dev/null; then
    bad "3a  mutation_copy_engine refuses a non-engine source" "it accepted a directory with no scripts/hooks and no orchestration.config"
else
    ok "3a  mutation_copy_engine refuses a source that is not a readable engine root"
fi
if ( . "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"; mutation_copy_engine "$SANDBOX/dest-b" "$FAKE_ENG" ) 2>/dev/null; then
    ok "3b  and accepts one that is — so 3a was the check firing, not the function being broken"
else
    bad "3b  mutation_copy_engine accepts a real engine root" "it refused the fixture engine, so 3a proves nothing"
fi
if [ -f "$SANDBOX/dest-b/scripts/hooks/fake-guard.sh" ] && [ -f "$SANDBOX/dest-b/orchestration.config" ]; then
    ok "3c  the copy carries the whole mechanical layer, not one file — the missing-dependency trap the old in-place harnesses cited"
else
    bad "3c  the copy carries the mechanical layer" "the sandbox is missing the guard or the config"
fi

# ---------------------------------------------------------------------------
# 4. STRUCTURAL, AND SAID TO BE STRUCTURAL: the two harnesses that carried the
#    defect use the sandbox. This is a proxy for sections 1-2, not a repeat of
#    them; their own M99 case is the run-time proof.
# ---------------------------------------------------------------------------
for h in guard-worktree-isolation guard-worktree-removal; do
    F="$ENGINE_ROOT/scripts/hooks/$h.mutation.sh"
    if [ ! -f "$F" ]; then
        bad "4  $h.mutation.sh exists" "not found at $F"
        continue
    fi
    if grep -q 'mutation_sandbox_engine' "$F"; then
        ok "4a  $h.mutation.sh builds a sandbox instead of mutating the shipped guard"
    else
        bad "4a  $h.mutation.sh builds a sandbox" "it does not call mutation_sandbox_engine, so it may be mutating the shipped tree again"
    fi
    # The old shape is recognizable by a GUARD assigned under the source engine
    # root. Matching the assignment rather than the word 'trap' keeps this
    # honest: the new shape still has a trap, and should.
    if grep -qE '^(GUARD|SUITE)="\$SRC_ENG/' "$F"; then
        bad "4b  $h.mutation.sh does not point GUARD at the shipped tree" "GUARD or SUITE resolves under SRC_ENG, which is the real engine root"
    else
        ok "4b  $h.mutation.sh points neither GUARD nor SUITE at the shipped tree"
    fi
    if grep -q 'SHIPPED_GUARD' "$F" && grep -q 'M99' "$F"; then
        ok "4c  $h.mutation.sh witnesses the shipped guard across its own run (M99)"
    else
        bad "4c  $h.mutation.sh witnesses the shipped guard (M99)" "no run-time check that it left the shipped file alone"
    fi
done

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
