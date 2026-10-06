#!/usr/bin/env bash
#
# inflight-two-leads.test.sh: with two leads in one repository, is a push ever refused
# because of ANOTHER LEAD's live worktree (or its own)?
#
# THE RULE (CEO 2026-10-06): a push needs no in-flight notice and no waiver, for any live
# teammate, whichever lead it belongs to. Each worker catches up with main once, itself, as
# the last step before handover. guard-inflight-notify.sh therefore never refuses.
# History: Frank's F4 (richos-hq bd685c14) asked whether the old guard refused or skipped a
# worktree absent from the landing lead's identity index; it refused. That refusal is gone.
#
# THE SHAPE, as the operator runs it: one repository, two lead sessions (A lands, B does not).
#   A's agent : a native worktree, locked with a live pid, named in A's transcript.
#   B's agent : a native worktree, locked with a live pid, named only in B's transcript.
#   B's other : a hand-rolled worktree (spawn.sh's shape), presumed live, as the engine says.
# All three are cut from the base; A's land moves main under all of them. Nobody is notified.
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

echo "=== in-flight guard, two leads: a push is never refused for a live teammate ==="

# ---- 0. The test is not vacuous: all three teammates are live and behind main -------------
SOUT="$(INFLIGHT_TEAMS_DIR="$TEAM_A" INFLIGHT_TRANSCRIPT="$TRANSCRIPT_A" CLAUDE_SESSION_ID="$SID_A" \
        bash "$RUNNER" status --repo "$REPO" 2>&1)"
say "0 status from A" "$SOUT"
case "$SOUT" in
    *"live worktrees: 3"*) ok "0. the sweep sees all three live worktrees (A's agent, B's native, B's hand-rolled)" ;;
    *) bad "0. three live worktrees are in flight" "$SOUT" ;;
esac

# ---- 1. Lead A pushes with NO notice sent to anyone --------------------------------------
push_as "$SID_A" "$TRANSCRIPT_A"
say "1 A pushes" "$GOUT"
[ "$GRC" -eq 0 ] && ok "1a. A's push is allowed (exit 0) with three live teammates and no notice" \
    || bad "1a. A's push is allowed" "exit $GRC: $GOUT"
case "$GOUT" in
    *"agent-$AID_B"*|*norm-sonnet-leadb2*|*"agent-$AID_A"*) bad "1b. the push names no teammate" "$GOUT" ;;
    *) ok "1b. the push says nothing about any teammate's worktree (none of A's, B's native or B's hand-rolled)" ;;
esac

# ---- 2. Lead B's own push, from the same repository, is allowed the same way --------------
push_as "$SID_B" "$TRANSCRIPT_B"
say "2 B pushes" "$GOUT"
[ "$GRC" -eq 0 ] && ok "2. B's push is allowed too: nothing depends on which lead a teammate belongs to" \
    || bad "2. B's push is allowed" "exit $GRC: $GOUT"

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf 'in-flight two leads: all %s checks passed.\n' "$PASS"
    exit 0
fi
printf 'in-flight two leads: %s/%s passed, %s FAILED.\n' "$PASS" "$((PASS + FAIL))" "$FAIL" >&2
exit 1
