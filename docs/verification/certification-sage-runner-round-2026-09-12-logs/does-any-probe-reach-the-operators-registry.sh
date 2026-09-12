#!/bin/bash
# does-any-probe-reach-the-operators-registry.sh — Sage, 2026-09-12.
#
# `~/.claude/state/workspaces/integration.json` disappeared during my review
# session and I could not attribute it. This is the reproduction that clears the
# probe set, and it is built so that a probe which WOULD have unlinked the real
# file unlinks a decoy instead.
#
# The trick is the environment. `state_dir()` resolves in this order:
#
#     $RICHOS_WORKSPACES_DIR, else $CLAUDE_CONFIG_DIR/state/workspaces,
#     else ~/.claude/state/workspaces
#
# so UNSETTING the first two and pointing HOME at a decoy makes the decoy the
# thing any escaping probe reaches. If the decoy survives, nothing in the probe
# set touches an operator's registry.
#
# It writes only under $TMPDIR-ish scratch and reads the real repository.
set -u
T="$(mktemp -d "${TMPDIR:-/tmp}/decoy-registry-XXXXXX")"
trap 'rm -rf "$T"' EXIT
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

mkdir -p "$T/.claude/state/workspaces/agents" "$T/.claude/state/workspaces/done"
printf '{"works":{"decoy-001":{"id":"decoy-001","repo":"/decoy","branch":"main"}},"current":{"/decoy":"decoy-001"}}\n' \
    > "$T/.claude/state/workspaces/integration.json"
: > "$T/.claude/state/workspaces/events.jsonl"
printf '[user]\n\tname=p\n\temail=p@example.invalid\n[init]\n\tdefaultBranch=main\n' > "$T/.gitconfig"

echo "--- the decoy registry, before ---"
ls "$T/.claude/state/workspaces/"

export HOME="$T"
export GIT_CONFIG_GLOBAL="$T/.gitconfig"
unset RICHOS_WORKSPACES_DIR 2>/dev/null || true
unset CLAUDE_CONFIG_DIR 2>/dev/null || true

cd "$SRC"
python3 engine/scripts/workspace-probes.py > "$T/run.txt" 2>&1
echo "runner exit=$?  (1 is expected: one reviewer's probe is red and only its author may retire it)"
grep -E "^probes discovered|^GREEN|^RED|^RETIRED" "$T/run.txt"

echo
echo "--- the decoy registry, after ---"
ls "$T/.claude/state/workspaces/"
if [ -f "$T/.claude/state/workspaces/integration.json" ]; then
    echo "integration.json  PRESENT"
else
    echo "integration.json  GONE — a probe reached the operator's registry"
fi
echo "events.jsonl      $(wc -c < "$T/.claude/state/workspaces/events.jsonl" | tr -d ' ') bytes (0 means no library call ran against it)"
