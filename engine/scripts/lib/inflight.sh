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
    return 0
}

# inflight_teams_dir <session-id> — the session team directory, or "".
#
# Same resolution the four worker-lifecycle emitters use: exact session match
# first, then a single-session fallback (and ONLY when there is exactly one —
# guessing between sessions would attribute one session's notices to another).
# INFLIGHT_TEAMS_DIR / WORKER_EVENTS_TEAMS_DIR override the parent directory,
# which is how the tests point this at a sandbox.
inflight_teams_dir() {
    local sid="${1:-}" base short d found=""
    base="${INFLIGHT_TEAMS_DIR:-${WORKER_EVENTS_TEAMS_DIR:-$HOME/.claude/teams}}"
    [ -d "$base" ] || { printf '%s' ""; return 0; }
    short="$(printf '%s' "$sid" | cut -c1-8)"
    if [ -n "$short" ] && [ -d "$base/session-$short" ]; then
        printf '%s' "$base/session-$short"
        return 0
    fi
    for d in "$base"/session-*; do
        [ -d "$d" ] || continue
        if [ -n "$found" ]; then printf '%s' ""; return 0; fi
        found="$d"
    done
    printf '%s' "$found"
    return 0
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

# inflight_assess <repo> <tip-or-empty> <teams-dir> <timeout-min> <format>
inflight_assess() {
    local repo="${1:-}" tip="${2:-}" teams="${3:-}" tmo="${4:-30}" fmt="${5:-text}"
    python3 "$INFLIGHT_PY" --repo "$repo" --tip "$tip" --teams-dir "$teams" \
        --timeout-min "$tmo" --format "$fmt"
}
