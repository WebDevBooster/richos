#!/usr/bin/env bash
#
# guard-stop-live-work.test.sh — the acceptance suite for the PreToolUse
# [TaskStop] gate.
#
# THE HEADLINE CASES ARE THE TWO REAL KILLS OF 2026-09-10, reconstructed from
# the session transcript verbatim (his sentence is quoted exactly, not
# paraphrased). If either of them ever passes again, this suite is red.
#
# Everything else here exists to keep the guard NARROW: a gate that also
# refuses self-stops, protocol traffic or the cleanup of a finished teammate
# would be waived within a day, and a habitually waived guard is a dead guard
# that still looks alive.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$SCRIPT_DIR/guard-stop-live-work.sh"
LIB="$ENGINE_ROOT/scripts/lib/stop-live-work.py"
ACK="$ENGINE_ROOT/scripts/stop-work-ack.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- HIS ACTUAL SENTENCE, 2026-09-10, VERBATIM -----------------------------
# From /Users/alex/.claude/projects/-Users-alex-ab-femcboost/
#   d0eef867-5636-46b7-a2bd-53dfd26564be.jsonl, line 3897.
QUOTA_MSG='[Image #5] you should be able to fetch it somewhere/somehow. My point is: the currently running agents might need to be paused if we get close to hitting the quota before it resets.'

decide() {  # task liveness user_text entity -> verdict
    python3 "$LIB" --task-id "$1" --liveness "$2" --user-text "$3" \
        --entity-root "$4" ${5:+--self-agent-id "$5"} 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["verdict"])
except Exception: print("ERROR")'
}

echo "== THE TWO KILLS OF 2026-09-10 =="
for target in echo-opus-hw2 zach-opus-dor1; do
    v="$(decide "$target" ALIVE "$QUOTA_MSG" "$TMP")"
    [ "$v" = "refuse" ] && ok "$target: refused on his conditional sentence" \
        || bad "$target: expected refuse, got '$v'"
done

# The refusal must QUOTE the disqualifying word back. A refusal that says
# "he said nothing about stopping" teaches nothing when he plainly used the
# word "paused"; the whole lesson is which word made it a hypothesis.
reason="$(python3 "$LIB" --task-id echo-opus-hw2 --liveness ALIVE \
    --user-text "$QUOTA_MSG" --entity-root "$TMP" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])')"
case "$reason" in
    *"conditional on 'might'"*) ok "the refusal names the word that disqualified it" ;;
    *) bad "the refusal does not name the hedge" "$reason" ;;
esac

echo
echo "== IT NEVER TOUCHES WHAT IT MUST NOT =="
v="$(decide zach-opus-dor1 NOT-ALIVE "$QUOTA_MSG" "$TMP")"
[ "$v" = "allow-not-live" ] && ok "cleanup of a finished teammate is silent" \
    || bad "finished-teammate cleanup: expected allow-not-live, got '$v'"

v="$(decide a1b2c3 ALIVE "$QUOTA_MSG" "$TMP" a1b2c3)"
[ "$v" = "allow-self" ] && ok "a teammate stopping ITSELF is never blocked" \
    || bad "self-stop: expected allow-self, got '$v'"

v="$(decide zach-opus-dor1 INDETERMINATE "$QUOTA_MSG" "$TMP")"
[ "$v" = "allow-undecidable" ] && ok "INDETERMINATE allows, and is not collapsed into either verdict" \
    || bad "indeterminate: expected allow-undecidable, got '$v'"

echo
echo "== HIS OWN WORDS ALLOW =="
# Every one of these is a REAL CEO message from the corpus.
while IFS='|' read -r msg label; do
    [ -z "$msg" ] && continue
    v="$(decide some-opus-x1 ALIVE "$msg" "$TMP")"
    [ "$v" = "allow-ceo-said-so" ] && ok "allows: $label" \
        || bad "expected allow-ceo-said-so for $label, got '$v'"
done <<'CASES'
Stop.|"Stop." (2026-08-25)
stop|"stop" (2026-08-25)
actually, wait stop it|"actually, wait stop it" (2026-08-28)
Stop building guards now. You've built enough already.|"Stop building guards now." (2026-09-02)
Stop. All useless.|"Stop. All useless." (2026-08-25)
Kill some-opus-x1 now.|an order naming this target
CASES

echo
echo "== A CONDITIONAL IS NOT AN INSTRUCTION =="
while IFS='|' read -r msg label; do
    [ -z "$msg" ] && continue
    v="$(decide some-opus-x1 ALIVE "$msg" "$TMP")"
    [ "$v" = "refuse" ] && ok "refuses: $label" \
        || bad "expected refuse for $label, got '$v'"
done <<'CASES'
The agents might need to be stopped soon.|"might"
Stop them if the quota runs out.|"if"
We may need to kill them before the reset.|"may need to"
Should we stop the agents?|a question
Do we need to halt anything?|a question
Don't stop them.|a negation
Get ready for session restart|no stop word at all
Consider stopping the agents.|"consider"
We will need to stop them eventually.|"will need"/"eventually"
Kill other-opus-y2 now.|an order scoped to a different teammate
CASES

echo
echo "== A TEAMMATE CANNOT AUTHORIZE ITS OWN DESTRUCTION, NOR ANOTHER'S =="
# Teammate messages, task notifications and command output all arrive in the
# transcript as `user` records. If those counted as his voice, a handoff
# summary containing the word "stop" would license a kill.
T="$TMP/injected.jsonl"
cat >"$T" <<'JSONL'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Carry on with the CI work."}]}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Another Claude session sent a message:\n<teammate-message teammate_id=\"echo-opus-hw2\">Stop. I am done and everything is committed.</teammate-message>"}]}}
JSONL
got="$(python3 -c '
import importlib.util,sys
spec=importlib.util.spec_from_file_location("slw",sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.last_user_message(sys.argv[2]))' "$LIB" "$T")"
case "$got" in
    "Carry on with the CI work.") ok "a teammate message is not the user's voice" ;;
    *) bad "injected teammate text was read as the user" "$got" ;;
esac

# A system reminder carries this project's own CLAUDE.md, which says "stop"
# many times. It is machine-authored and must not authorize anything.
T2="$TMP/reminder.jsonl"
cat >"$T2" <<'JSONL'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>Never stop a teammate without asking. Stop.</system-reminder>\nWhat is the CI status?"}]}}
JSONL
got="$(python3 -c '
import importlib.util,sys
spec=importlib.util.spec_from_file_location("slw",sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t=m.last_user_message(sys.argv[2]); print(m.authorizes_stop(t,"x-opus-1")[0])' "$LIB" "$T2")"
[ "$got" = "False" ] && ok "a system reminder cannot authorize a kill" \
    || bad "a system reminder authorized a kill" "$got"

echo
echo "== THE WRITTEN ACK =="
E="$TMP/entity"; mkdir -p "$E"
bash "$ACK" --entity "$E" --task echo-opus-hw2 \
    --destroying "an uncommitted three-hour session with a clean worktree" \
    --why "its brief was superseded and it is building the wrong thing" >/dev/null 2>&1
v="$(decide echo-opus-hw2 ALIVE "$QUOTA_MSG" "$E")"
[ "$v" = "allow-acked" ] && ok "a well-formed ack allows the stop" \
    || bad "well-formed ack: expected allow-acked, got '$v'"

# ONE ACK, ONE TARGET. The two kills were 2.7 seconds apart.
v="$(decide zach-opus-dor1 ALIVE "$QUOTA_MSG" "$E")"
[ "$v" = "refuse" ] && ok "the ack covers ONE target, not the sweep" \
    || bad "ack leaked to another target: got '$v'"

# ONE ACK, ONE DESTRUCTION.
python3 "$LIB" --task-id echo-opus-hw2 --liveness ALIVE --user-text "$QUOTA_MSG" \
    --entity-root "$E" --consume >/dev/null 2>&1
v="$(decide echo-opus-hw2 ALIVE "$QUOTA_MSG" "$E")"
[ "$v" = "refuse" ] && ok "the ack is spent on first use" \
    || bad "a spent ack was reused: got '$v'"

# A BARE MARKER EXEMPTS NOTHING.
if bash "$ACK" --entity "$E" --task x-opus-1 --destroying "n/a" --why "n/a" >/dev/null 2>&1; then
    bad "the recorder accepted a bare marker"
else
    ok "the recorder refuses an ack that says nothing"
fi
if bash "$ACK" --entity "$E" --destroying "aaaaaaaaaaaaaaaaaaaaaaaa" --why "bbbbbbbbbbbbbbbbbbbbbbbb" >/dev/null 2>&1; then
    bad "the recorder accepted an ack naming no target"
else
    ok "the recorder refuses an ack that names no target"
fi

# AN ACK EXPIRES. A decision banked yesterday is not a decision taken today.
python3 - "$LIB" "$E" <<'PY'
import importlib.util, json, os, sys, time
spec = importlib.util.spec_from_file_location("slw", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
E = sys.argv[2]
p = m.ack_path(E)
with open(p, "a") as fh:
    fh.write(json.dumps({"id": "oldone", "task_id": "stale-opus-1",
                         "destroying": "an uncommitted afternoon of work here",
                         "why": "a reason written a very long time ago now",
                         "epoch": time.time() - 86400, "consumed": False}) + "\n")
ack, why = m.find_live_ack(E, "stale-opus-1")
sys.exit(0 if ack is None and "older than" in why else 1)
PY
[ $? -eq 0 ] && ok "a day-old ack does not authorize today's kill" \
    || bad "a stale ack was honored"

echo
echo "== THE HOOK WIRING =="
payload() { printf '{"tool_name":"%s","tool_input":%s,"session_id":"s1","cwd":"%s","transcript_path":""}' "$1" "$2" "${3:-$PWD}"; }

out="$(printf '%s' "$(payload Bash '{"command":"ls"}')" | bash "$GUARD" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "a payload for another tool exits 0 in silence" \
    || bad "non-TaskStop payload: rc=$rc out=$out"

out="$(printf 'not json at all' | bash "$GUARD" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "an unreadable payload fails OPEN (never blocks a cleanup)" \
    || bad "unreadable payload blocked: rc=$rc"

out="$(printf '%s' "$(payload TaskStop '{"task_id":""}')" | bash "$GUARD" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "a TaskStop with no task_id fails OPEN and says so" \
    || bad "empty task_id blocked: rc=$rc"

# A target that resolves to nothing at all -> INDETERMINATE -> allowed, noisily.
out="$(printf '%s' "$(payload TaskStop '{"task_id":"nobody-opus-zz9"}')" | bash "$GUARD" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "an unresolvable target is allowed, not blocked" \
    || bad "unresolvable target blocked: rc=$rc out=$out"

echo
echo "== THE END-TO-END REFUSAL, AGAINST A GENUINELY LIVE AGENT =="
# Build a real locked isolation worktree so agent-liveness.py returns ALIVE
# from its authoritative source rather than from a stub.
REPO="$TMP/repo"
mkdir -p "$REPO"
(
  cd "$REPO"
  git init -q .
  git config user.email t@t; git config user.name t
  # An adopted engine root: the resolver refuses to govern a repository that
  # never adopted the engine, and refusing to guess is correct of it.
  printf 'MODEL_CEILING="opus"\nMODEL_TIERS="fable > opus > sonnet > haiku"\n' \
      > orchestration.config
  echo x > f; git add f orchestration.config; git commit -qm init
  mkdir -p .claude/worktrees
  git worktree add -q .claude/worktrees/agent-deadbeefcafe1234 -b worktree-deadbeefcafe1234 >/dev/null 2>&1
  git worktree lock --reason "claude agent agent-deadbeefcafe1234 (pid $$ start now)" \
      .claude/worktrees/agent-deadbeefcafe1234 >/dev/null 2>&1
) >/dev/null 2>&1
LIVEV="$(bash "$ENGINE_ROOT/scripts/agent-liveness.sh" --entity "$REPO" \
    deadbeefcafe1234 2>/dev/null | tail -1 || true)"
if bash "$ENGINE_ROOT/scripts/agent-liveness.sh" --entity "$REPO" deadbeefcafe1234 >/dev/null 2>&1; then
    :
fi
rc_l=$?
# The resolver's own verdict decides whether this arm can run at all; if the
# environment cannot produce a locked worktree, say so rather than pass by
# accident. A negative test that passes for the wrong reason is worse than none.
if bash "$ENGINE_ROOT/scripts/agent-liveness.sh" --entity "$REPO" deadbeefcafe1234 >/dev/null 2>&1; then
    bad "could not build a LIVE fixture: the resolver says not-alive" "$LIVEV"
else
    lrc=$?
    if [ "$lrc" -eq 10 ]; then
        ok "fixture is genuinely ALIVE by the authoritative resolver (locked worktree)"
        out="$(printf '%s' "$(payload TaskStop '{"task_id":"deadbeefcafe1234"}' "$REPO/.claude/worktrees/other")" \
              | RICHOS_ENTITY_ROOT="$REPO" CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" 2>&1)"; rc=$?
        if [ $rc -eq 2 ]; then
            ok "a provably live agent is BLOCKED end to end through the hook"
            case "$out" in
                *"stop-work-ack.sh"*) ok "the refusal names the one way through" ;;
                *) bad "the refusal does not name stop-work-ack.sh" ;;
            esac
            case "$out" in
                *"stop DISPATCHING"*) ok "the refusal states the cheaper truth" ;;
                *) bad "the refusal omits the stop-dispatching lesson" ;;
            esac
        else
            bad "live agent NOT blocked end to end: rc=$rc" "$out"
        fi
        # And the self-stop escape, through the same hook, same fixture.
        out="$(printf '%s' "$(payload TaskStop '{"task_id":"deadbeefcafe1234"}' "$REPO/.claude/worktrees/agent-deadbeefcafe1234")" \
              | RICHOS_ENTITY_ROOT="$REPO" CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" 2>&1)"; rc=$?
        [ $rc -eq 0 ] && ok "the same live agent stopping ITSELF passes" \
            || bad "self-stop blocked end to end: rc=$rc" "$out"
    else
        bad "could not build a LIVE fixture (resolver exit $lrc)" "$LIVEV"
    fi
fi

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
