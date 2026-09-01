#!/usr/bin/env bash
#
# guard-inflight-notify.sh — BLOCKING PreToolUse guard on the Bash tool.
#
# REFUSES A LAND THAT LEAVES A LIVE TEAMMATE BEHIND AND UN-NOTIFIED.
#
# The predicate — who is in flight, what moved under them, who was told, and
# what an ack has to contain — lives in scripts/lib/inflight.py and NOWHERE
# ELSE. Read that file first; this one is the wiring and the refusal.
#
# ===========================================================================
# THE FAILURE
# ===========================================================================
# Landing moves `main`. Every teammate still working was cut from an older base
# and is now silently behind. Nothing tells them; the lander is the only thing
# that can. Twice on 2026-08-30 the lander did not, and both are written up by
# name in rich-lander/SKILL.md §8b: a techy renderer landed under an agent
# building the splash screen from the same base (eight conflicting hunks across
# five files, one extra agent to resolve them), and twelve new design
# variations landed under an agent building a library from the seven that
# existed at its spawn (shipped 7 of 19, another agent, another round).
#
# §8b is the specification. It is also a paragraph, and a paragraph is a
# promise. This is the machine underneath it.
#
# ===========================================================================
# WHY `git push`, AND NOTHING ELSE — the chokepoint, argued from evidence
# ===========================================================================
# The land sequence is: merge (step 4), verify (5), PUSH (6), deploy (7),
# remove the worktree (8), sweep the in-flight teammates (8b).
#
#   `git merge` — REJECTED, and it is the obvious candidate, so here is why.
#     The merge is the moment the debt is CREATED, but the notice must name the
#     SHA that main moved TO, and at PreToolUse time on the merge that commit
#     does not exist yet. A guard there could only ever enforce the PREVIOUS
#     land's debt — a whole land of lag, and a refusal aimed at a lander who is
#     midway through discharging it. Worse coverage, worse experience.
#
#   `git push origin main` — CHOSEN. By this point the merge commit exists, so
#     the tip is nameable and the debt is real, current, and dischargeable
#     inside the SAME land: send the messages, then push. It happens exactly
#     once per land, it is the orchestrator's exclusive act (engineers never
#     push), and it is non-optional in the sequence, so it cannot be walked
#     around by doing the work differently.
#
#   Anything else — not matched, and stated as a gap rather than left to be
#     discovered: a land that MERGES AND NEVER PUSHES is not caught here. That
#     tail is covered by notice-inflight-acks.sh, the Stop-hook notice, which
#     reports outstanding debt at the end of every turn regardless of how the
#     turn got there.
#
# ONLY AT A LANDING: the main checkout, attached HEAD, on main/master. An
# engineer pushing a worktree branch has moved nothing anyone is reading, and
# blocking them would block the wrong person entirely. That exit is SCOPE, and
# it is silent for the same reason guard-row-currency-commits.sh's is.
#
# ===========================================================================
# JURISDICTION: THE REPOSITORY BEING PUSHED, NOT THE SEAT
# ===========================================================================
# This operation's own shape is a session seated in one repository landing work
# in another (femcboost seat, richos worktrees). guard-row-currency-commits.sh
# learned this the expensive way — an unadopted seat exited before the check
# and a whole repository's contract was read by nothing at all. So the seat
# decides nothing here: the repository the push is FOR is resolved from `-C` /
# the payload cwd, and that repository is what gets swept.
#
# ===========================================================================
# WHAT IT GUARANTEES, AND THE TWO THINGS IT DOES NOT
# ===========================================================================
# GUARANTEED: no land completes while a live teammate is behind with no
# witnessed notice naming this tip. The witness is written by a hook inside the
# lead's own SendMessage call (notice-inflight-sends.sh), so the only way to
# produce it is to actually send the message.
#
# NOT GUARANTEED, 1 — THE ACK. A missing ack does NOT block. It cannot: at push
# time the message is seconds old and the teammate has not had a tool round
# yet. Blocking a land until another party acts is how a guard wedges a
# session. The ack is surfaced by the Stop-hook notice on a measured timeout,
# and the operator escalates. Said plainly: THE SEND IS ENFORCED, THE ACK IS
# SURFACED.
#
# NOT GUARANTEED, 2 — RELEVANCE. Whether the move actually breaks a given
# teammate's assumptions is a human judgment; see inflight.py on why path
# overlap is reported and never used as a filter. This guard forces every live
# teammate to be CONSIDERED and a decision to be RECORDED. It cannot make the
# decision good.
#
# THE ESCAPE HATCH IS A COMMAND, NOT A TOKEN. Other guards take a live prompt
# line (main-checkout-run:, resume-ack:). A Bash payload is the wrong place for
# one — the marker would sit in the same command line it excuses, forgeable by
# reflex and invisible afterwards. Instead:
#
#     scripts/inflight-notify.sh waive <worktree> --reason "<why>"
#
# which appends a dated, attributed row to inflight-waivers.jsonl naming the
# tip, the worktree and the reason. Auditable, never silent, and it survives
# the session that issued it.
#
# FAIL-CLOSED on a missing python3 or a missing predicate: a guard that cannot
# run must not report that it looked.
#
# NOTE: hooks are snapshotted at session start. This one is INERT until the
# next session — it assumes nothing about being live in the session that adds it.

set -eo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-inflight-notify.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/guard-inflight-notify.sh"
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

# --- JURISDICTION ----------------------------------------------------------
# Deliberately BELOW the root-resolution bootstrap, never inside it: Layer R of
# contract-integrity-probe.sh extracts that block verbatim and asserts it is
# byte-identical across every rooted hook.
#
# The seat resolved above answers "am I governed?". It does NOT answer "does the
# repository I was just handed belong to the one I govern?" — and this guard is
# the case where those differ routinely: a session seated in one repository
# landing work in another is the normal shape here, not an edge.
_SJ_LIB="$SCRIPT_DIR/../lib/seat-jurisdiction.sh"
if [ ! -f "$_SJ_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-inflight-notify.sh"
        echo "  scripts/lib/seat-jurisdiction.sh is missing at: $_SJ_LIB"
        echo "  Without it this guard cannot tell whether the repository it was"
        echo "  handed belongs to the one it governs, and a guard that cannot"
        echo "  tell must not answer."
    } >&2
    exit 2
fi
# shellcheck source=../lib/seat-jurisdiction.sh
. "$_SJ_LIB"

_IF_LIB="$SCRIPT_DIR/../lib/inflight.sh"
if [ ! -f "$_IF_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-inflight-notify.sh"
        echo "  scripts/lib/inflight.sh is missing at: $_IF_LIB"
        echo "  This guard's entire predicate lives behind it. Without it it cannot"
        echo "  tell a notified teammate from a forgotten one, and it will not guess."
    } >&2
    exit 2
fi
# shellcheck source=../lib/inflight.sh
. "$_IF_LIB"

INPUT="$(cat)"

if resolve_entity_root "$INPUT"; then
    SEAT_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # DELIBERATELY NOT AN EXIT — the row-currency lesson. The seat answers "am I
    # governed?", not "which repository is this push for?". A session seated in
    # an unadopted repo can still be landing work in an adopted one, and exiting
    # here is exactly how a repository's contract ends up read by nothing.
    SEAT_ROOT=""
else
    root_failure_banner "scripts/hooks/guard-inflight-notify.sh" >&2
    exit 2
fi

# --- Is this a push of main, and where? ------------------------------------
# Parsed as a COMMAND LINE, not matched as a substring: `echo "git push"` is not
# a push, and a guard that thinks it is teaches people it cries wolf. Assigned
# via a quoted heredoc first for the bash 3.2 reason guard-worktree-removal.sh
# documents — a ')' inside a character class mis-scans as the close of a $( )
# substitution on macOS's /bin/bash.
read -r -d '' _IF_CLASSIFIER <<'PYEOF' || true
import json, os, re, shlex, sys

def out(*fields):
    sys.stdout.write("\t".join(str(f) for f in fields) + "\n")
    raise SystemExit

try:
    d = json.loads(os.environ.get("GUARD_PAYLOAD") or "{}")
except Exception:
    out("PASS")
if not isinstance(d, dict) or d.get("tool_name") != "Bash":
    out("PASS")
ti = d.get("tool_input") or {}
cmd = (ti.get("command", "") if isinstance(ti, dict) else "") or ""
cwd = str(d.get("cwd", "") or "")
sid = str(d.get("session_id", "") or "")
# The lead's own transcript, carried on every hook payload. It holds the ONLY
# complete name -> agent id join (Agent tool_use -> toolUseResult.agentId), so
# it is passed through to the predicate rather than left to be rediscovered.
tpath = str(d.get("transcript_path", "") or "")

if not re.search(r"\bgit\b", cmd):
    out("PASS")

for seg in re.split(r"(?:\|\||&&|[;\n|])", cmd):
    try:
        argv = shlex.split(seg, comments=False)
    except ValueError:
        continue
    while argv and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[0]):
        argv.pop(0)
    if not argv or os.path.basename(argv[0]) != "git":
        continue
    repo = ""
    k = 1
    sub = ""
    while k < len(argv):
        a = argv[k]
        if a == "-C" and k + 1 < len(argv):
            repo = argv[k + 1]; k += 2; continue
        if a.startswith("--git-dir") or a.startswith("--work-tree"):
            k += 2 if "=" not in a else 1
            continue
        if a == "-c" and k + 1 < len(argv):
            k += 2; continue
        if a.startswith("-"):
            k += 1; continue
        sub = a
        k += 1
        break
    if sub != "push":
        continue
    rest = argv[k:]
    if "--dry-run" in rest or "-n" in rest or "--delete" in rest:
        continue
    positional = [a for a in rest if not a.startswith("-")]
    # positional[0] is the remote; anything after it is a refspec.
    refspecs = positional[1:] if len(positional) > 1 else []
    out("ACT", repo, cwd, sid, " ".join(refspecs), tpath)

out("PASS")
PYEOF

CLASS="$(GUARD_PAYLOAD="$INPUT" python3 -c "$_IF_CLASSIFIER" 2>/dev/null || printf 'PASS')"
[ "$(printf '%s' "$CLASS" | cut -f1)" = "ACT" ] || exit 0

REPO_HINT="$(printf '%s' "$CLASS" | cut -f2)"
PAYLOAD_CWD="$(printf '%s' "$CLASS" | cut -f3)"
SESSION_ID="$(printf '%s' "$CLASS" | cut -f4)"
REFSPECS="$(printf '%s' "$CLASS" | cut -f5)"
TRANSCRIPT="$(printf '%s' "$CLASS" | cut -f6)"

ANCHOR="${REPO_HINT:-${PAYLOAD_CWD:-$PWD}}"
case "$ANCHOR" in
  /*) ;;
  *) ANCHOR="${PAYLOAD_CWD:-$PWD}/$ANCHOR" ;;
esac

REPO="$(git -C "$ANCHOR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO" ] || exit 0

# --- ONLY AT A LANDING (scope, not a skipped check) ------------------------
BRANCH="$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null || true)"
case "$BRANCH" in
  main|master) ;;
  *) exit 0 ;;                       # detached, or an engineer's branch
esac
# A refspec that names something other than the current branch is not this land.
if [ -n "$REFSPECS" ] && ! printf '%s' "$REFSPECS" | grep -q "$BRANCH"; then
    exit 0
fi
MAIN_CHECKOUT="$(IF_LIB_DIR="$SCRIPT_DIR/../lib" IF_REPO="$REPO" python3 -c '
import os, sys
sys.path.insert(0, os.environ["IF_LIB_DIR"])
import inflight
print(inflight.main_checkout(os.environ["IF_REPO"]))
' 2>/dev/null || true)"
[ -n "$MAIN_CHECKOUT" ] || MAIN_CHECKOUT="$REPO"
[ "$(cd "$REPO" && pwd -P)" = "$(cd "$MAIN_CHECKOUT" && pwd -P)" ] || exit 0

# The seat is REPORTED when it differs from the repository being pushed, and
# never obeyed. A guard that switched itself off on a seat mismatch would have
# let through exactly the cross-repository land this whole mechanism exists for.
if [ -n "${SEAT_ROOT}" ]; then
    richos_assert_jurisdiction "scripts/hooks/guard-inflight-notify.sh" "${SEAT_ROOT}" "$REPO" "push in" || true
fi

inflight_require || {
    echo "ERROR: guard-inflight-notify.sh: $INFLIGHT_BROKEN — refusing (fail-closed), because a sweep that cannot run is not a sweep." >&2
    exit 2
}

TEAMS_DIR="$(inflight_teams_dir "$SESSION_ID")"
TIMEOUT_MIN="$(inflight_timeout_min "${SEAT_ROOT:-$REPO}")"
inflight_register_repo "$TEAMS_DIR" "$REPO"

# `set -e` is on, and a debt is signalled by exit 1 — so the status is captured
# with `|| RC=$?` rather than a bare `$?`, which would end the hook on the very
# condition it exists to report.
RC=0
REPORT="$(inflight_assess "$REPO" "" "$TEAMS_DIR" "$TIMEOUT_MIN" text "$SESSION_ID" "$TRANSCRIPT" 2>/dev/null)" || RC=$?

case "$RC" in
  0) exit 0 ;;                       # nothing in flight, or everyone disposed of
  1) ;;                              # at least one live teammate is un-notified
  *)
    echo "ERROR: guard-inflight-notify.sh: the in-flight predicate could not run — refusing (fail-closed)." >&2
    printf '%s\n' "$REPORT" >&2
    exit 2 ;;
esac

TIP="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
{
    echo "=== IN-FLIGHT SWEEP: THIS PUSH LEAVES A LIVE TEAMMATE BEHIND — REFUSING ==="
    echo "  repository : $REPO"
    echo "  tip        : $TIP"
    echo ""
    echo "  Main has moved. The teammate(s) marked OWED-NO-NOTICE below were cut"
    echo "  from an older base, are still live, and nothing has told them. That is"
    echo "  the exact failure rich-lander/SKILL.md §8b was written from — twice in"
    echo "  one day, costing two extra agents."
    echo ""
    printf '%s\n' "$REPORT"
    echo ""
    echo "  TO CLEAR THIS, per §8b — for each one, either:"
    echo ""
    echo "   1. MESSAGE IT. Say what changed, NAME THE SHA $TIP verbatim in the"
    echo "      body (that is what the witness matches on), and say which of its"
    echo "      assumptions it breaks. Ask for the ack, and tell it the command:"
    echo "        scripts/inflight-ack.sh --sha $TIP --impact <conflict|stale-record|grew-scope|none> \\"
    echo "            --detail \"<its own words>\" --paths \"<paths or none>\""
    echo "      The send itself is the record — no file to write, nothing to"
    echo "      remember. Then re-run this push."
    echo ""
    echo "   2. WAIVE IT, on the record:"
    echo "        scripts/inflight-notify.sh waive <worktree-path> --reason \"<why>\""
    echo ""
    echo "  See what you are deciding about first:"
    echo "        scripts/inflight-notify.sh status"
    echo "(hook: scripts/hooks/guard-inflight-notify.sh)"
} >&2
exit 2
