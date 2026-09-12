#!/usr/bin/env bash
#
# per-case-unavailable.sh — item 3, asked of the file that INHERITED the five
# green assertions the per-case mechanism was built to protect.
#
# cases_of() reads `^CASES = [...]`. certification-sage-runner-round-2026-09-12
# .probe.py declares its ten cases as a RUNNERS list, so the runner reads NONE of
# them, and the check that a retirement names a case the probe HAS then refuses an
# honest per-case retirement outright -- turning a GREEN probe UNRUNNABLE, which
# blocks. Fails closed and names the reason, which is the right direction; but
# per case is not available for that file.
#
#   usage: per-case-unavailable.sh <richos-worktree-root>
#
# It writes ONE line into the working-tree TSV and reverts it. Nothing is
# committed and nothing outside the given worktree is touched.
set -uo pipefail
W="${1:?usage: per-case-unavailable.sh <richos-worktree-root>}"
PROBE=certification-sage-runner-round-2026-09-12.probe.py
TSV="$W/docs/verification/workspace-probe-retirements.tsv"

cd "$W"
echo "=== what the runner reads as this probe's cases:"
python3 engine/scripts/workspace-probes.py --list 2>&1 | grep -A1 "$PROBE" | tail -1

echo
echo "=== the probe DOES take case arguments — its own interface:"
grep -n 'wanted = argv or' "docs/verification/$PROBE"

echo
echo "=== an honest per-case retirement of R4, signed by its own author:"
printf '%s\tR4\tsage\tSuppose I ruled R4 obsolete and R1-R3 and R5-R10 still live.\n' \
    "$PROBE" >> "$TSV"
python3 engine/scripts/workspace-probes.py --only certification-sage-runner-round > /tmp/pcu.$$ 2>&1
echo "runner exit $?"
git checkout -- "docs/verification/workspace-probe-retirements.tsv"
grep -E '^(UNRUNNABLE|GREEN|RED)' /tmp/pcu.$$ | grep runner-round
sed -n '/^UNRUNNABLE .*runner-round/,+1p' /tmp/pcu.$$ | tail -1
rm -f /tmp/pcu.$$
echo
echo "=== the TSV is back to its committed state:"
git status --porcelain docs/verification/workspace-probe-retirements.tsv
echo "(nothing above means clean)"
