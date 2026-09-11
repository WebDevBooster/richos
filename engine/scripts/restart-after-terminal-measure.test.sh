#!/usr/bin/env bash
#
# restart-after-terminal-measure.test.sh — the measurement that decides whether
# a terminal agent runs again, and whether the platform re-locks before a
# restarted run, proven on a sandbox whose answer is known in advance.
#
# WHY A MEASUREMENT NEEDS A SUITE (Frank R7, round two, 2026-09-10): the join
# this script performs was done three times by hand on the same day and gave
# three different counts. A committed join that nothing runs can drift the same
# way the by-hand joins did — a changed row shape, a changed directory name —
# and keep printing a number. Every case here builds the record from scratch
# (transaction store, team event log, ownership ledger, a real git worktree
# with a real lock file), so the expected numerator, denominator and lock
# deltas are known before the script runs.
#
# Run directly: scripts/restart-after-terminal-measure.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEASURE="$SCRIPT_DIR/restart-after-terminal-measure.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t restart-measure-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$MEASURE" ] || { echo "FATAL: missing $MEASURE" >&2; exit 1; }

export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
export RICHOS_TEAMS_DIR="$SANDBOX/teams"
export RICHOS_WORKTREE_LEDGER="$SANDBOX/ledger.jsonl"
SID="11111111-0000-4000-8000-000000000001"
A_RESTARTED="aaaaaa000001"     # terminal, then started again (events AND start fact)
A_QUIET="bbbbbb000002"         # terminal, never started again
A_UNLOCKED="cccccc000003"      # reaper witnessed its tree unlocked, then it restarted; admin dir gone
REPO="$SANDBOX/entity"
mkdir -p "$REPO/.claude/worktrees" "$SANDBOX/tx/$SID/starts" "$SANDBOX/teams/session-${SID:0:8}"
git -C "$REPO" init -q -b main
printf 'seed\n' >"$REPO/seed.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m seed
git -C "$REPO" worktree add -q -b "worktree-agent-$A_RESTARTED" "$REPO/.claude/worktrees/agent-$A_RESTARTED"
git -C "$REPO" worktree lock --reason "claude agent agent-$A_RESTARTED (pid 1 start fixture)" "$REPO/.claude/worktrees/agent-$A_RESTARTED"
LOCK="$REPO/.git/worktrees/agent-$A_RESTARTED/locked"

# the timeline, in epoch seconds: T0 initial start, T1 terminal, T2 restart
T0=1800000000; T1=$((T0 + 600)); T2=$((T1 + 300))
iso() { python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(float(sys.argv[1]), datetime.timezone.utc).isoformat())' "$1"; }
tx_record() { # <agent-id> <terminal-epoch>
    python3 - "$SANDBOX/tx/$SID/$1.json" "$SID" "$1" "$(iso "$2")" "$REPO" <<'PY'
import json, sys
path, sid, aid, terminal_ts, repo = sys.argv[1:6]
json.dump({"record": "transaction", "session_id": sid, "agent_id": aid, "teammate": "dev-" + aid[:6],
           "sealed": True, "state": "terminal",
           "terminal": {"ingress": "SubagentStop", "ts": terminal_ts, "detail": ""},
           "members": [{"class": "native", "repo": repo,
                        "path": repo + "/.claude/worktrees/agent-" + aid,
                        "branch": "worktree-agent-" + aid, "state": "bound", "cleanup_policy": "integrated-daily"}]},
          open(path, "w"))
PY
}
event() { # <epoch> <event> <agent-id>
    printf '{"timestamp": "%s", "event": "%s", "agent_id": "%s", "session_id": "%s", "source_hook": "fixture"}\n' \
        "$(iso "$1")" "$2" "$3" "$SID" >>"$SANDBOX/teams/session-${SID:0:8}/worker-events.jsonl"
}
tx_record "$A_RESTARTED" "$T1"
tx_record "$A_QUIET" "$T1"
tx_record "$A_UNLOCKED" "$T1"
printf '{"record": "start", "session_id": "%s", "agent_id": "%s", "cwd": "", "ts": "%s"}\n' "$SID" "$A_RESTARTED" "$(iso "$T2")" >"$SANDBOX/tx/$SID/starts/$A_RESTARTED.json"
printf '{"record": "start", "session_id": "%s", "agent_id": "%s", "cwd": "", "ts": "%s"}\n' "$SID" "$A_QUIET" "$(iso "$T0")" >"$SANDBOX/tx/$SID/starts/$A_QUIET.json"
event "$T0" WorkerStarted "$A_RESTARTED"
event "$T0" WorkerStarted "$A_QUIET"
event "$T0" WorkerStarted "$A_UNLOCKED"
event "$((T0 + 30))" WorkerRunEnded "$A_RESTARTED"
event "$T2" WorkerStarted "$A_RESTARTED"
event "$((T2 + 40))" WorkerRunEnded "$A_RESTARTED"
event "$((T2 + 100))" WorkerStarted "$A_UNLOCKED"
printf '{"event": "terminated", "agent_id": "%s", "ts": "%s", "reason": "native isolation worktree registered and unlocked", "witness": "reaper"}\n' \
    "$A_UNLOCKED" "$(iso "$((T2 + 50))")" >>"$RICHOS_WORKTREE_LEDGER"
# the lock file's mtime PRECEDES the initial start by 50 ms, and therefore
# precedes the restart by minutes: the shape the live record shows
python3 -c 'import os,sys; t=float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$LOCK" "$((T0 - 1)).95"

echo "=== restart-after-terminal-measure tests ==="

# 1. the join: numerator, denominator, and the row
OUT="$(python3 "$MEASURE" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'DENOMINATOR: those that own at least one workspace : 3' \
   && printf '%s' "$OUT" | grep -q 'NUMERATOR  : those with a start strictly after their terminal record : 2' \
   && printf '%s' "$OUT" | grep -q "$A_RESTARTED" && printf '%s' "$OUT" | grep -q "$A_UNLOCKED" \
   && ! printf '%s' "$OUT" | grep -q "^  dev-bbbbbb"; then
    ok "M1  the join counts 2 restarted of 3 workspace-owning terminal transactions, names both, and never the quiet one"
else
    bad "M1  rc=$RC: $(printf '%s' "$OUT" | head -12)"
fi

# 2. the two sources are reported separately: events vs the start fact
if printf '%s' "$OUT" | grep -E "dev-aaaaaa +$A_RESTARTED" | grep -qE ' 1 +yes '; then
    ok "M2  the restarted agent shows 1 WorkerStarted after terminal AND a later start fact (two sources, both reported)"
else
    bad "M2  row: $(printf '%s' "$OUT" | grep -E "$A_RESTARTED")"
fi

# 3. --json carries the same numbers
J="$(python3 "$MEASURE" --json 2>&1)"
if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["denominator"]==3 and d["restarted_after_terminal"]==2 and d["rate"]==66.667, d' <<<"$J"; then
    ok "M3  --json: denominator 3, numerator 2, rate 66.667"
else
    bad "M3  json: $(printf '%s' "$J" | head -5)"
fi

# 4. --census: the vocabulary, with registration ids counted apart from payload ids
C="$(python3 "$MEASURE" --census 2>&1)"
if printf '%s' "$C" | grep -qE 'WorkerStarted +rows=5 +distinct payload ids=3 +of which registration ids=3' \
   && printf '%s' "$C" | grep -qE 'WorkerRunEnded +rows=2 +distinct payload ids=1 +of which registration ids=1'; then
    ok "M4  --census counts rows, distinct payload ids and registration ids separately"
else
    bad "M4  census: $(printf '%s' "$C" | head -6)"
fi

# 5. --locks, the shape of the live record: the lock precedes the INITIAL start
#    and is UNCHANGED across the restart -- no re-lock observed
L="$(python3 "$MEASURE" --locks 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] \
   && printf '%s' "$L" | grep -q '(a) initial starts with a lock file on disk : 1; lock PRECEDES the start in 1 of them' \
   && printf '%s' "$L" | grep -q '(b) restarts with a lock file on disk       : 1; lock mtime moved AFTER the restart (a re-lock OBSERVED) in 0 of them' \
   && printf '%s' "$L" | grep -E "$A_RESTARTED +initial" | grep -qE -- '-50\.0 ms' \
   && printf '%s' "$L" | grep -q 'UNMEASURED'; then
    ok "M5  --locks: the lock precedes the initial start (-50.0 ms) and a restart with the lock held throughout is NOT counted as a re-lock; the sentence says UNMEASURED"
else
    bad "M5  rc=$RC: $(printf '%s' "$L" | grep -E '\(a\)|\(b\)|initial|restart' | head -6)"
fi

# 6. --locks (c): a restart into a tree the reaper witnessed unlocked, whose
#    admin directory is gone, is reported as unobservable -- never as a re-lock
if printf '%s' "$L" | grep -q '(c) restarts into a tree the reaper witnessed UNLOCKED : 1; admin directory still on disk for 0 of them' \
   && printf '%s' "$L" | grep -E "$A_UNLOCKED" | grep -q 'GONE -- re-lock unobservable'; then
    ok "M6  --locks (c): the witnessed-unlocked restart is counted, its admin directory reported GONE, and no re-lock is claimed for it"
else
    bad "M6  (c): $(printf '%s' "$L" | grep -E '\(c\)|cccccc' | head -4)"
fi

# 7. THE POSITIVE PROBE: a lock whose mtime moves AFTER the restart IS counted
#    as an observed re-lock -- so M5's zero is a measurement, not a blind spot
python3 -c 'import os,sys; t=float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$LOCK" "$((T2)).04"
L2="$(python3 "$MEASURE" --locks 2>&1)"
if printf '%s' "$L2" | grep -q '(b) restarts with a lock file on disk       : 1; lock mtime moved AFTER the restart (a re-lock OBSERVED) in 1 of them' \
   && printf '%s' "$L2" | grep -E "$A_RESTARTED +restart" | grep -qE -- '\+40\.0 ms'; then
    ok "M7  the positive probe: a lock re-taken 40 ms after the restart IS reported as an observed re-lock (b = 1 of 1)"
else
    bad "M7  (b) after utime: $(printf '%s' "$L2" | grep -E '\(b\)|restart' | head -4)"
fi

# 8. --locks --json parses and agrees
LJ="$(python3 "$MEASURE" --locks --json 2>&1)"
if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["initial_starts_with_lock_on_disk"]==1 and d["restarts_lock_retaken_after_restart"]==1 and d["restarts_into_witnessed_unlocked_tree"]==1 and d["restarts_into_witnessed_unlocked_tree_with_admin_dir"]==0, d' <<<"$LJ"; then
    ok "M8  --locks --json carries the same counts"
else
    bad "M8  locks json: $(printf '%s' "$LJ" | head -8)"
fi

# 9. an empty record is an absence, said in those words, exit 0
RICHOS_WORKTREE_TX_DIR="$SANDBOX/nowhere" OUT="$(python3 "$MEASURE" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'THIS IS NOT A PROOF THAT ONE CANNOT HAPPEN'; then
    ok "M9  an empty corpus reports no restart and says absence is not evidence, exit 0"
else
    bad "M9  rc=$RC: $(printf '%s' "$OUT" | tail -3)"
fi

# ===========================================================================
# 10-11. THE SUBSTRATE IS PER-SESSION AND EPHEMERAL (Sage D3 / Frank F1,
# round three). A second session with NO team directory: its rows are in the
# FALLBACK file beside the teams directory, and one of its agents was
# witnessed unlocked and restarted with no event row anywhere -- the shape
# the four live cases took once the platform deleted their session's log.
# ===========================================================================
# M9 above is `VAR=x OUT="$(...)"` with no command word, which assigns BOTH in
# this shell; the empty store it named would otherwise be the corpus here.
export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
SID2="22222222-0000-4000-8000-000000000002"
A_FALLBACK="eeeeee000005"   # terminal, restarted; the restart is recorded ONLY in the fallback file
A_LOGGONE="dddddd000004"    # witnessed unlocked, restarted per its start fact; NO event row anywhere
mkdir -p "$SANDBOX/tx/$SID2/starts"
tx_record2() { # <agent-id> <terminal-epoch>
    python3 - "$SANDBOX/tx/$SID2/$1.json" "$SID2" "$1" "$(iso "$2")" "$REPO" <<'PY'
import json, sys
path, sid, aid, terminal_ts, repo = sys.argv[1:6]
json.dump({"record": "transaction", "session_id": sid, "agent_id": aid, "teammate": "dev-" + aid[:6],
           "sealed": True, "state": "terminal",
           "terminal": {"ingress": "SubagentStop", "ts": terminal_ts, "detail": ""},
           "members": [{"class": "native", "repo": repo,
                        "path": repo + "/.claude/worktrees/agent-" + aid,
                        "branch": "worktree-agent-" + aid, "state": "bound", "cleanup_policy": "integrated-daily"}]},
          open(path, "w"))
PY
}
tx_record2 "$A_FALLBACK" "$T1"
tx_record2 "$A_LOGGONE" "$T1"
# the fallback file: the sibling of the teams directory, rows keyed by the FULL session id
printf '{"timestamp": "%s", "event": "WorkerStarted", "agent_id": "%s", "session_id": "%s", "source_hook": "fixture"}\n' \
    "$(iso "$T2")" "$A_FALLBACK" "$SID2" >>"$SANDBOX/worker-events.jsonl"
# the log-gone agent: a ledger witness, a later start fact, no event row
printf '{"event": "terminated", "agent_id": "%s", "ts": "%s", "reason": "native isolation worktree registered and unlocked", "witness": "reaper"}\n' \
    "$A_LOGGONE" "$(iso "$((T2 + 50))")" >>"$RICHOS_WORKTREE_LEDGER"
printf '{"record": "start", "session_id": "%s", "agent_id": "%s", "cwd": "", "ts": "%s"}\n' "$SID2" "$A_LOGGONE" "$(iso "$((T2 + 100))")" >"$SANDBOX/tx/$SID2/starts/$A_LOGGONE.json"

OUT="$(python3 "$MEASURE" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'DENOMINATOR: those that own at least one workspace : 5' \
   && printf '%s' "$OUT" | grep -q 'NUMERATOR  : those with a start strictly after their terminal record : 4' \
   && printf '%s' "$OUT" | grep -E "dev-eeeeee +$A_FALLBACK" | grep -qE ' 1 +no ' \
   && printf '%s' "$OUT" | grep -E "dev-dddddd +$A_LOGGONE" | grep -qE ' 0 +yes ' \
   && printf '%s' "$OUT" | grep -q 'plus the fallback file if present) : 2'; then
    ok "M10 the FALLBACK file is read: a session with no team directory contributes its WorkerStarted (events=1, fact=no), a session whose log is gone contributes only its start fact (events=0, fact=yes), 4 of 5, 2 logs scanned"
else
    bad "M10 rc=$RC: $(printf '%s' "$OUT" | grep -E 'DENOMINATOR|NUMERATOR|eeeeee|dddddd|scanned' | head -6)"
fi

L3="$(python3 "$MEASURE" --locks 2>&1)"
if printf '%s' "$L3" | grep -q '(c) restarts into a tree the reaper witnessed UNLOCKED : 2; admin directory still on disk for 0 of them; known only from the start fact (event log gone) for 1 of them' \
   && printf '%s' "$L3" | grep -E "$A_LOGGONE" | grep -q 'restart from start-fact -- session event log GONE' \
   && printf '%s' "$L3" | grep -E "$A_UNLOCKED" | grep -q 'restart from events' \
   && printf '%s' "$L3" | grep -q 'CORPUS LIFETIME'; then
    ok "M11 --locks (c): a witnessed-unlocked restart whose event log is gone is REPORTED from the ledger witness and the start fact, named as unobservable from the log, never dropped; and the corpus lifetime is stated"
else
    bad "M11 (c): $(printf '%s' "$L3" | grep -E '\(c\)|dddddd|cccccc|LIFETIME' | head -5)"
fi

# ===========================================================================
# 12. A NON-UTF-8 LINE IN THE FALLBACK FILE IS SKIPPED, NOT FATAL (Sage D-C,
# round four). The fallback is shared by every session; one bad byte must
# not stop the measure or change what it counts. Same corpus as M10, plus
# one line of bytes that is not UTF-8 -- the numbers are M10's numbers.
# ===========================================================================
printf '\xff\xfe not utf-8 at all \x80\n' >>"$SANDBOX/worker-events.jsonl"
OUT="$(python3 "$MEASURE" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'NUMERATOR  : those with a start strictly after their terminal record : 4' \
   && printf '%s' "$OUT" | grep -q 'plus the fallback file if present) : 2'; then
    ok "M12 a line that is not UTF-8 in the fallback file is skipped: exit 0, the same 4 restarts, the same 2 logs scanned"
else
    bad "M12 rc=$RC: $(printf '%s' "$OUT" | grep -E 'NUMERATOR|scanned|Error|Traceback' | head -4)"
fi
# ...and a retracted ledger witness is not a witness (round 15): the (c) line
# drops the agent whose `terminated` row a `retracted` row names.
printf '{"event": "retracted", "agent_id": "%s", "retracts_ts": "%s", "reason": "fixture", "source": "test"}\n' \
    "$A_LOGGONE" "$(iso "$((T2 + 50))")" >>"$RICHOS_WORKTREE_LEDGER"
L4="$(python3 "$MEASURE" --locks 2>&1)"
if printf '%s' "$L4" | grep -q '(c) restarts into a tree the reaper witnessed UNLOCKED : 1;' \
   && ! printf '%s' "$L4" | grep -E "$A_LOGGONE" | grep -q 'restart from start-fact'; then
    ok "M13 --locks (c): a witnessed-unlocked row that a 'retracted' row names is no longer counted as a witness (1 instead of M11's 2)"
else
    bad "M13 retraction in (c): $(printf '%s' "$L4" | grep -E '\(c\)|dddddd' | head -3)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== restart-after-terminal-measure tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== restart-after-terminal-measure tests: all $PASS passed ==="
exit 0
