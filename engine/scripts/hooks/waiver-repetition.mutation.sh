#!/usr/bin/env bash
#
# waiver-repetition.mutation.sh — PROVES THE WAIVER-REPETITION SUITE CAN FAIL.
#
# ===========================================================================
# WHY THIS FILE EXISTS, AND THE TRAP IT IS BUILT AROUND
# ===========================================================================
# 27 green ticks are evidence of nothing until somebody shows them turning red
# for the RIGHT REASON. This mechanism is unusually exposed to that, because
# half its properties are of the form "it stayed quiet" — and a test for
# staying quiet passes for free, including when the thing under test never ran.
#
# Worse, the same trap has already been sprung on a mutation harness in this
# engine: one killed 11 of its 18 mutants because the sandboxes it built were
# missing a dependency, so the guard REFUSED TO START and its refusal was
# scored as "the mutation was caught". Every mutant looked killed; nothing was
# being tested.
#
# So this harness runs a CONTROL FIRST: an unmutated sandbox, built by the same
# function every mutant uses, must run the suite to 0 failures. If the control
# is red the harness stops and says so, rather than reporting a wall of kills
# earned by a broken sandbox. Then, per mutant:
#
#   1. the mutation must APPLY (a replacement matching nothing gives a green
#      run that looks like a green run — the same trap one level up),
#   2. the suite must FAIL, and
#   3. the SPECIFIC named case must fail, not merely "something went red".
#
# Every mutant is a throwaway copy of the engine subtree. Nothing here touches
# the real tree.
#
# Run directly: scripts/hooks/waiver-repetition.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t waiver-repetition-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# build <dir> — an engine subtree the suite can run against, unmutated.
build() {
    local dir="$1"
    mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib" "$dir/hooks"
    cp "$ENGINE_ROOT/scripts/hooks/notice-waiver-repetition.sh" \
       "$ENGINE_ROOT/scripts/hooks/notice-waiver-repetition.py" \
       "$ENGINE_ROOT/scripts/hooks/waiver-repetition.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" \
       "$ENGINE_ROOT/scripts/lib/seat-jurisdiction.sh" \
       "$ENGINE_ROOT/scripts/lib/stop-hook-notice.sh" "$dir/scripts/lib/"
    cp "$ENGINE_ROOT/scripts/waiver-repetition-lint.sh" "$dir/scripts/"
    cp "$ENGINE_ROOT/hooks/hooks.json" "$dir/hooks/hooks.json"
    chmod +x "$dir/scripts/hooks/"*.sh "$dir/scripts/"*.sh
}

# ---------------------------------------------------------------------------
# THE CONTROL. Same builder, no mutation. If this is not clean, every kill
# below is worthless and the harness must say so instead of counting them.
# ---------------------------------------------------------------------------
echo "=== waiver-repetition.mutation.sh ==="
echo ""
CTRL="$SANDBOX/control"
build "$CTRL"
bash "$CTRL/scripts/hooks/waiver-repetition.test.sh" >"$CTRL/out.txt" 2>&1
CTRL_RC=$?
if [ "$CTRL_RC" -ne 0 ]; then
    echo "  FATAL: the CONTROL sandbox is already red, so no kill below would mean anything."
    echo "         This is the exact failure that scored 11 phantom kills in another harness:"
    echo "         a sandbox missing a dependency makes the subject refuse to start, and a"
    echo "         refusal reads as a catch."
    grep '  FAIL' "$CTRL/out.txt" | sed 's/^/         /'
    exit 1
fi
CTRL_N="$(grep -c '  PASS' "$CTRL/out.txt")"
printf '  CONTROL  unmutated sandbox: %s cases pass, 0 fail — kills below are real\n\n' "$CTRL_N"

# mutant <name> <expected-failing-case> <rel-file> <old> <new> <why>
mutant() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"
    build "$dir"

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1)); return
    fi

    bash "$dir/scripts/hooks/waiver-repetition.test.sh" >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        FAIL=$((FAIL + 1)); return
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at %s (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        FAIL=$((FAIL + 1)); return
    fi
    printf '  PASS  %s — removing it turns "%s" red\n' "$name" "$want"
    PASS=$((PASS + 1))
}

PY_REL="scripts/hooks/notice-waiver-repetition.py"
SH_REL="scripts/hooks/notice-waiver-repetition.sh"
LINT_REL="scripts/waiver-repetition-lint.sh"
JSON_REL="hooks/hooks.json"

# --- the verdict rule ------------------------------------------------------
# EVERY CONSTANT BELOW IS ANCHORED ON THE LINE THAT FOLLOWS IT. MIN_CLASS,
# JACCARD and ACTIVE_DAYS each appear FIRST in the analyzer's docstring, where
# they are argued — so a first-occurrence replacement rewrote the PROSE and left
# the code untouched, and all three mutants survived while looking applied. That
# is the same class of failure this harness exists to catch, arriving one level
# up, and it is written down here rather than quietly fixed.
mutant "verdict-always-true" "1. ONE considered waiver" "$PY_REL" \
    '    """The whole verdict, in one place, so a reader can check it against the
    docstring without tracing call sites."""' \
    '    """The whole verdict, in one place, so a reader can check it against the
    docstring without tracing call sites."""
    return True' \
    "with no verdict at all, a SINGLE considered waiver is reported as a broken guard — the quiet side is a decision, not an accident of the data."

mutant "min-class-raised" "3. THREE waivers" "$PY_REL" \
    "MIN_CLASS = 3
JACCARD" "MIN_CLASS = 99
JACCARD" \
    "with the floor out of reach nothing is ever surfaced, and the suite would be green over a checker that reports nothing."

mutant "min-class-lowered" "2. TWO waivers" "$PY_REL" \
    "MIN_CLASS = 3
JACCARD" "MIN_CLASS = 1
JACCARD" \
    "at a floor of one, a single considered exception is reported as a broken guard, which is how a notice earns being muted."

mutant "grouping-exact" "4. the same reason RETYPED" "$PY_REL" \
    "JACCARD = 0.35
ACTIVE_DAYS" "JACCARD = 0.99
ACTIVE_DAYS" \
    "at 0.99 only near-identical strings group, so the 226-distinct-strings case goes unseen — the exact failure that makes byte-matching useless here."

# NOT the similarity test itself: candidate pairs come from an inverted index,
# so entries sharing no token are never compared and `if True:` changes nothing.
# The mutation has to reach the grouping, which is what actually decides.
mutant "grouping-everything" "5. three DIFFERENT reasons" "$PY_REL" \
    "    for i in range(n):
        groups[find(i)].append(i)" \
    "    for i in range(n):
        groups[0].append(i)" \
    "a grouping that puts everything in one class merges reasons sharing nothing, and every ledger becomes one giant false finding."

mutant "independence-dropped" "6. one day, ONE subject" "$PY_REL" \
    'independent = cls["days"] >= 2 or cls["subjects"] >= 2' \
    "independent = True" \
    "without the independence test, one act restated three times reads as three independent failures of the guard."

mutant "window-removed" "8. a class last used 30 days ago" "$PY_REL" \
    "ACTIVE_DAYS = 14
MAX_LINES" "ACTIVE_DAYS = 100000
MAX_LINES" \
    "with no activity window a guard that was FIXED keeps being reported forever, which is precisely how this notice would become the line nobody reads."

mutant "double-fire-counted" "9. four lines that are two acts" "$PY_REL" \
    "            if line in seen:" "            if False:" \
    "counting a host's double-fired duplicate as a second act turns every pair into a class and every quiet ledger loud."

# --- discovery -------------------------------------------------------------
mutant "everything-is-a-hatch" "10. the hatch is derived" "$PY_REL" \
    "            hatch = bool(HATCH_VOCAB.search(context))" \
    "            hatch = True" \
    "if every appended file is a hatch, plain event ledgers get analyzed and the report fills with findings about records nobody can waive."

mutant "empty-scan-is-quiet" "12. an engine with no append site" "$PY_REL" \
    '        notes.append(
            "read %d engine scripts and found NO append site at all — the "
            "discovery scan is broken, not the engine" % len(files))' \
    "        pass" \
    "a discovery scan that matches nothing would report a clean engine — the same shape that left a probe layer green over a scanner that never started."

mutant "orphans-dropped" "11. a ledger no guard claims" "$PY_REL" \
    '            report["unattributed_on_disk"].append(fn)' \
    "            pass" \
    "dropping the ledgers no guard claims makes a broken deriver look like a cleaner report, which is the failure mode of every derived inventory."

# --- the notice channel ----------------------------------------------------
mutant "state-key-frozen" "14. the state key is stable" "$PY_REL" \
    '    return "repeated:" + ",".join(parts)' \
    '    return "repeated"' \
    "a state key that never changes means the operator is told once and never again, however far the problem grows."

mutant "no-recovery-line" "15c. a recovery is announced" "$SH_REL" \
    '    stop_notice_normal \
        "WAIVER-REPETITION WATCH: clear again — no escape hatch is being used repeatedly for the same reason."' \
    '    stop_notice_normal ""' \
    "without the recovery line the operator's last-seen state is stale forever, and silence stops meaning no-change."

mutant "quiet-without-analyzer" "16. no analyzer" "$SH_REL" \
    '    stop_notice_abnormal "no-analyzer" \
        "WAIVER-REPETITION WATCH IS OFF: scripts/hooks/notice-waiver-repetition.py is missing, so no escape-hatch ledger was read. This hook decides nothing on its own — without the analyzer it is wiring around an empty space."
    exit 0' \
    "    exit 0" \
    "a wrapper that goes quiet without its analyzer is wired, hashed, executable and reading nothing — and looks exactly like a clean turn."

# --- the operator surfaces -------------------------------------------------
mutant "lint-always-clean" "18. the lint shows its work" "$LINT_REL" \
    'exit "$RC"' "exit 0" \
    "a lint that always exits 0 cannot be wired into anything, and 'no repeated waiver' becomes indistinguishable from 'nothing was read'."

mutant "unregistered" "19. notice-waiver-repetition.sh is registered" "$JSON_REL" \
    '${CLAUDE_PLUGIN_ROOT}/scripts/hooks/notice-waiver-repetition.sh' \
    '${CLAUDE_PLUGIN_ROOT}/scripts/hooks/notice-nothing-at-all.sh' \
    "a hook on disk and in no hook table never runs, and this engine has shipped that exact state before."

# --- the property that keeps it from becoming what it reports --------------
mutant "marker-honored" "20b. a marker inside the waivers" "$PY_REL" \
    '    line = line.rstrip("\n")' \
    '    line = line.rstrip("\n")
    if "waiver-repetition-ack" in line:
        return None' \
    "the moment a marker in the ledger can suppress a finding, this mechanism has grown the escape hatch it exists to report, and it would be waived like the other 228."

echo ""
echo "  $PASS mutants killed, $FAIL survived"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
