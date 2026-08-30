#!/usr/bin/env bash
#
# guard-ceo-todos-commits.sh — BLOCKING PreToolUse guard on the Bash tool.
#
# Refuses a commit into a repository whose CEO TODOs is making a claim it
# cannot back: an item sitting in a "waiting on the CEO" section without the
# four fields, or naming an artifact that does not exist on disk.
#
# The predicate, the two states, the declaration format and the honest list of
# what none of this can catch all live in scripts/lib/ceo-todos.sh — one place,
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
# declares its own scope in a committed `.ceo-todos`. A governed session
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

command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-ceo-todos-commits.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

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
        echo "  hook: scripts/hooks/guard-ceo-todos-commits.sh"
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
        echo "  hook: scripts/hooks/guard-ceo-todos-commits.sh"
        echo "  scripts/lib/seat-jurisdiction.sh is missing at: $_SJ_LIB"
        echo "  Without it this guard cannot tell whether the artifact it was"
        echo "  handed belongs to the repository it governs, and a guard that"
        echo "  cannot tell must not answer."
    } >&2
    exit 2
fi
# shellcheck source=../lib/seat-jurisdiction.sh
. "$_SJ_LIB"

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
    root_failure_banner "scripts/hooks/guard-ceo-todos-commits.sh" >&2
    exit 2
fi

_CT_LIB="$SCRIPT_DIR/../lib/ceo-todos.sh"
if [ ! -f "$_CT_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-ceo-todos-commits.sh"
        echo "  scripts/lib/ceo-todos.sh is missing at: $_CT_LIB"
        echo "  This guard's entire predicate lives there. Without it it cannot"
        echo "  tell a prepared item from an unprepared one, and it will not guess."
    } >&2
    exit 2
fi
# shellcheck source=../lib/ceo-todos.sh
. "$_CT_LIB"

# --- Is this a commit at all, and where? -----------------------------------
# Classified in python, assigned via a quoted heredoc first for the same bash
# 3.2 reason guard-worktree-removal.sh documents: a `)` inside a character
# class mis-scans as the close of a $( ) substitution on macOS's /bin/bash.
read -r -d '' _CT_CLASSIFIER <<'PYEOF' || true
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

CLASS="$(GUARD_PAYLOAD="$INPUT" python3 -c "$_CT_CLASSIFIER" 2>/dev/null || printf 'PASS')"
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

CT_ANCHOR="${REPO_HINT:-${PAYLOAD_CWD:-$PWD}}"
case "$CT_ANCHOR" in
  /*) ;;
  *) CT_ANCHOR="${PAYLOAD_CWD:-$PWD}/$CT_ANCHOR" ;;
esac

CT_REPO="$(ct_repo_root "$CT_ANCHOR" 2>/dev/null || true)"
[ -n "$CT_REPO" ] || exit 0

# --- GOVERNANCE: the artifact's OWN repository decides ---------------------
# "Am I governed?" and "what am I inspecting?" are the same question here, and
# they are now asked of the SAME repository: the declaration loaded immediately
# below is read out of $CT_REPO — which is also the thing being judged. Two
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
    richos_assert_jurisdiction "scripts/hooks/guard-ceo-todos-commits.sh" "${SEAT_ROOT}" "$CT_REPO" "commit in" || true
fi

CT_DECL_RC=0
ct_load_declaration "$CT_REPO" || CT_DECL_RC=$?
case "$CT_DECL_RC" in
  0) ;;
  1) exit 0 ;;   # this repository declares no CEO TODOs — nothing to enforce
  *) ct_broken_banner "guard-ceo-todos-commits.sh" "$CT_BROKEN_REASON" >&2; exit 2 ;;
esac

# --- Which bytes are the record about to be? -------------------------------
# Staged blob when the record is staged (those are the bytes that land); the
# worktree copy otherwise, including under `-a`, where an unstaged modification
# is what gets committed.
WORK="$(mktemp -d -t ceo-todos-commit.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
SUBJECT="$WORK/record.md"
TOUCHED=0

STAGED_LIST="$(git -C "$CT_REPO" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
case "
$STAGED_LIST
" in
  *"
$CT_TODO_RECORD
"*) TOUCHED=1 ;;
esac

if [ "$TOUCHED" -eq 1 ] && [ "$STAGE_ALL" -eq 0 ]; then
    if ! git -C "$CT_REPO" show ":$CT_TODO_RECORD" > "$SUBJECT" 2>/dev/null; then
        rm -f "$SUBJECT"
    fi
fi
if [ ! -s "$SUBJECT" ]; then
    if [ -f "$CT_REPO/$CT_TODO_RECORD" ]; then
        cp "$CT_REPO/$CT_TODO_RECORD" "$SUBJECT" 2>/dev/null || true
    fi
fi

# --- The SURFACE around the record, resolved the same way ------------------
# THE ENTRY POINT IS CHECKED FROM THE SAME BYTES AS THE RECORD, and it has to
# be: the failure being gated is a view that no longer matches the record, and
# the commonest way to produce one is to stage a record change and leave the
# generated page behind. Comparing a staged record against a WORKTREE view
# would pass exactly that commit — the gate would be looking at two different
# moments in time and calling them consistent.
#
# "-" means: this file will not be there after the commit. Distinct from unset
# (read the worktree), because a DELETED entry point must read as absent, not
# as whatever is still lying on disk.
stage_view() {
    # stage_view <repo-relative path> <scratch name> -> prints the override token
    local rel="$1" tmp="$WORK/$2" staged=0 deleted=0
    [ -n "$rel" ] || { printf ''; return; }
    case "
$STAGED_LIST
" in
        *"
$rel
"*) staged=1 ;;
    esac
    case "
$DELETED_LIST
" in
        *"
$rel
"*) deleted=1 ;;
    esac
    if [ "$staged" -eq 1 ] && [ "$STAGE_ALL" -eq 0 ]; then
        if git -C "$CT_REPO" show ":$rel" > "$tmp" 2>/dev/null; then
            printf '%s' "$tmp"
            return
        fi
    fi
    if [ "$deleted" -eq 1 ] && [ "$STAGE_ALL" -eq 0 ]; then
        printf '%s' '-'
        return
    fi
    if [ -f "$CT_REPO/$rel" ]; then
        printf ''      # unset: the library reads the worktree copy
        return
    fi
    printf '%s' '-'
}

DELETED_LIST="$(git -C "$CT_REPO" diff --cached --name-only --diff-filter=D 2>/dev/null || true)"
CT_OVERRIDE_VIEW="$(stage_view "$CT_TODO_VIEW" view.md)"
CT_OVERRIDE_README="$(stage_view "$CT_ROOT_README" readme.md)"
export CT_OVERRIDE_VIEW CT_OVERRIDE_README

if [ ! -f "$SUBJECT" ] || [ ! -s "$SUBJECT" ]; then
    # The declaration names a record that is not there. That is BROKEN — never
    # a quiet pass. A guard whose subject has vanished protects nothing while
    # looking switched on, which is the failure mode this engine keeps finding.
    {
        echo "=== CEO TODOs: THE DECLARED RECORD IS NOT ON DISK — REFUSING THIS COMMIT ==="
        echo "  repository : $CT_REPO"
        echo "  declared   : $CT_TODO_RECORD  (in $CEO_TODOS_DECLARATION)"
        echo ""
        echo "  Either restore the record, or delete $CEO_TODOS_DECLARATION to stand"
        echo "  this mechanism down deliberately and visibly."
        echo "(hook: scripts/hooks/guard-ceo-todos-commits.sh)"
    } >&2
    exit 2
fi

ct_resolve_roots "$CT_REPO"

RESULT="$(ct_lint_file "$CT_TODO_RECORD" "$SUBJECT" "$CT_REPO")" || {
    echo "ERROR: guard-ceo-todos-commits.sh: the CEO-TODOs predicate could not run — refusing (fail-closed), because a checker that cannot run is not a clean record." >&2
    exit 2
}

VERDICT="$(printf '%s' "$RESULT" | head -1 | cut -f1)"
BODY="$(printf '%s\n' "$RESULT" | tail -n +2)"

case "$VERDICT" in
  CLEAN)
    # A clean pass still says what it did NOT check. The only way to silence
    # these lines is to declare the thing they name, which is the point: an
    # undeclared check must cost something visible every time, or "clean"
    # quietly grows to mean "checked" and we are back where this started.
    printf '%s\n' "$BODY" | awk -F'\t' '$1=="NOTE" {printf "  CEO TODOs — NOT CHECKED: %s\n         %s\n", $2, $3}' >&2
    exit 0 ;;
  BROKEN)
    ct_broken_banner "guard-ceo-todos-commits.sh" "$(printf '%s' "$RESULT" | head -1 | cut -f2-)" >&2
    exit 2 ;;
  VIOLATIONS)
    if [ "$TOUCHED" -eq 1 ]; then
        HEADLINE="this commit changes the record, and $(printf '%s' "$RESULT" | head -1 | cut -f2) thing(s) about these TODOs are not ready"
    else
        HEADLINE="PRE-EXISTING: $(printf '%s' "$RESULT" | head -1 | cut -f2) thing(s) about this repository's CEO TODOs are not ready (this commit did not touch the record)"
    fi
    ct_refusal "guard-ceo-todos-commits.sh" "$HEADLINE" "$BODY" "$CT_REPO/$CT_TODO_RECORD" >&2
    exit 2 ;;
  *)
    echo "ERROR: guard-ceo-todos-commits.sh: unexpected verdict from the predicate — refusing (fail-closed)" >&2
    exit 2 ;;
esac
