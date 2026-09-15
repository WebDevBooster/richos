#!/usr/bin/env bash
#
# scripts/lib/assert-own-worktree-registered.sh — sourceable "identity-or-
# refuse on my own location" guard for long-running scripts that write state
# under a git worktree (install-fresh, its seal writers, etc.).
#
# THE FAILURE CLASS (observed 2026-07-18): a stalled agent's orphaned
# background `ios-install-fresh` run outlived BOTH the agent AND its reaped
# worktree. `git worktree remove` had deleted the worktree directory and its
# registry entry, but the still-running orphan re-created
# `.claude/worktrees/agent-<id>/` (via a mkdir on the way to a state write) and
# wrote per-run seal state into that GHOST path. Downstream tooling could then
# trust a seal that lives in a directory git no longer knows about.
#
# THE GUARD: before any state write, a script must prove its own working
# location is legitimate — either the true main checkout, or a path currently
# REGISTERED in that main checkout's `git worktree list`. A zombie residue
# directory is, by construction, absent from the registry (git removed the
# registration when the worktree was reaped), so it fails this check. On
# failure the script aborts LOUDLY (non-zero) and NEVER creates directories.
#
# Design mirrors resolve-main-checkout.sh: main-checkout runs and legitimate
# linked-worktree runs (the 2026-07-14 worktree-runnable design) both pass;
# only the unregistered-path zombie condition fails.
#
# Source it, then call:
#
#   assert_own_worktree_registered <anchor_dir> <repo_root> [phase_label]
#
#   <anchor_dir>   a directory INSIDE the checkout (typically the caller's
#                  SCRIPT_DIR) used as the git -C context for main-checkout
#                  resolution.
#   <repo_root>    the caller's own resolved checkout root (current-checkout
#                  semantics, e.g. "$SCRIPT_DIR/..") — the location whose
#                  legitimacy is being asserted.
#   [phase_label]  optional label for the abort message (e.g. "startup",
#                  "before seal write"). Defaults to "state write".
#
# Returns 0 when the location is legitimate; prints a diagnostic to stderr and
# returns 1 when it is an unregistered zombie path. Never mutates state, never
# changes the caller's cwd, never creates directories. Safe to source and call
# repeatedly (e.g. at startup and again before each state-write phase).

# Include guard — safe to source repeatedly.
if [ -n "${_ASSERT_OWN_WORKTREE_REGISTERED_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_ASSERT_OWN_WORKTREE_REGISTERED_SH_SOURCED=1

# Pull in resolve_main_checkout from the sibling lib (same directory).
_AOWR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-main-checkout.sh
. "$_AOWR_LIB_DIR/resolve-main-checkout.sh"

assert_own_worktree_registered() {
    local anchor="${1:-$PWD}"
    local repo_root="${2:-$PWD}"
    local phase="${3:-state write}"

    # Normalize repo_root to its PHYSICAL path (pwd -P, symlink-resolved, no
    # trailing slash) so it compares byte-for-byte against `git worktree list`
    # output and resolve_main_checkout — git always reports physical paths, so
    # on macOS the /var -> /private/var symlink would otherwise cause a spurious
    # mismatch.
    local self
    self="$( cd "$repo_root" 2>/dev/null && pwd -P )" || self="$repo_root"

    # Resolve the ONE true main checkout from wherever we physically live. From
    # a zombie path under the main working tree this still resolves upward to
    # the main checkout's shared .git (the zombie dir has no private git-dir of
    # its own), so main-checkout identity is always recoverable. Canonicalize to
    # the physical path for the same reason as `self`.
    local main_co_raw main_co
    main_co_raw="$(resolve_main_checkout "$anchor" "$self")"
    main_co="$( cd "$main_co_raw" 2>/dev/null && pwd -P )" || main_co="$main_co_raw"

    # Case 1: we ARE the main checkout — always legitimate (main-checkout run).
    if [ "$self" = "$main_co" ]; then
        return 0
    fi

    # Case 2: we are a linked worktree. Legitimate ONLY if git's registry for
    # the main checkout still lists our exact path. A reaped-then-recreated
    # zombie directory is absent from this list by definition.
    if git -C "$main_co" worktree list --porcelain 2>/dev/null \
         | sed -n 's|^worktree ||p' \
         | grep -qxF "$self"; then
        return 0
    fi

    # Unregistered path -> zombie residue. Refuse LOUDLY. Create nothing.
    {
        printf '\033[31m✗ ZOMBIE-PATH ABORT (%s): refusing to write state.\033[0m\n' "$phase"
        printf '  This run'\''s working location is neither the main checkout nor a\n'
        printf '  REGISTERED worktree of it:\n'
        printf '    working location : %s\n' "$self"
        printf '    main checkout    : %s\n' "$main_co"
        printf '  This is the zombie-residue condition: a worktree removed via\n'
        printf '  '\''git worktree remove'\'' whose directory was re-created by an orphaned\n'
        printf '  background process that outlived its agent. Any state written here is\n'
        printf '  a ghost that no live agent owns. Kill this stray process; do not trust\n'
        printf '  its output. (No directories were created.)\n'
    } >&2
    return 1
}
