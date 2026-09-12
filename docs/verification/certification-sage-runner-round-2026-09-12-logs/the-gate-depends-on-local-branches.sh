#!/bin/bash
# the-gate-depends-on-local-branches.sh — Sage, 2026-09-12.
#
# Item 2 of the brief: the runner reads other LOCAL branches, not just the tree.
# This measures what that makes the gate's verdict a function of. Throwaway
# repository under $TMPDIR; nothing outside it is read or written.
#
#   H  a stale local branch from an old round, named neither cc/ nor dev/,
#      carries a red probe: it is read, and it BLOCKS. A codex/ branch carrying
#      the same probe is correctly never read (spec point 2).
#   I  the stale branch is deleted — which is what spec point 4 says happens to
#      an agent's branch when its work lands — and the same commit, same tree,
#      same library now runs green with no trace that anything was dropped.
set -u
T="$(mktemp -d "${TMPDIR:-/tmp}/branch-probe-XXXXXX")"
trap 'rm -rf "$T"' EXIT
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

mkdir -p "$T/engine/scripts/lib" "$T/docs/verification" "$T/home"
cp "$SRC/engine/scripts/workspace-probes.py" "$T/engine/scripts/"
cp "$SRC/engine/scripts/lib/"*.py "$T/engine/scripts/lib/"
export HOME="$T/home"
printf '[user]\n\tname=p\n\temail=p@example.invalid\n[init]\n\tdefaultBranch=main\n' > "$HOME/.gitconfig"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git -C "$T" init -q -b main
D="$T/docs/verification"
R="$T/engine/scripts/workspace-probes.py"

cat > "$D/certification-frank-tree-probe.py" <<'PY'
"""A green probe of engine/scripts/lib/workspaces.py, in the tree."""
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("workspaces", os.path.abspath(sys.argv[1]))
ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
assert hasattr(ws, "land")
def main(a): return 0
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
PY
git -C "$T" add -A >/dev/null; git -C "$T" commit -qm base

red_on_branch() {   # $1 = branch, $2 = probe file name
    git -C "$T" checkout -q -b "$1"
    cat > "$D/$2" <<'PY'
"""A probe of engine/scripts/lib/workspaces.py from an older round."""
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("workspaces", os.path.abspath(sys.argv[1]))
ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
assert hasattr(ws, "an_entry_point_deleted_two_rounds_ago")
def main(a): return 0
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
PY
    git -C "$T" add -A >/dev/null; git -C "$T" commit -qm "$1"
    git -C "$T" checkout -q main
    rm -f "$D/$2"
}

red_on_branch "stale/old-round" "certification-sage-stale-probe.py"
red_on_branch "codex/thing"     "certification-sage-codex-probe.py"

echo "=== H. a stale local branch and a codex/ branch both carry a red probe"
python3 "$R" 2>&1 | grep -E "^probes discovered|^RED|^GREEN|every discovered"
python3 "$R" >/dev/null 2>&1; echo "    exit=$?"

echo
echo "=== I. the stale branch is deleted, exactly as spec point 4 says a landed"
echo "       agent's branch is. Same commit, same tree, same library."
git -C "$T" branch -qD stale/old-round
python3 "$R" 2>&1 | grep -E "^probes discovered|^RED|^GREEN|every discovered"
python3 "$R" >/dev/null 2>&1; echo "    exit=$?"
