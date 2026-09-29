#!/usr/bin/env bash
#
# install.sh — put the automatic checks into a repository's hooks, and PROVE git will call them.
#
# Usage:
#   install.sh [<repo>]              install (default: the repository this file is in)
#   install.sh --check [<repo>]      report each hook; exit 1 if any is missing or unreachable
#   install.sh --uninstall [<repo>]  remove the hooks this installed, and nothing else
#
# WHAT IT INSTALLS: shim.sh, copied to <git-common-dir>/hooks/ as pre-commit,
# pre-merge-commit, post-commit, post-merge and pre-push. Every linked worktree of the
# repository (native, ~/ab/richos-wt, Codex's, the nightly's) shares that one directory,
# so one install covers every committer. The shim runs the committed autocheck.py; see its
# header for what each hook checks.
#
# WHY "PROVE": on this Mac core.hooksPath is set globally, and it REPLACES .git/hooks. A hook
# placed there runs only because the global dispatcher (femcboost's
# install-git-identity-guard.sh) chains to "$(git rev-parse --git-common-dir)/hooks/<name>".
# So the chain is checked for each hook name, as engine/scripts/install-ref-forensics.sh
# checks it for reference-transaction, and a hook that would never be called is reported.
#
# A hook file that this did not write is never overwritten: it is reported and the install
# refuses, because replacing it would silently remove somebody else's check.

set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SELF_DIR/shim.sh"
MARKER="richos-autocheck-shim"
HOOKS="pre-commit pre-merge-commit post-commit post-merge pre-push"

MODE=install
case "${1:-}" in
    --check) MODE=check; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
REPO="${1:-$SELF_DIR}"

die() { printf 'autocheck install: %s\n' "$*" >&2; exit 2; }

[ -f "$SHIM" ] || die "shim missing at $SHIM"
COMMON="$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null)" || die "not a git repository: $REPO"
case "$COMMON" in
    /*) ;;
    *) COMMON="$(cd "$REPO" && cd "$COMMON" && pwd)" ;;
esac
DEST="$COMMON/hooks"
HOOKS_PATH="$(git -C "$REPO" config --get core.hooksPath 2>/dev/null || true)"

reachable() {
    local name="$1" dispatch
    [ -z "$HOOKS_PATH" ] && return 0
    dispatch="$HOOKS_PATH/$name"
    [ -e "$dispatch" ] || return 1
    grep -q 'git-common-dir' "$(readlink -f "$dispatch" 2>/dev/null || printf '%s' "$dispatch")" 2>/dev/null
}

ours() { [ -f "$1" ] && grep -q "$MARKER" "$1" 2>/dev/null; }

rc=0
for name in $HOOKS; do
    target="$DEST/$name"
    case "$MODE" in
        install)
            if [ -e "$target" ] && ! ours "$target"; then
                printf 'REFUSED    %s exists and was not written by this installer; not replaced\n' "$target"
                rc=1
                continue
            fi
            if [ ! -f "$target" ] || ! cmp -s "$SHIM" "$target"; then
                if ! { mkdir -p "$DEST" && cp "$SHIM" "$target" && chmod +x "$target"; }; then
                    printf 'FAILED     %s\n' "$target"
                    rc=1
                    continue
                fi
                printf 'INSTALLED  %s\n' "$target"
            else
                printf 'CURRENT    %s\n' "$target"
            fi
            if ! reachable "$name"; then
                printf 'UNREACHABLE core.hooksPath=%s does not chain to %s\n' "$HOOKS_PATH" "$target"
                rc=1
            fi
            ;;
        check)
            if ! ours "$target"; then
                printf 'MISSING    %s\n' "$target"; rc=1
            elif ! cmp -s "$SHIM" "$target"; then
                printf 'STALE      %s (differs from %s; run install.sh)\n' "$target" "$SHIM"; rc=1
            elif ! reachable "$name"; then
                printf 'UNREACHABLE %s (core.hooksPath=%s does not chain to it)\n' "$target" "$HOOKS_PATH"; rc=1
            else
                printf 'INSTALLED  %s\n' "$target"
            fi
            ;;
        uninstall)
            if ours "$target"; then
                rm -f "$target" && printf 'REMOVED    %s\n' "$target"
            fi
            ;;
    esac
done
exit "$rc"
