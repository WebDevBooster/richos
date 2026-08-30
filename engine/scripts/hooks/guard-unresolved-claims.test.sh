#!/usr/bin/env bash
#
# guard-unresolved-claims.test.sh — regression tests for the Stop-time claim
# gate (scripts/hooks/guard-unresolved-claims.sh + .py).
#
# THE TWO REAL FAILURES ARE REPLAYED HERE, STRUCTURALLY, NOT VERBATIM.
#   richos is a public repository, so no operator speech and no transcript text
#   is committed. Every fixture below reproduces the SHAPE of a real failure —
#   an agent name with no spawn, a SHA that names no object, a nameless action
#   claim in a turn with zero Agent calls — with invented content. The
#   measurement that justified each threshold was run against the real
#   transcripts on disk and only the NUMBERS are recorded, in the hook header.
#
# Covers:
#   BLOCKING — agent names (monotonic ground truth: the ledger only grows)
#     (a)  name never spawned, session team dir present     -> exit 2
#     (b)  name present in spawned-names.log                -> exit 0
#     (c)  name present in the roster only                  -> exit 0
#     (d)  name present in an event log only                -> exit 0
#     (e)  name never spawned, session team dir ABSENT      -> exit 0 (inert)
#     (f)  name never spawned but grounded in tool output   -> exit 0
#   BLOCKING — commit SHAs
#     (g)  SHA that resolves in the entity repo             -> exit 0
#     (h)  SHA that names no object anywhere                -> exit 2
#     (i)  dead SHA grounded in this session's tool output  -> exit 0
#   MUST NOT FIRE — the precision cases
#     (j)  UUID fragments, tool-use ids, hex-looking prose  -> exit 0
#     (k)  ratios and labels that look like paths (13/13)   -> exit 0
#     (l)  a path that does not resolve                     -> exit 0 + report
#     (m)  quoting the operator; describing another agent   -> exit 0
#     (n)  a legitimate turn end: a hold, a question, an
#          answer, a named next step awaiting a decision    -> exit 0
#   FAILURE REPLAYS
#     (o)  FAILURE 2, as written: nameless action claim,
#          zero Agent calls                                 -> exit 0 + report
#     (o2) FAILURE 2, named: the same claim naming an agent
#          that was never spawned                           -> exit 2
#     (p)  FAILURE 1: a turn naming the next step without
#          taking it                                        -> exit 0 + report
#   SAFETY — this gate must never strand a session
#     (q)  stop_hook_active=true, violation present         -> exit 0
#     (r)  repository has not adopted the engine            -> exit 0
#     (s)  CHECK_UNRESOLVED_CLAIMS=0                        -> exit 0 + notice
#     (t)  unparseable payload                              -> exit 0
#     (u)  empty last_assistant_message                     -> exit 0
#     (v)  transcript_path missing / unreadable             -> exit 2 still
#          works from last_assistant_message alone
#     (w)  broken install (resolve-roots.sh absent)         -> exit 0 + banner
#   RECORD
#     (x)  an observation line is appended for every turn
#
# Run directly: scripts/hooks/guard-unresolved-claims.test.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-unresolved-claims.sh"
unset CLAUDE_PROJECT_DIR

PASS=0
FAIL=0

SANDBOX="$(mktemp -d -t guard-unresolved-claims.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

SESSION_ID="feedface-0000-4000-8000-000000000000"
TEAMS="$SANDBOX/teams"
TEAM_DIR="$TEAMS/session-feedface"
mkdir -p "$TEAM_DIR"

printf 'norm-opus-a1\n' > "$TEAM_DIR/spawned-names.log"
cat >"$TEAM_DIR/config.json" <<'JSON'
{ "name": "session-feedface",
  "members": [ { "name": "team-lead" }, { "name": "mark-sonnet-r7" } ] }
JSON
printf '{"teammate":"echo-opus-k3"}\n' > "$TEAM_DIR/idle-events.jsonl"

# --- the governed repository ----------------------------------------------
# A real git repo, because the SHA resolver runs `git cat-file` against it.
ENTITY="$SANDBOX/entity"
mkdir -p "$ENTITY"
git -C "$ENTITY" init -q . >/dev/null 2>&1
git -C "$ENTITY" config user.email t@t.t >/dev/null 2>&1
git -C "$ENTITY" config user.name t >/dev/null 2>&1
# The operator may have a global core.hooksPath (an identity guard, a linter).
# A suite that inherits it fails for reasons that have nothing to do with the
# thing under test, so the sandbox repo gets an empty hooks dir of its own.
mkdir -p "$SANDBOX/nohooks"
git -C "$ENTITY" config core.hooksPath "$SANDBOX/nohooks" >/dev/null 2>&1
: > "$ENTITY/orchestration.config"
mkdir -p "$ENTITY/docs"
printf 'real\n' > "$ENTITY/docs/real-file.md"
git -C "$ENTITY" add -A >/dev/null 2>&1
git -C "$ENTITY" commit -qm seed >/dev/null 2>&1
LIVE_SHA="$(git -C "$ENTITY" rev-parse --short=7 HEAD)"
# Hex, 7 chars, has a digit and a letter, and names no object anywhere.
DEAD_SHA="d0d0d0d"

# A repository that never adopted the engine: no orchestration.config.
UNADOPTED="$SANDBOX/unadopted"
mkdir -p "$UNADOPTED"
git -C "$UNADOPTED" init -q . >/dev/null 2>&1

# --- transcript fixtures ---------------------------------------------------
# At Stop time the transcript holds the turn's tool_use/tool_result records but
# NOT the final assistant text. These fixtures mirror that exactly.
EMPTY_TR="$SANDBOX/empty.jsonl"
: > "$EMPTY_TR"

BASH_TR="$SANDBOX/bash-turn.jsonl"
cat >"$BASH_TR" <<JSON
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git log --oneline -3"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"$DEAD_SHA an old commit\nzz-opus-zz9 was in the ledger once"}]}}
JSON

AGENT_TR="$SANDBOX/agent-turn.jsonl"
cat >"$AGENT_TR" <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"name":"norm-opus-a1"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"agent started"}]}}
JSON

# --- payload builder -------------------------------------------------------
payload() { # <message> [transcript] [session_id] [stop_hook_active] [cwd]
    python3 - "$1" "${2:-$EMPTY_TR}" "${3:-$SESSION_ID}" "${4:-false}" "${5:-$ENTITY}" <<'PY'
import json, sys
msg, tr, sid, active, cwd = sys.argv[1:6]
print(json.dumps({
    "hook_event_name": "Stop",
    "session_id": sid,
    "transcript_path": tr,
    "cwd": cwd,
    "prompt_id": "11111111-2222-3333-4444-555555555555",
    "permission_mode": "bypassPermissions",
    "stop_hook_active": active == "true",
    "last_assistant_message": msg,
    "background_tasks": [],
    "session_crons": [],
}))
PY
}

LAST_ERR=""
run_case() { # <name> <expected-exit> <payload-json> [needle-in-stderr]
    local name="$1" want="$2" json="$3" needle="${4:-}" got err
    err="$(mktemp "$SANDBOX/err.XXXXXX")"
    printf '%s' "$json" | RICHOS_ENTITY_ROOT="$ENTITY" \
        RICHOS_CLAIMS_TEAMS_DIR="$TEAMS" "$HOOK" >/dev/null 2>"$err"
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

echo "=== guard-unresolved-claims.sh ==="

# --- BLOCKING: agent names -------------------------------------------------
run_case "a.name-never-spawned-blocks" 2 \
    "$(payload 'Dispatched sage-opus-q4 on the migration.')" \
    "never spawned"

run_case "b.name-in-ledger-passes" 0 \
    "$(payload 'norm-opus-a1 landed the fix.')"

run_case "c.name-in-roster-passes" 0 \
    "$(payload 'mark-sonnet-r7 is still running.')"

run_case "d.name-in-event-log-passes" 0 \
    "$(payload 'echo-opus-k3 finished and reported.')"

run_case "e.no-session-team-dir-is-inert" 0 \
    "$(payload 'Dispatched sage-opus-q4 on the migration.' "$EMPTY_TR" \
       'aaaaaaaa-0000-4000-8000-000000000000')"

run_case "f.name-grounded-in-tool-output-passes" 0 \
    "$(payload 'The ledger still lists zz-opus-zz9 from an earlier session.' "$BASH_TR")"

# --- BLOCKING: commit SHAs -------------------------------------------------
run_case "g.live-sha-passes" 0 \
    "$(payload "Landed at \`$LIVE_SHA\`, tree clean.")"

run_case "h.dead-sha-blocks" 2 \
    "$(payload "Landed at \`$DEAD_SHA\`, tree clean." "$EMPTY_TR")" \
    "name no object"

run_case "i.dead-sha-grounded-passes" 0 \
    "$(payload "The rewrite dropped \`$DEAD_SHA\`, so that citation is now dead." "$BASH_TR")"

# --- MUST NOT FIRE: precision ----------------------------------------------
run_case "j.uuid-and-toolid-fragments-ignored" 0 \
    "$(payload 'Prompt 49fb795d-c3cd-4fe5-92f1-1014c3f81bf1 and toolu_01LXJkEdyh9Rh68N2W8u3zVD, plus deadbeef and 1234567 in prose.')"

run_case "k.ratios-are-not-paths" 0 \
    "$(payload 'Suites green: `18/18`, guards `13/13`, criteria `44/46`.')"

run_case "l.unresolved-path-reports-never-blocks" 0 \
    "$(payload 'I deleted `docs/gone-forever.md` in the cleanup.')" \
    "not blocking"

run_case "m.describing-others-and-the-past-passes" 0 \
    "$(payload 'He said "just ship it". norm-opus-a1 already merged that yesterday, and I am not spawning anything further tonight.')"

run_case "n.legitimate-turn-end-passes" 0 \
    "$(payload 'Two options and I need your call before either: rename the field, or add a second one. Nothing is running while you decide.')"

# --- FAILURE REPLAYS -------------------------------------------------------
# FAILURE 2 as it actually occurred: an action claim with NO identifier in it.
# The identifier gate cannot see this and must not pretend to; the reporting
# layer records it. Asserting exit 0 here is the honest limit, written down.
run_case "o.failure2-nameless-claim-reports-only" 0 \
    "$(payload 'The trees are disjoint, so it goes now — dispatching it rather than queuing it.' "$BASH_TR")" \
    "in-flight dispatch claim"

# The same claim in the form the engine's naming doctrine already requires.
# Naming the agent is what moves the failure into the blocking layer.
run_case "o2.failure2-named-claim-blocks" 2 \
    "$(payload 'The trees are disjoint, so it goes now — dispatching mark-opus-v2 rather than queuing it.' "$BASH_TR")" \
    "never spawned"

# FAILURE 1: naming the next step without taking it. Sometimes correct (a hold,
# a decision point), so it is REPORTED, never blocked.
run_case "p.failure1-next-step-named-not-taken" 0 \
    "$(payload 'That leaves the scanner hole. I am spawning someone on it right after this lands.' "$BASH_TR")" \
    "in-flight dispatch claim"

# --- SAFETY: never strand a session ----------------------------------------
run_case "q.stop-hook-active-stands-down" 0 \
    "$(payload 'Dispatched sage-opus-q4 on the migration.' "$EMPTY_TR" "$SESSION_ID" true)"

printf '%s' "$(payload 'Dispatched sage-opus-q4.' "$EMPTY_TR" "$SESSION_ID" false "$UNADOPTED")" \
    | RICHOS_ENTITY_ROOT="$UNADOPTED" RICHOS_CLAIMS_TEAMS_DIR="$TEAMS" "$HOOK" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    printf '  PASS  r.unadopted-repository-passes\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  r.unadopted-repository-passes\n'; FAIL=$((FAIL + 1))
fi

printf 'CHECK_UNRESOLVED_CLAIMS=0\n' > "$ENTITY/orchestration.config"
run_case "s.explicit-opt-out-says-so" 0 \
    "$(payload 'Dispatched sage-opus-q4 on the migration.')" \
    "STOOD DOWN"
: > "$ENTITY/orchestration.config"

run_case "t.unparseable-payload-passes" 0 'not json at all {{{'

run_case "u.empty-final-message-passes" 0 "$(payload '')"

run_case "v.missing-transcript-still-blocks" 2 \
    "$(payload 'Dispatched sage-opus-q4.' "$SANDBOX/no-such-transcript.jsonl")" \
    "never spawned"

# Broken install: the root contract is gone. A PreToolUse guard blocks here.
# This one must NOT, or a broken install makes every turn unendable.
BROKEN="$SANDBOX/broken-engine/scripts/hooks"
mkdir -p "$BROKEN"
cp "$HOOK" "$BROKEN/guard-unresolved-claims.sh"
cp "$SCRIPT_DIR/guard-unresolved-claims.py" "$BROKEN/guard-unresolved-claims.py"
err="$(mktemp "$SANDBOX/err.XXXXXX")"
# Fed from a FILE, not a pipe. This path bails out before it reads stdin, so a
# pipe would leave `printf` writing into a closed descriptor; under `pipefail`
# that EPIPE becomes the pipeline's status and the case fails for a reason that
# has nothing to do with the hook. (Every other case reaches `INPUT="$(cat)"`,
# drains stdin, and is unaffected.)
pay="$(mktemp "$SANDBOX/pay.XXXXXX")"
payload 'Dispatched sage-opus-q4.' > "$pay"
RICHOS_ENTITY_ROOT="$ENTITY" bash "$BROKEN/guard-unresolved-claims.sh" \
    <"$pay" >/dev/null 2>"$err"
rc=$?
rm -f "$pay"
if [ "$rc" -eq 0 ] && grep -qF "BROKEN INSTALL" "$err"; then
    printf '  PASS  w.broken-install-passes-loudly\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  w.broken-install-passes-loudly (exit %s)\n' "$rc"; FAIL=$((FAIL + 1))
fi
rm -f "$err"

# --- RECORD ----------------------------------------------------------------
LOG="$ENTITY/.claude/state/claim-checks.jsonl"
if [ -s "$LOG" ] && python3 - "$LOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert any(r["verdict"] == "block" for r in rows), "no block recorded"
assert any(r["verdict"] == "pass" for r in rows), "no pass recorded"
assert any(r.get("prose_signal") for r in rows), "prose signal never recorded"
PY
then
    printf '  PASS  x.observation-record-written\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  x.observation-record-written\n'; FAIL=$((FAIL + 1))
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf '✓ %s/%s passed\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '✗ %s/%s passed — %s FAILED\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
exit 1
