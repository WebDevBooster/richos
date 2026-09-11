#!/usr/bin/env bash
# wtr-repeat.sh <n> [label-prefix] — run guard-worktree-removal.mutation.sh n times sequentially, each output kept.
set -uo pipefail
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/b7869424-972c-4693-80f8-5e034a119d86/scratchpad/r5
N="$1"; P="${2:-wtr-rep}"
for i in $(seq 1 "$N"); do
    bash "$SP/run-suite.sh" "$P$i" scripts/hooks/guard-worktree-removal.mutation.sh | head -1
done
grep "^$P" "$SP/RESULTS.tsv"
