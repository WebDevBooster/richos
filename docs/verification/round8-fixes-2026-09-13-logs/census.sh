#!/usr/bin/env bash
# census.sh <label> — sha256 census of the two live state dirs. Read-only.
set -euo pipefail
label="${1:?label}"
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad
for d in "$HOME/.claude/state/workspaces" "$HOME/.claude/state/workspace-retirement"; do
  name=$(basename "$d")
  echo "== $d ($label) $(date -u +%FT%TZ)"
  if [ -d "$d" ]; then
    out="$S/census-$name-$label.txt"
    ( cd "$d" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done ) > "$out"
    echo "files: $(wc -l < "$out" | tr -d ' ')"
    echo "census-sha256: $(shasum -a 256 < "$out" | cut -d' ' -f1)"
  else
    echo "ABSENT"
  fi
done
