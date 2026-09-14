#!/usr/bin/env bash
set -uo pipefail
WT=/Users/alex/ab/richos-wt/zach-opus-landgate1
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/b7d89f44-e47a-4f64-a551-b41bd8468250/scratchpad
cd "$WT"

echo "=== timing 3 runs (tsv) ==="
for i in 1 2 3; do
  /usr/bin/time -p python3 engine/scripts/check-census.py \
      --engine-root engine --entity-root /Users/alex/ab/femcboost --format tsv \
      > "$SP/census.tsv" 2> "$SP/census.time.$i"
  echo "run $i exit=$?"
  grep -E '^(real|user|sys)' "$SP/census.time.$i" || true
done

echo
echo "=== tsv header ==="
head -1 "$SP/census.tsv"
echo
echo "=== row count (excl header) ==="
tail -n +2 "$SP/census.tsv" | wc -l
