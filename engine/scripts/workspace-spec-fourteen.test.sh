#!/usr/bin/env bash
#
# workspace-spec-fourteen.test.sh — THE FOURTEEN CHECKS OF THE ROUND-6 BRIEF,
# FROZEN, ONE PER SENTENCE OF THE CEO'S PAGE, MEASURED THROUGH THE REAL HOOKS.
#
# The page:  docs/plans/worktree-spec-2026-09-11.md (richos-hq; mirrored here).
# The list:  richos-hq docs/plans/round6-brief-fourteen-points-2026-09-12.md §4,
#            frozen before the engineer started. A check may be ADDED here. None
#            of the fourteen is removed or reworded; where one is believed wrong
#            it is implemented as written and the report says why.
#
# Every step goes through the hook scripts exactly as hooks/hooks.json registers
# them — the spawn guard, the Bash worktree guard, the lifecycle hook, the
# lock-out, the catch-all PostToolUse, the Stop gate — with the payload shapes
# the platform sends, in temporary repositories, with HOME and CLAUDE_CONFIG_DIR
# redirected. The operator's real files are never read or written. The only
# simulated party is the platform itself.
#
# OUTPUT. One line per sub-assertion — `      ok   C4.2 ...` or
# `      FAIL  C4.2 ...` — one verdict line per check — `  PASS  C4  ...` /
# `  FAIL  C4  ...`, TWO spaces after the id so a harness grepping `FAIL  C1 `
# cannot match C10..C14 and `FAIL  C4 ` cannot match `FAIL  C4.2` — and the
# last line is the round's own headline:
#
#     CHECKS RUN: <N>  RED: <K>
#
# A check is RED when any of its sub-assertions is red. Exit 0 only when K = 0.
#
# THE MUTATION HARNESS NAMES SUB-ASSERTIONS, NEVER CHECKS. One check (C14) is
# red on the base this was written against, so a mutant wanting `FAIL  C14 `
# would be "proven" by a suite that was red before the mutant touched anything
# — absence reading as success, which is failure type A of the 2026-09-10
# record. workspace-spec-fourteen.mutation.sh therefore wants `FAIL  C14.3 `,
# a line that is green until the mutation makes it red.
#
# Usage: workspace-spec-fourteen.test.sh [--keep]   (--keep leaves the sandbox)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
HOOKS="$ENGINE/scripts/hooks"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

# --- the tally --------------------------------------------------------------
CHECKS_RUN=0; CHECKS_RED=0
CUR=""; CUR_RED=0; CUR_TITLE=""
begin() { # <id> <title>
    CUR="$1"; CUR_TITLE="$2"; CUR_RED=0
    echo "=== $1  $2 ==="
}
sub() { # <label> <cond> [detail]   — one sub-assertion of the current check
    if eval "$2"; then
        printf '      ok   %s\n' "$1"
    else
        printf '      FAIL  %s\n' "$1"
        [ -n "${3:-}" ] && printf '           %s\n' "$(printf '%s' "$3" | head -c 600 | tr '\n' ' ')"
        CUR_RED=$((CUR_RED + 1))
    fi
}
verdict() {
    CHECKS_RUN=$((CHECKS_RUN + 1))
    if [ "$CUR_RED" -eq 0 ]; then
        printf '  PASS  %s  %s\n' "$CUR" "$CUR_TITLE"
    else
        printf '  FAIL  %s  %s  (%d sub-assertion(s) red)\n' "$CUR" "$CUR_TITLE" "$CUR_RED"
        CHECKS_RED=$((CHECKS_RED + 1))
    fi
    echo ""
}

# --- the sandbox ------------------------------------------------------------
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ws-fourteen.XXXXXX")" && pwd -P)"
SESS_PIDS=()
cleanup() {
    for p in "${SESS_PIDS[@]+"${SESS_PIDS[@]}"}"; do kill "$p" 2>/dev/null || true; done
    [ -n "${HOLD_PID:-}" ] && kill -9 "$HOLD_PID" 2>/dev/null
    if [ "$KEEP" -eq 1 ]; then echo "sandbox kept: $T"; else
        chflags -R nouchg "$T" 2>/dev/null || true
        chmod -R u+w "$T" 2>/dev/null || true
        rm -rf "$T"
    fi
}
trap cleanup EXIT

export HOME="$T/home" CLAUDE_CONFIG_DIR="$T/home/.claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
export GIT_CONFIG_GLOBAL="$T/home/.gitconfig"
printf '[user]\n\tname = fourteen\n\temail = fourteen@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
unset RICHOS_WORKSPACES_DIR RICHOS_SESSION_ID CLAUDE_PROJECT_DIR RICHOS_ENGINE_ROOT CLAUDE_PLUGIN_ROOT RICHOS_SESSION_PID 2>/dev/null || true
export SEAL_WAIT_SECONDS=0 RICHOS_WORKSPACES_SPAWN_WINDOW=0 RICHOS_WORKSPACES_STOP_GRACE=1 RICHOS_WORKSPACES_RETRY_BASE=0
STORE="$CLAUDE_CONFIG_DIR/state/workspaces"

new_repo() { # <path> [adopt]
    mkdir -p "$1" && git init -q -b main "$1"
    printf 'x\n' > "$1/README"
    [ "${2:-}" = adopt ] && cp "$ENGINE/orchestration.config" "$1/orchestration.config"
    printf '.claude/\n.env\n' > "$1/.gitignore"
    git -C "$1" add -A && git -C "$1" commit -q -m init
}
ENT="$T/entity";   new_repo "$ENT" adopt     # the session's repository
OTHER="$T/other";  new_repo "$OTHER"         # a repository a cross-repo agent edits (integrates on main)
DEV="$T/devrepo";  new_repo "$DEV"           # a repository whose work integrates on a dev branch
export RICHOS_ENTITY_ROOT="$ENT"

start_session() { # <session-id> [cwd]
    local pid
    pid="$(sh -c 'sleep 3600 >/dev/null 2>&1 & echo $!')"
    SESS_PIDS+=("$pid")
    export RICHOS_SESSION_PID="$pid"
    CUR_SID="$1"
    payload SessionStart "{\"session_id\":\"$1\",\"cwd\":\"${2:-$ENT}\"}" | bash "$HOOKS/workspace-lifecycle.sh" > "$T/last-start.json" 2>"$T/last-start.err"
}
payload() { # <event> <json-object>
    python3 -c 'import json,sys; d=json.loads(sys.argv[2]); d["hook_event_name"]=sys.argv[1]; print(json.dumps(d))' "$1" "$2"
}
spawn_payload() { # <name> <prompt>
    python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","session_id":sys.argv[1],"tool_use_id":"tu-"+sys.argv[2],"tool_name":"Agent","cwd":sys.argv[4],"tool_input":{"name":sys.argv[2],"subagent_type":"zach","isolation":"worktree","prompt":sys.argv[3]}}))' "$CUR_SID" "$1" "$2" "$ENT"
}
spawn() { # <name> <prompt> -> rc of the spawn guard; stderr in $T/spawn.err
    spawn_payload "$1" "$2" | bash "$HOOKS/guard-worktree-isolation.sh" >/dev/null 2>"$T/spawn.err"
}
platform_spawn() { # <name> <agent-id>  — the platform: native workspace, SubagentStart, Agent result
    local name="$1" aid="$2" np="$ENT/.claude/worktrees/agent-$2"
    git -C "$ENT" worktree add -q "$np" -b "worktree-agent-$aid"
    payload SubagentStart "{\"session_id\":\"$CUR_SID\",\"agent_id\":\"$aid\",\"agent_type\":\"zach\",\"cwd\":\"$np\"}" \
        | bash "$HOOKS/workspace-lifecycle.sh" >/dev/null 2>>"$T/hooks.err"
    python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","session_id":sys.argv[1],"tool_use_id":"tu-"+sys.argv[2],"tool_name":"Agent","cwd":sys.argv[4],"tool_input":{"name":sys.argv[2],"isolation":"worktree"},"tool_response":{"agentId":sys.argv[3],"status":"async_launched"}}))' "$CUR_SID" "$name" "$aid" "$ENT" \
        | bash "$HOOKS/workspace-lifecycle.sh" >/dev/null 2>>"$T/hooks.err"
}
subagent_stop() { # <agent-id>
    payload SubagentStop "{\"session_id\":\"$CUR_SID\",\"agent_id\":\"$1\",\"cwd\":\"$ENT\"}" \
        | bash "$HOOKS/workspace-lifecycle.sh" >/dev/null 2>>"$T/hooks.err"
}
send_message() { # <to> <text>  — PostToolUse[SendMessage] through the lifecycle hook
    python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","session_id":sys.argv[1],"tool_name":"SendMessage","cwd":sys.argv[4],"tool_input":{"to":sys.argv[2],"message":sys.argv[3]},"tool_response":{}}))' "$CUR_SID" "$1" "$2" "$ENT" \
        | bash "$HOOKS/workspace-lifecycle.sh" >/dev/null 2>>"$T/hooks.err"
}
barrier() { # <agent-id> <tool> -> rc of the lock-out (empty agent id = the lead)
    python3 -c 'import json,sys; d={"hook_event_name":"PreToolUse","session_id":sys.argv[1],"agent_type":"zach","tool_name":sys.argv[3],"cwd":sys.argv[4],"tool_input":{}}
if sys.argv[2]: d["agent_id"]=sys.argv[2]
print(json.dumps(d))' "$CUR_SID" "$1" "$2" "$ENT" \
        | bash "$HOOKS/guard-sealed-worktree.sh" >/dev/null 2>"$T/barrier.err"
}
bash_guard() { # <command> -> rc of the Bash worktree guard; stderr in $T/bash.err
    python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","session_id":sys.argv[1],"tool_name":"Bash","cwd":sys.argv[3],"tool_input":{"command":sys.argv[2]}}))' "$CUR_SID" "$1" "$ENT" \
        | bash "$HOOKS/guard-worktree-removal.sh" >/dev/null 2>"$T/bash.err"
}
stop_gate() { # [last_assistant_message] [transcript_path] -> rc; message in $T/stop.err, stdout in $T/stop.out
    python3 -c 'import json,sys; d={"hook_event_name":"Stop","session_id":sys.argv[1],"cwd":sys.argv[2],"stop_hook_active":False,"last_assistant_message":sys.argv[3] or "done"}
if sys.argv[4]: d["transcript_path"]=sys.argv[4]
print(json.dumps(d))' "$CUR_SID" "$ENT" "${1:-}" "${2:-}" \
        | bash "$HOOKS/guard-workspace-gate.sh" >"$T/stop.out" 2>"$T/stop.err"
}
commit_in() { # <path> <file>
    printf 'work %s\n' "$2" > "$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -q -m "work $2"
}
has_branch() { git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null; }
listed() { local l; l="$(git -C "$1" worktree list --porcelain)"; printf "%s\n" "$l" | grep -xF "worktree $2" >/dev/null; }
agent_rec() { ls "$STORE/agents" 2>/dev/null | grep -- "--$1.json" | head -1 | sed "s|^|$STORE/agents/|"; }
done_rec()  { ls "$STORE/done" 2>/dev/null | grep -- "--$1.json" | head -1 | sed "s|^|$STORE/done/|"; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); cur=d
for k in sys.argv[2].split("."):
    cur = cur.get(k) if isinstance(cur, dict) else None
print("" if cur is None else (json.dumps(cur) if isinstance(cur,(dict,list)) else cur))' "$1" "$2" 2>/dev/null; }
quarantine_dirs() { find "$T" -maxdepth 4 \( -iname '*retired*' -o -iname '*quarantin*' \) 2>/dev/null; }
WS="$ENGINE/scripts/workspaces.sh"
CREATE="$ENGINE/scripts/create-teammate-worktree.sh"
ws() { RICHOS_SESSION_ID="$CUR_SID" "$WS" "$@"; }

start_session "sess-fourteen-1111"

# ===========================================================================
begin C14 "The integration branch is recorded before the first spawn, or the spawn is refused naming what to record; every consumer asks the recorded branch and none asks main"
# The page: "The branch a body of work integrates on is RECORDED when that work
# starts, before its first agent is spawned. Nothing infers it and nothing
# guesses it." Nothing is recorded yet. The check's first clause is a guarantee
# only if the SYSTEM refuses the spawn; a habit of recording is not a guarantee.
spawn "zach-opus-n0" "work with no integration branch recorded"; rc=$?
sub "C14.1 with NO branch recorded, the first spawn is refused, naming the recording command" \
    "[ $rc -ne 0 ] && grep -q 'workspaces.sh integration' '$T/spawn.err'" "spawn rc=$rc stderr=$(cat "$T/spawn.err")"
ws integration --repo "$ENT" --branch main --why "the fourteen checks, entity" >"$T/integration.out" 2>&1; rc1=$?
ws integration --repo "$OTHER" --branch main --why "the fourteen checks, other" >>"$T/integration.out" 2>&1; rc2=$?
git -C "$DEV" branch dev/work
ws integration --repo "$DEV" --branch dev/work --why "the fourteen checks, a body of work on a dev branch" >>"$T/integration.out" 2>&1; rc3=$?
sub "C14.2 Rich records the branch, once per repository, and the record names it" \
    "[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ $rc3 -eq 0 ] && grep -q 'dev/work' '$T/integration.out'" "$(cat "$T/integration.out")"
# Work merged onto its RECORDED dev branch, never onto main, counts as landed.
git -C "$DEV" worktree add -q "$T/devrepo-wt/zach-opus-d1" -b cc/zach-opus-d1 2>/dev/null || true
git -C "$DEV" worktree remove --force "$T/devrepo-wt/zach-opus-d1" 2>/dev/null; git -C "$DEV" branch -D cc/zach-opus-d1 >/dev/null 2>&1 || true
RICHOS_SESSION_ID="$CUR_SID" bash "$CREATE" "$DEV" zach-opus-d1 >"$T/create.out" 2>&1; rc=$?
CCD="$T/devrepo-wt/zach-opus-d1"
spawn "zach-opus-d1" "$(printf 'edit the dev repository\ncross-repo-worktree: %s\n' "$CCD")"; rc=$?
platform_spawn "zach-opus-d1" "ad1d1d1d1d1d1d1d1"
commit_in "$CCD" dev.txt
DEV_TIP="$(git -C "$CCD" rev-parse HEAD)"
subagent_stop "ad1d1d1d1d1d1d1d1"
git -C "$DEV" branch -f dev/work "$DEV_TIP"          # merged onto the dev branch (a fast-forward), main untouched
stop_gate; rc=$?
sub "C14.3 work merged onto its recorded dev branch (not main) is landed on its own: workspace and branch gone" \
    "[ $rc -eq 0 ] && [ ! -e '$CCD' ] && ! has_branch '$DEV' cc/zach-opus-d1 && ! git -C '$DEV' merge-base --is-ancestor $DEV_TIP main" "$(cat "$T/stop.err")"
# Consumers: unlanded-branches.py and guard-unresolved-claims.py ask the record.
: > "$T/ledger.jsonl"
git -C "$DEV" branch side/ahead "$DEV_TIP"; commit_in "$DEV" ahead-marker.txt 2>/dev/null || true
git -C "$DEV" checkout -q -b tmp-ahead "$DEV_TIP" 2>/dev/null; printf 'ahead\n' > "$DEV/ahead.txt"; git -C "$DEV" add ahead.txt; git -C "$DEV" commit -q -m "ahead of dev/work"; git -C "$DEV" checkout -q main; git -C "$DEV" branch -f side/ahead tmp-ahead; git -C "$DEV" branch -D tmp-ahead >/dev/null
RICHOS_SESSION_ID="$CUR_SID" bash "$ENGINE/scripts/unlanded-branches-lint.sh" "$DEV" --json --ledger "$T/ledger.jsonl" >"$T/unlanded.json" 2>"$T/unlanded.err"; rc_u=$?
sub "C14.4 unlanded-branches.py compares against the RECORDED branch dev/work (a branch merged onto dev/work but not main is not ahead; one ahead of dev/work is)" \
    "[ $rc_u -eq 1 ] && grep -q '\"trunk\": *\"dev/work\"' '$T/unlanded.json' && grep -q 'side/ahead' '$T/unlanded.json'" "rc=$rc_u $(head -c 400 "$T/unlanded.json") $(cat "$T/unlanded.err")"
git -C "$DEV" branch -D side/ahead >/dev/null
NOREC="$T/norecord"; new_repo "$NOREC"; git -C "$NOREC" branch stray; git -C "$NOREC" checkout -q stray; printf 's\n' > "$NOREC/s.txt"; git -C "$NOREC" add s.txt; git -C "$NOREC" commit -q -m s; git -C "$NOREC" checkout -q main
RICHOS_SESSION_ID="$CUR_SID" bash "$ENGINE/scripts/unlanded-branches-lint.sh" "$NOREC" --json --ledger "$T/ledger.jsonl" >"$T/unlanded2.json" 2>"$T/unlanded2.err"; rc_n=$?
sub "C14.5 with no branch recorded, unlanded-branches.py ABSTAINS (exit 2) rather than assuming main" \
    "[ $rc_n -eq 2 ]" "rc=$rc_n $(head -c 300 "$T/unlanded2.json") $(cat "$T/unlanded2.err")"
python3 - "$HOOKS/guard-unresolved-claims.py" "$DEV" "$DEV_TIP" "$NOREC" > "$T/claims.out" 2>&1 <<'PY'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("guc", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
dev, tip, norec = sys.argv[2], sys.argv[3], sys.argv[4]
print("dev:", m.state_verdict("integrated", tip, [dev], time.monotonic() + 8))
import subprocess
sha = subprocess.run(["git", "-C", norec, "rev-parse", "stray"], capture_output=True, text=True).stdout.strip()
print("norecord:", m.state_verdict("integrated", sha, [norec], time.monotonic() + 8))
PY
sub "C14.6 guard-unresolved-claims.py: a commit on the recorded dev branch (not main) is 'integrated'; with no record it abstains ('unknown')" \
    "grep -q \"dev: ('ok',)\" '$T/claims.out' && grep -q \"norecord: ('unknown',)\" '$T/claims.out'" "$(cat "$T/claims.out")"
MAINREFS="$(grep -c 'INTEGRATION_REFS\b' "$HOOKS/guard-unresolved-claims.py")"
MAINUSE="$(grep -n 'INTEGRATION_REFS' "$HOOKS/guard-unresolved-claims.py" | grep -v -E '^[0-9]+:INTEGRATION_REFS =|^[0-9]+:#' | wc -l | tr -d ' ')"
sub "C14.7 guard-unresolved-claims.py keeps no live fallback to main: its INTEGRATION_REFS tuple is referenced by no code" \
    "[ \"$MAINUSE\" = 0 ]" "INTEGRATION_REFS mentions=$MAINREFS, code uses=$MAINUSE: $(grep -n 'INTEGRATION_REFS' "$HOOKS/guard-unresolved-claims.py" | tr '\n' ' ')"
verdict

# ===========================================================================
begin C1 "Creating a non-native workspace not named cc/ is refused — non-zero exit, nothing created"
ws register-cc --name zach-opus-x1 --repo "$OTHER" --path "$T/other-wt/zach-opus-x1" --branch feature/x >"$T/reg.out" 2>&1; rc=$?
sub "C1.1 the registry refuses a non-native workspace on a branch not named cc/ (exit $rc)" \
    "[ $rc -ne 0 ] && grep -q 'cc/' '$T/reg.out' && [ -z \"\$(agent_rec zach-opus-x1)\" ] && [ ! -e '$T/other-wt/zach-opus-x1' ]" "$(cat "$T/reg.out")"
bash_guard "git worktree add $T/raw-feature -b feature/y"; rc=$?
sub "C1.2 a raw 'git worktree add' in Bash is refused by the worktree guard (exit $rc), and nothing is created" \
    "[ $rc -eq 2 ] && grep -q 'REFUSED' '$T/bash.err' && [ ! -e '$T/raw-feature' ]" "$(cat "$T/bash.err")"
bash_guard "git worktree add $T/raw-cc -b cc/zach-opus-raw"; rc=$?
sub "C1.3 even a raw add NAMED cc/ is refused: a workspace is created by create-teammate-worktree.sh, which registers it first (point 3)" \
    "[ $rc -eq 2 ] && [ ! -e '$T/raw-cc' ]" "$(cat "$T/bash.err")"
RICHOS_SESSION_ID="$CUR_SID" bash "$CREATE" "$OTHER" zach-opus-c1 >"$T/create.out" 2>&1; rc=$?
CC1="$T/other-wt/zach-opus-c1"
sub "C1.4 POSITIVE CONTROL: the sanctioned path creates a cc/ workspace, registered (exit $rc)" \
    "[ $rc -eq 0 ] && has_branch '$OTHER' cc/zach-opus-c1 && [ -d '$CC1' ] && [ -n \"\$(agent_rec zach-opus-c1)\" ]" "$(cat "$T/create.out")"
# It is registered but never spawned into. OBSERVED, not one of the fourteen: such
# a registration has no end-of-run signal, so it is not finished (point 11) and a
# discard refuses it until the session ends (point 12) or Rich stops it.
ws discard zach-opus-c1 --reason "the positive control of check 1 is over" --not-ceo-ordered "a fixture of this suite" >"$T/discard.out" 2>&1; rc0=$?
ws stop zach-opus-c1 --why "never spawned into; the control is over" >>"$T/discard.out" 2>&1
ws discard zach-opus-c1 --reason "the positive control of check 1 is over" --not-ceo-ordered "a fixture of this suite" >>"$T/discard.out" 2>&1; rc=$?
sub "C1.5 the control workspace, registered but never spawned into, is not finished until stopped (discard: $rc0, then stop, then discard: $rc) and is then deleted by the page's own discard" \
    "[ $rc0 -eq 2 ] && [ $rc -eq 0 ] && [ ! -e '$CC1' ] && ! has_branch '$OTHER' cc/zach-opus-c1" "$(cat "$T/discard.out")"
verdict

# ===========================================================================
begin C2 "No deletion path reaches a codex/ path or ref: with codex/ present in the fixture, every deleter runs and codex/ is byte-identical after; an agent briefed against codex/ work gets a cc/ copy"
CX="$T/codex-wt"
git -C "$OTHER" worktree add -q "$CX" -b codex/fix
commit_in "$CX" codex-work.txt
git -C "$OTHER" branch codex/other
codex_state() { { git -C "$OTHER" rev-parse codex/fix codex/other; git -C "$OTHER" worktree list --porcelain | grep -A3 "^worktree $CX\$"; (cd "$CX" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum -a 256); } | shasum -a 256 | cut -d' ' -f1; }
BEFORE="$(codex_state)"
# every deleter: an automatic land at the Stop gate, a discard, a retry, a
# SessionStart scan, the Bash guard on direct deletion, and a spawn aimed at it.
RICHOS_SESSION_ID="$CUR_SID" bash "$CREATE" "$OTHER" zach-opus-c2 >/dev/null 2>&1
CC2="$T/other-wt/zach-opus-c2"
spawn "zach-opus-c2" "$(printf 'x\ncross-repo-worktree: %s\n' "$CC2")"
platform_spawn "zach-opus-c2" "ac2c2c2c2c2c2c2c2"
commit_in "$CC2" c2.txt; subagent_stop "ac2c2c2c2c2c2c2c2"
git -C "$OTHER" merge -q --no-edit cc/zach-opus-c2
stop_gate; rc_land=$?
RICHOS_SESSION_ID="$CUR_SID" bash "$CREATE" "$OTHER" zach-opus-c2b >/dev/null 2>&1
CC2B="$T/other-wt/zach-opus-c2b"
spawn "zach-opus-c2b" "$(printf 'x\ncross-repo-worktree: %s\n' "$CC2B")"
platform_spawn "zach-opus-c2b" "ac2bc2bc2bc2bc2bc"
commit_in "$CC2B" c2b.txt; subagent_stop "ac2bc2bc2bc2bc2bc"
ws discard zach-opus-c2b --reason "the reviewer rejected it, check 2 fixture" --not-ceo-ordered "a fixture of this suite" >"$T/discard.out" 2>&1; rc_disc=$?
ws retry >/dev/null 2>&1
payload SessionStart "{\"session_id\":\"$CUR_SID\",\"cwd\":\"$ENT\"}" | bash "$HOOKS/workspace-lifecycle.sh" >/dev/null 2>>"$T/hooks.err"
sub "C2.1 a land (exit $rc_land) and a discard (exit $rc_disc) in the repository ran, the retry ran, the SessionStart scan ran" "[ $rc_land -eq 0 ] && [ $rc_disc -eq 0 ]" "$(cat "$T/stop.err" "$T/discard.out")"
bash_guard "git branch -D codex/other"; r1=$?
bash_guard "git worktree remove $CX"; r2=$?
bash_guard "rm -rf $CX"; r3=$?
bash_guard "git worktree remove $CX  # worktree-remove-ack: I really want to"; r4=$?
sub "C2.2 direct deletion of the codex/ branch or workspace is refused in Bash, with no override (exits $r1 $r2 $r3 $r4)" \
    "[ $r1 -eq 2 ] && [ $r2 -eq 2 ] && [ $r3 -eq 2 ] && [ $r4 -eq 2 ]" "$(cat "$T/bash.err")"
spawn "zach-opus-cx" "$(printf 'fix it in codex\ncross-repo-worktree: %s\n' "$CX")"; rc=$?
sub "C2.3 a spawn aimed INSIDE the codex/ workspace is refused (exit $rc)" "[ $rc -eq 2 ] && grep -q 'codex/' '$T/spawn.err'" "$(cat "$T/spawn.err")"
RICHOS_SESSION_ID="$CUR_SID" bash "$CREATE" "$OTHER" zach-opus-cb --base codex/fix >"$T/create.out" 2>&1; rc=$?
sub "C2.4 a cc/ workspace based ON the codex/ branch is refused, and the refusal names the copy to take instead (exit $rc)" \
    "[ $rc -eq 3 ] && grep -q 'branch from the commit instead' '$T/create.out' && ! has_branch '$OTHER' cc/zach-opus-cb" "$(cat "$T/create.out")"
RICHOS_SESSION_ID="$CUR_SID" bash "$CREATE" "$OTHER" zach-opus-cc --base "$(git -C "$OTHER" rev-parse codex/fix)" >"$T/create.out" 2>&1; rc=$?
CCC="$T/other-wt/zach-opus-cc"
sub "C2.5 an agent briefed against codex/ work gets a cc/ COPY: cc/zach-opus-cc at the codex/fix commit (exit $rc)" \
    "[ $rc -eq 0 ] && [ \"\$(git -C '$CCC' rev-parse HEAD)\" = \"\$(git -C '$OTHER' rev-parse codex/fix)\" ] && [ \"\$(git -C '$CCC' rev-parse --abbrev-ref HEAD)\" = cc/zach-opus-cc ]" "$(cat "$T/create.out")"
ws stop zach-opus-cc --why "the codex/ copy fixture is done with" >/dev/null 2>&1        # never spawned into: no end signal of its own
ws discard zach-opus-cc --reason "the codex/ copy fixture is done with" --not-ceo-ordered "a fixture of this suite" >/dev/null 2>&1
AFTER="$(codex_state)"
sub "C2.6 codex/ is byte-identical after every deleter ran: refs, worktree listing and every file" \
    "[ \"$BEFORE\" = \"$AFTER\" ] && [ -d '$CX' ] && has_branch '$OTHER' codex/fix && has_branch '$OTHER' codex/other" "before=$BEFORE after=$AFTER"
stop_gate; rc=$?
sub "C2.7 nothing pending after check 2 (the codex/ workspace is not the system's concern)" "[ $rc -eq 0 ]" "$(cat "$T/stop.err")"
verdict

# ===========================================================================
begin C3 "A registration failure means the spawn does not happen; claude -w is refused; an unregistered cc/ or native workspace appears in point 5's pending list"
GOOD_PID="$RICHOS_SESSION_PID"
export RICHOS_SESSION_PID=999999            # a process that does not exist: the session's identity cannot be read
spawn "zach-opus-r1" "work"; rc=$?
export RICHOS_SESSION_PID="$GOOD_PID"
sub "C3.1 a registration that fails (no session identity) refuses the spawn (exit $rc) and leaves no record" \
    "[ $rc -eq 2 ] && grep -q -i 'regist' '$T/spawn.err' && [ -z \"\$(agent_rec zach-opus-r1)\" ]" "$(cat "$T/spawn.err")"
bash_guard "claude --worktree"; r1=$?
bash_guard "claude -w"; r2=$?
bash_guard "cd /somewhere && claude -w --model opus"; r3=$?
sub "C3.2 'claude --worktree' and 'claude -w' are refused in Bash (exits $r1 $r2 $r3)" "[ $r1 -eq 2 ] && [ $r2 -eq 2 ] && [ $r3 -eq 2 ]" "$(cat "$T/bash.err")"
git -C "$ENT" worktree add -q "$ENT/.claude/worktrees/lead-here" -b lead-here
WT_SID="sess-in-a-worktree-9"
SAVE_SID="$CUR_SID"
start_session "$WT_SID" "$ENT/.claude/worktrees/lead-here"
barrier "" Edit; re=$?
barrier "" Read; rr=$?
FORB="$(jget "$STORE/sessions/$WT_SID.json" forbidden)"
sub "C3.3 a session started inside its own workspace is recorded as not allowed; its lead is refused Edit ($re) and allowed Read ($rr)" \
    "[ -n \"$FORB\" ] && [ $re -eq 2 ] && [ $rr -eq 0 ]" "forbidden=$FORB $(cat "$T/barrier.err")"
payload SessionEnd "{\"session_id\":\"$WT_SID\",\"reason\":\"exit\"}" | bash "$HOOKS/workspace-lifecycle.sh" >/dev/null 2>&1
git -C "$ENT" worktree remove --force "$ENT/.claude/worktrees/lead-here"; git -C "$ENT" branch -D lead-here >/dev/null 2>&1
CUR_SID="$SAVE_SID"; export RICHOS_SESSION_PID="$GOOD_PID"
git -C "$OTHER" worktree add -q "$T/rogue-cc" -b cc/rogue-hand      # made raw: registered by nothing
commit_in "$T/rogue-cc" rogue.txt
git -C "$ENT" worktree add -q "$ENT/.claude/worktrees/agent-deadbeefdeadbeef0" -b worktree-agent-deadbeefdeadbeef0
commit_in "$ENT/.claude/worktrees/agent-deadbeefdeadbeef0" native-rogue.txt
stop_gate; rc=$?
sub "C3.4 an unregistered cc/ workspace is in point 5's list: the turn cannot end and it is named" \
    "[ $rc -eq 2 ] && grep -q 'orphan-rogue-cc' '$T/stop.err'" "$(cat "$T/stop.err")"
sub "C3.5 an unregistered NATIVE workspace is in point 5's list too, by name" \
    "[ $rc -eq 2 ] && grep -q 'orphan-agent-deadbeefdeadbeef0' '$T/stop.err'" "$(cat "$T/stop.err")"
spawn "zach-opus-r2" "new work"; rc=$?
sub "C3.6 and new work is refused while they are pending" "[ $rc -eq 2 ]" "$(cat "$T/spawn.err")"
ws discard orphan-rogue-cc --reason "made by hand, never registered" --not-ceo-ordered "a fixture of this suite" >"$T/d1.out" 2>&1; r1=$?
ws discard orphan-agent-deadbeefdeadbeef0 --reason "made by hand, never registered" --not-ceo-ordered "a fixture of this suite" >"$T/d2.out" 2>&1; r2=$?
sub "C3.7 both are handled under point 5 (discarded: $r1 $r2) and gone" \
    "[ $r1 -eq 0 ] && [ $r2 -eq 0 ] && [ ! -e '$T/rogue-cc' ] && ! has_branch '$OTHER' cc/rogue-hand && [ ! -e '$ENT/.claude/worktrees/agent-deadbeefdeadbeef0' ] && ! has_branch '$ENT' worktree-agent-deadbeefdeadbeef0" "$(cat "$T/d1.out" "$T/d2.out")"
verdict

# ===========================================================================
begin C6 "Points 3 and 4 again, against a native agent-<id> / worktree-agent-<id> pair"
spawn "zach-opus-n1" "native work"; rc=$?
platform_spawn "zach-opus-n1" "an1n1n1n1n1n1n1n1"
NP1="$ENT/.claude/worktrees/agent-an1n1n1n1n1n1n1n1"
REC="$(agent_rec zach-opus-n1)"
sub "C6.1 the spawn is registered (exit $rc) and the native workspace joins its record by path and branch" \
    "[ $rc -eq 0 ] && [ -n \"$REC\" ] && grep -q '\"kind\": \"native\"' '$REC' && grep -q 'agent-an1n1n1n1n1n1n1n1' '$REC' && grep -q 'worktree-agent-an1n1n1n1n1n1n1n1' '$REC'" "$(head -30 "$REC" 2>/dev/null)"
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","session_id":sys.argv[1],"tool_use_id":"tu-never-registered","tool_name":"Agent","cwd":sys.argv[2],"tool_input":{"name":"zach-opus-ghost","isolation":"worktree"},"tool_response":{"agentId":"aghostghostghost1","status":"async_launched"}}))' "$CUR_SID" "$ENT" \
    | bash "$HOOKS/workspace-lifecycle.sh" >/dev/null 2>>"$T/hooks.err"
barrier "aghostghostghost1" Edit; rc=$?
sub "C6.2 a native agent whose spawn was never registered gets no record and is refused every writing tool (exit $rc): the spawn did not happen" \
    "[ $rc -eq 2 ] && [ ! -e '$STORE/ids/aghostghostghost1' ]" "$(cat "$T/barrier.err")"
commit_in "$NP1" n1.txt
subagent_stop "an1n1n1n1n1n1n1n1"
git -C "$ENT" merge -q --no-edit "worktree-agent-an1n1n1n1n1n1n1n1"
stop_gate; rc=$?
sub "C6.3 after the land (automatic, exit $rc): workspace absent, branch absent, no prompt, no quarantine directory, no registry entry" \
    "[ $rc -eq 0 ] && [ ! -e '$NP1' ] && ! listed '$ENT' '$NP1' && ! has_branch '$ENT' worktree-agent-an1n1n1n1n1n1n1n1 && [ -z \"\$(quarantine_dirs)\" ] && [ -z \"\$(agent_rec zach-opus-n1)\" ] && [ -n \"\$(done_rec zach-opus-n1)\" ]" "$(cat "$T/stop.err") quarantine=$(quarantine_dirs)"
verdict

# ===========================================================================
begin C4 "After a land: workspace absent, branch absent, no prompt, no quarantine directory, no registry entry"
RICHOS_SESSION_ID="$CUR_SID" bash "$CREATE" "$OTHER" zach-opus-l1 >/dev/null 2>&1
CCL="$T/other-wt/zach-opus-l1"
spawn "zach-opus-l1" "$(printf 'x\ncross-repo-worktree: %s\n' "$CCL")"
platform_spawn "zach-opus-l1" "al1l1l1l1l1l1l1l1"
NPL="$ENT/.claude/worktrees/agent-al1l1l1l1l1l1l1l1"
commit_in "$CCL" l1.txt
subagent_stop "al1l1l1l1l1l1l1l1"
git -C "$OTHER" merge -q --no-edit cc/zach-opus-l1
BEFORE_WT="$(git -C "$OTHER" worktree list --porcelain | grep -c '^worktree ')"
stop_gate; rc=$?
sub "C4.1 no prompt: the merged work is landed by the Stop gate itself, with no command (exit $rc)" "[ $rc -eq 0 ] && ! grep -q 'land' '$T/stop.err'" "$(cat "$T/stop.err")"
sub "C4.2 workspace absent — from disk and from git's list (both workspaces)" \
    "[ ! -e '$CCL' ] && ! listed '$OTHER' '$CCL' && [ ! -e '$NPL' ] && ! listed '$ENT' '$NPL'"
sub "C4.3 branch absent (both)" "! has_branch '$OTHER' cc/zach-opus-l1 && ! has_branch '$ENT' worktree-agent-al1l1l1l1l1l1l1l1"
sub "C4.4 no quarantine directory anywhere in the sandbox, and no detached leftover in either repository's worktree list" \
    "[ -z \"\$(quarantine_dirs)\" ] && ! git -C '$OTHER' worktree list --porcelain | grep -q '^detached' && ! git -C '$ENT' worktree list --porcelain | grep -q '^detached'" "$(quarantine_dirs; git -C "$OTHER" worktree list)"
sub "C4.5 no registry entry: nothing in agents/ names it, status lists nothing for it; its ending is in done/" \
    "[ -z \"\$(agent_rec zach-opus-l1)\" ] && [ -n \"\$(done_rec zach-opus-l1)\" ] && ! ws status 2>/dev/null | grep -q 'zach-opus-l1'"
verdict

# ===========================================================================
begin C7 "Every ending reads landed or discarded in the store; a discard carries its reason; an agent that produced nothing reads landed; CEO-ordered work cannot be discarded without a recorded word"
D="$(done_rec zach-opus-l1)"
sub "C7.1 the landed agent's ending reads 'landed' in the store" "[ \"\$(jget '$D' disposition.kind)\" = landed ]" "$(jget "$D" disposition)"
D2="$(done_rec zach-opus-c2b)"
sub "C7.2 the discarded agent's ending reads 'discarded' with its reason and the tips it deleted" \
    "[ \"\$(jget '$D2' disposition.kind)\" = discarded ] && [ -n \"\$(jget '$D2' disposition.reason)\" ] && [ -n \"\$(jget '$D2' disposition.tips)\" ]" "$(jget "$D2" disposition)"
spawn "zach-opus-z0" "produce nothing"
platform_spawn "zach-opus-z0" "az0z0z0z0z0z0z0z0"
subagent_stop "az0z0z0z0z0z0z0z0"
stop_gate; rc=$?
DZ="$(done_rec zach-opus-z0)"
sub "C7.3 an agent that produced nothing counts as landed: deleted on its own (exit $rc) and its ending reads 'landed'" \
    "[ $rc -eq 0 ] && [ -n \"$DZ\" ] && [ \"\$(jget '$DZ' disposition.kind)\" = landed ] && [ ! -e '$ENT/.claude/worktrees/agent-az0z0z0z0z0z0z0z0' ]" "$(cat "$T/stop.err")"
spawn "zach-opus-ceo" "$(printf 'build the thing he asked for\nceo-ordered: build the thing, his words 2026-09-12\n')"
platform_spawn "zach-opus-ceo" "aceoceoceoceoceo1"
commit_in "$ENT/.claude/worktrees/agent-aceoceoceoceoceo1" ceo.txt
subagent_stop "aceoceoceoceoceo1"
ws discard zach-opus-ceo --reason "a reviewer rejected the approach" --not-ceo-ordered "it was not his order, I think" >"$T/d.out" 2>&1; r1=$?
sub "C7.4 work recorded as CEO-ordered cannot be discarded without his word (exit $r1), even with a --not-ceo-ordered claim" \
    "[ $r1 -eq 2 ] && grep -q 'his word' '$T/d.out' && [ -e '$ENT/.claude/worktrees/agent-aceoceoceoceoceo1' ]" "$(cat "$T/d.out")"
ws discard zach-opus-ceo --reason "a reviewer rejected the approach" --ceo-word "drop it, he said 2026-09-12" >"$T/d.out" 2>&1; r2=$?
DC="$(done_rec zach-opus-ceo)"
sub "C7.5 with his word it is discarded and the word is RECORDED (exit $r2)" \
    "[ $r2 -eq 0 ] && [ \"\$(jget '$DC' disposition.ceo_word)\" = 'drop it, he said 2026-09-12' ]" "$(cat "$T/d.out") $(jget "$DC" disposition)"
verdict

# ===========================================================================
begin C8 "A land of a tree with uncommitted or needed-ignored files is refused; after the commit it proceeds; nothing under the tree is lost by the deletion"
spawn "zach-opus-u1" "work, then leave things"
platform_spawn "zach-opus-u1" "au1u1u1u1u1u1u1u1"
NPU="$ENT/.claude/worktrees/agent-au1u1u1u1u1u1u1u1"
commit_in "$NPU" u1.txt
printf 'half-written\n' > "$NPU/draft.txt"                 # uncommitted
printf 'SECRET=needed\n' > "$NPU/.env"                     # ignored, and the main checkout does not have it
subagent_stop "au1u1u1u1u1u1u1u1"
git -C "$ENT" merge -q --no-edit "worktree-agent-au1u1u1u1u1u1u1u1"
ws land zach-opus-u1 >"$T/land.out" 2>&1; r1=$?
sub "C8.1 the land is refused while draft.txt is uncommitted (exit $r1), naming the uncommitted entry, and the tree is untouched" \
    "[ $r1 -eq 2 ] && grep -q 'uncommitted entr' '$T/land.out' && grep -q 'draft.txt' '$T/land.out' && [ -e '$NPU/draft.txt' ] && [ -e '$NPU/.env' ]" "$(cat "$T/land.out")"
stop_gate; r2=$?
sub "C8.2 the Stop gate does not land it either: it is pending, by name" "[ $r2 -eq 2 ] && grep -q 'zach-opus-u1' '$T/stop.err'" "$(cat "$T/stop.err")"
git -C "$NPU" add draft.txt && git -C "$NPU" commit -q -m "what it left"
git -C "$ENT" merge -q --no-edit "worktree-agent-au1u1u1u1u1u1u1u1"
ws land zach-opus-u1 >"$T/land.out" 2>&1; r3=$?
sub "C8.3 committed and merged, the land is still refused for the ignored .env the main checkout lacks (exit $r3)" \
    "[ $r3 -eq 2 ] && grep -q 'ignored' '$T/land.out' && [ -e '$NPU/.env' ]" "$(cat "$T/land.out")"
cp "$NPU/.env" "$ENT/.env"                                  # Rich keeps what it needs
TIP="$(git -C "$NPU" rev-parse HEAD)"
ws land zach-opus-u1 >"$T/land.out" 2>&1; r4=$?
sub "C8.4 with the needed file kept, the land proceeds (exit $r4) and the workspace and branch are gone" \
    "[ $r4 -eq 0 ] && [ ! -e '$NPU' ] && ! has_branch '$ENT' worktree-agent-au1u1u1u1u1u1u1u1" "$(cat "$T/land.out")"
MISSING_FILES="$(git -C "$ENT" ls-tree -r --name-only "$TIP" | while read -r f; do [ -e "$ENT/$f" ] || echo "$f"; done)"
sub "C8.5 nothing under the tree is lost: every file of the agent's tip is in the main checkout, and so is .env" \
    "[ -z \"$MISSING_FILES\" ] && grep -q 'SECRET=needed' '$ENT/.env' && git -C '$ENT' merge-base --is-ancestor $TIP main" "missing: $MISSING_FILES"
verdict

# ===========================================================================
begin C9 "A restarted finished agent gets no tool; a process started inside the workspace is dead before deletion (fixture: a sleeper holding an open file)"
spawn "zach-opus-p1" "start a process"
platform_spawn "zach-opus-p1" "ap1p1p1p1p1p1p1p1"
NPP="$ENT/.claude/worktrees/agent-ap1p1p1p1p1p1p1p1"
commit_in "$NPP" p1.txt
printf 'held\n' > "$NPP/held.txt"; git -C "$NPP" add held.txt; git -C "$NPP" commit -q -m held
HOLD_PID="$(cd "$NPP" && sh -c 'exec 3<held.txt; sleep 3600 >/dev/null 2>&1 & echo $!')"   # cwd inside, a file open
subagent_stop "ap1p1p1p1p1p1p1p1"
barrier "ap1p1p1p1p1p1p1p1" Read; r1=$?
barrier "ap1p1p1p1p1p1p1p1" Bash; r2=$?
sub "C9.1 finished: the restarted agent is refused every tool, Read ($r1) and Bash ($r2) alike" "[ $r1 -eq 2 ] && [ $r2 -eq 2 ]" "$(cat "$T/barrier.err")"
sub "C9.2 POSITIVE CONTROL: the sleeper is alive in the workspace before the land (pid $HOLD_PID)" "kill -0 $HOLD_PID 2>/dev/null"
git -C "$ENT" merge -q --no-edit "worktree-agent-ap1p1p1p1p1p1p1p1"
stop_gate; rc=$?
sleep 0.3
ALIVE=0; kill -0 "$HOLD_PID" 2>/dev/null && ALIVE=1
sub "C9.3 landed (exit $rc): the process is dead and the workspace is gone" "[ $rc -eq 0 ] && [ $ALIVE -eq 0 ] && [ ! -e '$NPP' ]" "alive=$ALIVE $(cat "$T/stop.err")"
KEY="$(basename "$(done_rec zach-opus-p1)" .json)"
ORDER="$(grep -E '"event": "(processes-stopped|deleted)"' "$STORE/events.jsonl" | grep -E "processes-stopped.*$HOLD_PID|\"key\": \"$KEY\"" | grep -o -E '"event": "[a-z-]+"' | tr -d '"' | sed 's/event: //' | tr '\n' ' ')"
sub "C9.4 and it was stopped BEFORE the deletion: the store's history reads 'processes-stopped' then 'deleted'" \
    "[ \"$ORDER\" = 'processes-stopped deleted ' ]" "order=[$ORDER]"
barrier "ap1p1p1p1p1p1p1p1" Write; r3=$?
sub "C9.5 restarted after its workspace is gone: still refused ($r3)" "[ $r3 -eq 2 ]"
verdict

# ===========================================================================
begin C10 "Landing a two-workspace agent removes both workspaces and both branches in one operation"
RICHOS_SESSION_ID="$CUR_SID" bash "$CREATE" "$OTHER" zach-opus-t1 >/dev/null 2>&1
CCT="$T/other-wt/zach-opus-t1"
spawn "zach-opus-t1" "$(printf 'two workspaces\ncross-repo-worktree: %s\n' "$CCT")"
platform_spawn "zach-opus-t1" "at1t1t1t1t1t1t1t1"
NPT="$ENT/.claude/worktrees/agent-at1t1t1t1t1t1t1t1"
commit_in "$CCT" t1.txt; commit_in "$NPT" t1-native.txt
subagent_stop "at1t1t1t1t1t1t1t1"
git -C "$OTHER" merge -q --no-edit cc/zach-opus-t1
git -C "$ENT" merge -q --no-edit "worktree-agent-at1t1t1t1t1t1t1t1"
REC="$(agent_rec zach-opus-t1)"
sub "C10.1 POSITIVE CONTROL: before the land the agent has both workspaces registered and both exist" \
    "[ \"\$(python3 -c 'import json,sys; print(len([w for w in json.load(open(sys.argv[1]))[\"workspaces\"] if not w.get(\"deleted_at\")]))' '$REC')\" = 2 ] && [ -d '$CCT' ] && [ -d '$NPT' ]"
BEFORE_EVENTS="$(wc -l < "$STORE/events.jsonl")"
ws land zach-opus-t1 >"$T/land.out" 2>&1; rc=$?
sub "C10.2 ONE operation (exit $rc): both workspaces gone" "[ $rc -eq 0 ] && [ ! -e '$CCT' ] && [ ! -e '$NPT' ] && ! listed '$OTHER' '$CCT' && ! listed '$ENT' '$NPT'" "$(cat "$T/land.out")"
sub "C10.3 and both branches gone" "! has_branch '$OTHER' cc/zach-opus-t1 && ! has_branch '$ENT' worktree-agent-at1t1t1t1t1t1t1t1"
NEW_LANDED="$(tail -n +"$((BEFORE_EVENTS + 1))" "$STORE/events.jsonl" | grep -c '"event": "landed"')"
NEW_DELETED="$(tail -n +"$((BEFORE_EVENTS + 1))" "$STORE/events.jsonl" | grep -c '"event": "deleted"')"
sub "C10.4 the store records one land and one deletion covering both (landed=$NEW_LANDED deleted=$NEW_DELETED)" "[ $NEW_LANDED -eq 1 ] && [ $NEW_DELETED -eq 1 ]"
verdict

# ===========================================================================
begin C11 "A SubagentStop for a sub-run does not finish the teammate; a pause is recorded with what ends it; a pause naming nothing appears in point 5's list"
spawn "zach-opus-s1" "long work with sub-runs"
platform_spawn "zach-opus-s1" "as1s1s1s1s1s1s1s1"
NPS="$ENT/.claude/worktrees/agent-as1s1s1s1s1s1s1s1"
commit_in "$NPS" s1.txt
subagent_stop "asubrun00000000001"                          # a sub-run's own id, not the teammate's
subagent_stop "asubrun00000000002"
barrier "as1s1s1s1s1s1s1s1" Edit; r1=$?
stop_gate; r2=$?
sub "C11.1 two SubagentStops carrying sub-run ids do not finish the teammate: it may still write ($r1) and nothing is pending ($r2)" \
    "[ $r1 -eq 0 ] && [ $r2 -eq 0 ]" "$(cat "$T/barrier.err" "$T/stop.err")"
send_message "zach-opus-s1" "$(printf 'commit and hold\npause-until: the CEO'"'"'s answer\n')"
REC="$(agent_rec zach-opus-s1)"
sub "C11.2 a pause sent to it is RECORDED with what ends it" "[ \"\$(jget '$REC' pause.until)\" = \"the CEO's answer\" ]" "$(jget "$REC" pause)"
subagent_stop "as1s1s1s1s1s1s1s1"                           # its own run ends while paused
barrier "as1s1s1s1s1s1s1s1" Edit; r3=$?
stop_gate; r4=$?
sub "C11.3 its own end of run while PAUSED is not finished: not locked out ($r3), not pending ($r4)" "[ $r3 -eq 0 ] && [ $r4 -eq 0 ]" "$(cat "$T/barrier.err" "$T/stop.err")"
send_message "zach-opus-s1" "go on, here is his answer"
barrier "as1s1s1s1s1s1s1s1" Edit; r5=$?
sub "C11.4 a later message resumes it ($r5)" "[ $r5 -eq 0 ] && [ -z \"\$(jget '$REC' pause)\" ]" "$(jget "$REC" pause)"
ws pause zach-opus-s1 --until "" >"$T/pause.out" 2>&1
subagent_stop "as1s1s1s1s1s1s1s1"
stop_gate; r6=$?
sub "C11.5 a pause naming NOTHING is pending work under point 5: the turn cannot end and it is named" \
    "[ $r6 -eq 2 ] && grep -q 'zach-opus-s1' '$T/stop.err' && grep -q -i 'nothing named' '$T/stop.err'" "$(cat "$T/pause.out" "$T/stop.err")"
ws stop zach-opus-s1 --why "its work is no longer wanted" >/dev/null 2>&1
subagent_stop "as1s1s1s1s1s1s1s1"
barrier "as1s1s1s1s1s1s1s1" Edit; r7=$?
git -C "$ENT" merge -q --no-edit "worktree-agent-as1s1s1s1s1s1s1s1"
stop_gate; r8=$?
sub "C11.6 stopped: it is finished ($r7 = refused), and its own SubagentStop carrying ITS id is the end-of-run signal; landed once merged ($r8)" \
    "[ $r7 -eq 2 ] && [ $r8 -eq 0 ] && [ ! -e '$NPS' ]" "$(cat "$T/stop.err")"
verdict

# ===========================================================================
begin C5 "With one finished-and-unlanded agent, a spawn and a turn end are both refused; the two allowances his sentence names are allowed; nothing else is"
spawn "zach-opus-a1" "finish without being merged"
platform_spawn "zach-opus-a1" "aa1a1a1a1a1a1a1a1"
NPA="$ENT/.claude/worktrees/agent-aa1a1a1a1a1a1a1a1"
commit_in "$NPA" a1.txt
subagent_stop "aa1a1a1a1a1a1a1a1"
spawn "zach-opus-b1" "unrelated new work"; r1=$?
stop_gate; r2=$?
sub "C5.1 a spawn is refused ($r1), naming the agent" \
    "[ $r1 -eq 2 ] && grep -q 'zach-opus-a1' '$T/spawn.err'" "$(cat "$T/spawn.err")"
sub "C5.1b and a turn end is refused ($r2), naming the agent" \
    "[ $r2 -eq 2 ] && grep -q 'zach-opus-a1' '$T/stop.err'" "$(cat "$T/stop.err")"
TR="$T/transcript-ceo.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"Where is it? (the CEO)"}}' > "$TR"
TRN="$T/transcript-notification.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"<task-notification>agent done</task-notification>"}}' > "$TRN"
# The two "nothing else" cases come FIRST: the one allowance is spent by the
# reply that uses it, and a refusal after that would be for the wrong reason.
stop_gate "zach-opus-a1 is pending" "$TRN"; r5=$?
sub "C5.4 NOTHING ELSE: a turn that began with a platform notification, not the CEO, is refused even when it names the work ($r5)" "[ $r5 -eq 2 ]" "$(cat "$T/stop.err")"
stop_gate "all good" "$TR"; r6=$?
sub "C5.5 NOTHING ELSE: a reply to the CEO that does not name the pending work is refused ($r6)" "[ $r6 -eq 2 ]" "$(cat "$T/stop.err")"
stop_gate "It is pending: zach-opus-a1 finished and is not merged yet; I land it right after this." "$TR"; r3=$?
sub "C5.2 ALLOWANCE 1: answering the CEO, naming the pending work, may end the turn ($r3)" "[ $r3 -eq 0 ]" "$(cat "$T/stop.err")"
stop_gate "It is pending: zach-opus-a1 finished and is not merged yet; I land it right after this." "$TR"; r4=$?
sub "C5.3 NOTHING ELSE: naming it a second time without handling it is refused ($r4) — the allowance is spent" "[ $r4 -eq 2 ]" "$(cat "$T/stop.err")"
spawn "zach-opus-h1" "$(printf 'merge and land it\nlands-pending: zach-opus-a1\n')"; r7=$?
sub "C5.6 ALLOWANCE 2: work whose only purpose is landing it may start ($r7)" "[ $r7 -eq 0 ]" "$(cat "$T/spawn.err")"
stop_gate; r8=$?
sub "C5.7 and with that work started, the turn may end ($r8) while the item waits on it" "[ $r8 -eq 0 ] && grep -q 'zach-opus-a1' '$T/stop.out'" "$(cat "$T/stop.out" "$T/stop.err")"
spawn "zach-opus-b2" "unrelated new work"; r9=$?
sub "C5.8 NOTHING ELSE: unrelated new work is still refused ($r9)" "[ $r9 -eq 2 ]" "$(cat "$T/spawn.err")"
platform_spawn "zach-opus-h1" "ah1h1h1h1h1h1h1h1"
git -C "$ENT" merge -q --no-edit "worktree-agent-aa1a1a1a1a1a1a1a1"
subagent_stop "ah1h1h1h1h1h1h1h1"
stop_gate; r10=$?
sub "C5.9 merged: both are landed on their own and the turn may end ($r10)" "[ $r10 -eq 0 ] && [ ! -e '$NPA' ] && [ -n \"\$(done_rec zach-opus-a1)\" ] && [ -n \"\$(done_rec zach-opus-h1)\" ]" "$(cat "$T/stop.err")"
verdict

# ===========================================================================
begin C13 "A deletion blocked by a held file is retried without involvement and succeeds when the hold clears; the CEO hears only after a stated number of failures"
spawn "zach-opus-k1" "leave a held file"
platform_spawn "zach-opus-k1" "ak1k1k1k1k1k1k1k1"
NPK="$ENT/.claude/worktrees/agent-ak1k1k1k1k1k1k1k1"
commit_in "$NPK" k1.txt
printf 'held by the OS\n' > "$NPK/pinned.txt"; git -C "$NPK" add pinned.txt; git -C "$NPK" commit -q -m pinned
if command -v chflags >/dev/null 2>&1; then chflags uchg "$NPK/pinned.txt"; HOLD=uchg; else chmod 555 "$(dirname "$NPK")"; HOLD=chmod; fi
subagent_stop "ak1k1k1k1k1k1k1k1"
git -C "$ENT" merge -q --no-edit "worktree-agent-ak1k1k1k1k1k1k1k1"
stop_gate; rc=$?
REC="$(agent_rec zach-opus-k1)"
A1="$(jget "$REC" deletion.attempts)"
sub "C13.1 the land is recorded ($rc, landed) and the deletion FAILED on the held file: attempt 1, workspace still there, retry scheduled" \
    "[ $rc -eq 0 ] && [ \"\$(jget '$REC' disposition.kind)\" = landed ] && [ \"$A1\" = 1 ] && [ -e '$NPK' ] && [ -n \"\$(jget '$REC' deletion.next_at)\" ]" "hold=$HOLD attempts=$A1 $(jget "$REC" deletion)"
sub "C13.2 the CEO does NOT hear of it yet (no 'TELL THE CEO' at attempt 1)" "! grep -q 'TELL THE CEO' '$T/stop.out' '$T/stop.err'" "$(cat "$T/stop.out")"
STATED="$(sed -n 's/^RETRY_TELL_CEO_AFTER = int(os.environ.get("RICHOS_WORKSPACES_RETRY_TELL_CEO", "\([0-9]*\)")).*/\1/p' "$ENGINE/scripts/lib/workspaces.py")"
subagent_stop "anothersubrun0001"                          # hook events, no command: each one retries what is due
subagent_stop "anothersubrun0002"
A3="$(jget "$REC" deletion.attempts)"
sub "C13.3 retried WITHOUT involvement: two unrelated hook events later the attempt count is $A3 (no command was run)" "[ \"$A3\" -ge 3 ]"
stop_gate >/dev/null 2>&1
A4="$(jget "$REC" deletion.attempts)"
sub "C13.4 still below the stated number ($STATED): the CEO is not told at attempt $A4" "[ \"$A4\" -lt \"$STATED\" ] && ! grep -q 'TELL THE CEO' '$T/stop.out'" "$(cat "$T/stop.out")"
i=0; while [ "$(jget "$REC" deletion.attempts)" -lt "$STATED" ] && [ $i -lt 10 ]; do subagent_stop "anothersubrun00$i"; i=$((i + 1)); done
stop_gate; rc=$?
AN="$(jget "$REC" deletion.attempts)"
sub "C13.5 at the stated number of failures ($STATED, now $AN) the turn-end gate tells the CEO, by name, and still lets the turn end ($rc)" \
    "[ \"$AN\" -ge \"$STATED\" ] && grep -q 'TELL THE CEO' '$T/stop.out' && grep -q 'zach-opus-k1' '$T/stop.out' && [ $rc -eq 0 ]" "$(cat "$T/stop.out" "$T/stop.err")"
if [ "$HOLD" = uchg ]; then chflags nouchg "$NPK/pinned.txt"; else chmod 755 "$(dirname "$NPK")"; fi
subagent_stop "anothersubrun0099"                           # the hold clears; the next hook event retries
sub "C13.6 when the hold clears, the next retry succeeds on its own: workspace and branch gone, nothing left retrying" \
    "[ ! -e '$NPK' ] && ! has_branch '$ENT' worktree-agent-ak1k1k1k1k1k1k1k1 && [ -z \"\$(agent_rec zach-opus-k1)\" ] && [ -n \"\$(done_rec zach-opus-k1)\" ]" "$(ls "$NPK" 2>&1 | head -3)"
verdict

# ===========================================================================
begin C12 "The session is recorded at start; its end is read from the process start-time, never a pid alone; the next session lands or discards the previous session's agents before any spawn"
S="$STORE/sessions/$CUR_SID.json"
sub "C12.1 SessionStart recorded the session with its process number AND its process start time" \
    "[ -n \"\$(jget '$S' pid)\" ] && [ -n \"\$(jget '$S' pid_start)\" ]" "$(cat "$S" 2>/dev/null | head -c 300)"
spawn "zach-opus-w1" "work that outlives nothing"
platform_spawn "zach-opus-w1" "aw1w1w1w1w1w1w1w1"
NPW="$ENT/.claude/worktrees/agent-aw1w1w1w1w1w1w1w1"
commit_in "$NPW" w1.txt
ORIG_START="$(jget "$S" pid_start)"
python3 - "$S" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["pid_start"] = "Thu Jan  1 00:00:00 1970"; json.dump(d, open(p, "w"))
PY
barrier "aw1w1w1w1w1w1w1w1" Edit; r1=$?
sub "C12.2 NEVER A PID ALONE: the same live pid with a different recorded start time is a different process — the session counts as ended and its agent is locked out ($r1)" \
    "[ $r1 -eq 2 ] && grep -q -i 'session' '$T/barrier.err'" "$(cat "$T/barrier.err")"
python3 - "$S" "$ORIG_START" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["pid_start"] = sys.argv[2]; json.dump(d, open(p, "w"))
PY
barrier "aw1w1w1w1w1w1w1w1" Edit; r2=$?
sub "C12.3 POSITIVE CONTROL: with the true start time restored the agent is live again ($r2)" "[ $r2 -eq 0 ]"
OLD_PID="$RICHOS_SESSION_PID"
kill "$OLD_PID"; while kill -0 "$OLD_PID" 2>/dev/null; do sleep 0.1; done
start_session "sess-fourteen-2222"
sub "C12.4 the process is gone, read from the OS: the NEXT session is told first, by name" \
    "grep -q 'zach-opus-w1' '$T/last-start.json' && grep -q 'FIRST' '$T/last-start.json'" "$(cat "$T/last-start.json" "$T/last-start.err")"
spawn "zach-opus-x2" "new work in the new session"; r3=$?
sub "C12.5 before any spawn: new work is refused until the previous session's agent is landed or discarded ($r3)" "[ $r3 -eq 2 ] && grep -q 'zach-opus-w1' '$T/spawn.err'" "$(cat "$T/spawn.err")"
git -C "$ENT" merge -q --no-edit "worktree-agent-aw1w1w1w1w1w1w1w1"
ws land zach-opus-w1 >"$T/land.out" 2>&1; r4=$?
spawn "zach-opus-x2" "new work in the new session"; r5=$?
platform_spawn "zach-opus-x2" "ax2x2x2x2x2x2x2x2"; subagent_stop "ax2x2x2x2x2x2x2x2"; stop_gate >/dev/null 2>&1
sub "C12.6 landed by the next session ($r4): its workspace is gone and new work may start ($r5)" "[ $r4 -eq 0 ] && [ ! -e '$NPW' ] && [ $r5 -eq 0 ]" "$(cat "$T/land.out" "$T/spawn.err")"
verdict

# ===========================================================================
begin C0 "ADDED: the sandbox ends clean — every ending in the store reads landed or discarded, no agent workspace or branch survives in any repository, the hooks reported nothing unexpected"
KINDS="$(python3 -c 'import json,os,sys; d=sys.argv[1]; print(sorted(set(json.load(open(os.path.join(d,f)))["disposition"]["kind"] for f in os.listdir(d))))' "$STORE/done")"
sub "C0.1 every record in done/ ends 'landed' or 'discarded' (kinds: $KINDS)" "[ \"$KINDS\" = \"['discarded', 'landed']\" ]"
LIVE="$(python3 -c 'import json,os,sys; d=sys.argv[1]; print(sorted(f for f in os.listdir(d) if any(not w.get("deleted_at") for w in json.load(open(os.path.join(d,f))).get("workspaces") or [])))' "$STORE/agents")"
sub "C0.2 no agent still holds a workspace in agents/ (live: $LIVE)" "[ \"$LIVE\" = '[]' ]"
sub "C0.3 the entity repository has only its main checkout" "[ \"\$(git -C '$ENT' worktree list --porcelain | grep -c '^worktree ')\" = 1 ]"
sub "C0.4 the other repository has only its main checkout and the untouched codex/ workspace" "[ \"\$(git -C '$OTHER' worktree list --porcelain | grep -c '^worktree ')\" = 2 ] && listed '$OTHER' '$CX'"
sub "C0.5 no agent branch survives anywhere (codex/ excepted)" \
    "[ -z \"\$(git -C '$ENT' for-each-ref refs/heads/worktree-agent-* refs/heads/cc; git -C '$OTHER' for-each-ref refs/heads/cc refs/heads/worktree-agent-*; git -C '$DEV' for-each-ref refs/heads/cc)\" ]" "$(git -C "$ENT" for-each-ref refs/heads/worktree-agent-* refs/heads/cc; git -C "$OTHER" for-each-ref refs/heads/cc)"
if [ -s "$T/hooks.err" ]; then
    sub "C0.6 the lifecycle hook reported nothing unexpected" "false" "$(head -5 "$T/hooks.err")"
else
    sub "C0.6 the lifecycle hook reported nothing unexpected" "true"
fi
verdict

# --- THE MUTATION HARNESS -------------------------------------------------
# A green check is evidence of nothing until it has been watched going red for
# its own reason; the harness removes one rule at a time in a throwaway copy of
# the engine and demands the named SUB-ASSERTION go red. Its verdict is printed
# here and never folded into the headline below: the headline counts the CEO's
# checks, and the harness counts the checks' own honesty.
MUT_RC=""
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$HERE/workspace-spec-fourteen.mutation.sh" ] && [ "${RICHOS_FOURTEEN_SKIP_MUTANTS:-0}" != 1 ]; then
    echo "=== running the mutation harness ==="
    bash "$HERE/workspace-spec-fourteen.mutation.sh"; MUT_RC=$?
    echo ""
fi

echo "CHECKS RUN: $CHECKS_RUN  RED: $CHECKS_RED"
[ -n "$MUT_RC" ] && echo "MUTATION HARNESS: exit $MUT_RC ($([ "$MUT_RC" -eq 0 ] && echo 'every property proven load-bearing' || echo 'a property is NOT proven — see above'))"
[ "$CHECKS_RED" -eq 0 ] && [ "${MUT_RC:-0}" -eq 0 ]
