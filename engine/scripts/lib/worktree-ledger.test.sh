#!/usr/bin/env bash
#
# worktree-ledger.test.sh — behavioral tests for scripts/lib/worktree-ledger.py,
# the durable ownership record that lets a worktree's owner be judged AFTER the
# harness's lock is gone.
#
# Every verdict-shaped case is TWO-SIDED: the case that must be refused and the
# case that must pass sit next to each other, because a resolver that says
# INDETERMINATE for everything satisfies every safety assertion and reaps
# nothing — the exact shape of the defect this file exists to close.
#
# SINCE 2026-09-03 ownership is EXACT PATH ONLY. A registration is matched by
# the worktree path it names; a teammate name, a branch name and a transcript's
# name join are NOT ownership (names are reusable, and a verdict that deletes
# on a reusable key deletes the wrong tree). The cases below register by path
# and prove, beside every positive, that a name-only or transcript-only match
# is UNRESOLVED.
#
# Run directly: scripts/lib/worktree-ledger.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_PY="$SCRIPT_DIR/worktree-ledger.py"
TX_PY="$SCRIPT_DIR/worktree-transactions.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t worktree-ledger-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$LEDGER_PY" ] || { echo "FATAL: missing $LEDGER_PY" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

LEDGER="$SANDBOX/ledger.jsonl"
L() { python3 "$LEDGER_PY" --ledger "$LEDGER" "$@"; }
export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"

# NO local git identity override: fixtures inherit the operator's real global
# identity, which a machine-wide pre-commit identity guard requires.
seed_repo() { # <path>
    mkdir -p "$1"
    git -C "$1" init -q -b main
    printf 'seed\n' >"$1/seed.txt"
    git -C "$1" add -A
    git -C "$1" commit -q -m seed
}
add_native() { # <entity> <agent-id> [lock-pid]
    mkdir -p "$1/.claude/worktrees"
    git -C "$1" worktree add -q -b "worktree-agent-$2" "$1/.claude/worktrees/agent-$2"
    if [ -n "${3:-}" ]; then
        git -C "$1" worktree lock --reason "claude agent agent-$2 (pid $3 start test)" \
            "$1/.claude/worktrees/agent-$2"
    fi
}

ENTITY="$SANDBOX/entity"
seed_repo "$ENTITY"
MY_START="$(python3 "$LEDGER_PY" pid-start "$$")"

echo "=== worktree-ledger tests ==="

# 1. record appends one JSON line carrying ts + the fields given.
L record registered --teammate zach-opus-t1 --agent-id aaa111 --session-id sess-1 \
    --session-pid "$$" --pid-start-of-session --repo "$ENTITY" \
    --worktree "$SANDBOX/wt/zach-opus-t1" --branch zach-opus-t1 --class hand-rolled \
    --source test >/dev/null
if [ "$(grep -c . "$LEDGER")" -eq 1 ] && python3 - "$LEDGER" "$MY_START" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1]).read().strip())
assert d["event"] == "registered" and d["teammate"] == "zach-opus-t1"
assert isinstance(d["session_pid"], int)
assert d["pid_start"] == sys.argv[2], (d["pid_start"], sys.argv[2])
assert "ts" in d and d["class"] == "hand-rolled"
PY
then ok "L01  record appends one line with ts, fields, and pid_start read from ps"
else bad "L01  record shape: $(cat "$LEDGER")"; fi

# 2. UNRESOLVED: nothing on record for a path -> UNRESOLVED, never NOT-ALIVE.
#    (Absence is not death.)
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/nobody" --name nobody-owns-this --format triple --no-write)"
case "$V" in
UNRESOLVED*) ok "L02  no record for the path -> UNRESOLVED" ;;
*) bad "L02  unresolved owner got: $V" ;;
esac

# 2b. NAME-ONLY IS NOT OWNERSHIP. zach-opus-t1 is registered at wt/zach-opus-t1;
#     a DIFFERENT path whose branch/dirname carries the same name is UNRESOLVED,
#     and the reason says why.
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/other/zach-opus-t1" --name zach-opus-t1 --format triple --no-write)"
if printf '%s' "$V" | grep -q '^UNRESOLVED.*name-based and transcript-based matching are not ownership'; then
    ok "L03  a name that matches a registration for ANOTHER path is UNRESOLVED (names are reusable, never ownership)"
else
    bad "L03  name-only match: $V"
fi
# ...and the same name at the REGISTERED path is judged (positive control).
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-t1" --name zach-opus-t1 --format triple --no-write)"
case "$V" in
UNRESOLVED*) bad "L03  exact-path registration not judged: $V" ;;
*) ok "L04  the same name at the EXACT registered path is judged (positive control for 2b)" ;;
esac

# 3. SESSION PROVABLY GONE -> NOT-ALIVE. A path registration whose session pid
#    was a process that has since exited. This is the prior-session case: the
#    native worktree never existed in this entity, and the tree is decidable.
sleep 5 &
DEAD_PID=$!
DEAD_START="$(python3 "$LEDGER_PY" pid-start "$DEAD_PID")"
kill "$DEAD_PID" 2>/dev/null; wait "$DEAD_PID" 2>/dev/null || true
L record registered --teammate zach-opus-gone --agent-id gone001 --session-id sess-old \
    --session-pid "$DEAD_PID" --pid-start "$DEAD_START" --repo "$ENTITY" \
    --worktree "$SANDBOX/wt/zach-opus-gone" --class native >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-gone" --name zach-opus-gone --format triple --no-write)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*host session pid .* is gone'; then
    ok "L05  registration whose session pid is GONE -> NOT-ALIVE (prior-session owner is decidable)"
else
    bad "L05  dead session pid: $V"
fi

# 4. SESSION STILL RUNNING, native absent -> INDETERMINATE, naming the pid.
#    The negative control for case 3: same shape, live process.
L record registered --teammate zach-opus-live --agent-id live001 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" \
    --worktree "$SANDBOX/wt/zach-opus-live" --class native >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-live" --name zach-opus-live --format triple --no-write)"
if printf '%s' "$V" | grep -q "^INDETERMINATE.*session pid $$ is still running"; then
    ok "L06  registration whose session pid is RUNNING and native worktree absent -> INDETERMINATE"
else
    bad "L06  live session pid: $V"
fi

# 4b. THE PLATFORM'S TERMINAL RECORD DECIDES WHAT ABSENCE COULD NOT (round 14,
#     2026-09-11, O2). Same registration as L06 -- session running, native
#     shell absent -- plus a SEALED TERMINAL TRANSACTION in the store naming
#     this exact path as a member: the platform's own SubagentStop claimed the
#     agent. That is positive evidence, the same fact the reclaim lane removes
#     on, and it turns L06's INDETERMINATE into NOT-ALIVE. A transaction that
#     names a DIFFERENT path, or an adopted one, decides nothing (controls).
export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
tx_terminal() { # <session-id> <agent-id> <member-path> [kind]
    mkdir -p "$RICHOS_WORKTREE_TX_DIR/$1"
    python3 - "$RICHOS_WORKTREE_TX_DIR/$1/$2.json" "$1" "$2" "$3" "${4:-}" <<'PY'
import datetime, json, sys
path, sid, aid, member, kind = sys.argv[1:6]
rec = {"record": "transaction", "session_id": sid, "agent_id": aid, "teammate": "zach-opus-live",
       "sealed": True, "state": "terminal",
       "terminal": {"ingress": "SubagentStop", "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(), "detail": ""},
       "members": [{"class": "hand-rolled", "path": member, "branch": "zach-opus-live",
                    "state": "bound", "cleanup_policy": "integrated-daily"}]}
if kind:
    rec["kind"] = kind
json.dump(rec, open(path, "w"))
PY
}
tx_terminal sess-now live001 "$SANDBOX/wt/somewhere-else"
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-live" --name zach-opus-live --format triple --no-write)"
printf '%s' "$V" | grep -q "^INDETERMINATE.*session pid $$ is still running" \
    && ok "L06a  a terminal transaction naming ANOTHER path decides nothing about this one (control)" \
    || bad "L06a  other-path transaction: $V"
tx_terminal sess-now live001 "$SANDBOX/wt/zach-opus-live" adopted
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-live" --name zach-opus-live --format triple --no-write)"
printf '%s' "$V" | grep -q "^INDETERMINATE.*session pid $$ is still running" \
    && ok "L06a' an ADOPTED terminal transaction (the engine's own derivation, not the platform's word) decides nothing (control)" \
    || bad "L06a' adopted transaction: $V"
tx_terminal sess-now live001 "$SANDBOX/wt/zach-opus-live"
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-live" --name zach-opus-live --format triple --no-write)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*platform terminal record: the platform.s own terminal record for agent live001: SubagentStop at .* is member 1 of 1'; then
    ok "L06b  the platform's SEALED TERMINAL RECORD naming this exact path turns the same registration NOT-ALIVE while the session still runs -- positive evidence, the fact the reclaim lane removes on"
else
    bad "L06b  terminal record: $V"
fi
# 4c. ...and ROW 5 STILL APPLIES: a post-terminal start note with no stop
#     after it means the platform ran the agent AGAIN, and the verdict is
#     INDETERMINATE with row 5's own reason, never NOT-ALIVE.
python3 "$SCRIPT_DIR/worktree-transactions.py" note-after-terminal --session-id sess-now --agent-id live001 --kind start --detail /cwd >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-live" --name zach-opus-live --format triple --no-write)"
if printf '%s' "$V" | grep -q '^INDETERMINATE.*RETRY, not a verdict: the platform started agent live001 again after its terminal record'; then
    ok "L06c  a post-terminal run OPEN in the transaction's notes holds the verdict at INDETERMINATE with row 5's reason (the agent is running again; the record is not death)"
else
    bad "L06c  open run: $V"
fi
python3 "$SCRIPT_DIR/worktree-transactions.py" note-after-terminal --session-id sess-now --agent-id live001 --kind stop --detail SubagentStop >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-live" --name zach-opus-live --format triple --no-write)"
printf '%s' "$V" | grep -q '^NOT-ALIVE.*platform terminal record' \
    && ok "L06d  and once that run's stop is recorded the verdict is NOT-ALIVE again" \
    || bad "L06d  after the stop: $V"

# =========================================================================
# 4d-4k. ROUND 15 (2026-09-11, Frank D1-D3 / Sage D-A): THE LOCK IS RESOLVED
# WHERE THE SHELL LIVES, NOTHING IS WRITTEN FROM THE RECORD, A WRONG ROW CAN
# BE RETRACTED, AND THE TWO-ROW SHAPE IS JUDGED AS ONE AGENT.
#
# Round 14's step 2b resolved the lock in the CALLER'S entity, fell through
# to the transaction's terminal record when that entity held no shell, and
# with write on appended a `terminated` row that step 1 then returned on
# every later call — ahead of the lock, ahead of row 5. It happened on the
# operator's ledger at 00:02:34Z for an agent whose shell was LOCKED by a
# running pid in the session's repository. Every case below is the shape a
# real cross-repository tree has: the shell in repository A (the session's),
# the tree in repository B, one entity argument from a caller that cannot
# know which is which.
# =========================================================================
ENTITY_B="$SANDBOX/entity-b"
seed_repo "$ENTITY_B"
tx_terminal2() { # <session-id> <agent-id> <teammate> <native-repo> <native-path> <hand-rolled-path>
    mkdir -p "$RICHOS_WORKTREE_TX_DIR/$1"
    python3 - "$RICHOS_WORKTREE_TX_DIR/$1/$2.json" "$@" <<'PY'
import datetime, json, sys
path, sid, aid, teammate, nrepo, npath, hpath = sys.argv[1:8]
rec = {"record": "transaction", "session_id": sid, "agent_id": aid, "teammate": teammate,
       "sealed": True, "state": "terminal",
       "terminal": {"ingress": "SubagentStop", "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(), "detail": ""},
       "members": [{"class": "native", "repo": nrepo, "path": npath, "branch": "worktree-agent-" + aid,
                    "state": "bound", "cleanup_policy": "integrated-daily", "cleanup_owner": "claude-code"},
                   {"class": "hand-rolled", "path": hpath, "branch": "cc/" + teammate,
                    "state": "bound", "cleanup_policy": "integrated-daily"}]}
json.dump(rec, open(path, "w"))
PY
}
terminated_rows() { grep -c '"event": "terminated"' "$LEDGER" 2>/dev/null || true; }
last_ts_for() { # <agent-id> <event> -> ts of the last such row
    python3 - "$LEDGER" "$1" "$2" <<'PY'
import json, sys
ts = ""
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except Exception: continue
    if d.get("agent_id") == sys.argv[2] and d.get("event") == sys.argv[3]: ts = d.get("ts") or ""
print(ts)
PY
}

# 4d. THE WRONG ENTITY. Shell LOCKED by a running pid in A; both rows the
#     engine writes (native in A, hand-rolled in B); a sealed terminal
#     transaction naming both. Judged with entity B (where no shell can be)
#     and with entity A, write ON: ALIVE both times and NOT ONE ROW appended.
add_native "$ENTITY" "xr001" "$$"
L record registered --teammate sage-fable-x1 --agent-id xr001 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" \
    --worktree "$ENTITY/.claude/worktrees/agent-xr001" --class native --source detect-nonnative-worktree.sh >/dev/null
L record registered --teammate sage-fable-x1 --agent-id xr001 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY_B" \
    --worktree "$SANDBOX/wt-b/sage-fable-x1" --branch cc/sage-fable-x1 --class hand-rolled --source detect-nonnative-worktree.sh >/dev/null
tx_terminal2 sess-now xr001 sage-fable-x1 "$ENTITY" "$ENTITY/.claude/worktrees/agent-xr001" "$SANDBOX/wt-b/sage-fable-x1"
N0="$(grep -c . "$LEDGER")"
VB="$(L judge --entity "$ENTITY_B" --worktree "$SANDBOX/wt-b/sage-fable-x1" --format triple)"
VA="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt-b/sage-fable-x1" --format triple)"
N1="$(grep -c . "$LEDGER")"
if printf '%s' "$VB" | grep -q '^ALIVE.*LOCKED by running pid' && printf '%s' "$VA" | grep -q '^ALIVE.*LOCKED by running pid' && [ "$N1" -eq "$N0" ]; then
    ok "L06e  a cross-repository tree whose owner's shell is LOCKED in the SESSION repository is ALIVE whichever entity the caller passes, and nothing is appended (write ON) — the entity join lives inside the judge"
else
    bad "L06e  wrong entity (rows $N0 -> $N1): B=[$VB] A=[$VA]"
fi

# 4e. THE TRANSACTION'S OWN NATIVE MEMBER is enough — no native ledger row at
#     all, only the hand-rolled row and the manifest the reclaim lane reads.
#     And the CONTROL that proves the lookup is real rather than a stub that
#     answers ALIVE: the same shape with the shell UNLOCKED is the observed
#     termination it always was, written once, through the manifest's repo.
add_native "$ENTITY" "xr002" "$$"
L record registered --teammate sage-fable-x2 --agent-id xr002 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY_B" \
    --worktree "$SANDBOX/wt-b/sage-fable-x2" --branch cc/sage-fable-x2 --class hand-rolled --source detect-nonnative-worktree.sh >/dev/null
tx_terminal2 sess-now xr002 sage-fable-x2 "$ENTITY" "$ENTITY/.claude/worktrees/agent-xr002" "$SANDBOX/wt-b/sage-fable-x2"
V="$(L judge --entity "$ENTITY_B" --worktree "$SANDBOX/wt-b/sage-fable-x2" --format triple)"
printf '%s' "$V" | grep -q '^ALIVE.*LOCKED by running pid' \
    && ok "L06f  with NO native ledger row, the transaction's own native member names the repository whose lock speaks — ALIVE with the tree's entity" \
    || bad "L06f  transaction member lookup: $V"
add_native "$ENTITY" "xr003"
L record registered --teammate sage-fable-x3 --agent-id xr003 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY_B" \
    --worktree "$SANDBOX/wt-b/sage-fable-x3" --branch cc/sage-fable-x3 --class hand-rolled --source detect-nonnative-worktree.sh >/dev/null
tx_terminal2 sess-now xr003 sage-fable-x3 "$ENTITY" "$ENTITY/.claude/worktrees/agent-xr003" "$SANDBOX/wt-b/sage-fable-x3"
T0="$(terminated_rows)"
V="$(L judge --entity "$ENTITY_B" --worktree "$SANDBOX/wt-b/sage-fable-x3" --format triple)"
T1="$(terminated_rows)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*OBSERVED now' && [ "$T1" -eq $((T0 + 1)) ] \
   && grep '"agent_id": "xr003"' "$LEDGER" | grep -q '"witness": "reaper-observation"'; then
    ok "L06f' (control) the same shape with the shell UNLOCKED in the session repository is the OBSERVED termination, witnessed once through the manifest — the lookup is real"
else
    bad "L06f' unlocked shell via the manifest (terminated $T0 -> $T1): $V"
fi

# 4f. FRANK'S SEQUENCE. The terminal-record verdict with write ON persists
#     NOTHING; then the platform starts the agent again, and the verdict is
#     row 5's INDETERMINATE — a property one persisted row destroyed in
#     round 14 (the sandbox in certification-frank-round4, D1).
T0="$(terminated_rows)"
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-live" --name zach-opus-live --format triple)"
T1="$(terminated_rows)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*platform terminal record' && [ "$T1" -eq "$T0" ]; then
    ok "L06g  the terminal-record verdict with write ON appends NO terminated row — the store is re-read, never copied"
else
    bad "L06g  2b wrote (terminated $T0 -> $T1): $V"
fi
python3 "$SCRIPT_DIR/worktree-transactions.py" note-after-terminal --session-id sess-now --agent-id live001 --kind start --detail /cwd-again >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-live" --name zach-opus-live --format triple)"
printf '%s' "$V" | grep -q '^INDETERMINATE.*RETRY, not a verdict: the platform started agent live001 again' \
    && ok "L06g' and a post-terminal start AFTER a write-enabled judgment still holds at row 5's INDETERMINATE — the record was not made permanent" \
    || bad "L06g' open run after a write-enabled judgment: $V"
python3 "$SCRIPT_DIR/worktree-transactions.py" note-after-terminal --session-id sess-now --agent-id live001 --kind stop --detail SubagentStop >/dev/null

# 4g. A RECORD-DERIVED WITNESS ON THE LEDGER NEVER OUTRANKS THE LOCK. The
#     one row round 14 wrote on the operator's ledger has this exact shape;
#     put beside a LOCKED shell it decides nothing. Beside it, the ledger's
#     OWN kind (an observed unlocked shell) still decides — the filter is by
#     kind, not a disabled step — and THAT row can be RETRACTED.
printf '{"event": "terminated", "agent_id": "xr001", "teammate": "sage-fable-x1", "session_id": "sess-now", "worktree": "%s", "reason": "the platform'"'"'s own terminal record for agent xr001 (fixture copy of the 00:02:34Z row)", "witness": "platform-terminal-record", "ts": "2026-09-11T00:02:34.984941+00:00"}\n' \
    "$SANDBOX/wt-b/sage-fable-x1" >>"$LEDGER"
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt-b/sage-fable-x1" --format triple --no-write)"
printf '%s' "$V" | grep -q '^ALIVE.*LOCKED by running pid' \
    && ok "L06h  a 'platform-terminal-record' witness row on the ledger (the round-14 shape) does not outrank a held lock: ALIVE" \
    || bad "L06h  record-derived witness outranked the lock: $V"
L record terminated --agent-id xr001 --teammate sage-fable-x1 --session-id sess-now \
    --worktree "$ENTITY/.claude/worktrees/agent-xr001" --reason "fixture: an observation this ledger holds as its own" --witness reaper-observation >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt-b/sage-fable-x1" --format triple --no-write)"
printf '%s' "$V" | grep -q '^NOT-ALIVE.*witnessed termination on record.*an observation this ledger holds as its own' \
    && ok "L06h' (control) the ledger's OWN witness kind still decides at step 1 — the filter is by kind, not a disabled step" \
    || bad "L06h' own-kind witness: $V"
TS="$(last_ts_for xr001 terminated)"
N0="$(grep -c . "$LEDGER")"
L retract --agent-id xr001 --ts "not-a-row" --reason "control" >/dev/null 2>&1 && bad "L06i  retract accepted a ts that names no row" || ok "L06i  retract REFUSES (rc 2) a ts that names no row"
L retract --agent-id xr001 --ts "$TS" --reason "dry run" --dry-run >/dev/null
N1="$(grep -c . "$LEDGER")"
[ "$N1" -eq "$N0" ] && ok "L06i' --dry-run appends nothing" || bad "L06i' --dry-run appended $((N1 - N0)) line(s)"
OUT="$(L retract --agent-id xr001 --ts "$TS" --reason "the shell was LOCKED by a running pid when this row was written (round 15 fixture)" --source test)"
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt-b/sage-fable-x1" --format triple --no-write)"
if printf '%s' "$OUT" | grep -q '"retracts_ts": "'"$TS"'"' && printf '%s' "$V" | grep -q '^ALIVE.*LOCKED by running pid' \
   && grep '"event": "retracted"' "$LEDGER" | grep -q '"retracts_witness": "reaper-observation"'; then
    ok "L06j  RETRACTION: a 'retracted' row naming the exact ts supersedes the terminated row for step 1 — the same registration is ALIVE again, and the record keeps both rows with the reason"
else
    bad "L06j  retraction: out=[$OUT] verdict=[$V]"
fi
N0="$(grep -c . "$LEDGER")"
OUT="$(L retract --agent-id xr001 --ts "$TS" --reason "again" --source test)"
N1="$(grep -c . "$LEDGER")"
printf '%s' "$OUT" | grep -q '"skipped": "already retracted"' && [ "$N1" -eq "$N0" ] \
    && ok "L06j' a second retraction of the same row is skipped, not duplicated" \
    || bad "L06j' duplicate retraction: $OUT ($N0 -> $N1)"

# 4h. THE TWO-ROW SHAPE (Frank D3). What every helper-made tree carries: a
#     `prepared` row with NO agent id (create-teammate-worktree.sh, before the
#     spawn) and a `registered` row with one (detect-nonnative-worktree.sh,
#     after). Shell absent, session alive, terminal record closed. The
#     id-less row is joined to the id, so the aggregate is the record's
#     NOT-ALIVE and not step 3's INDETERMINATE — and the reason says so.
#     Two controls: a HAND-WRITTEN prepared row never joins; two ids for one
#     name in one session are ambiguous and never join.
two_rows() { # <teammate> <agent-id> <prepared-source> [second-agent-id]
    local tm="$1" aid="$2" src="$3" aid2="${4:-}"
    L record prepared --teammate "$tm" --session-id sess-now --session-pid "$$" --pid-start "$MY_START" \
        --repo "$ENTITY_B" --worktree "$SANDBOX/wt-b/$tm" --branch "cc/$tm" --class hand-rolled --source "$src" >/dev/null
    L record registered --teammate "$tm" --agent-id "$aid" --session-id sess-now --session-pid "$$" --pid-start "$MY_START" \
        --repo "$ENTITY_B" --worktree "$SANDBOX/wt-b/$tm" --branch "cc/$tm" --class hand-rolled --source detect-nonnative-worktree.sh >/dev/null
    [ -z "$aid2" ] || L record registered --teammate "$tm" --agent-id "$aid2" --session-id sess-now --session-pid "$$" --pid-start "$MY_START" \
        --repo "$ENTITY_B" --worktree "$SANDBOX/wt-b/$tm" --branch "cc/$tm" --class hand-rolled --source detect-nonnative-worktree.sh >/dev/null
    tx_terminal "sess-now" "$aid" "$SANDBOX/wt-b/$tm"
}
two_rows zach-opus-two two001 create-teammate-worktree.sh
V="$(L judge --entity "$ENTITY_B" --worktree "$SANDBOX/wt-b/zach-opus-two" --format triple)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*2 registrations match (ledger); prepared row joined to agent two001.*platform terminal record' \
   && printf '%s' "$V" | grep -q 'two001' ; then
    ok "L06k  the two-row shape (id-less prepared + registered with the id), shell absent, session alive, record closed -> NOT-ALIVE from the record, the prepared row JOINED to the id and the reason saying so"
else
    bad "L06k  two-row shape: $V"
fi
two_rows zach-opus-hand two002 rich-land-binding
V="$(L judge --entity "$ENTITY_B" --worktree "$SANDBOX/wt-b/zach-opus-hand" --format triple)"
printf '%s' "$V" | grep -q "^INDETERMINATE.*session pid $$ is still running" \
    && ok "L06k' (control) a HAND-WRITTEN prepared row is never joined: it still reserves at INDETERMINATE while the session lives" \
    || bad "L06k' hand-written prepared row joined: $V"
two_rows zach-opus-twin2 two003 create-teammate-worktree.sh two004
V="$(L judge --entity "$ENTITY_B" --worktree "$SANDBOX/wt-b/zach-opus-twin2" --format triple)"
printf '%s' "$V" | grep -q "^INDETERMINATE.*session pid $$ is still running" \
    && ok "L06k'' (control) two agent ids for one name in one session are ambiguous: no join, INDETERMINATE" \
    || bad "L06k'' ambiguous join: $V"

# the fixture's transactions must not leak into the cases below, which assert L06's shape elsewhere
rm -rf "$RICHOS_WORKTREE_TX_DIR/sess-now"

# 5. PID REUSED -> NOT-ALIVE. Same pid as case 4, but the recorded start time is
#    not this process's start time: that process is gone and its number was
#    handed to someone else. A bare kill -0 would call this ALIVE.
L record registered --teammate zach-opus-reused --agent-id reuse01 --session-id sess-x \
    --session-pid "$$" --pid-start "ps-lstart-utc-v1:Mon Jan 1 00:00:00 1990" --repo "$ENTITY" \
    --worktree "$SANDBOX/wt/zach-opus-reused" --class native >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-reused" --name zach-opus-reused --format triple --no-write)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*is reused'; then
    ok "L07  running pid with a DIFFERENT start time -> NOT-ALIVE (pid reuse is not liveness)"
else
    bad "L07  pid reuse: $V"
fi

# 6. ALIVE WINS. Two registrations for one PATH: one dead session, one whose
#    native isolation worktree is LOCKED by a running pid. The tree's owner is
#    ALIVE — one live registration outranks any number of dead ones.
add_native "$ENTITY" "twin01" "$$"
L record registered --teammate zach-opus-twin --agent-id twin00 --session-id sess-old \
    --session-pid "$DEAD_PID" --pid-start "$DEAD_START" --repo "$ENTITY" \
    --worktree "$SANDBOX/wt/zach-opus-twin" --class native >/dev/null
L record registered --teammate zach-opus-twin --agent-id twin01 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" \
    --worktree "$SANDBOX/wt/zach-opus-twin" --class native >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-twin" --name zach-opus-twin --format triple --no-write)"
if printf '%s' "$V" | grep -q '^ALIVE.*LOCKED by running pid'; then
    ok "L08  two registrations for one path, one LOCKED by a running pid -> ALIVE (a live owner outranks a dead twin)"
else
    bad "L08  alive wins: $V"
fi

# 7. THE ACCEPTANCE PROPERTY. Native worktree registered + unlocked -> NOT-ALIVE
#    OBSERVED, and the observation is WRITTEN. Then the native worktree is
#    removed (what a land does) and the same tree is STILL decidable from the
#    record. This is the case every prior fix failed.
add_native "$ENTITY" "done01"
L record registered --teammate zach-opus-done --agent-id done01 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" \
    --worktree "$SANDBOX/wt/zach-opus-done" --class native >/dev/null
BEFORE="$(grep -c '"event": "terminated"' "$LEDGER" || true)"
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-done" --name zach-opus-done --format triple)"
AFTER="$(grep -c '"event": "terminated"' "$LEDGER" || true)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*OBSERVED now' && [ "$AFTER" -eq $((BEFORE + 1)) ]; then
    ok "L09  native registered+unlocked -> NOT-ALIVE observed, and a 'terminated' record is written"
else
    bad "L09  observed termination (before=$BEFORE after=$AFTER): $V"
fi
git -C "$ENTITY" worktree remove "$ENTITY/.claude/worktrees/agent-done01" >/dev/null 2>&1
git -C "$ENTITY" branch -d worktree-agent-done01 >/dev/null 2>&1
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-done" --name zach-opus-done --format triple --no-write)"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*witnessed termination on record'; then
    ok "L10  AFTER the native worktree is gone, the owner is STILL NOT-ALIVE from the witnessed record"
else
    bad "L10  post-removal decidability: $V"
fi

# 7b. NEGATIVE CONTROL for 7: the same shape WITHOUT the witnessed record and
#     with a running session is INDETERMINATE — the record is what decides it,
#     not the removal.
add_native "$ENTITY" "quiet01"
L record registered --teammate zach-opus-quiet --agent-id quiet01 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" \
    --worktree "$SANDBOX/wt/zach-opus-quiet" --class native >/dev/null
git -C "$ENTITY" worktree remove "$ENTITY/.claude/worktrees/agent-quiet01" >/dev/null 2>&1
git -C "$ENTITY" branch -d worktree-agent-quiet01 >/dev/null 2>&1
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-quiet" --name zach-opus-quiet --format triple --no-write)"
case "$V" in
INDETERMINATE*) ok "L11  native removed with NO witnessed record and a live session -> INDETERMINATE (never guessed)" ;;
*) bad "L11  unwitnessed removal: $V" ;;
esac

# 8. --no-write writes nothing, even on an observation.
add_native "$ENTITY" "nowrite1"
L record registered --teammate zach-opus-nw --agent-id nowrite1 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" \
    --worktree "$SANDBOX/wt/zach-opus-nw" --class native >/dev/null
BEFORE="$(grep -c . "$LEDGER")"
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-nw" --format triple --no-write)"
AFTER="$(grep -c . "$LEDGER")"
if [ "$AFTER" -eq "$BEFORE" ] && printf '%s' "$V" | grep -q '^NOT-ALIVE.*OBSERVED now'; then
    ok "L12  --no-write appends nothing, even on an observation that would be written"
else
    bad "L12  --no-write appended $((AFTER - BEFORE)) line(s): $V"
fi

# 9. ADVISORY SIGNALS NEVER DECIDE. Three 'finished' records for a live-session
#    agent leave it INDETERMINATE, and the reason says they are advisory.
for sig in TeammateIdle TaskCompleted SubagentStop; do
    L record finished --signal "$sig" --agent-id live001 --teammate zach-opus-live --session-id sess-now >/dev/null
done
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-live" --name zach-opus-live --format triple --no-write)"
if printf '%s' "$V" | grep -q '^INDETERMINATE' && printf '%s' "$V" | grep -q 'advisory, never decisive: live001: 3 advisory finish signal'; then
    ok "L13  TeammateIdle/TaskCompleted/SubagentStop are reported as advisory and never decide"
else
    bad "L13  advisory signals: $V"
fi

# 10. THE TRANSCRIPT IS NOT OWNERSHIP. No ledger row for the path; a transcript
#     joins the tree's NAME to an agent whose native worktree is LOCKED. Until
#     2026-09-03 that was ALIVE / NOT-ALIVE by name; now it is UNRESOLVED with
#     the hint that the join exists and is refused. Beside it, the same agent
#     with a PATH registration is judged — proving the refusal is the key, not
#     a broken resolver.
T="$SANDBOX/transcript.jsonl"
python3 - "$T" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for i, (name, aid) in enumerate([("echo-opus-tr1", "tr1"), ("echo-opus-tr2", "tr2")]):
        tu = "tu%d" % i
        f.write(json.dumps({"message": {"content": [{"type": "tool_use", "name": "Agent", "id": tu, "input": {"name": name}}]}}) + "\n")
        f.write(json.dumps({"message": {"content": [{"type": "tool_result", "tool_use_id": tu}]}, "toolUseResult": {"agentId": aid}}) + "\n")
PY
add_native "$ENTITY" "tr1" "$$"
add_native "$ENTITY" "tr2"
V1="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/echo-opus-tr1" --name echo-opus-tr1 --transcript "$T" --format triple --no-write)"
if printf '%s' "$V1" | grep -q '^UNRESOLVED.*a transcript joins the name .echo-opus-tr1. to an agent, and that is NOT accepted as ownership'; then
    ok "L14  a transcript-only name join is UNRESOLVED and the reason names the refused join"
else
    bad "L14  transcript-only: $V1"
fi
L record registered --teammate echo-opus-tr2 --agent-id tr2 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" \
    --worktree "$SANDBOX/wt/echo-opus-tr2" --class native >/dev/null
V2="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/echo-opus-tr2" --name echo-opus-tr2 --transcript "$T" --format triple --no-write)"
if printf '%s' "$V2" | grep -q '^NOT-ALIVE.*OBSERVED now'; then
    ok "L15  the same agent WITH a path registration is judged (positive control for 10)"
else
    bad "L15  path-registered beside transcript: $V2"
fi

# 11. judge-batch: one line per input path, same verdicts.
OUT="$(printf '%s\t%s\t%s\t%s\n%s\t%s\t%s\t%s\n' \
        "$ENTITY" "$SANDBOX/wt/zach-opus-gone" zach-opus-gone zach-opus-gone \
        "$ENTITY" "$SANDBOX/wt/nobody" nobody nobody \
      | L judge-batch --entity "$ENTITY" --no-write)"
if printf '%s\n' "$OUT" | grep -q "^$SANDBOX/wt/zach-opus-gone	NOT-ALIVE	gone001	" \
   && printf '%s\n' "$OUT" | grep -q "^$SANDBOX/wt/nobody	UNRESOLVED		"; then
    ok "L16  judge-batch emits path<TAB>verdict<TAB>agent-ids<TAB>reason per input line"
else
    bad "L16  judge-batch: $OUT"
fi

# 12. branches --repo lists the registered branch names for that repository.
if [ "$(L branches --repo "$ENTITY" | tr '\n' ' ')" = "zach-opus-t1 " ]; then
    ok "L17  branches --repo lists ledger-registered branches"
else
    bad "L17  branches: $(L branches --repo "$ENTITY" | tr '\n' ' ')"
fi

# 13. A malformed line never poisons the record.
printf 'this is not json\n' >>"$LEDGER"
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/wt/zach-opus-gone" --name zach-opus-gone --format triple --no-write)"
printf '%s' "$V" | grep -q '^NOT-ALIVE' && ok "L18  a malformed ledger line is skipped, not fatal" || bad "L18  malformed line: $V"

# 14. Exact-path registration wins without any name match: a hand-rolled tree
#     registered by path, whose directory is named nothing like its owner.
L record registered --teammate mark-opus-p1 --agent-id gone002 --session-id sess-old \
    --session-pid "$DEAD_PID" --pid-start "$DEAD_START" --repo "$SANDBOX/other" \
    --worktree "$SANDBOX/other-wt/feature-x" --branch feature-x --class hand-rolled >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SANDBOX/other-wt/feature-x" --name feature-x --format triple --no-write)"
printf '%s' "$V" | grep -q '^NOT-ALIVE.*host session pid' && ok "L19  a path-registered tree is judged by its registration, not its name" || bad "L19  path registration: $V"

# 15. THE DURABLE APPEND. `append` fsyncs the line: the record is on disk the
#     moment the call returns True (read back through a fresh process).
N0="$(grep -c . "$LEDGER")"
L record prepared --teammate mark-opus-pr1 --session-id sess-now --repo "$SANDBOX/other" \
    --worktree "$SANDBOX/other-wt/mark-opus-pr1" --branch mark-opus-pr1 --class hand-rolled \
    --source test >/dev/null
N1="$(python3 -c 'import sys; print(sum(1 for l in open(sys.argv[1]) if l.strip()))' "$LEDGER")"
[ "$N1" -eq $((N0 + 1)) ] && ok "L20  record prepared appends one durable line" || bad "L20  prepared append: $N0 -> $N1"

# 16. PREPARED RECORDS ARE EXACT. Every filter must match; each negative sits
#     beside the positive.
if L prepared --session-id sess-now --teammate mark-opus-pr1 --worktree "$SANDBOX/other-wt/mark-opus-pr1" >/dev/null; then
    ok "L21  prepared: exact (session, teammate, path) resolves"
else
    bad "L21  prepared positive"
fi
L prepared --session-id sess-OTHER --teammate mark-opus-pr1 --worktree "$SANDBOX/other-wt/mark-opus-pr1" >/dev/null 2>&1 \
    && bad "L22  prepared: another session matched" || ok "L22  prepared: a different session id does NOT match"
L prepared --session-id sess-now --teammate mark-opus-pr2 --worktree "$SANDBOX/other-wt/mark-opus-pr1" >/dev/null 2>&1 \
    && bad "L23  prepared: another teammate matched" || ok "L23  prepared: a different teammate name does NOT match"
L prepared --session-id sess-now --teammate mark-opus-pr1 --worktree "$SANDBOX/elsewhere-wt/mark-opus-pr1" >/dev/null 2>&1 \
    && bad "L24  prepared: another path matched" || ok "L24  prepared: a different path with the SAME basename does NOT match (no prefix, no basename)"
L prepared --session-id sess-now --teammate mark-opus-pr1 --repo "$SANDBOX/elsewhere" >/dev/null 2>&1 \
    && bad "L25  prepared: another repo matched" || ok "L25  prepared: a different repository does NOT match"

# 17. A prepared record satisfies the exact-path REGISTRATION lookup the spawn
#     guard's clause 4 performs (it is the creation-time record), and `--name`
#     on that CLI is reporting only: it finds the row, and a path lookup for a
#     different path with the same name finds nothing.
L registrations --worktree "$SANDBOX/other-wt/mark-opus-pr1" >/dev/null \
    && ok "L26  registrations --worktree resolves a prepared record by exact path" || bad "L26  registrations vs prepared"
L registrations --worktree "$SANDBOX/other-wt/mark-opus-pr1-twin" >/dev/null 2>&1 \
    && bad "L27  registrations matched a different path" || ok "L27  registrations --worktree does NOT match a different path with the same name"

# 18. bound-members: NOTHING without a sealed transaction — no registration,
#     no prepared record, no name is a substitute — and the sealed members
#     with one. The transaction library is the only source.
if [ -f "$TX_PY" ]; then
    BM="$(L bound-members --session-id sess-now --agent-id bm0001)"
    [ -z "$BM" ] && ok "L28  bound-members: no sealed transaction -> nothing (no fallback to registrations or names)" \
                 || bad "L28  bound-members without a transaction returned: $BM"
    add_native "$ENTITY" "bm0001" "$$"
    python3 - "$TX_PY" <<'PY' >/dev/null
import json, sys, importlib.util, os
spec = importlib.util.spec_from_file_location("tx", sys.argv[1]); tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
tx.write_intent("sess-now", "tu-bm", {"kind": "native", "teammate": "bm-opus-1", "externals": []})
tx.bind("sess-now", "tu-bm", "bm0001", "test")
PY
    python3 "$TX_PY" start --session-id sess-now --agent-id bm0001 --cwd "$ENTITY/.claude/worktrees/agent-bm0001" >/dev/null
    python3 "$TX_PY" seal --session-id sess-now --agent-id bm0001 >/dev/null
    BM="$(L bound-members --session-id sess-now --agent-id bm0001)"
    if printf '%s' "$BM" | grep -q "^native	$ENTITY	$ENTITY/.claude/worktrees/agent-bm0001	worktree-agent-bm0001	bound$"; then
        ok "L29  bound-members: a sealed transaction's exact native member is returned"
    else
        bad "L29  bound-members sealed: [$BM]"
    fi
else
    bad "L29  scripts/lib/worktree-transactions.py is missing beside the ledger"
fi

# =========================================================================
# SESSION DEATH BY EXHAUSTION — owners registered by PATH with a session id
# and no pid (the shape a prior session leaves). The process table and the
# harness registry are PINNED through their test overrides so these cases
# mean the same thing on every machine. Every case has its opposite beside it.
# =========================================================================
NOW="$(python3 -c 'import time; print(int(time.time()))')"
SESS_DIR="$SANDBOX/sessions"; mkdir -p "$SESS_DIR"
PROJ="$SANDBOX/projects"; mkdir -p "$PROJ/-some-project"
OLD_SID="aaaaaaaa-0000-4000-8000-000000000001"
NEW_SID="bbbbbbbb-0000-4000-8000-000000000002"
write_tx() { # <path> <name>=<aid> ... ; a transcript in the shape names_to_ids reads
    local out="$1"; shift
    python3 - "$out" "$@" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for i, spec in enumerate(sys.argv[2:]):
        name, aid = spec.split("=", 1)
        tu = "tu%d" % i
        f.write(json.dumps({"message": {"content": [{"type": "tool_use", "name": "Agent", "id": tu, "input": {"name": name}}]}}) + "\n")
        f.write(json.dumps({"message": {"content": [{"type": "tool_result", "tool_use_id": tu}]}, "toolUseResult": {"agentId": aid}}) + "\n")
PY
}
write_tx "$PROJ/-some-project/$OLD_SID.jsonl" "art-opus-old1=oldart1"
touch -t "$(date -r $((NOW - 7200)) +%Y%m%d%H%M.%S)" "$PROJ/-some-project/$OLD_SID.jsonl"   # last write: 2h ago
write_tx "$PROJ/-some-project/$NEW_SID.jsonl" "art-opus-new1=newart1"
OLD_WT="$SANDBOX/wt/art-opus-old1"
NEW_WT="$SANDBOX/wt/art-opus-new1"
L record registered --teammate art-opus-old1 --agent-id oldart1 --session-id "$OLD_SID" --repo "$ENTITY" \
    --worktree "$OLD_WT" --class native >/dev/null
L record registered --teammate art-opus-new1 --agent-id newart1 --session-id "$NEW_SID" --repo "$ENTITY" \
    --worktree "$NEW_WT" --class native >/dev/null
registry() { # <pid> <session-id> <started-epoch>
    printf '{"pid":%s,"sessionId":"%s","startedAt":%s000}\n' "$1" "$2" "$3" >"$SESS_DIR/$1.json"
}
EX() { # <processes> -- judge args ; pins CLAUDE_PID to the first listed pid
    local procs="$1"; shift
    local first="${procs%%:*}"
    RICHOS_CLAUDE_PROCESSES="$procs" RICHOS_SESSIONS_DIR="$SESS_DIR" RICHOS_PROJECTS_DIR="$PROJ" CLAUDE_PID="$first" \
        python3 "$LEDGER_PY" --ledger "$LEDGER" judge --entity "$ENTITY" --format triple --no-write --projects-dir "$PROJ" "$@"
}

# E1. GONE. One claude process, started 30 min ago (AFTER the old session's
#     last write), registered to another session. Nothing could be the old
#     session -> NOT-ALIVE by exhaustion. The last-write time comes from the
#     OLDER transcript on disk — the acceptance case the newest-file lookup
#     failed.
rm -f "$SESS_DIR"/*.json; registry 4242 "$NEW_SID" $((NOW - 1800))
V="$(EX "4242:$((NOW - 1800))" --worktree "$OLD_WT")"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*over by exhaustion: no running claude process predates'; then
    ok "L30  EXHAUSTION: a path owner whose session no running process predates -> NOT-ALIVE"
else
    bad "L30  exhaustion gone: $V"
fi

# E2. ALIVE SESSION. The registry says the running pid IS the old session.
rm -f "$SESS_DIR"/*.json; registry 4242 "$OLD_SID" $((NOW - 9000))
V="$(EX "4242:$((NOW - 9000))" --worktree "$OLD_WT")"
if printf '%s' "$V" | grep -q "^INDETERMINATE.*session ${OLD_SID:0:8} is registered to running pid 4242"; then
    ok "L31  EXHAUSTION: the registry names the running pid as THIS session -> INDETERMINATE (session alive)"
else
    bad "L31  exhaustion alive: $V"
fi

# E3. UNACCOUNTED. A process started BEFORE the last write with no registry
#     row could be the session -> INDETERMINATE, naming the pid.
rm -f "$SESS_DIR"/*.json
V="$(EX "4242:$((NOW - 9000))" --worktree "$OLD_WT")"
if printf '%s' "$V" | grep -q '^INDETERMINATE.*running claude pid(s) 4242 started before this session.s last write and are not accounted for'; then
    ok "L32  EXHAUSTION: an unaccounted process that predates the last write -> INDETERMINATE (never guessed)"
else
    bad "L32  exhaustion unaccounted: $V"
fi

# E4. ACCOUNTED FOR. Same process, but the registry says it is ANOTHER
#     session with a matching start -> ruled out -> NOT-ALIVE.
rm -f "$SESS_DIR"/*.json; registry 4242 "$NEW_SID" $((NOW - 9000))
V="$(EX "4242:$((NOW - 9000))" --worktree "$OLD_WT")"
if printf '%s' "$V" | grep -q '^NOT-ALIVE.*over by exhaustion'; then
    ok "L33  EXHAUSTION: a predating process registered to a DIFFERENT session is ruled out -> NOT-ALIVE"
else
    bad "L33  exhaustion accounted: $V"
fi

# E4b. ...but a registry row whose startedAt does NOT match the process start
#      does not account for it (pid reuse in the registry's own terms).
rm -f "$SESS_DIR"/*.json; registry 4242 "$NEW_SID" $((NOW - 100))
V="$(EX "4242:$((NOW - 9000))" --worktree "$OLD_WT")"
if printf '%s' "$V" | grep -q '^INDETERMINATE.*not accounted for'; then
    ok "L34  EXHAUSTION: a registry row with a mismatched start does not account for the process"
else
    bad "L34  exhaustion start mismatch: $V"
fi

# E5. BROKEN ENUMERATION. CLAUDE_PID is not in the enumerated table -> the
#     table is not trusted -> INDETERMINATE, whatever else it says.
rm -f "$SESS_DIR"/*.json; registry 4242 "$NEW_SID" $((NOW - 1800))
V="$(RICHOS_CLAUDE_PROCESSES="4242:$((NOW - 1800))" RICHOS_SESSIONS_DIR="$SESS_DIR" RICHOS_PROJECTS_DIR="$PROJ" CLAUDE_PID=99999 \
     python3 "$LEDGER_PY" --ledger "$LEDGER" judge --entity "$ENTITY" --format triple --no-write --projects-dir "$PROJ" --worktree "$OLD_WT")"
if printf '%s' "$V" | grep -q '^INDETERMINATE.*does not contain this session.s own pid 99999'; then
    ok "L35  EXHAUSTION: an enumeration missing our own pid is refused -> INDETERMINATE"
else
    bad "L35  exhaustion self-check: $V"
fi

# E6. THE TRANSCRIPT NAME JOIN ALONE, with every exhaustion condition met for
#     NOT-ALIVE, is STILL UNRESOLVED: exhaustion is evidence about a session,
#     and only an exact-path record says which tree that session owned.
rm -f "$SESS_DIR"/*.json; registry 4242 "$NEW_SID" $((NOW - 1800))
V="$(EX "4242:$((NOW - 1800))" --worktree "$SANDBOX/wt/art-opus-orphan" --name art-opus-old1)"
printf '%s' "$V" | grep -q '^UNRESOLVED.*NOT accepted as ownership' \
    && ok "L36  EXHAUSTION never fires on a transcript-only name: no path record -> UNRESOLVED" \
    || bad "L36  transcript-only exhaustion: $V"

# E7. NEGATIVE: the newest transcript's own agent, with a live registered
#     session, is INDETERMINATE — exhaustion never fires against a session that
#     is registered as running.
rm -f "$SESS_DIR"/*.json; registry 4242 "$NEW_SID" $((NOW - 1800))
V="$(EX "4242:$((NOW - 1800))" --worktree "$NEW_WT")"
printf '%s' "$V" | grep -q '^INDETERMINATE.*registered to running pid 4242' \
    && ok "L37  the running session's own agent stays INDETERMINATE" \
    || bad "L37  live session's agent: $V"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== worktree-ledger tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== worktree-ledger tests: all $PASS passed ==="

# The mutation harness is part of this suite's definition of green: a suite
# nobody has watched go red proves nothing (open-items rows 3.22-3.29).
if [ -f "$SCRIPT_DIR/worktree-ledger.mutation.sh" ]; then
    bash "$SCRIPT_DIR/worktree-ledger.mutation.sh" || exit 1
fi
exit 0
