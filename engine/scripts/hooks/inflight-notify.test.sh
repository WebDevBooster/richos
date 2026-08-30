#!/usr/bin/env bash
#
# inflight-notify.test.sh — the in-flight sweep, end to end, in a sandbox.
#
# Builds a real git repository with a real linked worktree, moves main under it,
# and drives the SHIPPED hooks with synthetic payloads. Nothing is stubbed
# except the session team directory (INFLIGHT_TEAMS_DIR), because that is the
# one thing a test must not share with the live session.
#
# THE FOUR TRANSCRIPTS THE BRIEF ASKS FOR, and where each is asserted:
#   1. a land with a live teammate behind and un-notified -> BLOCKED, named
#        cases 2a/2b
#   2. the same land after the notification is recorded    -> ALLOWED
#        cases 4a/4b
#   3. an ack absent -> detected; an ack present -> verified from durable state
#        cases 5a-5f
#   4. no live worktrees -> silent no-op, PROVEN BY A POSITIVE PROBE so the
#      guard cannot pass by never running at all
#        cases 6a/6b/6c
#
# Run directly:  scripts/hooks/inflight-notify.test.sh [--verbose]

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

SANDBOX="$(mktemp -d -t inflight-notify.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

REPO="$SANDBOX/repo"
TEAMS="$SANDBOX/teams"
TEAM_DIR="$TEAMS/session-deadbeef"
mkdir -p "$REPO" "$TEAM_DIR"

# --- the sandbox engine copy ----------------------------------------------
# The hooks resolve their libraries relative to their own location, so the
# sandbox hosts both. A copy, not a symlink: a mutation test rewrites one.
mkdir -p "$REPO/scripts/hooks" "$REPO/scripts/lib"
for h in guard-inflight-notify.sh notice-inflight-sends.sh notice-inflight-acks.sh; do
    cp "$SRC_DIR/$h" "$REPO/scripts/hooks/$h"
    chmod +x "$REPO/scripts/hooks/$h"
done
for l in inflight.sh inflight.py resolve-roots.sh resolve-main-checkout.sh seat-jurisdiction.sh stop-hook-notice.sh; do
    cp "$SRC_DIR/../lib/$l" "$REPO/scripts/lib/$l" 2>/dev/null || true
done
cp "$ENGINE_ROOT/scripts/inflight-notify.sh" "$REPO/scripts/"
cp "$ENGINE_ROOT/scripts/inflight-ack.sh" "$REPO/scripts/"
chmod +x "$REPO/scripts/inflight-notify.sh" "$REPO/scripts/inflight-ack.sh"
printf 'PROTECTED_PATHS="src"\n' > "$REPO/orchestration.config"

GUARD="$REPO/scripts/hooks/guard-inflight-notify.sh"
WITNESS="$REPO/scripts/hooks/notice-inflight-sends.sh"
STOPHOOK="$REPO/scripts/hooks/notice-inflight-acks.sh"
RUNNER="$REPO/scripts/inflight-notify.sh"
ACKER="$REPO/scripts/inflight-ack.sh"

export RICHOS_ENTITY_ROOT="$REPO"
export INFLIGHT_TEAMS_DIR="$TEAMS"

# --- a real repository, a real worktree -----------------------------------
git -C "$REPO" init -q -b main
# Inherit the operator's identity rather than inventing one: this machine runs a
# global pre-commit identity guard, and a sandbox that hard-codes an address
# fails on the guard instead of on the thing under test.
git -C "$REPO" config user.email "$(git config user.email 2>/dev/null || echo tester@example.invalid)"
git -C "$REPO" config user.name "$(git config user.name 2>/dev/null || echo tester)"
mkdir -p "$REPO/src"
echo "one" > "$REPO/src/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "base"
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

WT="$SANDBOX/wt/norm-sonnet-feature1"
mkdir -p "$SANDBOX/wt"
git -C "$REPO" worktree add -q -b worktree-norm "$WT" >/dev/null 2>&1
echo "teammate work" > "$WT/src/b.txt"
git -C "$WT" add -A
git -C "$WT" commit -q -m "teammate commit"

# main moves under the teammate — the whole failure, reproduced.
echo "two" >> "$REPO/src/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "a land that moves main"
TIP="$(git -C "$REPO" rev-parse HEAD)"

# --- payload builders ------------------------------------------------------
push_payload() { # [cwd]
    CWD="${1:-$REPO}" python3 -c '
import json, os
print(json.dumps({"tool_name": "Bash", "cwd": os.environ["CWD"],
                  "session_id": "deadbeef-1111-4000-8000-000000000000",
                  "tool_input": {"command": "git push origin main"}}))'
}
send_payload() { # <to> <body> [agent_id]
    TO="$1" BODY="$2" AID="${3:-}" python3 -c '
import json, os
d = {"tool_name": "SendMessage", "hook_event_name": "PostToolUse",
     "session_id": "deadbeef-1111-4000-8000-000000000000",
     "cwd": os.environ.get("CWD", ""),
     "tool_input": {"to": os.environ["TO"], "message": os.environ["BODY"],
                    "summary": "in-flight notice"}}
if os.environ.get("AID"):
    d["agent_id"] = os.environ["AID"]
print(json.dumps(d))'
}
stop_payload() {
    python3 -c '
import json
print(json.dumps({"hook_event_name": "Stop", "session_id": "deadbeef-1111-4000-8000-000000000000",
                  "cwd": "", "stop_hook_active": False, "last_assistant_message": "Done.",
                  "background_tasks": [], "session_crons": []}))'
}

run_guard() { # -> sets GRC / GOUT
    GOUT="$(push_payload "${1:-$REPO}" | bash "$GUARD" 2>&1)"
    GRC=$?
}

echo "=== in-flight sweep: guard, witness, ack, and the silent case ==="

# ==========================================================================
# 1. the sweep sees the world
# ==========================================================================
SOUT="$(bash "$RUNNER" status --repo "$REPO" 2>&1)"
say "1a status" "$SOUT"
case "$SOUT" in
    *"OWED-NO-NOTICE"*) ok "1a. the runner names the live teammate that main moved under" ;;
    *) bad "1a. the runner names the live teammate" "$SOUT" ;;
esac
case "$SOUT" in
    *"OVERLAPS"*) bad "1b. no false overlap is reported (the teammate touched a different file)" "$SOUT" ;;
    *) ok "1b. no false overlap — the teammate changed src/b.txt, the land changed src/a.txt" ;;
esac

# ==========================================================================
# 2. TRANSCRIPT ONE — a land with a live teammate behind and un-notified
# ==========================================================================
run_guard
say "2 guard BLOCKED" "$GOUT"
[ "$GRC" -eq 2 ] && ok "2a. the push is BLOCKED (exit 2)" \
                 || bad "2a. the push is BLOCKED" "exit $GRC: $GOUT"
case "$GOUT" in
    *"norm-sonnet-feature1"*) ok "2b. the refusal NAMES the teammate it is refusing on behalf of" ;;
    *) bad "2b. the refusal names the teammate" "$GOUT" ;;
esac
case "$GOUT" in
    *"$TIP"*) ok "2c. the refusal names the SHA that has to appear in the message" ;;
    *) bad "2c. the refusal names the tip" "$GOUT" ;;
esac

# ==========================================================================
# 3. what does NOT satisfy it
# ==========================================================================
printf '%s' "$(CWD="$REPO" send_payload "norm-sonnet-feature1" "main moved, please rebase")" | bash "$WITNESS"
run_guard
[ "$GRC" -eq 2 ] && ok "3a. a message with NO SHA in it does not clear the debt" \
                 || bad "3a. a message with no SHA does not clear the debt" "exit $GRC"

printf '%s' "$(CWD="$REPO" send_payload "someone-else-entirely" "main moved to $TIP")" | bash "$WITNESS"
run_guard
[ "$GRC" -eq 2 ] && ok "3b. a message to a DIFFERENT teammate does not clear the debt" \
                 || bad "3b. a message to someone else does not clear the debt" "exit $GRC"

printf '%s' "$(CWD="$REPO" send_payload "norm-sonnet-feature1" "main moved to $BASE_SHA")" | bash "$WITNESS"
run_guard
[ "$GRC" -eq 2 ] && ok "3c. a message naming the OLD sha does not clear the debt" \
                 || bad "3c. a message naming the old sha does not clear the debt" "exit $GRC"

printf '%s' "$(CWD="$REPO" send_payload "norm-sonnet-feature1" "main moved to $TIP" "aworker-1234")" | bash "$WITNESS"
run_guard
[ "$GRC" -eq 2 ] && ok "3d. a WORKER's message is not the lead's notice (attribution gate holds)" \
                 || bad "3d. a worker's message is not the lead's notice" "exit $GRC"

# ==========================================================================
# 4. TRANSCRIPT TWO — the same land, after the notification is recorded
# ==========================================================================
NOTICE_BODY="Main moved to $TIP while you were working. It changed src/a.txt.
Acknowledge with: scripts/inflight-ack.sh --sha $TIP --impact <kind> --detail \"...\" --paths \"...\""
printf '%s' "$(CWD="$REPO" send_payload "norm-sonnet-feature1" "$NOTICE_BODY")" | bash "$WITNESS"
run_guard
say "4 guard ALLOWED" "$GOUT"
[ "$GRC" -eq 0 ] && ok "4a. once the notice naming this tip is witnessed, the push is ALLOWED" \
                 || bad "4a. the push is allowed after the notice" "exit $GRC: $GOUT"
[ -z "$GOUT" ] && ok "4b. and it is allowed SILENTLY — a guard that talks on success gets muted" \
               || bad "4b. allowed silently" "$GOUT"

# THE WITNESS IS NOT A SELF-REPORT: it is the hook, on the send, not a file the
# lander chose to write. Prove the ledger came from the hook and carries the sha.
LEDGER="$TEAM_DIR/inflight-notices.jsonl"
if [ -s "$LEDGER" ] && grep -q '"source_hook": "PostToolUse\[SendMessage\]"' "$LEDGER" \
   && grep -q "$TIP" "$LEDGER"; then
    ok "4c. the record was written by the SEND itself, and carries the tip"
else
    bad "4c. the record was written by the send itself" "$(cat "$LEDGER" 2>/dev/null | tail -2)"
fi
if grep -q "Acknowledge with" "$LEDGER"; then
    bad "4d. the message BODY is never logged" "the body leaked into the ledger"
else
    ok "4d. the message BODY is never logged — only the recipient, the shas, a digest and a length"
fi

# ==========================================================================
# 5. TRANSCRIPT THREE — the ack: absent, malformed, then verified
# ==========================================================================
AOUT="$(bash "$RUNNER" status --repo "$REPO" 2>&1)"
say "5a ack absent" "$AOUT"
case "$AOUT" in
    *"NOTIFIED-NO-ACK"*) ok "5a. an ABSENT ack is detected and reported, not assumed" ;;
    *) bad "5a. an absent ack is detected" "$AOUT" ;;
esac

# The teammate writes a bad one: the shape check is real.
bash "$ACKER" --sha "$BASE_SHA" --impact conflict --detail "x" --paths none --worktree "$WT" >/dev/null 2>&1
[ $? -ne 0 ] && ok "5b. the ack writer REFUSES a too-short detail rather than writing a hollow ack" \
             || bad "5b. the ack writer refuses a too-short detail"
bash "$ACKER" --sha "abc123" --impact conflict --detail "$(printf 'x%.0s' $(seq 1 50))" --paths none --worktree "$WT" >/dev/null 2>&1
[ $? -ne 0 ] && ok "5c. the ack writer REFUSES a short sha — it has to be checkable against the tip" \
             || bad "5c. the ack writer refuses a short sha"

# A well-formed ack for the WRONG commit must not count.
bash "$ACKER" --sha "$BASE_SHA" --impact none \
    --detail "I read the notice and nothing in it affects the file I am editing." \
    --paths none --worktree "$WT" >/dev/null 2>&1
AOUT="$(bash "$RUNNER" status --repo "$REPO" 2>&1)"
case "$AOUT" in
    *"NOTIFIED-NO-ACK"*) ok "5d. an ack naming a DIFFERENT commit is not an ack for this one" ;;
    *) bad "5d. an ack for a different commit does not count" "$AOUT" ;;
esac

# A path that exists nowhere is caught.
bash "$ACKER" --sha "$TIP" --impact stale-record \
    --detail "My copy of the plan predates this land, so the count I was given is wrong." \
    --paths "src/does-not-exist.txt" --worktree "$WT" >/dev/null 2>&1
AOUT="$(bash "$RUNNER" acks --repo "$REPO" 2>&1)"
say "5e invalid ack" "$AOUT"
case "$AOUT" in
    *"verified : NO"*) ok "5e. an ack citing a path in neither the changeset nor the worktree is INVALID" ;;
    *) bad "5e. an ack citing an impossible path is invalid" "$AOUT" ;;
esac

# The real thing.
bash "$ACKER" --sha "$TIP" --impact stale-record \
    --detail "My copy of src/a.txt is one revision behind; I will re-read it before I touch it." \
    --paths "src/a.txt src/b.txt" --worktree "$WT" >/dev/null 2>&1
AOUT="$(bash "$RUNNER" acks --repo "$REPO" 2>&1)"
say "5f verified ack" "$AOUT"
case "$AOUT" in
    *"verified : YES"*) ok "5f. a well-formed ack VERIFIES — from a file on disk, with no message received" ;;
    *) bad "5f. a well-formed ack verifies" "$AOUT" ;;
esac
case "$AOUT" in
    *"HUMAN JUDGMENT REQUIRED"*) ok "5g. and the verifier SAYS which part of it no machine here checked" ;;
    *) bad "5g. the verifier names the unmachine-checkable part" "$AOUT" ;;
esac
SOUT="$(bash "$RUNNER" status --repo "$REPO" 2>&1)"
case "$SOUT" in
    *"NOTIFIED-ACKED"*) ok "5h. the sweep reports the teammate as told AND proved" ;;
    *) bad "5h. the sweep reports told and proved" "$SOUT" ;;
esac

# The filename carries the sha, so a wrong-commit ack lands under a different
# name and is simply absent (5d). This is the other half: the RIGHT filename
# with a STALE sha INSIDE, which is what copying an old ack forward produces.
python3 - "$WT/.claude/inflight-acks/$(printf '%s' "$TIP" | cut -c1-12).ack" "$BASE_SHA" <<'STALEPY'
import re, sys
p, stale = sys.argv[1], sys.argv[2]
src = open(p).read()
open(p, "w").write(re.sub(r"^sha: .*$", "sha: " + stale, src, count=1, flags=re.M))
STALEPY
AOUT="$(bash "$RUNNER" acks --repo "$REPO" 2>&1)"
say "5m stale sha inside a correctly named ack" "$AOUT"
case "$AOUT" in
    *"verified : NO"*) ok "5m. the right FILENAME with a stale sha INSIDE is still invalid" ;;
    *) bad "5m. a stale sha inside a correctly named ack is invalid" "$AOUT" ;;
esac
bash "$ACKER" --sha "$TIP" --impact stale-record \
    --detail "My copy of src/a.txt is one revision behind; I will re-read it before I touch it." \
    --paths "src/a.txt src/b.txt" --worktree "$WT" >/dev/null 2>&1

# ==========================================================================
# 5i. the waiver — the only escape hatch, and it is loud
# ==========================================================================
rm -f "$TEAM_DIR/inflight-notices.jsonl"
run_guard
[ "$GRC" -eq 2 ] && ok "5i. with the notices gone the debt is back (the ledger is what is trusted)" \
                 || bad "5i. removing the ledger restores the debt" "exit $GRC"
WOUT="$(bash "$RUNNER" waive "$WT" --reason "abandoned experiment, agent confirmed dead" --repo "$REPO" 2>&1)"
say "5i waiver" "$WOUT"
run_guard
[ "$GRC" -eq 0 ] && ok "5j. a recorded waiver clears the debt" \
                 || bad "5j. a recorded waiver clears the debt" "exit $GRC: $GOUT"
if grep -q "abandoned experiment" "$TEAM_DIR/inflight-waivers.jsonl" 2>/dev/null; then
    ok "5k. and the waiver is on the record with its reason and its actor"
else
    bad "5k. the waiver is recorded with its reason"
fi
WOUT="$(bash "$RUNNER" waive "$WT" --repo "$REPO" 2>&1)"
case "$WOUT" in
    *"--reason is required"*) ok "5l. a waiver with no reason is refused — that is a silent skip in a costume" ;;
    *) bad "5l. a reasonless waiver is refused" "$WOUT" ;;
esac

# ==========================================================================
# 6. TRANSCRIPT FOUR — no live worktrees: a SILENT no-op, positively probed
# ==========================================================================
BARE="$SANDBOX/bare"
mkdir -p "$BARE/scripts/hooks" "$BARE/scripts/lib"
cp "$GUARD" "$BARE/scripts/hooks/"
cp "$REPO/scripts/lib/"* "$BARE/scripts/lib/" 2>/dev/null || true
printf 'PROTECTED_PATHS="src"\n' > "$BARE/orchestration.config"
git -C "$BARE" init -q -b main
git -C "$BARE" config user.email "$(git config user.email 2>/dev/null || echo tester@example.invalid)"
git -C "$BARE" config user.name "$(git config user.name 2>/dev/null || echo tester)"
echo x > "$BARE/f.txt"; git -C "$BARE" add -A; git -C "$BARE" commit -q -m one

BARE_TEAMS="$SANDBOX/teams-bare/session-deadbeef"
mkdir -p "$BARE_TEAMS"
GOUT="$(RICHOS_ENTITY_ROOT="$BARE" INFLIGHT_TEAMS_DIR="$SANDBOX/teams-bare" \
        push_payload "$BARE" | RICHOS_ENTITY_ROOT="$BARE" INFLIGHT_TEAMS_DIR="$SANDBOX/teams-bare" \
        bash "$BARE/scripts/hooks/guard-inflight-notify.sh" 2>&1)"
GRC=$?
say "6 no worktrees" "rc=$GRC out=[$GOUT]"
[ "$GRC" -eq 0 ] && ok "6a. with no teammate worktrees the guard allows the push" \
                 || bad "6a. no worktrees -> allowed" "exit $GRC: $GOUT"
[ -z "$GOUT" ] && ok "6b. and says NOTHING — silence is the whole requirement here" \
               || bad "6b. no worktrees -> silent" "$GOUT"
# THE POSITIVE PROBE. 6a and 6b would both pass if the guard never ran at all,
# which is precisely how a guard passes for the wrong reason. It leaves a
# footprint when it runs: the repository it swept is registered for the Stop
# hook to watch. No footprint, no run.
if grep -qxF "$(cd "$BARE" && pwd -P)" "$SANDBOX/teams-bare/session-deadbeef/inflight-repos.txt" 2>/dev/null; then
    ok "6c. POSITIVE PROBE: the guard demonstrably RAN — it registered the repo it swept"
else
    bad "6c. POSITIVE PROBE: the guard actually ran" \
        "no inflight-repos.txt entry — 6a/6b may be passing because nothing executed"
fi

# ==========================================================================
# 7. scope — the guard is silent everywhere it has no business
# ==========================================================================
scope_case() { # <name> <command> <cwd>
    local name="$1" cmd="$2" cwd="$3" out rc
    out="$(CMD="$cmd" CWD="$cwd" python3 -c '
import json, os
print(json.dumps({"tool_name": "Bash", "cwd": os.environ["CWD"],
                  "session_id": "deadbeef-1111-4000-8000-000000000000",
                  "tool_input": {"command": os.environ["CMD"]}}))' | bash "$GUARD" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "$name"; else bad "$name" "exit $rc: $out"; fi
}
rm -f "$TEAM_DIR/inflight-waivers.jsonl"
scope_case "7a. an ordinary command is not a push"            "ls -la"                      "$REPO"
scope_case "7b. talking about a push is not a push"           "echo 'git push origin main'" "$REPO"
scope_case "7c. --dry-run is not a land"                      "git push --dry-run origin main" "$REPO"
scope_case "7d. pushing a teammate branch is not a land"      "git push origin worktree-norm"  "$REPO"
scope_case "7e. a push from inside a WORKTREE is not a land"  "git push origin main"           "$WT"
scope_case "7f. a merge is not the chokepoint (stated gap)"   "git merge worktree-norm"        "$REPO"
# A linked worktree can sit on a branch that IS in the main/master set, and a
# bare `git push` names no refspec — so neither the branch test nor the refspec
# test stops it there. Only "am I the main checkout?" does.
WT_MASTER="$SANDBOX/wt/other-sonnet-master1"
git -C "$REPO" worktree add -q -b master "$WT_MASTER" >/dev/null 2>&1
scope_case "7g. a bare push from a worktree on 'master' is not a land" "git push" "$WT_MASTER"
git -C "$REPO" worktree remove --force "$WT_MASTER" >/dev/null 2>&1

# ==========================================================================
# 8. the Stop-hook notice — surfaced, never enforced
# ==========================================================================
NOTICE_BODY="Main moved to $TIP. Ack with scripts/inflight-ack.sh."
printf '%s' "$(CWD="$REPO" send_payload "norm-sonnet-feature1" "$NOTICE_BODY")" | bash "$WITNESS"
rm -rf "$WT/.claude/inflight-acks"
# Backdate the notice past the timeout.
python3 - "$TEAM_DIR/inflight-notices.jsonl" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
p = sys.argv[1]
rows = [json.loads(l) for l in open(p) if l.strip()]
old = (datetime.now(timezone.utc) - timedelta(hours=3)).isoformat()
for r in rows:
    r["timestamp"] = old
open(p, "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
printf '%s\n' "$(cd "$REPO" && pwd -P)" > "$TEAM_DIR/inflight-repos.txt"
rm -rf "$REPO/.claude/state/stop-hook-notices"
NOUT="$(stop_payload | bash "$STOPHOOK" 2>/dev/null)"
NRC=$?
say "8 stop notice" "rc=$NRC out=$NOUT"
[ "$NRC" -eq 0 ] && ok "8a. the Stop hook never blocks — it exits 0 on every path" \
                 || bad "8a. the Stop hook exits 0" "exit $NRC"
if printf '%s' "$NOUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "no ack past the timeout" in d.get("systemMessage","") else 1)' 2>/dev/null; then
    ok "8b. an overdue ack is SURFACED to the operator on the channel that reaches him"
else
    bad "8b. an overdue ack is surfaced" "$NOUT"
fi
if printf '%s' "$NOUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "TaskStop" in d.get("systemMessage","") else 1)' 2>/dev/null; then
    ok "8c. and it names the ACTION and the ACTOR, not just the condition"
else
    bad "8c. the notice names the action" "$NOUT"
fi
NOUT2="$(stop_payload | bash "$STOPHOOK" 2>/dev/null)"
[ -z "$NOUT2" ] && ok "8d. the same unchanged condition says nothing again — a notice every turn gets muted" \
               || bad "8d. an unchanged condition is not re-announced" "$NOUT2"

# ==========================================================================
# 9. an AMBIGUOUS recipient credits nothing — a notice attached to the wrong
#    worktree is a guard reporting a teammate was told when it was not
# ==========================================================================
rm -f "$TEAM_DIR/inflight-notices.jsonl" "$TEAM_DIR/inflight-waivers.jsonl"
WT2="$SANDBOX/wt/norm-sonnet-feature2"
git -C "$REPO" worktree add -q -b worktree-norm2 "$WT2" >/dev/null 2>&1
echo "second teammate" > "$WT2/src/c.txt"
git -C "$WT2" add -A
git -C "$WT2" commit -q -m "second teammate commit"
# "norm-sonnet-feature" shares {norm, feature} with BOTH worktree basenames, so
# it names neither of them.
printf '%s' "$(CWD="$REPO" send_payload "norm-sonnet-feature" "main moved to $TIP")" | bash "$WITNESS"
run_guard
say "9 ambiguous recipient" "$GOUT"
[ "$GRC" -eq 2 ] && ok "9a. a recipient that matches TWO live worktrees credits NEITHER" \
                 || bad "9a. an ambiguous recipient credits nothing" "exit $GRC: $GOUT"
printf '%s' "$(CWD="$REPO" send_payload "norm-sonnet-feature1" "main moved to $TIP")" | bash "$WITNESS"
printf '%s' "$(CWD="$REPO" send_payload "norm-sonnet-feature2" "main moved to $TIP")" | bash "$WITNESS"
run_guard
[ "$GRC" -eq 0 ] && ok "9b. telling BOTH of them, by name, clears it" \
                 || bad "9b. naming both clears it" "exit $GRC: $GOUT"
git -C "$REPO" worktree remove --force "$WT2" >/dev/null 2>&1

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✓ in-flight sweep: all %s checks passed.\033[0m\n' "$PASS"
    exit 0
fi
printf '\033[31m✗ in-flight sweep: %s/%s passed, %s FAILED.\033[0m\n' "$PASS" "$((PASS + FAIL))" "$FAIL" >&2
exit 1
