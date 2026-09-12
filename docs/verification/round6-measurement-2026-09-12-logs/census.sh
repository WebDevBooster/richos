#!/usr/bin/env bash
# sha256 census of the operator's live workspace state. Read-only.
set -u
for p in "$HOME/.claude/state/workspaces" "$HOME/.claude/state/workspace-retirement"; do
  if [ -d "$p" ]; then
    n=$(find "$p" -type f | wc -l | tr -d ' ')
    h=$(find "$p" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
    echo "$h  $p (tree, $n files)"
  else
    echo "ABSENT  $p"
  fi
done
f="$HOME/.claude/state/worktree-ledger.jsonl"
if [ -f "$f" ]; then
  h=$(shasum -a 256 "$f" | cut -d' ' -f1)
  n=$(wc -l < "$f" | tr -d ' ')
  echo "$h  $f ($n lines)"
else
  echo "ABSENT  $f"
fi
echo "taken: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
