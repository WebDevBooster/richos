#!/bin/bash
R=/Users/alex/ab/richos-wt/frank-opus-lc2
for d in 2026-08-06 2026-08-16 2026-08-24 2026-08-27 2026-08-28 2026-08-29 2026-08-30 2026-09-01 2026-09-02 2026-09-04 2026-09-06 2026-09-09; do
  sha=$(git -C "$R" rev-list -1 --before="$d 23:59" main)
  if [ -z "$sha" ]; then continue; fi
  names=$(git -C "$R" ls-tree -r --name-only "$sha")
  n=$(printf '%s\n' "$names" | grep -c '\.test\.sh$' || true)
  m=$(printf '%s\n' "$names" | grep -c '\.mutation\.sh$' || true)
  echo "$d  suites=$n  mutation_harnesses=$m  ${sha:0:8}"
done
