#!/usr/bin/env bash
#
# quota-watch.sh — the CEO's 93% quota rule, as the one command a lead runs.
#
# HIS WORDS, the whole behavior (ruling §87, richos-hq/wiki/ceo-decisions.md):
#   "quota polling: every 5 minutes from now. And once it crosses the 93%
#    threshold: PAUSE subagents. Then resume after quota rest."
#
# HIS UPDATE, 2026-09-25 (ruling §87): at or above the threshold, do not pause
# when the reset is LESS than 20 minutes away (exactly 20 still pauses), and a
# hold already in place releases inside that window, keeping the same agent.
# Polling stays every 5 minutes at every usage level: "Well, I've changed my
# mind. Let's drop the 30-minute check nonsense. Keep it consistent at 5
# minutes."
#
#   quota-watch.sh --once
#       one line: the reading, its age and the reset time.
#       exit 0 below the threshold, 1 at or above it (pause), 2 unknown,
#       3 at or above it with the reset less than 20 minutes away (no pause)
#   quota-watch.sh --status
#       the same reading, human-readable, with this session's live workers
#   quota-watch.sh --watch [--until-reset]
#       polls every 300 s. Run it as a BACKGROUND command (Bash with
#       run_in_background: true) so its exit wakes the lead. It exits after
#       printing ONE event:
#         QUOTA-THRESHOLD  at or above the threshold with a worker running and
#                          20 minutes or more to the reset: the exact pause
#                          message, the names to send it to, the minutes to
#                          reset and the live-worker count
#         QUOTA-RELEASE    the reset is less than 20 minutes away and agents
#                          are paused for the quota: the exact resume message
#                          and their names (the hold releases there)
#         WINDOW-RESET     the window turned over: the exact resume message and
#                          the names of the agents paused for the quota
#         QUOTA-STALE      the reading is older than one poll while a worker
#                          runs: its value is not the current one, and the
#                          lead's own turn refreshes the payload
#         QUOTA-UNKNOWN    the reading has been missing or malformed for one
#                          poll while a worker runs, so the watcher is blind
#       --until-reset never fires the threshold: for a window in which the
#       lead has already decided (paused, or chose to keep working). It wakes
#       at the hold's release when agents are paused for the quota, and at
#       the reset.
#
# THE THRESHOLD is QUOTA_PAUSE_PERCENT in the governed repository's
# orchestration.config, beside MODEL_CEILING, read here and nowhere else.
# Undeclared is UNKNOWN (exit 2), never a built-in 93.
#
# It reads ~/.claude/statusline-payload.json (QUOTA_PAYLOAD overrides, for
# tests) and the workspace registry. It never messages, pauses, stops or
# spawns anything, and it never reads a credential. The lead acts.
#
# The logic, and every choice in it: scripts/lib/quota_watch.py.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/quota_watch.py"
RR="$SCRIPT_DIR/lib/resolve-roots.sh"

command -v python3 >/dev/null 2>&1 || { echo "quota-watch.sh: python3 is required" >&2; exit 2; }
[ -f "$LIB" ] || { echo "quota-watch.sh: $LIB is missing" >&2; exit 2; }
[ -f "$RR" ] || { echo "quota-watch.sh: $RR is missing" >&2; exit 2; }

# shellcheck source=lib/resolve-roots.sh
. "$RR"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR/lib")"

# The governed repository, the same way every rooted engine script finds it:
# RICHOS_ENTITY_ROOT, then CLAUDE_PROJECT_DIR, then the working directory.
CONFIG=""
RAW=""
if resolve_entity_root ""; then
    CONFIG="$RICHOS_ENTITY_ROOT_RESOLVED/orchestration.config"
    if [ -f "$CONFIG" ]; then
        # Sourced in a subshell, exactly as the guards read MODEL_CEILING: the
        # declaration is shell, and nothing it sets leaks into this process.
        RAW="$( ( . "$CONFIG" >/dev/null 2>&1; printf '%s' "${QUOTA_PAUSE_PERCENT:-}" ) 2>/dev/null || true )"
    fi
else
    CONFIG=""
fi

# The command a lead is told to run, spelled the way it can be copied.
SELF="$SCRIPT_DIR/quota-watch.sh"

exec python3 "$LIB" "$@" --threshold-raw "$RAW" --config "$CONFIG" \
    --engine-root "$ENGINE_ROOT" --command "$SELF"
