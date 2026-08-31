#!/usr/bin/env bash
#
# ceo-asks.mutation.sh — PROVES THE CEO-ASK SUITE CAN FAIL.
#
# 46 green ticks are evidence of nothing until somebody shows them turning red
# for the right reason. That is not a general anxiety: the whole mechanism this
# suite covers exists because a set of guards was GREEN over a session in which
# the CEO was never asked anything. A suite that passed over a gutted gate would
# be the same defect, one layer in.
#
# So: take the SHIPPED source, remove ONE property at a time, and assert that
#   1. ceo-asks.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied (a replacement that matched nothing gives a
#      green run that looks like a green run, which is the same trap again).
#
# Every mutant is a throwaway copy of the engine subtree. Nothing here touches
# the real tree.
#
# Run directly: scripts/hooks/ceo-asks.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t ceo-asks-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
# The needles arrive from a shell single-quoted string, so a multi-line target
# is written `a\nb`. Decoded here rather than in bash, where the quoting to
# carry a literal newline through three levels is its own bug. A CONSEQUENCE,
# stated because it bit once: a needle may not contain the two characters
# backslash-n as data.
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# mutant <name> <expected-failing-case> <rel-file> <old> <new> <why>
mutant() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"
    mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib" "$dir/hooks"
    cp "$ENGINE_ROOT/scripts/hooks/notice-ceo-asks.sh" \
       "$ENGINE_ROOT/scripts/hooks/guard-ceo-ask-first.sh" \
       "$ENGINE_ROOT/scripts/hooks/notice-ceo-unasked.sh" \
       "$ENGINE_ROOT/scripts/hooks/session-start-ceo-ask.sh" \
       "$ENGINE_ROOT/scripts/hooks/ceo-asks.test.sh" \
       "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" \
       "$ENGINE_ROOT/scripts/hooks/install.sh" \
       "$ENGINE_ROOT/scripts/hooks/notice-unstarted-rows.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/ceo-asks.sh" "$ENGINE_ROOT/scripts/lib/ceo-asks.py" \
       "$ENGINE_ROOT/scripts/lib/ceo-todos.sh" "$ENGINE_ROOT/scripts/lib/ceo-todos.py" \
       "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" \
       "$ENGINE_ROOT/scripts/lib/stop-hook-notice.sh" \
       "$ENGINE_ROOT/scripts/lib/cold-open-prompt.md" "$dir/scripts/lib/"
    cp "$ENGINE_ROOT/scripts/ceo-asks-status.sh" "$dir/scripts/"
    cp "$ENGINE_ROOT/hooks/hooks.json" "$dir/hooks/"
    chmod +x "$dir/scripts/hooks/"*.sh "$dir/scripts/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1)); return
    fi

    bash "$dir/scripts/hooks/ceo-asks.test.sh" >"$dir/out.txt" 2>&1
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
    printf '  PASS  %s — removing it turns %s red\n' "$name" "$want"
    PASS=$((PASS + 1))
}

echo "=== the CEO-ask gate: every property, proven load-bearing by removing it ==="

PY="scripts/lib/ceo-asks.py"
LIB="scripts/lib/ceo-asks.sh"
W="scripts/hooks/notice-ceo-asks.sh"
G="scripts/hooks/guard-ceo-ask-first.sh"
N="scripts/hooks/notice-ceo-unasked.sh"
S="scripts/hooks/session-start-ceo-ask.sh"

# --- 1. THE ANTI-GAMING PROPERTY -------------------------------------------
# First, because it is the one the whole design rests on.
mutant everything-matches "C3. " "$PY" \
    'return hits >= needed, score, hits, needed, "title"' \
    'return True, score, hits, needed, "title"' \
    "if any question matches something, one junk question per session clears the gate forever."

mutant worker-discharges "C4. " "$W" \
    '"discharges": bool(verdict == "MATCH" and not agent_id),' \
    '"discharges": bool(verdict == "MATCH"),' \
    "any subagent asking any clarifying question would hand the session a free discharge."

mutant no-session-filter "C5. " "$LIB" \
    'if not sid or str(rec.get("session_id") or "") != sid:' \
    'if False:' \
    "a question put to him yesterday did not reach the person who opened a session today."

mutant blocked-counts-as-prepared "A5. " "$PY" \
    'prepared = [i for i in items if (i.get("state") or "") == ready_state]' \
    'prepared = list(items)' \
    "demanding that an UNPREPARED item be put to him is the failure the CEO-TODOs contract exists to stop, arriving from the other side."

# --- 2. THE BLOCK ----------------------------------------------------------
mutant gate-does-not-block "C1. " "$G" \
    '} >&2\nexit 2' \
    '} >&2\nexit 0' \
    "the CEO ruled BLOCK, not notify. A gate that exits 0 is the option he did not take."

mutant no-escape-hatch "C6. " "$G" \
    'if [ -n "$DEFER_MARKER" ]; then' \
    'if [ -n "" ]; then' \
    "when he says get on with it, nothing may wedge — and the deferral must be on the record."

mutant bare-defer-permits "C7. " "$G" \
    '[[:space:]]*[^[:space:]].*"' \
    '.*"' \
    "a bare token is something a reflex types; a reason is something a person writes."

mutant broken-fails-closed "C10. " "$G" \
    'UNGATED, and a declared-but-unreadable list is not an empty one."\n        exit 0 ;;' \
    'UNGATED, and a declared-but-unreadable list is not an empty one."\n        exit 2 ;;' \
    "a guard that wedges every dispatch over its own plumbing is a guard that gets switched off."

# --- 3. THE WITNESS --------------------------------------------------------
mutant no-ledger-write "B1. " "$W" \
    'with open(os.environ["CA_LEDGER"], "a", encoding="utf-8") as fh:' \
    'if False:' \
    "the ledger IS the evidence; without it nothing can ever discharge and the gate becomes a wall."

# --- 4. THE NOTICES --------------------------------------------------------
mutant notice-counts-not-names "D1. " "$N" \
    '"HE HAS NOT BEEN ASKED — CEO TODO ${TOP_ID}: ${TOP_ASK}${MORE}' \
    '"HE HAS NOT BEEN ASKED — ${CA_UNASKED} items outstanding.${MORE}' \
    "a count is what got demoted on 2026-08-31; a specific question is what got answered."

mutant notice-blocks-the-turn "D1. " "$N" \
    'stop_notice_abnormal "unasked:$IDS" \' \
    'exit 2; stop_notice_abnormal "unasked:$IDS" \' \
    "a turn that ends to answer him is a turn ending correctly; refusing those gets the hook switched off."

mutant broken-list-is-quiet "D4. " "$N" \
    'are UNGATED and no prepared decision is being surfaced' \
    'are fine and no prepared decision is being surfaced' \
    "a declared-but-unreadable list must be loud on the one channel measured to reach the operator."

mutant session-start-silent "E2. " "$S" \
    '| head -1)"\nTOP_ID=' \
    '| head -0)"\nTOP_ID=' \
    "opening with a nameless announcement is opening with a count, which is the thing that failed."

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "  $PASS/$PASS properties proven load-bearing"
    exit 0
fi
echo "  $PASS proven, $FAIL SURVIVED — a surviving mutant is a property nothing checks"
exit 1
