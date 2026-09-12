#!/usr/bin/env bash
# wave1.sh — the quick suites, serially, then the round-7-on-round-6-code run.
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad/m3
for w in unit e2e removal-guard completeness probes-runner; do
  echo "== $w"; bash "$S/run-suite.sh" m3 "$w"
done
echo "== fourteen no mutants"; bash "$S/run-fourteen.sh" m3-no-mutants
echo "== round-7 checks on round-6 code"; bash "$S/run-new-checks-on-base-code.sh"
echo "== removal-guard mutants"; bash "$S/run-suite.sh" m3 removal-guard-mut
echo "WAVE1 DONE $(date -u +%FT%TZ)"
