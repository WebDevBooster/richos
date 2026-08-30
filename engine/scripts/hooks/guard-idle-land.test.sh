#!/usr/bin/env bash
#
# guard-idle-land.test.sh — regression tests for the Stop-time idle-land gate
# (scripts/hooks/guard-idle-land.sh + .py).
#
# THE REAL FAILURE IS REPLAYED HERE STRUCTURALLY, NOT VERBATIM.
#   richos is a public repository, so no operator speech and no transcript text
#   is committed. Every fixture below reproduces the SHAPE of the real failure —
#   a turn that merges a branch, pushes it, writes a report and calls no Agent,
#   with unblocked rows still in the record — with invented content. The
#   measurement that decided this gate ships BLOCKING rather than report-only
#   was run against the real transcripts on disk and only the NUMBERS are
#   recorded, in the hook header.
#
# Covers:
#   THE POSITIVE CONTROL
#     (a)  merge confirmed, no Agent, unblocked row        -> exit 2
#     (a2) the merge message spans lines and holds quotes  -> exit 2
#          (THE BUG THE REPLAY FOUND: a newline split cut the -m message in
#           half, shlex choked, and 4 of 4 real merges vanished)
#     (a3) `-m <subject>` is not read as the merged ref    -> exit 2
#     (a4) push, HEAD == upstream                          -> exit 2
#   THE FIVE NEGATIVE CASES
#     (b)  lands AND dispatches                            -> exit 0
#     (c)  lands while an agent is still running           -> exit 0
#     (d)  lands, backlog fully struck through / blocked   -> exit 0
#     (e)  no landing in this turn at all                  -> exit 0
#     (f)  the operator called a hold                      -> exit 0
#     (f2) a hold word inside a HOST-written prompt        -> exit 2
#     (f3) a hold word inside the operator's own code span -> exit 2
#          (f2 and f3 exist separately because two different defences stop the
#           one real false positive, and a fixture that trips both proves
#           neither)
#   CONFIRMATION IS IDENTITY, NOT PROSE
#     (g)  merge command ran but the ref is NOT an ancestor -> exit 0
#     (h)  push command ran but HEAD != upstream            -> exit 0
#     (h2) `git merge --abort` is not a landing             -> exit 0
#     (h3) the command only MENTIONS a merge (echo/grep)    -> exit 0
#   TURN SCOPING — the sibling gate's silent death
#     (i)  Agent called only in an EARLIER turn            -> exit 2
#     (j)  Agent called in THIS turn                       -> exit 0
#   THE RECORD, DERIVED
#     (k)  "<x> free after 1-2" with 1 and 2 struck        -> free  (fires)
#     (l)  "<x> free after 1-2" with 2 still open          -> blocked
#     (m)  an unrecognised blocker cell is BLOCKED, quietly
#     (n)  no such section              -> exit 0 + INERT and says so
#     (o)  section present, no table    -> exit 0 + INERT and says so
#     (p)  two candidate records        -> exit 0 + INERT and says so
#     (q)  record but no .ceo-todos     -> exit 0 + INERT and says so
#   SAFETY — this gate must never strand a session
#     (r)  stop_hook_active=true, violation present        -> exit 0
#     (s)  repository has not adopted the engine           -> exit 0
#     (t)  CHECK_IDLE_LAND=0                               -> exit 0 + notice
#     (u)  unparseable payload                             -> exit 0
#     (v)  no prompt_id — the turn cannot be scoped        -> exit 0, silent
#     (w)  transcript missing / unreadable                 -> exit 0
#     (x)  broken install (resolve-roots.sh absent)        -> exit 0 + banner
#     (y)  IDLE_LAND_ENFORCE=0                             -> exit 0 + report
#   RECORD
#     (z)  an observation line is appended
#
# Run directly: scripts/hooks/guard-idle-land.test.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-idle-land.sh"
unset CLAUDE_PROJECT_DIR

PASS=0
FAIL=0

SANDBOX="$(mktemp -d -t guard-idle-land.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
# macOS hands out /var symlinked to /private/var; the hook resolves real paths
# through git, so the fixtures must speak the same dialect or every path
# comparison in here is comparing two spellings of one directory.
SANDBOX="$(cd "$SANDBOX" && pwd -P)"

SESSION_ID="feedface-0000-4000-8000-000000000000"
PROMPT_ID="11111111-2222-3333-4444-555555555555"
OLD_PROMPT="00000000-0000-4000-8000-000000000000"

# --- the governed repository, which is also the landing repo and the record --
# One repo plays all three parts so the fixtures stay readable. The hook does
# not care: it resolves the record from the repositories the turn landed in and
# their siblings, and this is one of them.
ENTITY="$SANDBOX/entity"
mkdir -p "$ENTITY"
git -C "$ENTITY" init -q -b main . >/dev/null 2>&1
git -C "$ENTITY" config user.email t@t.t >/dev/null 2>&1
git -C "$ENTITY" config user.name t >/dev/null 2>&1
# The operator may have a global core.hooksPath (an identity guard, a linter).
# A suite that inherits it fails for reasons that have nothing to do with the
# thing under test, so the sandbox repo gets an empty hooks dir of its own.
mkdir -p "$SANDBOX/nohooks"
git -C "$ENTITY" config core.hooksPath "$SANDBOX/nohooks" >/dev/null 2>&1
: > "$ENTITY/orchestration.config"
: > "$ENTITY/.ceo-todos"

write_record() { # <path> <mode>
    case "$2" in
      normal)
cat >"$1" <<'MD'
# The backlog

## Next

| # | Item | Blocked by |
|---|---|---|
| ~~1~~ | ~~**First thing**~~ — landed earlier | done |
| ~~2~~ | ~~**Second thing**~~ — landed earlier | done |
| 3 | **The wire protocol handshake** — the half nobody built | engine free |
| 4 | **The other one** — needs 1 and 2 first | engine free after 1-2 |
| 5 | **A third one** | — |
| 6 | **The toolchain one** | **needs a toolchain that is not on this machine** |

## Standing

- something that is not a table row
MD
        ;;
      exhausted)
cat >"$1" <<'MD'
# The backlog

## Next

| # | Item | Blocked by |
|---|---|---|
| ~~1~~ | ~~**First thing**~~ | done |
| 6 | **The toolchain one** | **needs a toolchain that is not on this machine** |
| 7 | **The other blocked one** | waiting on an external answer |
MD
        ;;
      deferred-open)
cat >"$1" <<'MD'
# The backlog

## Next

| # | Item | Blocked by |
|---|---|---|
| ~~1~~ | ~~**First thing**~~ | done |
| 2 | **Second thing** | **an external answer** |
| 4 | **The other one** | engine free after 1-2 |
MD
        ;;
      no-section)
cat >"$1" <<'MD'
# The backlog

## Later

| # | Item | Blocked by |
|---|---|---|
| 3 | **A thing** | — |
MD
        ;;
      no-table)
cat >"$1" <<'MD'
# The backlog

## Next

Just prose. Three things are open and none of them is in a table.
MD
        ;;
    esac
}

write_record "$ENTITY/RICH-TODOs.md" normal
git -C "$ENTITY" add -A >/dev/null 2>&1
git -C "$ENTITY" commit -qm seed >/dev/null 2>&1

# A branch that WAS merged: its tip is an ancestor of HEAD.
git -C "$ENTITY" checkout -q -b landed-branch >/dev/null 2>&1
printf 'work\n' > "$ENTITY/work.txt"
git -C "$ENTITY" add -A >/dev/null 2>&1
git -C "$ENTITY" commit -qm work >/dev/null 2>&1
git -C "$ENTITY" checkout -q main >/dev/null 2>&1
git -C "$ENTITY" merge -q --no-ff landed-branch -m merged >/dev/null 2>&1

# A branch that was NOT merged: its tip is not an ancestor of anything.
git -C "$ENTITY" branch -q unmerged-branch landed-branch >/dev/null 2>&1
git -C "$ENTITY" checkout -q unmerged-branch >/dev/null 2>&1
printf 'more\n' > "$ENTITY/more.txt"
git -C "$ENTITY" add -A >/dev/null 2>&1
git -C "$ENTITY" commit -qm more >/dev/null 2>&1
git -C "$ENTITY" checkout -q main >/dev/null 2>&1

# A remote, so the push half can be confirmed the way the hook confirms it:
# HEAD against the branch's remote-tracking ref.
REMOTE="$SANDBOX/remote.git"
git init -q --bare "$REMOTE" >/dev/null 2>&1
git -C "$ENTITY" remote add origin "$REMOTE" >/dev/null 2>&1
git -C "$ENTITY" push -q -u origin main >/dev/null 2>&1

# A repository that never adopted the engine: no orchestration.config.
UNADOPTED="$SANDBOX/unadopted"
mkdir -p "$UNADOPTED"
git -C "$UNADOPTED" init -q . >/dev/null 2>&1

# --- transcript fixtures ---------------------------------------------------
# At Stop time the transcript holds the turn's tool_use records but NOT the
# final assistant text. These mirror that exactly. The DSL is a JSON list:
#   {"prompt": "..."}          a real operator prompt (carries promptSource)
#   {"machine": "..."}         a host-written prompt (task notification)
#   {"bash": "..."}            an assistant Bash tool_use
#   {"agent": "..."}           an assistant Agent tool_use
#   {"turn": "<prompt-id>"}    switch the promptId from here on
mk_tr() { # <outfile> <json-spec>
    python3 - "$1" "$2" "$PROMPT_ID" "$ENTITY" <<'PY'
import json, sys
out, spec, pid, cwd = sys.argv[1:5]
cur = pid
rows = []
def user(text, machine):
    rows.append({"type": "user", "promptId": cur, "cwd": cwd,
                 "promptSource": "user" if not machine else "hook",
                 "message": {"content": text}})
for step in json.loads(spec):
    if "turn" in step:
        cur = step["turn"]
        continue
    if "prompt" in step:
        user(step["prompt"], False); continue
    if "machine" in step:
        user(step["machine"], True); continue
    if "bash" in step:
        rows.append({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Bash",
             "input": {"command": step["bash"]}}]}})
        rows.append({"type": "user", "promptId": cur, "cwd": cwd,
                     "message": {"content": [
                         {"type": "tool_result", "content": "ok"}]}})
        continue
    if "agent" in step:
        rows.append({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Agent",
             "input": {"name": step["agent"]}}]}})
        continue
with open(out, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
}

EMPTY_TR="$SANDBOX/empty.jsonl"
: > "$EMPTY_TR"

MERGE_CMD="cd $ENTITY && git merge --no-ff landed-branch -m 'landed it'"
PUSH_CMD="cd $ENTITY && git push 2>&1 | tail -2"

TR_MERGE="$SANDBOX/merge.jsonl"
mk_tr "$TR_MERGE" "$(printf '[{"prompt":"land it"},{"bash":%s}]' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$MERGE_CMD")")"

TR_PUSH="$SANDBOX/push.jsonl"
mk_tr "$TR_PUSH" "$(printf '[{"prompt":"land it"},{"bash":%s}]' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$PUSH_CMD")")"

# THE REGRESSION FIXTURE. This is how a landing is really written here: a
# multi-line quoted message, blank lines inside it, and a pipe afterwards. A
# newline-first split cuts the quote in half and the merge disappears.
REAL_MERGE="cd $ENTITY && git merge --no-ff landed-branch -m \"A subject line that is quite long

A body paragraph with a blank line above it; a semicolon, a | pipe character
and an & ampersand, all inside the quotes.\" 2>&1 | tail -3"
TR_REAL="$SANDBOX/real-merge.jsonl"
mk_tr "$TR_REAL" "$(printf '[{"prompt":"land it"},{"bash":%s}]' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$REAL_MERGE")")"

# `-m <subject>` must not be mistaken for the merged ref.
MSG_FIRST="cd $ENTITY && git merge -m 'landed-branch' --no-ff landed-branch"
TR_MSGFIRST="$SANDBOX/msg-first.jsonl"
mk_tr "$TR_MSGFIRST" "$(printf '[{"prompt":"land it"},{"bash":%s}]' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$MSG_FIRST")")"

TR_UNMERGED="$SANDBOX/unmerged.jsonl"
mk_tr "$TR_UNMERGED" "$(printf '[{"prompt":"land it"},{"bash":%s}]' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "cd $ENTITY && git merge --no-ff unmerged-branch -m nope")")"

TR_ABORT="$SANDBOX/abort.jsonl"
mk_tr "$TR_ABORT" "$(printf '[{"prompt":"land it"},{"bash":%s}]' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "cd $ENTITY && git merge --abort")")"

TR_MENTION="$SANDBOX/mention.jsonl"
mk_tr "$TR_MENTION" "$(printf '[{"prompt":"land it"},{"bash":%s}]' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "cd $ENTITY && echo 'git merge landed-branch' && grep -rn 'git push' docs || true")")"

TR_NOLAND="$SANDBOX/no-land.jsonl"
mk_tr "$TR_NOLAND" "$(printf '[{"prompt":"look at it"},{"bash":%s}]' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "cd $ENTITY && git status --short && git log --oneline -3")")"

TR_MERGE_AGENT="$SANDBOX/merge-agent.jsonl"
mk_tr "$TR_MERGE_AGENT" "$(printf '[{"prompt":"land it"},{"bash":%s},{"agent":"norm-opus-a1"}]' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$MERGE_CMD")")"

# Agent in an EARLIER turn only. The whole point: this turn dispatched nothing.
TR_AGENT_EARLIER="$SANDBOX/agent-earlier.jsonl"
mk_tr "$TR_AGENT_EARLIER" "$(printf '[{"turn":"%s"},{"prompt":"earlier"},{"agent":"norm-opus-a1"},{"turn":"%s"},{"prompt":"land it"},{"bash":%s}]' \
    "$OLD_PROMPT" "$PROMPT_ID" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$MERGE_CMD")")"

# The operator calling a hold, in the same turn as the land.
TR_HOLD="$SANDBOX/hold.jsonl"
mk_tr "$TR_HOLD" "$(printf '[{"prompt":"Land what is finished and then hold — do not dispatch anything else tonight."},{"bash":%s}]' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$MERGE_CMD")")"

# The OPERATOR quoting a hold-shaped word inside a code span. Two separate
# defences stop the real false positive — the host-prompt filter and the
# code-span strip — and a fixture that trips both proves neither: remove one
# and the case still passes. So there is a fixture per defence, and the
# mutation run confirms each one can go red on its own.
TR_OPERATOR_CODE_HOLD="$SANDBOX/operator-code-hold.jsonl"
mk_tr "$TR_OPERATOR_CODE_HOLD" "$(printf '[{"prompt":"Land it. The measurement I care about is `Freeze margin 1.5` and `pause budget 200ms` — nothing else."},{"bash":%s}]' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$MERGE_CMD")")"

# A HOST-written prompt quoting a hold-shaped word inside a code span. This is
# the real false positive the replay found: an agent's handoff, arriving as a
# task notification, containing `Freeze margin 1.5`.
TR_QUOTED_HOLD="$SANDBOX/quoted-hold.jsonl"
mk_tr "$TR_QUOTED_HOLD" "$(printf '[{"machine":"<task-notification><status>completed</status>Over 400 messages it claimed an id in 36 and most were wrong: `Freeze margin 1.5`, `Stages 3.5`. Pause was never requested.</task-notification>"},{"bash":%s}]' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$MERGE_CMD")")"

# --- payload builder -------------------------------------------------------
payload() { # [transcript] [stop_hook_active] [cwd] [n-running] [prompt_id]
    python3 - "${1:-$EMPTY_TR}" "${2:-false}" "${3:-$ENTITY}" "${4:-0}" \
             "${5:-$PROMPT_ID}" "$SESSION_ID" <<'PY'
import json, sys
tr, active, cwd, running, pid, sid = sys.argv[1:7]
p = {
    "hook_event_name": "Stop",
    "session_id": sid,
    "transcript_path": tr,
    "cwd": cwd,
    "permission_mode": "bypassPermissions",
    "stop_hook_active": active == "true",
    "last_assistant_message": "Landed and reported.",
    "background_tasks": [{"id": "t%d" % i, "status": "running"}
                         for i in range(int(running))],
    "session_crons": [],
}
if pid != "-":
    p["prompt_id"] = pid
print(json.dumps(p))
PY
}

LAST_ERR=""
run_case() { # <name> <expected-exit> <payload-json> [needle-in-stderr]
    local name="$1" want="$2" json="$3" needle="${4:-}" got err
    err="$(mktemp "$SANDBOX/err.XXXXXX")"
    printf '%s' "$json" | RICHOS_ENTITY_ROOT="$ENTITY" "$HOOK" >/dev/null 2>"$err"
    got=$?
    LAST_ERR="$(cat "$err")"
    if [ "$got" -ne "$want" ]; then
        printf '  FAIL  %s (expected exit %s, got %s)\n' "$name" "$want" "$got"
        [ -s "$err" ] && sed 's/^/          /' "$err"
        FAIL=$((FAIL + 1))
    elif [ -n "$needle" ] && ! grep -qF "$needle" "$err"; then
        printf '  FAIL  %s (stderr missing %q)\n' "$name" "$needle"
        [ -s "$err" ] && sed 's/^/          /' "$err"
        FAIL=$((FAIL + 1))
    else
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    fi
    rm -f "$err"
}

echo "=== guard-idle-land.sh ==="

# --- THE POSITIVE CONTROL --------------------------------------------------
run_case "a.merge-and-start-nothing-blocks" 2 \
    "$(payload "$TR_MERGE")" \
    "LANDED, AND STARTED NOTHING"

# The refusal must NAME the row. A refusal that says "there is work left" and
# not WHICH work is a refusal the reader has to go and research.
if ! printf '%s' "$LAST_ERR" | grep -qF "The wire protocol handshake"; then
    printf '  FAIL  a1.refusal-names-the-top-row-verbatim\n'; FAIL=$((FAIL + 1))
else
    printf '  PASS  a1.refusal-names-the-top-row-verbatim\n'; PASS=$((PASS + 1))
fi
# ...and it must name the deferral route, which is the only escape there is.
if ! printf '%s' "$LAST_ERR" | grep -qF "CEO's record"; then
    printf "  FAIL  a1b.refusal-names-the-deferral-route\n"; FAIL=$((FAIL + 1))
else
    printf "  PASS  a1b.refusal-names-the-deferral-route\n"; PASS=$((PASS + 1))
fi

run_case "a2.multiline-quoted-merge-message-still-seen" 2 \
    "$(payload "$TR_REAL")" "LANDED, AND STARTED NOTHING"

run_case "a3.dash-m-subject-is-not-the-merged-ref" 2 \
    "$(payload "$TR_MSGFIRST")" "LANDED, AND STARTED NOTHING"

run_case "a4.push-with-head-at-upstream-blocks" 2 \
    "$(payload "$TR_PUSH")" "LANDED, AND STARTED NOTHING"

# --- THE FIVE NEGATIVE CASES ----------------------------------------------
run_case "b.lands-and-dispatches-passes" 0 "$(payload "$TR_MERGE_AGENT")"

run_case "c.lands-while-an-agent-runs-passes" 0 \
    "$(payload "$TR_MERGE" false "$ENTITY" 3)"

write_record "$ENTITY/RICH-TODOs.md" exhausted
run_case "d.lands-with-nothing-unblocked-passes" 0 "$(payload "$TR_MERGE")"
write_record "$ENTITY/RICH-TODOs.md" normal

run_case "e.no-landing-passes" 0 "$(payload "$TR_NOLAND")"

run_case "f.operator-called-a-hold-passes" 0 "$(payload "$TR_HOLD")"

# The hold suppressor must not be reachable from a HOST-written prompt, and not
# from a code span. Both halves of the real false positive, in one case.
run_case "f2.quoted-hold-word-in-a-machine-prompt-does-not-suppress" 2 \
    "$(payload "$TR_QUOTED_HOLD")" "LANDED, AND STARTED NOTHING"

run_case "f3.hold-word-inside-a-code-span-does-not-suppress" 2 \
    "$(payload "$TR_OPERATOR_CODE_HOLD")" "LANDED, AND STARTED NOTHING"

# --- CONFIRMATION IS IDENTITY, NOT PROSE ----------------------------------
run_case "g.merge-that-did-not-take-passes" 0 "$(payload "$TR_UNMERGED")"
run_case "h2.merge-abort-is-not-a-landing" 0 "$(payload "$TR_ABORT")"
run_case "h3.merely-mentioning-a-merge-is-not-a-landing" 0 "$(payload "$TR_MENTION")"

# The push half, made to fail by moving HEAD past the remote-tracking ref.
printf 'ahead\n' > "$ENTITY/ahead.txt"
git -C "$ENTITY" add -A >/dev/null 2>&1
git -C "$ENTITY" commit -qm ahead >/dev/null 2>&1
run_case "h.push-with-head-ahead-of-upstream-passes" 0 "$(payload "$TR_PUSH")"
git -C "$ENTITY" push -q origin main >/dev/null 2>&1

# --- TURN SCOPING ----------------------------------------------------------
run_case "i.agent-only-in-an-earlier-turn-still-blocks" 2 \
    "$(payload "$TR_AGENT_EARLIER")" "LANDED, AND STARTED NOTHING"
run_case "j.agent-in-this-turn-passes" 0 "$(payload "$TR_MERGE_AGENT")"

# --- THE RECORD, DERIVED ---------------------------------------------------
# "free after 1-2" with both references struck through resolves to FREE. The
# `normal` record's row 3 fires first, so this is asserted on the parse rather
# than on the exit code — see below.
write_record "$ENTITY/RICH-TODOs.md" deferred-open
run_case "l.deferred-row-with-an-open-reference-is-blocked" 0 "$(payload "$TR_MERGE")"
write_record "$ENTITY/RICH-TODOs.md" normal

if python3 - "$SCRIPT_DIR/guard-idle-land.py" "$ENTITY/RICH-TODOs.md" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gil", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rows, reason = m.parse_record(open(sys.argv[2], encoding="utf-8").read(), "Next")
assert rows is not None, reason
st = {r["num"]: r["state"] for r in rows}
assert st["1"] == "done" and st["2"] == "done", st
assert st["3"] == "free", st                 # "engine free"
assert st["4"] == "free", st                 # "engine free after 1-2", both done
assert st["5"] == "free", st                 # an em dash
assert st["6"] == "blocked", st              # a real blocker
free = [r for r in rows if r["state"] == "free"]
assert free[0]["num"] == "3", [r["num"] for r in free]
PY
then
    printf '  PASS  k.record-states-are-derived-from-the-table\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  k.record-states-are-derived-from-the-table\n'; FAIL=$((FAIL + 1))
fi

if python3 - "$SCRIPT_DIR/guard-idle-land.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gil", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
doc = """## Next

| # | Item | Blocked by |
|---|---|---|
| 9 | **A thing** | probably fine, ask Mark |
| 10 | **Another** | after the release |
"""
rows, reason = m.parse_record(doc, "Next")
assert rows is not None, reason
assert all(r["state"] == "blocked" for r in rows), [(r["num"], r["state"]) for r in rows]
PY
then
    printf '  PASS  m.an-unrecognised-blocker-is-blocked-not-free\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  m.an-unrecognised-blocker-is-blocked-not-free\n'; FAIL=$((FAIL + 1))
fi

write_record "$ENTITY/RICH-TODOs.md" no-section
run_case "n.no-such-section-is-inert-and-says-so" 0 "$(payload "$TR_MERGE")" "INERT"
write_record "$ENTITY/RICH-TODOs.md" no-table
run_case "o.no-table-is-inert-and-says-so" 0 "$(payload "$TR_MERGE")" "INERT"
write_record "$ENTITY/RICH-TODOs.md" normal

# Two candidate records: a gate that guesses is not a gate.
OTHER="$SANDBOX/other-record"
mkdir -p "$OTHER"
git -C "$OTHER" init -q . >/dev/null 2>&1
: > "$OTHER/.ceo-todos"
write_record "$OTHER/RICH-TODOs.md" normal
run_case "p.two-candidate-records-is-inert-and-says-so" 0 \
    "$(payload "$TR_MERGE")" "candidate records"
rm -rf "$OTHER"

# The record with no .ceo-todos beside it: the deferral target does not exist,
# so there is nowhere honest to send the row and the gate stands down.
mv "$ENTITY/.ceo-todos" "$SANDBOX/ceo-todos.bak"
run_case "q.record-without-a-deferral-declaration-is-inert" 0 \
    "$(payload "$TR_MERGE")" "INERT"
mv "$SANDBOX/ceo-todos.bak" "$ENTITY/.ceo-todos"

# --- SAFETY: never strand a session ---------------------------------------
run_case "r.stop-hook-active-stands-down" 0 "$(payload "$TR_MERGE" true)"

printf '%s' "$(payload "$TR_MERGE" false "$UNADOPTED")" \
    | RICHOS_ENTITY_ROOT="$UNADOPTED" "$HOOK" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    printf '  PASS  s.unadopted-repository-passes\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  s.unadopted-repository-passes\n'; FAIL=$((FAIL + 1))
fi

printf 'CHECK_IDLE_LAND=0\n' > "$ENTITY/orchestration.config"
run_case "t.explicit-opt-out-says-so" 0 "$(payload "$TR_MERGE")" "STOOD DOWN"
: > "$ENTITY/orchestration.config"

run_case "u.unparseable-payload-passes" 0 'not json at all {{{'

run_case "v.no-prompt-id-cannot-scope-the-turn" 0 \
    "$(payload "$TR_MERGE" false "$ENTITY" 0 -)"
if [ -n "$LAST_ERR" ]; then
    printf '  FAIL  v2.no-prompt-id-is-silent (said: %s)\n' "${LAST_ERR:0:80}"
    FAIL=$((FAIL + 1))
else
    printf '  PASS  v2.no-prompt-id-is-silent\n'; PASS=$((PASS + 1))
fi

run_case "w.missing-transcript-passes" 0 \
    "$(payload "$SANDBOX/no-such-transcript.jsonl")"

# Report-only. The gate says everything it would have said and lets the turn end.
printf 'IDLE_LAND_ENFORCE=0\n' > "$ENTITY/orchestration.config"
run_case "y.report-only-mode-does-not-block" 0 "$(payload "$TR_MERGE")" "report only"
: > "$ENTITY/orchestration.config"

# Broken install: the root contract is gone. A PreToolUse guard blocks here.
# This one must NOT, or a broken install makes every turn unendable.
BROKEN="$SANDBOX/broken-engine/scripts/hooks"
mkdir -p "$BROKEN"
cp "$HOOK" "$BROKEN/guard-idle-land.sh"
cp "$SCRIPT_DIR/guard-idle-land.py" "$BROKEN/guard-idle-land.py"
err="$(mktemp "$SANDBOX/err.XXXXXX")"
# Fed from a FILE, not a pipe. This path bails out before it reads stdin, so a
# pipe would leave `printf` writing into a closed descriptor; under `pipefail`
# that EPIPE becomes the pipeline's status and the case fails for a reason that
# has nothing to do with the hook.
pay="$(mktemp "$SANDBOX/pay.XXXXXX")"
payload "$TR_MERGE" > "$pay"
RICHOS_ENTITY_ROOT="$ENTITY" bash "$BROKEN/guard-idle-land.sh" \
    <"$pay" >/dev/null 2>"$err"
rc=$?
rm -f "$pay"
if [ "$rc" -eq 0 ] && grep -qF "BROKEN INSTALL" "$err"; then
    printf '  PASS  x.broken-install-passes-loudly\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  x.broken-install-passes-loudly (exit %s)\n' "$rc"; FAIL=$((FAIL + 1))
fi
rm -f "$err"

# --- RECORD ----------------------------------------------------------------
LOG="$ENTITY/.claude/state/idle-land-checks.jsonl"
if [ -s "$LOG" ] && python3 - "$LOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
verdicts = {r["verdict"] for r in rows}
for want in ("block", "dispatched", "background-running", "held", "backlog-empty"):
    assert want in verdicts, (want, sorted(verdicts))
assert any(r.get("free") for r in rows), "no derived free-row count recorded"
PY
then
    printf '  PASS  z.observation-record-written\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  z.observation-record-written\n'; FAIL=$((FAIL + 1))
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf '✓ %s/%s passed\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '✗ %s/%s passed — %s FAILED\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
exit 1
