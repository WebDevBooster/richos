#!/usr/bin/env bash
#
# reap-stale-worktrees.sh — reap merged, clean, dead native-isolation
# worktrees under `.claude/worktrees/agent-*` so landed-but-never-removed
# teammate worktrees stop accumulating across sessions.
#
# WHY: every file-writing teammate spawn creates a linked git worktree at
# `.claude/worktrees/agent-<id>` (native isolation — see the "Git Worktree
# Isolation" section of your CLAUDE.md). The orchestrator is supposed to remove
# each one at land time (collect-worktree-artifacts.sh + `git worktree remove`
# + `git branch -d`), but across restarts, dropped handoffs, and interrupted
# sessions these pile up. In the upstream production project this kit was
# extracted from, 43 stale worktrees were found to have silently accumulated
# before anyone noticed. This script is the safety net: a conservative sweep
# that removes ONLY worktrees provably safe to discard, DRY-RUN by default.
#
# REPO-AGNOSTIC: works against ANY repo using the same
# `.claude/worktrees/agent-<hex>` directory / `worktree-agent-<hex>` branch
# naming convention — no assumptions about your product, your branch names, or
# your directory layout. Repo root defaults to the TRUE main checkout, resolved
# via scripts/lib/resolve-main-checkout.sh (the same helper the integrity probe
# uses), so this works correctly even when this copy of the script is itself
# running from inside a linked worktree. If that helper is absent (a repo that
# hasn't adopted it), falls back to plain current-checkout resolution
# (`$SCRIPT_DIR/..`) — degrade gracefully, never hard-fail on a missing
# convenience helper.
#
# SAFETY MODEL (non-negotiable): this tool must be STRUCTURALLY incapable of
# destroying unlanded work.
#   - Default mode is DRY-RUN. Nothing is removed, nothing is unlocked, and
#     `git worktree prune` is not run, unless --execute is passed.
#   - Every removal is gated on ALL FOUR safety checks below passing, in
#     order. The first failing gate short-circuits to a SKIP with a reason
#     — a SKIP is never treated as an error.
#   - Removal uses `git worktree remove` (NEVER --force) then `git branch -d`
#     (NEVER -D) — a branch with unmerged commits refuses `-d`, which is
#     exactly the backstop you want if gate 2 is somehow wrong.
#   - The operator (not this script, not a hook) is the one who passes
#     --execute for the first real run.
#
# Per-tree safety gates — a tree is REAP-eligible only if ALL hold:
#   1. NOT locked. A lock means "possibly still in use" and is always
#      respected. With --unlock-stale, a lock is broken ONLY when BOTH:
#        (a) no live process references the worktree path (`pgrep -f
#            <path>`), AND
#        (b) the lock file is older than 2 hours (its mtime).
#      Otherwise: SKIP locked-possibly-live. Without --unlock-stale, any
#      locked tree is simply SKIP locked.
#   2. Branch `worktree-<id>` is a merge-base ancestor of whatever branch
#      the resolved repo root's HEAD is actually on (no hardcoded "main"
#      literal — repo-agnostic). Unmerged -> SKIP unmerged(+N) (N = commit
#      count not yet in the target branch). Branch missing entirely ->
#      SKIP no-branch (can't verify — conservative).
#   3. `git -C <tree> status --porcelain` is empty (tracked AND untracked).
#      Dirty -> SKIP dirty(N).
#   4. No live process references the tree path (`pgrep -f <path>`).
#      Live -> SKIP live-process(<pids>).
#   A tree whose directory no longer exists on disk (registered but
#   deleted out-of-band) is reported SKIP missing-dir — `git worktree
#   prune` (run at the end, --execute only) clears its registration; no
#   further gate is evaluated for it.
#
# Usage:
#   scripts/reap-stale-worktrees.sh [repo-root] [--execute] [--unlock-stale]
#
#   repo-root        Optional. Defaults to the resolved main checkout.
#   --execute        Perform removals/unlocks/prune. Without it: DRY-RUN
#                     (report only, zero mutation).
#   --unlock-stale   Allow breaking a stale lock per gate 1. Without
#                     --execute this only changes what the DRY-RUN reports
#                     (nothing is actually unlocked).
#
# Before each real removal, scripts/collect-worktree-artifacts.sh is run
# against the tree if it exists in the target repo (tolerated if absent) —
# mirrors land-time practice ("the commit IS the handoff"; gitignored test/QA
# evidence still needs collecting first). Never run in DRY-RUN (it writes
# gitignored artifact dirs into the main checkout).
#
# Output: one `REAP <id>` / `SKIP <id> <reason>` line per tree (DRY-RUN
# REAP lines are prefixed `DRY-RUN` in addition to the banner), plus a final
# summary. Any directory under `.claude/worktrees/` that is NOT a registered
# git worktree is reported as residue — never deleted; git doesn't own it.
#
# Wired as a SessionStart sweep by scripts/hooks/session-start-reap-worktrees.sh
# and covered by the integrity probe's Layer Q (see README.md, "What ships").
#
# Exit codes:
#   0  clean run (a SKIP is not an error)
#   1  unexpected error (missing/invalid repo, a git command failed
#      unexpectedly, a removal failed, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: scripts/reap-stale-worktrees.sh [repo-root] [--execute] [--unlock-stale]

  repo-root        Optional. Defaults to the resolved main checkout.
  --execute        Perform removals/unlocks/prune. Without it: DRY-RUN.
  --unlock-stale   Allow breaking a lock that is >2h old with no live
                    process referencing the tree. No effect without
                    --execute except on what the DRY-RUN reports.
  -h, --help       Show this help.
EOF
}

EXECUTE=0
UNLOCK_STALE=0
REPO_ROOT_ARG=""

for arg in "$@"; do
    case "$arg" in
    --execute)
        EXECUTE=1
        ;;
    --unlock-stale)
        UNLOCK_STALE=1
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        echo "ERROR: unknown flag: $arg" >&2
        usage >&2
        exit 1
        ;;
    *)
        if [ -n "$REPO_ROOT_ARG" ]; then
            echo "ERROR: unexpected extra positional argument: $arg" >&2
            exit 1
        fi
        REPO_ROOT_ARG="$arg"
        ;;
    esac
done

command -v git >/dev/null 2>&1 || { echo "ERROR: git is required" >&2; exit 1; }

# --- Resolve repo root -----------------------------------------------------
_RMC_LIB="$SCRIPT_DIR/lib/resolve-main-checkout.sh"
_FALLBACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -n "$REPO_ROOT_ARG" ]; then
    [ -d "$REPO_ROOT_ARG" ] || { echo "ERROR: repo-root does not exist: $REPO_ROOT_ARG" >&2; exit 1; }
    REPO_ROOT="$(cd "$REPO_ROOT_ARG" && pwd)"
elif [ -f "$_RMC_LIB" ]; then
    # shellcheck source=lib/resolve-main-checkout.sh
    . "$_RMC_LIB"
    REPO_ROOT="$(resolve_main_checkout "$SCRIPT_DIR" "$_FALLBACK_ROOT")"
else
    REPO_ROOT="$_FALLBACK_ROOT"
fi

git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERROR: not a git repository: $REPO_ROOT" >&2; exit 1; }

WT_ROOT="$REPO_ROOT/.claude/worktrees"

if [ "$EXECUTE" -eq 1 ]; then
    MODE_LABEL="EXECUTE"
else
    MODE_LABEL="DRY-RUN"
fi

echo "=== reap-stale-worktrees: $MODE_LABEL — repo root: $REPO_ROOT ==="
if [ "$EXECUTE" -eq 0 ]; then
    echo "=== DRY-RUN: no worktree/branch will be removed, no lock broken, no prune run. Pass --execute to perform. ==="
fi

# --- Resolve the target branch for the merge-base check (gate 2) ----------
# Whatever branch the resolved repo root's HEAD is actually on — no
# hardcoded "main" literal, so this stays correct in any repo/branch scheme.
# Falls back to the raw commit SHA if HEAD is detached.
TARGET_REF="$(git -C "$REPO_ROOT" symbolic-ref -q --short HEAD || true)"
if [ -z "$TARGET_REF" ]; then
    TARGET_REF="$(git -C "$REPO_ROOT" rev-parse HEAD)"
fi

# --- Small helpers ----------------------------------------------------------

mtime_of() { # <file> -> epoch seconds on stdout, or nonzero exit
    local f="$1" v
    v="$(stat -f %m "$f" 2>/dev/null)" && { printf '%s\n' "$v"; return 0; }
    v="$(stat -c %Y "$f" 2>/dev/null)" && { printf '%s\n' "$v"; return 0; }
    if command -v python3 >/dev/null 2>&1; then
        v="$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$f" 2>/dev/null)" && { printf '%s\n' "$v"; return 0; }
    fi
    return 1
}

live_pids_for() { # <path> -> comma-separated pids on stdout (may be empty)
    local path="$1"
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$path" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true
    fi
}

REAP_COUNT=0
SKIP_COUNT=0
ERROR_COUNT=0
SKIP_LOCKED=0
SKIP_LOCKED_LIVE=0
SKIP_UNMERGED=0
SKIP_DIRTY=0
SKIP_LIVE_PROCESS=0
SKIP_MISSING_DIR=0
SKIP_NO_BRANCH=0

skip() { # <id> <reason>
    echo "SKIP $1 $2"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

# --- Parse `git worktree list --porcelain` into parallel arrays ------------
# Each block: "worktree <path>" / "HEAD <sha>" / "branch refs/heads/<name>"
# (or "detached") / optional "locked [reason]" / optional "prunable
# [reason]" / blank line separator.
WT_PATHS=()
WT_LOCKED=()

_cur_path=""
_cur_locked=0
_have_cur=0

_flush() {
    if [ "$_have_cur" -eq 1 ]; then
        WT_PATHS+=("$_cur_path")
        WT_LOCKED+=("$_cur_locked")
    fi
}

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    worktree\ *)
        _flush
        _cur_path="${line#worktree }"
        _cur_locked=0
        _have_cur=1
        ;;
    locked*)
        _cur_locked=1
        ;;
    "")
        : # block separator — flush happens on next "worktree " or at EOF
        ;;
    esac
done < <(git -C "$REPO_ROOT" worktree list --porcelain)
_flush

if [ "${#WT_PATHS[@]}" -eq 0 ]; then
    echo "ERROR: 'git worktree list' returned no entries — unexpected" >&2
    exit 1
fi

# --- Registered-worktree set, for the residue report later -----------------
REGISTERED_LIST="$(git -C "$REPO_ROOT" worktree list --porcelain | sed -n 's|^worktree ||p')"

# --- Main sweep --------------------------------------------------------------
for i in "${!WT_PATHS[@]}"; do
    path="${WT_PATHS[$i]}"
    locked="${WT_LOCKED[$i]}"

    # Only consider native-isolation agent worktrees under this repo's
    # .claude/worktrees/agent-* — never the main worktree itself (it never
    # matches this path shape) and never any hand-rolled/non-native tree.
    case "$path" in
    "$WT_ROOT"/agent-*) : ;;
    *) continue ;;
    esac

    id="$(basename "$path")"
    branch_name="worktree-$id"

    # Directory gone but still registered -> report + let `worktree prune`
    # (execute-only, end of run) clear the registration. No further gate.
    if [ ! -d "$path" ]; then
        skip "$id" "missing-dir"
        SKIP_MISSING_DIR=$((SKIP_MISSING_DIR + 1))
        continue
    fi

    # --- Gate 1: lock ---
    if [ "$locked" -eq 1 ]; then
        if [ "$UNLOCK_STALE" -eq 0 ]; then
            skip "$id" "locked"
            SKIP_LOCKED=$((SKIP_LOCKED + 1))
            continue
        fi

        admin_dir="$(git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
        lock_file="$admin_dir/locked"
        if [ -z "$admin_dir" ] || [ ! -f "$lock_file" ]; then
            # Porcelain says locked but we can't find/verify the lock file
            # — conservative: never touch what we can't verify.
            skip "$id" "locked-possibly-live"
            SKIP_LOCKED_LIVE=$((SKIP_LOCKED_LIVE + 1))
            continue
        fi

        lock_mtime="$(mtime_of "$lock_file" || true)"
        now="$(date +%s)"
        pids="$(live_pids_for "$path")"

        if [ -z "$lock_mtime" ]; then
            skip "$id" "locked-possibly-live"
            SKIP_LOCKED_LIVE=$((SKIP_LOCKED_LIVE + 1))
            continue
        fi
        age=$((now - lock_mtime))

        if [ -n "$pids" ] || [ "$age" -lt 7200 ]; then
            skip "$id" "locked-possibly-live"
            SKIP_LOCKED_LIVE=$((SKIP_LOCKED_LIVE + 1))
            continue
        fi

        # Stale lock: no live process, lock file >2h old.
        if [ "$EXECUTE" -eq 1 ]; then
            if ! git -C "$REPO_ROOT" worktree unlock "$path" >/dev/null 2>&1; then
                echo "ERROR: failed to unlock stale lock on $id (age ${age}s, no live process) — leaving alone" >&2
                skip "$id" "unlock-failed"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                continue
            fi
            echo "  (unlocked stale lock on $id — age ${age}s, no live process)"
        else
            echo "  (DRY-RUN: would unlock stale lock on $id — age ${age}s, no live process — then re-evaluate)"
        fi
        # Fall through to gates 2-4 below (real unlock happened above in
        # EXECUTE mode; in DRY-RUN we simply continue evaluating as if it
        # would be unlocked, for accurate reporting).
    fi

    # --- Gate 2: merged ---
    if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/$branch_name" >/dev/null; then
        skip "$id" "no-branch"
        SKIP_NO_BRANCH=$((SKIP_NO_BRANCH + 1))
        continue
    fi
    if ! git -C "$REPO_ROOT" merge-base --is-ancestor "refs/heads/$branch_name" "$TARGET_REF" 2>/dev/null; then
        n="$(git -C "$REPO_ROOT" rev-list --count "$TARGET_REF..refs/heads/$branch_name" 2>/dev/null || echo '?')"
        skip "$id" "unmerged(+$n)"
        SKIP_UNMERGED=$((SKIP_UNMERGED + 1))
        continue
    fi

    # --- Gate 3: clean ---
    dirty_lines="$(git -C "$path" status --porcelain 2>/dev/null || true)"
    if [ -n "$dirty_lines" ]; then
        n="$(printf '%s\n' "$dirty_lines" | grep -c . || true)"
        skip "$id" "dirty($n)"
        SKIP_DIRTY=$((SKIP_DIRTY + 1))
        continue
    fi

    # --- Gate 4: no live process ---
    pids="$(live_pids_for "$path")"
    if [ -n "$pids" ]; then
        skip "$id" "live-process($pids)"
        SKIP_LIVE_PROCESS=$((SKIP_LIVE_PROCESS + 1))
        continue
    fi

    # --- All gates passed: REAP-eligible ---
    if [ "$EXECUTE" -eq 1 ]; then
        if [ -f "$REPO_ROOT/scripts/collect-worktree-artifacts.sh" ]; then
            if ! bash "$REPO_ROOT/scripts/collect-worktree-artifacts.sh" "$path"; then
                echo "WARN: artifact collection failed for $id — proceeding with removal anyway" >&2
            fi
        fi
        if git -C "$REPO_ROOT" worktree remove "$path"; then
            if git -C "$REPO_ROOT" branch -d "$branch_name" >/dev/null 2>&1; then
                echo "REAP $id"
                REAP_COUNT=$((REAP_COUNT + 1))
            else
                echo "ERROR: removed worktree $id but 'git branch -d $branch_name' refused (unmerged commits protecting it?) — investigate manually" >&2
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
        else
            echo "ERROR: 'git worktree remove' failed for $id" >&2
            ERROR_COUNT=$((ERROR_COUNT + 1))
        fi
    else
        echo "DRY-RUN REAP $id"
        REAP_COUNT=$((REAP_COUNT + 1))
    fi
done

# --- After the loop: prune + residue report --------------------------------
if [ "$EXECUTE" -eq 1 ]; then
    git -C "$REPO_ROOT" worktree prune
    echo "(ran: git worktree prune)"
else
    echo "(DRY-RUN: would run 'git worktree prune')"
fi

RESIDUE_COUNT=0
if [ -d "$WT_ROOT" ]; then
    for d in "$WT_ROOT"/*/; do
        [ -d "$d" ] || continue
        real_d="$(cd "${d%/}" 2>/dev/null && pwd -P)" || continue
        if printf '%s\n' "$REGISTERED_LIST" | grep -qxF "$real_d"; then
            continue
        fi
        echo "RESIDUE $real_d — present on disk under .claude/worktrees/ but NOT a registered git worktree (git doesn't own it; investigate manually, never auto-deleted)"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    done
fi

echo "=== summary ($MODE_LABEL): reaped=$REAP_COUNT skipped=$SKIP_COUNT errors=$ERROR_COUNT residue=$RESIDUE_COUNT ==="
echo "    skip breakdown: locked=$SKIP_LOCKED locked-possibly-live=$SKIP_LOCKED_LIVE unmerged=$SKIP_UNMERGED dirty=$SKIP_DIRTY live-process=$SKIP_LIVE_PROCESS missing-dir=$SKIP_MISSING_DIR no-branch=$SKIP_NO_BRANCH"

if [ "$ERROR_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
