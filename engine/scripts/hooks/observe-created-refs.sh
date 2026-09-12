#!/usr/bin/env bash
#
# observe-created-refs.sh — THE OTHER HALF OF THE PAIR. Matcherless PostToolUse.
#
# ===========================================================================
# WHAT IT RECORDS — docs/plans/worktree-spec-2026-09-11.md, points 3 and 10
# ===========================================================================
#   "A cc/ or native workspace with no registration, and ANY BRANCH AN AGENT
#    CREATED, counts as finished work of an ended session"          (point 3)
#   "every workspace and branch it has is deleted, as one. None is left
#    behind."                                                       (point 10)
#
# A ref an agent created is the agent's; a ref that already existed never is.
# CREATION is therefore the fact to record, and a tool call is the only moment
# the platform vouches for with an agent's id. It has two halves:
#
#   PreToolUse (matcherless)   guard-sealed-worktree.sh -> barrier() ->
#                              snapshot_refs(): what the agent's repositories
#                              held when this call STARTED.
#   PostToolUse (matcherless)  THIS HOOK -> observe() -> observe_created_refs():
#                              what is there now. A ref that is new AND carries
#                              this agent's own unlanded work was created by it.
#
# BOTH HALVES CARRY `tool_use_id`, AND IT IS THE SAME STRING FOR ONE CALL. That
# is what keys the window, and it is why this hook passes the WHOLE payload
# through rather than the agent id alone: an agent's own calls overlap, so one
# slot per agent lost a window every time two were open at once, and a ref
# created in the second was attributed to nobody. See scripts/lib/workspaces.py,
# "ONE WINDOW PER TOOL CALL, KEYED BY THE CALL".
#
# THE PRE HALF ALREADY EXISTED AND THE POST HALF DID NOT, which is the whole
# reason attribution had to be read from POSSESSION (a ref checked out at the
# agent's own workspace path) until 2026-09-12 — and possession left the stray
# (`git branch spare` checks nothing out), the side branch (committed to and
# switched away from) and the borrowed branch (pre-existing, merely checked out,
# then deleted by a discard). scripts/lib/workspaces.py carries the four filters
# that keep co-occurrence in time from being mistaken for authorship.
#
# IT RECORDS A FACT AND NEVER REFUSES ANYTHING. Exit 0 always, on every path:
# this hook fires after the work is already done, so a fact it could not record
# must never be allowed to look like a failed tool call. A missed observation
# costs one window of attribution, which under-attributes, which loses nothing.
#
# THE LEAD'S OWN CALLS COST ALMOST NOTHING. A payload with no `agent_id` is the
# lead's, and it is answered by one grep before python3 is started at all — this
# hook is registered against EVERY tool, so the lead's path has to be cheap.
#
# NOTE: hooks are snapshotted at session start. This hook is inert until the next
# session and assumes nothing about being live in the session that adds it.

set -o pipefail

# A BOUNDED read, never `cat`: the payload arrives on stdin and the platform
# closes it within milliseconds; 3 s is ample for a 225 KB payload. `-d ''`
# returns nonzero on a complete read, so the VALUE is judged, never `$?`.
INPUT=""
IFS= read -r -t "${RICHOS_HOOK_STDIN_TIMEOUT:-3}" -d '' INPUT || true

# The lead's own call: no agent created anything, so there is nothing to compare.
if ! printf '%s' "$INPUT" | grep -E >/dev/null '(^|[^\\])"agent_id"[[:space:]]*:[[:space:]]*"[^"]'; then
    exit 0
fi

# --- ROOT RESOLUTION -------------------------------------------------------
# TWO ROOTS, NEVER ONE. The full contract, and why the old single-root
# resolution was wrong the moment the engine became loadable by reference,
# is in scripts/lib/resolve-roots.sh. This bootstrap block is byte-identical
# in every hook that needs a root; contract-integrity-probe.sh Layer R asserts
# that, so a divergent copy is a probe failure rather than a surprise.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RR_LIB="$SCRIPT_DIR/../lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/observe-created-refs.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defense"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 0
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # No engine here, no workspace contract: stand down. A RESOLVED state.
    exit 0
else
    root_failure_banner "scripts/hooks/observe-created-refs.sh" >&2
    exit 0
fi

LIB="$SCRIPT_DIR/../lib/workspaces.py"
if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$LIB" ]; then
    echo "NOTICE: observe-created-refs.sh: python3 or $LIB is unavailable — a branch this agent created was NOT recorded against it (docs/plans/worktree-spec-2026-09-11.md, points 3, 10). Restore the engine." >&2
    exit 0
fi

# The payload travels on stdin, never in the environment: a large payload must
# not skip the observation. Anything it recorded is announced, because a branch
# joining an agent's record decides what a land deletes.
OUT="$(printf '%s' "$INPUT" | python3 "$LIB" --entity "$ENTITY_ROOT" observe-refs 2>/dev/null)" || true
if [ -n "$OUT" ]; then
    printf '%s' "$OUT" | while IFS=$'\t' read -r _tag repo branch; do
        [ -n "$branch" ] && echo "NOTICE: $branch in $repo was created by this agent and is recorded against it: it is deleted with its workspaces when its work is landed or discarded (docs/plans/worktree-spec-2026-09-11.md, points 3, 10)." >&2
    done
fi
exit 0
