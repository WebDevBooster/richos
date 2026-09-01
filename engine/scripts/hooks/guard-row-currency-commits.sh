#!/usr/bin/env bash
#
# guard-row-currency-commits.sh — BLOCKING PreToolUse guard on the Bash tool.
#
# Refuses a LANDING whose record no longer describes the work it claims to.
#
# The predicate, the warrant grammar, the precision rules, the override
# decision and the honest list of what none of this can catch all live in
# scripts/lib/row-currency.{sh,py} — one place, because a predicate in two
# copies is the defect class this engine keeps finding in itself. READ THAT
# FILE FIRST; this one is the wiring.
#
# ===========================================================================
# WHY THE COMMIT AND THE MERGE, AND WHY NOTHING ELSE
# ===========================================================================
# The sibling guard-ceo-todos-commits.sh matches `git commit` only, and names
# `git merge` as an accepted gap on the grounds that the merged content was
# gated when it was committed on the source branch. That reasoning does not
# transfer here, and the difference is the whole point of this guard:
#
#   THE MERGE IS NOT A RE-COMMIT OF ALREADY-GATED CONTENT. IT IS THE MOMENT
#   A PROPOSAL BECOMES THE TRUTH THE RECORD IS DESCRIBING.
#
# All four rows that rotted in one day rotted at a merge. A guard on `git
# commit` alone would have watched every one of them go past. So `git merge`
# is matched, and the tree the merge is about to produce is computed exactly
# (`merge-tree --write-tree`) rather than guessed at from the branch tip.
#
# `git cherry-pick`, `git am`, `git rebase` and `git revert` also create
# commits without `git commit`. They are NOT matched, and that is a stated
# gap rather than an oversight: none of them is how work lands here, and a
# guard that tried to model a rebase's eventual tree would be modelling
# instead of measuring.
#
# ===========================================================================
# ONLY AT A LANDING
# ===========================================================================
# Main checkout, attached HEAD. An engineer's worktree branch is a proposal,
# it has changed nothing the record describes, and blocking it would block the
# wrong person on a file they do not own and cannot reach from there. That
# exit is SCOPE, not a skipped check, which is why it is silent — the same way
# this guard is silent in a repository that declares no contract at all.
#
# ===========================================================================
# NO LIVE OVERRIDE
# ===========================================================================
# Deliberately, and for the publication pair's reason applied with more force:
# the judgment that failed four times in one day was "I will update the row
# after the deploy", made by the lander, in the moment, under exactly the
# pressure an escape token is reached for. The way through is to fix the row,
# or to delete the declaration in a committed, reviewable diff.
#
# PRECISION: fires only on a command that really runs `git commit` or
# `git merge`, parsed as a command line rather than matched as a substring.

set -eo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-row-currency-commits.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/guard-row-currency-commits.sh"
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
# byte-identical across every rooted hook, so anything added inside it would
# read as divergence.
#
# The seat resolved above answers "am I governed?". It does NOT answer "does
# the artifact I was just handed belong to the repository I govern?" — and
# until 2026-08-30 nothing asked. See scripts/lib/seat-jurisdiction.sh.
_SJ_LIB="$SCRIPT_DIR/../lib/seat-jurisdiction.sh"
if [ ! -f "$_SJ_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-row-currency-commits.sh"
        echo "  scripts/lib/seat-jurisdiction.sh is missing at: $_SJ_LIB"
        echo "  Without it this guard cannot tell whether the artifact it was"
        echo "  handed belongs to the repository it governs, and a guard that"
        echo "  cannot tell must not answer."
    } >&2
    exit 2
fi
# shellcheck source=../lib/seat-jurisdiction.sh
. "$_SJ_LIB"

# --- GIT JURISDICTION ------------------------------------------------------
# The question UNDERNEATH the one above: which repository is this git command
# talking to? It was answered in five hand-copied blocks and every one of them
# missed `cd <repo> && git commit`. REFUSING TO START is deliberate — a guard
# that resolved the repository by guessing would be the 2026-09-01 bypass with
# a nicer error message.
_GJ_LIB="$SCRIPT_DIR/../lib/git-jurisdiction.sh"
if [ ! -f "$_GJ_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-row-currency-commits.sh"
        echo "  scripts/lib/git-jurisdiction.sh is missing at: $_GJ_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY the command"
        echo "  it was handed will actually commit to, and the fallback it used"
        echo "  to carry is the exact bypass that library exists to close."
    } >&2
    exit 2
fi
# shellcheck source=../lib/git-jurisdiction.sh
. "$_GJ_LIB"

INPUT="$(cat)"

if resolve_entity_root "$INPUT"; then
    # CAPTURED, not discarded. This used to be `:` — the seat decided whether
    # this guard ran and then had no say in WHAT it judged, which is the
    # divergence in its purest form.
    SEAT_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # DELIBERATELY NOT AN EXIT. This guard reads its contract out of the TARGET
    # repository, not out of the seat, so an unadopted seat is not a reason to
    # stop — the artifact's own repository still gets to govern itself below
    # by its own declaration. Exiting here is what made richos-hq's committed
    # .row-currency and .ceo-todos readable by nothing at all.
    SEAT_ROOT=""
else
    root_failure_banner "scripts/hooks/guard-row-currency-commits.sh" >&2
    exit 2
fi

_RC_LIB="$SCRIPT_DIR/../lib/row-currency.sh"
if [ ! -f "$_RC_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-row-currency-commits.sh"
        echo "  scripts/lib/row-currency.sh is missing at: $_RC_LIB"
        echo "  This guard's entire predicate lives there. Without it it cannot"
        echo "  tell a current row from a stale one, and it will not guess."
    } >&2
    exit 2
fi
# shellcheck source=../lib/row-currency.sh
. "$_RC_LIB"

# --- What is this command, and where? --------------------------------------
# Parsed as a COMMAND LINE, not matched as a substring: `echo "git commit"` is
# not a commit, and a guard that thinks it is teaches people it cries wolf.
# Assigned via a quoted heredoc first for the bash 3.2 reason
# guard-worktree-removal.sh documents: a `)` inside a character class
# mis-scans as the close of a $( ) substitution on macOS's /bin/bash.
read -r -d '' _RC_CLASSIFIER <<'PYEOF' || true
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

if not re.search(r"\bgit\b", cmd):
    out("PASS")

# --- heredocs, kept aside so `-F -` can still be read ----------------------
heredocs = {}
lines = cmd.split("\n")
i = 0
while i < len(lines):
    m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", lines[i])
    if m:
        tag = m.group(2)
        body, j = [], i + 1
        while j < len(lines) and lines[j].strip() != tag:
            body.append(lines[j])
            j += 1
        heredocs.setdefault(tag, "\n".join(body))
        i = j
    i += 1

# --- segments -------------------------------------------------------------
segments = re.split(r"(?:\|\||&&|[;\n|])", cmd)

def parse(seg):
    try:
        argv = shlex.split(seg, comments=False)
    except ValueError:
        return None
    while argv and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[0]):
        argv.pop(0)
    if not argv:
        return None
    if os.path.basename(argv[0]) != "git":
        return None
    return argv

for seg in segments:
    argv = parse(seg)
    if not argv:
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
        if a.startswith("-c") and a != "-c":
            k += 1; continue
        if a == "-c" and k + 1 < len(argv):
            k += 2; continue
        if a.startswith("-"):
            k += 1; continue
        sub = a
        k += 1
        break
    if sub not in ("commit", "merge"):
        continue

    rest = argv[k:]
    message = None
    msource = "unavailable"
    stage_all = 0
    merge_ref = ""
    skip = False
    n = 0
    parts = []
    while n < len(rest):
        a = rest[n]
        if a in ("--dry-run", "--abort", "--continue", "--quit", "--no-commit"):
            skip = True
            break
        if a in ("-m", "--message") and n + 1 < len(rest):
            parts.append(rest[n + 1]); msource = sub + " -m"; n += 2; continue
        if a.startswith("--message="):
            parts.append(a.split("=", 1)[1]); msource = sub + " -m"; n += 1; continue
        if a.startswith("-m") and len(a) > 2:
            parts.append(a[2:]); msource = sub + " -m"; n += 1; continue
        if a in ("-F", "--file") and n + 1 < len(rest):
            src = rest[n + 1]
            if src == "-":
                if len(heredocs) == 1:
                    parts.append(list(heredocs.values())[0])
                    msource = sub + " -F - (heredoc)"
                else:
                    msource = sub + " -F - (stdin, not readable here)"
            else:
                p = src if os.path.isabs(src) else os.path.join(cwd or ".", src)
                try:
                    with open(p, encoding="utf-8") as fh:
                        parts.append(fh.read())
                    msource = sub + " -F"
                except Exception:
                    msource = sub + " -F (file unreadable)"
            n += 2
            continue
        if a in ("-a", "--all"):
            stage_all = 1; n += 1; continue
        if a.startswith("-") and not a.startswith("--") and len(a) > 1 and "a" in a[1:] and sub == "commit":
            stage_all = 1; n += 1; continue
        if a == "--amend":
            if msource == "unavailable":
                msource = "commit --amend (message from HEAD or an editor)"
            n += 1; continue
        if a.startswith("-"):
            # A flag that takes a value we do not care about.
            if a in ("-s", "--strategy", "-X", "--strategy-option", "--into-name",
                     "-C", "--reuse-message", "-c", "--reedit-message",
                     "--author", "--date", "--cleanup", "--gpg-sign", "-S"):
                n += 2
            else:
                n += 1
            continue
        if sub == "merge" and not merge_ref:
            merge_ref = a
        n += 1
    if skip:
        continue
    if parts:
        message = "\n\n".join(parts)
    # `repo` is deliberately NOT emitted. WHERE the command points is resolved
    # by scripts/lib/git-jurisdiction.sh, which understands the `cd <repo> &&
    # git commit` form this walk cannot see. Emitting a second answer here would
    # be the divergent copy that put the same hole in five files.
    out("ACT", sub, stage_all, merge_ref, msource,
        json.dumps(message) if message is not None else "")

out("PASS")
PYEOF

CLASS="$(GUARD_PAYLOAD="$INPUT" python3 -c "$_RC_CLASSIFIER" 2>/dev/null || printf 'PASS')"
KIND="$(printf '%s' "$CLASS" | cut -f1)"
[ "$KIND" = "ACT" ] || exit 0

ACTION="$(printf '%s' "$CLASS" | cut -f2)"
STAGE_ALL="$(printf '%s' "$CLASS" | cut -f3)"
MERGE_REF="$(printf '%s' "$CLASS" | cut -f4)"
MSRC="$(printf '%s' "$CLASS" | cut -f5)"
MSG_JSON="$(printf '%s' "$CLASS" | cut -f6-)"

# --- WHICH REPOSITORY IS THIS COMMAND TALKING TO? --------------------------
# ONE resolver, shared by every guard that asks (scripts/lib/git-jurisdiction.sh),
# never a local copy — a copy is how the same hole ended up in five files.
_RC_GJ="$(richos_git_anchor "$INPUT" "commit merge")"
ANCHOR="$(printf '%s' "$_RC_GJ" | cut -f2)"
[ -n "$ANCHOR" ] || ANCHOR="$PWD"

rc_require_ceo_todos_lib || { rc_broken_banner "guard-row-currency-commits.sh" "$RC_BROKEN_REASON" >&2; exit 2; }

REPO="$(ct_repo_root "$ANCHOR" 2>/dev/null || true)"
[ -n "$REPO" ] || exit 0

# --- GOVERNANCE: the artifact's OWN repository decides ---------------------
# "Am I governed?" and "what am I inspecting?" are the same question here, and
# they are now asked of the SAME repository: the declaration loaded immediately
# below is read out of $REPO — which is also the thing being judged. Two
# questions about one repository cannot disagree; that is the whole fix, and it
# needs no extra comparison to hold.
#
# The seat is deliberately given NO VETO. It used to have one: an unadopted seat
# exited before this point, which is exactly why richos-hq's committed
# .row-currency and .ceo-todos were read by nothing at all while the repository
# took 28 commits in a day. The seat is REPORTED when it differs from the
# artifact's repository, and never obeyed — a guard that switched itself off on
# a seat mismatch would have let through a merge that was correctly refused.
if [ -n "${SEAT_ROOT}" ]; then
    richos_assert_jurisdiction "scripts/hooks/guard-row-currency-commits.sh" "${SEAT_ROOT}" "$REPO" "commit in" || true
fi

DECL_RC=0
rc_load_declaration "$REPO" || DECL_RC=$?
case "$DECL_RC" in
  0) ;;
  1) exit 0 ;;   # this repository declares no row-currency contract
  *) rc_broken_banner "guard-row-currency-commits.sh" "$RC_BROKEN_REASON" >&2; exit 2 ;;
esac

# SCOPE, not a skipped check. See the header.
rc_is_landing "$REPO" || exit 0

RES_RC=0
rc_resolve_record "$REPO" || RES_RC=$?
case "$RES_RC" in
  0) ;;
  1)
    # LOUD, and never a block. A public repository whose private record nobody
    # cloned must not have every commit in it refused.
    {
        echo "=== ROW CURRENCY: STOOD DOWN — THE RECORD IS NOT ON THIS MACHINE ==="
        echo "  repository : $REPO"
        echo "  reason     : $RC_STANDDOWN_REASON"
        echo "  Nothing is being checked. This is announced rather than silent so"
        echo "  that 'the guard is on' never means 'the guard looked'."
    } >&2
    exit 0 ;;
  *) rc_broken_banner "guard-row-currency-commits.sh" "$RC_BROKEN_REASON" >&2; exit 2 ;;
esac

WORK="$(mktemp -d -t row-currency.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --- The tree this operation is about to create ----------------------------
MODE="index"
[ "$STAGE_ALL" = "1" ] && MODE="all"
[ "$ACTION" = "merge" ] && MODE="merge"
SELF_TREE="$(rc_pending_tree "$REPO" "$MODE" "$MERGE_REF" 2>/dev/null || true)"
[ -n "$SELF_TREE" ] || SELF_TREE="-"

# --- The record, as it will be after this operation -------------------------
# When the record lives in THIS repository the pending tree is the truth; when
# it lives in a sibling, the sibling's worktree is. Comparing a pending tree
# here against a committed record there would be two different moments in time
# called consistent — the mistake guard-ceo-todos-commits.sh documents in its
# own stage_view().
RECORD="$WORK/record.md"
if [ "$RC_MODE" = "record" ] && [ "$SELF_TREE" != "-" ]; then
    git -C "$REPO" show "$SELF_TREE:$RC_RECORD_REL" > "$RECORD" 2>/dev/null || rm -f "$RECORD"
fi
if [ ! -s "$RECORD" ] && [ -f "$RC_RECORD_REPO/$RC_RECORD_REL" ]; then
    cp "$RC_RECORD_REPO/$RC_RECORD_REL" "$RECORD" 2>/dev/null || true
fi
if [ ! -s "$RECORD" ]; then
    {
        echo "=== ROW CURRENCY: THE DECLARED RECORD IS NOT ON DISK — REFUSING ==="
        echo "  repository : $RC_RECORD_REPO"
        echo "  declared   : $RC_RECORD_REL  (in $CEO_TODOS_DECLARATION)"
        echo ""
        echo "  A guard whose subject has vanished protects nothing while looking"
        echo "  switched on. Restore the record, or delete $ROW_CURRENCY_DECLARATION"
        echo "  to stand this mechanism down deliberately and visibly."
        echo "(hook: scripts/hooks/guard-row-currency-commits.sh)"
    } >&2
    exit 2
fi

B1="$WORK/base1.md"; B2="$WORK/base2.md"
git -C "$RC_RECORD_REPO" show "HEAD:$RC_RECORD_REL" > "$B1" 2>/dev/null || rm -f "$B1"
# ONE COMMIT OF LOOKBACK, and no more. A landing is a small, serialized
# sequence, and the row edit is legitimately allowed to be the commit
# immediately before the one that lands the work — which is how a lander who
# does the record half FIRST would otherwise be refused for doing it right.
git -C "$RC_RECORD_REPO" show "HEAD~1:$RC_RECORD_REL" > "$B2" 2>/dev/null || rm -f "$B2"
[ -f "$B1" ] || B1="-"
[ -f "$B2" ] || B2="-"

MSGF="-"
if [ -n "$MSG_JSON" ]; then
    MSGF="$WORK/message.txt"
    RC_MSG_JSON="$MSG_JSON" python3 -c 'import json,os,sys
sys.stdout.write(json.loads(os.environ["RC_MSG_JSON"]))' > "$MSGF" 2>/dev/null || MSGF="-"
fi

JOB="$WORK/job.json"
rc_build_job "$JOB" "$RECORD" "$B1" "$B2" "$MSGF" "$MSRC" "$ACTION" "$SELF_TREE" || {
    echo "ERROR: guard-row-currency-commits.sh: could not assemble the check — refusing (fail-closed), because a checker that cannot run is not a current record." >&2
    exit 2
}

RESULT="$(rc_run "$JOB")" || {
    echo "ERROR: guard-row-currency-commits.sh: the row-currency predicate could not run — refusing (fail-closed)." >&2
    exit 2
}

VERDICT="$(printf '%s' "$RESULT" | head -1 | cut -f1)"
BODY="$(printf '%s\n' "$RESULT" | tail -n +2)"

case "$VERDICT" in
  CLEAN)
    # A clean pass still says what it did NOT check. The only way to silence
    # these lines is to fix what they name.
    printf '%s\n' "$BODY" | awk -F'\t' '$1=="NOTE" {printf "  ROW CURRENCY — NOTE: %s\n         %s\n", $2, $3}' >&2
    printf '%s\n' "$BODY" | awk -F'\t' '$1=="SKIP" {printf "  ROW CURRENCY — NOT CHECKED: item %s, %s\n         %s\n", $2, $3, $4}' >&2
    exit 0 ;;
  BROKEN)
    rc_broken_banner "guard-row-currency-commits.sh" "$(printf '%s' "$RESULT" | head -1 | cut -f2-)" >&2
    exit 2 ;;
  VIOLATIONS)
    N="$(printf '%s' "$RESULT" | head -1 | cut -f2)"
    rc_refusal "guard-row-currency-commits.sh" \
        "$N row(s) of this record no longer describe the work — REFUSING THIS $(printf '%s' "$ACTION" | tr '[:lower:]' '[:upper:]')" \
        "$BODY" "$RC_RECORD_REPO/$RC_RECORD_REL" >&2
    exit 2 ;;
  *)
    echo "ERROR: guard-row-currency-commits.sh: unexpected verdict from the predicate — refusing (fail-closed)" >&2
    exit 2 ;;
esac
