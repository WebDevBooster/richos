#!/usr/bin/env bash
# Is the record canary blind to DELETION? Throwaway CLAUDE_CONFIG_DIR only.
set -uo pipefail
SB="$(mktemp -d -t rc-del.XXXXXX)"
trap 'rm -rf "$SB"' EXIT
CFG="$SB/cfg"; mkdir -p "$CFG/state" "$CFG/teams/session-aaaaaaaa" "$CFG/teams/session-bbbbbbbb"
printf 'x\n' > "$CFG/teams/session-aaaaaaaa/worker-events.jsonl"
export CLAUDE_CONFIG_DIR="$CFG"
. "$1/engine/scripts/lib/record-canary.sh"
L="$CFG/state/worktree-ledger.jsonl"
printf '{"event": "registered", "agent_id": "a1", "teammate": "t1", "source": "detect-nonnative-worktree.sh", "ts": "1"}\n{"event": "terminated", "agent_id": "a1", "witness": "reaper-observation", "ts": "2"}\n{"event": "prepared", "teammate": "t2", "source": "create-teammate-worktree.sh", "ts": "3"}\n' > "$L"
printf '{"event": "WorkerRunEnded", "agent_id": "f1", "session_id": "s-1", "timestamp": "t"}\n{"event": "WorkerRunEnded", "agent_id": "f2", "session_id": "s-2", "timestamp": "t"}\n' > "$CFG/worker-events.jsonl"
rc_baseline "$SB/b.txt"; echo "baseline healthy=$RC_HEALTHY lines=$(wc -l < "$SB/b.txt")"

echo "--- A. one ledger row DELETED (the terminated row):"
python3 - "$L" <<'PY'
import sys; p=sys.argv[1]; ls=[l for l in open(p) if '"terminated"' not in l]; open(p,"w").write("".join(ls))
PY
E="$(rc_escaped "$SB/b.txt")"; echo "escaped=[${E}]"; [ -z "$E" ] && echo "RESULT A: GREEN (deletion of a terminated row NOT reported)"

echo "--- B. ledger TRUNCATED to empty:"
: > "$L"
E="$(rc_escaped "$SB/b.txt")"; echo "escaped=[${E}]"; [ -z "$E" ] && echo "RESULT B: GREEN (ledger wiped, NOT reported)"

echo "--- C. fallback log truncated to empty:"
: > "$CFG/worker-events.jsonl"
E="$(rc_escaped "$SB/b.txt")"; echo "escaped=[${E}]"; [ -z "$E" ] && echo "RESULT C: GREEN (fallback wiped, NOT reported)"

echo "--- D. a team directory REMOVED (rm -rf session-bbbbbbbb):"
rm -rf "$CFG/teams/session-bbbbbbbb"
E="$(rc_escaped "$SB/b.txt")"; echo "escaped=[${E}]"; [ -z "$E" ] && echo "RESULT D: GREEN (team directory removed, NOT reported)"

echo "--- E. control: a row APPENDED after all that:"
printf '{"event": "terminated", "agent_id": "zz", "witness": "reaper-observation", "ts": "9"}\n' >> "$L"
E="$(rc_escaped "$SB/b.txt")"; echo "escaped=[${E}]"
