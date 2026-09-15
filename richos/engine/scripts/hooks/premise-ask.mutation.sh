#!/usr/bin/env bash
#
# premise-ask.mutation.sh — PROVES THE PREMISE-CHECK SUITE CAN FAIL.
#
# This check refuses nothing, so its suite is not protecting a verdict — it is
# protecting the three properties that make an interrupting check survivable at
# all, and every one of them fails SILENTLY and looks exactly like working:
#
#   * FIRES ONCE. A check that fired on the re-issue would trap the revision it
#     asked for; a check that never fired would be a comment.
#   * STANDS DOWN WHERE IT HAS NO BUSINESS. A worker's question, and a
#     repository with no CEO in it.
#   * KEEPS THE LEDGER HONEST. `reissue` is the only number that can ever
#     justify making this stronger or deleting it, and it dies to a JSON
#     separator — which is not hypothetical, it was the state of this code
#     until the first smoke test read the ledger back.
#
# The harness is scripts/lib/mutation-harness.sh — one loop, shared. Run
# directly, or let premise-ask.test.sh run it, which it does.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "the premise check" "scripts/hooks/premise-ask.test.sh"

LIB="scripts/lib/premise-ask.sh"
PY="scripts/lib/premise-ask.py"
GATE="scripts/hooks/guard-ceo-ruled-ask.sh"

# --- 1. IT FIRES AT ALL ----------------------------------------------------
mutant always-stood-down "1a." "$LIB" \
    '    [ -f "$f" ] || return 1' \
    '    [ -f "$f" ] || return 0' \
    "the stand-down would read as active before any check had ever fired, so no question would ever be examined and the whole check would be a comment that reports itself as installed."

# --- 2. ...AND IT FIRES ONCE ------------------------------------------------
# The failure that turns a check into a wall: the second question of an episode
# is usually the FIRST one rewritten, and refusing that is refusing the fix.
mutant never-stands-down "1e." "$LIB" \
    '    [ "$((now - then))" -lt "$PA_STANDDOWN_SECONDS" ] || return 1' \
    '    [ "$((now - then))" -lt 0 ] || return 1' \
    "every question would be interrupted, including the revision the check just asked for -- 72 interruptions instead of 51 in the measured corpus, and the shape that gets a guard torn out."

# --- 3. THE DECLARATION IS NOT A TOKEN --------------------------------------
mutant bare-marker-exempts "2c." "$PY" \
    '        if len(words(reason)) >= MIN_MARKER_WORDS:' \
    '        if True:' \
    "'premise-unverified: dunno' would switch the check off, which is the difference between a declaration a reviewer can read and a word a reflex types."

# --- 4. SCOPE — A WORKER'S QUESTION IS NOT THE ORCHESTRATOR'S ---------------
mutant worker-questions-checked "3a." "$GATE" \
    '    elif [ -n "$PA_AGENT" ]; then' \
    '    elif [ -n "" ]; then' \
    "a teammate asking its own clarifying question would be interrupted with a lecture about the CEO's attention, spending this check's whole credibility on the case it was not built for."

# --- 5. SCOPE — A REPOSITORY WITH NO CEO IN IT ------------------------------
mutant ungoverned-repositories-checked "3b." "$GATE" \
    '        elif [ "$PA_GOV" -eq 0 ]; then' \
    '        elif [ "$PA_GOV" -le 1 ]; then' \
    "the engine loads at user scope in every directory on this machine, so every repository with no CEO record would start interrupting questions about nothing."

# --- 6. FAIL OPEN, ALWAYS ---------------------------------------------------
mutant broken-predicate-blocks "3c." "$GATE" \
    '        announce_broken "PREMISE CHECK IS OFF: $PA_BROKEN. Questions to the CEO are going through unexamined."' \
    '        exit 2' \
    "a missing python3 or a missing predicate would wedge the orchestrator's ability to ask the CEO anything at all -- worse than the failure this exists to prevent, and the one direction it must never fail in."

# --- 7. THE LEDGER'S ONE NUMBER --------------------------------------------
mutant ledger-separators-widened "4a." "$LIB" \
    'sys.stdout.write(json.dumps(rec, sort_keys=True, separators=(",", ":")) + "\n")' \
    'sys.stdout.write(json.dumps(rec, sort_keys=True) + "\n")' \
    "the re-issue comparison greps this file for a compact key, so every re-issue would silently record as '-' and the only evidence that could ever justify making this check stronger would stop existing while the ledger still looked full."

# --- 8. THE FINDING WRITTEN FOR THE 2026-09-10 PAIR -------------------------
mutant occurrence-findings-dropped "1d." "$PY" \
    '    occ = hits(OCCURRENCE_RE, whole)' \
    '    occ = []' \
    "the interruption would print nothing about a question that rests on something happening -- which is both questions of 2026-09-10, and the entire class this check was built for."

mutation_end
