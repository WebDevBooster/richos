#!/usr/bin/env bash
#
# scripts/lib/inflight.sh — the shared wiring for the in-flight sweep.
#
# The PREDICATE lives in inflight.py and nowhere else — read that file first.
# This is the small amount of shell every consumer needs: find the predicate,
# find the session team directory the ledgers live in, and read the timeout
# out of the governed repository's config.
#
# Sourceable repeatedly. Never changes the caller's cwd.

if [ -n "${_INFLIGHT_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_INFLIGHT_SH_SOURCED=1

INFLIGHT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFLIGHT_PY="$INFLIGHT_LIB_DIR/inflight.py"
INFLIGHT_IDENTITY_PY="$INFLIGHT_LIB_DIR/teammate-identity.py"

# inflight_require — 0 if the predicate can run, else 1 with INFLIGHT_BROKEN set.
inflight_require() {
    INFLIGHT_BROKEN=""
    if ! command -v python3 >/dev/null 2>&1; then
        INFLIGHT_BROKEN="python3 is not on PATH"
        return 1
    fi
    if [ ! -f "$INFLIGHT_PY" ]; then
        INFLIGHT_BROKEN="the predicate is missing at $INFLIGHT_PY"
        return 1
    fi
    if [ ! -f "$INFLIGHT_IDENTITY_PY" ]; then
        # Without it the sweep can still run, but only ever knows a teammate by
        # its ROLE — which is exactly the 2026-08-31 false positive. A guard
        # that would report OWED-NO-NOTICE against notices that were sent is
        # worse than one that refuses to start, because the fix on the day is
        # to waive it.
        INFLIGHT_BROKEN="the identity resolver is missing at $INFLIGHT_IDENTITY_PY"
        return 1
    fi
    return 0
}

# inflight_teams_dir <session-id> — the session team directory, or "".
# inflight_teams_dir_how <session-id> — the one-line reason it chose that one.
#
# THE LADDER IS NOT HERE. It lives in scripts/lib/teammate-identity.py
# (resolve_teams_dir), because the WITNESS writes the notice ledger from python
# and the guard reads it from here, and a ledger written to one path and read
# from another is the same class of defect as a teammate called two names.
# Both halves now call the one resolver.
#
# INFLIGHT_TEAMS_DIR / WORKER_EVENTS_TEAMS_DIR are read by that resolver as the
# parent directory of the session-* directories.
inflight_teams_dir() {
    python3 "$INFLIGHT_IDENTITY_PY" --resolve-teams-dir --session "${1:-}" 2>/dev/null || printf '%s' ""
}

inflight_teams_dir_how() {
    python3 "$INFLIGHT_IDENTITY_PY" --resolve-teams-dir --how --session "${1:-}" 2>/dev/null \
        || printf '%s' "teammate-identity.py could not run"
}

# inflight_resolve_teams_dir <session-id> — sets TWO variables in the caller:
#   INFLIGHT_TEAMS_DIR_RESOLVED   the directory
#   INFLIGHT_TEAMS_DIR_SOURCE     the rung of the ladder it came from, EXPORTED
#                                 so the predicate can print it
# The source is exported rather than returned because a sweep that is reading
# the wrong ledger looks exactly like a sweep of an empty world, and the
# difference has to be on the screen.
inflight_resolve_teams_dir() {
    local pair
    pair="$(python3 "$INFLIGHT_IDENTITY_PY" --resolve-teams-dir --with-how --session "${1:-}" 2>/dev/null)"
    INFLIGHT_TEAMS_DIR_RESOLVED="$(printf '%s' "$pair" | cut -f1)"
    INFLIGHT_TEAMS_DIR_SOURCE="$(printf '%s' "$pair" | cut -f2-)"
    [ -n "$INFLIGHT_TEAMS_DIR_SOURCE" ] || INFLIGHT_TEAMS_DIR_SOURCE="teammate-identity.py could not run"
    export INFLIGHT_TEAMS_DIR_SOURCE
}

# inflight_timeout_min <entity-root> — the ack timeout in minutes.
#
# WHY 30 MINUTES, measured rather than picked (this session's own
# worker-events.jsonl, 22 completed run segments, 2026-08-30):
#
#     run-segment length   min 111s   p50 2375s (40m)   p90 4258s (71m)
#
# A queued message is delivered at the receiver's next TOOL ROUND, which is
# bounded by one tool call, not by a whole run segment — so a worker that is
# running at all gets many delivery opportunities inside 30 minutes. 30 is
# deliberately BELOW the median segment (40m) so the nag reaches the operator
# while the teammate is still inside the segment it can act in; nagging at the
# p90 (71m) would routinely arrive after the damage was done. It is not a kill
# switch: nothing here stops a teammate, it only tells the operator that the
# §8b fallback (TaskStop + respawn with a corrected brief) is now the move.
inflight_timeout_min() {
    local root="${1:-}" cfg v=""
    cfg="$root/orchestration.config"
    if [ -n "$root" ] && [ -f "$cfg" ]; then
        v="$(grep -E '^[[:space:]]*INFLIGHT_ACK_TIMEOUT_MIN=' "$cfg" 2>/dev/null \
             | tail -1 | sed -E 's/^[^=]*=//; s/^["'"'"']//; s/["'"'"']$//' | tr -cd '0-9')"
    fi
    [ -n "${INFLIGHT_ACK_TIMEOUT_MIN:-}" ] && v="$(printf '%s' "$INFLIGHT_ACK_TIMEOUT_MIN" | tr -cd '0-9')"
    [ -n "$v" ] || v=30
    printf '%s' "$v"
}

# inflight_register_repo <teams-dir> <repo> — remember that this repository is
# one we sweep.
#
# The Stop-hook notice can only watch repositories it knows about, and a session
# seated in one repository routinely lands in another (femcboost seat, richos
# worktrees — the shape this was built in). So every consumer that looks at a
# repository writes it down here, once, and the Stop hook reads the list. Best
# effort by design: failing to record a repo must never fail a push.
inflight_register_repo() {
    local teams="${1:-}" repo="${2:-}" f
    [ -n "$teams" ] && [ -n "$repo" ] || return 0
    f="$teams/inflight-repos.txt"
    mkdir -p "$teams" 2>/dev/null || return 0
    if [ -f "$f" ] && grep -qxF "$repo" "$f" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$repo" >> "$f" 2>/dev/null || true
    return 0
}

# inflight_assess <repo> <tip-or-empty> <teams-dir> <timeout-min> <format> [session] [transcript]
#
# The session id and the transcript path are how the predicate reaches the
# EXACT name join (Agent tool_use -> toolUseResult.agentId). A caller that has
# either one must pass it: without them a native worktree resolves to its role
# and no notice can ever be credited to it.
inflight_assess() {
    local repo="${1:-}" tip="${2:-}" teams="${3:-}" tmo="${4:-30}" fmt="${5:-text}"
    local sid="${6:-}" transcript="${7:-}"
    python3 "$INFLIGHT_PY" --repo "$repo" --tip "$tip" --teams-dir "$teams" \
        --timeout-min "$tmo" --format "$fmt" --session "$sid" --transcript "$transcript"
}
