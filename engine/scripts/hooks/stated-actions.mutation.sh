#!/usr/bin/env bash
#
# stated-actions.mutation.sh — PROVES THE STATED-ACTIONS SUITE CAN FAIL.
#
# A green suite is evidence of nothing until it has been shown turning red for
# the right reason. This gate's two arms are both the two-sided kind a corpse
# satisfies: "a stated-but-untaken action is refused" is passed by a gate that
# refuses everything, and "a same-turn dispatch is let through" by one that
# refuses nothing. So every property below is removed from a throwaway copy of
# the shipped source, one at a time, and the suite must go red AT THE NAMED
# CASE — not merely somewhere.
#
# Three things are asserted per mutant:
#   1. guard-stated-actions.test.sh FAILS,
#   2. the SPECIFIC case fails (a red elsewhere is an unrelated red),
#   3. the mutation actually applied (a needle that matched nothing gives a
#      green run that looks like a green run, which is the same trap again).
#
# Every mutant is a copy of the engine subtree under a temp dir. Nothing here
# touches the real tree.
#
# Run directly: scripts/hooks/stated-actions.mutation.sh
# Run by:       scripts/hooks/contract-integrity.test.sh (case SA2)
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t stated-actions-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
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
    mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/scripts/hooks/guard-stated-actions.sh" \
       "$ENGINE_ROOT/scripts/hooks/guard-stated-actions.py" \
       "$ENGINE_ROOT/scripts/hooks/guard-stated-actions.test.sh" \
       "$ENGINE_ROOT/scripts/hooks/turn-manifest.py" \
       "$ENGINE_ROOT/scripts/hooks/guard-idle-land.py" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" \
       "$ENGINE_ROOT/scripts/lib/stop-hook-notice.sh" "$dir/scripts/lib/"
    chmod +x "$dir/scripts/hooks/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1)); return
    fi

    bash "$dir/scripts/hooks/guard-stated-actions.test.sh" >"$dir/out.txt" 2>&1
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

echo "=== stated-actions gate: every property, proven load-bearing by removing it ==="

H="scripts/hooks/guard-stated-actions.sh"
P="scripts/hooks/guard-stated-actions.py"

# --- 1. IT BLOCKS ----------------------------------------------------------
mutant does-not-block "a." "$P" \
    '    return 2 if enforce else 0' \
    '    return 0' \
    "a gate that reports is a gate that has already failed this test."

mutant enforce-flag-ignored "y." "$P" \
    '    return 2 if enforce else 0' \
    '    return 2' \
    "report-only exists so an adopter can read its own numbers before arming it; a flag that does nothing is a lie in the config."

# --- 2. ARM 1: WHAT IS READ, AND WHAT IS NOT ------------------------------
mutant list-items-scanned "f." "$P" \
    '                or LIST_LINE_RE.match(line) or TABLE_LINE_RE.match(line)):' \
    '                or TABLE_LINE_RE.match(line)):' \
    "a bulleted plan is not a statement; 4 of the 13 corpus false fires were list items."

mutant fences-not-stripped "e2." "$P" \
    '    text = FENCE_RE.sub(" ", message)' \
    '    text = message' \
    "an ecs record carries the sentence as before=\"...\"; scanning it would refuse the correction turn."

mutant quotes-not-stripped "e." "$P" \
    '    text = DQUOTE_RE.sub(" ", text)' \
    '    text = text' \
    "the refusal prints the clause in quotes; without the strip, pasting it back re-fires the gate."

mutant reported-speech-scanned "e3." "$P" \
    '            or REPORTED_RE.search(sentence) or PROPOSAL_RE.search(sentence)' \
    '            or PROPOSAL_RE.search(sentence)' \
    "'Frank breaks it first, I said' is the apology, and a gate that fires on the apology punishes the fix."

mutant report-verbs-not-excluded "g." "$P" \
    '            if m and m.group("verb").lower() not in REPORT_VERBS:' \
    '            if m:' \
    "'Frank recommends the hybrid' is an agent's output; 6 of the 13 corpus false fires were report verbs."

mutant bare-object-accepted "h." "$P" \
    '    return re.compile(r"^(?P<role>" + alt + r")\s+(?P<verb>[a-z]+s)\s+" + OBJECT, re.S)' \
    '    return re.compile(r"^(?P<role>" + alt + r")\s+(?P<verb>[a-z]+s)\s+", re.S)' \
    "'Art designs Bootstrap components' describes a craft; the pronoun/determiner object is what makes it an act."

mutant proposal-not-excluded "d." "$P" \
    '            or REPORTED_RE.search(sentence) or PROPOSAL_RE.search(sentence)' \
    '            or REPORTED_RE.search(sentence)' \
    "all 10 raw 1b fires in the corpus were 'Say the word and I'll dispatch it'."

mutant ends-on-ceo-ignored "i." "$P" \
    '    if claims and ends_on_ceo(message):' \
    '    if False:' \
    "a plan stated above a question to the CEO is a proposal, and the turn may end on his answer."

mutant conditional-clause-scanned "o." "$P" \
    '    if SUBORD_RE.search(clause) or (progress and PROGRESS_RE.search(clause)):' \
    '    if (progress and PROGRESS_RE.search(clause)):' \
    "'Frank breaks it the moment Sage returns' is a condition, not an announcement."

mutant progress-marker-ignored "f2." "$P" \
    '    if SUBORD_RE.search(clause) or (progress and PROGRESS_RE.search(clause)):' \
    '    if SUBORD_RE.search(clause):' \
    "'Zach builds it — in flight now' is a liveness claim, owned report-only by the state-claims guard."

mutant negation-ignored "p." "$P" \
    '    if (NEG_RE.search(sentence) or MODAL_RE.search(sentence) or PAST_RE.search(sentence)' \
    '    if (MODAL_RE.search(sentence) or PAST_RE.search(sentence)' \
    "'Frank breaks it, but not tonight' is a deferral, and the deferral notice owns it."

mutant emphasized-list-scanned "f3." "$P" \
    'LIST_LINE_RE = re.compile(r"^[ \t]*[*_]{0,3}(?:[-*+•]|\d{1,3}[.)])[ \t]")' \
    'LIST_LINE_RE = re.compile(r"^[ \t]*(?:[-*+•]|\d{1,3}[.)])[ \t]")' \
    "'**1. Zach builds it — in flight now.**' was the replay's own false fire; the emphasis hid the number."

mutant role-future-blocks "j." "$P" \
    '                (reported if arm == "role-future" else unmet).append((who, clause, arm))' \
    '                unmet.append((who, clause, arm))' \
    "the role-future shape measured 0 true in 2 fires; it reports, and a blocking version is the 17% gate rebuilt."

# --- 3. ARM 1: WHAT DISCHARGES A CLAIM -----------------------------------
mutant any-agent-does-not-discharge-1a "b2." "$P" \
    '            if arm != "first-person-dispatch" or inp is None:' \
    '            if inp is None:' \
    "role-matching 1a fired on 'Sage is designing that now ... Zach builds it.' in the turn that spawned Sage — a plan in motion."

mutant any-agent-discharges-1b "c2." "$P" \
    '            if arm != "first-person-dispatch" or inp is None:' \
    '            if True:' \
    "'I'm dispatching Frank' names who; a spawn of somebody else does not make it true."

mutant teammate-message-does-not-discharge "b3." "$P" \
    '            if not to or to not in ("team-lead", "main", "lead"):' \
    '            if False:' \
    "a resumed teammate is a dispatch; refusing it would refuse the turn that did the work."

mutant ask-does-not-exempt "k." "$P" \
    '        if name == "AskUserQuestion":\n            return "ceo-asked"' \
    '        if name == "AskUserQuestion":\n            pass' \
    "ending a turn on a question he has to answer is the one move nobody else can make for him."

mutant turn-not-scoped "l." "$P" \
    '        calls, inputs, err = turn_calls(tm, transcript, prompt_id)' \
    '        calls, inputs, err = turn_calls(tm, transcript, None)' \
    "the sibling that read session-wide was inverted for weeks: after the first spawn, every turn 'called Agent'."

# --- 4. ARM 2: EVERY TERM ---------------------------------------------------
mutant arm2-does-not-block "n." "$P" \
    '    undeclared = stop is not None and stop["verdict"] == "undeclared-stop"' \
    '    undeclared = False' \
    "six times in one day the CEO restarted work that paused on a report; a notice would be the reaper's CLEAN again."

mutant arm2-ignores-agent-call "n2." "$P" \
    '    if "Agent" in turn["tools"]:\n        return {"finishes": finishes, "verdict": "started", "detail": "Agent"}' \
    '    if False:\n        return {"finishes": finishes, "verdict": "started", "detail": "Agent"}' \
    "the turn that landed a design and spawned its reviewer is the turn this rule asks for."

mutant arm2-ignores-background "n3." "$P" \
    '    if turn.get("backgrounded"):' \
    '    if False:' \
    "a tool call sent to the background is the turn handing work off."

mutant arm2-ignores-ask "n4." "$P" \
    '    if "AskUserQuestion" in turn["tools"]:\n        return {"finishes": finishes, "verdict": "ceo-owed", "detail": "AskUserQuestion"}' \
    '    if False:\n        return {"finishes": finishes, "verdict": "ceo-owed", "detail": "AskUserQuestion"}' \
    "a question to the CEO is owed an answer, and refusing that turn demands a dispatch over his head."

mutant arm2-ignores-hold "n5." "$P" \
    '    hold = idle.hold_signal(turn.get("said"))' \
    '    hold = None' \
    "'hold everything' in his own words is the operator taking the turn; the gate must not overrule him."

mutant arm2-ignores-declaration "n6." "$P" \
    '    if decl and decl.get("ok"):' \
    '    if False:' \
    "without a route through, a blocking gate with any legitimate-stop class gets unwired within a day."

mutant finish-signal-reads-any-notice "n9." "$P" \
    '    finishes = idle.agent_finishes(turn.get("notices"))' \
    '    finishes = ["Break the elimination design"] if turn.get("notices") else []' \
    "a killed agent and a finished shell arrive in the same envelope; only the summary shape tells them apart."

mutant declaration-not-shown-to-him "n6." "$H" \
    'if [ -n "$DECLARED_LINE" ]; then' \
    'if [ -z "$DECLARED_LINE" ]; then' \
    "a justification filed where nobody reads it is a flag with a longer spelling."

mutant refusal-lacks-the-declaration-form "n." "$P" \
    '        out.append("           stop-declared: <case> — <why, in a full sentence>")' \
    '        out.append("           (declare the stop in the documented form)")' \
    "an escape described but not spelled is an escape that gets waived by guesswork."

# --- 5. THE WRAPPER'S OWN STAND-DOWNS ARE SEEN ----------------------------
mutant stood-down-silently "t." "$H" \
    'if [ "$CHECK_STATED_ACTIONS" = "0" ]; then' \
    'if false; then' \
    "an opt-out that cannot be seen is a defense that decays into a rumor."

mutant missing-dependency-not-announced "y2." "$H" \
    'for _DEP in turn-manifest.py guard-idle-land.py; do' \
    'for _DEP in turn-manifest.py; do' \
    "with guard-idle-land.py gone ARM 2 decides nothing and the wrapper would start perfectly and exit 0 every turn."

echo
if [ "$FAIL" -eq 0 ]; then
    printf '✓ %d/%d properties are load-bearing\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '✗ %d/%d — %d propert(ies) are NOT load-bearing\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
exit 1
