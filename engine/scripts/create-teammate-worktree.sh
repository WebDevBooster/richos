#!/usr/bin/env bash
#
# create-teammate-worktree.sh — THE ONLY WAY TO GIVE A TEAMMATE A WORKSPACE IN
# ANOTHER REPOSITORY. The page: docs/plans/worktree-spec-2026-09-11.md.
#
#   1. "Every non-native Claude workspace is named cc/."            (point 1)
#   3. "If registration fails, the spawn does not happen. Creating a
#       non-native workspace not named cc/ is refused."             (point 3)
#
# WHAT IT DOES, in order — and it stops at the first refusal:
#   1. Refuses a name that is not <role>-<model>-<identifier> (the spawn
#      contract), a path that already exists, a branch that already exists,
#      and a base that is a codex/ branch (point 2: an agent works from a copy
#      in its own cc/ workspace, never inside a codex/ one).
#   2. REGISTERS the workspace — session, teammate, repository, path, cc/
#      branch — in the workspace registry (scripts/lib/workspaces.py) BEFORE
#      anything exists on disk. If the registration cannot be written, nothing
#      is created, so no spawn can name the workspace.
#   3. `git worktree add <dir> -b cc/<name> <base>` in the repository's MAIN
#      checkout (resolved through `git worktree list`, never guessed).
#   4. Seeds every gitignored file matching a `.worktreeinclude` pattern from
#      the main checkout — the same contract native isolation honors.
#   5. Confirms the registration: created. If creation failed, the
#      registration records that instead; the agent was never spawned, so it
#      counts as finished, and whatever git left behind (a branch) is deleted
#      by the page's own land — an agent that produced nothing counts as landed
#      (point 7). This script deletes nothing.
#   6. Prints the path and the spawn contract that carries it.
#
# USAGE
#   ~/.claude/richos-engine/scripts/create-teammate-worktree.sh <repo> <teammate-name> [--dir <path>]
#       [--base <ref>] [--session <id>]
#
#   <repo>            any path inside the target repository
#   <teammate-name>   the name the spawn will carry, e.g. echo-opus-bt2
#   --dir <path>      where to put it; default <main>-wt/<name> beside the
#                     main checkout (the convention this machine already uses)
#   --base <ref>      branch point; default the main checkout's HEAD. To
#                     continue a finished agent's work (point 7), its branch:
#                     --base cc/<old-name>, and spawn with `continues: <old-name>`.
#   --session <id>    the session the spawn will run in; default the session
#                     this command runs in (its recorded process is an ancestor)
#
# Environment (test affordances): RICHOS_WORKSPACES_DIR, RICHOS_SESSION_PID,
# RICHOS_SESSION_ID.
#
# Exit codes: 0 created + registered; 2 usage; 3 refused (name / exists /
#             registration); 4 git failed (the registration records it).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_PY="$SCRIPT_DIR/lib/workspaces.py"

usage() {
    sed -n '/^# USAGE/,/^# Environment/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

REPO_ARG=""; NAME=""; DIR=""; BASE=""; SESSION=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir)     DIR="${2:-}"; shift 2 ;;
        --base)    BASE="${2:-}"; shift 2 ;;
        --session) SESSION="${2:-}"; shift 2 ;;
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
[ -f "$WS_PY" ] || { echo "create-teammate-worktree.sh: the workspace registry is missing at $WS_PY — refusing to create a workspace that could not be registered" >&2; exit 2; }

refuse() { echo "create-teammate-worktree.sh: REFUSED — $*" >&2; exit 3; }

# --- 1. the name is the spawn contract's name --------------------------------
ALLOWED_MODELS="fable opus sonnet haiku"
if [ -f "$SCRIPT_DIR/../orchestration.config" ]; then
    _am="$(sed -n 's/^ALLOWED_MODELS="\(.*\)"$/\1/p' "$SCRIPT_DIR/../orchestration.config" | head -1)"
    [ -n "$_am" ] && ALLOWED_MODELS="$_am"
fi
NAME_RE="^[a-z][a-z0-9]{1,15}-($(printf '%s' "$ALLOWED_MODELS" | tr ' ' '|'))-[a-z0-9]{1,12}$"
printf '%s' "$NAME" | grep -qE "$NAME_RE" \
    || refuse "'$NAME' is not a teammate name of the form <role>-<model>-<identifier> (model one of: $ALLOWED_MODELS)."

# --- the repository's MAIN checkout, from git, never from the argument -------
[ -d "$REPO_ARG" ] || refuse "'$REPO_ARG' is not a directory"
MAIN="$(git -C "$REPO_ARG" worktree list --porcelain 2>/dev/null | sed -n '1s|^worktree ||p')"
[ -n "$MAIN" ] || refuse "'$REPO_ARG' is not inside a git repository"
MAIN="$(cd "$MAIN" && pwd -P)"

[ -n "$DIR" ] || DIR="$(dirname "$MAIN")/$(basename "$MAIN")-wt/$NAME"
[ ! -e "$DIR" ] || refuse "'$DIR' already exists"
case "$DIR" in /*) : ;; *) DIR="$(pwd -P)/$DIR" ;; esac
# THE BRANCH CARRIES OUR OWN PREFIX (point 1). Git cannot hold a bare `cc`
# ref beside `cc/<name>`, so nothing may ever create one.
BRANCH="cc/$NAME"
if git -C "$MAIN" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
    refuse "branch '$BRANCH' already exists in $MAIN — a teammate name is used once; pick a fresh identifier"
fi
[ -n "$BASE" ] || BASE="HEAD"
git -C "$MAIN" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
    || refuse "base ref '$BASE' does not resolve in $MAIN"
case "$BASE" in
    codex/*|refs/heads/codex/*)
        refuse "base '$BASE' is a codex/ branch — codex/ is never touched; an agent works from a copy in its own cc/ workspace, so branch from the commit instead: --base \$(git -C $MAIN rev-parse $BASE) (point 2)" ;;
esac

# --- 2. register BEFORE anything exists (point 3) ---------------------------
SESS_ARGS=()
[ -n "$SESSION" ] && SESS_ARGS=(--session "$SESSION")
if ! _reg_err="$(python3 "$WS_PY" ${SESS_ARGS[@]+"${SESS_ARGS[@]}"} register-cc --name "$NAME" --repo "$MAIN" \
        --path "$DIR" --branch "$BRANCH" 2>&1 >/dev/null)"; then
    refuse "the workspace could not be registered, so it was not created: ${_reg_err#workspaces: REFUSED — }"
fi

# --- 3. create --------------------------------------------------------------
_fail() { # <why>
    python3 "$WS_PY" ${SESS_ARGS[@]+"${SESS_ARGS[@]}"} confirm-cc --name "$NAME" --path "$DIR" --failed "$1" >/dev/null 2>&1 || true
    echo "create-teammate-worktree.sh: $1 — the registration records it; nothing is spawned into it, and whatever git left behind is deleted by the page's own land (docs/plans/worktree-spec-2026-09-11.md, point 7)." >&2
    exit 4
}
mkdir -p "$(dirname "$DIR")" || _fail "cannot create $(dirname "$DIR")"
git -C "$MAIN" worktree add -q "$DIR" -b "$BRANCH" "$BASE" || _fail "git worktree add failed for $DIR"
DIR="$(cd "$DIR" && pwd -P)"
git -C "$MAIN" worktree list --porcelain 2>/dev/null | sed -n 's|^worktree ||p' \
    | while IFS= read -r _p; do [ "$(cd "$_p" 2>/dev/null && pwd -P)" = "$DIR" ] && exit 0; done \
    || _fail "git does not list $DIR as a worktree of $MAIN"

# --- 4. seed .worktreeinclude ---------------------------------------------
# The same contract native isolation honors: gitignore-style patterns, matched
# against files that are IGNORED in the main checkout, copied with their
# relative paths. Done in python so `**/` means what .gitignore means by it.
SEEDED=0
if [ -f "$MAIN/.worktreeinclude" ]; then
    SEEDED="$(MAIN="$MAIN" DIR="$DIR" python3 - <<'PY' 2>/dev/null || echo 0
import os, re, shutil, subprocess, sys
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

# --- 5. confirm -------------------------------------------------------------
if ! python3 "$WS_PY" ${SESS_ARGS[@]+"${SESS_ARGS[@]}"} confirm-cc --name "$NAME" --path "$DIR" >/dev/null 2>&1; then
    echo "create-teammate-worktree.sh: created $DIR but its registration could not be confirmed — the spawn guard will refuse to spawn into it; it is finished work of this session (point 3) and the page's land deletes it." >&2
    exit 4
fi

# --- 6. report --------------------------------------------------------------
echo "created:    $DIR"
echo "branch:     $BRANCH  (from $BASE in $MAIN)"
echo "seeded:     $SEEDED file(s) from .worktreeinclude"
echo "registered: teammate=$NAME ($(python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("w",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.state_dir())' "$WS_PY" 2>/dev/null))"
echo ""
echo "Spawn with isolation: \"worktree\" in the session repo; add this prompt line:"
echo "  cross-repo-worktree: $DIR"
echo "A cwd-only spawn is refused."
echo "Prepare the full Agent JSON, including its mandatory acknowledgement contract:"
echo "  python3 \"$SCRIPT_DIR/prepare-agent-spawn.py\" --file <task-input.json>"
exit 0
