#!/usr/bin/env bash
#
# guard-stated-actions.test.sh — regression tests for the Stop-time gate that
# refuses a turn whose REPORT does not match its ACTIONS
# (scripts/hooks/guard-stated-actions.sh + .py).
#
# THE REAL FAILURES ARE REPLAYED HERE BY SHAPE, WITH THE REAL SENTENCES.
#   The two ARM 1 sentences are the lead's own words from 2026-09-02 and are
#   short enough to carry; everything around them is invented. The measurement
#   that decided which arms block was run against the real transcripts on disk
#   and only its NUMBERS are recorded, in the hook header and the corpus file.
#
# Covers:
#   ARM 1 — STATED, NOT TAKEN
#     (a)  "Zach builds it tomorrow." + Bash only               -> exit 2, names the clause
#     (a2) "Frank breaks it first, and I want him attacking
#           whether ... still ... now that ..." + Bash only     -> exit 2
#          (the clause split keeps the subject clause; the `whether`, `still`
#           and `now that` of the SECOND clause do not exempt the first)
#     (b)  same sentence + Agent(frank) this turn                -> exit 0
#     (b2) role act + Agent(sage) — any dispatch discharges 1a   -> exit 0
#     (b3) role act + SendMessage to a teammate                  -> exit 0
#     (c)  "I'm dispatching Frank now." + no Agent               -> exit 2  (1b positive probe)
#     (c2) 1b + Agent(sage) — 1b is role-matched                 -> exit 2
#     (c3) 1b + Agent(frank-opus-x1)                              -> exit 0
#     (d)  "Say the word and I'll dispatch Frank."               -> exit 0  (proposal)
#     (e)  the sentence inside double quotes                     -> exit 0
#     (e2) the sentence inside a fenced ```ecs``` block           -> exit 0
#     (e3) "Frank breaks it first, I said, and ..." (reported)   -> exit 0
#     (f)  "- Zach builds it tomorrow" as a list item             -> exit 0
#     (f2) "Zach builds it — in flight now." (progress)          -> exit 0
#     (f3) "**1. Zach builds it tomorrow.**" (emphasized number) -> exit 0
#     (g)  "Frank recommends the hybrid." (report verb)          -> exit 0
#     (h)  "Art designs Bootstrap components." (bare object)     -> exit 0
#     (i)  role act, then "Want me to post the brief first?"     -> exit 0  (ends on CEO)
#     (j)  "Sage will fold it in tonight." (1c, report-only)     -> exit 0 + observation
#     (k)  role act + AskUserQuestion this turn                  -> exit 0
#     (l)  Agent only in an EARLIER prompt, role act now         -> exit 2  (turn scoping)
#     (m)  no roles on disk                                      -> exit 0  (inert, recorded)
#     (o)  "Frank breaks it the moment Sage returns."            -> exit 0  (conditional)
#     (p)  "Frank breaks it, but not tonight."                   -> exit 0  (negation)
#   ARM 2 — THE TURN THAT STOPS
#     (n)  Agent "X" finished, nothing started, no declaration   -> exit 2, names X + the form
#     (n2) same + Agent call                                      -> exit 0
#     (n3) same + backgrounded Bash                               -> exit 0
#     (n4) same + AskUserQuestion                                 -> exit 0
#     (n5) same + operator said "hold everything"                 -> exit 0
#     (n6) same + valid stop-declared: line                       -> exit 0, SHOWN as declared, not verified
#     (n7) declaration too short                                  -> exit 2 + REJECTED + why
#     (n8) declaration inside a code span                         -> exit 2
#     (n9) Agent "X" was stopped by user                          -> exit 0
#     (n10) Background command "..." completed                    -> exit 0
#     (n11) finished but <status> not completed                   -> exit 0
#   SAFETY — never strand a session
#     (r)  stop_hook_active=true, violation present               -> exit 0
#     (s)  repository has not adopted the engine                  -> exit 0, silent
#     (t)  CHECK_STATED_ACTIONS=0                                  -> exit 0 + STOOD DOWN notice
#     (u)  unparseable payload                                     -> exit 0
#     (v)  no prompt_id                                            -> exit 0, silent
#     (w)  transcript missing                                      -> exit 0
#     (x)  broken install (resolve-roots.sh absent)                -> exit 0 + banner
#     (y)  STATED_ACTIONS_ENFORCE=0                                -> exit 0 + report on stderr
#     (y2) guard-idle-land.py absent                               -> exit 0 + NOT RUNNING notice
#   RECORD
#     (z)  an observation line is appended
#
# Run directly: scripts/hooks/guard-stated-actions.test.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-stated-actions.sh"
unset CLAUDE_PROJECT_DIR

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

SANDBOX="$(mktemp -d -t guard-stated-actions.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }

PROMPT_ID="11111111-2222-3333-4444-555555555555"
OLD_PROMPT="00000000-0000-4000-8000-000000000000"

# --- the governed repository ----------------------------------------------
ENTITY="$SANDBOX/entity"
mkdir -p "$ENTITY/.claude/agents"
git -C "$ENTITY" init -q -b main . >/dev/null 2>&1
git -C "$ENTITY" config user.email t@t.t >/dev/null 2>&1
git -C "$ENTITY" config user.name t >/dev/null 2>&1
mkdir -p "$SANDBOX/nohooks"
git -C "$ENTITY" config core.hooksPath "$SANDBOX/nohooks" >/dev/null 2>&1
: > "$ENTITY/orchestration.config"
for r in frank zach sage mark art; do printf -- '---\nname: %s\n---\n' "$r" > "$ENTITY/.claude/agents/$r.md"; done
git -C "$ENTITY" add -A >/dev/null 2>&1
git -C "$ENTITY" commit -qm seed >/dev/null 2>&1

# A repository that never adopted the engine.
UNADOPTED="$SANDBOX/unadopted"
mkdir -p "$UNADOPTED"
git -C "$UNADOPTED" init -q . >/dev/null 2>&1

# An entity with NO roles at all.
NOROLES="$SANDBOX/noroles"
mkdir -p "$NOROLES"
git -C "$NOROLES" init -q -b main . >/dev/null 2>&1
git -C "$NOROLES" config user.email t@t.t >/dev/null 2>&1
git -C "$NOROLES" config user.name t >/dev/null 2>&1
git -C "$NOROLES" config core.hooksPath "$SANDBOX/nohooks" >/dev/null 2>&1
: > "$NOROLES/orchestration.config"
git -C "$NOROLES" add -A >/dev/null 2>&1
git -C "$NOROLES" commit -qm seed >/dev/null 2>&1

# --- transcript fixtures ---------------------------------------------------
# At Stop time the transcript holds the turn's tool_use records but NOT the
# final assistant text. The DSL is a JSON list:
#   {"prompt": "..."}            a real operator prompt (carries promptSource)
#   {"machine": "..."}           a host-written prompt (task notification)
#   {"bash": "..."}              an assistant Bash tool_use
#   {"bgbash": "..."}            the same, sent to the background
#   {"agent": "<name>"}          an Agent tool_use with name + subagent_type
#   {"send": "<to>"}             a SendMessage tool_use
#   {"tool": "..."}              any other assistant tool_use, by name
#   {"turn": "<prompt-id>"}      switch the promptId from here on
mk_tr() { # <outfile> <json-spec>
    python3 - "$1" "$2" "$PROMPT_ID" "$ENTITY" <<'PY'
import json, sys
out, spec, pid, cwd = sys.argv[1:5]
cur = pid
rows = []
n = 0
def user(text, machine):
    rows.append({"type": "user", "promptId": cur, "cwd": cwd,
                 "promptSource": "user" if not machine else "hook",
                 "message": {"content": text}})
def call(name, inp):
    global n
    n += 1
    tid = "toolu_%03d" % n
    rows.append({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": tid, "name": name, "input": inp}]}})
    rows.append({"type": "user", "promptId": cur, "cwd": cwd,
                 "message": {"content": [
                     {"type": "tool_result", "tool_use_id": tid, "content": "ok"}]}})
for step in json.loads(spec):
    if "turn" in step:
        cur = step["turn"]; continue
    if "prompt" in step:
        user(step["prompt"], False); continue
    if "machine" in step:
        user(step["machine"], True); continue
    if "bash" in step:
        call("Bash", {"command": step["bash"]}); continue
    if "bgbash" in step:
        call("Bash", {"command": step["bgbash"], "run_in_background": True}); continue
    if "agent" in step:
        name = step["agent"]
        call("Agent", {"name": name, "subagent_type": name.split("-")[0], "prompt": "go"}); continue
    if "send" in step:
        call("SendMessage", {"to": step["send"], "message": "hi"}); continue
    if "tool" in step:
        call(step["tool"], {}); continue
with open(out, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
}

FINISHED='<task-notification><task-id>a1</task-id><status>completed</status><summary>Agent "Break the elimination design" finished</summary><result>done</result></task-notification>'
KILLED='<task-notification><task-id>a1</task-id><status>completed</status><summary>Agent "Break the elimination design" was stopped by user</summary></task-notification>'
SHELL_DONE='<task-notification><task-id>b1</task-id><status>completed</status><summary>Background command "npm test" completed</summary></task-notification>'
NOT_COMPLETED='<task-notification><task-id>a1</task-id><status>failed</status><summary>Agent "Break the elimination design" finished</summary></task-notification>'

TR_BASH="$SANDBOX/bash.jsonl";        mk_tr "$TR_BASH"    '[{"prompt":"go"},{"bash":"git status"},{"bash":"ls"}]'
TR_FRANK="$SANDBOX/frank.jsonl";      mk_tr "$TR_FRANK"   '[{"prompt":"go"},{"bash":"git status"},{"agent":"frank-opus-x1"}]'
TR_SAGE="$SANDBOX/sage.jsonl";        mk_tr "$TR_SAGE"    '[{"prompt":"go"},{"agent":"sage-opus-x1"}]'
TR_SEND="$SANDBOX/send.jsonl";        mk_tr "$TR_SEND"    '[{"prompt":"go"},{"send":"frank-opus-x1"}]'
TR_ASK="$SANDBOX/ask.jsonl";          mk_tr "$TR_ASK"     '[{"prompt":"go"},{"tool":"AskUserQuestion"}]'
TR_EARLIER="$SANDBOX/earlier.jsonl";  mk_tr "$TR_EARLIER" "[{\"turn\":\"$OLD_PROMPT\"},{\"prompt\":\"before\"},{\"agent\":\"frank-opus-x1\"},{\"turn\":\"$PROMPT_ID\"},{\"prompt\":\"now\"},{\"bash\":\"ls\"}]"
TR_FIN="$SANDBOX/fin.jsonl";          mk_tr "$TR_FIN"     "[{\"machine\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$FINISHED")},{\"bash\":\"git merge --no-ff x\"}]"
TR_FIN_AGENT="$SANDBOX/fin-agent.jsonl"; mk_tr "$TR_FIN_AGENT" "[{\"machine\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$FINISHED")},{\"agent\":\"sage-opus-x2\"}]"
TR_FIN_BG="$SANDBOX/fin-bg.jsonl";    mk_tr "$TR_FIN_BG"  "[{\"machine\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$FINISHED")},{\"bgbash\":\"npm test\"}]"
TR_FIN_ASK="$SANDBOX/fin-ask.jsonl";  mk_tr "$TR_FIN_ASK" "[{\"machine\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$FINISHED")},{\"tool\":\"AskUserQuestion\"}]"
TR_FIN_HOLD="$SANDBOX/fin-hold.jsonl"; mk_tr "$TR_FIN_HOLD" "[{\"machine\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$FINISHED")},{\"prompt\":\"hold everything until I am back\"},{\"bash\":\"ls\"}]"
TR_KILLED="$SANDBOX/killed.jsonl";    mk_tr "$TR_KILLED"  "[{\"machine\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$KILLED")},{\"bash\":\"ls\"}]"
TR_SHELL="$SANDBOX/shell.jsonl";      mk_tr "$TR_SHELL"   "[{\"machine\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$SHELL_DONE")},{\"bash\":\"ls\"}]"
TR_NOTDONE="$SANDBOX/notdone.jsonl";  mk_tr "$TR_NOTDONE" "[{\"machine\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$NOT_COMPLETED")},{\"bash\":\"ls\"}]"

# --- running the hook ------------------------------------------------------
CASE_N=0
OUT=""; ERR=""; RC=0
# run_hook <transcript|-> <message> [stop_hook_active] [entity] [hook] [prompt_id]
run_hook() {
    local tr="$1" msg="$2" active="${3:-false}" ent="${4:-$ENTITY}" hook="${5:-$HOOK}" pid="${6:-$PROMPT_ID}"
    CASE_N=$((CASE_N + 1))
    local sid; sid="$(printf 'feedface-%04d-4000-8000-000000000000' "$CASE_N")"
    local payload="$SANDBOX/payload.json"
    python3 - "$tr" "$msg" "$active" "$ent" "$sid" "$pid" > "$payload" <<'PY'
import json, sys
tr, msg, active, ent, sid, pid = sys.argv[1:7]
p = {"hook_event_name": "Stop", "session_id": sid,
     "transcript_path": (tr if tr != "-" else "/nonexistent/none.jsonl"),
     "cwd": ent, "permission_mode": "default",
     "stop_hook_active": active == "true", "last_assistant_message": msg,
     "background_tasks": [], "session_crons": []}
# "none" means the payload carries NO prompt_id at all (the unscopable turn);
# anything else is the id. The first version of this block deleted a key it
# had not set, crashed, wrote an empty payload, and case (v) passed for the
# wrong reason — an empty stdin exits 0 too.
if pid != "none":
    p["prompt_id"] = pid
print(json.dumps(p))
PY
    local o e
    o="$(mktemp "$SANDBOX/o.XXXXXX")"; e="$(mktemp "$SANDBOX/e.XXXXXX")"
    RICHOS_ENTITY_ROOT="$ent" bash "$hook" < "$payload" > "$o" 2> "$e"
    RC=$?
    OUT="$(cat "$o")"; ERR="$(cat "$e")"
    rm -f "$o" "$e"
}
# run_unrooted <transcript> <message> <cwd> — no explicit root; resolution is
# from the payload's cwd, which is how the not-adopted case is reached.
run_unrooted() {
    local tr="$1" msg="$2" ent="$3"
    CASE_N=$((CASE_N + 1))
    local payload="$SANDBOX/payload.json"
    python3 - "$tr" "$msg" "$ent" "$PROMPT_ID" > "$payload" <<'PY'
import json, sys
tr, msg, ent, pid = sys.argv[1:5]
print(json.dumps({"hook_event_name": "Stop", "session_id": "feedface-9999-4000-8000-000000000000",
                  "transcript_path": tr, "cwd": ent, "prompt_id": pid,
                  "stop_hook_active": False, "last_assistant_message": msg}))
PY
    local o e
    o="$(mktemp "$SANDBOX/o.XXXXXX")"; e="$(mktemp "$SANDBOX/e.XXXXXX")"
    ( cd "$ent" && env -u RICHOS_ENTITY_ROOT bash "$HOOK" < "$payload" > "$o" 2> "$e" )
    RC=$?
    OUT="$(cat "$o")"; ERR="$(cat "$e")"
    rm -f "$o" "$e"
}
has_sysmsg() { # <needle>
    python3 -c 'import json,sys; d=json.loads(sys.stdin.readline() or "{}"); m=d.get("systemMessage",""); sys.exit(0 if isinstance(m,str) and sys.argv[1] in m else 1)' "$1" <<<"$OUT"
}

ZACH="Landed at abc1234. Sixty-five lines get added and none removes anything.

Zach builds it tomorrow."
FRANK="Design 4 landed, and it found something that reframes the whole eleven days.

I'm not accepting it on its summary. Frank breaks it first, and I want him attacking whether −66% is still too generous now that the platform's own record turns out to exist."
FIN_REPORT="Both arms are in, and they answer the question that has consumed eleven days. The design holds."

echo "=== guard-stated-actions: the report must match the turn ==="
echo ""

# ---------------------------------------------------------------------------
# ARM 1
# ---------------------------------------------------------------------------
run_hook "$TR_BASH" "$ZACH"
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'Zach builds it tomorrow' && printf '%s' "$ERR" | grep -q 'no Agent call for zach'; then
    ok "a.  a role act with no Agent call this turn is REFUSED, and the refusal quotes the clause"
else bad "a.  role act refused" "rc=$RC err=$(printf '%s' "$ERR" | head -c 300)"; fi

run_hook "$TR_BASH" "$FRANK"
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'Frank breaks it first'; then
    ok "a2. the second real sentence is refused — the clause split keeps 'Frank breaks it first' and the second clause's 'whether/still/now that' do not exempt it"
else bad "a2. Frank breaks it first" "rc=$RC err=$(printf '%s' "$ERR" | head -c 300)"; fi

run_hook "$TR_FRANK" "$FRANK"
[ "$RC" -eq 0 ] && ok "b.  the same sentence with an Agent call for frank this turn is let through" || bad "b.  same-turn dispatch" "rc=$RC err=$(printf '%s' "$ERR" | head -c 200)"

run_hook "$TR_SAGE" "$ZACH"
[ "$RC" -eq 0 ] && ok "b2. a role act is discharged by ANY Agent call this turn (a plan in motion is not the defect)" || bad "b2. any Agent discharges 1a" "rc=$RC"

run_hook "$TR_SEND" "$ZACH"
[ "$RC" -eq 0 ] && ok "b3. a SendMessage to a teammate this turn discharges a role act" || bad "b3. SendMessage discharges" "rc=$RC"

run_hook "$TR_BASH" "I'm dispatching Frank now, with the full brief."
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'in the first person'; then
    ok "c.  POSITIVE PROBE for 1b: 'I'm dispatching Frank now' with no Agent call is refused"
else bad "c.  1b positive probe" "rc=$RC err=$(printf '%s' "$ERR" | head -c 200)"; fi

run_hook "$TR_SAGE" "I'm dispatching Frank now, with the full brief."
[ "$RC" -eq 2 ] && ok "c2. 1b is ROLE-MATCHED: an Agent call for sage does not discharge 'I'm dispatching Frank'" || bad "c2. 1b role-matched" "rc=$RC"

run_hook "$TR_FRANK" "I'm dispatching Frank now, with the full brief."
[ "$RC" -eq 0 ] && ok "c3. ...and an Agent call for frank does" || bad "c3. 1b discharged by frank" "rc=$RC"

# ONE DEFENSE PER FIXTURE. The mutation run found three fixtures here carrying
# two defenses at once (a quoted sentence inside a fence; a proposal that was
# also the reply's last sentence), so removing either property left the suite
# green over a defense it was not testing. Each of (d), (e), (e2) now reaches
# exactly one property.
run_hook "$TR_BASH" "Say the word and I'll dispatch Frank. The rest stays exactly as it is."
[ "$RC" -eq 0 ] && ok "d.  a dispatch conditioned on the CEO's word is a proposal, not a claim (and it is not the last sentence, so only the clause rule protects it)" || bad "d.  proposal" "rc=$RC err=$(printf '%s' "$ERR" | head -c 200)"

run_hook "$TR_BASH" "The sentence \"I'm dispatching Frank now\" was the failure, quoted here as evidence."
[ "$RC" -eq 0 ] && ok "e.  a dispatch claim inside double quotes is quoted speech, not a claim" || bad "e.  quoted" "rc=$RC"

run_hook "$TR_BASH" "The transcript line, verbatim:

\`\`\`
Zach builds it tomorrow.
\`\`\`

That is the sentence under discussion."
[ "$RC" -eq 0 ] && ok "e2. the sentence inside a fenced block is not scanned" || bad "e2. fenced" "rc=$RC"

run_hook "$TR_BASH" "Frank breaks it first, I said, and then I wrote a status report."
[ "$RC" -eq 0 ] && ok "e3. reported speech ('I said') in the sentence is not a claim" || bad "e3. reported" "rc=$RC"

run_hook "$TR_BASH" "The sequence:

- Sage designs the lease
- Zach builds it tomorrow
- I land it"
[ "$RC" -eq 0 ] && ok "f.  a list item is a plan, not a statement, and is not scanned" || bad "f.  list item" "rc=$RC"

run_hook "$TR_BASH" "Zach builds it — in flight now. Worktree cut, no commits yet."
[ "$RC" -eq 0 ] && ok "f2. a present-progress marker after a dash stays in the clause and marks it as state, not announcement" || bad "f2. progress" "rc=$RC"

run_hook "$TR_BASH" "**1. Zach builds it tomorrow.** Then I land it."
[ "$RC" -eq 0 ] && ok "f3. an emphasized numbered line is still a list item" || bad "f3. emphasized list" "rc=$RC"

run_hook "$TR_BASH" "Frank recommends the hybrid, and I agree with him."
[ "$RC" -eq 0 ] && ok "g.  a report verb ('recommends') describes an agent's output, not an act to take" || bad "g.  report verb" "rc=$RC"

run_hook "$TR_BASH" "Art designs Bootstrap components for a mobile coaching app."
[ "$RC" -eq 0 ] && ok "h.  a bare-noun object is a description of a craft, not an announced act" || bad "h.  bare object" "rc=$RC"

run_hook "$TR_BASH" "$ZACH

Want me to post the brief first?"
[ "$RC" -eq 0 ] && ok "i.  a reply that ENDS on a question to the CEO is a proposal; the turn may end on his answer" || bad "i.  ends on CEO" "rc=$RC"

run_hook "$TR_BASH" "Sage will fold it in tonight, with the count."
if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -q 'not blocking'; then
    ok "j.  the role-future shape (0/2 on the corpus) REPORTS and never blocks"
else bad "j.  role-future reports" "rc=$RC err=$(printf '%s' "$ERR" | head -c 200)"; fi

run_hook "$TR_ASK" "$ZACH"
[ "$RC" -eq 0 ] && ok "k.  an AskUserQuestion this turn exempts the turn — the CEO is being asked" || bad "k.  AskUserQuestion" "rc=$RC"

run_hook "$TR_EARLIER" "$ZACH"
[ "$RC" -eq 2 ] && ok "l.  TURN SCOPING: an Agent call in an EARLIER prompt does not discharge this turn's claim" || bad "l.  turn scoping" "rc=$RC"

run_hook "$TR_BASH" "$ZACH" false "$NOROLES"
if [ "$RC" -eq 0 ] && grep -q '"roles": 0' "$NOROLES/.claude/state/stated-actions.jsonl" 2>/dev/null; then
    ok "m.  with no roles on disk ARM 1 is inert, and the record says roles: 0"
else bad "m.  no roles" "rc=$RC record=$(cat "$NOROLES/.claude/state/stated-actions.jsonl" 2>/dev/null | tail -1)"; fi

run_hook "$TR_BASH" "Frank breaks it the moment Sage returns."
[ "$RC" -eq 0 ] && ok "o.  a conditional ('the moment ...') in the clause is not an announcement" || bad "o.  conditional" "rc=$RC"

run_hook "$TR_BASH" "Frank breaks it, but not tonight."
[ "$RC" -eq 0 ] && ok "p.  a negation anywhere in the sentence is not an announcement (it is a deferral, owned elsewhere)" || bad "p.  negation" "rc=$RC"

# ---------------------------------------------------------------------------
# ARM 2
# ---------------------------------------------------------------------------
run_hook "$TR_FIN" "$FIN_REPORT"
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'Break the elimination design' \
   && printf '%s' "$ERR" | grep -q 'stop-declared: <case>' \
   && printf '%s' "$ERR" | grep -q 'waiting-on-teammate'; then
    ok "n.  a teammate finished, nothing started, nothing declared -> REFUSED, naming the agent and the exact declaration line"
else bad "n.  undeclared stop refused" "rc=$RC err=$(printf '%s' "$ERR" | head -c 400)"; fi

run_hook "$TR_FIN_AGENT" "$FIN_REPORT"
[ "$RC" -eq 0 ] && ok "n2. ...and the same turn with an Agent call is let through" || bad "n2. started" "rc=$RC"

run_hook "$TR_FIN_BG" "$FIN_REPORT"
[ "$RC" -eq 0 ] && ok "n3. a BACKGROUNDED tool call counts as started" || bad "n3. backgrounded" "rc=$RC"

run_hook "$TR_FIN_ASK" "$FIN_REPORT"
[ "$RC" -eq 0 ] && ok "n4. a question put to the CEO this turn is owed an answer; the turn may end" || bad "n4. ask" "rc=$RC"

run_hook "$TR_FIN_HOLD" "$FIN_REPORT"
[ "$RC" -eq 0 ] && ok "n5. the operator's own hold in his own prompt stands the arm down" || bad "n5. hold" "rc=$RC"

DECL="$FIN_REPORT

stop-declared: waiting-on-teammate — the other two designers are still running and the review needs both before anything moves."
run_hook "$TR_FIN" "$DECL"
if [ "$RC" -eq 0 ] && has_sysmsg "STOP DECLARED" && has_sysmsg "NOT VERIFIED" && has_sysmsg "waiting-on-teammate"; then
    ok "n6. a valid declaration lets the turn through AND is shown to the operator as declared, not verified"
else bad "n6. declaration shown" "rc=$RC out=$(printf '%s' "$OUT" | head -c 300)"; fi

run_hook "$TR_FIN" "$FIN_REPORT

stop-declared: waiting-on-teammate — later."
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'REJECTED'; then
    ok "n7. a declaration short on words is REJECTED and the refusal says why"
else bad "n7. short declaration" "rc=$RC err=$(printf '%s' "$ERR" | head -c 300)"; fi

run_hook "$TR_FIN" "$FIN_REPORT

The form is \`stop-declared: waiting-on-teammate — the other two designers are still running and the review needs both.\` and I am not using it."
[ "$RC" -eq 2 ] && ok "n8. a declaration inside a code span exempts nothing" || bad "n8. code span" "rc=$RC"

run_hook "$TR_KILLED" "Frank left nothing — killed before it wrote a line."
[ "$RC" -eq 0 ] && ok "n9. an agent the operator STOPPED is not a delivery" || bad "n9. killed" "rc=$RC"

run_hook "$TR_SHELL" "The suite is green."
[ "$RC" -eq 0 ] && ok "n10. a finished BACKGROUND COMMAND is not a teammate" || bad "n10. shell" "rc=$RC"

run_hook "$TR_NOTDONE" "$FIN_REPORT"
[ "$RC" -eq 0 ] && ok "n11. a notification without <status>completed</status> is not a delivery" || bad "n11. not completed" "rc=$RC"

# ---------------------------------------------------------------------------
# SAFETY
# ---------------------------------------------------------------------------
run_hook "$TR_BASH" "$ZACH" true
[ "$RC" -eq 0 ] && ok "r.  stop_hook_active=true stands the gate down — it refuses a turn at most once" || bad "r.  re-fire" "rc=$RC"

run_unrooted "$TR_BASH" "$ZACH" "$UNADOPTED"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "s.  a repository that never adopted the engine: exit 0, silent" || bad "s.  not adopted" "rc=$RC out=$OUT"

printf 'CHECK_STATED_ACTIONS=0\n' > "$ENTITY/orchestration.config"
run_hook "$TR_BASH" "$ZACH"
if [ "$RC" -eq 0 ] && has_sysmsg "STOOD DOWN"; then ok "t.  CHECK_STATED_ACTIONS=0: exit 0, and the operator is TOLD"
else bad "t.  stood down" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"; fi
: > "$ENTITY/orchestration.config"

CASE_N=$((CASE_N + 1))
printf 'this is not json' | RICHOS_ENTITY_ROOT="$ENTITY" bash "$HOOK" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "u.  an unparseable payload never wedges turn-end" || bad "u.  garbage" "rc=$RC"

run_hook "$TR_BASH" "$ZACH" false "$ENTITY" "$HOOK" none
[ "$RC" -eq 0 ] && ok "v.  no prompt_id: the turn cannot be scoped, so nothing is refused" || bad "v.  unscoped" "rc=$RC"

run_hook "-" "$ZACH"
[ "$RC" -eq 0 ] && ok "w.  a missing transcript: exit 0" || bad "w.  missing transcript" "rc=$RC"

# A mirror of the engine subtree, so the broken-install paths are reached for
# the right reason (see stop-hook-visibility.test.sh on why a bare temp dir
# proves nothing).
MIRROR="$SANDBOX/mirror"
mkdir -p "$MIRROR/scripts/hooks" "$MIRROR/scripts/lib"
cp "$SCRIPT_DIR/guard-stated-actions.sh" "$SCRIPT_DIR/guard-stated-actions.py" \
   "$SCRIPT_DIR/turn-manifest.py" "$SCRIPT_DIR/guard-idle-land.py" "$MIRROR/scripts/hooks/"
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" \
   "$SCRIPT_DIR/../lib/stop-hook-notice.sh" "$MIRROR/scripts/lib/"
BROKEN="$SANDBOX/broken"
cp -R "$MIRROR" "$BROKEN"
rm -f "$BROKEN/scripts/lib/resolve-roots.sh"
run_hook "$TR_BASH" "$ZACH" false "$ENTITY" "$BROKEN/scripts/hooks/guard-stated-actions.sh"
if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -q 'BROKEN INSTALL'; then ok "x.  broken install (resolve-roots.sh absent): exit 0 + banner"
else bad "x.  broken install" "rc=$RC err=$(printf '%s' "$ERR" | head -c 200)"; fi

printf 'STATED_ACTIONS_ENFORCE=0\n' > "$ENTITY/orchestration.config"
run_hook "$TR_BASH" "$ZACH"
if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -q 'TURN BLOCKED'; then ok "y.  STATED_ACTIONS_ENFORCE=0: the refusal is printed and the turn ends"
else bad "y.  report-only" "rc=$RC err=$(printf '%s' "$ERR" | head -c 200)"; fi
: > "$ENTITY/orchestration.config"

NODEP="$SANDBOX/nodep"
cp -R "$MIRROR" "$NODEP"
rm -f "$NODEP/scripts/hooks/guard-idle-land.py"
run_hook "$TR_FIN" "$FIN_REPORT" false "$ENTITY" "$NODEP/scripts/hooks/guard-stated-actions.sh"
if [ "$RC" -eq 0 ] && has_sysmsg "NOT RUNNING"; then ok "y2. guard-idle-land.py absent: the gate does not guess, exits 0, and the operator is TOLD"
else bad "y2. dependency absent" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"; fi

# ---------------------------------------------------------------------------
# RECORD
# ---------------------------------------------------------------------------
REC="$ENTITY/.claude/state/stated-actions.jsonl"
if [ -f "$REC" ] && grep -q '"verdict": "block"' "$REC" && grep -q '"undeclared-stop"' "$REC"; then
    ok "z.  an observation record is appended per evaluated turn, with the verdict and the arm"
else bad "z.  record" "missing or incomplete: $REC"; fi

echo ""
echo "=== summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
