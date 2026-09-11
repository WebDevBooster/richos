#!/usr/bin/env bash
# Attack the retraction in a sandbox: own ledger (--ledger), own tx store, own entity. Nothing live.
set -uo pipefail
ENGINE=/Users/alex/ab/richos-wt/frank-fable-cert5/engine
LP="$ENGINE/scripts/lib/worktree-ledger.py"
SB="$(cd "$(mktemp -d -t retract-attack.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SB"' EXIT
export RICHOS_WORKTREE_TX_DIR="$SB/tx"
LEDGER="$SB/ledger.jsonl"
L() { python3 "$LP" --ledger "$LEDGER" "$@"; }
ENTITY="$SB/entity"; mkdir -p "$ENTITY"; git -C "$ENTITY" init -q -b main; printf 's\n' > "$ENTITY/s"; git -C "$ENTITY" add -A; git -C "$ENTITY" commit -q -m s
MY_START="$(python3 "$LP" pid-start "$$")"
add_native() { mkdir -p "$ENTITY/.claude/worktrees"; git -C "$ENTITY" worktree add -q -b "worktree-agent-$1" "$ENTITY/.claude/worktrees/agent-$1"; [ -n "${2:-}" ] && git -C "$ENTITY" worktree lock --reason "claude agent agent-$1 (pid $2 start test)" "$ENTITY/.claude/worktrees/agent-$1"; }
count_term() { grep -c '"event": "terminated"' "$LEDGER" || true; }

echo "=== A. a GENUINE observation (shell registered+unlocked), then the shell is removed, then the observation is retracted"
add_native ra001
L record registered --teammate mark-opus-a --agent-id ra001 --session-id sess-a --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" --worktree "$SB/wt/mark-opus-a" --branch cc/mark-opus-a --class hand-rolled --source detect-nonnative-worktree.sh >/dev/null
L record registered --teammate mark-opus-a --agent-id ra001 --session-id sess-a --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" --worktree "$ENTITY/.claude/worktrees/agent-ra001" --class native --source detect-nonnative-worktree.sh >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SB/wt/mark-opus-a" --format triple)"; echo "  judge (write ON), shell unlocked: $V" | cut -c1-160
echo "  terminated rows: $(count_term)"
git -C "$ENTITY" worktree remove --force "$ENTITY/.claude/worktrees/agent-ra001"
V="$(L judge --entity "$ENTITY" --worktree "$SB/wt/mark-opus-a" --format triple --no-write)"; echo "  judge after shell removed: $V" | cut -c1-160
TS="$(python3 - "$LEDGER" <<'PY'
import json,sys
ts=""
for l in open(sys.argv[1]):
    d=json.loads(l)
    if d.get("event")=="terminated" and d.get("agent_id")=="ra001": ts=d["ts"]
print(ts)
PY
)"
L retract --agent-id ra001 --ts "$TS" --reason "attack: retract a TRUE observation" --source attacker >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SB/wt/mark-opus-a" --format triple --no-write)"; echo "  judge after RETRACTION of a true observation: $V" | cut -c1-200
echo "  -> can a retraction make a dead owner ALIVE? $(printf '%s' "$V" | grep -q '^ALIVE' && echo YES || echo 'no (ALIVE needs a held lock)')"
echo "  record terminated --once after the retraction:"; L record terminated --agent-id ra001 --worktree "$SB/wt/mark-opus-a" --reason "re-witnessed" --witness reaper-observation --once | cut -c1-120

echo; echo "=== B. a HAND-APPENDED retracted row (printf, no verb, any source) — is it honored?"
add_native rb001
L record registered --teammate mark-opus-b --agent-id rb001 --session-id sess-b --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" --worktree "$SB/wt/mark-opus-b" --branch cc/mark-opus-b --class hand-rolled --source detect-nonnative-worktree.sh >/dev/null
L record terminated --agent-id rb001 --teammate mark-opus-b --session-id sess-b --worktree "$ENTITY/.claude/worktrees/agent-rb001" --reason "observed unlocked" --witness reaper-observation >/dev/null
git -C "$ENTITY" worktree remove --force "$ENTITY/.claude/worktrees/agent-rb001"
V="$(L judge --entity "$ENTITY" --worktree "$SB/wt/mark-opus-b" --format triple --no-write)"; echo "  before: $V" | cut -c1-120
TSB="$(grep '"agent_id": "rb001"' "$LEDGER" | grep terminated | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["ts"])')"
printf '{"event": "retracted", "agent_id": "rb001", "retracts_ts": "%s", "source": "anybody", "ts": "x"}\n' "$TSB" >> "$LEDGER"
V="$(L judge --entity "$ENTITY" --worktree "$SB/wt/mark-opus-b" --format triple --no-write)"; echo "  after a hand-written retracted row: $V" | cut -c1-160

echo; echo "=== C. the retract verb's CLI surface: can 'record' write a retracted row?"
L record retracted --agent-id rb001 2>&1 | tail -1 | cut -c1-160

echo; echo "=== D. two terminated rows with the SAME ts for one agent — can either be retracted?"
printf '{"event": "terminated", "agent_id": "rd001", "witness": "reaper-observation", "reason": "dup", "ts": "2026-01-01T00:00:00+00:00"}\n' >> "$LEDGER"
printf '{"event": "terminated", "agent_id": "rd001", "witness": "reaper-observation", "reason": "dup", "ts": "2026-01-01T00:00:00+00:00"}\n' >> "$LEDGER"
L retract --agent-id rd001 --ts "2026-01-01T00:00:00+00:00" --reason x; echo "  rc=$?"

echo; echo "=== E. retract a reaper-observation while the shell is STILL registered and unlocked (the observation was true and still is)"
add_native re001
L record registered --teammate mark-opus-e --agent-id re001 --session-id sess-e --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" --worktree "$SB/wt/mark-opus-e" --branch cc/mark-opus-e --class hand-rolled --source detect-nonnative-worktree.sh >/dev/null
L record registered --teammate mark-opus-e --agent-id re001 --session-id sess-e --session-pid "$$" --pid-start "$MY_START" --repo "$ENTITY" --worktree "$ENTITY/.claude/worktrees/agent-re001" --class native --source detect-nonnative-worktree.sh >/dev/null
L judge --entity "$ENTITY" --worktree "$SB/wt/mark-opus-e" --format triple >/dev/null
TSE="$(grep '"agent_id": "re001"' "$LEDGER" | grep '"terminated"' | head -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["ts"])')"
N0=$(count_term)
L retract --agent-id re001 --ts "$TSE" --reason "attack" >/dev/null
V="$(L judge --entity "$ENTITY" --worktree "$SB/wt/mark-opus-e" --format triple)"; echo "  judge (write ON) after retraction, shell still unlocked: $V" | cut -c1-120
echo "  terminated rows $N0 -> $(count_term) (a fresh observation re-witnessed: expected +1)"
