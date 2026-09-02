#!/usr/bin/env bash
#
# create-teammate-worktree.sh — THE SANCTIONED WAY TO GIVE A TEAMMATE A
# WORKTREE IN ANOTHER REPOSITORY.
#
# ===========================================================================
# WHY THIS EXISTS
# ===========================================================================
# Native `isolation: "worktree"` roots at the SESSION's repository, so a
# femcboost session cannot give a teammate a native worktree in `richos`. The
# Agent tool's own escape hatch is `cwd` — "mutually exclusive with
# isolation: worktree" — which means cross-repository work runs in a
# HAND-ROLLED worktree, and until 2026-09-02 that worktree was improvised by
# the teammate itself from a sentence in its prompt ("git -C <repo> worktree
# add ..."). Native isolation gives six things for free that the improvised
# tree got none of: creation, `.worktreeinclude` seeding (.envrc, **/.env.local
# — nobody seeded these into a richos worktree), base-ref from HEAD, the
# agent's cwd, spawn-time enforcement, and — the one that matters most — a
# RECORD of who owns it. This helper does the first four and the last one in
# a single call; guard-worktree-isolation.sh supplies the enforcement by
# refusing a `cwd` spawn into a worktree this helper did not register.
#
# WHAT IT DOES, in order — and it stops at the first refusal:
#   1. Refuses a name that is not <role>-<model>-<identifier> (the spawn
#      contract), a path that already exists, or a branch that already exists.
#   2. `git worktree add <dir> -b <name> <base>` in the repository's MAIN
#      checkout (resolved through `git worktree list`, never guessed).
#   3. Seeds every gitignored file matching a `.worktreeinclude` pattern from
#      the main checkout into the new tree — the same contract native
#      isolation honors — and reports how many.
#   4. Registers the tree in the ownership ledger (scripts/lib/
#      worktree-ledger.py): teammate, session id (from the harness's own
#      ~/.claude/sessions/<pid>.json registry), session pid + start time,
#      repository, worktree path, branch, class hand-rolled. This is the
#      record the reaper judges the tree by after the session is gone.
#   5. Prints the path and the two spawn shapes that carry it.
#
# USAGE
#   scripts/create-teammate-worktree.sh <repo> <teammate-name> [--dir <path>]
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
# Exit codes: 0 created + registered; 2 usage; 3 refused (name / exists);
#             4 git failed; 5 created but NOT registered (the ledger write
#             failed — the tree is reported so it can be registered by hand,
#             and the exit is non-zero because an unregistered cross-repo
#             worktree is exactly the object this helper exists to prevent).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_PY="$SCRIPT_DIR/lib/worktree-ledger.py"

usage() {
    sed -n '38,52p' "$0" | sed 's/^# \{0,1\}//' >&2
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

[ -n "$DIR" ] || DIR="$(dirname "$MAIN")/$(basename "$MAIN")-wt/$NAME"
[ ! -e "$DIR" ] || refuse "'$DIR' already exists"
if git -C "$MAIN" rev-parse --verify --quiet "refs/heads/$NAME" >/dev/null; then
    refuse "branch '$NAME' already exists in $MAIN — a teammate name is used once; pick a fresh identifier"
fi
[ -n "$BASE" ] || BASE="HEAD"
git -C "$MAIN" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
    || refuse "base ref '$BASE' does not resolve in $MAIN"

# --- 2. create -------------------------------------------------------------
mkdir -p "$(dirname "$DIR")" || { echo "create-teammate-worktree.sh: cannot create $(dirname "$DIR")" >&2; exit 4; }
if ! git -C "$MAIN" worktree add -q "$DIR" -b "$NAME" "$BASE"; then
    echo "create-teammate-worktree.sh: git worktree add failed for $DIR" >&2
    exit 4
fi
DIR="$(cd "$DIR" && pwd -P)"

# --- 3. seed .worktreeinclude ---------------------------------------------
# The same contract native isolation honors: gitignore-style patterns, matched
# against files that are IGNORED in the main checkout, copied with their
# relative paths. Done in python so `**/` means what .gitignore means by it.
SEEDED=0
if [ -f "$MAIN/.worktreeinclude" ]; then
    SEEDED="$(MAIN="$MAIN" DIR="$DIR" python3 - <<'PY' 2>/dev/null || echo 0
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
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    n += 1
print(n)
PY
)"
fi

# --- 4. register ------------------------------------------------------------
SESSION_PID="$PID_ARG"
[ -n "$SESSION_PID" ] || SESSION_PID="$(python3 "$LEDGER_PY" session-pid 2>/dev/null || true)"
if [ -z "$SESSION" ] && [ -n "$SESSION_PID" ]; then
    _sdir="${RICHOS_SESSIONS_DIR:-$HOME/.claude/sessions}"
    if [ -f "$_sdir/$SESSION_PID.json" ]; then
        SESSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sessionId",""))' "$_sdir/$SESSION_PID.json" 2>/dev/null || true)"
    fi
fi
REG_ARGS=(record registered --teammate "$NAME" --repo "$MAIN" --worktree "$DIR" --branch "$NAME" \
          --class hand-rolled --source create-teammate-worktree.sh)
[ -n "$SESSION" ] && REG_ARGS+=(--session-id "$SESSION")
[ -n "$SESSION_PID" ] && REG_ARGS+=(--session-pid "$SESSION_PID" --pid-start-of-session)
if ! python3 "$LEDGER_PY" "${REG_ARGS[@]}" >/dev/null 2>&1; then
    {
        echo "create-teammate-worktree.sh: created $DIR on branch $NAME but could NOT register it in the ownership ledger"
        echo "  ($(python3 "$LEDGER_PY" path 2>/dev/null || echo '<ledger path unknown>'))."
        echo "  An unregistered cross-repository worktree is the object this helper exists to prevent:"
        echo "  the reaper will report it owner-unresolved and FAIL until it is registered. Register it by hand:"
        echo "    python3 $LEDGER_PY ${REG_ARGS[*]}"
    } >&2
    exit 5
fi

# --- 5. report --------------------------------------------------------------
echo "created:    $DIR"
echo "branch:     $NAME  (from $BASE in $MAIN)"
echo "seeded:     $SEEDED file(s) from .worktreeinclude"
echo "registered: teammate=$NAME session=${SESSION:-<unknown>} pid=${SESSION_PID:-<unknown>} ($(python3 "$LEDGER_PY" path 2>/dev/null))"
echo ""
echo "Spawn it one of two ways (guard-worktree-isolation.sh refuses any other):"
echo "  cwd: \"$DIR\"                       -- no isolation: the teammate works here directly"
echo "  cross-repo-worktree: $DIR   -- as a prompt line, with isolation: \"worktree\" in the session repo"
exit 0
