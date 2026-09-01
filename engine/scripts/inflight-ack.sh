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
# A file in your own worktree is different in the one way that matters: the
# lead can stat it. It does not depend on delivery, it does not depend on the
# lead's context surviving, and it is still there after the session that sent
# the message has ended.
#
#     <your worktree>/.claude/inflight-acks/<first-12-of-sha>.<you>.ack
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
#                   [--worktree <path>] [--teammate <name>]
#
# --worktree defaults to the top level of the git worktree you are standing in,
# which is right whenever you run this from your own workspace.
# --teammate defaults to that worktree's directory name, which the lead's sweep
# already treats as one of your addresses — so the collision above is closed
# without anybody having to remember a new flag.

set -uo pipefail

SHA=""; IMPACT=""; DETAIL=""; PATHS=""; WT=""; TEAMMATE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --sha)      SHA="${2:-}"; shift 2 ;;
        --impact)   IMPACT="${2:-}"; shift 2 ;;
        --detail)   DETAIL="${2:-}"; shift 2 ;;
        --paths)    PATHS="${2:-}"; shift 2 ;;
        --worktree) WT="${2:-}"; shift 2 ;;
        --teammate) TEAMMATE="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '3,72p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "inflight-ack.sh: unrecognized argument '$1'" >&2; exit 2 ;;
    esac
done

die() { echo "inflight-ack.sh: $*" >&2; exit 2; }

[ -n "$WT" ] || WT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$WT" ] || die "not inside a git worktree, and no --worktree given."
[ -d "$WT" ] || die "worktree does not exist: $WT"

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
mkdir -p "$ACK_DIR" || die "could not create $ACK_DIR"

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

{
    printf 'sha: %s\n' "$SHA"
    printf 'impact: %s\n' "$IMPACT"
    printf 'detail: %s\n' "$DETAIL"
    printf 'paths: %s\n' "$PATHS"
    printf 'teammate: %s\n' "$TEAMMATE"
    printf 'worktree: %s\n' "$WT"
    printf 'written: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$ACK_FILE" || die "could not write $ACK_FILE"

echo "ack written: $ACK_FILE"
echo "  The lead verifies this with  scripts/inflight-notify.sh acks  — it needs no"
echo "  message from you and no reply from anyone. Carry on with your work."
