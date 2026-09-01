#!/usr/bin/env bash
#
# notice-inflight-acks.sh — NON-BLOCKING Stop hook. Tells the OPERATOR that a
# teammate was told main moved under it, has not proved it heard, and that the
# timeout has passed — so the §8b fallback is now the move.
#
# ===========================================================================
# THE HALF THE PUSH GUARD DELIBERATELY CANNOT DO
# ===========================================================================
# guard-inflight-notify.sh enforces the SEND: no land completes with a live
# teammate behind and un-notified. It stops there on purpose. At push time the
# message is seconds old; the teammate has not had a tool round yet, and a
# guard that blocked a land until another party acted would wedge the session
# on somebody else's schedule.
#
# So the ack is SURFACED rather than enforced, and this is where. It also
# closes the push guard's one stated gap: a land that merges and never pushes
# is invisible to a guard on `git push`, but every turn ends at Stop.
#
# ===========================================================================
# WHY 30 MINUTES — MEASURED, NOT PICKED
# ===========================================================================
# ~/.claude/teams/session-8a598936/worker-events.jsonl, 22 completed run
# segments (WorkerStarted -> WorkerRunEnded), 2026-08-30, this machine:
#
#     min 111s      p25 824s      p50 2375s (40m)      p90 4258s (71m)
#
# A queued message is delivered at the receiver's next TOOL ROUND, which is
# bounded by one tool call rather than by a whole run segment — so a teammate
# that is running at all gets many delivery opportunities inside 30 minutes.
# 30 sits deliberately BELOW the median segment so the notice reaches the
# operator while the teammate is still inside a segment it can act in; a
# threshold at the p90 (71m) would routinely arrive after the damage. Tunable
# per repository with INFLIGHT_ACK_TIMEOUT_MIN in orchestration.config.
#
# NOTHING IS KILLED AUTOMATICALLY. §8b is explicit that TaskStop + respawn
# destroys whatever the teammate has written and is the FALLBACK, not the first
# move. A hook that reaped a teammate on a timer would be making that call on a
# stopwatch, with none of the context it needs. This notice states the
# condition and names the action; the operator decides.
#
# ===========================================================================
# WHICH REPOSITORIES IT SWEEPS — and the limit, named
# ===========================================================================
# The seat (this session's governed repository) plus every repository recorded
# in <team dir>/inflight-repos.txt, which guard-inflight-notify.sh and
# scripts/inflight-notify.sh both append to the moment they look at one. That
# is how a session seated in one repository and landing in another gets swept
# at all — the shape this whole operation runs in.
#
# THE LIMIT: a repository that has never been pushed and never been asked about
# is not on that list, and this hook will not find it. It is discovered the
# first time anyone runs the sweep or the push guard against it.
#
# systemMessage via scripts/lib/stop-hook-notice.sh, because that is the only
# channel measured to reach the operator (see that file's table). One line,
# state-change de-duplicated: a persistent condition announced every turn is a
# condition the eye is trained to skip.

set -eo pipefail

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
        echo "  hook: scripts/hooks/notice-inflight-acks.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defense"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

INPUT="$(cat)"

_SHN_LIB="$SCRIPT_DIR/../lib/stop-hook-notice.sh"
[ -f "$_SHN_LIB" ] || exit 0
# shellcheck source=../lib/stop-hook-notice.sh
. "$_SHN_LIB"

_IF_LIB="$SCRIPT_DIR/../lib/inflight.sh"
[ -f "$_IF_LIB" ] || exit 0
# shellcheck source=../lib/inflight.sh
. "$_IF_LIB"

if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # Nothing is governed here, so no teammate of this repository can be behind.
    # The plugin loads in every directory on the machine; a notice in each would
    # be noise, and engine-status.sh already announces the stand-down at session
    # start.
    exit 0
else
    # This hook believes it governs something and cannot tell what. It does NOT
    # exit 2 — a Stop hook that blocks on a broken install re-fires to the block
    # cap and strands the session. It says so instead, on the one channel that
    # reaches the operator, and stops.
    root_failure_banner "scripts/hooks/notice-inflight-acks.sh" >&2
    stop_notice_init "notice-inflight-acks.sh" "" "$INPUT"
    stop_notice_abnormal "root-failure" \
        "IN-FLIGHT ACK WATCH IS OFF: this hook cannot tell which repository it governs (${RICHOS_ROOT_REASON:-root resolution failed}). Nobody is watching whether teammates were told main moved under them — run scripts/inflight-notify.sh status by hand."
    exit 0
fi

stop_notice_init "notice-inflight-acks.sh" "$ENTITY_ROOT" "$INPUT"

if ! inflight_require; then
    stop_notice_abnormal "broken" \
        "IN-FLIGHT ACK WATCH IS OFF: $INFLIGHT_BROKEN. Nobody is watching whether teammates acked the last land; run scripts/inflight-notify.sh status by hand."
    exit 0
fi

SESSION_ID="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(str(d.get("session_id","") or "") if isinstance(d,dict) else "")
except Exception:
    print("")' 2>/dev/null || true)"
TRANSCRIPT="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(str(d.get("transcript_path","") or "") if isinstance(d,dict) else "")
except Exception:
    print("")' 2>/dev/null || true)"
TEAMS_DIR="$(inflight_teams_dir "$SESSION_ID")"
TIMEOUT_MIN="$(inflight_timeout_min "$ENTITY_ROOT")"

REPOS=""
[ -n "$ENTITY_ROOT" ] && REPOS="$ENTITY_ROOT"
if [ -n "$TEAMS_DIR" ] && [ -f "$TEAMS_DIR/inflight-repos.txt" ]; then
    while IFS= read -r r; do
        [ -n "$r" ] && [ -d "$r" ] && REPOS="$REPOS
$r"
    done < "$TEAMS_DIR/inflight-repos.txt"
fi
[ -n "$REPOS" ] || { stop_notice_normal ""; exit 0; }

SUMMARY="$(IF_LIB_DIR="$SCRIPT_DIR/../lib" IF_REPOS="$REPOS" IF_TEAMS="$TEAMS_DIR" \
           IF_SID="$SESSION_ID" IF_TRANSCRIPT="$TRANSCRIPT" \
           IF_TMO="$TIMEOUT_MIN" python3 -c '
import os, sys
sys.path.insert(0, os.environ["IF_LIB_DIR"])
import inflight

seen = []
overdue = []
unsent = []
for repo in dict.fromkeys(r for r in os.environ["IF_REPOS"].split("\n") if r.strip()):
    if repo in seen:
        continue
    seen.append(repo)
    try:
        res = inflight.assess(repo, None, os.environ["IF_TEAMS"], int(os.environ["IF_TMO"]),
                              os.environ.get("IF_SID", ""),
                              os.environ.get("IF_TRANSCRIPT", ""))
    except Exception:
        continue
    for wt in res["worktrees"]:
        who = wt.get("resolved_name") or os.path.basename(wt["path"].rstrip("/"))
        if wt["verdict"] == "OWED-NO-NOTICE":
            unsent.append(who)
        elif wt["verdict"] in ("NOTIFIED-NO-ACK", "NOTIFIED-ACK-INVALID"):
            ack = wt.get("ack") or {}
            if wt["verdict"] == "NOTIFIED-ACK-INVALID" or ack.get("overdue"):
                overdue.append(who)

parts = []
if unsent:
    parts.append("NEVER TOLD: " + ", ".join(sorted(set(unsent))))
if overdue:
    parts.append("no ack past the timeout: " + ", ".join(sorted(set(overdue))))
print("\t".join(["|".join(sorted(set(unsent + overdue))), "; ".join(parts)]))
' 2>/dev/null || true)"

KEY="$(printf '%s' "$SUMMARY" | cut -f1)"
TEXT="$(printf '%s' "$SUMMARY" | cut -f2-)"

if [ -z "$KEY" ]; then
    stop_notice_normal "IN-FLIGHT SWEEP: every live teammate behind the current tip has now been told and has acked. Nothing outstanding."
    exit 0
fi

stop_notice_abnormal "outstanding:$KEY" \
    "IN-FLIGHT SWEEP (rich-lander SKILL.md §8b) — $TEXT. Main moved under them and they cannot know it. Message them naming the SHA, or if ${TIMEOUT_MIN}min has passed with no ack, TaskStop + respawn with a corrected brief. That is yours to do: scripts/inflight-notify.sh status"
exit 0
