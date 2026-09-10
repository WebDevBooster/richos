#!/usr/bin/env bash
#
# make-mutant-engine.sh — a throwaway engine copy with PREFER-THE-RESOLVABLE
# flipped back to PREFER-THE-PRESENT, which is the condition the three finish
# writers actually shipped (`if not agent_id`).
#
# Run run-live-proof.sh against the directory this prints and the same real
# SubagentStop writes an incomplete row again. That is the difference between
# "the code changed" and "the change is what produces the row".
#
# The shipped tree is never opened for writing: an EXIT trap that restores a
# mutated file is a promise conditional on exiting, and this machine's engine
# is a symlink to the live checkout.
#
#   make-mutant-engine.sh <source-engine-root> [dest]
set -uo pipefail
SRC="${1:?usage: make-mutant-engine.sh <source-engine-root> [dest]}"
DST="${2:-}"
[ -n "$DST" ] || DST="$(cd "$(mktemp -d -t mutant-engine.XXXXXX)" && pwd -P)/engine"
rm -rf "$DST"
mkdir -p "$DST"
cp -R "$SRC/scripts" "$DST/scripts"
python3 - "$DST/scripts/lib/worktree-ledger.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "    owner = agent_id_from_worktree(worktree)\n"
new = '    owner = agent_id_from_worktree(worktree) if not agent_id else ""\n'
n = s.count(old)
if n != 1:
    sys.stderr.write("MUTATION MALFORMED — matched %d sites, expected exactly 1\n" % n)
    sys.exit(3)
open(p, "w").write(s.replace(old, new))
PY
[ $? -eq 0 ] || exit 1
echo "MUTATED (prefer-the-resolvable -> prefer-the-present): $DST"
