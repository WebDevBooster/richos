#!/usr/bin/env bash
#
# inflight-two-leads.test.sh: does the in-flight push guard refuse, or skip, ANOTHER LEAD's
# worktree?
#
# THE QUESTION (Frank's F4 on the operator contract, richos-hq bd685c14,
# docs/verification/2026-09-26-operator-contract-review): behind the RichOS app, each
# conversation has its own lead, which is its own Claude session with its own team directory
# and its own SendMessage witness ledger. The guard reads WHO IS IN FLIGHT from
# `git worktree list` (every lead's agents), and WHO WAS TOLD from the landing lead's own
# ledger. Frank read the code and could not say from reading whether a worktree absent from
# the landing lead's identity index is refused or skipped (`inflight.py` identity_index,
# resolve_worktree_identity). This suite settles it by running the shipped guard and runner.
#
# THE SHAPE, as the operator runs it: one repository, two lead sessions (A lands, B does not).
#   A's agent : a native worktree, locked with a live pid, named in A's transcript.
#   B's agent : a native worktree, locked with a live pid, named only in B's transcript.
#   B's other : a hand-rolled worktree (spawn.sh's shape), presumed live, as the engine says.
# All three are cut from the base; A's land moves main under all of them. A notifies its own
# agent through the witness, exactly as a lead does, and then pushes.
#
# WHAT IS ASSERTED IS WHAT THE GUARD DOES TODAY. If Rich scopes the guard to a lead's own
# agents, the refusal cases below turn red on purpose, and this file says why they were green.
#
# Run directly:  scripts/hooks/inflight-two-leads.test.sh [--verbose]

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SRC_DIR/../.." && pwd)"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
say() { [ "$VERBOSE" -eq 1 ] && printf '\n----- %s -----\n%s\n' "$1" "$2"; return 0; }

SANDBOX="$(mktemp -d -t inflight-two-leads.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

REPO="$SANDBOX/repo"
TEAMS="$SANDBOX/teams"
SID_A="aaaa1111-1111-4000-8000-000000000000"
SID_B="bbbb2222-2222-4000-8000-000000000000"
TEAM_A="$TEAMS/session-aaaa1111"
TEAM_B="$TEAMS/session-bbbb2222"
mkdir -p "$REPO" "$TEAM_A" "$TEAM_B" "$SANDBOX/state" "$SANDBOX/wt"

# The shipped hooks and libraries, copied: they resolve their libraries beside themselves.
mkdir -p "$REPO/scripts/hooks" "$REPO/scripts/lib"
for h in guard-inflight-notify.sh notice-inflight-sends.sh; do
    cp "$SRC_DIR/$h" "$REPO/scripts/hooks/$h"
done
for l in inflight.sh inflight.py teammate-identity.py agent-liveness.py resolve-roots.sh resolve-main-checkout.sh seat-jurisdiction.sh git-jurisdiction.sh stop-hook-notice.sh; do
    cp "$SRC_DIR/../lib/$l" "$REPO/scripts/lib/$l" 2>/dev/null || true
done
cp "$ENGINE_ROOT/scripts/inflight-notify.sh" "$REPO/scripts/"
printf 'PROTECTED_PATHS="src"\n' > "$REPO/orchestration.config"

GUARD="$REPO/scripts/hooks/guard-inflight-notify.sh"
WITNESS="$REPO/scripts/hooks/notice-inflight-sends.sh"
RUNNER="$REPO/scripts/inflight-notify.sh"

export RICHOS_ENTITY_ROOT="$REPO"
export INFLIGHT_TEAMS_DIR="$TEAMS"
# The durable ack ledger, kept in the sandbox so nothing here writes the operator's own.
export RICHOS_INFLIGHT_ACK_LEDGER="$SANDBOX/state/inflight-acks.jsonl"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "$(git config user.email 2>/dev/null || echo tester@example.invalid)"
git -C "$REPO" config user.name "$(git config user.name 2>/dev/null || echo tester)"
mkdir -p "$REPO/src"
echo "one" > "$REPO/src/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "base"
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

native_agent() { # <agent-id> <branch> <file> -> echoes the worktree path
    local wt="$REPO/.claude/worktrees/agent-$1"
    git -C "$REPO" worktree add -q -b "$2" "$wt" "$BASE_SHA" >/dev/null 2>&1
    echo "work" > "$wt/src/$3"
    git -C "$wt" add -A
    git -C "$wt" commit -q -m "agent commit $2"
    # The harness locks a native worktree while its agent runs; $$ is this test, alive.
    git -C "$REPO" worktree lock --reason "agent running (pid $$)" "$wt" 2>/dev/null
    printf '%s' "$wt"
}

transcript_spawn() { # <transcript> <name> <agent-id>
    NM="$2" AID="$3" python3 -c '
import json, os
nm, aid = os.environ["NM"], os.environ["AID"]
tu = "toolu_" + aid[:8]
print(json.dumps({"type": "assistant", "message": {"content": [
    {"type": "tool_use", "id": tu, "name": "Agent",
     "input": {"name": nm, "subagent_type": nm.split("-")[0], "isolation": "worktree"}}]}}))
print(json.dumps({"type": "user", "message": {"content": [
    {"type": "tool_result", "tool_use_id": tu}]}, "toolUseResult": {"agentId": aid}}))' >> "$1"
}

AID_A="a0a0a0a0a0a0a0a01"
AID_B="b0b0b0b0b0b0b0b02"
WT_A="$(native_agent "$AID_A" worktree-mark-leada1 b.txt)"
WT_B="$(native_agent "$AID_B" worktree-zach-leadb1 c.txt)"
WT_B2="$SANDBOX/wt/norm-sonnet-leadb2"
git -C "$REPO" worktree add -q -b norm-sonnet-leadb2 "$WT_B2" "$BASE_SHA" >/dev/null 2>&1
echo "work" > "$WT_B2/src/d.txt"
git -C "$WT_B2" add -A
git -C "$WT_B2" commit -q -m "hand-rolled agent commit"

TRANSCRIPT_A="$SANDBOX/transcript-a.jsonl"
TRANSCRIPT_B="$SANDBOX/transcript-b.jsonl"
: > "$TRANSCRIPT_A"
: > "$TRANSCRIPT_B"
transcript_spawn "$TRANSCRIPT_A" mark-opus-leada1 "$AID_A"
transcript_spawn "$TRANSCRIPT_B" zach-opus-leadb1 "$AID_B"

# Lead A lands: main moves under all three.
echo "two" >> "$REPO/src/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "lead A's land"
TIP="$(git -C "$REPO" rev-parse HEAD)"

send_as() { # <session> <transcript> <to> <body>: lead's SendMessage, through the witness
    SID="$1" TO="$3" BODY="$4" CWD="$REPO" python3 -c '
import json, os
print(json.dumps({"tool_name": "SendMessage", "hook_event_name": "PostToolUse",
                  "session_id": os.environ["SID"], "cwd": os.environ["CWD"],
                  "tool_input": {"to": os.environ["TO"], "message": os.environ["BODY"],
                                 "summary": "in-flight notice"}}))' \
        | INFLIGHT_TRANSCRIPT="$2" bash "$WITNESS"
}
push_as() { # <session> <transcript> -> GRC / GOUT
    GOUT="$(SID="$1" TP="$2" CWD="$REPO" python3 -c '
import json, os
print(json.dumps({"tool_name": "Bash", "cwd": os.environ["CWD"], "session_id": os.environ["SID"],
                  "transcript_path": os.environ["TP"],
                  "tool_input": {"command": "git push origin main"}}))' \
        | INFLIGHT_TRANSCRIPT="$2" bash "$GUARD" 2>&1)"
    GRC=$?
}
verdict_of() { # <status text> <worktree basename> -> that worktree's verdict (its line's first word)
    printf '%s\n' "$1" | python3 -c '
import sys
want = sys.argv[1]
for line in sys.stdin.read().splitlines():
    words = line.split()
    if len(words) == 2 and words[1].rstrip("/").endswith("/" + want):
        print(words[0]); break' "$2"
}

echo "=== in-flight guard, two leads: refuse or skip another lead's worktree? ==="

# ---- A notifies its own agent, by its unique name, as a lead does ------------------------
send_as "$SID_A" "$TRANSCRIPT_A" mark-opus-leada1 "Main moved to $TIP while you were working."
[ -s "$TEAM_A/inflight-notices.jsonl" ] && ok "0. the witness recorded lead A's notice in A's own ledger" \
    || bad "0. lead A's notice was witnessed" "$(ls -la "$TEAM_A")"
[ ! -s "$TEAM_B/inflight-notices.jsonl" ] && ok "0b. and nothing in lead B's ledger" \
    || bad "0b. lead B's ledger is untouched" "$(cat "$TEAM_B/inflight-notices.jsonl")"

# ---- 1. THE ANSWER: A's push -------------------------------------------------------------
push_as "$SID_A" "$TRANSCRIPT_A"
say "1 A pushes" "$GOUT"
[ "$GRC" -eq 2 ] && ok "1a. A's push is REFUSED (exit 2): another lead's agents are not skipped" \
    || bad "1a. A's push is refused" "exit $GRC: $GOUT"
case "$GOUT" in
    *"agent-$AID_B"*) ok "1b. the refusal names lead B's native worktree (agent-$AID_B)" ;;
    *) bad "1b. the refusal names B's native worktree" "$GOUT" ;;
esac
case "$GOUT" in
    *"norm-sonnet-leadb2"*) ok "1c. the refusal names lead B's hand-rolled worktree" ;;
    *) bad "1c. the refusal names B's hand-rolled worktree" "$GOUT" ;;
esac

SOUT="$(INFLIGHT_TEAMS_DIR="$TEAM_A" INFLIGHT_TRANSCRIPT="$TRANSCRIPT_A" CLAUDE_SESSION_ID="$SID_A" \
        bash "$RUNNER" status --repo "$REPO" 2>&1)"
say "1 status from A" "$SOUT"
V_A="$(verdict_of "$SOUT" "agent-$AID_A")"
V_B="$(verdict_of "$SOUT" "agent-$AID_B")"
V_B2="$(verdict_of "$SOUT" "norm-sonnet-leadb2")"
case "$V_A" in *NOTIFIED*) ok "1d. from A, A's own agent reads notified ($V_A)" ;;
    *) bad "1d. A's own agent is notified" "$V_A :: $SOUT" ;; esac
case "$V_B" in *OWED-NO-NOTICE*) ok "1e. from A, B's native agent reads OWED-NO-NOTICE ($V_B)" ;;
    *) bad "1e. B's native agent is owed" "$V_B :: $SOUT" ;; esac
case "$V_B2" in *OWED-NO-NOTICE*) ok "1f. from A, B's hand-rolled agent reads OWED-NO-NOTICE ($V_B2)" ;;
    *) bad "1f. B's hand-rolled agent is owed" "$V_B2 :: $SOUT" ;; esac

# ---- 2. What the generated notice would address B's native agent as ----------------------
NOUT="$(INFLIGHT_TEAMS_DIR="$TEAM_A" INFLIGHT_TRANSCRIPT="$TRANSCRIPT_A" CLAUDE_SESSION_ID="$SID_A" \
        bash "$RUNNER" notice --repo "$REPO" --impact none --detail "Lead A landed an unrelated change under you." 2>&1)"
say "2 notice from A" "$NOUT"
case "$NOUT" in
    *"NO EXACT NAME JOIN"*) ok "2a. A cannot name B's native agent: the generated notice says NO EXACT NAME JOIN" ;;
    *) bad "2a. the generated notice flags the missing name join for B's agent" "$NOUT" ;;
esac

# ---- 3. The ways through: a notice by the name B knows it by does not clear it -----------
send_as "$SID_A" "$TRANSCRIPT_A" zach-opus-leadb1 "Main moved to $TIP."
push_as "$SID_A" "$TRANSCRIPT_A"
say "3a after a notice to B's agent by name" "$GOUT"
case "$GOUT" in
    *"agent-$AID_B"*) ok "3a. a notice from A to B's agent BY NAME clears nothing: A's index cannot join that name" ;;
    *) bad "3a. a notice by name from A does not clear B's native agent" "exit $GRC: $GOUT" ;;
esac
send_as "$SID_A" "$TRANSCRIPT_A" "$AID_B" "Main moved to $TIP."
send_as "$SID_A" "$TRANSCRIPT_A" norm-sonnet-leadb2 "Main moved to $TIP."
push_as "$SID_A" "$TRANSCRIPT_A"
say "3b after notices by agent id and by worktree name" "$GOUT"
[ "$GRC" -eq 0 ] && ok "3b. only a notice to B's raw agent id (and the hand-rolled one's name) lets A push" \
    || bad "3b. notices by agent id clear A's push" "exit $GRC: $GOUT"

# ---- 4. And lead B's own push, from the same repository, sees A's agent the same way ------
push_as "$SID_B" "$TRANSCRIPT_B"
say "4 B pushes" "$GOUT"
case "$GOUT" in
    *"agent-$AID_A"*) ok "4. from B, A's agent is owed too: the refusal is symmetric" ;;
    *) bad "4. B's push names A's agent" "exit $GRC: $GOUT" ;;
esac

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf 'in-flight two leads: all %s checks passed.\n' "$PASS"
    exit 0
fi
printf 'in-flight two leads: %s/%s passed, %s FAILED.\n' "$PASS" "$((PASS + FAIL))" "$FAIL" >&2
exit 1
