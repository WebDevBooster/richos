#!/usr/bin/env bash
#
# quota-watch.mutation.sh — PROVES THE 93% RULE'S SUITE CAN FAIL.
#
# Takes the SHIPPED scripts/lib/quota_watch.py, removes ONE property at a time
# in a throwaway copy of the engine, and asserts that (1) the suite fails,
# (2) the SPECIFIC named case fails, and (3) the mutation actually applied.
# The loop is scripts/lib/mutation-harness.sh; this file is the list of
# properties his rule rests on.
#
# Invoked by quota-watch.test.sh, so the runner that discovers *.test.sh runs
# it too. Run directly: scripts/quota-watch.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$SCRIPT_DIR/lib/mutation-harness.sh"
mutation_begin "quota-watch (the CEO's 93% rule)" "scripts/quota-watch.test.sh"

L="scripts/lib/quota_watch.py"

# 1. THE EDGE. "once it crosses the 93% threshold" — 93 itself is across.
mutant threshold-strict "Q02" "$L" \
    'if r["used"] >= threshold:' \
    'if r["used"] > threshold:' \
    "A reading of exactly 93% would read as below the threshold and nobody would be paused."

# 2. THE NUMBER IS HIS AND LIVES IN ONE PLACE. A built-in fallback is a second
#    place holding 93, which is how the number drifts.
mutant builtin-fallback "Q11" "$L" \
    'raw = (raw or "").strip()' \
    'raw = (raw or "93").strip()' \
    "An undeclared threshold would silently become 93 instead of being announced as missing."

mutant hardcoded-threshold "Q13" "$L" \
    'return v, ""' \
    'return 93.0, ""' \
    "The declared QUOTA_PAUSE_PERCENT would be read and ignored."

# 3. ABSENCE IS NEVER FINE (design notes R6).
mutant unknown-exits-zero "Q04" "$L" \
    'return {"below": 0, "at-or-above": 1}.get(verdict, 2)' \
    'return {"below": 0, "at-or-above": 1}.get(verdict, 0)' \
    "A missing or unreadable payload would exit exactly like a healthy reading below the threshold."

mutant stale-read-as-fresh "R01" "$L" \
    'if r["age"] is not None and r["age"] > stale_after:' \
    'if False:' \
    "A reading an hour old would be reported as a fresh 'below the threshold': 2026-09-25, replayed by R01."

mutant ended-window-read-as-current "Q10" "$L" \
    '    if r["ended"]:{NL}        return "unknown"' \
    '    if False:{NL}        return "unknown"' \
    "A reading of a window that no longer exists would be trusted."

mutant stale-bound-three-polls "Q16" "$L" \
    'a.stale = _env_int("QUOTA_WATCH_STALE_SECONDS", a.poll)' \
    'a.stale = _env_int("QUOTA_WATCH_STALE_SECONDS", 3 * a.poll)' \
    "A reading two polls old would pass as current, which is how the 93% crossing went unseen."

mutant stale-wakes-nobody "W05" "$L" \
    'stale = r["state"] == "ok" and not r["ended"]' \
    'stale = False' \
    "A stale reading would wait out a further poll on the watcher's own clock before telling the lead to refresh."

# 4. HIS "every 5 minutes".
mutant poll-not-five-minutes "W09" "$L" \
    'POLL_SECONDS = 300' \
    'POLL_SECONDS = 30' \
    "The watcher would poll ten times as often as he said."

# 5. THE PAUSE IS A REAL PAUSE. Without the pause-until: line the registry
#    records the agent's own end of run as FINISHED, and the wake at the reset
#    is refused: 2026-09-18, exactly.
mutant pause-message-without-pause-until "E02" "$L" \
    '        pause_until_line(r["resets_at"]),{NL}    ])' \
    '    ])' \
    "The pause message would read correctly and record nothing, and every paused agent would be finished at its first SubagentStop."

mutant resume-message-re-pauses "E06" "$L" \
    'Continue exactly where you stopped."' \
    'Continue exactly where you stopped.\npause-until: later"' \
    "The resume message would re-pause the agent it was meant to wake."

# 6. WAKE THE LEAD ONLY WHEN THERE IS SOMETHING TO DO.
mutant fires-with-nothing-working "W03" "$L" \
    '                if w["known"] and not w["working"]:{NL}                    print("  at the threshold with nothing working' \
    '                if False:{NL}                    print("  at the threshold with nothing working' \
    "After the lead paused everybody, restarting the watcher would wake it again at once, forever, until the reset."

mutant blind-wake-with-nothing-working "W06" "$L" \
    '                    if w["known"] and not w["working"]:{NL}                        print("  the reading is unknown but nothing' \
    '                    if False:{NL}                        print("  the reading is unknown but nothing' \
    "A quiet session would be woken for a stale reading when there is no spend it could hide."

mutation_end
