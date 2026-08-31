#!/usr/bin/env bash
#
# unasked-deferral.mutation.sh — PROVES THE UNASKED-DEFERRAL SUITE CAN FAIL.
#
# 34 green ticks are evidence of nothing until somebody shows them turning red
# for the right reason. For a guard whose entire mechanism is a set of regular
# expressions, that is not a general anxiety — it is the specific way this kind
# of suite lies:
#
#   BREAK THE MATCHER AND EVERY SILENCE CASE GOES GREEN. Sections 3, 4 and 5 of
#   the suite are almost all "the hook says nothing". A matcher that matches
#   NOTHING AT ALL passes every one of them. So the suite carries positive
#   controls, and this file proves the controls are the thing holding it up:
#   the first mutant below deletes the notice entirely and the run must go red
#   at 1a, not merely somewhere.
#
# The method: take the shipped source, remove ONE property at a time, and assert
#   1. unasked-deferral.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied (a replacement matching nothing gives a
#      green run that looks like a green run, which is the same trap again).
#
# Every mutant is a throwaway copy of the engine subtree. Nothing here touches
# the real tree.
#
# Run directly: scripts/hooks/unasked-deferral.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t unasked-deferral-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
# THE NEWLINE TOKEN IS @@NL@@, NOT \n. The sibling mutation suites decode a
# literal backslash-n, which is correct for their targets and WRONG for these:
# every pattern in guard-unasked-deferral.py contains [^.\n], so a \n decoder
# silently corrupts the needle and every mutant reports "target absent". That is
# a mutation suite failing OPEN — it looks like drift and is actually the
# harness eating its own input.
old = old.replace("@@NL@@", "\n")
new = new.replace("@@NL@@", "\n")
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
    cp "$ENGINE_ROOT/scripts/hooks/notice-unasked-deferral.sh" \
       "$ENGINE_ROOT/scripts/hooks/guard-unasked-deferral.py" \
       "$ENGINE_ROOT/scripts/hooks/unasked-deferral.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" \
       "$ENGINE_ROOT/scripts/lib/seat-jurisdiction.sh" \
       "$ENGINE_ROOT/scripts/lib/stop-hook-notice.sh" "$dir/scripts/lib/"
    chmod +x "$dir/scripts/hooks/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1)); return
    fi

    bash "$dir/scripts/hooks/unasked-deferral.test.sh" >"$dir/out.txt" 2>&1
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

echo "=== the unasked deferral: every property, proven load-bearing by removing it ==="

H="scripts/hooks/notice-unasked-deferral.sh"
A="scripts/hooks/guard-unasked-deferral.py"

# --- 1. THE NOTICE ITSELF, AND THE POSITIVE CONTROLS UNDER THE SILENCES ----
mutant no-notice "1a " "$H" \
    'stop_notice_abnormal "$KEY" \' \
    'notice_clean; stop_notice_abnormal "$KEY" \' \
    "the whole point: a deferral he was not asked about must end the turn with something on screen."

mutant matcher-dead "1a " "$A" \
    '    scan = strip_quoted(text)' \
    '    scan = ""' \
    "a matcher that matches nothing passes every silence case in sections 3-5. This is the trap the positive controls exist for."

mutant unquoted-notice "1b " "$H" \
    'THIS TURN DEFERS WORK: \"${QUOTE}\"' \
    'THIS TURN DEFERS WORK.' \
    "quoting the construction is what makes the notice actionable rather than a scold — he can see the sentence he wrote."

mutant vague-notice "1c " "$H" \
    'A deferral you did not choose is a decision taken on your behalf' \
    'FYI' \
    "the notice must name the harm, not merely announce that something happened."

mutant blocking "1d " "$H" \
    'stop_notice_abnormal "$KEY" \' \
    'exit 2; stop_notice_abnormal "$KEY" \' \
    "a Stop hook that refuses turns over a regex on prose wedges the session and earns CHECK_UNASKED_DEFERRAL=0."

# --- 2. THE THREE DISCHARGES ----------------------------------------------
mutant no-ask-discharge "2a " "$A" \
    '    if "AskUserQuestion" in tools:' \
    '    if False and "AskUserQuestion" in tools:' \
    "putting the deferral to him IS the rule being satisfied; firing anyway punishes the correct behaviour."

mutant no-handback-discharge "2b " "$A" \
    '    if text and _HANDBACK.search(text):' \
    '    if False and _HANDBACK.search(text):' \
    "without it the guard fires on 12 corpus turns at 33% — including every turn where the CEO himself ordered the stop."

mutant no-agent-discharge "2d " "$A" \
    '    if "Agent" in tools:' \
    '    if False and "Agent" in tools:' \
    "condition 3 of the rule: a turn that starts the work is not a turn that deferred it."

# --- 3. PRECISION: the narrowings that keep ordinary prose silent ----------
# Every one of these is a measured decision from the 2,198-turn corpus, recorded
# in the analyzer's REFUSED table. Widening it back out must turn a specific
# silence case red — which is the only proof the narrowing was load-bearing
# rather than decorative.
mutant first-person-and-now-marker-dropped "3e " "$A" \
    '|I am)\s+[^.\n]{0,60}?\brather\s+than\s+" + _ACT +@@NL@@     r"\b[^.\n]{0,40}?\b" + _NOW + r"\b"),' \
    '|I am|)\s*" + r"\brather\s+than\s+" + _ACT + r"\b"),' \
    "'extending the CSV rather than adding a second ledger' is a DESIGN CHOICE. The first-person subject and the now-marker are what separate a choice from a postponement."

mutant bundle-object-dropped "3f " "$A" \
    '     r"(?:goes|go|will go|can go|would go|rides|ships|lands)\s+in\s+with\b"@@NL@@     r"[^.\n]{0,60}?\b(?:land|lands|landing|pass|spawn|batch|round|merge|"@@NL@@     r"deploy|commit)\b"),' \
    '     r"(?:goes|go|will go|can go|would go|rides|ships|lands)\s+in\s+with\b"),' \
    "'the fix goes in with the next pilot restart' was describing a checklist inside a document. The object has to be a unit of orchestration work."

mutant bare-deliberately-not "3g " "$A" \
    '    ("not-dispatching",' \
    '    ("deliberately-not", r"\bdeliberately\s+not\b"),@@NL@@    ("not-dispatching",' \
    "bare 'deliberately not' measured 4/23 on the corpus — the dominant use is the record's own 'Deliberately NOT open' heading."

mutant postponing-family-back "3h " "$A" \
    '    ("chose-not-to-start-now",' \
    '    ("postponing-it", r"\bI.?m\s+(?:holding|queueing|parking)\s+the\s+\w+\b"),@@NL@@    ("chose-not-to-start-now",' \
    "the family measured at 44% and then deleted: it fires on a plainly correct pipeline hold — holding a merge until three agents report."

# --- 4. QUOTED IS NOT USED ------------------------------------------------
mutant no-quote-strip "4a " "$A" \
    '    out = _DQUOTE.sub(blank, out)' \
    '    out = out' \
    "a turn describing this guard quotes its own triggers; a guard that fires on its own documentation is a guard that gets switched off."

mutant no-tick-strip "4c " "$A" \
    '    out = _TICK.sub(blank, out)' \
    '    out = out' \
    "backticked spec text is quotation, not speech."

# --- 5. VISIBLE STAND-DOWNS ------------------------------------------------
mutant silent-standdown "5a " "$H" \
    '    stop_notice_abnormal "stood-down" \' \
    '    true \' \
    "an opt-out the operator cannot see is a defense that decays into a rumour — a sentence this engine has already had to learn twice."

mutant silent-no-analyzer "5c " "$H" \
    '    stop_notice_abnormal "no-analyzer" \' \
    '    true \' \
    "a clean session and an absent checker must never look the same."

mutant silent-root-failure "5e " "$H" \
    '    stop_notice_abnormal "root-failure" \' \
    '    true \' \
    "a guard that cannot tell which repository it governs is not entitled to be quiet."

# --- 6. DE-DUPLICATION -----------------------------------------------------
# The first mutant here is a bug this suite ACTUALLY CAUGHT on its first run, not
# a hypothetical: the wrapper recorded "ok" before the analysis, so the ledger
# alternated between "ok" and the finding key and the same deferral was
# announced on every single turn.
mutant normal-before-analysis "6a " "$H" \
    'set +e@@NL@@FINDING="$(printf' \
    'stop_notice_normal "back"@@NL@@set +e@@NL@@FINDING="$(printf' \
    "the ledger holds ONE state per (session, hook); writing 'ok' on entry and the finding afterwards defeats de-duplication entirely."

mutant constant-state-key "6b " "$H" \
    'KEY="deferral:${CONSTRUCTION}:$(printf' \
    'KEY="deferral"; : "$(printf' \
    "a constant key mutes every SUBSEQUENT deferral in the session — the first one silences the rest."

# --- 7. THE TRANSCRIPT ----------------------------------------------------
mutant transcript-unknown-is-empty "7a " "$A" \
    '        return None  # UNKNOWN — never the same as "no tools used"' \
    '        return set()' \
    "an unreadable transcript is not a turn with no tools: treating it as one accuses turns whose discharges could not be read."

mutant no-stop-hook-active "7c " "$A" \
    '    if payload.get("stop_hook_active"):' \
    '    if False and payload.get("stop_hook_active"):' \
    "on a blocked turn's re-fire the text is unchanged; re-accusing piles a second notice onto a turn already in trouble."

echo ""
echo "=== $PASS proven load-bearing, $FAIL not ==="
[ "$FAIL" -eq 0 ]
