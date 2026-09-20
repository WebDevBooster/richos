#!/usr/bin/env bash
#
# stop.test.sh — THE BEHAVIOR OF `scripts/stop.sh`, ON A FIXTURE BUILT THE WAY
#                THE REAL THING IS BUILT.
#
# The fixture is four teammates in a throwaway pair of git repositories, with a
# throwaway workspace registry and a throwaway governed repository:
#
#   alpha-opus-t1     RUNNING, nothing committed, clean tree
#   bravo-opus-t1     RUNNING, one commit on its branch and one uncommitted file
#   charlie-opus-t1   RUNNING, and NEVER NAMED — the control. Every case that
#                     says "only the named ones were touched" is worth nothing
#                     without a third agent sitting there to be touched.
#   delta-opus-t1     FINISHED, and its isolation worktree is STILL LOCKED by a
#                     live pid. The only thing that makes it not-alive is the
#                     registry record, which is exactly how the real resolver
#                     decides (point 11) — a fixture where "finished" and
#                     "unlocked" coincide would prove nothing about which of
#                     the two was read.
#
#   S1   two of the three running teammates are named -> exactly two acks, and
#        the control has none.
#   S2   the ack SAYS SOMETHING: the CEO's sentence verbatim, and the measured
#        state of the branch (S2W for his words, S2D for the measurement).
#   S3   the finished one is reported and SKIPPED — no ack, and the run still
#        exits 0. A name that is not running is not an error.
#   S4   no names -> usage, nothing written, and the message names the sentence
#        that forbids an everything mode.
#   S5   no --ceo-word -> refused, nothing written.
#   S6   --dry-run writes NOTHING and still prints the stop.
#   S7   there is no all/every/enumerate MODE in the shipped source.
#   S8   THE END-TO-END PROPERTY: after stop.sh, the TaskStop guard's own
#        predicate answers `allow-acked` for the named teammate on a turn whose
#        user text carries no stop order at all. This is the case the whole
#        command exists for.
#   S9   a nine-character order from the CEO ("stop them") still produces a
#        valid ack. The floor in stop-work-ack.sh is 20 characters and his words
#        are never padded to reach it.
#   S10  the TaskStop targets are printed once per name, in the order given.
#   S11  a running teammate is acked under BOTH spellings of its one target —
#        its name and its agent id — because find_live_ack matches exactly and
#        6% of real TaskStop calls carry the id.
#   S12  the run does not mutate the workspace registry.
#   S13  a name nobody knows is UNDECIDED and exits 1 — with its ack written,
#        because an exit code reports what is unknown and never withholds a
#        stop.
#   M    the mutation harness: every property above has been watched fail.
#
# Exit 0 = every case passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STOP="$SCRIPT_DIR/stop.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); return 0; }

[ -f "$STOP" ] || { echo "FATAL: missing $STOP" >&2; exit 1; }

# The allocator, never a bare mktemp: scripts/lib/scratch.sh, and the 105 GB
# night in its header. The trap is an optimization; the ledger is the mechanism.
# shellcheck source=lib/scratch.sh
. "$ENGINE_ROOT/scripts/lib/scratch.sh"
SANDBOX="$(scratch_new stop-test)" || { echo "FATAL: could not allocate scratch" >&2; exit 1; }
trap 'scratch_release "$SANDBOX" >/dev/null 2>&1 || rm -rf "$SANDBOX"' EXIT

# Nothing here may read or write the operator's real state.
export RICHOS_WORKSPACES_DIR="$SANDBOX/registry"
unset CLAUDE_SESSION_ID CLAUDE_PROJECT_DIR RICHOS_ENTITY_ROOT RICHOS_STOP_ENTITY 2>/dev/null || true
export GIT_CONFIG_NOSYSTEM=1
export HOME="$SANDBOX/home"; mkdir -p "$HOME"

FX="$SANDBOX/fx"
ENTITY="$FX/entity"
WORK="$FX/work"
LEDGER="$ENTITY/.claude/state/stop-work-acks.jsonl"

RUNNING_PID=$$        # this suite's own pid: alive for as long as the fixture is

echo "=== stop.sh tests ==="

# ---------------------------------------------------------------------------
# the fixture
# ---------------------------------------------------------------------------
gitq() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

build_fixture() {
    rm -rf "$FX"
    mkdir -p "$ENTITY" "$WORK" "$FX/wt" "$ENTITY/.claude/state"

    for r in "$ENTITY" "$WORK"; do
        gitq "$r" init -q -b main
        gitq "$r" config user.email "fixture@example.invalid"
        gitq "$r" config user.name "stop.test fixture"
        echo "seed" > "$r/seed.txt"
        gitq "$r" add seed.txt
        gitq "$r" commit -q -m "seed"
    done

    # Four teammates. Each gets a cc/ workspace in the work repository and a
    # native isolation worktree in the governed one, locked with a LIVE pid —
    # the shape agent-liveness.py reads.
    local i=0
    for name in alpha-opus-t1 bravo-opus-t1 charlie-opus-t1 delta-opus-t1; do
        i=$((i + 1))
        local aid="a${i}1111111111111a${i}"
        printf '%s\n' "$aid" > "$FX/id-$name"
        gitq "$WORK" worktree add -q -b "cc/$name" "$FX/wt/$name" main
        gitq "$ENTITY" worktree add -q -b "worktree-agent-$aid" \
            "$ENTITY/.claude/worktrees/agent-$aid" main
        git -C "$ENTITY" worktree lock \
            --reason "claude agent agent-$aid (pid $RUNNING_PID start Sun Sep 20 05:30:00 2026)" \
            "$ENTITY/.claude/worktrees/agent-$aid" >/dev/null 2>&1
    done

    # bravo has work to lose: one commit past the integration ref, and one
    # uncommitted file. S2D reads these out of the ack.
    echo "bravo work" > "$FX/wt/bravo-opus-t1/bravo.txt"
    gitq "$FX/wt/bravo-opus-t1" add bravo.txt
    gitq "$FX/wt/bravo-opus-t1" commit -q -m "bravo: the commit that would survive"
    echo "not committed" > "$FX/wt/bravo-opus-t1/uncommitted.txt"

    ENTITY="$ENTITY" WORK="$WORK" FX="$FX" python3 - <<'PY'
import importlib.util, os, sys, time

engine = os.environ.get("STOP_TEST_ENGINE") or ""
spec = importlib.util.spec_from_file_location("fx_ws", os.path.join(engine, "mega-lander", "workspaces.py"))
ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)

entity, work, fx = os.environ["ENTITY"], os.environ["WORK"], os.environ["FX"]
ws.record_integration(work, "main", why="the stop.sh fixture")
ws.record_integration(entity, "main", why="the stop.sh fixture")

for name in ("alpha-opus-t1", "bravo-opus-t1", "charlie-opus-t1", "delta-opus-t1"):
    aid = open(os.path.join(fx, "id-" + name)).read().strip()
    key = ws.named_key("", name)
    rec = ws.new_record(key, name=name, session_id="", agent_id=aid, workspaces=[
        {"kind": "cc", "repo": ws.main_checkout(work), "path": os.path.join(fx, "wt", name),
         "branch": "cc/" + name, "created": True, "registered_at": ws.iso()},
        {"kind": "native", "repo": ws.main_checkout(entity),
         "path": os.path.join(entity, ".claude", "worktrees", "agent-" + aid),
         "branch": "worktree-agent-" + aid, "registered_at": ws.iso()},
    ])
    ws._bind_body_of_work(rec, work)
    ws._bind_body_of_work(rec, entity)
    if name == "delta-opus-t1":
        # FINISHED by the registry, and its lock is still held by a live pid.
        rec["end"] = {"at": ws.now(), "signal": "stopped", "detail": "the fixture ended its run"}
    ws.save_agent(rec)
PY
}

STOP_TEST_ENGINE="$ENGINE_ROOT"
export STOP_TEST_ENGINE
build_fixture

ledger_count() { # <task-id> -> number of ack lines for it
    [ -f "$LEDGER" ] || { echo 0; return; }
    TASK="$1" python3 - "$LEDGER" <<'PY'
import json, os, sys
n = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if (d.get("task_id") or "") == os.environ["TASK"]:
        n += 1
print(n)
PY
}

ledger_field() { # <task-id> <field> -> the newest value
    [ -f "$LEDGER" ] || { echo ""; return; }
    TASK="$1" FIELD="$2" python3 - "$LEDGER" <<'PY'
import json, os, sys
best = None
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if (d.get("task_id") or "") == os.environ["TASK"]:
        if best is None or float(d.get("epoch") or 0) >= float(best.get("epoch") or 0):
            best = d
print((best or {}).get(os.environ["FIELD"]) or "")
PY
}

run_stop() { # <args...> -> OUT (stdout+stderr), RC. Never from inside the entity.
    OUT="$(cd "$SANDBOX" && bash "$STOP" "$@" --entity "$ENTITY" 2>&1)"
    RC=$?
}

# ---------------------------------------------------------------------------
# S1 / S11 / S2 — the two named, the third untouched, and what the ack says
# ---------------------------------------------------------------------------
CEO_WORD="And those 3 are gonna keep running and burning my tokens OR WHAT???"
run_stop alpha-opus-t1 bravo-opus-t1 --ceo-word "$CEO_WORD"
S1_RC=$RC; S1_OUT="$OUT"

A_N="$(ledger_count alpha-opus-t1)"
B_N="$(ledger_count bravo-opus-t1)"
C_N="$(ledger_count charlie-opus-t1)"
D_N="$(ledger_count delta-opus-t1)"

if [ "$A_N" = "1" ] && [ "$B_N" = "1" ] && [ "$C_N" = "0" ] && [ "$D_N" = "0" ] && [ "$S1_RC" = "0" ]; then
    ok "S1  naming two running teammates writes an ack for exactly those two and touches no other (control charlie: 0)"
else
    bad "S1  acks alpha=$A_N bravo=$B_N charlie=$C_N delta=$D_N rc=$S1_RC, expected 1/1/0/0 rc=0" "$S1_OUT"
fi

A_ID="$(cat "$FX/id-alpha-opus-t1")"
if [ "$(ledger_count "$A_ID")" = "1" ]; then
    ok "S11 the one target is acked under both of its spellings — the name and the agent id ($A_ID)"
else
    bad "S11 no ack keyed on the agent id $A_ID; a TaskStop made with the id form would be refused" "$S1_OUT"
fi

WHY_TEXT="$(ledger_field alpha-opus-t1 why)"
case "$WHY_TEXT" in
    *"$CEO_WORD"*) ok "S2W the ack's --why carries the CEO's sentence verbatim" ;;
    *) bad "S2W the CEO's words are not in the ack: '$WHY_TEXT'" ;;
esac

DESTROY_B="$(ledger_field bravo-opus-t1 destroying)"
if printf '%s' "$DESTROY_B" | grep -q "1 commit(s)" \
   && printf '%s' "$DESTROY_B" | grep -q "1 uncommitted path(s)"; then
    ok "S2D the ack's --destroying is a MEASUREMENT: bravo's one commit and one uncommitted path, read from git"
else
    bad "S2D the ack does not carry what would be lost: '$DESTROY_B'"
fi

DESTROY_A="$(ledger_field alpha-opus-t1 destroying)"
if printf '%s' "$DESTROY_A" | grep -q "0 commits past" \
   && printf '%s' "$DESTROY_A" | grep -q "clean tree"; then
    ok "S2Z  an agent with nothing to lose is measured as such, rather than described"
else
    bad "S2Z  alpha's ack does not say it holds nothing: '$DESTROY_A'"
fi

# ---------------------------------------------------------------------------
# S8 — the end-to-end property: the guard's own predicate now allows the stop
# ---------------------------------------------------------------------------
PRED="$ENGINE_ROOT/scripts/lib/stop-live-work.py"
V_JSON="$(python3 "$PRED" --task-id alpha-opus-t1 --liveness ALIVE \
    --entity-root "$ENTITY" --user-text "what is taking so long with the build" 2>&1)"
V="$(printf '%s' "$V_JSON" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("verdict") or "")
except Exception: print("")' 2>/dev/null)"
if [ "$V" = "allow-acked" ]; then
    ok "S8  the TaskStop guard's own predicate answers allow-acked on a turn carrying no stop order — the stop goes through"
else
    bad "S8  the guard would answer '$V', not allow-acked; the ack this command writes is not the one the guard reads" "$V_JSON"
fi

# ---------------------------------------------------------------------------
# S10 — one TaskStop line per name, in the order given
# ---------------------------------------------------------------------------
ORDER="$(printf '%s\n' "$S1_OUT" | grep -o 'TaskStop(task_id="[^"]*")' | sed 's/.*"\(.*\)")/\1/' | tr '\n' ' ')"
if [ "$ORDER" = "alpha-opus-t1 bravo-opus-t1 " ]; then
    ok "S10 the TaskStop targets are printed once each, in the order the CEO's words named them"
else
    bad "S10 printed targets were '[$ORDER]', expected 'alpha-opus-t1 bravo-opus-t1 '" "$S1_OUT"
fi

# ---------------------------------------------------------------------------
# S12 — the registry is not mutated
# ---------------------------------------------------------------------------
# CONTENT, not size: a mutation that rewrites a record in place without
# changing its length would pass a size comparison, and "the registry is
# untouched" is exactly the claim that must not be provable by accident.
reg_fingerprint() {
    find "$RICHOS_WORKSPACES_DIR" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s  %s\n' "$(shasum "$f" 2>/dev/null | cut -d' ' -f1)" "$f"
    done
}
BEFORE="$(reg_fingerprint)"
run_stop charlie-opus-t1 --ceo-word "$CEO_WORD" --dry-run
AFTER="$(reg_fingerprint)"
# THE POSITIVE PROBE. "Nothing changed" is also what a fingerprint that reads
# nothing reports, and this suite has no mutant for S12 (the natural one cannot
# fail in this fixture — stop.mutation.sh says so in its header). So the
# fingerprint is made to notice a real write before its silence is believed.
STOP_TEST_ENGINE="$ENGINE_ROOT" python3 - <<'PY' >/dev/null 2>&1
import importlib.util, os
engine = os.environ["STOP_TEST_ENGINE"]
spec = importlib.util.spec_from_file_location("probe_ws", os.path.join(engine, "mega-lander", "workspaces.py"))
ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
ws.save_agent(ws.new_record(ws.named_key("", "probe-opus-t0"), name="probe-opus-t0"))
PY
PROBE="$(reg_fingerprint)"

if [ "$BEFORE" = "$AFTER" ] && [ "$PROBE" != "$BEFORE" ]; then
    ok "S12 a run does not mutate the workspace registry — it reads, it never observes (and the fingerprint provably notices a write)"
elif [ "$PROBE" = "$BEFORE" ]; then
    bad "S12 the fingerprint did not notice a record being written, so its silence proves nothing"
else
    bad "S12 the registry changed under a dry run" "$(diff <(printf '%s' "$BEFORE") <(printf '%s' "$AFTER") | head -5)"
fi

# ---------------------------------------------------------------------------
# S6 — --dry-run writes nothing, and still prints the stop
# ---------------------------------------------------------------------------
C_BEFORE="$(ledger_count charlie-opus-t1)"
run_stop charlie-opus-t1 --ceo-word "$CEO_WORD" --dry-run
S6_OUT="$OUT"; S6_RC=$RC
C_AFTER="$(ledger_count charlie-opus-t1)"
if [ "$C_BEFORE" = "0" ] && [ "$C_AFTER" = "0" ] \
   && printf '%s' "$S6_OUT" | grep -q 'TaskStop(task_id="charlie-opus-t1")'; then
    ok "S6  --dry-run writes no ack and still prints the exact stop to make"
else
    bad "S6  dry run: acks before=$C_BEFORE after=$C_AFTER rc=$S6_RC" "$S6_OUT"
fi

# ---------------------------------------------------------------------------
# S3 — the finished teammate is reported and skipped
# ---------------------------------------------------------------------------
run_stop delta-opus-t1 --ceo-word "$CEO_WORD"
S3_OUT="$OUT"; S3_RC=$RC
D_AFTER="$(ledger_count delta-opus-t1)"
if [ "$D_AFTER" = "0" ] && [ "$S3_RC" = "0" ] \
   && printf '%s' "$S3_OUT" | grep -q "NOT RUNNING" \
   && printf '%s' "$S3_OUT" | grep -qi "skipped"; then
    ok "S3  a name that is not running is reported and SKIPPED — no ack, exit 0, and its lock was held the whole time"
else
    bad "S3  finished teammate: acks=$D_AFTER rc=$S3_RC" "$S3_OUT"
fi

# ---------------------------------------------------------------------------
# S13 — a name nobody knows
# ---------------------------------------------------------------------------
run_stop nobody-opus-t9 --ceo-word "$CEO_WORD"
S13_OUT="$OUT"; S13_RC=$RC
if [ "$S13_RC" = "1" ] && [ "$(ledger_count nobody-opus-t9)" = "1" ] \
   && printf '%s' "$S13_OUT" | grep -q "UNDECIDED"; then
    ok "S13 an unknown name is UNDECIDED and exits 1, with its ack written — the exit code reports, it never withholds a stop"
else
    bad "S13 unknown name: rc=$S13_RC acks=$(ledger_count nobody-opus-t9)" "$S13_OUT"
fi

# ---------------------------------------------------------------------------
# S9 — a nine-character order from the CEO
# ---------------------------------------------------------------------------
build_fixture
run_stop alpha-opus-t1 --ceo-word "stop them"
S9_RC=$RC; S9_OUT="$OUT"
S9_WHY="$(ledger_field alpha-opus-t1 why)"
if [ "$(ledger_count alpha-opus-t1)" = "1" ] && [ "$S9_RC" = "0" ] \
   && printf '%s' "$S9_WHY" | grep -q '"stop them"'; then
    ok "S9  a nine-character order still produces a valid ack — his words are quoted, never padded to a floor"
else
    bad "S9  short order: rc=$S9_RC why='$S9_WHY'" "$S9_OUT"
fi

# ---------------------------------------------------------------------------
# S4 / S5 — the two refusals
# ---------------------------------------------------------------------------
build_fixture
run_stop --ceo-word "$CEO_WORD"
S4_RC=$RC; S4_OUT="$OUT"
if [ "$S4_RC" = "2" ] && [ ! -s "$LEDGER" ] \
   && printf '%s' "$S4_OUT" | grep -q "EVERYTHING RUNNING"; then
    ok "S4  no names: refused with usage, nothing written, and the message quotes the sentence that forbids an everything mode"
else
    bad "S4  no names: rc=$S4_RC (expected 2), ledger $( [ -s "$LEDGER" ] && echo "NOT empty" || echo empty)" "$S4_OUT"
fi

run_stop alpha-opus-t1
S5_RC=$RC; S5_OUT="$OUT"
if [ "$S5_RC" = "2" ] && [ ! -s "$LEDGER" ]; then
    ok "S5  no --ceo-word: refused, nothing written — a stop nobody can quote is not his order"
else
    bad "S5  missing --ceo-word: rc=$S5_RC (expected 2)" "$S5_OUT"
fi

# ---------------------------------------------------------------------------
# S7 — there is no everything mode in the shipped source
# ---------------------------------------------------------------------------
# The grep is over FLAGS and enumerating CALLS, not over prose: this file and
# both sources discuss the mode at length, and a test that flagged the
# discussion would be waived the day it landed. `all_agents(...)` used to look
# a name up is not a mode; a flag named all/every/everything/sweep/each is.
S7_HITS="$(
    { grep -nE '(--(all|every|everything|sweep|each|any)\b)' "$STOP" "$SCRIPT_DIR/lib/stop.py" \
        | grep -vE '^\s*[0-9]+:\s*#' | grep -v '^[^:]*:[0-9]*:#'
      grep -n 'enumerate_all' "$STOP" "$SCRIPT_DIR/lib/stop.py"
    } 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*(#|//)' || true
)"
if [ -z "$S7_HITS" ]; then
    ok "S7  no all/every/enumerate mode exists in stop.sh or lib/stop.py — the design, asserted rather than remembered"
else
    bad "S7  an everything mode appeared in the source" "$S7_HITS"
fi

# ---------------------------------------------------------------------------
# THE MUTATION HARNESS
# ---------------------------------------------------------------------------
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$SCRIPT_DIR/stop.mutation.sh" ]; then
    echo ""
    echo "=== running the mutation harness ==="
    if bash "$SCRIPT_DIR/stop.mutation.sh"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL  M. the mutation harness found a property this suite does not actually prove"
    fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== stop.sh tests: all $PASS passed ==="
    exit 0
fi
echo "=== stop.sh tests: $PASS passed, $FAIL FAILED ==="
exit 1
