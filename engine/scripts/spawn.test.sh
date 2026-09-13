#!/usr/bin/env bash
#
# spawn.test.sh — behavioral tests for scripts/spawn.sh, the one command that
# starts one teammate (docs/plans/worktree-spec-2026-09-11.md; the reason it
# exists is in scripts/lib/spawn.py's header).
#
# WHAT IS PINNED, AND WHY. HOME, CLAUDE_CONFIG_DIR, the workspace registry and
# the session identity all live in the sandbox, and the session is a process of
# this suite's own, so no case can touch the operator's record. The hook
# surfaces are pinned too (RICHOS_SPAWN_HOOK_SOURCES): the point of these cases
# is what spawn.sh does with a verdict, not which verdicts the machine's live
# CEO-todo state happens to produce today. The REAL guard-worktree-isolation.sh
# is in the pinned set, because clauses 4c and 7 are half of what is under test.
#
# One case is deliberately NOT hermetic (REAL-SURFACES): it asserts that the
# collector finds a guard from the engine's matcherless group AND one from a
# governed repository's settings.local.json. Reading only the engine's Agent
# group is the exact hole that cost two refusals on 2026-09-13, and a hermetic
# fixture cannot prove it is closed on this machine.
#
# Run directly: scripts/spawn.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$SCRIPT_DIR/spawn.sh"
WS_PY="$SCRIPT_DIR/lib/workspaces.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t spawn-test.XXXXXX)" && pwd -P)"
SESS_PID="$(sh -c 'sleep 3600 >/dev/null 2>&1 & echo $!')"
# RICHOS_SPAWN_TEST_KEEP=1 leaves the sandbox on disk for a post-mortem.
if [ -n "${RICHOS_SPAWN_TEST_KEEP:-}" ]; then
    trap 'kill "$SESS_PID" 2>/dev/null; echo "  sandbox kept: $SANDBOX"' EXIT
else
    trap 'kill "$SESS_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
fi
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); shift; [ "$#" -gt 0 ] && printf '        %s\n' "$*"; }

[ -x "$SPAWN" ] || { echo "FATAL: $SPAWN missing or not executable" >&2; exit 1; }

export HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$SANDBOX/home/.claude"
export RICHOS_WORKSPACES_DIR="$SANDBOX/workspaces"
export RICHOS_SESSION_PID="$SESS_PID" RICHOS_SESSION_ID="feedface-0000-4000-8000-0000000000a1"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$CLAUDE_CONFIG_DIR"

mkrepo() {   # <path> [branch-to-end-on]
    local r="$1"
    mkdir -p "$r"
    git -C "$r" init -q -b main
    printf 'seed\n' >"$r/seed.txt"
    git -C "$r" add -A
    git -C "$r" commit -q -m seed
    [ "$#" -ge 2 ] && git -C "$r" checkout -q -b "$2"
    return 0
}

# The session's own repository. It carries the agent definition the model
# resolver reads and the settings.local.json that stands in for femcboost's.
PROJECT="$SANDBOX/session-repo"
mkrepo "$PROJECT"
mkdir -p "$PROJECT/.claude/agents"
cat >"$PROJECT/.claude/agents/zach.md" <<'DEF'
---
name: zach
description: infrastructure
model: sonnet
tools: Read, Write, Edit, Bash
---
Infrastructure engineer.
DEF
# THE SANDBOX REPOSITORY MUST ACTUALLY ADOPT THE ENGINE. resolve-roots.sh
# answers `not-adopted` for a repository with no orchestration.config at its
# root, and every guard then STANDS DOWN and exits 0 — correctly, because
# nothing has asked it to enforce anything there. Without this line the suite
# would run every case against guards that were all silently switched off, and
# would have reported them passing. (It did, on 2026-09-13, and the case that
# caught it was the one that checked what a FAILURE leaves behind.)
cp "$SCRIPT_DIR/../orchestration.config" "$PROJECT/orchestration.config"
git -C "$PROJECT" add orchestration.config
git -C "$PROJECT" commit -q -m "adopt the engine"
TARGET="$SANDBOX/widgets"
mkrepo "$TARGET"
python3 "$WS_PY" integration --repo "$PROJECT" --branch main --why "the session repo" >/dev/null

# --- the pinned hook surfaces ---------------------------------------------
# An engine file with a MATCHERLESS group (every tool) and an Agent group, and a
# repository-local file with one more Agent guard: the two surfaces, in the two
# shapes that matter.
GUARDS="$SANDBOX/guards"
mkdir -p "$GUARDS"
cat >"$GUARDS/always-ok.sh" <<'G'
#!/usr/bin/env bash
cat >/dev/null
exit 0
G
cat >"$GUARDS/refuse-a.sh" <<'G'
#!/usr/bin/env bash
payload="$(cat)"
if [ -n "${REFUSE_A:-}" ]; then echo "GUARD A REFUSES: reason alpha" >&2; exit 2; fi
exit 0
G
cat >"$GUARDS/refuse-b.sh" <<'G'
#!/usr/bin/env bash
payload="$(cat)"
if [ -n "${REFUSE_B:-}" ]; then echo "GUARD B REFUSES: reason beta" >&2; exit 2; fi
exit 0
G
# Fault injection for the rollback case: passes while the workspace is still
# only PLANNED, refuses once it exists. Nothing natural does that; the rollback
# path has to be reachable to be tested.
cat >"$GUARDS/refuse-after-create.sh" <<'G'
#!/usr/bin/env bash
payload="$(cat)"
[ -n "${REFUSE_AFTER:-}" ] || exit 0
if printf '%s' "$payload" | grep -q '"planned": \[\]'; then
  echo "GUARD REFUSES AFTER CREATION: injected fault" >&2
  exit 2
fi
exit 0
G
chmod +x "$GUARDS"/*.sh
cat >"$GUARDS/engine-hooks.json" <<J
{"hooks": {"PreToolUse": [
  {"hooks": [{"type": "command", "command": "bash $GUARDS/always-ok.sh"}]},
  {"matcher": "Agent", "hooks": [
    {"type": "command", "command": "bash $SCRIPT_DIR/hooks/guard-worktree-isolation.sh"},
    {"type": "command", "command": "bash $GUARDS/refuse-a.sh"},
    {"type": "command", "command": "bash $GUARDS/refuse-after-create.sh"}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash $GUARDS/never-runs.sh"}]}
]}}
J
mkdir -p "$PROJECT/.claude"
cat >"$PROJECT/.claude/settings.local.json" <<J
{"hooks": {"PreToolUse": [
  {"matcher": "Agent", "hooks": [{"type": "command", "command": "bash $GUARDS/refuse-b.sh"}]}
]}}
J
export RICHOS_SPAWN_HOOK_SOURCES="engine=$GUARDS/engine-hooks.json:local=$PROJECT/.claude/settings.local.json"

BRIEF="$SANDBOX/brief.md"
cat >"$BRIEF" <<'B'
ceo-todos-deferred: the suite's own fixture; no CEO item is being skipped by a test.

Fix the widget health check. Scope: health.js only.
Verify with `scripts/hooks/contract-integrity.test.sh --only base`.
B

run() {   # <spawn args...> -> stdout+stderr in OUT, status in RC
    OUT="$("$SPAWN" "$@" --project-dir "$PROJECT" 2>&1)"
    RC=$?
    return 0
}

echo "spawn.sh"

# ---------------------------------------------------------------------------
echo "  repository resolution"
# ---------------------------------------------------------------------------
run "zach-sonnet-r1" --repo widgets --type zach --brief "$BRIEF" --dry-run
case "$OUT" in
    *"$TARGET"*) ok "a bare repository name resolves (the old helper answered \"'richos' is not a directory\")" ;;
    *) bad "a bare repository name resolves" "$OUT" ;;
esac

run "zach-sonnet-r2" --repo nosuchrepo --type zach --brief "$BRIEF" --dry-run
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "no repository of that name is known here" \
   && printf '%s' "$OUT" | grep -q "widgets"; then
    ok "an unknown bare name is refused WITH the candidates"
else
    bad "an unknown bare name is refused with the candidates" "rc=$RC $OUT"
fi

mkrepo "$SANDBOX/other/widgets"
python3 "$WS_PY" integration --repo "$SANDBOX/other/widgets" --branch main --why "the twin" >/dev/null
run "zach-sonnet-r3" --repo widgets --type zach --brief "$BRIEF" --dry-run
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "is ambiguous"; then
    ok "an ambiguous bare name is refused and both candidates are named"
else
    bad "an ambiguous bare name is refused" "rc=$RC $OUT"
fi
rm -rf "$SANDBOX/other"

run "zach-sonnet-r4" --repo "$TARGET" --type zach --brief "$BRIEF" --dry-run
[ "$RC" -eq 0 ] && ok "an absolute path resolves" || bad "an absolute path resolves" "rc=$RC $OUT"

# ---------------------------------------------------------------------------
echo "  the branch this work integrates on (point 14)"
# ---------------------------------------------------------------------------
# A repository nothing has recorded yet. (By now $TARGET HAS a record, written
# by the first case above — which is itself the behavior under test, so it needs
# a repository that has not been through it.)
FRESH="$SANDBOX/sprockets"
mkrepo "$FRESH"
run "zach-sonnet-r4b" --repo "$FRESH" --type zach --brief "$BRIEF" --dry-run
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "RECORDED main for $FRESH"; then
    ok "an ABSENT record is RECORDED, not refused with a second command to run"
else
    bad "an absent record is recorded" "rc=$RC $OUT"
fi
if printf '%s' "$OUT" | grep -q "If this work must not reach main yet"; then
    ok "and the recording SAYS SO, with the one line that would change it"
else
    bad "the recording is announced" "$OUT"
fi
WORK_ID="$(python3 "$WS_PY" integration --repo "$TARGET" | awk '{print $5}')"
[ -n "$WORK_ID" ] && ok "the recording names a body of work ($WORK_ID)" \
                  || bad "the recording names a body of work" "none"

# STALE: the recorded branch is deleted under it, as dev/workspace-spec was.
git -C "$TARGET" branch -f dev/old main
python3 "$WS_PY" integration --repo "$TARGET" --branch dev/old --correct --why "kept off main" >/dev/null
git -C "$TARGET" branch -D dev/old >/dev/null 2>&1
if python3 "$WS_PY" integration-branch --repo "$TARGET" >/dev/null 2>&1; then
    bad "NEGATIVE CONTROL: a stale record should abstain before the repair" ""
else
    ok "NEGATIVE CONTROL: with the stale record every consumer abstains"
fi
run "zach-sonnet-r5" --repo "$TARGET" --type zach --brief "$BRIEF" --dry-run
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "CORRECTED $TARGET from dev/old (no such branch) to main"; then
    ok "a STALE record is CORRECTED in place"
else
    bad "a stale record is corrected" "rc=$RC $OUT"
fi
AFTER_ID="$(python3 "$WS_PY" integration --repo "$TARGET" | awk '{print $5}')"
[ "$AFTER_ID" = "$WORK_ID" ] \
    && ok "the correction KEEPS the body of work's id ($AFTER_ID), so agents bound to it move with it" \
    || bad "the correction keeps the work id" "was $WORK_ID now $AFTER_ID"

# THE HUMAN DECISION: no record, and the checkout is not on the default branch.
DEV="$SANDBOX/gadgets"
mkrepo "$DEV" dev/rework
run "zach-sonnet-r6" --repo "$DEV" --type zach --brief "$BRIEF" --dry-run
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "DECISION:" \
   && printf '%s' "$OUT" | grep -q "not on its default branch"; then
    ok "where the answer is a human's, it says WHICH decision and stops (it never guesses one)"
else
    bad "the human decision is named" "rc=$RC $OUT"
fi
run "zach-sonnet-r7" --repo "$DEV" --type zach --brief "$BRIEF" \
    --integration dev/rework --integration-why "the gadget rework" --dry-run
[ "$RC" -eq 0 ] && ok "--integration answers it and the run proceeds" \
                || bad "--integration answers it" "rc=$RC $OUT"

# ---------------------------------------------------------------------------
echo "  every guard, from every surface, all failures together"
# ---------------------------------------------------------------------------
run "zach-sonnet-g1" --repo "$TARGET" --type zach --brief "$BRIEF" --dry-run
if printf '%s' "$OUT" | grep -q "always-ok.sh"; then
    ok "a MATCHERLESS PreToolUse group is collected (it matches every tool, Agent included)"
else
    bad "a matcherless group is collected" "$OUT"
fi
if printf '%s' "$OUT" | grep -q "refuse-b.sh"; then
    ok "the repository's OWN settings.local.json is collected (femcboost's surface)"
else
    bad "the repository's settings.local.json is collected" "$OUT"
fi
if printf '%s' "$OUT" | grep -q "never-runs.sh"; then
    bad "a Bash-matched group must NOT be collected for an Agent call" "$OUT"
else
    ok "a group matched to another tool is NOT collected"
fi

REFUSE_A=1 REFUSE_B=1 run "zach-sonnet-g2" --repo "$TARGET" --type zach --brief "$BRIEF" --dry-run
if [ "$RC" -eq 1 ] \
   && printf '%s' "$OUT" | grep -q "reason alpha" && printf '%s' "$OUT" | grep -q "reason beta"; then
    ok "TWO guards refusing are BOTH named in ONE run (never one refusal per attempt)"
else
    bad "both refusals are reported together" "rc=$RC $OUT"
fi

# ---------------------------------------------------------------------------
echo "  create, and leave nothing behind on failure"
# ---------------------------------------------------------------------------
REFUSE_A=1 run "zach-sonnet-c1" --repo "$TARGET" --type zach --brief "$BRIEF"
WT="$SANDBOX/widgets-wt/zach-sonnet-c1"
if [ "$RC" -eq 1 ] && [ ! -e "$WT" ] && [ ! -e "$RICHOS_WORKSPACES_DIR/agents/$RICHOS_SESSION_ID--zach-sonnet-c1.json" ] \
   && ! git -C "$TARGET" rev-parse --verify --quiet refs/heads/cc/zach-sonnet-c1 >/dev/null; then
    ok "a refusal BEFORE creation leaves no workspace, no branch and no registration"
else
    bad "a pre-create refusal leaves nothing" "rc=$RC wt=$( [ -e "$WT" ] && echo present || echo absent)"
fi

run "zach-sonnet-c2" --repo "$TARGET" --type zach --brief "$BRIEF"
WT2="$SANDBOX/widgets-wt/zach-sonnet-c2"
if [ "$RC" -eq 0 ] && [ -d "$WT2" ]; then
    ok "a clean run creates the workspace and exits 0"
else
    bad "a clean run creates the workspace" "rc=$RC $OUT"
fi
N="$(git -C "$TARGET" worktree list --porcelain | grep -c "^worktree $WT2\$")"
[ "$N" = "1" ] && ok "the workspace exists EXACTLY once" || bad "the workspace exists exactly once" "found $N"
if printf '%s' "$OUT" | grep -q '"isolation": "worktree"' \
   && printf '%s' "$OUT" | grep -q "cross-repo-worktree: $WT2" \
   && printf '%s' "$OUT" | grep -q "inflight-ack.sh"; then
    ok "the printed payload carries isolation, the registered workspace and the ack contract"
else
    bad "the printed payload is complete" "$OUT"
fi

run "zach-sonnet-c2" --repo "$TARGET" --type zach --brief "$BRIEF"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qi "already"; then
    ok "a REUSED name is refused before anything is created"
else
    bad "a reused name is refused" "rc=$RC $OUT"
fi
[ -d "$WT2" ] && ok "and the refusal did not touch the workspace that already owned the name" \
              || bad "the refused reuse left the existing workspace alone" "$OUT"

REFUSE_AFTER=1 run "zach-sonnet-c3" --repo "$TARGET" --type zach --brief "$BRIEF"
WT3="$SANDBOX/widgets-wt/zach-sonnet-c3"
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep -q "rolled back"; then
    ok "FAULT INJECTION: a refusal AFTER creation rolls the workspace back and says so"
else
    bad "a post-create refusal rolls back" "rc=$RC $OUT"
fi
if [ ! -e "$WT3" ] && ! git -C "$TARGET" rev-parse --verify --quiet refs/heads/cc/zach-sonnet-c3 >/dev/null \
   && [ ! -e "$RICHOS_WORKSPACES_DIR/agents/$RICHOS_SESSION_ID--zach-sonnet-c3.json" ]; then
    ok "the rollback leaves no workspace, no branch and no registration"
else
    bad "the rollback leaves nothing" "wt=$( [ -e "$WT3" ] && echo present || echo absent)"
fi
run "zach-sonnet-c3" --repo "$TARGET" --type zach --brief "$BRIEF" --dry-run
[ "$RC" -eq 0 ] && ok "and the name is FREE again, so the retry is the same command" \
                || bad "the name is free after a rollback" "rc=$RC $OUT"

# ---------------------------------------------------------------------------
echo "  the dry evaluation is the same code with the write removed"
# ---------------------------------------------------------------------------
ENV_JSON="$SANDBOX/env.json"
python3 - "$ENV_JSON" "$RICHOS_SESSION_ID" "$SANDBOX/widgets-wt/zach-sonnet-d1" "$TARGET" "$PROJECT" <<'PY'
import json, sys
out, sid, path, repo, cwd = sys.argv[1:6]
json.dump({"session_id": sid, "cwd": cwd, "hook_event_name": "PreToolUse", "tool_name": "Agent",
           "tool_input": {"name": "zach-sonnet-d1", "subagent_type": "zach", "isolation": "worktree",
                          "prompt": "cross-repo-worktree: %s\n\ndo the thing" % path},
           "richos_spawn_check": {"planned": [{"path": path, "repo": repo,
                                               "branch": "cc/zach-sonnet-d1"}]}},
          open(out, "w"))
PY
if python3 "$WS_PY" check-spawn <"$ENV_JSON" >/dev/null 2>&1; then
    ok "check-spawn evaluates a payload the platform has not minted a tool_use_id for"
else
    bad "check-spawn evaluates an unsent payload" "$(python3 "$WS_PY" check-spawn <"$ENV_JSON" 2>&1)"
fi
if python3 "$WS_PY" register-spawn <"$ENV_JSON" >/dev/null 2>&1; then
    bad "NEGATIVE CONTROL: register-spawn must still refuse the same payload" ""
else
    ok "NEGATIVE CONTROL: register-spawn still refuses it — that was the pre-flight's false positive"
fi
if [ -e "$RICHOS_WORKSPACES_DIR/agents/$RICHOS_SESSION_ID--zach-sonnet-d1.json" ]; then
    bad "check-spawn wrote a registration" "it must write nothing"
else
    ok "check-spawn wrote NOTHING: no record, no binding, no event"
fi
python3 - "$ENV_JSON" "$SANDBOX/live.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["tool_use_id"] = "toolu_live_0001"
json.dump(d, open(sys.argv[2], "w"))
PY
if python3 "$WS_PY" check-spawn <"$SANDBOX/live.json" >/dev/null 2>&1; then
    bad "check-spawn accepted a payload carrying a tool_use_id" "a live call must go to register-spawn"
else
    ok "a payload WITH a tool_use_id is refused by check-spawn: the marker cannot dry-run a live call"
fi

# ---------------------------------------------------------------------------
echo "  REAL SURFACES (not hermetic, on purpose)"
# ---------------------------------------------------------------------------
REAL_PROJECT="${RICHOS_SPAWN_TEST_REAL_PROJECT:-/Users/alex/ab/femcboost}"
if [ -f "$REAL_PROJECT/.claude/settings.local.json" ] && [ -f "$SCRIPT_DIR/../hooks/hooks.json" ]; then
    FOUND="$(env -u RICHOS_SPAWN_HOOK_SOURCES python3 - "$SCRIPT_DIR/lib/spawn.py" "$REAL_PROJECT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("spawnlib", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for label, _src, cmd in m.collect_guards(sys.argv[2]):
    print("%s\t%s" % (label, m.guard_name(cmd)))
PY
)"
    if printf '%s' "$FOUND" | grep -q '^engine.*guard-sealed-worktree.sh$'; then
        ok "the engine's MATCHERLESS guard is collected from the real hooks.json"
    else
        bad "the engine's matcherless guard is collected" "$FOUND"
    fi
    if printf '%s' "$FOUND" | grep -q '^local'; then
        ok "a guard registered only in the repository's settings.local.json is collected (the hole that cost two refusals)"
    else
        bad "the repository's own guard is collected" "$FOUND"
    fi
else
    bad "REAL-SURFACES could not run" "no $REAL_PROJECT/.claude/settings.local.json on this machine"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
