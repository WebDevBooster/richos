#!/usr/bin/env bash
#
# install-ref-forensics.sh — install the `reference-transaction` forensics hook
# into a repository, and PROVE it will actually be invoked.
#
# Usage:
#   install-ref-forensics.sh [<repo>]            install (default: cwd's repo)
#   install-ref-forensics.sh --check [<repo>]    report status, exit 1 if absent
#   install-ref-forensics.sh --uninstall [<repo>]
#
# WHY AN INSTALLER AND NOT "just drop a file in .git/hooks"
# ---------------------------------------------------------
# On this machine `core.hooksPath` is set GLOBALLY to
# /Users/alex/.config/git/hooks. core.hooksPath REPLACES .git/hooks wholesale,
# so a hook dropped into <repo>/.git/hooks is, by default, DEAD — it is never
# invoked and nobody is told. It survives here only because that directory's
# dispatcher (git-identity-guard-dispatch, installed by femcboost's
# scripts/hooks/install-git-identity-guard.sh) explicitly chains to
# "$(git rev-parse --git-common-dir)/hooks/<name>". This installer therefore
# checks the chain rather than assuming it, and REFUSES rather than installing
# a hook that would silently never run.
#
# .git/hooks is untracked and machine-local, which is why the hook's source
# lives in the engine under version control and is copied into place here.

set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_HOOK="$SELF_DIR/hooks/ref-transaction-forensics.sh"
HOOK_NAME="reference-transaction"
MARKER="ref-transaction-forensics.sh"

MODE="install"
case "${1:-}" in
    --check)     MODE="check";     shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --help|-h)   sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac

REPO="${1:-$PWD}"

die() { printf 'install-ref-forensics: %s\n' "$*" >&2; exit 2; }

[ -f "$SOURCE_HOOK" ] || die "hook source missing at $SOURCE_HOOK"

COMMON="$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null)" \
    || die "not a git repository: $REPO"
case "$COMMON" in
    /*) ;;
    *)  COMMON="$(cd "$REPO" && cd "$COMMON" && pwd)" ;;
esac
TARGET="$COMMON/hooks/$HOOK_NAME"

# --- The operator-fence launcher owns the hook when it is there --------------
# `operator-fences.sh install` (spec r3 e8: "one installer owns the chain")
# writes a launcher as the repository's reference-transaction hook and runs the
# hooks in reference-transaction.d/ as its chain, refused transactions included.
# When the launcher is present, the recorder goes into its slot in that chain
# and NEVER over the launcher: copying over it would silently remove the fence.
LAUNCHER_MARKER="richos-operator-fence-launcher"
if [ -f "$TARGET" ] && grep -q "$LAUNCHER_MARKER" "$TARGET" 2>/dev/null; then
    TARGET="$COMMON/hooks/reference-transaction.d/20-ref-transaction-forensics.sh"
fi

# --- Will a repo-local hook actually be invoked here? ------------------------
HOOKS_PATH="$(git -C "$REPO" config --get core.hooksPath 2>/dev/null || true)"
chain_ok() {
    [ -z "$HOOKS_PATH" ] && return 0        # no override: .git/hooks is live
    local dispatch="$HOOKS_PATH/$HOOK_NAME"
    [ -e "$dispatch" ] || return 1          # override set, no such hook: dead
    # The dispatcher must chain to the repo's own hook of the same name.
    grep -q 'git-common-dir' "$(readlink -f "$dispatch" 2>/dev/null || printf '%s' "$dispatch")" 2>/dev/null
}

case "$MODE" in
    check)
        if [ -f "$TARGET" ] && grep -q "$MARKER" "$TARGET" 2>/dev/null; then
            printf 'INSTALLED  %s\n' "$TARGET"
            if chain_ok; then
                printf 'REACHABLE  core.hooksPath=%s chains to the repo hook\n' \
                    "${HOOKS_PATH:-(unset)}"
                exit 0
            fi
            printf 'UNREACHABLE core.hooksPath=%s does NOT chain — the hook will never run\n' \
                "$HOOKS_PATH" >&2
            exit 1
        fi
        printf 'ABSENT     %s\n' "$TARGET" >&2
        exit 1
        ;;
    uninstall)
        if [ -f "$TARGET" ] && grep -q "$MARKER" "$TARGET" 2>/dev/null; then
            rm -f "$TARGET" && printf 'removed %s\n' "$TARGET"
        else
            printf 'nothing of ours at %s\n' "$TARGET"
        fi
        exit 0
        ;;
esac

# --- install -----------------------------------------------------------------
if ! chain_ok; then
    die "core.hooksPath=$HOOKS_PATH overrides .git/hooks and does not chain to
  the repository's own '$HOOK_NAME'. Installing to $TARGET would produce a hook
  that never runs, which is worse than no hook. Install a chaining dispatcher at
  $HOOKS_PATH/$HOOK_NAME first, or unset core.hooksPath."
fi

if [ -f "$TARGET" ] && ! grep -q "$MARKER" "$TARGET" 2>/dev/null; then
    die "$TARGET already exists and is not ours. Refusing to clobber it."
fi

mkdir -p "$(dirname "$TARGET")"
cp "$SOURCE_HOOK" "$TARGET"
chmod +x "$TARGET"

printf 'installed  %s\n' "$TARGET"
printf 'source     %s\n' "$SOURCE_HOOK"
printf 'log        %s\n' "${RICHOS_REF_FORENSICS_DIR:-$HOME/.claude/state/ref-forensics}/ref-transactions.jsonl"
printf 'hooksPath  %s (chains to the repo hook)\n' "${HOOKS_PATH:-(unset)}"
