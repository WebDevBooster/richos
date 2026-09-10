#!/usr/bin/env bash
#
# create-teammate-worktree.sh — THE SANCTIONED WAY TO GIVE A TEAMMATE A
# WORKTREE IN ANOTHER REPOSITORY.
#
# ===========================================================================
# WHY THIS EXISTS
# ===========================================================================
# Native isolation roots at the SESSION repository. For another repository,
# this helper prepares and registers an external worktree. The Agent call must
# STILL set isolation:"worktree" and name the external path on a
# cross-repo-worktree: prompt line. The native worktree supplies the platform
# lifecycle witness; the registered external tree supplies the target checkout.
# A cwd-only spawn is refused because it has no native lifecycle witness.
#
# WHAT IT DOES, in order — and it stops at the first refusal:
#   1. Refuses a name that is not <role>-<model>-<identifier> (the spawn
#      contract), a path that already exists, or a branch that already exists.
#   2. `git worktree add <dir> -b <name> <base>` in the repository's MAIN
#      checkout (resolved through `git worktree list`, never guessed).
#   3. Seeds every gitignored file matching a `.worktreeinclude` pattern from
#      the main checkout into the new tree — the same contract native
#      isolation honors — and reports how many.
#   4. Verifies the path in the repository's own `git worktree list`, then
#      appends a durable (fsynced) PREPARED record to the ownership ledger
#      (scripts/lib/worktree-ledger.py): teammate, session id (from the
#      harness's own ~/.claude/sessions/<pid>.json registry, REQUIRED), session
#      pid + start time, repository, canonical worktree path, branch. This is
#      the authoritative creation-time membership: guard-worktree-isolation.sh
#      refuses a spawn into a path with no prepared record for this session
#      and teammate, and the seal binds exactly this record to the platform's
#      agent id (docs/plans/worktree-real-fix-2026-09-03.md, phase 1). If the
#      record cannot be written and read back, the worktree and branch are
#      ROLLED BACK — a tree without its record is worse than no tree.
#   5. Prints the path and the native+external spawn contract that carries it.
#
# USAGE
#   ~/.claude/richos-engine/scripts/create-teammate-worktree.sh <repo> <teammate-name> [--dir <path>]
#       [--base <ref>] [--session <id>] [--pid <n>]
#
#   <repo>            any path inside the target repository
#   <teammate-name>   the name the spawn will carry, e.g. echo-opus-bt2
#   --dir <path>      where to put it; default <main>-wt/<name> beside the
#                     main checkout (the convention this machine already uses)
#   --base <ref>      branch point; default the main checkout's HEAD
#   --session <id>    session id to record; default from the sessions registry
#   --pid <n>         session pid to record; default CLAUDE_PID, else the
#                     nearest ancestor `claude` process
#
# Environment (test affordances): RICHOS_WORKTREE_LEDGER, RICHOS_SESSIONS_DIR.
#
# Exit codes: 0 created + prepared; 2 usage; 3 refused (name / exists);
#             4 git failed; 5 created and then ROLLED BACK because the
#             prepared record could not be written (no session id, ledger
#             unwritable, or the record did not read back). Nothing is left
#             on disk in that case: an unrecorded cross-repository worktree
#             is exactly the object this helper exists to prevent — and 5 is
#             emitted only after the directory, the branch and the
#             registration have each been CHECKED to be gone.
#             6 created, rollback attempted, and something SURVIVED it. The
#             message names exactly what is still there. 5 and 6 are separate
#             codes because "cleaned up" and "tried to clean up" are separate
#             facts, and collapsing them is what let a false success be
#             reported for every failed creation between 6472bb60 and
#             2026-09-08. On the managed-workspace path the workspace is
#             deliberately RETAINED for retry and that is reported as 5, with
#             the retention stated in the message.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_PY="$SCRIPT_DIR/lib/worktree-ledger.py"
MANAGED_PY="$SCRIPT_DIR/lib/managed-workspace-integration.py"

usage() {
    sed -n '/^# USAGE/,/^# Environment/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

REPO_ARG=""; NAME=""; DIR=""; BASE=""; SESSION=""; PID_ARG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir)     DIR="${2:-}"; shift 2 ;;
        --base)    BASE="${2:-}"; shift 2 ;;
        --session) SESSION="${2:-}"; shift 2 ;;
        --pid)     PID_ARG="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 2 ;;
        -*)        echo "create-teammate-worktree.sh: unknown option '$1'" >&2; usage; exit 2 ;;
        *)
            if [ -z "$REPO_ARG" ]; then REPO_ARG="$1"
            elif [ -z "$NAME" ]; then NAME="$1"
            else echo "create-teammate-worktree.sh: unexpected argument '$1'" >&2; usage; exit 2; fi
            shift ;;
    esac
done
[ -n "$REPO_ARG" ] && [ -n "$NAME" ] || { usage; exit 2; }
command -v git >/dev/null 2>&1 || { echo "create-teammate-worktree.sh: git is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "create-teammate-worktree.sh: python3 is required" >&2; exit 2; }
[ -f "$LEDGER_PY" ] || { echo "create-teammate-worktree.sh: the ownership ledger library is missing at $LEDGER_PY — refusing to create a worktree that could not be registered" >&2; exit 2; }

refuse() { echo "create-teammate-worktree.sh: REFUSED — $*" >&2; exit 3; }

# --- 1. the name is the spawn contract's name --------------------------------
ALLOWED_MODELS="fable opus sonnet haiku"
if [ -f "$SCRIPT_DIR/../orchestration.config" ]; then
    _am="$(sed -n 's/^ALLOWED_MODELS="\(.*\)"$/\1/p' "$SCRIPT_DIR/../orchestration.config" | head -1)"
    [ -n "$_am" ] && ALLOWED_MODELS="$_am"
fi
NAME_RE="^[a-z][a-z0-9]{1,15}-($(printf '%s' "$ALLOWED_MODELS" | tr ' ' '|'))-[a-z0-9]{1,12}$"
printf '%s' "$NAME" | grep -qE "$NAME_RE" \
    || refuse "'$NAME' is not a teammate name of the form <role>-<model>-<identifier> (model one of: $ALLOWED_MODELS). The worktree is named for the teammate that owns it; that is how the reaper finds its owner."

# --- the repository's MAIN checkout, from git, never from the argument -------
[ -d "$REPO_ARG" ] || refuse "'$REPO_ARG' is not a directory"
MAIN="$(git -C "$REPO_ARG" worktree list --porcelain 2>/dev/null | sed -n '1s|^worktree ||p')"
[ -n "$MAIN" ] || refuse "'$REPO_ARG' is not inside a git repository"
MAIN="$(cd "$MAIN" && pwd -P)"

MANAGED=0
if [ -f "$MANAGED_PY" ]; then
    python3 "$MANAGED_PY" configured --repo "$MAIN" >/dev/null
    _managed_rc=$?
    case "$_managed_rc" in
        0) MANAGED=1 ;;
        3) : ;;
        *) refuse "managed workspace policy could not be read; creation was not attempted" ;;
    esac
elif [ -e '/Library/Application Support/RichOS/ManagedWorkspaces/client.json' ] || \
     [ -L '/Library/Application Support/RichOS/ManagedWorkspaces/client.json' ]; then
    refuse "managed workspace configuration exists but its integration module is missing"
fi
if [ "$MANAGED" -eq 0 ]; then
    [ -n "$DIR" ] || DIR="$(dirname "$MAIN")/$(basename "$MAIN")-wt/$NAME"
    [ ! -e "$DIR" ] || refuse "'$DIR' already exists"
else
    [ -z "$DIR" ] || refuse "managed workspaces use the manager's assigned path; omit --dir"
fi
# THE BRANCH CARRIES OUR OWN PREFIX (CEO, 2026-09-10: "if the cc/ prefix helps
# fix this shitshow once and for all, add it now and be done with it").
#
# The DIRECTORY keeps the bare teammate name and always will: eight places in
# scripts/lib/inflight.py name "worktree basename" as an identity source, and
# the `-wt/` location already marks these unambiguously. The BRANCH is what
# had no mark, and a branch is the durable half — it outlives the directory,
# it is what a merge sees, and it is what a sweep of a repository's refs has
# to decide about. `cc/` is this engine's own signature on a ref it created,
# which is a fact rather than a guess about a name.
#
# The namespace was verified empty across all five repositories before this
# landed. Note git cannot hold a bare `cc` ref beside `cc/<name>`, so nothing
# may ever create one.
BRANCH="$NAME"
[ "$MANAGED" -eq 0 ] && BRANCH="cc/$NAME"
if [ "$MANAGED" -eq 0 ] && git -C "$MAIN" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
    refuse "branch '$BRANCH' already exists in $MAIN — a teammate name is used once; pick a fresh identifier"
fi
[ -n "$BASE" ] || BASE="HEAD"
git -C "$MAIN" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
    || refuse "base ref '$BASE' does not resolve in $MAIN"

# --- 2. create -------------------------------------------------------------
MANAGED_ID=""
if [ "$MANAGED" -eq 1 ]; then
    SESSION_PID="$PID_ARG"
    [ -n "$SESSION_PID" ] || SESSION_PID="$(python3 "$LEDGER_PY" session-pid 2>/dev/null || true)"
    if [ -z "$SESSION" ] && [ -n "$SESSION_PID" ]; then
        _sdir="${RICHOS_SESSIONS_DIR:-$HOME/.claude/sessions}"
        if [ -f "$_sdir/$SESSION_PID.json" ]; then
            SESSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sessionId",""))' "$_sdir/$SESSION_PID.json" 2>/dev/null || true)"
        fi
    fi
    [ -n "$SESSION" ] || refuse "managed creation requires the owning session ID"
    _commit="$(git -C "$MAIN" rev-parse --verify "$BASE^{commit}")" || exit 4
    _managed_record="$(python3 "$MANAGED_PY" create --repo "$MAIN" --commit "$_commit" \
        --session-id "$SESSION" --agent-name "$NAME" --request-id "$SESSION:$NAME")" || exit 4
    DIR="$(printf '%s' "$_managed_record" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')" || exit 4
    MANAGED_ID="$(printf '%s' "$_managed_record" | python3 -c 'import json,sys; print(json.load(sys.stdin)["manager_id"])')" || exit 4
else
mkdir -p "$(dirname "$DIR")" || { echo "create-teammate-worktree.sh: cannot create $(dirname "$DIR")" >&2; exit 4; }
if ! git -C "$MAIN" worktree add -q "$DIR" -b "$BRANCH" "$BASE"; then
    echo "create-teammate-worktree.sh: git worktree add failed for $DIR" >&2
    exit 4
fi
fi
DIR="$(cd "$DIR" && pwd -P)"

# --- 3. seed .worktreeinclude ---------------------------------------------
# The same contract native isolation honors: gitignore-style patterns, matched
# against files that are IGNORED in the main checkout, copied with their
# relative paths. Done in python so `**/` means what .gitignore means by it.
SEEDED=0
if [ -f "$MAIN/.worktreeinclude" ]; then
    SEEDED="$(MAIN="$MAIN" DIR="$DIR" MANAGED="$MANAGED" python3 - <<'PY' 2>/dev/null || echo 0
import fnmatch, os, re, shutil, subprocess, sys
main = os.environ["MAIN"]; dest = os.environ["DIR"]
pats = []
with open(os.path.join(main, ".worktreeinclude"), encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("#"):
            pats.append(line)
if not pats:
    print(0); sys.exit(0)

def to_regex(pat):
    # .gitignore semantics, the subset that matters: a leading '**/' matches at
    # any depth (including none); a pattern with no '/' matches the basename at
    # any depth; otherwise it is anchored at the repository root.
    anchored = "/" in pat.strip("/") and not pat.startswith("**/")
    p = pat.lstrip("/")
    if p.startswith("**/"):
        p = p[3:]
        prefix = r"(?:.*/)?"
    elif not anchored:
        prefix = r"(?:.*/)?"
    else:
        prefix = ""
    body = re.escape(p).replace(r"\*\*/", r"(?:.*/)?").replace(r"\*", r"[^/]*").replace(r"\?", r"[^/]")
    return re.compile("^" + prefix + body + "$")

regs = [to_regex(p) for p in pats]
res = subprocess.run(["git", "-C", main, "ls-files", "--others", "--ignored", "--exclude-standard", "-z"],
                     capture_output=True, text=True)
n = 0
for rel in res.stdout.split("\0"):
    if not rel or not any(r.match(rel) for r in regs):
        continue
    src = os.path.join(main, rel)
    if not os.path.isfile(src):
        continue
    dst = os.path.join(dest, rel)
    if os.environ.get('MANAGED') == '1' and os.path.lexists(dst):
        continue  # Idempotent preparation must not overwrite existing bytes.
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    n += 1
print(n)
PY
)"
fi

# --- 4. the PREPARED record — authoritative creation-time membership --------
#
# This record is not bookkeeping. After creation there is no safe way to
# rediscover who owns this tree: names and branch shapes are reusable, and
# process absence says nothing. The spawn guard (guard-worktree-isolation.sh)
# refuses to spawn into a path with no `prepared` record for THIS session and
# THIS teammate, and the seal (worktree-transactions.py) binds exactly this
# record to the platform's agent id. So:
#   - the path must appear in git's own worktree list (verified, not assumed);
#   - the session id is REQUIRED — a prepared record with no session can never
#     match a spawn-intent, so the tree could never be bound, never sealed, and
#     never cleaned up; that is the object this helper exists to prevent;
#   - the append is durable (fsync) and, if it fails, the just-created
#     worktree and branch are ROLLED BACK. A tree that exists without its
#     record is worse than no tree.
rollback() { # <why>
    if [ "$MANAGED" -eq 1 ]; then
        echo "create-teammate-worktree.sh: preparation failed: $1. Managed workspace $MANAGED_ID is retained; retry this same session/name to resume preparation." >&2
        exit 5
    fi
    # Resolve THIS tree's admin registration BEFORE removing anything. The
    # worktree's own .git file is a one-line `gitdir: <main>/.git/worktrees/<id>`
    # pointer, and <id> is NOT always the basename — git disambiguates
    # collisions with a numeric suffix. Once the directory is gone there is
    # nothing left to read it from, so it is captured here or not at all.
    _admin=""
    if [ -f "$DIR/.git" ]; then
        _admin="$(sed -n 's/^gitdir: *//p' "$DIR/.git" 2>/dev/null | head -1)"
    fi
    git -C "$MAIN" worktree remove --force "$DIR" >/dev/null 2>&1 || rm -rf "$DIR"
    # NEVER bulk-prune (`git worktree prune`) here: it also drops registrations
    # for UNRELATED native/legacy trees whose directory is merely absent, which
    # is a live and separate harm. But the registration for THIS tree still has
    # to go, and dropping the bulk prune without replacing it is what broke this
    # function. When the removal above fails and the `rm -rf` fallback runs, the
    # admin directory survives, and git then REFUSES the branch delete below
    # with "cannot delete branch 'NAME' used by worktree at ..." — silently,
    # because that line swallows its own status. Deleting only this tree's own
    # admin directory frees the branch and touches no other registration.
    # The path came out of a file, so it is checked before anything is deleted:
    # it must live under THIS repository's own .git/worktrees/ (asked of git,
    # never assembled from string arithmetic), and the directory it registers
    # must already be gone.
    _common="$(git -C "$MAIN" rev-parse --git-common-dir 2>/dev/null || true)"
    case "$_common" in ""|/*) : ;; *) _common="$MAIN/$_common" ;; esac
    if [ -n "$_admin" ] && [ -n "$_common" ] && [ ! -e "$DIR" ] && [ -d "$_admin" ] \
       && [ "$_admin" != "${_admin#"$_common"/worktrees/}" ]; then
        rm -rf "$_admin"
    fi
    git -C "$MAIN" branch -D "$BRANCH" >/dev/null 2>&1 || true

    # REPORT THE ARTIFACT, NEVER THE COMMAND. Every removal above is
    # best-effort and each one swallows its own exit status, so "rolled back"
    # is a claim that has to be CHECKED before it is printed. It was printed
    # unconditionally until 2026-09-08, which meant a failed creation told the
    # orchestrator it had cleaned up while the branch and the registration
    # both survived — the one thing worse than not cleaning up is reporting
    # that you did.
    _left=""
    [ -e "$DIR" ] && _left="$_left
    directory:    $DIR"
    if git -C "$MAIN" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null 2>&1; then
        _left="$_left
    branch:       $BRANCH"
    fi
    if git -C "$MAIN" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $DIR"; then
        _left="$_left
    registration: $DIR"
    fi
    if [ -n "$_left" ]; then
        {
            echo "create-teammate-worktree.sh: created $DIR on branch $BRANCH but $1"
            echo "  ROLLBACK INCOMPLETE — the cleanup was attempted and these SURVIVE:$_left"
            echo "  They must be removed by hand before this name or path is reused. This is"
            echo "  reported rather than swallowed: a rollback that claims a success it did not"
            echo "  achieve leaves an unbindable tree behind AND hides it."
        } >&2
        exit 6
    fi
    {
        echo "create-teammate-worktree.sh: created $DIR on branch $BRANCH but $1"
        echo "  ROLLED BACK: the worktree and the branch were removed again. A cross-repository"
        echo "  worktree without its prepared record can never be bound to the teammate that"
        echo "  works in it, never sealed, and never cleaned up — so it is not left behind."
        echo "  (Verified on disk after the fact: directory, branch and registration are gone.)"
    } >&2
    exit 5
}

if [ "$MANAGED" -eq 1 ]; then
    python3 "$MANAGED_PY" inspect --path "$DIR" >/dev/null || rollback "manager membership could not be verified"
elif ! git -C "$MAIN" worktree list --porcelain 2>/dev/null | sed -n 's|^worktree ||p' \
     | while IFS= read -r _p; do [ "$(cd "$_p" 2>/dev/null && pwd -P)" = "$DIR" ] && exit 0; done; then
    rollback "git does not list it as a worktree of $MAIN"
fi

SESSION_PID="$PID_ARG"
[ -n "$SESSION_PID" ] || SESSION_PID="$(python3 "$LEDGER_PY" session-pid 2>/dev/null || true)"
if [ -z "$SESSION" ] && [ -n "$SESSION_PID" ]; then
    _sdir="${RICHOS_SESSIONS_DIR:-$HOME/.claude/sessions}"
    if [ -f "$_sdir/$SESSION_PID.json" ]; then
        SESSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sessionId",""))' "$_sdir/$SESSION_PID.json" 2>/dev/null || true)"
    fi
fi
[ -n "$SESSION" ] || rollback "no session id could be resolved (pass --session <id>, or run this from inside the session whose ~/.claude/sessions/<pid>.json names it)"

REG_ARGS=(record prepared --teammate "$NAME" --session-id "$SESSION" --repo "$MAIN" --worktree "$DIR" \
          --branch "$BRANCH" --source create-teammate-worktree.sh)
if [ "$MANAGED" -eq 1 ]; then
    REG_ARGS+=(--class managed-image --extra "manager_id=$MANAGED_ID")
else
    REG_ARGS+=(--class hand-rolled)
fi
[ -n "$SESSION_PID" ] && REG_ARGS+=(--session-pid "$SESSION_PID" --pid-start-of-session)
if ! python3 "$LEDGER_PY" "${REG_ARGS[@]}" >/dev/null 2>&1; then
    rollback "could NOT write its prepared record to the ownership ledger ($(python3 "$LEDGER_PY" path 2>/dev/null || echo '<ledger path unknown>'))"
fi
# Read it back through a fresh process: the record is authoritative only if it
# is on disk, not if a write call returned.
if ! python3 "$LEDGER_PY" prepared --session-id "$SESSION" --teammate "$NAME" --worktree "$DIR" >/dev/null 2>&1; then
    rollback "its prepared record could not be read back from the ownership ledger"
fi

# --- 5. report --------------------------------------------------------------
echo "created:    $DIR"
echo "branch:     $BRANCH  (from $BASE in $MAIN)"
if [ "$MANAGED" -eq 1 ]; then
    echo "delivery:   worker branch is image-local; after terminal capture query:"
    printf '  python3 %q delivery --id %q --repo %q\n' "$MANAGED_PY" "$MANAGED_ID" "$MAIN"
    echo "Merge the returned exact tip in source_repo; the returned ref preserves it. Do not look for a canonical teammate branch."
fi
echo "seeded:     $SEEDED file(s) from .worktreeinclude"
echo "prepared:   teammate=$NAME session=$SESSION pid=${SESSION_PID:-<unknown>} ($(python3 "$LEDGER_PY" path 2>/dev/null))"
echo ""
echo "Spawn with isolation: \"worktree\" in the session repo; add this prompt line:"
echo "  cross-repo-worktree: $DIR"
echo "A cwd-only spawn is refused: it has no platform-owned lifecycle witness."
echo "Prepare the full Agent JSON, including its mandatory acknowledgement contract:"
echo "  python3 \"$SCRIPT_DIR/prepare-agent-spawn.py\" --file <task-input.json>"
exit 0
