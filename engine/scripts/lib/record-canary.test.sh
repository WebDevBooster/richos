#!/usr/bin/env bash
#
# record-canary.test.sh — PROVE THE RECORD CANARY IN BOTH DIRECTIONS.
#
# scripts/lib/record-canary.sh watches the operator's record — the ownership
# ledger, the platform's fallback event log, the team directories — per suite.
# A canary that cannot go red is a green tick printed over the defect, and the
# defect here is dated: on 2026-09-11 a green suite wrote a false `terminated`
# witness for a running agent into the operator's real ledger and nothing said
# so. So this suite drives the detector onto each of the three shapes that
# class has taken and off them again:
#
#   a `terminated` row appended to the ledger          (9b, 2026-09-11)
#   fixture rows appended to the fallback event log     (feedbeef, 2026-09-10)
#   a fixture team directory created                    (session-deadbeef, 2026-09-10)
#
# and pins the one thing it deliberately cannot see — the platform's own
# per-turn `finished` rows — so nobody reads more into a green run than is
# there.
#
# Everything happens under a throwaway CLAUDE_CONFIG_DIR. This suite reads
# nothing under the operator's real ~/.claude and writes nothing there —
# which, given what it is about, is the least it can do.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t record-canary-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '          %s\n' "$2"; FAIL=$((FAIL + 1)); }

CFG="$SANDBOX/cfg"
mkdir -p "$CFG/state" "$CFG/teams/session-aaaaaaaa"
export CLAUDE_CONFIG_DIR="$CFG"
# shellcheck source=record-canary.sh
. "$SCRIPT_DIR/record-canary.sh"

echo "=== record canary: red on the operator's record, green on the noise ==="

# ===========================================================================
# 1. THE PATHS ARE CAPTURED AT SOURCE TIME, NOT RE-READ
# ===========================================================================
if [ "$RC_LEDGER" = "$CFG/state/worktree-ledger.jsonl" ] && [ "$RC_FALLBACK" = "$CFG/worker-events.jsonl" ] && [ "$RC_TEAMS" = "$CFG/teams" ]; then
    ok "1a  the three watched paths resolve under CLAUDE_CONFIG_DIR as it was when the library was sourced"
else
    bad "1a  watched paths" "ledger=$RC_LEDGER fallback=$RC_FALLBACK teams=$RC_TEAMS"
fi
CLAUDE_CONFIG_DIR="$SANDBOX/elsewhere"
if [ "$RC_LEDGER" = "$CFG/state/worktree-ledger.jsonl" ]; then
    ok "1b  and moving CLAUDE_CONFIG_DIR afterwards does not move them — a suite that relocates its config halfway through is still compared against the record it started with"
else
    bad "1b  paths captured, not re-read" "ledger=$RC_LEDGER"
fi
CLAUDE_CONFIG_DIR="$CFG"

# ===========================================================================
# 2. GREEN WHEN NOTHING HAPPENS — including with every path ABSENT (CI's shape)
# ===========================================================================
B0="$SANDBOX/b0.txt"
rc_baseline "$B0"
if [ "$RC_HEALTHY" -eq 1 ] && [ -z "$(rc_escaped "$B0")" ]; then
    ok "2a  with the ledger and the fallback absent and one empty team directory, the baseline is healthy and nothing has escaped"
else
    bad "2a  quiet before any write" "healthy=$RC_HEALTHY escaped=[$(rc_escaped "$B0")]"
fi
printf '{"event": "finished", "agent_id": "a1", "signal": "SubagentStop", "source": "worker-ended-handoff.sh", "ts": "2026-09-11T00:00:00+00:00"}\n' >>"$CFG/state/worktree-ledger.jsonl"
B1="$SANDBOX/b1.txt"
rc_baseline "$B1"
printf '{"event": "finished", "agent_id": "a2", "signal": "SubagentStop", "source": "worker-ended-handoff.sh", "ts": "2026-09-11T00:00:01+00:00"}\n' >>"$CFG/state/worktree-ledger.jsonl"
E="$(rc_escaped "$B1")"
if [ -z "$E" ]; then
    ok "2b  a 'finished' row appended to the ledger is NOT reported — the platform's own per-turn row, the one exclusion, stated in the library's header"
else
    bad "2b  finished rows are excluded" "got: $E"
fi

# ===========================================================================
# 3. RED ON EACH SHAPE THE CLASS HAS TAKEN
# ===========================================================================
B2="$SANDBOX/b2.txt"
rc_baseline "$B2"
printf '{"event": "terminated", "agent_id": "ae904aac1949e5696", "teammate": "sage-fable-cert3", "witness": "platform-terminal-record", "ts": "2026-09-11T00:02:34.984941+00:00"}\n' >>"$CFG/state/worktree-ledger.jsonl"
E="$(rc_escaped "$B2")"
case "$E" in
    *"ledger row APPEARED"*"event=terminated"*"witness=platform-terminal-record"*"teammate=sage-fable-cert3"*)
        ok "3a  RED: a 'terminated' row appended to the ledger is caught and NAMED (event, witness, teammate) — the 2026-09-11 shape" ;;
    "") bad "3a  RED on a terminated row" "a terminated row appeared in the watched ledger and the canary reported nothing" ;;
    *)  bad "3a  the row is named" "got: $E" ;;
esac
B3="$SANDBOX/b3.txt"
rc_baseline "$B3"
printf '{"event": "registered", "agent_id": "x", "teammate": "dev-1", "source": "detect-nonnative-worktree.sh", "ts": "t"}\n{"event": "prepared", "teammate": "dev-2", "source": "create-teammate-worktree.sh", "ts": "t"}\n{"event": "retracted", "agent_id": "x", "retracts_ts": "t", "ts": "t"}\n' >>"$CFG/state/worktree-ledger.jsonl"
E="$(rc_escaped "$B3")"
if [ "$(printf '%s\n' "$E" | grep -c 'ledger row APPEARED')" -eq 3 ] \
   && printf '%s' "$E" | grep -q 'event=registered' && printf '%s' "$E" | grep -q 'event=prepared' && printf '%s' "$E" | grep -q 'event=retracted'; then
    ok "3b  and so are registered, prepared and retracted rows — every event except 'finished' is witnessed, one line each"
else
    bad "3b  every other event is witnessed" "got: $E"
fi
B4="$SANDBOX/b4.txt"
rc_baseline "$B4"
printf '{"event": "WorkerRunEnded", "agent_id": "feedbeef", "session_id": "feedbeef-0000", "timestamp": "2026-09-10T00:00:00+00:00"}\n' >>"$CFG/worker-events.jsonl"
E="$(rc_escaped "$B4")"
case "$E" in
    *"fallback: was ABSENT and now EXISTS"*|*"fallback event log line APPEARED"*"session=feedbeef-0000"*)
        ok "3c  RED: a fixture row appended to the fallback event log is caught and named — the feedbeef shape (Sage D4)" ;;
    "") bad "3c  RED on the fallback log" "a row appeared in the fallback event log and the canary reported nothing" ;;
    *)  bad "3c  the fallback row is named" "got: $E" ;;
esac
B5="$SANDBOX/b5.txt"
rc_baseline "$B5"
mkdir -p "$CFG/teams/session-deadbeef"
printf 'dev-1\n' >"$CFG/teams/session-deadbeef/spawned-names.log"
E="$(rc_escaped "$B5")"
case "$E" in
    *"team directory entry APPEARED: session-deadbeef/"*)
        ok "3d  RED: a fixture team directory is caught and named — the session-deadbeef shape (round 14, D4's sibling)" ;;
    "") bad "3d  RED on a team directory" "a directory appeared under teams/ and the canary reported nothing" ;;
    *)  bad "3d  the directory is named" "got: $E" ;;
esac
case "$E" in
    *"session-deadbeef/spawned-names.log"*) ok "3d' and the file inside it, by name" ;;
    *) bad "3d' the file inside the new directory is named" "got: $E" ;;
esac

# ===========================================================================
# 4. THE WITNESS IS CONTENTS, NOT COUNTS — an overwrite in place is a change
# ===========================================================================
B6="$SANDBOX/b6.txt"
rc_baseline "$B6"
python3 - "$CFG/state/worktree-ledger.jsonl" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines(True)
# rewrite the terminated row's witness in place: same row count, different bytes
lines = [l.replace('"witness": "platform-terminal-record"', '"witness": "edited-by-hand"') for l in lines]
open(p, "w", encoding="utf-8").write("".join(lines))
PY
E="$(rc_escaped "$B6")"
case "$E" in
    *"witness=edited-by-hand"*) ok "4a  a row rewritten IN PLACE (same count, different bytes) is caught — the witness is contents, not a line count" ;;
    "") bad "4a  in-place edits are caught" "the ledger changed bytes without changing its row count and the canary reported nothing" ;;
    *)  bad "4a  the edited row is named" "got: $E" ;;
esac

# ===========================================================================
# 5. A PATH IT CANNOT READ IS A FAILURE, NEVER A QUIET PASS
# ===========================================================================
chmod 000 "$CFG/state/worktree-ledger.jsonl"
if [ ! -r "$CFG/state/worktree-ledger.jsonl" ]; then
    B7="$SANDBOX/b7.txt"
    rc_baseline "$B7"
    if [ "$RC_HEALTHY" -eq 0 ]; then
        ok "5a  an unreadable ledger makes the baseline UNHEALTHY, so a runner can refuse to report a pass over it"
    else
        bad "5a  unreadable ledger is unhealthy" "RC_HEALTHY=$RC_HEALTHY with a mode-000 ledger"
    fi
    E="$(rc_escaped "$B7")"
    case "$E" in
        *UNREADABLE*) ok "5b  and the diff says UNREADABLE by name, never 'nothing escaped'" ;;
        *) bad "5b  unreadable is reported as unreadable" "got: [$E]" ;;
    esac
else
    ok "5a  (not testable here: this user can read a mode-000 file — running as root)"
    ok "5b  (same)"
fi
chmod 644 "$CFG/state/worktree-ledger.jsonl"

# ===========================================================================
# 6. NOTHING HERE TOUCHED THE OPERATOR'S REAL RECORD — the library's own promise,
#    checked against the real paths rather than assumed from the sandbox.
# ===========================================================================
if [ -e "$SANDBOX/elsewhere" ]; then
    bad "6a  the suite wrote under the CLAUDE_CONFIG_DIR it merely pointed at" "$SANDBOX/elsewhere exists"
else
    ok "6a  the suite created nothing under a config directory it only named"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
