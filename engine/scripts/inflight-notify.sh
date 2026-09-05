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
#   inflight-notify.sh notice [--repo R] [--tip SHA] [--teammate N | --worktree P]
#                             [--impact <kind>] [--detail "<one sentence>"]
#       GENERATES the notice. Does not send it, does not decide who gets one.
#
#       The guard ALREADY computes everything mechanical in this message in
#       order to decide whom to refuse for: which live worktrees are behind,
#       which teammate each belongs to, the tip main is moving to, and the path
#       overlap. It then used to make the lander type all of that back by hand
#       and checked the typing. On 2026-09-02 that produced a 25-line notice
#       whose mandatory content is five short fields, and the CEO called it
#       needlessly feeding piles of noise to agents in flight. The
#       answer offered was that the lander would write shorter ones, and he
#       rejected it on the spot, correctly: an intention is not a mechanism, and
#       his standing ruling on exactly this is "I cannot rely on your promises.
#       There must be a guarantee."
#
#       So the notice is GENERATED. `sha`, `paths` and `teammate` come from the
#       predicate. EXACTLY TWO FIELDS ARE THE OPERATOR'S: impact and detail.
#       There is no blank space left to inflate — that is the whole mechanism.
#
#       It does NOT send, and it does NOT filter by path overlap. Relevance is a
#       human judgment: the costlier of the two §8b failures — twelve design
#       variations landing under an agent building a library from seven — had
#       ZERO file overlap. The agent's assumptions went stale, not its files.
#       This removes the typing, not the judgment.
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
# COMMON OPTIONS, all four subcommands:
#   --repo R          the repository to sweep (default: the enclosing one)
#   --tip SHA         the tip to sweep against (default: the main checkout HEAD)
#   --session ID      which session's ledgers to read; defaults to
#                     CLAUDE_SESSION_ID, which is unset when you run this by
#                     hand from a terminal
#   --transcript P    the orchestrator transcript, for the exact
#                     name -> agent-id join; defaults to INFLIGHT_TRANSCRIPT,
#                     then to the transcript of --session
#
# Where the ledgers live: <session team dir>/inflight-notices.jsonl (written by
# the PostToolUse[SendMessage] witness) and inflight-waivers.jsonl (written
# here). INFLIGHT_TEAMS_DIR points at either the directory session-* dirs live
# under, OR straight at one team directory — both readings work, which is what
# every header here has claimed since the beginning and what the code did not
# do until 2026-09-01. `status` prints which directory it resolved and why, so
# a sweep that is looking in the wrong place says so instead of reporting an
# empty ledger as an empty world.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/inflight.sh"

# The whole leading comment block, minus the shebang — so a header that grows
# does not silently stop being the help text.
usage() { sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

CMD="${1:-status}"
[ "$#" -gt 0 ] && shift || true
case "$CMD" in
    -h|--help|help) usage; exit 0 ;;
esac

REPO=""
TIP=""
REASON=""
IMPACT=""
DETAIL=""
TEAMMATE=""
WORKTREE=""
SESSION_ID="${CLAUDE_SESSION_ID:-}"
TRANSCRIPT="${INFLIGHT_TRANSCRIPT:-}"
TARGET=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)       REPO="${2:-}"; shift 2 ;;
        --tip)        TIP="${2:-}"; shift 2 ;;
        --reason)     REASON="${2:-}"; shift 2 ;;
        --impact)     IMPACT="${2:-}"; shift 2 ;;
        --detail)     DETAIL="${2:-}"; shift 2 ;;
        --teammate)   TEAMMATE="${2:-}"; shift 2 ;;
        --worktree)   WORKTREE="${2:-}"; shift 2 ;;
        --session)    SESSION_ID="${2:-}"; shift 2 ;;
        --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
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

inflight_resolve_teams_dir "$SESSION_ID"
TEAMS_DIR="$INFLIGHT_TEAMS_DIR_RESOLVED"
TIMEOUT_MIN="$(inflight_timeout_min "$REPO")"
inflight_register_repo "$TEAMS_DIR" "$(cd "$REPO" && git rev-parse --show-toplevel 2>/dev/null || printf %s "$REPO")"

case "$CMD" in
    status)
        inflight_assess "$REPO" "$TIP" "$TEAMS_DIR" "$TIMEOUT_MIN" text "$SESSION_ID" "$TRANSCRIPT"
        exit 0 ;;

    check)
        RC=0
        inflight_assess "$REPO" "$TIP" "$TEAMS_DIR" "$TIMEOUT_MIN" text "$SESSION_ID" "$TRANSCRIPT" || RC=$?
        exit "$RC" ;;

    acks)
        IF_ARGS_REPO="$REPO" IF_ARGS_TIP="$TIP" IF_ARGS_TEAMS="$TEAMS_DIR" \
        IF_ARGS_TMO="$TIMEOUT_MIN" IF_ARGS_SID="$SESSION_ID" IF_ARGS_TRANSCRIPT="$TRANSCRIPT" \
        IF_LIB_DIR="$SCRIPT_DIR/lib" python3 -c '
import os, sys
sys.path.insert(0, os.environ["IF_LIB_DIR"])
import inflight
res = inflight.assess(os.environ["IF_ARGS_REPO"], os.environ["IF_ARGS_TIP"] or None,
                      os.environ["IF_ARGS_TEAMS"], int(os.environ["IF_ARGS_TMO"]),
                      os.environ.get("IF_ARGS_SID", ""),
                      os.environ.get("IF_ARGS_TRANSCRIPT", ""))
print("acks for tip %s" % res["tip"])
print("  durable ledger : %s (%d row(s) for this tip)"
      % (res.get("ack_ledger", ""), res.get("ack_ledger_rows_for_tip", 0)))
if res.get("ack_ledger_error"):
    # UNREADABLE IS NOT EMPTY. If this line is on the screen, every "no ack"
    # below is unproven rather than false.
    print("  ** THE DURABLE LEDGER COULD NOT BE READ: %s" % res["ack_ledger_error"])
    print("     Anything reported as unacked below is UNKNOWN, not absent.")
if res.get("ack_ledger_malformed"):
    print("  ** %d malformed ledger line(s) SKIPPED — not counted as acks."
          % res["ack_ledger_malformed"])
any_ack = False
for wt in res["worktrees"]:
    ack = wt.get("ack") or {}
    if ack.get("state") in ("none", "n/a"):
        continue
    any_ack = True
    print("")
    print("  %s%s" % (wt["path"], "" if wt.get("present") else "   [DIRECTORY GONE]"))
    print("    channel  : %s" % ack.get("channel", ""))
    print("    verified : %s" % ("YES" if ack.get("verified") else "NO"))
    # EVERY record for this tip, with whose it is. Two teammates acknowledging
    # one land is the normal case; printing only the deciding record would hide
    # the collision this key was changed to survive.
    for r in (ack.get("records") or []):
        print("    record   : [%s] %s  %s  %s"
              % (r.get("source", ""),
                 os.path.basename(r["path"]),
                 ("this teammate" if r.get("own") else "ANOTHER teammate: %s"
                  % (r.get("teammate") or r.get("worktree") or "unnamed")),
                 "verified" if r.get("verified") else "INVALID"))
    for p in ack.get("problems", []):
        print("      - %s" % p)
    # A CHECK THAT COULD NOT RUN NAMES ITSELF RATHER THAN PASSING QUIETLY.
    for n in ack.get("notes", []):
        print("      ~ COULD NOT RE-CHECK: %s" % n)
    if ack.get("detail"):
        print("    detail   : %s" % ack["detail"])
        print("    ^^ HUMAN JUDGMENT REQUIRED. Everything above this line was checked by")
        print("       a machine. Whether that sentence is CORRECT was not, and cannot be:")
        print("       a string match is not comprehension. Read it yourself.")

# ACKED AND THEN GONE. A teammate that answered and finished has no registered
# worktree left, so it appears in no loop above. Its answer is still an answer,
# and this section is the difference between reading that and reading nothing.
orphans = res.get("orphan_acks") or []
if orphans:
    any_ack = True
    print("")
    print("  ACKED, WORKTREE GONE — %d durable record(s), no registered worktree left" % len(orphans))
    for o in orphans:
        print("")
        print("    %s  (%s)" % (o["teammate"] or "<unnamed>", o["timestamp"]))
        print("      worktree : %s%s"
              % (o["worktree"] or "<none recorded>",
                 "" if o["worktree_present"] else "   [GONE]"))
        print("      impact   : %s   paths: %s" % (o["impact"], o["paths"]))
        print("      detail   : %s" % o["detail"])
        print("      ^^ HUMAN JUDGMENT REQUIRED, same as above.")

if not any_ack:
    print("  no ack artifacts, no durable ledger rows, and no witnessed replies for this tip.")
'
        exit 0 ;;

    notice)
        # THE TWO OPERATOR FIELDS, validated before anything is generated. An
        # impact outside the four kinds is not a notice, it is a sentence; and a
        # detail that spans lines is where 25 lines came from last time.
        if [ -n "$IMPACT" ]; then
            case "$IMPACT" in
                conflict|stale-record|grew-scope|none) ;;
                *) echo "inflight-notify.sh notice: --impact must be one of: conflict stale-record grew-scope none (got '$IMPACT')." >&2; exit 2 ;;
            esac
        fi
        if [ -n "$DETAIL" ]; then
            if [ "$(printf '%s' "$DETAIL" | wc -l | tr -d ' ')" != "0" ]; then
                echo "inflight-notify.sh notice: --detail must be ONE line. A multi-line detail is how a five-field notice became twenty-five." >&2
                exit 2
            fi
            if [ "${#DETAIL}" -gt 240 ]; then
                echo "inflight-notify.sh notice: --detail is ${#DETAIL} characters; the cap is 240. Say which assumption breaks, not the whole land." >&2
                exit 2
            fi
        fi
        [ -n "$WORKTREE" ] || WORKTREE="$TARGET"
        RC=0
        IF_ARGS_REPO="$REPO" IF_ARGS_TIP="$TIP" IF_ARGS_TEAMS="$TEAMS_DIR" \
        IF_ARGS_TMO="$TIMEOUT_MIN" IF_ARGS_SID="$SESSION_ID" IF_ARGS_TRANSCRIPT="$TRANSCRIPT" \
        IF_ARGS_IMPACT="$IMPACT" IF_ARGS_DETAIL="$DETAIL" \
        IF_ARGS_TEAMMATE="$TEAMMATE" IF_ARGS_WORKTREE="$WORKTREE" \
        IF_LIB_DIR="$SCRIPT_DIR/lib" python3 -c '
import os, sys
sys.path.insert(0, os.environ["IF_LIB_DIR"])
import inflight

res = inflight.assess(os.environ["IF_ARGS_REPO"], os.environ["IF_ARGS_TIP"] or None,
                      os.environ["IF_ARGS_TEAMS"], int(os.environ["IF_ARGS_TMO"]),
                      os.environ.get("IF_ARGS_SID", ""),
                      os.environ.get("IF_ARGS_TRANSCRIPT", ""))
if res.get("error"):
    sys.stderr.write("inflight-notify.sh notice: %s\n" % res["error"])
    raise SystemExit(2)

tip = res["tip"]
want_wt = inflight.norm(os.environ.get("IF_ARGS_WORKTREE") or "")
want_name = (os.environ.get("IF_ARGS_TEAMMATE") or "").strip()

# WHO GETS ONE is the guards own predicate, unchanged and un-second-guessed.
# OWED-NO-NOTICE is exactly the set it refuses the push for. An explicit
# selector widens it to any live worktree that is behind, so a lander can
# regenerate a notice it has already sent.
owed = [w for w in res["worktrees"] if w["verdict"] == "OWED-NO-NOTICE"]
if want_wt or want_name:
    pool = [w for w in res["worktrees"] if w["live"] and w["behind"] and w["moved_shas"]]
    sel = []
    for w in pool:
        if want_wt and inflight.norm(w["path"]) == want_wt:
            sel.append(w)
        elif want_name and (want_name in (w.get("addresses") or [])
                            or want_name == (w.get("resolved_name") or "")):
            sel.append(w)
    if not sel:
        sys.stderr.write(
            "inflight-notify.sh notice: %r matches no live worktree of %s that is behind %s.\n"
            "  Run `inflight-notify.sh status` for the list.\n"
            % (want_name or want_wt, res["main_checkout"], tip[:12]))
        raise SystemExit(2)
    owed = sel

print("in-flight notices for tip %s" % tip)
print("  repository : %s" % res["main_checkout"])
if not owed:
    print("")
    print("  Nothing is owed a notice. Either nothing is in flight, or every live")
    print("  teammate is already notified, waived, landed, or not behind.")
    raise SystemExit(0)

impact = (os.environ.get("IF_ARGS_IMPACT") or "").strip()
detail = (os.environ.get("IF_ARGS_DETAIL") or "").strip()
missing = []
if not impact:
    impact = "<FILL: conflict | stale-record | grew-scope | none>"
    missing.append("--impact")
if not detail:
    detail = "<FILL: one sentence — which of ITS assumptions this breaks>"
    missing.append("--detail")

for i, wt in enumerate(owed, 1):
    # THE ADDRESS. A notice addressed to something the witness cannot credit
    # discharges nothing, so the generator uses the unique spawn name when the
    # exact join resolved it and says so out loud when it did not.
    to = wt.get("resolved_name") or ""
    addr_note = ""
    if not to:
        to = wt.get("agent_id") or os.path.basename(wt["path"].rstrip("/"))
        addr_note = ("NO EXACT NAME JOIN (%s). Check this address before sending: a "
                     "notice the witness cannot credit will not clear the debt."
                     % wt.get("name_source", "unresolved"))

    # PATHS, from the predicate. Overlap when there is overlap — that is the
    # merge-conflict case and it is the thing worth naming. Otherwise the size
    # of the move, which is the honest answer to "does this touch me".
    if wt["overlap"]:
        shown = wt["overlap"][:8]
        paths = " ".join(shown)
        if len(wt["overlap"]) > len(shown):
            paths += " (+%d more)" % (len(wt["overlap"]) - len(shown))
    else:
        paths = ("none of yours (%d file(s) in %d commit(s) moved)"
                 % (len(wt["moved_paths"]), len(wt["moved_shas"])))

    ack_paths = " ".join(wt["overlap"][:8]) if wt["overlap"] else "none"
    # NO SINGLE QUOTES ANYWHERE IN THIS PYTHON: it lives inside a single-quoted
    # shell string, and one would end it — silently turning the pipes in
    # <conflict|stale-record|...> into shell pipes.
    ack_cmd = ("scripts/inflight-ack.sh --sha %s --impact <conflict|stale-record|grew-scope|none> "
               "--detail \"<40+ chars, your own words>\" --paths \"%s\"" % (tip, ack_paths))
    if wt.get("resolved_name"):
        ack_cmd += " --teammate %s" % wt["resolved_name"]

    print("")
    print("=== notice %d of %d ===" % (i, len(owed)))
    print("  SendMessage to : %s" % to)
    print("  worktree       : %s" % wt["path"])
    if addr_note:
        print("  ** %s" % addr_note)
    if wt["overlap"]:
        print("  ** OVERLAPS %d of its own file(s) — the merge-conflict case." % len(wt["overlap"]))
    print("  --------------------------- message body ---------------------------")
    print("  main moved to %s" % tip)
    print("  impact: %s" % impact)
    print("  detail: %s" % detail)
    print("  paths: %s" % paths)
    print("  ack: %s" % ack_cmd)
    print("  --------------------------------------------------------------------")

print("")
if missing:
    # NOTE the wording: this line must NOT contain the FILL marker itself, or a
    # reader counting the markers to prove there are exactly two would count it.
    print("  %s not given, so %s left as a FILL placeholder in the body above."
          % (" and ".join(missing), "it is" if len(missing) == 1 else "they are"))
    print("  Pass them and the body comes out ready to send:")
    print("      scripts/inflight-notify.sh notice --impact <kind> --detail \"<one sentence>\"")
print("  sha, paths and teammate are GENERATED from the same predicate the guard")
print("  refuses on. impact and detail are the only two fields that are yours.")
print("  RELEVANCE IS STILL YOURS TOO: the costlier of the two failures this")
print("  mechanism exists for had ZERO file overlap. Waive with a reason, or send.")
'
        RC=$?
        exit "$RC" ;;

    waive)
        [ -n "$TARGET" ] || { echo "inflight-notify.sh waive: give the worktree path to waive." >&2; exit 2; }
        [ -n "$REASON" ] || { echo "inflight-notify.sh waive: --reason is required. A waiver with no reason is a silent skip wearing a ledger row." >&2; exit 2; }
        if [ -z "$TEAMS_DIR" ]; then
            {
                echo "inflight-notify.sh waive: could not resolve a session team directory to record the waiver in."
                echo "  tried: $(inflight_teams_dir_how "$SESSION_ID")"
                echo "  Either:"
                echo "    INFLIGHT_TEAMS_DIR=<dir>   the directory session-* dirs live under, OR one team directory itself"
                echo "    --session <id>             name the session whose ledgers to use"
            } >&2
            exit 2
        fi
        IF_ARGS_REPO="$REPO" IF_ARGS_TIP="$TIP" IF_ARGS_TEAMS="$TEAMS_DIR" \
        IF_ARGS_TMO="$TIMEOUT_MIN" IF_ARGS_TARGET="$TARGET" IF_ARGS_REASON="$REASON" \
        IF_ARGS_SID="$SESSION_ID" IF_ARGS_TRANSCRIPT="$TRANSCRIPT" \
        IF_LIB_DIR="$SCRIPT_DIR/lib" python3 -c '
import json, os, sys, getpass
from datetime import datetime, timezone
sys.path.insert(0, os.environ["IF_LIB_DIR"])
import inflight

repo = os.environ["IF_ARGS_REPO"]
teams = os.environ["IF_ARGS_TEAMS"]
target = inflight.norm(os.environ["IF_ARGS_TARGET"])
reason = os.environ["IF_ARGS_REASON"]
res = inflight.assess(repo, os.environ["IF_ARGS_TIP"] or None, teams,
                      int(os.environ["IF_ARGS_TMO"]),
                      os.environ.get("IF_ARGS_SID", ""),
                      os.environ.get("IF_ARGS_TRANSCRIPT", ""))
match = None
for wt in res["worktrees"]:
    if inflight.norm(wt["path"]) == target:
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
