#!/usr/bin/env bash
#
# inflight-ack.sh — THE TEAMMATE'S HALF. Run by a teammate, in its own
#                    worktree, to prove it holds a fact the lead just sent.
#
# ===========================================================================
# WHY AN ARTIFACT AND NOT A REPLY
# ===========================================================================
# The lead can never verify a reply it did not receive, and the teammate->lead
# mailbox is measured at roughly 50% loss. On 2026-08-30 the lead sent two
# receipt checks to one teammate and sat waiting for answers that never came;
# whether they were sent or dropped is, from the lead's side, unknowable — and
# that unknowability is the whole problem. Nothing built on that channel can be
# a guarantee.
#
# A file the lead can stat is different from a reply in the one way that
# matters: it does not depend on delivery, and it does not depend on the lead's
# context surviving. But WHERE that file lives turned out to matter more than
# the fact that it is a file.
#
# ===========================================================================
# TWO PLACES, AND ONLY ONE OF THEM SURVIVES YOU
# ===========================================================================
# THE DURABLE ROW — the one that counts:
#
#     ~/.claude/state/inflight-acks.jsonl
#
# THE READABLE FILE — a convenience, and where acks used to live alone:
#
#     <your worktree>/.claude/inflight-acks/<first-12-of-sha>.<you>.ack
#
# UNTIL 2026-09-05 THERE WAS ONLY THE SECOND ONE, AND IT WAS DELETED THE MOMENT
# YOU FINISHED. Both repositories this engine governs ignore `.claude/*`, so an
# ack is an untracked write; the harness auto-cleans an isolation worktree that
# is UNCHANGED at completion; and a gitignored write does not make a tree
# changed. An agent whose only writes were acks therefore had its worktree, and
# every ack in it, removed on completion. echo-opus-529 wrote three acks on
# 2026-09-05, reported them by path, and named the ignore rule itself in its
# handoff; all three are gone. zach-opus-not1 hit the other end: after its
# worktree was cleaned THIS SCRIPT refused its next ack outright with "worktree
# does not exist", so it could not answer at all.
#
# An ack that was written, confirmed and then deleted reads exactly like an ack
# that was never written — and the 30-minute Stop-hook timeout then tells the
# operator to chase a teammate that already complied.
#
# So the ledger row is now the authority and the file is the human-readable
# mirror. The ledger sits beside ~/.claude/state/worktree-ledger.jsonl and
# ~/.claude/state/escalations.jsonl for the same reason those do: it is outside
# every repository, every worktree and every session, because all three of
# those are disposable and the fact is not.
#
# IF THE LEDGER ROW CANNOT BE WRITTEN, THIS COMMAND SAYS SO AND EXITS NON-ZERO.
# It does not quietly leave you with a file in a tree that is about to be
# deleted. Your ack is not durable until that row exists.
#
# THE FILENAME CARRIES YOUR NAME AS WELL AS THE SHA, and it did not until
# 2026-09-01. Keyed on the sha alone, two teammates acknowledging the same land
# — which is correct, both were told and both answered — wrote two different
# files at ONE path, and the merge was an add/add conflict. It happened twice
# that night. A lander in a hurry resolves that with `--ours` and destroys the
# evidence that a teammate acknowledged a land, silently. An ack is
# per-teammate-per-sha; the multi-teammate case is the normal one.
#
# ===========================================================================
# WHAT YOU ARE ASSERTING
# ===========================================================================
#   sha     the FULL 40-character commit main moved to. Checked exactly. You
#           cannot produce it without having been told it, which is what makes
#           the file evidence rather than a nod.
#   impact  one of:
#             conflict      — it touched files I have also changed; I will hit
#                             a merge conflict I can avoid now
#             stale-record  — a record I was told to READ changed after my
#                             worktree was cut, so my copy is wrong
#             grew-scope    — the thing I am consuming got bigger; work sized
#                             at spawn time would ship incomplete
#             none          — I have read it and it does not affect me
#           These are §8b's three questions plus "not affected". Choosing one
#           forces a judgment; "got it" forces nothing.
#   detail  >= 40 characters IN YOUR OWN WORDS saying which of your assumptions
#           this breaks. Copying the notice back does not answer the question.
#   paths   the paths this actually lands on, space-separated, or "none". Each
#           must exist in your worktree or in the moved changeset — this is the
#           one field that cannot be filled without looking at your own
#           workspace.
#
# BE HONEST HERE. The verifier checks the shape of what you write and prints
# your `detail` to the lead under the words HUMAN JUDGMENT REQUIRED, because a
# string match is not comprehension and this engine does not pretend otherwise.
# An ack that passes the shape check and says nothing true is worse than none:
# it converts a known unknown into a false green.
#
# Usage:
#   inflight-ack.sh --sha <40-hex> --impact <kind> --detail "<...>" --paths "<a b|none>"
#                   [--worktree <path>] [--teammate <name>] [--repo <path>]
#
# --worktree defaults to the top level of the git worktree you are standing in,
# which is right whenever you run this from your own workspace. IT NO LONGER
# HAS TO STILL EXIST: if your worktree has already been removed under you, pass
# --worktree (and --teammate, since the directory name can no longer be read)
# and the ledger row is written on its own. Refusing that case is what stopped
# zach-opus-not1 answering at all.
# --teammate defaults to that worktree's directory name, which the lead's sweep
# already treats as one of your addresses — so the collision above is closed
# without anybody having to remember a new flag.
# --repo names the repository this ack is about; it defaults to the main
# checkout your worktree belongs to, and is only needed when the worktree is
# gone.
#
# RICHOS_INFLIGHT_ACK_LEDGER overrides the ledger path — that is how the test
# suites keep out of the operator's real ledger, and how a non-standard home is
# handled. Same switch, same spelling, as RICHOS_ESCALATION_LEDGER.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SHA=""; IMPACT=""; DETAIL=""; PATHS=""; WT=""; TEAMMATE=""; REPO=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --sha)      SHA="${2:-}"; shift 2 ;;
        --impact)   IMPACT="${2:-}"; shift 2 ;;
        --detail)   DETAIL="${2:-}"; shift 2 ;;
        --paths)    PATHS="${2:-}"; shift 2 ;;
        --worktree) WT="${2:-}"; shift 2 ;;
        --teammate) TEAMMATE="${2:-}"; shift 2 ;;
        --repo)     REPO="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '3,113p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "inflight-ack.sh: unrecognized argument '$1'" >&2; exit 2 ;;
    esac
done

die() { echo "inflight-ack.sh: $*" >&2; exit 2; }

[ -n "$WT" ] || WT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$WT" ] || die "not inside a git worktree, and no --worktree given."

# A MISSING WORKTREE IS NO LONGER FATAL. It used to be — `[ -d "$WT" ] || die
# "worktree does not exist"` — and that refusal is precisely what left
# zach-opus-not1 unable to acknowledge anything after its own workspace was
# cleaned up. The durable row does not need the directory; only the readable
# mirror does. So the directory's absence downgrades what gets written, loudly,
# instead of refusing the ack.
WT_PRESENT=1
[ -d "$WT" ] || WT_PRESENT=0

printf '%s' "$SHA" | grep -qE '^[0-9a-f]{40}$' \
    || die "--sha must be the FULL 40-character commit main moved to (got '${SHA:-<empty>}'). A short sha is not checkable against the tip."

case "$IMPACT" in
    conflict|stale-record|grew-scope|none) ;;
    *) die "--impact must be one of: conflict stale-record grew-scope none (got '${IMPACT:-<empty>}')." ;;
esac

[ "${#DETAIL}" -ge 40 ] \
    || die "--detail is ${#DETAIL} characters; it needs at least 40, in your own words. Say which of YOUR assumptions this breaks."

[ -n "$PATHS" ] || die "--paths is required. List the paths this lands on, or the word 'none'."

ACK_DIR="$WT/.claude/inflight-acks"
if [ "$WT_PRESENT" -eq 1 ]; then
    mkdir -p "$ACK_DIR" || die "could not create $ACK_DIR"
fi

# --- THE KEY IS PER-TEAMMATE-PER-SHA, NOT PER-SHA --------------------------
# It was `<sha12>.ack`, keyed on the land and nothing else. When two teammates
# both acknowledged the same land — the CORRECT behavior, both were notified and
# both answered — their branches carried two different files at ONE path, and
# the merge was an add/add conflict. That happened twice on 2026-09-01. A lander
# in a hurry resolves such a conflict with `--ours`, and the evidence that a
# teammate acknowledged a land is gone, silently, leaving the witness ledger and
# the worktree disagreeing for a reason nobody can reconstruct.
#
# The default identity is the worktree's own directory name, which is what the
# lead's sweep already treats as one of this teammate's addresses — so nothing
# new has to be configured, remembered, or passed in. --teammate overrides it
# for the case where the two differ.
[ -n "$TEAMMATE" ] || TEAMMATE="$(basename "${WT%/}")"
TEAMMATE_SLUG="$(printf '%s' "$TEAMMATE" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[-.]*//; s/[-.]*$//')"
[ -n "$TEAMMATE_SLUG" ] || TEAMMATE_SLUG="unnamed"
ACK_FILE="$ACK_DIR/$(printf '%s' "$SHA" | cut -c1-12).$TEAMMATE_SLUG.ack"

# --- PATHS, CHECKED AT THE ONLY MOMENT THEY ARE CHECKABLE ------------------
# `paths` is deliberately the one field that cannot be filled by copying the
# notice, because it is about YOUR workspace. Which means that once your
# workspace is gone, nobody can ever re-verify it — so the check is made HERE,
# now, while the directory still exists, and the result is recorded in the
# ledger row. The reader then reports "verified at ack time, worktree since
# removed" rather than either failing your ack or passing it in silence.
PATHS_PRESENT=""
if [ "$WT_PRESENT" -eq 1 ] && [ "$PATHS" != "none" ]; then
    for _p in $PATHS; do
        if [ -e "$WT/$_p" ]; then
            PATHS_PRESENT="$PATHS_PRESENT $_p"
        fi
    done
fi
PATHS_PRESENT="${PATHS_PRESENT# }"

WRITTEN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- THE REPOSITORY THIS ACK IS ABOUT --------------------------------------
# Recorded so the ledger — which is machine-wide and holds every repository's
# acks — can be scoped to the one being swept. Best effort: an empty repo field
# is read as "unscoped" rather than as a match for everything.
if [ -z "$REPO" ] && [ "$WT_PRESENT" -eq 1 ]; then
    _COMMON="$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [ -n "$_COMMON" ] && REPO="$(dirname "${_COMMON%/}")"
fi

# --- THE DURABLE ROW, AND IT IS NOT OPTIONAL -------------------------------
LEDGER_OUT="$(
    IF_SHA="$SHA" IF_IMPACT="$IMPACT" IF_DETAIL="$DETAIL" IF_PATHS="$PATHS" \
    IF_PRESENT="$PATHS_PRESENT" IF_TEAMMATE="$TEAMMATE" IF_WT="$WT" \
    IF_REPO="$REPO" IF_WHEN="$WRITTEN_AT" IF_ARTIFACT="$ACK_FILE" \
    IF_WT_PRESENT="$WT_PRESENT" IF_LIB_DIR="$SCRIPT_DIR/lib" python3 -c '
import json, os, sys
sys.path.insert(0, os.environ["IF_LIB_DIR"])
import inflight

branch = ""
if os.environ["IF_WT_PRESENT"] == "1":
    branch = inflight.git(os.environ["IF_WT"], "rev-parse", "--abbrev-ref", "HEAD").strip()

row = {
    "timestamp": os.environ["IF_WHEN"],
    "event": inflight.ACK_LEDGER_EVENT,
    "sha": os.environ["IF_SHA"],
    "impact": os.environ["IF_IMPACT"],
    "detail": os.environ["IF_DETAIL"],
    "paths": os.environ["IF_PATHS"],
    "paths_present": os.environ["IF_PRESENT"].split(),
    "teammate": os.environ["IF_TEAMMATE"],
    "worktree": os.environ["IF_WT"],
    "worktree_present_at_ack": os.environ["IF_WT_PRESENT"] == "1",
    "branch": branch,
    "repo": os.environ["IF_REPO"],
    "artifact": os.environ["IF_ARTIFACT"] if os.environ["IF_WT_PRESENT"] == "1" else "",
}
path = inflight.ack_ledger_path()
d = os.path.dirname(path)
if d:
    os.makedirs(d, exist_ok=True)
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row) + "\n")
print(path)
' 2>&1)"
LEDGER_RC=$?

if [ "$LEDGER_RC" -ne 0 ]; then
    {
        echo "inflight-ack.sh: THE DURABLE LEDGER ROW WAS NOT WRITTEN."
        echo "  $LEDGER_OUT"
        echo ""
        echo "  YOUR ACK IS NOT RECORDED. This exits non-zero rather than leaving you"
        echo "  with a file in a worktree that is deleted the moment you finish — which"
        echo "  is the exact failure this ledger was added to remove. Report this"
        echo "  verbatim in your handoff and say the ack could not be written."
    } >&2
    exit 3
fi
LEDGER_PATH="$LEDGER_OUT"

if [ "$WT_PRESENT" -eq 1 ]; then
    {
        printf 'sha: %s\n' "$SHA"
        printf 'impact: %s\n' "$IMPACT"
        printf 'detail: %s\n' "$DETAIL"
        printf 'paths: %s\n' "$PATHS"
        printf 'paths_present: %s\n' "$PATHS_PRESENT"
        printf 'teammate: %s\n' "$TEAMMATE"
        printf 'worktree: %s\n' "$WT"
        printf 'written: %s\n' "$WRITTEN_AT"
        printf 'ledger: %s\n' "$LEDGER_PATH"
    } > "$ACK_FILE" || {
        # The durable row is ALREADY WRITTEN at this point, so the ack itself
        # stands. Only the readable mirror failed, and saying "could not write"
        # without that distinction would send a teammate off to re-ack an ack
        # that is recorded.
        echo "inflight-ack.sh: the durable ledger row WAS written to $LEDGER_PATH," >&2
        echo "  but the readable mirror at $ACK_FILE could not be. Your ack counts;" >&2
        echo "  the convenience copy does not exist. Nothing to redo." >&2
    }
fi

echo "ack recorded: $LEDGER_PATH"
echo "  ^^ THIS is the record that counts. It is outside every repository, every"
echo "     worktree and every session, so it survives your worktree being removed."
if [ "$WT_PRESENT" -eq 1 ]; then
    echo "  readable mirror: $ACK_FILE"
    echo "     (gitignored in both repositories, and deleted with your worktree —"
    echo "      convenience only, never the evidence.)"
else
    echo "  NO readable mirror was written: $WT does not exist."
    echo "     Your worktree is already gone. The ledger row above is the whole ack,"
    echo "     and it is enough — this is the case that used to be refused outright."
fi
echo "  The lead verifies this with  scripts/inflight-notify.sh acks  — it needs no"
echo "  message from you and no reply from anyone. Carry on with your work."
