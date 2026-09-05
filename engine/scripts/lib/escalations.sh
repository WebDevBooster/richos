#!/usr/bin/env bash
#
# scripts/lib/escalations.sh — the shared wiring for the escalation channel.
#
# The PREDICATE lives in escalations.py and nowhere else — read that file
# first. This is the small amount of shell every consumer needs: find the
# predicate, and refuse to pretend when it cannot run.
#
# THREE CONSUMERS, ONE PREDICATE: scripts/escalate.sh (the teammate's call and
# the lead's reader), scripts/hooks/notice-escalations.sh (turn end) and
# scripts/hooks/session-start-escalations.sh (session start). None of them
# counts, formats or judges anything itself. A wrapper that composed its own
# sentence could tell the operator a different number from the one the lead's
# own command prints, and two answers to one question is the failure this
# engine keeps finding in itself.
#
# Sourceable repeatedly. Never changes the caller's cwd.

if [ -n "${_ESCALATIONS_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_ESCALATIONS_SH_SOURCED=1

ESCALATIONS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESCALATIONS_PY="$ESCALATIONS_LIB_DIR/escalations.py"

# escalations_require — 0 if the predicate can run, else 1 with
# ESCALATIONS_BROKEN set to a sentence the caller can put on screen.
#
# FAIL LOUD, NEVER QUIETLY. Every caller of this function announces the failure
# rather than carrying on: an escalation watch that cannot read the ledger and
# says nothing is indistinguishable from one that read it and found nothing,
# and that is precisely the confusion that let two escalations sit for two days.
escalations_require() {
    ESCALATIONS_BROKEN=""
    if ! command -v python3 >/dev/null 2>&1; then
        ESCALATIONS_BROKEN="python3 is not on PATH"
        return 1
    fi
    if [ ! -f "$ESCALATIONS_PY" ]; then
        ESCALATIONS_BROKEN="the predicate is missing at $ESCALATIONS_PY"
        return 1
    fi
    return 0
}

# escalations_ledger — the ledger path the predicate would use.
#
# Printed by every consumer that reports a count, so a reader looking at an
# empty report can see WHICH file was empty. RICHOS_ESCALATION_LEDGER overrides
# it; that is how the test suites work and how a non-standard home is handled.
escalations_ledger() {
    if [ -n "${RICHOS_ESCALATION_LEDGER:-}" ]; then
        printf '%s' "$RICHOS_ESCALATION_LEDGER"
        return 0
    fi
    printf '%s' "$HOME/.claude/state/escalations.jsonl"
}

# escalations_list <format> — text | json | hook-summary | session-context.
# Exit 0 nothing outstanding, 1 at least one outstanding, 2 could not read.
escalations_list() {
    python3 "$ESCALATIONS_PY" list --format "${1:-text}"
}
