#!/bin/bash
# Enumerate the real recordings that exist, WITHOUT printing what they are called.
#
# The CEO ruled on 2026-09-10 that no further recordings will ever be made, so the material on disk
# is permanent and a settings decision has to be made on it or not at all. That makes an inventory
# part of the record — and the files are private interviews whose names are people's names, in a
# tree that is gitignored precisely for that reason. So this prints an index, a kind and a duration,
# and never a basename. Run it to refresh the corpus table in README.md.
#
# The recordings themselves live in richos-hq/docs/reference/local/private-podcast-recordings/ and
# are not in this repository, will not be, and cannot be reconstructed from anything here.
set -uo pipefail
ROOT=/Users/alex/ab/richos-hq/docs/reference/local/private-podcast-recordings
for d in "$ROOT"/*/; do
  base=$(basename "$d")
  idx="${base%% *}"
  echo "recording $idx:"
  find "$d" -type f -name "*.mp3" -print0 | while IFS= read -r -d '' f; do
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null || echo "?")
    kind=raw
    case "$(basename "$f")" in *[Pp]odcast*) kind=edited-episode ;; esac
    printf '   %-16s %9.1f s\n' "$kind" "$dur"
  done
done
