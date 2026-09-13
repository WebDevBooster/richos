#!/usr/bin/env bash
# one-mutant.sh <label> <rel-file> <old-python-literal-file> <new-python-literal-file>
# Copies the branch's engine to scratch, applies ONE textual mutation, runs the fourteen
# without its mutant pass, and prints the FAIL lines. A by-hand reproduction of one row
# of the engineer's 83/83 table.
set -uo pipefail
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/16a15be1-c2c1-4d79-82eb-f09c3f533143/scratchpad/frank-c9
W=/Users/alex/ab/richos-wt/frank-fable-c9
LABEL="$1"; REL="$2"; OLDF="$3"; NEWF="$4"
D="$S/mut-$LABEL"; rm -rf "$D"; mkdir -p "$D/outer-home/.claude" "$D/outer-ws" "$D/outer-sessions"
cp -R "$W/engine" "$D/engine"
python3 - "$D/engine/$REL" "$OLDF" "$NEWF" <<'PY'
import sys
path, oldf, newf = sys.argv[1:4]
src = open(path).read(); old = open(oldf).read(); new = open(newf).read()
n = src.count(old)
print("occurrences of the old text:", n)
if n != 1:
    sys.exit(3)
open(path, "w").write(src.replace(old, new))
PY
rc=$?; echo "applied: exit $rc"
[ $rc -eq 0 ] || exit 3
export CLAUDE_CONFIG_DIR="$D/outer-home/.claude" RICHOS_WORKSPACES_DIR="$D/outer-ws" RICHOS_SESSIONS_DIR="$D/outer-sessions"
{
  echo "label: mutant $LABEL on $REL  started: $(date -u +%FT%TZ)"
  (cd "$D" && RICHOS_FOURTEEN_SKIP_MUTANTS=1 bash engine/scripts/workspace-spec-fourteen.test.sh); rc=$?
  echo "exit: $rc"
  echo "finished: $(date -u +%FT%TZ)"
} > "$D/fourteen.txt" 2>&1
grep -E '^      FAIL|^  FAIL|^FOURTEEN|^exit' "$D/fourteen.txt"
