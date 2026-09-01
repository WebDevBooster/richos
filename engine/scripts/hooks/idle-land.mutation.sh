#!/usr/bin/env bash
#
# idle-land.mutation.sh — PROVES THE IDLE-LAND SUITE CAN FAIL.
#
# 57 green ticks are evidence of nothing until somebody shows them turning red
# for the right reason. That is not a general anxiety about this suite; it is
# the exact way this gate failed in production. It shipped on 2026-08-30 with a
# green 38-case suite and a measurement over 1,082 turns, and then blocked ONCE
# in 107 real landing turns — because the suite's negative case (c) asserted
# that a running background task stands the gate down, and nobody asked whether
# that assertion was DESIRABLE. A suite can only be as good as its willingness
# to be wrong.
#
# So: take the shipped source, remove ONE property at a time, and assert that
#   1. guard-idle-land.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied (a replacement that matched nothing gives
#      a green run that looks like a green run, which is the same trap again).
#
# Every mutant is a throwaway copy of the engine subtree. Nothing here touches
# the real tree.
#
# Run directly: scripts/hooks/idle-land.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t idle-land-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
# The needles arrive from a shell single-quoted string, so a multi-line target
# is written `a\nb`. Decoded here rather than in bash, where the quoting to
# carry a literal newline through three levels is its own bug.
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
    cp "$ENGINE_ROOT/scripts/hooks/guard-idle-land.sh" \
       "$ENGINE_ROOT/scripts/hooks/guard-idle-land.py" \
       "$ENGINE_ROOT/scripts/hooks/guard-idle-land.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" \
       "$ENGINE_ROOT/scripts/lib/stop-hook-notice.sh" "$dir/scripts/lib/"
    chmod +x "$dir/scripts/hooks/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1)); return
    fi

    bash "$dir/scripts/hooks/guard-idle-land.test.sh" >"$dir/out.txt" 2>&1
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

echo "=== idle-land gate: every property, proven load-bearing by removing it ==="

H="scripts/hooks/guard-idle-land.sh"
P="scripts/hooks/guard-idle-land.py"

# --- 1. IT BLOCKS ----------------------------------------------------------
mutant does-not-block "a." "$P" \
    '    return 2 if enforce else 0' \
    '    return 0' \
    "a gate that reports is a gate that has already failed this test."

# --- 2. THE SECOND COMPLETION SIGNAL --------------------------------------
mutant blind-to-teammate-finishes "AA." "$P" \
    '    finishes = agent_finishes(turn.get("notices"))' \
    '    finishes = []' \
    "the second of the two failures reported on 2026-09-01 was a finished teammate answered with a list."

mutant finish-ignores-the-summary-shape "AA2." "$P" \
    '        m = AGENT_FINISHED_RE.search(text)' \
    '        m = re.search(r"<summary>(?P<title>[^<]+)</summary>", text)' \
    "a finished BACKGROUND COMMAND arrives in the identical envelope; only the summary tells them apart."

mutant finish-ignores-the-word-finished "AA3." "$P" \
    '        m = AGENT_FINISHED_RE.search(text)' \
    '        m = re.search(r"<summary> *Agent +(?P<title>[^<]+)", text)' \
    "an agent the operator KILLED is not a delivery, and 'was stopped by user' is a different summary from 'finished'."

mutant finish-ignores-the-status "AA4." "$P" \
    '        if not COMPLETED_STATUS_RE.search(text):' \
    '        if False:' \
    "a notification for a failure or a cancelation is not work handed back."

# --- 3. THE DISARM MUST NOT COME BACK -------------------------------------
# The single most important mutation in this file. It restores the exact term
# that made the shipped gate fire once in 107 landing turns.
mutant running-tasks-stand-the-gate-down-again "c." "$P" \
    '    # TERM 3a. THE TURN PUT SOMETHING TO THE CEO. Ending a turn on a question he' \
    '    if running:\\n        log()\\n        return 0\\n\\n    # TERM 3a. THE TURN PUT SOMETHING TO THE CEO. Ending a turn on a question he' \
    "this IS the defect: 44 of 107 real landing turns were waved through by it."

mutant backgrounding-is-not-starting "AD." "$P" \
    '    if turn.get("backgrounded"):' \
    '    if False:' \
    "a tool call sent to the background is the turn handing work off, which is what the rule asks for."

# --- 4. NOTHING IS OWED TO THE CEO ----------------------------------------
mutant asking-him-does-not-count "AB." "$P" \
    '    if "AskUserQuestion" in turn["tools"]:' \
    '    if False and "AskUserQuestion" in turn["tools"]:' \
    "ending a turn on a question he has to answer is the one move nobody else can make for him."

mutant off-duty-is-not-a-hold "AC." "$P" \
    '    m = OFF_DUTY_RE.search(text)' \
    '    m = None' \
    "'I am going to bed' is a different claim from 'hold', and it is how a night actually ends."

# --- 5. THE DECLARATION ---------------------------------------------------
mutant declaration-ignored "AE." "$P" \
    '    m = DECLARATION_RE.search(text)' \
    '    m = None' \
    "without a route through, a blocking gate with any false-positive class gets unwired within a day."

mutant bare-marker-accepted "AE2." "$P" \
    'MIN_DECLARATION_WORDS = 6' \
    'MIN_DECLARATION_WORDS = 0' \
    "A BARE MARKER EXEMPTS NOTHING — otherwise the declaration is a flag with a longer spelling."

# The two floors are two properties. This run is why: with only one fixture,
# zeroing the word floor left the suite green because the character floor was
# still catching the same string.
mutant short-reason-accepted "AE2b." "$P" \
    'MIN_DECLARATION_CHARS = 30' \
    'MIN_DECLARATION_CHARS = 0' \
    "'it is not worth it now' clears six words and says nothing; the character floor is what catches it."

mutant any-case-accepted "AE3." "$P" \
    '    if case not in DECLARED_CASES:' \
    '    if False:' \
    "an open set accepts 'stop-declared: reasons', and then it is a flag again."

mutant code-spans-not-stripped "AE4." "$P" \
    '    text = CODE_SPAN_RE.sub(" ", message)' \
    '    text = message' \
    "the refusal PRINTS the declaration line indented; without the strip, pasting it back switches the gate off."

# The second defense against a quoted declaration, and the run that made this
# file worth writing: the ORIGINAL AE4 fixture put the quote mid-sentence, where
# the line anchor caught it, so removing the code-span strip changed nothing and
# the suite stayed green over a defense that was not being tested.
mutant declaration-need-not-start-a-line "AE4b." "$P" \
    '    r"^[ \t>*\-\u2022]*stop-declared:[ \t]*(?P<case>[A-Za-z][A-Za-z0-9-]{2,40})"' \
    '    r"[ \t>*\-\u2022]*stop-declared:[ \t]*(?P<case>[A-Za-z][A-Za-z0-9-]{2,40})"' \
    "a declaration DESCRIBED in a sentence is not a declaration made; the line anchor is what says so."

mutant declaration-not-shown-to-him "c3b." "$H" \
    'if [ -n "$DECLARED_LINE" ]; then' \
    'if [ -z "$DECLARED_LINE" ]; then' \
    "a justification filed where nobody reads it is exactly the flag this was designed not to be."

# --- 6. THE REFUSAL IS PART OF THE DELIVERABLE ----------------------------
mutant refusal-does-not-say-what-is-available "AF1." "$P" \
    '    out.append("  UNBLOCKED AND AVAILABLE TO START — %d row(s) in %s (%s)"' \
    '    out.append("  There is work outstanding. — %d row(s) in %s (%s)"' \
    "a refusal that says only 'you stopped early' rebuilds the problem one level up."

mutant refusal-does-not-give-the-exact-line "AF1." "$P" \
    '    out.append("           stop-declared: <case> — <why, in a full sentence>")' \
    '    out.append("           (declare the stop in the documented form)")' \
    "an escape described but not spelled is an escape that gets waived by guesswork."

echo
if [ "$FAIL" -eq 0 ]; then
    printf '✓ %d/%d properties are load-bearing\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '✗ %d/%d — %d propert(ies) are NOT load-bearing\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
exit 1
