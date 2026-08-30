#!/usr/bin/env bash
#
# inflight-notify.sh — the in-flight sweep, by hand.
#
# guard-inflight-notify.sh runs the same predicate at `git push` time and
# refuses. This is how a human asks the same question BEFORE being refused,
# and the only way to record a deliberate decision not to notify.
#
#   inflight-notify.sh status [--repo R] [--tip SHA]
#       Who is in flight, what moved under them, who was told, who acked.
#       Always exit 0 — this one is for reading.
#
#   inflight-notify.sh check [--repo R] [--tip SHA]
#       The guard's predicate, exactly. Exit 0 clean, 1 if a live teammate is
#       behind and un-notified, 2 if it could not run.
#
#   inflight-notify.sh waive <worktree-path> --reason "<why>" [--repo R]
#       THE ESCAPE HATCH, and the only one. Records a dated row naming the tip,
#       the worktree and the reason. Never silent: it prints what it recorded,
#       and it prints LOUDLY when the worktree it is excusing has file overlap
#       with what just moved — that is the merge-conflict case, and waiving it
#       is a choice somebody should have to see themselves make.
#
#   inflight-notify.sh acks [--repo R] [--tip SHA]
#       The ack artifacts and their verification, including the one field no
#       machine here can check.
#
# Where the ledgers live: <session team dir>/inflight-notices.jsonl (written by
# the PostToolUse[SendMessage] witness) and inflight-waivers.jsonl (written
# here). Point both at a sandbox with INFLIGHT_TEAMS_DIR.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/inflight.sh"

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; }

CMD="${1:-status}"
[ "$#" -gt 0 ] && shift || true
case "$CMD" in
    -h|--help|help) usage; exit 0 ;;
esac

REPO=""
TIP=""
REASON=""
SESSION_ID="${CLAUDE_SESSION_ID:-}"
TARGET=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)    REPO="${2:-}"; shift 2 ;;
        --tip)     TIP="${2:-}"; shift 2 ;;
        --reason)  REASON="${2:-}"; shift 2 ;;
        --session) SESSION_ID="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*)        echo "inflight-notify.sh: unrecognized option '$1'" >&2; exit 2 ;;
        *)         [ -n "$TARGET" ] && { echo "inflight-notify.sh: unexpected argument '$1'" >&2; exit 2; }
                   TARGET="$1"; shift ;;
    esac
done

[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

inflight_require || {
    echo "inflight-notify.sh: $INFLIGHT_BROKEN — cannot run the sweep." >&2
    exit 2
}

TEAMS_DIR="$(inflight_teams_dir "$SESSION_ID")"
TIMEOUT_MIN="$(inflight_timeout_min "$REPO")"

case "$CMD" in
    status)
        inflight_assess "$REPO" "$TIP" "$TEAMS_DIR" "$TIMEOUT_MIN" text
        exit 0 ;;

    check)
        RC=0
        inflight_assess "$REPO" "$TIP" "$TEAMS_DIR" "$TIMEOUT_MIN" text || RC=$?
        exit "$RC" ;;

    acks)
        IF_ARGS_REPO="$REPO" IF_ARGS_TIP="$TIP" IF_ARGS_TEAMS="$TEAMS_DIR" \
        IF_ARGS_TMO="$TIMEOUT_MIN" IF_LIB_DIR="$SCRIPT_DIR/lib" python3 -c '
import os, sys
sys.path.insert(0, os.environ["IF_LIB_DIR"])
import inflight
res = inflight.assess(os.environ["IF_ARGS_REPO"], os.environ["IF_ARGS_TIP"] or None,
                      os.environ["IF_ARGS_TEAMS"], int(os.environ["IF_ARGS_TMO"]))
print("acks for tip %s" % res["tip"])
any_ack = False
for wt in res["worktrees"]:
    ack = wt.get("ack") or {}
    if ack.get("state") in ("none", "n/a"):
        continue
    any_ack = True
    print("")
    print("  %s" % wt["path"])
    print("    channel  : %s" % ack.get("channel", ""))
    print("    verified : %s" % ("YES" if ack.get("verified") else "NO"))
    for p in ack.get("problems", []):
        print("      - %s" % p)
    if ack.get("detail"):
        print("    detail   : %s" % ack["detail"])
        print("    ^^ HUMAN JUDGMENT REQUIRED. Everything above this line was checked by")
        print("       a machine. Whether that sentence is CORRECT was not, and cannot be:")
        print("       a string match is not comprehension. Read it yourself.")
if not any_ack:
    print("  no ack artifacts and no witnessed replies for this tip.")
'
        exit 0 ;;

    waive)
        [ -n "$TARGET" ] || { echo "inflight-notify.sh waive: give the worktree path to waive." >&2; exit 2; }
        [ -n "$REASON" ] || { echo "inflight-notify.sh waive: --reason is required. A waiver with no reason is a silent skip wearing a ledger row." >&2; exit 2; }
        [ -n "$TEAMS_DIR" ] || { echo "inflight-notify.sh waive: could not resolve a session team directory to record the waiver in. Set INFLIGHT_TEAMS_DIR or pass --session." >&2; exit 2; }
        IF_ARGS_REPO="$REPO" IF_ARGS_TIP="$TIP" IF_ARGS_TEAMS="$TEAMS_DIR" \
        IF_ARGS_TMO="$TIMEOUT_MIN" IF_ARGS_TARGET="$TARGET" IF_ARGS_REASON="$REASON" \
        IF_LIB_DIR="$SCRIPT_DIR/lib" python3 -c '
import json, os, sys, getpass
from datetime import datetime, timezone
sys.path.insert(0, os.environ["IF_LIB_DIR"])
import inflight

repo = os.environ["IF_ARGS_REPO"]
teams = os.environ["IF_ARGS_TEAMS"]
target = os.path.abspath(os.environ["IF_ARGS_TARGET"].rstrip("/"))
reason = os.environ["IF_ARGS_REASON"]
res = inflight.assess(repo, os.environ["IF_ARGS_TIP"] or None, teams,
                      int(os.environ["IF_ARGS_TMO"]))
match = None
for wt in res["worktrees"]:
    if os.path.abspath(wt["path"].rstrip("/")) == target:
        match = wt
if match is None:
    sys.stderr.write(
        "inflight-notify.sh waive: %s is not a registered worktree of %s.\n"
        "  Run `inflight-notify.sh status` for the list — waiving a path that is\n"
        "  not in the sweep would record a decision about nothing.\n" % (target, res["main_checkout"]))
    sys.exit(2)

row = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "event": "InflightWaiver",
    "repo": res["main_checkout"],
    "tip": res["tip"],
    "worktree": match["path"],
    "branch": match["branch"],
    "teammate": match.get("resolved_name", ""),
    "overlap": match.get("overlap", []),
    "reason": reason,
    "actor": getpass.getuser(),
}
path = inflight.waiver_ledger_path(teams)
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row) + "\n")

print("recorded a waiver in %s" % path)
print("  tip      : %s" % row["tip"])
print("  worktree : %s (%s)" % (row["worktree"], row["teammate"] or "<unresolved>"))
print("  reason   : %s" % reason)
if row["overlap"]:
    print("")
    print("  *** THIS WAIVER IS OVER A FILE OVERLAP ***")
    print("  What just moved touches %d file(s) this teammate has also changed:" % len(row["overlap"]))
    for p in row["overlap"][:12]:
        print("      %s" % p)
    print("  This is the merge-conflict case — the first of the two failures §8b was")
    print("  written from. The waiver stands; it is recorded, and you have now seen")
    print("  what you waived.")
'
        exit $? ;;

    *)
        echo "inflight-notify.sh: unknown subcommand '$CMD'" >&2
        usage >&2
        exit 2 ;;
esac
