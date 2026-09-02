#!/usr/bin/env bash
#
# guard-resume-isolation.test.sh — regression tests for
# scripts/hooks/guard-resume-isolation.sh (the PreToolUse[SendMessage]
# resume-isolation guard).
#
# Covers:
#   (a) active recipient (present worktree)           -> exit 0
#   (a2) active recipient (in-process, non-terminal)  -> exit 0
#   (b) completed recipient (worktree landed+removed) -> exit 2 (block)
#   (b2) completed recipient (in-process, shutdown)   -> exit 2 (block)
#   (c) resume-ack: on a completed recipient          -> exit 0 + log append
#   (d) lead / reply channel (main, team-lead, user)  -> exit 0
#   (e) protocol message (structured body + type)     -> exit 0
#   (f) missing python3                               -> exit 2 (fail-closed)
#   (g) malformed payload (tool_input not object)     -> exit 2 (fail-closed)
#   (g2) unparseable top-level JSON (garbage/empty/    -> exit 2 (fail-closed)
#        truncated/control-char) — the fail-OPEN bug
#   (h) no readable team config, specific recipient   -> exit 2 (fail-closed)
#   (i) ambiguous prefix                              -> exit 2 (fail-closed)
#   (j) not-found recipient                           -> exit 2 (fail-closed)
#   (k) non-SendMessage tool                          -> exit 0 (passthrough)
#   (k2) valid non-SendMessage payload carrying a `to` -> exit 0 (passthrough,
#        not blocked — only PARSE FAILURE blocks)
#   (l) positive-shape probe: block message carries the remediation text
#   (m) THE LIVE BACKGROUND AGENT — two-sided, and the reason this suite grew.
#       Background native-isolation agents NEVER appear in the session roster
#       (CLAUDE.md: "absence != terminated"), so the roster reading refuses them
#       structurally, every time. The authoritative signal is the isolation
#       worktree LOCK, read by scripts/lib/agent-liveness.py.
#         (m1) live agent, addressed by NAME            -> exit 0 (allow)
#         (m2) live agent, addressed by agent-<id>      -> exit 0 (allow)
#         (m3) live agent, addressed by raw agent id    -> exit 0 (allow)
#         (m4) completed + worktree REMOVED             -> exit 2 (still blocks)
#         (m5) locked by a DEAD pid (stale lock)        -> exit 2 (still blocks)
#         (m6) git unqueryable -> INDETERMINATE         -> exit 2 (never "allow")
#         (m7) the refusal NAMES the authoritative source and its verdict
#         (m8) NEGATIVE CONTROL: agent-liveness.py absent -> the live agent is
#              BLOCKED. Proves the allow in (m1)-(m3) is driven by that file and
#              is not a fall-through that would pass with the resolver gone.
#
# Run directly: scripts/hooks/guard-resume-isolation.test.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- declare the root under test -------------------------------------------
# The hooks now resolve the governed repository from the SESSION (see
# scripts/lib/resolve-roots.sh), not from their own on-disk location. Run from
# a session seated in some OTHER repository, they would correctly resolve that
# repository, find no adoption marker, stand down — and every case below would
# pass by never running. Declaring the subject makes the suite independent of
# ambient session state, and exercises the env-override candidate for free.
RICHOS_ENTITY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export RICHOS_ENTITY_ROOT
# CLAUDE_PROJECT_DIR is deliberately cleared: leaving the launching session's
# value in place would leave a second, lower-precedence candidate pointing
# somewhere irrelevant, and a future precedence change would then alter these
# results silently.
unset CLAUDE_PROJECT_DIR

HOOK="$SCRIPT_DIR/guard-resume-isolation.sh"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0

# Sandbox: a fake teams dir with a session-<id> team, plus a fake repo root for
# worktree-presence checks. SESSION id "feedface..." -> session-feedface.
SANDBOX="$(mktemp -d -t guard-resume-isolation.XXXXXX)"
SESSION_ID="feedface-0000-4000-8000-000000000000"
TEAM_DIR="$SANDBOX/teams/session-feedface"
mkdir -p "$TEAM_DIR"
# Present + gone worktree dirs used by roster members below.
PRESENT_WT="$SANDBOX/repo/.claude/worktrees/agent-1111111111111111"
GONE_WT="$SANDBOX/repo/.claude/worktrees/agent-2222222222222222"
mkdir -p "$PRESENT_WT"   # exists on disk -> active
# GONE_WT intentionally NOT created -> landed + removed

cat >"$TEAM_DIR/config.json" <<JSON
{
  "name": "session-feedface",
  "members": [
    { "agentId": "team-lead@session-feedface", "name": "team-lead", "cwd": "$SANDBOX/repo" },
    { "agentId": "dev-live@session-feedface", "name": "dev-live", "cwd": "$PRESENT_WT" },
    { "agentId": "dev-inproc@session-feedface", "name": "dev-inproc", "cwd": "$SANDBOX/repo", "status": "running" },
    { "agentId": "dev-done@session-feedface", "name": "dev-done", "cwd": "$GONE_WT" },
    { "agentId": "qa-inproc@session-feedface", "name": "qa-inproc", "cwd": "$SANDBOX/repo", "status": "shutdown" },
    { "agentId": "amb-1@session-feedface", "name": "amb-one", "cwd": "$PRESENT_WT" },
    { "agentId": "amb-2@session-feedface", "name": "amb-two", "cwd": "$PRESENT_WT" }
  ]
}
JSON

export RESUME_GUARD_TEAMS_DIR="$SANDBOX/teams"

# send_json <to> <message-json-fragment>  — builds a SendMessage payload.
# <message-json-fragment> is inserted verbatim as the value of "message" (so
# callers can pass a quoted string OR an object).
send_json() {
    local to="$1" msg="$2"
    python3 - "$to" "$msg" "$SESSION_ID" <<'PY'
import json, sys
to, msg_raw, sid = sys.argv[1], sys.argv[2], sys.argv[3]
# msg_raw is a JSON fragment; parse it so strings and objects both work.
msg = json.loads(msg_raw)
print(json.dumps({"tool_name": "SendMessage",
                  "tool_input": {"to": to, "message": msg},
                  "session_id": sid}))
PY
}

run_case() { # <name> <expected-exit> <json>
    local name="$1" expected="$2" json="$3" actual
    printf '%s' "$json" | "$HOOK" >/dev/null 2>&1
    actual=$?
    if [ "$actual" -eq "$expected" ]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected exit %s, got %s)\n' "$name" "$expected" "$actual"; FAIL=$((FAIL + 1))
    fi
}

run_case_msg() { # <name> <needle> <json>
    local name="$1" needle="$2" json="$3" out
    out="$(printf '%s' "$json" | "$HOOK" 2>&1 >/dev/null)"
    if printf '%s' "$out" | grep -qF "$needle"; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (stderr missing "%s")\n' "$name" "$needle"; FAIL=$((FAIL + 1))
    fi
}

echo "=== guard-resume-isolation tests ==="

# (k) non-SendMessage passthrough
run_case "non-SendMessage tool (Bash)" 0 '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
run_case "non-SendMessage tool (Agent)" 0 '{"tool_name":"Agent","tool_input":{"name":"dev-1"}}'
# (k2) a VALID non-SendMessage payload that happens to carry a `to` naming a
# completed teammate must still pass through — only a PARSE failure blocks, never
# a well-formed event for a different tool.
run_case "non-SendMessage tool with a 'to' field (completed name) -> allow" 0 \
    '{"tool_name":"SomeOtherTool","tool_input":{"to":"dev-done","message":"x"},"session_id":"feedface-0000-4000-8000-000000000000"}'

# (a) active recipient — present worktree
run_case "active: present-worktree recipient -> allow" 0 \
    "$(send_json 'dev-live' '"Please add the health check endpoint."')"
# (a2) active recipient — in-process, non-terminal status
run_case "active: in-process running recipient -> allow" 0 \
    "$(send_json 'dev-inproc' '"Continue with the schema change."')"

# (b) completed recipient — worktree landed + removed -> block
run_case "completed: worktree-removed recipient -> block" 2 \
    "$(send_json 'dev-done' '"Please also update the tests."')"
# (b2) completed recipient — in-process shutdown -> block
run_case "completed: in-process shutdown recipient -> block" 2 \
    "$(send_json 'qa-inproc' '"One more thing to check."')"

# (l) positive-shape probe — block message carries the remediation text
run_case_msg "block message names resume-ack: escape hatch" 'resume-ack:' \
    "$(send_json 'dev-done' '"Please also update the tests."')"
run_case_msg "block message names isolation:\"worktree\" fresh-spawn path" 'isolation:"worktree"' \
    "$(send_json 'dev-done' '"Please also update the tests."')"
run_case_msg "block message names the failure mode (worktree removed)" 'worktree' \
    "$(send_json 'dev-done' '"Please also update the tests."')"

# (c) resume-ack: on a completed recipient -> allow + log append
RESUME_ACK_MSG='"resume-ack: pure question, no file writes — just confirming the deploy SHA.\nWhat SHA did you deploy?"'
run_case "resume-ack: on completed recipient -> allow" 0 \
    "$(send_json 'dev-done' "$RESUME_ACK_MSG")"
# verify the ack was appended to .claude/state/resume-acks.log (under the hook's
# REPO_ROOT). Use a copy in a sandbox repo so we assert on a controlled path
# instead of polluting the real state log.
ACK_SANDBOX="$(mktemp -d -t guard-resume-ack.XXXXXX)"
mkdir -p "$ACK_SANDBOX/scripts/hooks" "$ACK_SANDBOX/scripts/lib" "$ACK_SANDBOX/.claude"
cp "$HOOK" "$ACK_SANDBOX/scripts/hooks/guard-resume-isolation.sh"
chmod +x "$ACK_SANDBOX/scripts/hooks/guard-resume-isolation.sh"
# The copied hook resolves its library relative to its own location, and its
# root from the SESSION — so the sandbox needs both the library and an explicit
# declaration. Without the library it refuses to start; without the declaration
# it would write the log into the launching session's repository, which is the
# very behavior under repair.
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$ACK_SANDBOX/scripts/lib/"
printf 'SESSION_TEAMS_DIR=""\n' >"$ACK_SANDBOX/orchestration.config"
RESUME_GUARD_TEAMS_DIR="$SANDBOX/teams" printf '%s' "$(send_json 'dev-done' "$RESUME_ACK_MSG")" \
    | RICHOS_ENTITY_ROOT="$ACK_SANDBOX" "$ACK_SANDBOX/scripts/hooks/guard-resume-isolation.sh" >/dev/null 2>&1
if [ -f "$ACK_SANDBOX/.claude/state/resume-acks.log" ] \
   && grep -qF "to=dev-done" "$ACK_SANDBOX/.claude/state/resume-acks.log" \
   && grep -qF "resume-ack:" "$ACK_SANDBOX/.claude/state/resume-acks.log"; then
    printf '  PASS  resume-ack: appended to .claude/state/resume-acks.log\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  resume-ack: appended to .claude/state/resume-acks.log\n'; FAIL=$((FAIL + 1))
fi
# SINGLE-APPEND: Claude Code fires this hook TWICE per delivery (registered in
# both .claude/settings.json and .claude/settings.local.json, which it merges).
# Invoke the SAME resume-ack payload twice back-to-back — the log must hold
# EXACTLY ONE line, not two byte-identical duplicates.
DEDUP_SANDBOX="$(mktemp -d -t guard-resume-dedup.XXXXXX)"
mkdir -p "$DEDUP_SANDBOX/scripts/hooks" "$DEDUP_SANDBOX/scripts/lib" "$DEDUP_SANDBOX/.claude"
cp "$HOOK" "$DEDUP_SANDBOX/scripts/hooks/guard-resume-isolation.sh"
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$DEDUP_SANDBOX/scripts/lib/"
printf 'SESSION_TEAMS_DIR=""\n' >"$DEDUP_SANDBOX/orchestration.config"
chmod +x "$DEDUP_SANDBOX/scripts/hooks/guard-resume-isolation.sh"
for _ in 1 2; do
    RESUME_GUARD_TEAMS_DIR="$SANDBOX/teams" printf '%s' "$(send_json 'dev-done' "$RESUME_ACK_MSG")" \
        | RICHOS_ENTITY_ROOT="$DEDUP_SANDBOX" "$DEDUP_SANDBOX/scripts/hooks/guard-resume-isolation.sh" >/dev/null 2>&1
done
DEDUP_LINES="$(wc -l < "$DEDUP_SANDBOX/.claude/state/resume-acks.log" 2>/dev/null | tr -d ' ')"
if [ "${DEDUP_LINES:-0}" = "1" ]; then
    printf '  PASS  double-fire logs EXACTLY ONE line (dedup)\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  double-fire logged %s lines, expected 1 (dedup)\n' "${DEDUP_LINES:-0}"; FAIL=$((FAIL + 1))
fi
# A genuinely DIFFERENT resume (different recipient) must still append.
RESUME_GUARD_TEAMS_DIR="$SANDBOX/teams" printf '%s' "$(send_json 'qa-inproc' "$RESUME_ACK_MSG")" \
    | RICHOS_ENTITY_ROOT="$DEDUP_SANDBOX" "$DEDUP_SANDBOX/scripts/hooks/guard-resume-isolation.sh" >/dev/null 2>&1
DEDUP_LINES2="$(wc -l < "$DEDUP_SANDBOX/.claude/state/resume-acks.log" 2>/dev/null | tr -d ' ')"
if [ "${DEDUP_LINES2:-0}" = "2" ]; then
    printf '  PASS  a genuinely different resume still appends (dedup not over-eager)\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  different resume produced %s lines, expected 2\n' "${DEDUP_LINES2:-0}"; FAIL=$((FAIL + 1))
fi
rm -rf "$DEDUP_SANDBOX"
rm -rf "$ACK_SANDBOX"

# DEDUP IGNORES THE TIMESTAMP (the clock-boundary race fix): a same-delivery
# double-fire can straddle a UTC-second boundary so the two lines carry DIFFERENT
# timestamps. The dedup key is recipient+ack ONLY, so the duplicate must still be
# dropped. Deterministic repro: append one real line, then rewrite ONLY its
# timestamp field to a bogus, different value, then fire the IDENTICAL payload
# again — the second fire must NOT append (still exactly 1 line). This case FAILS
# against the old full-line (timestamp-inclusive) equality and PASSES against the
# recipient+ack key.
TSRACE_SANDBOX="$(mktemp -d -t guard-resume-tsrace.XXXXXX)"
mkdir -p "$TSRACE_SANDBOX/scripts/hooks" "$TSRACE_SANDBOX/scripts/lib" "$TSRACE_SANDBOX/.claude"
cp "$HOOK" "$TSRACE_SANDBOX/scripts/hooks/guard-resume-isolation.sh"
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$TSRACE_SANDBOX/scripts/lib/"
printf 'SESSION_TEAMS_DIR=""\n' >"$TSRACE_SANDBOX/orchestration.config"
chmod +x "$TSRACE_SANDBOX/scripts/hooks/guard-resume-isolation.sh"
TSRACE_LOG="$TSRACE_SANDBOX/.claude/state/resume-acks.log"
RESUME_GUARD_TEAMS_DIR="$SANDBOX/teams" printf '%s' "$(send_json 'dev-done' "$RESUME_ACK_MSG")" \
    | RICHOS_ENTITY_ROOT="$TSRACE_SANDBOX" "$TSRACE_SANDBOX/scripts/hooks/guard-resume-isolation.sh" >/dev/null 2>&1
# Rewrite field 1 (timestamp) of the logged line to a DIFFERENT value, keeping
# the recipient+ack fields byte-identical — simulating the boundary straddle.
python3 - "$TSRACE_LOG" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines()
if lines:
    parts = lines[-1].split("\t", 1)
    if len(parts) == 2:
        lines[-1] = "1999-01-01T00:00:00Z\t" + parts[1]
open(p, "w", encoding="utf-8").write(("\n".join(lines) + "\n") if lines else "")
PY
RESUME_GUARD_TEAMS_DIR="$SANDBOX/teams" printf '%s' "$(send_json 'dev-done' "$RESUME_ACK_MSG")" \
    | RICHOS_ENTITY_ROOT="$TSRACE_SANDBOX" "$TSRACE_SANDBOX/scripts/hooks/guard-resume-isolation.sh" >/dev/null 2>&1
TSRACE_LINES="$(wc -l < "$TSRACE_LOG" 2>/dev/null | tr -d ' ')"
if [ "${TSRACE_LINES:-0}" = "1" ]; then
    printf '  PASS  dedup ignores timestamp (clock-boundary race) — still 1 line\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  dedup ignores timestamp: got %s lines, expected 1\n' "${TSRACE_LINES:-0}"; FAIL=$((FAIL + 1))
fi
rm -rf "$TSRACE_SANDBOX"

# (d) lead / reply channel — never blocked (even with no roster resolution)
run_case "lead channel: to=main -> allow" 0 "$(send_json 'main' '"status?"')"
run_case "lead channel: to=team-lead -> allow" 0 "$(send_json 'team-lead' '"done."')"
run_case "lead channel: to=user -> allow" 0 "$(send_json 'user' '"here is the result."')"

# (e) protocol messages — never blocked
# structured (non-string) message body
run_case "protocol: structured body -> allow" 0 \
    "$(send_json 'dev-done' '{"type":"shutdown_response","ok":true}')"
# string body carrying a quoted protocol token
run_case "protocol: quoted token in string body -> allow" 0 \
    "$(send_json 'dev-done' '"{\"type\": \"plan_approval_response\", \"approved\": true}"')"
# messageType field set to a protocol type (build payload explicitly)
run_case "protocol: messageType field -> allow" 0 \
    "$(python3 - <<PY
import json
print(json.dumps({"tool_name":"SendMessage","tool_input":{"to":"dev-done","message":"ok","messageType":"shutdown_request"},"session_id":"$SESSION_ID"}))
PY
)"
# prose that merely MENTIONS shutdown is NOT protocol -> still blocked (completed)
run_case "prose mentioning 'shutdown' is NOT protocol -> block" 2 \
    "$(send_json 'dev-done' '"can you shutdown the extra worker after you finish?"')"

# (i) ambiguous prefix -> block
run_case "ambiguous prefix 'amb' -> block" 2 \
    "$(send_json 'amb' '"which one are you?"')"

# (j) not-found recipient -> block
run_case "not-found recipient -> block" 2 \
    "$(send_json 'ghost-agent' '"are you there?"')"
run_case_msg "not-found block message offers resume-ack path" 'resume-ack:' \
    "$(send_json 'ghost-agent' '"are you there?"')"

# (h) no readable team config for a specific recipient -> block
run_case "no team config (bad session) -> block" 2 \
    "$(python3 - <<'PY'
import json
print(json.dumps({"tool_name":"SendMessage","tool_input":{"to":"dev-live","message":"hi"},"session_id":"00000000-no-such-session"}))
PY
)"
# but main is still allowed even with no config
run_case "no team config but to=main -> allow" 0 \
    "$(python3 - <<'PY'
import json
print(json.dumps({"tool_name":"SendMessage","tool_input":{"to":"main","message":"hi"},"session_id":"00000000-no-such-session"}))
PY
)"

# (g) malformed payload (tool_input not an object) -> fail-closed
run_case "malformed: tool_input not a dict -> block" 2 \
    '{"tool_name":"SendMessage","tool_input":"not-a-dict"}'
run_case "malformed: tool_input null -> block" 2 \
    '{"tool_name":"SendMessage","tool_input":null}'

# (g2) unparseable TOP-LEVEL JSON -> fail-closed (the regression this suite guards
# against: the old two-step parse swallowed a JSON-syntax error and exited 0
# (ALLOW) before the fail-closed block was reached — see the automation QA's audit Defect #1).
run_case "garbage stdin (not JSON) -> block" 2 \
    'not json at all garbage {{{ '
run_case "empty stdin -> block" 2 \
    ''
run_case "truncated JSON -> block" 2 \
    '{"tool_name":"SendMessage","tool_input":{"to":"dev-done","message":"truncated'
# a raw control character (literal NUL-free but invalid: an unescaped newline
# inside a JSON string value) -> unparseable -> block
run_case "control-char / unescaped-newline JSON -> block" 2 \
    "$(printf '{"tool_name":"SendMessage","tool_input":{"to":"dev-done","message":"line1\nline2"}}')"
# top-level JSON that is valid but NOT an object (a bare array/number) -> block
run_case "valid JSON but not an object (array) -> block" 2 \
    '["tool_name","SendMessage"]'
run_case_msg "garbage-stdin block message names fail-closed remediation" 'resume-ack:' \
    'not json at all garbage {{{ '

# (f) missing python3 -> fail-closed. Run the hook with a PATH that has no
# python3 (a fakebin dir populated with symlinks to every tool the hook needs
# EXCEPT python3), invoked via an explicit bash so the shebang lookup is moot.
FAKEBIN="$(mktemp -d -t guard-resume-nopy.XXXXXX)"
for b in cat grep sed date tr cut mkdir head printf env dirname basename; do
    src="$(command -v "$b" 2>/dev/null)"
    [ -n "$src" ] && ln -sf "$src" "$FAKEBIN/$b"
done
NOPY_OUT="$(printf '%s' "$(send_json 'dev-live' '"hi"')" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" 2>&1 >/dev/null)"; NOPY_RC=$?
if [ "$NOPY_RC" -eq 2 ] && printf '%s' "$NOPY_OUT" | grep -qF 'python3'; then
    printf '  PASS  missing python3 -> fail-closed (exit 2)\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  missing python3 -> fail-closed (got exit %s)\n' "$NOPY_RC"; FAIL=$((FAIL + 1))
fi
rm -rf "$FAKEBIN"


# ===========================================================================
# (m) THE LIVE BACKGROUND AGENT — the two-sided canary
# ===========================================================================
# Measured 2026-09-02: three agents that scripts/agent-liveness.sh had confirmed
# ALIVE seconds earlier — isolation worktree LOCKED, locking pid running — were
# refused by this guard, by teammate NAME and by raw agentId, with "not in
# session roster". The roster is not where liveness lives. The lock is.
#
# A ONE-SIDED TEST HERE WOULD BE THE WHOLE DEFECT AGAIN, so this fixture carries
# a live agent AND a completed-and-cleaned one AND a stale lock in ONE repository
# and asserts all three outcomes against the same guard invocation shape.
#
# The fixture is a real git repository with real registered worktrees and real
# `git worktree lock` reasons in the exact form the harness writes them
# (measured, quoted in agent-liveness.py's docstring):
#     claude agent agent-<id> (pid <host session pid> start <date>)
# The LIVE lock carries THIS TEST'S OWN PID, which is running by construction;
# the stale lock carries 999999, which cannot be a pid on macOS (max 99999).
#
# NO COMMIT IS MADE. `git worktree add -b <branch>` works on an unborn HEAD, and
# a repository-identity pre-commit hook on the developer's machine would
# otherwise make this suite's result depend on the machine it runs on.
LIVE_ID="aaaa1111bbbb2222"
GONE_ID="cccc3333dddd4444"
STALE_ID="eeee5555ffff6666"
BG="$(mktemp -d -t guard-resume-bg.XXXXXX)"
BG_REPO="$BG/repo"
BG_TEAMS="$BG/teams"
BG_TDIR="$BG_TEAMS/session-feedface"
mkdir -p "$BG_REPO" "$BG_TDIR"
printf 'SESSION_TEAMS_DIR=""\n' >"$BG_REPO/orchestration.config"
git -C "$BG_REPO" init -q >/dev/null 2>&1
git -C "$BG_REPO" worktree add -q -b br-live  "$BG_REPO/.claude/worktrees/agent-$LIVE_ID"  >/dev/null 2>&1
git -C "$BG_REPO" worktree add -q -b br-stale "$BG_REPO/.claude/worktrees/agent-$STALE_ID" >/dev/null 2>&1
git -C "$BG_REPO" worktree add -q -b br-gone  "$BG_REPO/.claude/worktrees/agent-$GONE_ID"  >/dev/null 2>&1
git -C "$BG_REPO" worktree lock \
    --reason "claude agent agent-$LIVE_ID (pid $$ start Tue Sep  2 09:00:00 2026)" \
    "$BG_REPO/.claude/worktrees/agent-$LIVE_ID" >/dev/null 2>&1
git -C "$BG_REPO" worktree lock \
    --reason "claude agent agent-$STALE_ID (pid 999999 start Tue Sep  2 09:00:00 2026)" \
    "$BG_REPO/.claude/worktrees/agent-$STALE_ID" >/dev/null 2>&1
# the completed one: landed and REMOVED, exactly as the land sequence leaves it
git -C "$BG_REPO" worktree remove --force "$BG_REPO/.claude/worktrees/agent-$GONE_ID" >/dev/null 2>&1
git -C "$BG_REPO" worktree prune >/dev/null 2>&1

# THE ROSTER DOES NOT LIST ANY OF THEM. That is not an omission in the fixture,
# it is the documented shape of a background native-isolation agent.
cat >"$BG_TDIR/config.json" <<JSON
{ "name": "session-feedface",
  "members": [
    { "agentId": "team-lead@session-feedface", "name": "team-lead", "cwd": "$BG_REPO" }
  ] }
JSON
# The EXACT name -> agent id join, from the source teammate-identity.py reads
# first (worker-events.jsonl WorkerCreated.worker_name).
cat >"$BG_TDIR/worker-events.jsonl" <<JSON
{"event":"WorkerCreated","agent_id":"$LIVE_ID","worker_name":"zach-opus-live1","agent_type":"zach"}
{"event":"WorkerCreated","agent_id":"$STALE_ID","worker_name":"zach-opus-stale1","agent_type":"zach"}
{"event":"WorkerCreated","agent_id":"$GONE_ID","worker_name":"zach-opus-gone1","agent_type":"zach"}
JSON

# PRE-FLIGHT: assert the fixture is what it claims to be. A `git worktree lock`
# that silently did nothing would make (m1)-(m3) pass for the wrong reason —
# "the lock is held" and "the lock was never taken" must not read the same.
if git -C "$BG_REPO" worktree list --porcelain 2>/dev/null \
     | grep -qF "locked claude agent agent-$LIVE_ID (pid $$"; then
    printf '  PASS  fixture: the live agent worktree really is LOCKED by a running pid\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  fixture: the live agent worktree is NOT locked — every (m) case below is meaningless\n'; FAIL=$((FAIL + 1))
fi

bg_case() { # <name> <expected-exit> <to> [entity-root]
    local name="$1" expected="$2" to="$3" root="${4:-$BG_REPO}" actual
    printf '%s' "$(send_json "$to" '"main moved to abc1234. Please ack."')" \
        | RESUME_GUARD_TEAMS_DIR="$BG_TEAMS" RICHOS_ENTITY_ROOT="$root" "$HOOK" >/dev/null 2>&1
    actual=$?
    if [ "$actual" -eq "$expected" ]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected exit %s, got %s)\n' "$name" "$expected" "$actual"; FAIL=$((FAIL + 1))
    fi
}

bg_case_msg() { # <name> <needle> <to> [entity-root]
    local name="$1" needle="$2" to="$3" root="${4:-$BG_REPO}" out
    out="$(printf '%s' "$(send_json "$to" '"main moved to abc1234. Please ack."')" \
        | RESUME_GUARD_TEAMS_DIR="$BG_TEAMS" RICHOS_ENTITY_ROOT="$root" "$HOOK" 2>&1 >/dev/null)"
    if printf '%s' "$out" | grep -qF "$needle"; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (stderr missing "%s")\n' "$name" "$needle"; FAIL=$((FAIL + 1))
    fi
}

# (m1)-(m3) THE LIVE AGENT, in all three legal addressing forms. Every one of
# these exited 2 against the pre-fix guard, and needed a resume-ack: waiver.
bg_case "live background agent by NAME (not in roster) -> allow" 0 "zach-opus-live1"
bg_case "live background agent by agent-<id> -> allow" 0 "agent-$LIVE_ID"
bg_case "live background agent by RAW agent id -> allow" 0 "$LIVE_ID"

# (m4)-(m5) THE PROTECTION, UNTOUCHED. Same fixture, same guard, same shape.
bg_case "completed + worktree REMOVED -> still BLOCKED" 2 "zach-opus-gone1"
bg_case "locked by a DEAD pid (stale lock) -> still BLOCKED" 2 "zach-opus-stale1"

# (m6) INDETERMINATE IS NOT "ALLOW". Point the guard at a root that is not a git
# checkout: `git worktree list` cannot be answered, agent-liveness.py returns
# INDETERMINATE, and the ack is still required.
BG_NOGIT="$BG/nogit"
mkdir -p "$BG_NOGIT"
printf 'SESSION_TEAMS_DIR=""\n' >"$BG_NOGIT/orchestration.config"
bg_case "INDETERMINATE liveness (git unqueryable) -> BLOCKED, not allowed" 2 \
    "agent-$LIVE_ID" "$BG_NOGIT"

# (m7) the refusal NAMES the authoritative source, its verdict, and the tree it
# swept. A refusal that only quotes the roster is the 2026-09-02 defect again.
bg_case_msg "refusal names the authoritative liveness source" "agent-liveness.py" "zach-opus-gone1"
bg_case_msg "refusal names the NOT-ALIVE verdict" "NOT-ALIVE" "zach-opus-gone1"
bg_case_msg "refusal names the main checkout it swept" "main checkout swept" "zach-opus-gone1"
bg_case_msg "INDETERMINATE refusal says so in those words" "INDETERMINATE" \
    "agent-$LIVE_ID" "$BG_NOGIT"

# (m8) NEGATIVE CONTROL — the allow above must be CAUSED by agent-liveness.py.
# Copy the guard into a tree with every library it needs EXCEPT that one. If the
# live agent is still allowed, the allow was a fall-through and (m1)-(m3) prove
# nothing.
NOLIVE="$(mktemp -d -t guard-resume-nolive.XXXXXX)"
mkdir -p "$NOLIVE/scripts/hooks" "$NOLIVE/scripts/lib"
cp "$HOOK" "$NOLIVE/scripts/hooks/guard-resume-isolation.sh"
chmod +x "$NOLIVE/scripts/hooks/guard-resume-isolation.sh"
cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" \
   "$SCRIPT_DIR/../lib/teammate-identity.py" "$NOLIVE/scripts/lib/"
printf '%s' "$(send_json 'zach-opus-live1' '"main moved to abc1234. Please ack."')" \
    | RESUME_GUARD_TEAMS_DIR="$BG_TEAMS" RICHOS_ENTITY_ROOT="$BG_REPO" \
      "$NOLIVE/scripts/hooks/guard-resume-isolation.sh" >/dev/null 2>&1
NOLIVE_RC=$?
if [ "$NOLIVE_RC" -eq 2 ]; then
    printf '  PASS  NEGATIVE CONTROL: agent-liveness.py absent -> the live agent is BLOCKED\n'; PASS=$((PASS + 1))
else
    printf '  FAIL  NEGATIVE CONTROL: agent-liveness.py absent still allowed (exit %s) — the allow is a fall-through, not a decision\n' "$NOLIVE_RC"; FAIL=$((FAIL + 1))
fi
rm -rf "$NOLIVE"

git -C "$BG_REPO" worktree unlock "$BG_REPO/.claude/worktrees/agent-$LIVE_ID"  >/dev/null 2>&1
git -C "$BG_REPO" worktree unlock "$BG_REPO/.claude/worktrees/agent-$STALE_ID" >/dev/null 2>&1
rm -rf "$BG"

rm -rf "$SANDBOX"

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== guard-resume-isolation tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== guard-resume-isolation tests: all $PASS passed ==="
    exit 0
fi
