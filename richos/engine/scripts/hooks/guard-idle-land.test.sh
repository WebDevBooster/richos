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
#   THE SECOND COMPLETION SIGNAL — a teammate handing work back
#     (AA)  a teammate finished, no git command at all      -> exit 2
#     (AA1) the refusal NAMES the teammate that finished
#     (AA2) a finished BACKGROUND COMMAND is not a teammate -> exit 0
#     (AA3) an agent stopped BY THE USER is not a delivery  -> exit 0
#     (AA4) a finish without <status>completed</status>     -> exit 0
#     (AA5) a finish answered by a dispatch                 -> exit 0
#   NOTHING IS OWED TO THE CEO — the two legitimate stops that had no route
#     (AB)  a question was put to him this turn             -> exit 0
#     (AC)  he said he is going to bed                      -> exit 0
#     (AD)  a BACKGROUNDED tool call counts as started      -> exit 0
#   THE DECLARATION — the only live escape, and it is a sentence
#     (AE)  a valid `stop-declared:` line                   -> exit 0
#     (AE1) the case AND the reason reach the operator, with the
#           "declared, not verified" caveat attached
#     (AE2) a declaration short on WORDS                    -> exit 2 + why
#     (AE2b) a declaration short on CHARACTERS               -> exit 2 + why
#     (AE3) a case outside the closed set of three          -> exit 2 + why
#     (AE4) a declaration inside a FENCED BLOCK exempts nothing -> exit 2
#     (AE4b) a declaration mentioned MID-SENTENCE exempts nothing -> exit 2
#           (two defenses, one fixture each: quoting the refusal, or this
#            guard's own documentation, can never switch it off)
#   THE REFUSAL IS PART OF THE DELIVERABLE
#     (AF1) it names what completed, what is unblocked and available, and
#           the exact declaration line that would have permitted the stop
#   THE FIVE NEGATIVE CASES
#     (b)  lands AND dispatches                            -> exit 0
#     (c)  lands while tasks run AND a row is free         -> exit 2
#          (THIS CASE INVERTED on 2026-09-01. It read 0, and that blanket
#           stand-down fired on 44 of 107 real landing turns — 41% — while
#           the gate blocked exactly once in its life. `background_tasks` is
#           the host's whole task registry, not a list of teammates.)
#     (c2) tasks run and EVERY remaining row is blocked    -> exit 0
#          (the legitimate version: "running AND the next step depends on
#           it", answered by the record's own `Blocked by` column)
#     (c3) tasks run and the stop is DECLARED              -> exit 0
#     (d)  lands, backlog fully struck through / blocked   -> exit 0
#     (e)  no landing in this turn at all                  -> exit 0
#     (f)  the operator called a hold                      -> exit 0
#     (f2) a hold word inside a HOST-written prompt        -> exit 2
#     (f3) a hold word inside the operator's own code span -> exit 2
#          (f2 and f3 exist separately because two different defenses stop the
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
#     (m)  an unrecognized blocker cell is BLOCKED, quietly
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
#   {"bgbash": "..."}          the same, sent to the background
#   {"agent": "..."}           an assistant Agent tool_use
#   {"tool": "..."}            any other assistant tool_use, by name
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
    if "bash" in step or "bgbash" in step:
        bg = "bgbash" in step
        inp = {"command": step["bgbash" if bg else "bash"]}
        if bg:
            inp["run_in_background"] = True
        rows.append({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Bash", "input": inp}]}})
        rows.append({"type": "user", "promptId": cur, "cwd": cwd,
                     "message": {"content": [
                         {"type": "tool_result", "content": "ok"}]}})
        continue
    if "tool" in step:
        rows.append({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": step["tool"], "input": {}}]}})
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
# defenses stop the real false positive — the host-prompt filter and the
# code-span strip — and a fixture that trips both proves neither: remove one
# and the case still passes. So there is a fixture per defense, and the
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

# --- fixtures for the SECOND completion signal -----------------------------
# The host's real shape, reproduced field for field. It is a user record with a
# promptSource, carrying a task-notification whose status is `completed` and
# whose summary is `Agent "<title>" finished` -- and the record carries the
# turn's own promptId, so a completion OPENS a turn.
notif() { # <status> <summary>
    printf '<task-notification>\n<task-id>abc123</task-id>\n<tool-use-id>toolu_01X</tool-use-id>\n<status>%s</status>\n<summary>%s</summary>\n<note>A task-notification fires each time this agent stops with no live background children of its own.</note>\n<result>Worktree, branch and SHAs are in the summary above.</result>\n</task-notification>' "$1" "$2"
}

jq_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

# A teammate finished and the turn did NOTHING ELSE -- no git command at all.
# This is the second of the two failures reported on 2026-09-01, and the first
# version of this gate could not see it, because `ops` was an early exit.
TR_FINISH="$SANDBOX/finish.jsonl"
mk_tr "$TR_FINISH" "$(printf '[{"machine":%s},{"bash":%s}]' \
    "$(jq_str "$(notif completed 'Agent "Rebuild the corpus" finished')")" \
    "$(jq_str "cd $ENTITY && git log --oneline -3")")"

# A BACKGROUND COMMAND finishing is not a teammate handing work back. Same
# envelope, same status, different summary -- and the gate must tell them apart
# on the summary alone.
TR_FINISH_BG="$SANDBOX/finish-bg.jsonl"
mk_tr "$TR_FINISH_BG" "$(printf '[{"machine":%s},{"bash":%s}]' \
    "$(jq_str "$(notif completed 'Background command "npm test" completed (exit code 0)')")" \
    "$(jq_str "cd $ENTITY && git log --oneline -3")")"

# The operator killing an agent is the operator taking the turn, not a delivery.
TR_FINISH_KILLED="$SANDBOX/finish-killed.jsonl"
mk_tr "$TR_FINISH_KILLED" "$(printf '[{"machine":%s},{"bash":%s}]' \
    "$(jq_str "$(notif completed 'Agent "Rebuild the corpus" was stopped by user')")" \
    "$(jq_str "cd $ENTITY && git log --oneline -3")")"

# A finish summary with a status that is NOT `completed`. Both halves are
# required, so this one is silent.
TR_FINISH_FAILED="$SANDBOX/finish-failed.jsonl"
mk_tr "$TR_FINISH_FAILED" "$(printf '[{"machine":%s},{"bash":%s}]' \
    "$(jq_str "$(notif failed 'Agent "Rebuild the corpus" finished')")" \
    "$(jq_str "cd $ENTITY && git log --oneline -3")")"

# A finish, answered by a dispatch. The correct shape, and it must stay silent.
TR_FINISH_AGENT="$SANDBOX/finish-agent.jsonl"
mk_tr "$TR_FINISH_AGENT" "$(printf '[{"machine":%s},{"agent":"norm-opus-a1"}]' \
    "$(jq_str "$(notif completed 'Agent "Rebuild the corpus" finished')")")"

# --- fixtures for "nothing is owed to the CEO" -----------------------------
# A land, and a question put to him in the same turn. Ending on a question he
# has to answer is the one move nobody else can make.
TR_MERGE_ASK="$SANDBOX/merge-ask.jsonl"
mk_tr "$TR_MERGE_ASK" "$(printf '[{"prompt":"land it"},{"bash":%s},{"tool":"AskUserQuestion"}]' \
    "$(jq_str "$MERGE_CMD")")"

# A land, and the operator saying HE is stopping -- which is not an instruction
# to hold, and is the far commoner way a night actually ends.
TR_BED="$SANDBOX/bed.jsonl"
mk_tr "$TR_BED" "$(printf '[{"prompt":"Land that and I will look in the morning, I am going to bed."},{"bash":%s}]' \
    "$(jq_str "$MERGE_CMD")")"

# A land, and a tool call sent to the background. That IS work started.
TR_MERGE_BG="$SANDBOX/merge-bg.jsonl"
mk_tr "$TR_MERGE_BG" "$(printf '[{"prompt":"land it"},{"bash":%s},{"bgbash":%s}]' \
    "$(jq_str "$MERGE_CMD")" \
    "$(jq_str "cd $ENTITY && sleep 600")")"

# --- payload builder -------------------------------------------------------
payload() { # [transcript] [stop_hook_active] [cwd] [n-running] [prompt_id] [msg]
    python3 - "${1:-$EMPTY_TR}" "${2:-false}" "${3:-$ENTITY}" "${4:-0}" \
             "${5:-$PROMPT_ID}" "$SESSION_ID" "${6:-Landed and reported.}" <<'PY'
import json, sys
tr, active, cwd, running, pid, sid, msg = sys.argv[1:8]
p = {
    "hook_event_name": "Stop",
    "session_id": sid,
    "transcript_path": tr,
    "cwd": cwd,
    "permission_mode": "bypassPermissions",
    "stop_hook_active": active == "true",
    "last_assistant_message": msg,
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
LAST_OUT=""
run_case() { # <name> <expected-exit> <payload-json> [needle-in-stderr]
    local name="$1" want="$2" json="$3" needle="${4:-}" got err out
    err="$(mktemp "$SANDBOX/err.XXXXXX")"
    out="$(mktemp "$SANDBOX/out.XXXXXX")"
    printf '%s' "$json" | RICHOS_ENTITY_ROOT="$ENTITY" "$HOOK" >"$out" 2>"$err"
    got=$?
    LAST_OUT="$(cat "$out")"
    rm -f "$out"
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

# The refusal headline, in one place. It changed when the trigger widened from
# "landed" to "completed", and seven cases asserted the old wording.
BLOCK_HEAD="WORK COMPLETED, NOTHING STARTED"

echo "=== guard-idle-land.sh ==="

# --- THE POSITIVE CONTROL --------------------------------------------------
run_case "a.merge-and-start-nothing-blocks" 2 \
    "$(payload "$TR_MERGE")" \
    "$BLOCK_HEAD"

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
    "$(payload "$TR_REAL")" "$BLOCK_HEAD"

run_case "a3.dash-m-subject-is-not-the-merged-ref" 2 \
    "$(payload "$TR_MSGFIRST")" "$BLOCK_HEAD"

run_case "a4.push-with-head-at-upstream-blocks" 2 \
    "$(payload "$TR_PUSH")" "$BLOCK_HEAD"

# --- THE FIVE NEGATIVE CASES ----------------------------------------------
run_case "b.lands-and-dispatches-passes" 0 "$(payload "$TR_MERGE_AGENT")"

# THE CASE THAT INVERTED, AND THE REASON IS THE WHOLE FIX.
# This read `0` until 2026-09-01: a landing turn with anything at all in
# `background_tasks` was waved through. Measured on this machine, that
# suppressor fired on 44 of 107 landing turns -- 41% -- and the gate blocked
# ONCE in its entire life. `background_tasks` is the host's whole task registry
# (teammates, subagents, shells, monitors, workflows, scans), and this
# orchestrator keeps ten to fifteen of them alive at all times.
#
# The legitimate stop is NARROWER than that suppressor was: "a teammate is
# running AND THE NEXT STEP DEPENDS ON ITS RESULT". Dependency is what the
# record's `Blocked by` column says, so c2 below is the case that must pass and
# this one is the case that must not.
run_case "c.lands-while-tasks-run-and-a-row-is-free-BLOCKS" 2 \
    "$(payload "$TR_MERGE" false "$ENTITY" 3)" "$BLOCK_HEAD"

# LEGITIMATE STOP 3, answered by the record rather than by a count of processes:
# three tasks running and every remaining row marked blocked.
write_record "$ENTITY/RICH-TODOs.md" exhausted
run_case "c2.LEGITIMATE-STOP-teammate-running-and-every-row-blocked" 0 \
    "$(payload "$TR_MERGE" false "$ENTITY" 3)"
write_record "$ENTITY/RICH-TODOs.md" normal

# LEGITIMATE STOP 3, answered by the DECLARATION, for the case where the record
# is right in general and wrong in this moment.
run_case "c3.LEGITIMATE-STOP-teammate-running-declared" 0 \
    "$(payload "$TR_MERGE" false "$ENTITY" 3 "$PROMPT_ID" \
       "Landed it.

stop-declared: waiting-on-teammate — row 3 is the wire protocol handshake and mark-opus-t2 is still rewriting the schema it binds to, so starting it now would be rework.")"

# The raw sentinel must NOT reach the host -- the wrapper consumes it and emits
# a systemMessage, because a Stop hook's stdout is parsed as JSON and a stray
# tab-delimited line there is a broken hook, not a notice.
C3_BAD=""
printf '%s' "$LAST_OUT" | grep -q "RICHOS_STOP_DECLARED" && C3_BAD="raw sentinel leaked to stdout"
printf '%s' "$LAST_OUT" | grep -q "systemMessage" || C3_BAD="$C3_BAD; no systemMessage"
printf '%s' "$LAST_OUT" | grep -q "STOP DECLARED" || C3_BAD="$C3_BAD; not announced"
printf '%s' "$LAST_OUT" | grep -q "waiting-on-teammate" || C3_BAD="$C3_BAD; case not named"
if [ -z "$C3_BAD" ]; then
    printf '  PASS  c3b.a-declared-stop-is-announced-to-the-operator\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  c3b.a-declared-stop-is-announced-to-the-operator (%s)\n' "$C3_BAD"
    FAIL=$((FAIL + 1))
fi

write_record "$ENTITY/RICH-TODOs.md" exhausted
run_case "d.lands-with-nothing-unblocked-passes" 0 "$(payload "$TR_MERGE")"
write_record "$ENTITY/RICH-TODOs.md" normal

run_case "e.no-landing-passes" 0 "$(payload "$TR_NOLAND")"

run_case "f.operator-called-a-hold-passes" 0 "$(payload "$TR_HOLD")"

# The hold suppressor must not be reachable from a HOST-written prompt, and not
# from a code span. Both halves of the real false positive, in one case.
run_case "f2.quoted-hold-word-in-a-machine-prompt-does-not-suppress" 2 \
    "$(payload "$TR_QUOTED_HOLD")" "$BLOCK_HEAD"

run_case "f3.hold-word-inside-a-code-span-does-not-suppress" 2 \
    "$(payload "$TR_OPERATOR_CODE_HOLD")" "$BLOCK_HEAD"

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
    "$(payload "$TR_AGENT_EARLIER")" "$BLOCK_HEAD"
run_case "j.agent-in-this-turn-passes" 0 "$(payload "$TR_MERGE_AGENT")"

# --- THE SECOND COMPLETION SIGNAL -----------------------------------------
# A teammate finishing is the other way work completes here, and the first
# version of this gate was blind to it: `ops` was an early return, so a turn
# with no git command in it could not be evaluated at all. This is the second of
# the two failures the operator reported on 2026-09-01.
run_case "AA.a-teammate-finished-and-nothing-started-BLOCKS" 2 \
    "$(payload "$TR_FINISH")" "$BLOCK_HEAD"

if printf '%s' "$LAST_ERR" | grep -qF "Rebuild the corpus"; then
    printf '  PASS  AA1.refusal-names-the-teammate-that-finished\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  AA1.refusal-names-the-teammate-that-finished\n'; FAIL=$((FAIL + 1))
fi

# Three narrowings, one case each, because a fixture that trips all three proves
# none of them.
run_case "AA2.a-finished-BACKGROUND-COMMAND-is-not-a-teammate" 0 \
    "$(payload "$TR_FINISH_BG")"
run_case "AA3.an-agent-STOPPED-BY-THE-USER-is-not-a-delivery" 0 \
    "$(payload "$TR_FINISH_KILLED")"
run_case "AA4.a-finish-without-completed-status-is-not-a-delivery" 0 \
    "$(payload "$TR_FINISH_FAILED")"
run_case "AA5.a-finish-answered-by-a-dispatch-passes" 0 \
    "$(payload "$TR_FINISH_AGENT")"

# --- NOTHING IS OWED TO THE CEO -------------------------------------------
# LEGITIMATE STOP 2, in its two real forms. Neither existed before: the first
# version of this gate would have refused the turn in which the orchestrator
# put a decision to him, and the turn in which he said he was going to bed.
run_case "AB.LEGITIMATE-STOP-a-question-was-put-to-the-CEO" 0 \
    "$(payload "$TR_MERGE_ASK")"
run_case "AC.LEGITIMATE-STOP-the-operator-is-going-to-bed" 0 \
    "$(payload "$TR_BED")"

# A tool call sent to the background IS work started -- the turn handed
# something off. It belongs with the dispatch, not with the stand-down.
run_case "AD.a-backgrounded-tool-call-counts-as-started" 0 \
    "$(payload "$TR_MERGE_BG")"

# --- THE DECLARATION -------------------------------------------------------
# LEGITIMATE STOP 1, and the whole argument for why the escape is a sentence
# rather than a flag: it can only be written by someone who has looked.
run_case "AE.LEGITIMATE-STOP-declared-nothing-unblocked" 0 \
    "$(payload "$TR_MERGE" false "$ENTITY" 0 "$PROMPT_ID" \
       "Landed and pushed.

stop-declared: nothing-unblocked — row 3 needs the CEO to choose between the two protocol shapes before anyone can write a line of it, and rows 4 to 6 are behind it.")"

# THE REASON ITSELF, VERBATIM, IN FRONT OF HIM. Half the value of a declaration
# over a flag is that the sentence is read by the person the stop affects; a
# notice that named only the case would be a flag with a longer spelling.
AE_BAD=""
printf '%s' "$LAST_OUT" | grep -q "nothing-unblocked" || AE_BAD="$AE_BAD (case)"
printf '%s' "$LAST_OUT" | grep -qF "choose between the two protocol shapes" || AE_BAD="$AE_BAD (reason)"
printf '%s' "$LAST_OUT" | grep -qF "DECLARED AND NOT VERIFIED" || AE_BAD="$AE_BAD (unverified-caveat)"
if [ -z "$AE_BAD" ]; then
    printf '  PASS  AE1.the-declared-case-and-reason-reach-the-operator\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  AE1.the-declared-case-and-reason-reach-the-operator%s\n' "$AE_BAD"
    FAIL=$((FAIL + 1))
fi

# A BARE MARKER EXEMPTS NOTHING. Three ways to get it wrong, three cases, and
# the refusal has to say WHICH -- a rejection the writer cannot diagnose is a
# gate he unwires.
# TWO FLOORS, TWO FIXTURES. A reason has to be long enough AND wordy enough,
# and the mutation run found that one fixture tripping both proves neither: with
# the word floor removed the suite stayed green, because the character floor was
# still catching the same string.
#
# AE2 is short on WORDS and long enough on characters.
run_case "AE2.a-declaration-with-too-few-words-is-REJECTED" 2 \
    "$(payload "$TR_MERGE" false "$ENTITY" 0 "$PROMPT_ID" \
       "Landed.

stop-declared: nothing-unblocked — unelaborated-justification-supplied-as-noted")" \
    "YOUR DECLARATION WAS REJECTED"

# AE2b is long enough on WORDS and short on characters.
run_case "AE2b.a-declaration-with-too-few-characters-is-REJECTED" 2 \
    "$(payload "$TR_MERGE" false "$ENTITY" 0 "$PROMPT_ID" \
       "Landed.

stop-declared: nothing-unblocked — it is not worth it now")" \
    "YOUR DECLARATION WAS REJECTED"

run_case "AE3.a-case-that-is-not-one-of-the-three-is-REJECTED" 2 \
    "$(payload "$TR_MERGE" false "$ENTITY" 0 "$PROMPT_ID" \
       "Landed.

stop-declared: busy — I have a great deal of other work in flight right now and this can wait.")" \
    "is not one of the three cases"

# QUOTING THE REFUSAL MUST NEVER DISARM THE GATE. The refusal text prints the
# declaration line as an example, so pasting it back -- or quoting this guard's
# own documentation -- must not switch it off. TWO SEPARATE DEFENSES do that, and
# the mutation run proved a single fixture proves neither: the inline case was
# caught by the line anchor, so removing the code-span strip left the suite
# green. So there is a fixture per defense, exactly as f2/f3 do for the hold.
#
# AE4 is the FENCED paste -- the realistic one, since the refusal indents its
# example. Only the code-span strip stops this.
run_case "AE4.a-declaration-inside-a-fenced-block-does-NOT-exempt" 2 \
    "$(payload "$TR_MERGE" false "$ENTITY" 0 "$PROMPT_ID" \
       "Landed. The hook told me to write this, which I am quoting rather than declaring:

\`\`\`
stop-declared: nothing-unblocked — a full sentence explaining why nothing at all is left to start
\`\`\`")" \
    "$BLOCK_HEAD"

# AE4b is the INLINE mention, mid-sentence. Only the line anchor stops this.
run_case "AE4b.a-declaration-mentioned-mid-sentence-does-NOT-exempt" 2 \
    "$(payload "$TR_MERGE" false "$ENTITY" 0 "$PROMPT_ID" \
       "Landed. The hook told me to write stop-declared: nothing-unblocked — a full sentence explaining why nothing is left, and I am describing that rather than doing it.")" \
    "$BLOCK_HEAD"

# --- THE REFUSAL IS PART OF THE DELIVERABLE -------------------------------
# It is read mid-turn by the thing being refused, and a refusal that says only
# "you stopped early" rebuilds the problem one level up: the reader has to
# reconstruct what completed, what is available, and what would have been
# allowed. All three are asserted, separately.
run_case "AF.refusal-is-actionable" 2 "$(payload "$TR_MERGE")" "$BLOCK_HEAD"
AF_MISSING=""
printf '%s' "$LAST_ERR" | grep -qF "WHAT COMPLETED IN THIS TURN" || AF_MISSING="$AF_MISSING (what-completed)"
printf '%s' "$LAST_ERR" | grep -qF "UNBLOCKED AND AVAILABLE TO START" || AF_MISSING="$AF_MISSING (what-is-available)"
printf '%s' "$LAST_ERR" | grep -qF "stop-declared: <case>" || AF_MISSING="$AF_MISSING (the-exact-line)"
printf '%s' "$LAST_ERR" | grep -qF "nothing-unblocked" || AF_MISSING="$AF_MISSING (case-names)"
printf '%s' "$LAST_ERR" | grep -qF "waiting-on-teammate" || AF_MISSING="$AF_MISSING (case-names-2)"
if [ -z "$AF_MISSING" ]; then
    printf '  PASS  AF1.refusal-names-completed-available-and-the-exact-declaration\n'
    PASS=$((PASS + 1))
else
    printf '  FAIL  AF1.refusal-names-completed-available-and-the-exact-declaration%s\n' "$AF_MISSING"
    FAIL=$((FAIL + 1))
fi

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
    printf '  PASS  m.an-unrecognized-blocker-is-blocked-not-free\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  m.an-unrecognized-blocker-is-blocked-not-free\n'; FAIL=$((FAIL + 1))
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

# --- t. THE OPT-OUT IS SEEN BY THE OPERATOR, NOT JUST BY THE TRANSCRIPT -----
#
# This case used to assert the notice appeared on STDERR, and passed. It was
# asserting the defect. Measured against 2.1.251, a Stop hook's stderr and its
# plain stdout are both filed into the transcript as a `hook_success`
# attachment and rendered to the operator NOWHERE; only a stdout
# {"systemMessage": ...} reaches his scroll. So the old assertion confirmed that
# this gate could be switched off and say so where nobody would ever read it,
# which is indistinguishable from not saying so at all.
#
# Both halves are asserted, because "it is on the right channel" and "it is no
# longer only on the wrong one" are different claims and only the pair rules out
# a notice that was duplicated rather than moved.
printf 'CHECK_IDLE_LAND=0\n' > "$ENTITY/orchestration.config"
rm -rf "$ENTITY/.claude/state/stop-hook-notices"
T_OUT="$(mktemp "$SANDBOX/tout.XXXXXX")"; T_ERR="$(mktemp "$SANDBOX/terr.XXXXXX")"
printf '%s' "$(payload "$TR_MERGE")" | RICHOS_ENTITY_ROOT="$ENTITY" "$HOOK" >"$T_OUT" 2>"$T_ERR"
T_RC=$?
if [ "$T_RC" -ne 0 ]; then
    printf '  FAIL  t.explicit-opt-out-says-so (expected exit 0, got %s)\n' "$T_RC"; FAIL=$((FAIL + 1))
elif ! grep -qF 'STOOD DOWN' "$T_OUT"; then
    printf '  FAIL  t.explicit-opt-out-says-so (stdout carries no stand-down notice)\n'; FAIL=$((FAIL + 1))
elif ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d.get("systemMessage"),str) else 1)' "$T_OUT" 2>/dev/null; then
    printf '  FAIL  t.explicit-opt-out-says-so (stdout is not valid JSON with a string systemMessage — the operator still cannot see it)\n'; FAIL=$((FAIL + 1))
elif grep -qF 'STOOD DOWN' "$T_ERR"; then
    printf '  FAIL  t.explicit-opt-out-says-so (still announced on stderr — the invisible channel was duplicated, not abandoned)\n'; FAIL=$((FAIL + 1))
else
    printf '  PASS  t.explicit-opt-out-says-so\n'; PASS=$((PASS + 1))
fi

# t2. AND IT DOES NOT REPEAT while the condition is unchanged — the state-change
# rule in scripts/lib/stop-hook-notice.sh. Text repeated under every turn is
# text the eye stops reading, and an unread notice is worth what the stderr one
# was worth.
printf '%s' "$(payload "$TR_MERGE")" | RICHOS_ENTITY_ROOT="$ENTITY" "$HOOK" >"$T_OUT" 2>/dev/null
if [ -s "$T_OUT" ]; then
    printf '  FAIL  t2.opt-out-does-not-repeat-while-unchanged (announced again: %s)\n' "$(head -c 120 "$T_OUT")"; FAIL=$((FAIL + 1))
else
    printf '  PASS  t2.opt-out-does-not-repeat-while-unchanged\n'; PASS=$((PASS + 1))
fi

# t3. THE NEGATIVE CONTROL for t2 — silence there must mean "unchanged", not
# "this hook never prints". Turn the gate back on in the same session: the state
# changed, so the recovery IS announced.
: > "$ENTITY/orchestration.config"
printf '%s' "$(payload "$TR_MERGE")" | RICHOS_ENTITY_ROOT="$ENTITY" "$HOOK" >"$T_OUT" 2>/dev/null || true
if grep -qF 'RUNNING AGAIN' "$T_OUT"; then
    printf '  PASS  t3.recovery-is-announced-so-silence-means-unchanged\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  t3.recovery-is-announced-so-silence-means-unchanged (nothing said when the gate came back: %s)\n' "$(head -c 120 "$T_OUT")"; FAIL=$((FAIL + 1))
fi
rm -f "$T_OUT" "$T_ERR"
rm -rf "$ENTITY/.claude/state/stop-hook-notices"
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
# `background-running` is GONE from this list on purpose: it was the verdict
# that stood the gate down on 41% of landing turns, and there is no longer any
# path that produces it. `declared` and `asked-ceo` are the two new ways a turn
# is let through, and both must be recorded -- an escape nobody can count is an
# escape nobody can audit.
for want in ("block", "dispatched", "held", "backlog-empty",
             "declared", "asked-ceo", "no-completion"):
    assert want in verdicts, (want, sorted(verdicts))
assert "background-running" not in verdicts, "the blanket stand-down is back"
assert any(r.get("free") for r in rows), "no derived free-row count recorded"
declared = [r for r in rows if r["verdict"] == "declared"]
assert declared and all(r.get("declared", {}).get("why") for r in declared), \
    "a declared stop was not recorded with its reason"
assert any(r.get("finishes") for r in rows), "no teammate completion recorded"
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
