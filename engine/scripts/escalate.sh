#!/usr/bin/env bash
#
# escalate.sh — RAISE AN ESCALATION THAT CANNOT QUIETLY FAIL TO ARRIVE.
#
# One call, from your own worktree, and you are done. The argument for every
# design decision here — why a ledger rather than a file, why it lives outside
# every repository, why `state` is required, why an unacknowledged escalation
# gets louder — is in scripts/lib/escalations.py. Read that if you want the
# reasoning; you do not need it to use this.
#
# ===========================================================================
# WHAT THIS REPLACES, AND WHY
# ===========================================================================
# The old protocol was: write `BLOCKED.md` at the root of your worktree, commit
# it, and send a one-line message. Two teammates did exactly that on 2026-09-02.
# Both were right to. Their escalations were found on 2026-09-04 by a worktree
# cleanup, because somebody was counting directories.
#
# A file on your branch is only ever seen by whoever merges your branch, and you
# cannot see whether your branch was merged. The repository root, separately, is
# now nine entries by permanent CEO ruling — so that write would be refused
# today with nowhere obvious to go.
#
# So this writes the escalation to a LEDGER OUTSIDE EVERY REPOSITORY, which the
# lead's session reads at every session start and at every turn end WITHOUT
# ANYTHING BEING MERGED. It also writes a record file under `docs/verification/`
# — the home the same ruling names — but NOTHING DEPENDS ON THAT FILE. It is
# the record; the ledger row is the delivery.
#
# ===========================================================================
# USAGE — the teammate's half is one command
# ===========================================================================
#   escalate.sh raise --title "<one line>" \
#                     --state work-complete|proceeding|stopped \
#                     --question "<the smallest question that would unblock>" \
#                     [--for lead|ceo] \
#                     [--tried "<what you already tried>"] \
#                     [--meanwhile "<what you are proceeding on>"] \
#                     [--worktree <path>] [--teammate <name>] [--no-record]
#
#       --state IS REQUIRED, and it is the field that keeps this channel alive:
#         work-complete  the work is DONE; this is a record, NOT a stall
#         proceeding     raised, and still working on everything else
#         stopped        the whole task depends on the answer; work has stopped
#       Both of the 2026-09-02 originals were `work-complete`. A mechanism that
#       read every escalation as a failure would teach you not to raise them.
#
#       --for names whose answer it is. `ceo` means only the CEO can decide it;
#       the lead's job is then to route it or decide, but not neither.
#
# ===========================================================================
# USAGE — the lead's half
# ===========================================================================
#   escalate.sh list                 every outstanding escalation, in full
#   escalate.sh show <id>            one, with its acknowledgements
#   escalate.sh ack <id> --disposition "<what you decided or did>"
#
#       `ack` APPENDS; nothing is ever deleted. The disposition must be at
#       least 30 characters, because an ack with no disposition is a dismissal
#       wearing a ledger row.
#
# Exit codes:
#   raise  0 delivered · 2 refused (bad arguments) or NOT DELIVERED (ledger
#          write failed — and it says so in those words)
#   list   0 nothing outstanding · 1 at least one outstanding · 2 unreadable
#   ack    0 recorded · 1 already acknowledged · 2 refused
#   show   0 found · 2 no such escalation

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalations.sh
. "$SCRIPT_DIR/lib/escalations.sh"

# The whole leading comment block, minus the shebang — so a header that grows
# does not silently stop being the help text.
usage() { sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

CMD="${1:-list}"
[ "$#" -gt 0 ] && shift || true
case "$CMD" in
    -h|--help|help) usage; exit 0 ;;
esac

TITLE=""; STATE=""; AUDIENCE="lead"; QUESTION=""; TRIED=""; MEANWHILE=""
WT=""; TEAMMATE=""; DISPOSITION=""; TARGET=""; NO_RECORD=0; FORMAT="text"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --title)       TITLE="${2:-}"; shift 2 ;;
        --state)       STATE="${2:-}"; shift 2 ;;
        --for)         AUDIENCE="${2:-}"; shift 2 ;;
        --question)    QUESTION="${2:-}"; shift 2 ;;
        --tried)       TRIED="${2:-}"; shift 2 ;;
        --meanwhile)   MEANWHILE="${2:-}"; shift 2 ;;
        --worktree)    WT="${2:-}"; shift 2 ;;
        --teammate)    TEAMMATE="${2:-}"; shift 2 ;;
        --disposition) DISPOSITION="${2:-}"; shift 2 ;;
        --format)      FORMAT="${2:-}"; shift 2 ;;
        --no-record)   NO_RECORD=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)  echo "escalate.sh: unrecognized option '$1'" >&2; exit 2 ;;
        *)   if [ -n "$TARGET" ]; then echo "escalate.sh: unexpected argument '$1'" >&2; exit 2; fi
             TARGET="$1"; shift ;;
    esac
done

escalations_require || {
    echo "escalate.sh: $ESCALATIONS_BROKEN — the escalation channel cannot run here." >&2
    echo "  YOUR ESCALATION HAS NOT BEEN RAISED. Put it verbatim in your final report and in" >&2
    echo "  your commit message, and say that this command could not run." >&2
    exit 2
}

case "$CMD" in
    list)
        escalations_list "$FORMAT"
        exit $? ;;

    show)
        [ -n "$TARGET" ] || { echo "escalate.sh show: give the escalation id. \`escalate.sh list\` has them." >&2; exit 2; }
        python3 "$ESCALATIONS_PY" show --id "$TARGET"
        exit $? ;;

    ack)
        [ -n "$TARGET" ] || { echo "escalate.sh ack: give the escalation id. \`escalate.sh list\` has them." >&2; exit 2; }
        python3 "$ESCALATIONS_PY" ack --id "$TARGET" --disposition "$DISPOSITION"
        exit $? ;;

    raise) ;;

    *)  echo "escalate.sh: unknown subcommand '$CMD'" >&2; usage >&2; exit 2 ;;
esac

# ===========================================================================
# raise
# ===========================================================================
# EVERYTHING MECHANICAL IS DERIVED. The worktree, its branch, its HEAD and your
# name come from the workspace you are standing in — the same generator
# argument scripts/inflight-notify.sh makes about notices: the fields a machine
# can fill are filled, and the operator's fields are the only ones left. Four
# are yours: title, state, question, and whichever of tried/meanwhile apply.
[ -n "$WT" ] || WT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$WT" ] || WT="$PWD"
BRANCH="$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null || git -C "$WT" rev-parse --short HEAD 2>/dev/null || true)"
HEAD_SHA="$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)"
# The repository NAME, not a path: a worktree path is per-agent and means
# nothing to a reader three days later, while "richos" or "femcboost" does.
REPO_NAME="$(basename "$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null | sed 's|/\.git$||; s|/\.git/worktrees/.*$||' || true)" 2>/dev/null || true)"
case "$REPO_NAME" in ""|.|.git) REPO_NAME="$(basename "${WT%/}")" ;; esac

# Your name defaults to the worktree's own directory name — the same default
# scripts/inflight-ack.sh uses, and one the lead's sweeps already treat as one
# of your addresses. Nothing new has to be remembered.
[ -n "$TEAMMATE" ] || TEAMMATE="$(basename "${WT%/}")"

# --- WHERE THE RECORD FILE GOES, AND WHY IT MAY GO NOWHERE -----------------
# `docs/verification/escalations/`, per ceo-decisions.md 27, which names
# `docs/verification/` as the home for a block record — and NEVER at a
# repository root, which is nine entries by permanent ruling.
#
# It is written ONLY into a `docs/` directory that ALREADY EXISTS. Creating
# `docs/` in a repository that has none would add a root entry, which is the
# very rule this is obeying. A repository without one gets the ledger row and
# no file, and this says so rather than failing.
RECORD=""
RECORD_NOTE=""
if [ "$NO_RECORD" -eq 0 ]; then
    if [ -d "$WT/docs" ]; then
        RECORD_DIR="$WT/docs/verification/escalations"
        SLUG="$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' | cut -c1-60)"
        [ -n "$SLUG" ] || SLUG="escalation"
        RECORD="$RECORD_DIR/$(date -u +%Y-%m-%d)-$TEAMMATE-$SLUG.md"
    else
        RECORD_NOTE="no docs/ directory in $WT, so no record file was written — writing one would have created a new root entry, which ceo-decisions.md 27 forbids. The ledger row below IS the escalation."
    fi
fi

# --- THE LEDGER ROW FIRST, THE FILE SECOND ---------------------------------
# Deliberate order. The ledger is the DELIVERY and the file is the RECORD, so a
# file write that fails — a read-only tree, a guard, a full disk — must not be
# able to stop the escalation from arriving. The reverse order would put the
# thing that failed before in front of the thing that replaced it.
OUT="$(python3 "$ESCALATIONS_PY" raise \
    --title "$TITLE" --state "$STATE" --for "$AUDIENCE" --question "$QUESTION" \
    --tried "$TRIED" --meanwhile "$MEANWHILE" \
    --teammate "$TEAMMATE" --worktree "$WT" --branch "$BRANCH" \
    --repo "$REPO_NAME" --head "$HEAD_SHA" --record "$RECORD")"
RC=$?
[ "$RC" -eq 0 ] || exit "$RC"

ID="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)"
LEDGER="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ledger"])' 2>/dev/null || escalations_ledger)"

if [ -n "$RECORD" ]; then
    if mkdir -p "$(dirname "$RECORD")" 2>/dev/null; then
        {
            printf '# Escalation: %s\n\n' "$TITLE"
            printf -- '- id: `%s`\n' "$ID"
            printf -- '- raised: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf -- '- from: %s\n' "$TEAMMATE"
            printf -- '- worktree: `%s` (branch `%s`)\n' "$WT" "$BRANCH"
            [ -n "$HEAD_SHA" ] && printf -- '- head: `%s`\n' "$HEAD_SHA"
            printf -- '- state: **%s**\n' "$STATE"
            printf -- '- for: %s\n\n' "$AUDIENCE"
            printf '## The question\n\n%s\n\n' "$QUESTION"
            if [ -n "$TRIED" ]; then printf '## What was already tried\n\n%s\n\n' "$TRIED"; fi
            if [ -n "$MEANWHILE" ]; then printf '## Proceeding meanwhile\n\n%s\n\n' "$MEANWHILE"; fi
            printf '## How this reaches the lead\n\n'
            printf 'This file is the RECORD, not the delivery. The escalation was written to the\n'
            printf 'engine escalation ledger at `%s` as `%s`, which the\n' "$LEDGER" "$ID"
            printf "lead's session reads at session start and at every turn end WITHOUT this branch\n"
            printf 'being merged. If this file is never landed, the escalation still arrives.\n\n'
            printf 'Close it with:\n\n    escalate.sh ack %s --disposition "<what you decided or did>"\n' "$ID"
        } > "$RECORD" 2>/dev/null || {
            RECORD_NOTE="the record file could not be written to $RECORD. The ledger row was written first for exactly this reason, so the escalation IS raised."
            RECORD=""
        }
    else
        RECORD_NOTE="could not create $(dirname "$RECORD"). The ledger row was written first for exactly this reason, so the escalation IS raised."
        RECORD=""
    fi
fi

echo "escalation RAISED: $ID"
echo "  ledger  : $LEDGER"
echo "            ^^ outside every repository and every session. It reaches the lead with"
echo "               NO MERGE, and it survives this session, this worktree and you."
if [ -n "$RECORD" ]; then
    echo "  record  : $RECORD"
    echo "            Commit it with your work. Nothing depends on it being merged."
fi
[ -n "$RECORD_NOTE" ] && echo "  note    : $RECORD_NOTE"
echo "  state   : $STATE"
echo "  for     : $AUDIENCE"
echo ""
echo "  It is announced to the lead at every session start and at every turn end, and it"
echo "  gets LOUDER at 1h, 24h and 72h until somebody acknowledges it. You do not have to"
echo "  chase it, wait for a reply, or check that it arrived."
echo ""
echo "  OPTIONAL, and only a doorbell: SendMessage to team-lead saying you raised $ID."
echo "  The mailbox drops roughly half of what crosses it, which is why it is no longer"
echo "  the thing your escalation depends on. Now carry on with your work."
exit 0
