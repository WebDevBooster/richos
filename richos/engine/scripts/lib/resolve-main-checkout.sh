#!/usr/bin/env bash
#
# scripts/lib/resolve-main-checkout.sh — sourceable helper that resolves the
# TRUE main checkout root of this repository, regardless of whether the
# calling script's own copy lives in the main checkout or in a linked git
# worktree (`.claude/worktrees/agent-<id>/`).
#
# Why this exists: several scripts resolve "the repo root" as
# `$(cd "$SCRIPT_DIR/.." && pwd)` — current-checkout semantics. That is
# correct for scripts that should act on whatever checkout they physically
# live in. But a handful of checks are conceptually about the ONE shared main
# checkout (e.g. the hook wiring in `.claude/settings.json`). When a copy of
# such a script runs from a worktree, current-checkout resolution silently
# mis-targets the worktree and the check spuriously fails. This helper gives
# those checks a main-checkout-true root from any invocation location.
#
# Mechanism: `git rev-parse --git-common-dir` returns the SHARED `.git`
# directory for every worktree of one repo (each linked worktree has its own
# PRIVATE git-dir under `.git/worktrees/<id>`, but --git-common-dir always
# points at the single shared `.git`). The main checkout is that directory's
# parent. From the main checkout this yields exactly the same value as the
# legacy `$SCRIPT_DIR/..`-style resolution, so behavior is byte-identical
# there; from any worktree it correctly resolves to the main checkout.
#
# Source it, then call:
#
#   resolve_main_checkout <anchor_dir> [fallback_root]
#
#   <anchor_dir>    a directory INSIDE the checkout (typically the calling
#                   script's own SCRIPT_DIR) — used as the `git -C` context.
#   [fallback_root] value returned verbatim when git is unavailable or the
#                   anchor is not a git checkout at all (e.g. a test sandbox).
#                   Defaults to <anchor_dir>. Callers pass their existing
#                   current-checkout REPO_ROOT here so the no-git fallback
#                   preserves pre-fix behavior exactly.
#
# Prints the resolved main-checkout root to stdout. Never mutates state,
# never changes the caller's cwd. Safe to source multiple times.

# Include guard — safe to source repeatedly.
if [ -n "${_RESOLVE_MAIN_CHECKOUT_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_RESOLVE_MAIN_CHECKOUT_SH_SOURCED=1

resolve_main_checkout() {
    local anchor="${1:-$PWD}"
    local fallback="${2:-$anchor}"
    local common_dir
    common_dir="$(git -C "$anchor" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$common_dir" ]; then
        # dirname of the shared .git is the main checkout root. Normalize via
        # cd/pwd so the result matches the legacy `(cd ... && pwd)` idiom
        # (symlink-resolved, no trailing slash).
        ( cd "$(dirname "$common_dir")" 2>/dev/null && pwd ) && return 0
    fi
    # No git, or not a git checkout — behave exactly as the pre-fix
    # current-checkout resolution did.
    printf '%s\n' "$fallback"
}
