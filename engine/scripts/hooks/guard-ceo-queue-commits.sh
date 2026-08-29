#!/usr/bin/env bash
#
# guard-ceo-queue-commits.sh — BLOCKING PreToolUse guard on the Bash tool.
#
# Refuses a commit into a repository whose CEO queue is making a claim it
# cannot back: an item sitting in a "waiting on the CEO" section without the
# four fields, or naming an artifact that does not exist on disk.
#
# The predicate, the two states, the declaration format and the honest list of
# what none of this can catch all live in scripts/lib/ceo-queue.sh — one place,
# because a predicate in two copies is the defect class this engine keeps
# finding in itself.
#
# ===========================================================================
# WHY THE COMMIT, AND WHY *ONLY* THE COMMIT
# ===========================================================================
# A PreToolUse[Write|Edit] guard was the obvious first choice and it was
# rejected on evidence, not taste. In this environment the dominant way a
# markdown record actually changes is the Bash tool — `sed -i`, a heredoc, a
# small script — and agents are explicitly steered that way. A Write-matcher
# guard would therefore miss most real edits while reporting a clean session,
# which is the same shape as the "18/18 suites" defect it is meant to prevent:
# a check whose scope quietly excludes the thing that is actually broken. Its
# sibling guard-publication-writes.sh documents the identical discovery from
# the other direction — 137 of 140 leaked files never touched a Write tool.
#
# At `git commit` provenance stops mattering. sed, heredoc, editor, generator,
# `git mv`, another agent's leftovers: the index sees all of them identically.
#
# ===========================================================================
# EVERY COMMIT, NOT ONLY THE ONES THAT TOUCH THE RECORD
# ===========================================================================
# The original failure was not a bad row being written. It was a bad row
# SITTING there for weeks while everyone read past it. A guard that only fires
# when the record changes cannot see that, and an artifact can be deleted long
# after the row that promises it was committed.
#
# So the record is re-checked at every commit in a declaring repository, and
# the refusal says plainly whether this commit introduced the problem or merely
# ran into one that was already there. The cost is that an unrelated commit can
# be blocked by somebody else's stale row; that is the intended trade. A record
# that lies about the most expensive person in the company is a defect of the
# same severity as the one guard-publication-commits.sh refuses.
#
# ===========================================================================
# SCOPE — DECLARED BY THE DESTINATION, NOT BY THE SESSION
# ===========================================================================
# The repository that owns the record may not have adopted this engine, and in
# the case this guard was built for it has not. So, exactly as the publication
# pair does: the SESSION must be governed, and the DESTINATION repository
# declares its own scope in a committed `.ceo-queue`. A governed session
# committing into an unadopted repository is fully covered.
#
# WHAT THAT CANNOT CATCH, said here rather than discovered later:
#   * A commit made from a session seated IN the unadopted repository. The
#     engine stands down for those sessions and this hook never loads. The one
#     change that would close it is an `orchestration.config` in that
#     repository — a deliberate adoption decision, not something a guard should
#     help itself to.
#   * A repo-local git hook would not close it either, and that was checked
#     rather than assumed: this machine sets core.hooksPath globally to a
#     directory owned by an unrelated identity guard, so `.git/hooks/pre-commit`
#     in the target repository never executes at all.
#   * `git merge`, `git cherry-pick`, `git am`, `git rebase` — they create
#     commits without running `git commit`. Merge is the acceptable gap; the
#     content was gated when it was committed on the source branch.
#   * `--no-verify` does not apply here (this is not a git hook), but a commit
#     made outside any governed session is the same hole by another road.
#
# NO LIVE OVERRIDE — deliberately, and for the publication pair's reason: the
# thing that failed was in-the-moment judgment about whether an item was really
# ready. An in-prompt escape token would rebuild exactly that. The way through
# is to fix the item, or to mark it BLOCKED-ON-RICH and move it to the
# preparer's section — which is the system working.
#
# PRECISION: fires only on a command that actually contains `git commit`.

set -eo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-ceo-queue-commits.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/guard-ceo-queue-commits.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defence"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

INPUT="$(cat)"

if resolve_entity_root "$INPUT"; then
    :
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    exit 0
else
    root_failure_banner "scripts/hooks/guard-ceo-queue-commits.sh" >&2
    exit 2
fi

_CQ_LIB="$SCRIPT_DIR/../lib/ceo-queue.sh"
if [ ! -f "$_CQ_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-ceo-queue-commits.sh"
        echo "  scripts/lib/ceo-queue.sh is missing at: $_CQ_LIB"
        echo "  This guard's entire predicate lives there. Without it it cannot"
        echo "  tell a prepared item from an unprepared one, and it will not guess."
    } >&2
    exit 2
fi
# shellcheck source=../lib/ceo-queue.sh
. "$_CQ_LIB"

# --- Is this a commit at all, and where? -----------------------------------
# Classified in python, assigned via a quoted heredoc first for the same bash
# 3.2 reason guard-worktree-removal.sh documents: a `)` inside a character
# class mis-scans as the close of a $( ) substitution on macOS's /bin/bash.
read -r -d '' _CQ_CLASSIFIER <<'PYEOF' || true
import json, os, re

try:
    d = json.loads(os.environ.get("GUARD_PAYLOAD") or "{}")
except Exception:
    print("PASS"); raise SystemExit
if not isinstance(d, dict) or d.get("tool_name") != "Bash":
    print("PASS"); raise SystemExit
ti = d.get("tool_input") or {}
cmd = (ti.get("command", "") if isinstance(ti, dict) else "") or ""

if not re.search(r"\bgit\b[^\n;|&]*\bcommit\b", cmd):
    print("PASS"); raise SystemExit

m = re.search(r"\bgit\b\s+(?:[^\n;|&]*?\s)?-C\s+(\"[^\"]+\"|'[^']+'|\S+)", cmd)
repo_hint = ""
if m:
    repo_hint = m.group(1).strip("\"'")

# `-a`/`--all` commits tracked modifications that are not in the index, so the
# staged blob would not be the bytes that land. Quoted spans are stripped first:
# `git commit -m "handle -a properly"` is not a `-a` commit.
unquoted = re.sub(r'"[^"]*"', " ", cmd)
unquoted = re.sub(r"'[^']*'", " ", unquoted)
stage_all = bool(re.search(r"(?:^|\s)-[a-zA-Z]*a[a-zA-Z]*\b", unquoted)
                 or re.search(r"(?:^|\s)--all\b", unquoted))

print("COMMIT\t%s\t%s" % (repo_hint, "1" if stage_all else "0"))
PYEOF

CLASS="$(GUARD_PAYLOAD="$INPUT" python3 -c "$_CQ_CLASSIFIER" 2>/dev/null || printf 'PASS')"
case "$(printf '%s' "$CLASS" | cut -f1)" in
  COMMIT) ;;
  *) exit 0 ;;
esac

REPO_HINT="$(printf '%s' "$CLASS" | cut -f2)"
STAGE_ALL="$(printf '%s' "$CLASS" | cut -f3)"

PAYLOAD_CWD="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(str(d.get("cwd", "") or "") if isinstance(d, dict) else "")
except Exception:
    print("")' 2>/dev/null || true)"

CQ_ANCHOR="${REPO_HINT:-${PAYLOAD_CWD:-$PWD}}"
case "$CQ_ANCHOR" in
  /*) ;;
  *) CQ_ANCHOR="${PAYLOAD_CWD:-$PWD}/$CQ_ANCHOR" ;;
esac

CQ_REPO="$(cq_repo_root "$CQ_ANCHOR" 2>/dev/null || true)"
[ -n "$CQ_REPO" ] || exit 0

CQ_DECL_RC=0
cq_load_declaration "$CQ_REPO" || CQ_DECL_RC=$?
case "$CQ_DECL_RC" in
  0) ;;
  1) exit 0 ;;   # this repository declares no CEO queue — nothing to enforce
  *) cq_broken_banner "guard-ceo-queue-commits.sh" "$CQ_BROKEN_REASON" >&2; exit 2 ;;
esac

# --- Which bytes are the record about to be? -------------------------------
# Staged blob when the record is staged (those are the bytes that land); the
# worktree copy otherwise, including under `-a`, where an unstaged modification
# is what gets committed.
WORK="$(mktemp -d -t ceo-queue-commit.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
SUBJECT="$WORK/record.md"
TOUCHED=0

STAGED_LIST="$(git -C "$CQ_REPO" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
case "
$STAGED_LIST
" in
  *"
$CQ_QUEUE_RECORD
"*) TOUCHED=1 ;;
esac

if [ "$TOUCHED" -eq 1 ] && [ "$STAGE_ALL" -eq 0 ]; then
    if ! git -C "$CQ_REPO" show ":$CQ_QUEUE_RECORD" > "$SUBJECT" 2>/dev/null; then
        rm -f "$SUBJECT"
    fi
fi
if [ ! -s "$SUBJECT" ]; then
    if [ -f "$CQ_REPO/$CQ_QUEUE_RECORD" ]; then
        cp "$CQ_REPO/$CQ_QUEUE_RECORD" "$SUBJECT" 2>/dev/null || true
    fi
fi

if [ ! -f "$SUBJECT" ] || [ ! -s "$SUBJECT" ]; then
    # The declaration names a record that is not there. That is BROKEN — never
    # a quiet pass. A guard whose subject has vanished protects nothing while
    # looking switched on, which is the failure mode this engine keeps finding.
    {
        echo "=== CEO QUEUE: THE DECLARED RECORD IS NOT ON DISK — REFUSING THIS COMMIT ==="
        echo "  repository : $CQ_REPO"
        echo "  declared   : $CQ_QUEUE_RECORD  (in $CEO_QUEUE_DECLARATION)"
        echo ""
        echo "  Either restore the record, or delete $CEO_QUEUE_DECLARATION to stand"
        echo "  this mechanism down deliberately and visibly."
        echo "(hook: scripts/hooks/guard-ceo-queue-commits.sh)"
    } >&2
    exit 2
fi

cq_resolve_roots "$CQ_REPO"

RESULT="$(cq_lint_file "$CQ_QUEUE_RECORD" "$SUBJECT")" || {
    echo "ERROR: guard-ceo-queue-commits.sh: the CEO-queue predicate could not run — refusing (fail-closed), because a checker that cannot run is not a clean record." >&2
    exit 2
}

VERDICT="$(printf '%s' "$RESULT" | head -1 | cut -f1)"
BODY="$(printf '%s\n' "$RESULT" | tail -n +2)"

case "$VERDICT" in
  CLEAN)
    exit 0 ;;
  BROKEN)
    cq_broken_banner "guard-ceo-queue-commits.sh" "$(printf '%s' "$RESULT" | head -1 | cut -f2-)" >&2
    exit 2 ;;
  VIOLATIONS)
    if [ "$TOUCHED" -eq 1 ]; then
        HEADLINE="this commit changes the record, and $(printf '%s' "$RESULT" | head -1 | cut -f2) item(s) in it are not ready"
    else
        HEADLINE="PRE-EXISTING: $(printf '%s' "$RESULT" | head -1 | cut -f2) item(s) in this repository's CEO queue are not ready (this commit did not touch the record)"
    fi
    cq_refusal "guard-ceo-queue-commits.sh" "$HEADLINE" "$BODY" "$CQ_REPO/$CQ_QUEUE_RECORD" >&2
    exit 2 ;;
  *)
    echo "ERROR: guard-ceo-queue-commits.sh: unexpected verdict from the predicate — refusing (fail-closed)" >&2
    exit 2 ;;
esac
