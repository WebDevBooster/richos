#!/usr/bin/env bash
#
# remove-agent-worktree.sh — the ONLY sanctioned way to remove an
# agent-associated worktree (a native `<entity>/.claude/worktrees/agent-<id>`
# OR a hand-rolled external-repo worktree).
#
# WHY THIS EXISTS (a downstream adopter's operator directive, 2026-08-24):
#   The orchestrator removed a RUNNING agent's hand-rolled worktree because it
#   checked the WRONG artifact for liveness — the hand-rolled worktree (which
#   carries NO agent lock) instead of the agent's isolation-worktree lock in
#   the ENTITY's own repository. The agent was alive and had to be cancelled.
#   A doctrine note is not enough — removal must be gated by STRUCTURE.
#
# THE AUTHORITATIVE LIVENESS RULE (the crux — do not deviate):
#   An agent is ALIVE iff its NATIVE isolation worktree, registered in the
#   ENTITY's main checkout, is locked with a LIVE pid:
#     git -C <entity-main> worktree list --porcelain
#       -> a block whose `locked claude agent agent-<id> (pid <p> ...)` line
#          names <agent-id> AND pid <p> is currently running.
#   A stale lock (dead pid) = NOT alive. An UNLOCKED entity worktree = NOT
#   alive. An ABSENT/unregistered entity worktree = NOT alive. Hand-rolled
#   external-repo worktrees carry NO lock — they are NEVER the liveness source
#   (checking one is the exact 2026-08-24 mistake).
#
# WHICH REPOSITORY IS "THE ENTITY"? Resolved by the engine's two-root contract
# (scripts/lib/resolve-roots.sh): $RICHOS_ENTITY_ROOT, else $CLAUDE_PROJECT_DIR,
# else $PWD — never this script's own location, which is the ENGINE and is
# usually not the repository being governed at all. Overridable with
# --entity-repo for tests and for cross-entity operator work.
#
# WHAT THIS SCRIPT DOES:
#   1. Verifies (authoritative entity-lock + live-pid check) that <agent-id> is
#      NOT alive. If it IS alive -> REFUSE loudly, remove nothing. If liveness
#      cannot be determined (git error) -> REFUSE (fail-closed — never remove a
#      worktree we cannot prove is dead).
#   2. Only then removes the worktree in the correct repo (git worktree remove;
#      falls back to a plain directory removal if the path is not a registered
#      worktree of that repo) and, if --branch was given, deletes the branch.
#
# The companion PreToolUse[Bash] guard, scripts/hooks/guard-worktree-removal.sh,
# BLOCKS raw `git worktree remove` / `git worktree prune --expire` /
# `git branch -D <worktree-*>` / `rm -r <worktree-path>` UNLESS the command
# invokes THIS helper (its name is the marker the guard recognises) or carries
# an explicit `worktree-remove-ack:<reason>` override. So this helper is the
# blessed path: it runs the removal internally as a subprocess, which the
# PreToolUse hook never intercepts.
#
# The guard and this helper MOVE AS A PAIR and must never be split: a guard
# whose sanctioned escape route is not installed is a guard that only blocks.
#
# USAGE:
#   <engine>/scripts/remove-agent-worktree.sh --owner <agent-id> <worktree-path> \
#       [--branch <branch>] [--repo <repo-path>] [--force]
#
#   --owner <agent-id>   REQUIRED. The agent whose liveness is checked against
#                        the ENTITY's worktree lock. Accepts "agent-<id>" or "<id>".
#   <worktree-path>      REQUIRED. The worktree directory to remove (native or
#                        hand-rolled).
#   --branch <branch>    Optional. A branch to delete after removal (e.g.
#                        worktree-agent-<id>).
#   --repo <repo-path>   Optional. The git repo that OWNS <worktree-path>
#                        (where `git worktree remove` runs). Defaults to the
#                        entity main checkout. For a hand-rolled worktree of
#                        another repository, pass that repository's path.
#   --force              Pass --force to `git worktree remove` (needed for a
#                        worktree with untracked/modified files — a native
#                        isolation worktree always has untracked files, so the
#                        orchestrator passes --force AFTER collecting artifacts).
#
# ENTITY OVERRIDE:
#   --entity-repo <path>  (or env REMOVE_AGENT_ENTITY_REPO) overrides the repo
#   whose worktree lock is treated as authoritative for liveness. Used by the
#   test suite to point at a sandbox, and by an operator removing one entity's
#   worktree from a session seated in another.
#
# Exit codes:
#   0  agent confirmed NOT alive; worktree (and optional branch) removed.
#   2  usage error.
#   3  agent is ALIVE (or liveness indeterminate) — REFUSED, nothing removed.
#   4  removal failed (e.g. dirty worktree without --force).

set -euo pipefail

HOOK_TAG="(<engine>/scripts/remove-agent-worktree.sh)"

err() { printf '%s\n' "$*" >&2; }

usage() {
    cat >&2 <<EOF
usage: remove-agent-worktree.sh --owner <agent-id> <worktree-path> \\
           [--branch <branch>] [--repo <repo-path>] [--force] \\
           [--entity-repo <path>]

The ONLY sanctioned way to remove an agent-associated worktree. Verifies the
agent is NOT alive (authoritative ENTITY isolation-worktree lock + live-pid
check) before removing anything.
$HOOK_TAG
EOF
}

OWNER=""
WT_PATH=""
BRANCH=""
REPO=""
ENTITY_OVERRIDE="${REMOVE_AGENT_ENTITY_REPO:-}"
FORCE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --owner)          OWNER="${2:-}"; shift 2 ;;
        --branch)         BRANCH="${2:-}"; shift 2 ;;
        --repo)           REPO="${2:-}"; shift 2 ;;
        --entity-repo)    ENTITY_OVERRIDE="${2:-}"; shift 2 ;;
        --force)          FORCE=1; shift ;;
        -h|--help)        usage; exit 2 ;;
        --) shift; break ;;
        -*) err "ERROR: unknown option: $1"; usage; exit 2 ;;
        *)
            if [ -z "$WT_PATH" ]; then WT_PATH="$1"; shift
            else err "ERROR: unexpected extra argument: $1"; usage; exit 2; fi
            ;;
    esac
done
# Any trailing positionals after `--`.
if [ -z "$WT_PATH" ] && [ "$#" -gt 0 ]; then WT_PATH="$1"; shift; fi

if [ -z "$OWNER" ] || [ -z "$WT_PATH" ]; then
    err "ERROR: --owner <agent-id> and <worktree-path> are both required."
    usage
    exit 2
fi

command -v git >/dev/null 2>&1 || { err "ERROR: git is required. $HOOK_TAG"; exit 2; }
command -v python3 >/dev/null 2>&1 || { err "ERROR: python3 is required. $HOOK_TAG"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Resolve the ENTITY main checkout — the authoritative liveness source ---
# NOT this script's own location. Under a by-reference engine, SCRIPT_DIR/..
# is the ENGINE, which is not the repository whose agents are being removed.
if [ -n "$ENTITY_OVERRIDE" ]; then
    ENTITY_MAIN="$ENTITY_OVERRIDE"
else
    _RR_LIB="$SCRIPT_DIR/lib/resolve-roots.sh"
    if [ ! -f "$_RR_LIB" ]; then
        err "ERROR: scripts/lib/resolve-roots.sh is missing at $_RR_LIB — cannot"
        err "       determine which repository's worktree lock is authoritative."
        err "       Pass --entity-repo <path> explicitly. $HOOK_TAG"
        exit 2
    fi
    # shellcheck source=lib/resolve-roots.sh
    . "$_RR_LIB"
    if resolve_entity_root ""; then
        ENTITY_MAIN="$RICHOS_ENTITY_ROOT_RESOLVED"
    else
        err "=== remove-agent-worktree: REFUSED — no governed entity ==="
        err "  Could not resolve an adopted repository for this session"
        err "  (status: ${RICHOS_ROOT_STATUS:-unknown}). The entity's worktree lock is"
        err "  the ONLY authoritative liveness signal, so there is nothing to check"
        err "  against and nothing is removed."
        err "  Run this from a session seated in the entity, or pass --entity-repo."
        err "  $HOOK_TAG"
        exit 3
    fi
fi

# The repo that owns the worktree being removed (where `git worktree remove`
# runs). Defaults to the entity main checkout (native worktree case).
[ -n "$REPO" ] || REPO="$ENTITY_MAIN"

# Normalize the owner id to "agent-<id>".
case "$OWNER" in
    agent-*) OWNER_ID="$OWNER" ;;
    *)       OWNER_ID="agent-$OWNER" ;;
esac

# --- Authoritative liveness check against the ENTITY lock -----------------
# Emits one of:
#   LOCKED\t<pid>\t<path>   entity worktree present + locked, pid parsed
#   DEAD\t<reason>          absent / unlocked / locked-without-pid -> not alive
#   ERROR\t<reason>         could not query git -> caller fails closed
# NOTE: the python is passed via `python3 -c` with a SINGLE-quoted bash string
# (so it uses ONLY double quotes internally, no apostrophes). This avoids the
# macOS bash-3.2 quirk where a heredoc containing parentheses inside a $(...)
# command substitution is misparsed. Inputs arrive via the environment.
LIVENESS="$(ENTITY_MAIN="$ENTITY_MAIN" OWNER_ID="$OWNER_ID" python3 -c '
import os, re, subprocess, sys

entity = os.environ["ENTITY_MAIN"]
aid = os.environ["OWNER_ID"]

try:
    res = subprocess.run(
        ["git", "-C", entity, "worktree", "list", "--porcelain"],
        capture_output=True, text=True, timeout=20,
    )
except Exception as e:
    print("ERROR\tgit worktree list failed: %s" % e)
    sys.exit(0)
if res.returncode != 0:
    print("ERROR\tgit worktree list exited %d: %s"
          % (res.returncode, (res.stderr or "").strip()[:200]))
    sys.exit(0)

entries = []
cur_path = None
cur_locked = None
for line in res.stdout.splitlines():
    if line.startswith("worktree "):
        if cur_path is not None:
            entries.append((cur_path, cur_locked))
        cur_path = line[len("worktree "):]
        cur_locked = None
    elif line.startswith("locked"):
        cur_locked = line
if cur_path is not None:
    entries.append((cur_path, cur_locked))

# Match the entity worktree for this agent: the final path component is
# exactly <agent-id>, OR the lock line names <agent-id>.
match = None
for path, locked in entries:
    base = path.rstrip("/").split("/")[-1]
    if base == aid or (locked and aid in locked):
        match = (path, locked)
        break

if match is None:
    print("DEAD\tno registered entity worktree for %s (absent/unregistered) -> not alive" % aid)
    sys.exit(0)

path, locked = match
if not locked:
    print("DEAD\tentity worktree %s is present but UNLOCKED -> not alive (a live agent isolation worktree is always locked)" % path)
    sys.exit(0)

m = re.search(r"\(pid\s+(\d+)", locked)
if not m:
    print("DEAD\tentity worktree %s is locked but the lock line carries no pid (%r) -> treating as not alive" % (path, locked))
    sys.exit(0)

print("LOCKED\t%s\t%s" % (m.group(1), path))
')"

LV_KIND="$(printf '%s' "$LIVENESS" | cut -f1)"

refuse_alive() { # <pid> <path>
    local pid="$1" path="$2"
    {
        echo "=== remove-agent-worktree: REFUSED — agent is ALIVE ==="
        echo "  Agent '$OWNER_ID' is ALIVE: its isolation worktree in the entity"
        echo "    $ENTITY_MAIN"
        echo "  at"
        echo "    $path"
        echo "  is locked with a RUNNING pid ($pid)."
        echo ""
        echo "  Removing a live agent's worktree corrupts its workspace and forces"
        echo "  a cancel (the 2026-08-24 incident). Nothing was removed."
        echo ""
        echo "  Liveness = the ENTITY's isolation-worktree lock with a LIVE pid —"
        echo "  NEVER a hand-rolled external-repo worktree (it carries no lock)."
        echo "  Wait for a positive termination signal (completion/kill notification,"
        echo "  or the entity worktree becomes unlocked/absent), then re-run."
        echo "$HOOK_TAG"
    } >&2
}

case "$LV_KIND" in
    LOCKED)
        PID="$(printf '%s' "$LIVENESS" | cut -f2)"
        LOCK_PATH="$(printf '%s' "$LIVENESS" | cut -f3)"
        if kill -0 "$PID" 2>/dev/null; then
            refuse_alive "$PID" "$LOCK_PATH"
            exit 3
        fi
        err "note: entity worktree $LOCK_PATH carries a STALE lock (pid $PID is dead) — agent not alive, proceeding."
        ;;
    DEAD)
        err "note: $(printf '%s' "$LIVENESS" | cut -f2-)"
        ;;
    ERROR|*)
        {
            echo "=== remove-agent-worktree: REFUSED — liveness indeterminate ==="
            echo "  Could not verify whether agent '$OWNER_ID' is alive:"
            echo "    $(printf '%s' "$LIVENESS" | cut -f2-)"
            echo "  Failing closed — refusing to remove a worktree we cannot prove is"
            echo "  dead. Fix the entity repo path (--entity-repo) or git state,"
            echo "  then re-run."
            echo "$HOOK_TAG"
        } >&2
        exit 3
        ;;
esac

# --- Not alive: perform the removal ---------------------------------------
if [ ! -d "$WT_PATH" ]; then
    err "note: worktree path $WT_PATH does not exist on disk — nothing to remove (pruning + branch cleanup only)."
fi

REGISTERED=0
if git -C "$REPO" worktree list --porcelain 2>/dev/null \
        | grep -qxF "worktree $WT_PATH"; then
    REGISTERED=1
fi

REMOVE_RC=0
if [ "$REGISTERED" -eq 1 ]; then
    # A dead agent's native worktree may still carry a stale lock; unlock so
    # `git worktree remove` will proceed (harmless/no-op if not locked).
    git -C "$REPO" worktree unlock "$WT_PATH" >/dev/null 2>&1 || true
    if [ "$FORCE" -eq 1 ]; then
        git -C "$REPO" worktree remove --force "$WT_PATH" || REMOVE_RC=$?
    else
        git -C "$REPO" worktree remove "$WT_PATH" || REMOVE_RC=$?
    fi
    if [ "$REMOVE_RC" -ne 0 ]; then
        {
            echo "=== remove-agent-worktree: removal FAILED ==="
            echo "  'git worktree remove' exited $REMOVE_RC for:"
            echo "    $WT_PATH  (repo: $REPO)"
            echo "  The worktree likely has untracked/modified files. Collect any"
            echo "  artifacts first (scripts/collect-worktree-artifacts.sh), then"
            echo "  re-run with --force."
            echo "$HOOK_TAG"
        } >&2
        exit 4
    fi
    git -C "$REPO" worktree prune >/dev/null 2>&1 || true
elif [ -d "$WT_PATH" ]; then
    # Not a registered worktree of $REPO (e.g. a hand-rolled dir whose repo
    # registration is gone) — remove the directory directly. Liveness is
    # already confirmed dead above.
    rm -rf "$WT_PATH"
    git -C "$REPO" worktree prune >/dev/null 2>&1 || true
fi

# --- Optional branch deletion ---------------------------------------------
if [ -n "$BRANCH" ]; then
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
        git -C "$REPO" branch -D "$BRANCH" >/dev/null 2>&1 \
            && err "note: deleted branch $BRANCH" \
            || err "note: could not delete branch $BRANCH (already gone or checked out?)"
    else
        err "note: branch $BRANCH not found in $REPO — skipping branch delete."
    fi
fi

echo "✓ removed agent worktree: $WT_PATH${BRANCH:+ (branch $BRANCH)} — agent '$OWNER_ID' confirmed not alive. $HOOK_TAG"
exit 0
