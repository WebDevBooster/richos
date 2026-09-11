#!/usr/bin/env bash
#
# session-start-stdin.test.sh — NO SessionStart HOOK MAY BLOCK ON STDIN.
#
# Until round 14 (2026-09-11) this was section 9 of root-contract.test.sh,
# moved out whole and unchanged for one reason: TIME, and what time did to a
# reviewer. Each hook here is run twice (a control arm with stdin closed, a
# test arm with stdin open and never closed), the reaper's control arm alone
# is ~14 s on this machine, and root-contract.mutation.sh replays the whole
# inner suite for every root-contract mutant — seven times. So the parent
# file took 713 s on a shared machine (Sage, round three), past the 600 s
# ceiling of a single harness call; the harness moved the call to the
# background, and the background job's exit resumed an agent after its
# terminal record (the fourteenth restart, first on Claude Code 2.1.268).
# Recorded in docs/verification/reclaim-round-14-zach-fable-fix3-2026-09-10.md.
#
# The cases are 9a-9k: every SessionStart script registered in hooks.json, in
# the form it actually fires in, plus the two NEGATIVE controls (9d, 9i) that
# stop "does not hang" from being satisfied by never reading the payload at
# all, and 9j, which derives the covered set from the registration surface
# rather than a typed list. 9k is new: session-start-ci-surface.sh was
# registered on 2026-09-10 and hang-checked by nobody, which 9j caught in CI.
#
# ITS MUTANT IS NOT HERE. M10 (the snapshotter's unconditional stdin read, the
# 92 s hang) is declared in root-contract.mutation.sh and runs from
# root-contract.test.sh's end against THIS file, so the property stays proven
# without this suite chaining a harness of its own. Run root-contract.test.sh
# to see it.
#
# Same sandbox topology as root-contract.test.sh (a real engine copied
# wholesale, a session repository that adopted it, a plain one that did not):
# a stubbed engine could pass while the shipped one hangs.
#
# Run directly: scripts/hooks/session-start-stdin.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t root-contract.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# The launching session's own project dir must not leak in as a candidate.
unset CLAUDE_PROJECT_DIR RICHOS_ENTITY_ROOT RICHOS_ENGINE_ROOT CLAUDE_PLUGIN_ROOT

# ===========================================================================
# THE OPERATOR'S RECORD IS OUT OF REACH, AND BOTH ARMS SAY SO (round 15,
# 2026-09-11 — Frank D2, Sage D-A). Case 9b runs the SHIPPED SessionStart
# reaper, and until this block it ran it with the operator's real HOME: the
# reaper read ~/.claude/teams/*/inflight-repos.txt, discovered the operator's
# real richos registry, judged a REAL agent's cross-repository tree with this
# suite's sandbox entity — in which no shell can exist — and, through round
# 14's step 2b, appended a `terminated` row to ~/.claude/state/worktree-
# ledger.jsonl at 2026-09-11T00:02:34.984941+00:00 for sage-fable-cert3, whose
# shell was LOCKED by a running pid. All 11 cases passed. Both round-four
# reviewers found the row; Frank reproduced the write twice against a copy.
#
# So: the real record's witness is taken FIRST (the library captures the real
# paths at source time), then HOME moves into the sandbox, and every path the
# reaper or the hooks resolve under HOME is named explicitly as well — belt
# and braces, because one of them being missed is the whole class. Case 9l
# proves the redirect is honored (the reaper names the SANDBOX paths in its
# own output); case 9m proves the real record did not move. The runner's
# record canary (scripts/lib/record-canary.sh) is the backstop for every
# suite; this is the suite that earned it.
# ===========================================================================
# shellcheck source=../lib/record-canary.sh
. "$SRC_ENGINE/scripts/lib/record-canary.sh"
rc_baseline "$SANDBOX/real-record-baseline.txt"
REAL_HOME="$HOME"
export HOME="$SANDBOX/home"
mkdir -p "$HOME/.claude/state" "$HOME/.claude/teams" "$HOME/.claude/projects" "$HOME/.claude/sessions"
# Fixture commits need an identity, and a machine-wide identity guard (if the
# operator has one in the global hooks path) requires the operator's own: the
# global config is copied in when there is one, and a fixture identity is set
# through the environment when there is not (CI).
if [ -f "$REAL_HOME/.gitconfig" ]; then
    cp "$REAL_HOME/.gitconfig" "$HOME/.gitconfig"
else
    export GIT_AUTHOR_NAME="fixture" GIT_AUTHOR_EMAIL="fixture@example.invalid" \
           GIT_COMMITTER_NAME="fixture" GIT_COMMITTER_EMAIL="fixture@example.invalid"
fi
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export REAP_WORKTREE_LEDGER="$HOME/.claude/state/worktree-ledger.jsonl"
export RICHOS_WORKTREE_LEDGER="$REAP_WORKTREE_LEDGER"
export REAP_TEAM_DIR="$HOME/.claude/teams" RICHOS_TEAMS_DIR="$HOME/.claude/teams" \
       WORKER_EVENTS_TEAMS_DIR="$HOME/.claude/teams" RICHOS_LIVENESS_TEAMS_DIR="$HOME/.claude/teams"
export REAP_LEDGER="$HOME/.claude/state/reap-known-repos.txt"
export REAP_PROJECTS_DIR="$HOME/.claude/projects" RICHOS_PROJECTS_DIR="$HOME/.claude/projects"
export RICHOS_SESSIONS_DIR="$HOME/.claude/sessions"
export RICHOS_WORKTREE_TX_DIR="$HOME/.claude/state/worktree-transactions"
export RICHOS_WORKTREE_CAPTURE_DIR="$HOME/.claude/state/worktree-captures"

# --- build the topology ----------------------------------------------------
mk_repo() {
    local r="$SANDBOX/$1"
    mkdir -p "$r"
    git -C "$r" init -q -b main
    printf 'seed\n' >"$r/seed.txt"
    git -C "$r" add -A && git -C "$r" commit -q -m seed
    printf '%s\n' "$r"
}

HOSTREPO="$(mk_repo hostrepo)"
ENGINE="$HOSTREPO/engine"
mkdir -p "$ENGINE"
# A real engine, copied wholesale — no stubs. A stubbed engine could pass these
# tests while the shipped one fails, which is the same wrong-reason pass this
# suite exists to prevent.
cp -R "$SRC_ENGINE/scripts" "$ENGINE/scripts"
cp -R "$SRC_ENGINE/.claude" "$ENGINE/.claude"
cp -R "$SRC_ENGINE/.claude-plugin" "$ENGINE/.claude-plugin"
cp "$SRC_ENGINE/orchestration.config" "$ENGINE/orchestration.config"
cp "$SRC_ENGINE/VERSION" "$ENGINE/VERSION" 2>/dev/null || echo "0.0.0-test" >"$ENGINE/VERSION"
# The engine's own config protects "app packages" — deliberately DIFFERENT from
# the session repo's "src", so a hook that loaded the wrong config guards the
# wrong directory names and the tests can tell which one it read.
git -C "$HOSTREPO" add -A >/dev/null 2>&1
git -C "$HOSTREPO" commit -q -m engine >/dev/null 2>&1

SESSREPO="$(mk_repo sessionrepo)"
printf 'PROTECTED_PATHS="src"\nREADONLY_ALLOWLIST="Explore Plan"\nALLOWED_MODELS="opus sonnet haiku"\n' >"$SESSREPO/orchestration.config"
mkdir -p "$SESSREPO/.claude/agents" "$SESSREPO/src" "$SESSREPO/app"
printf -- '---\nname: mark\nmodel: opus\n---\nbody\n' >"$SESSREPO/.claude/agents/mark.md"
git -C "$SESSREPO" add -A && git -C "$SESSREPO" commit -q -m adopt

PLAINREPO="$(mk_repo plainrepo)"
mkdir -p "$PLAINREPO/src"

HOOKS="$ENGINE/scripts/hooks"

# run <hook> <payload> [env...] -> sets RC, OUT (stdout+stderr merged)
run() {
    local hook="$1" payload="$2"; shift 2
    # cd into the marker-free, non-git sandbox first. $PWD is the resolver's
    # last-resort candidate and this suite is normally run FROM the engine
    # directory, which is itself adopted — left alone, every "unadopted repo"
    # case below would resolve the engine through $PWD and report enforcement
    # ON, i.e. pass while asserting the opposite of what it claims.
    OUT="$(cd "$SANDBOX" && printf '%s' "$payload" | env "$@" bash "$HOOKS/$hook" 2>&1)"
    RC=$?
}

echo "=== SessionStart hooks against an open, never-closed stdin ==="
echo ""

# ===========================================================================
# 9. NO SessionStart HOOK MAY BLOCK ON STDIN.
#
# These hooks are SessionStart handlers AND plain CLI tools. In the CLI case
# stdin is an inherited pipe nobody closes, and an unconditional `cat` waits
# forever — `[ ! -t 0 ]` does not save you, because an inherited pipe is not a
# TTY. This is not hypothetical: wiring the root contract, I gave all three an
# unconditional payload read, and the contract-integrity probe sat on the
# snapshotter for 92 seconds before I killed it. It would have hung a real
# session start.
#
# WHAT IT COSTS, MEASURED RATHER THAN FEARED (2026-09-05, claude 2.1.261): a
# SessionStart hook blocking on an unclosed stdin held a whole headless session
# for 602 seconds, releasing it at the exact moment the writer let go. There is
# no rescue timeout on that path. And the failure is SILENT in the ordinary
# case — handed an already-closed stdin the same hook exits 0 instantly — which
# is precisely how this class survives in a green suite.
#
# The check: run each with an OPEN, EMPTY stdin (a background writer that never
# writes and never closes) and require it to finish anyway.
#
# ---------------------------------------------------------------------------
# WHY THERE IS A CONTROL ARM (added 2026-09-05)
# ---------------------------------------------------------------------------
# The first version of this helper ran ONE arm and called any overrun "BLOCKED
# on stdin". A wall clock cannot tell blocking from slowness, and on
# 2026-09-05 that cost a whole investigation: case 9b was red on unmodified
# main and its message named stdin, but session-start-reap-worktrees.sh never
# reads its own stdin at all. It was simply SLOW — its inventory sweep measured
# 8150-8479ms across five runs against an 8s window, and it failed identically
# with stdin closed. The hook was innocent and the accusation was manufactured
# by the test.
#
# That is the mirror of this project's most-repeated failure. A single-armed
# timing check does not only fail for the wrong reason; it would later PASS for
# the wrong reason, the moment the sweep got faster, while a real stdin block
# went on sitting in the hook.
#
# So each hook is run TWICE, and only one combination is a stdin block:
#
#   closed stdin      open stdin        verdict
#   ----------------  ----------------  ----------------------------------
#   finishes          finishes          ok
#   finishes          overruns          BLOCKS ON STDIN  <- the defect
#   overruns          (either)          slow/hangs regardless of stdin
#
# The third row is a real finding too, and it is reported in its own words
# rather than dressed up as the second.
#
# ---------------------------------------------------------------------------
# AND THE VERDICT NO LONGER RESTS ON AN ABSOLUTE NUMBER OF SECONDS
# ---------------------------------------------------------------------------
# The control arm removes the machine from the COMPARISON, but a fixed ceiling
# would have put it straight back into the THRESHOLD. That is the same defect
# one layer up: 8 seconds was a number that happened to suit one laptop, and a
# sweep measuring 8150-8479ms turned every slower machine — a loaded laptop,
# CI, a colder cache — into a red "blocked on stdin" that no code change could
# explain. Widening it to 9 or 14 only moves the cliff.
#
# So the ceiling for the open-stdin arm is DERIVED from what this hook just
# took on THIS machine, with stdin closed: three times its own control time
# plus five seconds, and never less than eight. A hook that takes three times
# its own measured runtime plus five seconds longer merely because stdin is
# open is not a slow machine, it is a hook waiting on a read. The check scales
# with the hardware instead of assuming it.
#
# HANG_CTRL_CEIL is the one absolute left, and it is deliberately NOT an
# assertion: it exists only so the suite terminates if a hook wedges outright.
# It is set far above any plausible honest runtime for that reason.
# ===========================================================================
HANG_CTRL_CEIL="${HANG_CTRL_CEIL:-60}"

# _run_arm <ceil-seconds> <fd-source> <hook> [args...]
#   0 finished, 1 overran. Sets ARM_SECS (label) and ARM_N (integer seconds).
_run_arm() {
    local ceil="$1" src="$2" hook="$3"; shift 3
    local start child n
    start=$(date +%s)
    (
        cd "$SANDBOX" || exit 99
        CLAUDE_PROJECT_DIR="$SESSREPO" bash "$HOOKS/$hook" "$@" >/dev/null 2>&1 <"$src"
    ) &
    child=$!
    n=0
    while kill -0 "$child" 2>/dev/null && [ "$n" -lt "$ceil" ]; do
        sleep 1
        n=$((n + 1))
    done
    if kill -0 "$child" 2>/dev/null; then
        kill -9 "$child" 2>/dev/null
        wait "$child" 2>/dev/null
        ARM_N="$ceil"
        ARM_SECS="over-${ceil}s"
        return 1
    fi
    wait "$child" 2>/dev/null
    ARM_N="$(( $(date +%s) - start ))"
    ARM_SECS="${ARM_N}s"
    return 0
}

# hang_check <hook> [args...]
#   0 = does not block on stdin
#   1 = BLOCKS on stdin (control finished, open-stdin arm did not)
#   2 = slow or hangs regardless of stdin (control did not finish either)
# Sets HANG_WHY for the caller's message.
hang_check() {
    local hook="$1"; shift
    local fifo holder ctrl_secs ctrl_n open_ceil open_rc

    # --- control arm: stdin CLOSED. Two jobs. It establishes that the hook can
    # finish at all, so an overrun in the second arm is attributable to stdin —
    # and it MEASURES this machine, so the second arm's ceiling is this hook's
    # own speed rather than a number somebody typed.
    _run_arm "$HANG_CTRL_CEIL" /dev/null "$hook" "$@" || {
        HANG_WHY="did not finish within ${HANG_CTRL_CEIL}s even with stdin CLOSED (${ARM_SECS}) — slow or hanging for some reason OTHER than stdin"
        return 2
    }
    ctrl_secs="$ARM_SECS"
    ctrl_n="$ARM_N"

    # Three times its own control time, plus five seconds, floor of eight.
    # The floor covers the bounded-read ceiling a well-behaved hook may now
    # legitimately spend (RICHOS_HOOK_STDIN_TIMEOUT, 2s) on a hook whose
    # control time rounds to zero.
    open_ceil=$(( ctrl_n * 3 + 5 ))
    [ "$open_ceil" -lt 8 ] && open_ceil=8

    # --- test arm: stdin OPEN and never closed.
    fifo="$SANDBOX/fifo.$$"
    rm -f "$fifo"; mkfifo "$fifo"
    ( exec 3>"$fifo"; sleep $((open_ceil + 10)) ) &
    holder=$!
    _run_arm "$open_ceil" "$fifo" "$hook" "$@"
    open_rc=$?
    kill -9 "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
    rm -f "$fifo"

    if [ "$open_rc" -ne 0 ]; then
        HANG_WHY="finished in $ctrl_secs with stdin CLOSED but did not finish within ${open_ceil}s (3x its own control time + 5) with stdin OPEN — it reads a stdin that may never close"
        return 1
    fi
    HANG_WHY="closed=$ctrl_secs open=$ARM_SECS ceiling=${open_ceil}s"
    return 0
}

# say_hang <label> <hook> [args...] — runs the check and records the verdict,
# keeping the three outcomes distinguishable in the output.
say_hang() {
    local label="$1"; shift
    # The ARGS are part of the identity, not decoration: 9c and 9f are the same
    # script and differ only by `--session`, and that difference is the whole
    # point of 9f. A label naming only the script would print two identical
    # lines for two different assertions.
    local what="$*"
    hang_check "$@"
    case $? in
    0) ok   "$label POSITIVE  $what completes with an open, never-closed stdin ($HANG_WHY)" ;;
    1) bad  "$label $what BLOCKS ON STDIN — $HANG_WHY" ;;
    2) bad  "$label $what $HANG_WHY" ;;
    esac
}

say_hang 9a engine-status.sh
say_hang 9b session-start-reap-worktrees.sh
# The snapshotter with --session must not read stdin at all: that is the exact
# invocation the contract-integrity probe uses, and the exact one that hung.
say_hang 9c snapshot-agent-definitions.sh --session cafe1234-0000
# 9d NEGATIVE — and it must still READ the payload when there is no --session,
# because that is where the session id comes from. Without this, "does not
# hang" could be satisfied by never reading stdin at all, and the session-scoped
# snapshot would silently degrade to a timestamped one.
rm -rf "$SESSREPO/.claude/state"
run snapshot-agent-definitions.sh '{"session_id":"beef9999-0000","cwd":"'"$SESSREPO"'","hook_event_name":"SessionStart"}' "CLAUDE_PROJECT_DIR=$SESSREPO"
if [ -f "$SESSREPO/.claude/state/agent-definitions-beef9999.snapshot" ]; then
    ok "9d NEGATIVE  without --session it still reads the payload for the session id"
else
    bad "9d payload session id no longer read (out=${OUT:0:200})"
fi
# 9e — session-start-escalations.sh, added with the escalation channel on
# 2026-09-05. It deliberately reads NO payload (the ledger is session-
# independent, which is the entire point of that hook), so the claim in its
# header is asserted here rather than left as a comment.
say_hang 9e session-start-escalations.sh

# ---------------------------------------------------------------------------
# 9f-9i — THE COVERAGE HOLE THIS SECTION HAD, closed 2026-09-05.
#
# hooks/hooks.json registers SIX SessionStart scripts. Cases 9a-9e covered
# four, and covered the snapshotter only in its `--session` form — the ONE
# invocation that cannot reach its payload read. The two forms nobody tested
# were the two that blocked:
#
#   * snapshot-agent-definitions.sh WITHOUT --session, which is exactly how it
#     fires as a real SessionStart hook;
#   * snapshot-enforcing-hooks.sh, which had no hang case at all.
#
# Both ran forever against an open, never-closed stdin while finishing in
# under a second with stdin closed. Every SessionStart script is now checked
# in the form it actually fires in, so "all covered" means the registration
# surface rather than a list somebody typed.
# ---------------------------------------------------------------------------
say_hang 9f snapshot-agent-definitions.sh
say_hang 9g snapshot-enforcing-hooks.sh
say_hang 9h session-start-ceo-ask.sh
# 9k — session-start-ci-surface.sh, registered 2026-09-10 (the CI-surface notice).
# It reads the watch's cache files and never stdin; asserted here rather than
# assumed, because 9j went red in CI the day it was registered without this line.
say_hang 9k session-start-ci-surface.sh

# 9i NEGATIVE — the partner to 9d, and the reason 9g cannot be satisfied by
# simply never reading stdin: snapshot-enforcing-hooks.sh must STILL take its
# session id from the payload, because a bounded read that quietly dropped the
# payload would degrade every later staleness comparison to a timestamped
# baseline while reporting nothing wrong.
# HOOK_STALENESS_SURFACE points at the SHIPPED hooks.json: the sandbox engine
# is assembled without hooks/, and without a surface this hook writes no
# baseline at all — which would make 9i fail for a reason that has nothing to
# do with the payload it is here to assert.
rm -rf "$SESSREPO/.claude/state"
run snapshot-enforcing-hooks.sh '{"session_id":"feed4321-0000","cwd":"'"$SESSREPO"'","hook_event_name":"SessionStart"}' "CLAUDE_PROJECT_DIR=$SESSREPO" "HOOK_STALENESS_SURFACE=$SRC_ENGINE/hooks/hooks.json"
if [ -f "$SESSREPO/.claude/state/enforcing-hooks-feed4321.snapshot" ]; then
    ok "9i NEGATIVE  snapshot-enforcing-hooks.sh still reads the payload session id"
else
    bad "9i enforcing-hook snapshot is no longer session-scoped from the payload (out=${OUT:0:200})"
fi

# 9j — EVERY registered SessionStart script is checked above. Derived from the
# registration surface, never from a typed list, for the reason
# scripts/lib/registered-hooks.sh exists: a hand-maintained inventory of what
# is covered drifts, and a coverage claim over a stale inventory is exactly the
# hole 9f and 9g fell through.
COVERED="engine-status.sh session-start-reap-worktrees.sh snapshot-agent-definitions.sh snapshot-enforcing-hooks.sh session-start-ceo-ask.sh session-start-escalations.sh session-start-ci-surface.sh"
# Read the SHIPPED registration surface, not the sandbox copy: the sandbox
# engine is assembled from scripts/ and .claude*/ and deliberately has no
# hooks/hooks.json, and the claim being made here is about what the host
# actually loads.
REGISTERED_SS="$(python3 - "$SRC_ENGINE/hooks/hooks.json" <<'PY' 2>/dev/null || true
import json, re, sys
d = json.load(open(sys.argv[1]))
h = d.get("hooks", d)
out = []
for g in h.get("SessionStart", []):
    for hk in g.get("hooks", []):
        m = re.search(r"scripts/hooks/([A-Za-z0-9._-]+\.sh)", hk.get("command", ""))
        if m:
            out.append(m.group(1))
print(" ".join(sorted(set(out))))
PY
)"
UNCOVERED=""
for _s in $REGISTERED_SS; do
    case " $COVERED " in
    *" $_s "*) : ;;
    *) UNCOVERED="$UNCOVERED $_s" ;;
    esac
done
if [ -n "$REGISTERED_SS" ] && [ -z "$UNCOVERED" ]; then
    ok "9j POSITIVE  every SessionStart script registered in hooks.json has a hang case"
elif [ -z "$REGISTERED_SS" ]; then
    bad "9j could not read the SessionStart registrations from hooks.json — coverage unproven"
else
    bad "9j SessionStart scripts registered but never hang-checked:$UNCOVERED"
fi

# ---------------------------------------------------------------------------
# 9l / 9m — BOTH ARMS OF THE REDIRECT (round 15). 9l POSITIVE: the reaper,
# run exactly as 9b runs it but with its output kept, names the SANDBOX
# ledger and the SANDBOX team directory in its own blind lines — so the paths
# it resolved are provably under the moved HOME, not the operator's. It needs
# a hand-rolled worktree of the session repository on disk, because the
# ledger line is only printed when there is a hand-rolled candidate to judge.
# 9m NEGATIVE: the operator's real record — ledger rows (except the
# platform's per-turn `finished` rows), the fallback event log, the team
# directory entries — is exactly as it was before HOME moved.
# ---------------------------------------------------------------------------
git -C "$SESSREPO" worktree add -q -b mark-opus-t1 "$SANDBOX/sessrepo-wt/mark-opus-t1" >/dev/null 2>&1
run session-start-reap-worktrees.sh '' "CLAUDE_PROJECT_DIR=$SESSREPO"
if printf '%s' "$OUT" | grep -q "no ownership ledger exists yet at $HOME/.claude/state/worktree-ledger.jsonl" \
   && printf '%s' "$OUT" | grep -q "no inflight-repos.txt under $HOME/.claude/teams"; then
    ok "9l POSITIVE  the reaper resolved the ownership ledger and the team directories under the SANDBOX home ($HOME) — the redirect is honored, not assumed"
else
    bad "9l the reaper did not name the sandbox ledger and team directory in its blind lines (out=${OUT:0:600})"
fi
TOUCHED="$(rc_escaped "$SANDBOX/real-record-baseline.txt")"
if [ "$RC_HEALTHY" -eq 1 ] && [ -z "$TOUCHED" ]; then
    ok "9m NEGATIVE  the operator's real record under $RC_CFG is untouched by this suite (ledger rows except finished, fallback event log, team directory entries)"
else
    bad "9m the operator's real record CHANGED during this suite (healthy=$RC_HEALTHY): $TOUCHED"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== session-start stdin: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== session-start stdin: all $PASS passed ==="
    exit 0
fi
