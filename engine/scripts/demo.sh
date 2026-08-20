#!/usr/bin/env bash
#
# demo.sh — the 60-second proof-of-life. One command, unattended, that shows
# a CEO the kit's enforcement machinery actually working, before they trust it
# with a real repo.
#
# WHAT THIS IS: value-roadmap.md §B2 ("test-drive mode") plus the missing
# "one-command demo button" Frank's hostile-buyer review flagged as the
# single highest-leverage gap ("B2 is the content; this is the button").
# Frank's minimum proof-of-life spec (his review, "#1 build priority"):
# watch (a) the isolation guard block a bad spawn, (b) an engineer commit on
# a worktree branch, (c) a QA agent reject a planted defect, (d) the fix
# pass, (e) the lander merge to main. This script drives exactly that loop,
# unattended, against a throwaway sample repo — then tears the sample down.
#
# DESIGN DECISION — sample project is synthesized at runtime, not shipped:
# the "sample company repo" this script drives is built fresh in a temp dir
# on every run (git init, hooks copied in, a two-file toy product written out)
# rather than a persistent `demo/sample-project/` checked into the kit. This
# keeps the kit repo free of orphan demo data to maintain, guarantees the
# demo can never drift out of sync with the current hooks (it always copies
# THIS commit's hook files), and makes "re-runnable" and "kit repo untouched"
# trivially true by construction — there is nothing in the kit for the demo
# to touch in the first place.
#
# HONEST LABELING (Frank's truth-in-labeling lesson applies to the demo
# itself): every beat below is marked either
#   [REAL ENFORCEMENT]      — the actual hook binary / real git mechanics run,
#                             unmodified, and its real exit code decides
#                             pass/fail.
#   [NARRATED SIMULATION]   — there is no live LLM agent here (this script is
#                             plain bash), so the QA-verdict beat is narrated:
#                             the git/commit mechanics and the QA check script
#                             it runs are REAL and its exit code is real, but
#                             the "QA agent's judgment" is this demo's own
#                             scripted stand-in, not a spawned teammate. Said
#                             explicitly, every time, never presented as a
#                             live agent transcript.
#
# PREREQUISITES (same as the kit's own, nothing extra): bash, git, python3,
# standard coreutils. No Claude API key. No live agents. No network access.
# Deterministic and unattended — safe for a buyer to run sight-unseen.
#
# Usage:
#   scripts/demo.sh
#
# Exit codes:
#   0  every beat passed — the enforcement machinery works end-to-end
#   1  unexpected error (missing prerequisite, setup failure)
#   2  one or more beats failed — the demo doubles as an integrity check

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

command -v git >/dev/null 2>&1 || { echo "ERROR: demo.sh requires git — not found on PATH." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: demo.sh requires python3 — not found on PATH." >&2; exit 1; }

START_EPOCH="$(date +%s)"

C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'

BEATS_TOTAL=0
BEATS_PASSED=0
BEAT_NAMES_FAILED=()

heading() {
    printf '\n%s=== %s ===%s\n' "$C_BOLD" "$1" "$C_RESET"
}
narrate() {
    printf '%s\n' "$1"
}
label_real() {
    printf '  %s[REAL ENFORCEMENT]%s %s\n' "$C_BOLD" "$C_RESET" "$1"
}
label_sim() {
    printf '  %s[NARRATED SIMULATION]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
}
show_output() {
    # Indent a captured command's output for readability under a beat.
    printf '%s\n' "$1" | sed 's/^/    /'
}
beat_pass() {
    BEATS_TOTAL=$((BEATS_TOTAL + 1))
    BEATS_PASSED=$((BEATS_PASSED + 1))
    printf '  %s✓ Beat %s PASSED%s — %s\n' "$C_GREEN" "$1" "$C_RESET" "$2"
}
beat_fail() {
    BEATS_TOTAL=$((BEATS_TOTAL + 1))
    BEAT_NAMES_FAILED+=("Beat $1: $2")
    printf '  %s✗ Beat %s FAILED%s — %s\n' "$C_RED" "$1" "$C_RESET" "$2" >&2
}

# ---------------------------------------------------------------------------
# Sample repo setup — a throwaway "sample company" in a temp dir, wired with
# THIS commit's real hook files via the real install.sh (not a mock, not a
# copy-pasted re-implementation).
# ---------------------------------------------------------------------------
# pwd -P: canonicalize away macOS's /var -> /private/var (and /tmp) symlink so
# this variable and every hook's own `cd .. && pwd` / git-derived REPO_ROOT
# agree on the same real path from the start (same fix contract-integrity.
# test.sh's make_git_main already applies, for the identical reason).
#
# Portability note: an explicit "${TMPDIR:-/tmp}/template.XXXXXX" path (NOT
# `mktemp -t prefix`) is used deliberately — this is the ONE form that
# substitutes the trailing X's identically on both BSD/macOS mktemp and GNU/
# Linux mktemp. `-t prefix` behaves differently per platform: BSD/macOS
# treats the whole prefix as opaque and appends its OWN random suffix after
# it (harmless, but produces an ugly double-suffixed path this demo narrates
# straight to the CEO — e.g. "...demo.XXXXXX.k3ryLSxK9V"); GNU substitutes
# the X's directly. This form gives byte-for-byte identical, clean output on
# both platforms. (See docs/ci-portability-notes.md.)
SAMPLE_ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/orchestration-kit-demo.XXXXXX")" && pwd -P)"

cleanup() {
    rm -rf "$SAMPLE_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

heading "Setting up a throwaway sample company (temp dir, deleted on exit)"
narrate "Building a tiny sample repo at $SAMPLE_ROOT — this is NOT your repo and"
narrate "is deleted when this script exits. Wiring in the kit's real, unmodified"
narrate "enforcement hooks from this checkout — the same files that would protect"
narrate "your own repo."

mkdir -p "$SAMPLE_ROOT/scripts/hooks" "$SAMPLE_ROOT/scripts/lib" "$SAMPLE_ROOT/.claude/state" "$SAMPLE_ROOT/app"

for f in guard-worktree-isolation.sh guard-definition-drift.sh snapshot-agent-definitions.sh \
         reader-teammate-hint.sh verify-agent-prompt.sh \
         guard-main-checkout-writes.sh guard-bash-main-writes.sh scan-secrets.sh \
         guard-resume-isolation.sh detect-nonnative-worktree.sh teammate-idle-handoff.sh \
         task-completed-handoff.sh session-start-reap-worktrees.sh \
         install.sh contract-integrity-probe.sh; do
    cp "$REPO_ROOT/scripts/hooks/$f" "$SAMPLE_ROOT/scripts/hooks/$f"
done
chmod +x "$SAMPLE_ROOT/scripts/hooks/"*.sh
cp "$REPO_ROOT/scripts/lib/resolve-main-checkout.sh" "$SAMPLE_ROOT/scripts/lib/resolve-main-checkout.sh"
# The one managed script outside scripts/hooks/ — the half of the SessionStart
# worktree-reaper chain that actually removes worktrees. install.sh mints its
# sidecar and probe Layer Q hashes + exercises it, so the sample repo needs it.
cp "$REPO_ROOT/scripts/reap-stale-worktrees.sh" "$SAMPLE_ROOT/scripts/reap-stale-worktrees.sh"
chmod +x "$SAMPLE_ROOT/scripts/reap-stale-worktrees.sh"

cat >"$SAMPLE_ROOT/orchestration.config" <<'CFG'
# Sample orchestration.config for the demo — mirrors the shape of the real
# top-level file you fill in for your own repo.
PROTECTED_PATHS="app"
READONLY_ALLOWLIST="Explore Plan claude-code-guide statusline-setup"
READER_TEAMMATE="reed"
CREATOR_TEAMMATE="dean"
ARTIFACT_MERGE_DIRS="test-results output"
ARTIFACT_REPLACE_DIRS="playwright-report"
ENABLE_QA_INSTALL_FRESH_GATE=0
SECRET_SCAN_MIN_LENGTH=12
SECRET_SCAN_MIN_ENTROPY="3.0"
SECRET_SCAN_ALLOWLIST=""
CFG

python3 - "$SAMPLE_ROOT/.claude/settings.local.json" <<'PY'
import json, sys
out_path = sys.argv[1]
data = {
    "env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"},
    "worktree": {"baseRef": "head"},
    "hooks": {
        "SessionStart": [
            {"hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/session-start-reap-worktrees.sh", "timeout": 30}]},
            {"hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/snapshot-agent-definitions.sh", "timeout": 15}]}
        ],
        "PreToolUse": [
            {
                "matcher": "Agent",
                "hooks": [
                    {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/guard-worktree-isolation.sh", "timeout": 10},
                    {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/guard-definition-drift.sh", "timeout": 10},
                    {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/reader-teammate-hint.sh", "timeout": 10},
                    {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/verify-agent-prompt.sh", "timeout": 10},
                ],
            },
            {
                "matcher": "Write|Edit|MultiEdit|NotebookEdit",
                "hooks": [
                    {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/guard-main-checkout-writes.sh", "timeout": 10},
                    {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/scan-secrets.sh", "timeout": 10},
                ],
            },
            {
                "matcher": "SendMessage",
                "hooks": [
                    {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/guard-resume-isolation.sh", "timeout": 10},
                ],
            },
            {
                "matcher": "Bash",
                "hooks": [
                    {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/guard-bash-main-writes.sh", "timeout": 10},
                ],
            },
        ],
        "PostToolUse": [
            {
                "matcher": "Agent",
                "hooks": [
                    {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/detect-nonnative-worktree.sh", "timeout": 10},
                ],
            }
        ],
        "TeammateIdle": [
            {"hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/teammate-idle-handoff.sh", "timeout": 15}]}
        ],
        "TaskCompleted": [
            {"hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/task-completed-handoff.sh", "timeout": 15}]}
        ],
    },
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY

cat >"$SAMPLE_ROOT/.gitignore" <<'GI'
/.claude/settings.json
/.claude/worktrees/
scripts/hooks/*.sha256
scripts/*.sha256
GI

# The sample "product": a two-file toy — one source file, one QA check — just
# enough to carry a real, watchable defect -> reject -> fix -> pass story.
cat >"$SAMPLE_ROOT/app/greeting.py" <<'PY'
def greeting(name):
    return f"Hello, {name}!"
PY

cat >"$SAMPLE_ROOT/app/qa_check.py" <<'PY'
"""Sample QA check — the deterministic, scripted stand-in this demo narrates
as "the QA agent's verdict" (see demo.sh's NARRATED SIMULATION labeling).
Verifies greeting() produces the exact spec'd output."""
import sys
import importlib.util

app_dir = sys.argv[1] if len(sys.argv) > 1 else "."
spec = importlib.util.spec_from_file_location("greeting", f"{app_dir}/greeting.py")
greeting_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(greeting_mod)

expected = "Hello, World!"
actual = greeting_mod.greeting("World")
assert actual == expected, f"QA FAILED: expected {expected!r}, got {actual!r}"
print(f"QA PASSED: greeting('World') == {actual!r}")
PY

git -C "$SAMPLE_ROOT" init -q -b main
git -C "$SAMPLE_ROOT" config user.email "demo@example.com"
git -C "$SAMPLE_ROOT" config user.name "Sample Company"
git -C "$SAMPLE_ROOT" add -A
# Force-add the committed-by-design canonical settings file: a common GLOBAL
# gitignore convention (~/.config/git/ignore '**/.claude/settings.local.json')
# makes `git add -A` SILENTLY skip it, which would strand the next clone with no
# teammates — and now trips the probe's Layer N. `git add -f` is the remedy the
# probe points adopters at; the demo models it so beat 7's probe stays green on
# any machine (with or without that global rule).
git -C "$SAMPLE_ROOT" add -f .claude/settings.local.json
git -C "$SAMPLE_ROOT" commit -q -m "Initial sample product"

label_real "install.sh — generating .claude/settings.json + hook integrity sidecars"
INSTALL_OUT="$("$SAMPLE_ROOT/scripts/hooks/install.sh" 2>&1)"
show_output "$INSTALL_OUT"
narrate "Sample company ready."

# ---------------------------------------------------------------------------
# Beat 1 — a file-writing agent spawned WITHOUT isolation is BLOCKED.
# ---------------------------------------------------------------------------
heading "Beat 1 — spawning a file-writing teammate without isolation"
narrate 'Someone (or an over-eager orchestrator) tries to spawn an "engineer" to'
narrate 'fix a bug directly, forgetting isolation: "worktree". Watch what happens:'
label_real "guard-worktree-isolation.sh (the same hook that runs on every real Agent spawn)"

BAD_SPAWN_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"engineer","name":"engineer-sonnet-1","prompt":"Fix the greeting bug in app/greeting.py."},"session_id":"demo0000-0000-4000-8000-000000000000"}'
set +e
BEAT1_OUT="$(printf '%s' "$BAD_SPAWN_PAYLOAD" | "$SAMPLE_ROOT/scripts/hooks/guard-worktree-isolation.sh" 2>&1)"
BEAT1_RC=$?
set -e
show_output "$BEAT1_OUT"
if [ "$BEAT1_RC" -eq 2 ]; then
    beat_pass "1" "the guard refused the unsafe spawn — this is what protects your main branch from a stray agent editing it directly"
else
    beat_fail "1" "expected the guard to block (exit 2), got exit $BEAT1_RC"
fi

# ---------------------------------------------------------------------------
# Beat 2 — a write to a protected path from the main checkout is BLOCKED.
# ---------------------------------------------------------------------------
heading "Beat 2 — writing straight into a protected source tree"
narrate 'Now someone tries to edit app/greeting.py directly in the shared checkout'
narrate '(not inside an isolated worktree) — exactly the mistake that corrupts'
narrate 'other agents'"'"' work. Watch what happens:'
label_real "guard-main-checkout-writes.sh (the same hook that runs on every Write/Edit)"

BAD_WRITE_PAYLOAD="$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/app/greeting.py"}}' "$SAMPLE_ROOT")"
set +e
BEAT2_OUT="$(printf '%s' "$BAD_WRITE_PAYLOAD" | "$SAMPLE_ROOT/scripts/hooks/guard-main-checkout-writes.sh" 2>&1)"
BEAT2_RC=$?
set -e
show_output "$BEAT2_OUT"

# The Write/Edit guard never sees a RAW Bash command, so a compound
# `cd <main> && mkdir app/...` slips past it and would otherwise prompt the
# human operator interactively. The PreToolUse[Bash] guard closes that gap —
# demonstrate it on the same protected tree (folded into this beat, no separate
# beat count, mirroring how scan-secrets rides along under the Write matcher).
narrate ''
narrate 'And the raw-Bash variant of the same mistake — `cd <main> && mkdir app/new`'
narrate '— which the Write/Edit guard never sees, so it used to prompt YOU. The'
narrate 'Bash guard auto-denies it too:'
label_real "guard-bash-main-writes.sh (the same hook that runs on every Bash command)"
BAD_BASH_PAYLOAD="$(printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && mkdir app/new_dir"}}' "$SAMPLE_ROOT")"
set +e
BEAT2B_OUT="$(printf '%s' "$BAD_BASH_PAYLOAD" | "$SAMPLE_ROOT/scripts/hooks/guard-bash-main-writes.sh" 2>&1)"
BEAT2B_RC=$?
set -e
show_output "$BEAT2B_OUT"

if [ "$BEAT2_RC" -eq 2 ] && [ "$BEAT2B_RC" -eq 2 ]; then
    beat_pass "2" "both write-paths refused — the Write/Edit guard AND the raw-Bash guard block protected-source edits; source only changes via an isolated worktree + merge"
elif [ "$BEAT2_RC" -ne 2 ]; then
    beat_fail "2" "expected the write-guard to block (exit 2), got exit $BEAT2_RC"
else
    beat_fail "2" "expected the Bash-guard to block (exit 2), got exit $BEAT2B_RC"
fi

# ---------------------------------------------------------------------------
# Beat 3 — a COMPLIANT spawn (isolation: "worktree", well-formed name) passes
# the SAME chain that just blocked the bad one.
# ---------------------------------------------------------------------------
heading "Beat 3 — the same guard lets a correctly-isolated spawn through"
narrate 'This time the spawn does it right: isolation: "worktree", a proper'
narrate 'truthful "<role>-<model>-<identifier>" name. It should sail through the'
narrate 'full PreToolUse[Agent]'
narrate 'chain untouched:'
label_real "guard-worktree-isolation.sh -> guard-definition-drift.sh -> reader-teammate-hint.sh -> verify-agent-prompt.sh (the real chain, in the real order)"

GOOD_SPAWN_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"engineer","name":"engineer-sonnet-1","isolation":"worktree","prompt":"Fix the greeting bug in app/greeting.py."},"session_id":"demo0000-0000-4000-8000-000000000000"}'
BEAT3_OK=1
for hook in guard-worktree-isolation.sh guard-definition-drift.sh reader-teammate-hint.sh verify-agent-prompt.sh; do
    set +e
    HOOK_OUT="$(printf '%s' "$GOOD_SPAWN_PAYLOAD" | "$SAMPLE_ROOT/scripts/hooks/$hook" 2>&1)"
    HOOK_RC=$?
    set -e
    if [ "$HOOK_RC" -ne 0 ]; then
        BEAT3_OK=0
        printf '    %s✗ %s exited %s (expected 0)%s\n' "$C_RED" "$hook" "$HOOK_RC" "$C_RESET"
        show_output "$HOOK_OUT"
    else
        printf '    ✓ %s: exit 0 (allowed)\n' "$hook"
    fi
done
if [ "$BEAT3_OK" -eq 1 ]; then
    beat_pass "3" "the compliant spawn passed every gate — the guard blocks unsafe spawns, not spawning itself"
else
    beat_fail "3" "the compliant spawn was unexpectedly blocked somewhere in the chain"
fi

# ---------------------------------------------------------------------------
# Beat 4 — a real isolated worktree + a real commit (the engineer's handoff).
# ---------------------------------------------------------------------------
heading "Beat 4 — the engineer builds in an isolated worktree and commits"
narrate 'This is what isolation: "worktree" actually produces: a real, linked git'
narrate 'worktree on its own branch. The engineer'"'"'s commit on that branch IS the'
narrate 'handoff — no message required.'
label_real "git worktree add + git commit (real git mechanics, no mock)"

mkdir -p "$SAMPLE_ROOT/.claude/worktrees"
set +e
WT_ADD_OUT="$(git -C "$SAMPLE_ROOT" worktree add -q -b worktree-demo0001 "$SAMPLE_ROOT/.claude/worktrees/agent-demo0001" 2>&1)"
WT_ADD_RC=$?
set -e
WT="$SAMPLE_ROOT/.claude/worktrees/agent-demo0001"

# The engineer's change: a "flourish" that (accidentally) drops the comma —
# the planted defect this story's QA beat exists to catch.
cat >"$WT/app/greeting.py" <<'PY'
def greeting(name):
    return f"Hello {name}!"
PY
git -C "$WT" add app/greeting.py
git -C "$WT" commit -q -m "Add exclamation flourish to greeting"
COMMIT_SHA="$(git -C "$WT" rev-parse --short HEAD)"

if [ "$WT_ADD_RC" -eq 0 ] && git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    beat_pass "4" "worktree agent-demo0001 on branch worktree-demo0001, commit $COMMIT_SHA — the engineer's handoff, no message needed"
else
    beat_fail "4" "worktree/commit setup failed"
fi

# ---------------------------------------------------------------------------
# Beat 5 — the QA check rejects the planted defect (NARRATED SIMULATION).
# ---------------------------------------------------------------------------
heading "Beat 5 — QA reviews the engineer's commit and finds a defect"
label_sim "there is no live QA agent in this demo (this script is plain bash) — the git"
label_sim "history and the QA check's exit code below are REAL; the \"QA verdict\" is"
label_sim "this demo's own scripted stand-in for what a real QA teammate would do."
narrate "Running the QA check against the engineer's commit:"

set +e
BEAT5_OUT="$(python3 "$WT/app/qa_check.py" "$WT/app" 2>&1)"
BEAT5_RC=$?
set -e
show_output "$BEAT5_OUT"
if [ "$BEAT5_RC" -ne 0 ]; then
    beat_pass "5" "QA rejected the defect — the gate has real teeth, it does not rubber-stamp a broken commit"
else
    beat_fail "5" "QA check should have caught the defect but passed"
fi

# ---------------------------------------------------------------------------
# Beat 6 — the fix lands and QA re-passes (FIX-FIRST loop closes).
# ---------------------------------------------------------------------------
heading "Beat 6 — the engineer fixes it, QA re-checks and passes"
label_sim "same caveat as Beat 5 — the fix commit and the re-run QA check are REAL;"
label_sim "the pass/fail verdict narration stands in for a real QA teammate's signoff."

cat >"$WT/app/greeting.py" <<'PY'
def greeting(name):
    return f"Hello, {name}!"
PY
git -C "$WT" add app/greeting.py
git -C "$WT" commit -q -m "Fix greeting regression: restore the comma"
FIX_SHA="$(git -C "$WT" rev-parse --short HEAD)"

set +e
BEAT6_OUT="$(python3 "$WT/app/qa_check.py" "$WT/app" 2>&1)"
BEAT6_RC=$?
set -e
show_output "$BEAT6_OUT"
if [ "$BEAT6_RC" -eq 0 ]; then
    beat_pass "6" "fix $FIX_SHA passes QA — the FIX-FIRST loop closes, only a verified fix proceeds"
else
    beat_fail "6" "QA check should pass after the fix but failed"
fi

# ---------------------------------------------------------------------------
# Beat 7 — the single-writer land: merge to main, then the integrity probe
# runs green.
# ---------------------------------------------------------------------------
heading "Beat 7 — landing: merge to main, then the enforcement machinery re-verifies itself"
label_real "git merge (the land sequence's core mechanic) + contract-integrity-probe.sh"

set +e
MERGE_OUT="$(git -C "$SAMPLE_ROOT" merge --no-ff -q -m "Merge worktree-demo0001: fix greeting regression" worktree-demo0001 2>&1)"
MERGE_RC=$?
set -e
show_output "$MERGE_OUT"
git -C "$SAMPLE_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"

MERGED_CONTENT="$(cat "$SAMPLE_ROOT/app/greeting.py" 2>/dev/null || true)"
if [ "$MERGE_RC" -eq 0 ] && printf '%s' "$MERGED_CONTENT" | grep -q "Hello, {name}"; then
    printf '    ✓ main now has the fixed greeting.py\n'
    MERGE_OK=1
else
    printf '    %s✗ merge did not land the expected fix%s\n' "$C_RED" "$C_RESET"
    MERGE_OK=0
fi

set +e
PROBE_OUT="$("$SAMPLE_ROOT/scripts/hooks/contract-integrity-probe.sh" 2>&1)"
PROBE_RC=$?
set -e
show_output "$PROBE_OUT"

if [ "$MERGE_OK" -eq 1 ] && [ "$PROBE_RC" -eq 0 ]; then
    beat_pass "7" "merged to main cleanly, and the integrity probe confirms every layer is still wired correctly after the change"
else
    beat_fail "7" "merge and/or post-merge integrity probe failed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
END_EPOCH="$(date +%s)"
ELAPSED=$((END_EPOCH - START_EPOCH))

heading "Summary"
if [ "$BEATS_PASSED" -eq "$BEATS_TOTAL" ]; then
    printf '%s✓ Your team'"'"'s enforcement machinery works. %s/%s beats passed.%s (in %ss)\n' \
        "$C_GREEN" "$BEATS_PASSED" "$BEATS_TOTAL" "$C_RESET" "$ELAPSED"
    narrate ""
    narrate "What you just watched, real vs. simulated:"
    narrate "  [REAL ENFORCEMENT]      Beats 1, 2, 3, 4, 7 — actual hook binaries and real git"
    narrate "                          mechanics, unmodified from this checkout."
    narrate "  [NARRATED SIMULATION]   Beats 5, 6 — the QA check's git/exit-code mechanics are"
    narrate "                          real; the \"QA agent\" judgment is this script's scripted"
    narrate "                          stand-in, not a spawned teammate."
    exit 0
else
    printf '%s✗ %s/%s beats passed — the enforcement machinery has a problem.%s (in %ss)\n' \
        "$C_RED" "$BEATS_PASSED" "$BEATS_TOTAL" "$C_RESET" "$ELAPSED"
    narrate "Failing beats:"
    for n in "${BEAT_NAMES_FAILED[@]}"; do narrate "  - $n"; done
    exit 2
fi
