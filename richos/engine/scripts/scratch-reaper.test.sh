#!/usr/bin/env bash
#
# scratch-reaper.test.sh — A DELETER IS JUDGED ON WHAT IT LEAVES ALONE.
#
# ===========================================================================
# WHAT THIS SUITE IS FOR
# ===========================================================================
# Proving that a reaper deletes is one case and it is the easy one. Every
# other case here asks the only question that matters about a program with
# rm -rf in it:
#
#     WHEN IT IS WRONG, IS IT WRONG IN THE DIRECTION THAT COSTS NOTHING?
#
# The liveness cases use a REAL SESSION PROCESS — /bin/sleep started as
# `exec -a "$SUITE_PROC"` — with a REAL entry in the process table and a REAL session
# file naming its pid and its start time. Nothing about liveness is faked or
# injected, because the defect this suite exists to catch is a liveness check
# that has quietly stopped working, and a faked process table cannot catch it.
#
#   S1  a LIVE session's scratch survives.
#   S1b THE POSITIVE CONTROL for S1 — the same directory, same contents, same
#       everything, with the process KILLED, is deleted. Without this, S1
#       passes just as well against a reaper that deletes nothing at all,
#       which is the way a safety test rots.
#   S2  a REGISTERED WORKSPACE inside a scratch root survives (wall 3).
#   S3  INDETERMINATE survives AND SAYS SO: a running claude process that no
#       session file names makes every unattributed scratch undecidable, and
#       the verdict line carries the count.
#   S4  a tree containing a .git survives (wall 2).
#   S5  the LOG carries every deleted path, with bytes and a reason.
#   S6  --apply prints, byte for byte, what the dry run printed, plus one
#       final `applied:` line. A plan that changes when you agree to it is not
#       a plan.
#   S7  a file in a scratch root that PREDATES every running claude process is
#       deleted; one written after the oldest running process started is kept.
#   S8  nightly retention keeps the newest N and deletes the rest, and never
#       touches the source worktree or the runtime.
#   S9  AN UNDECLARED THRESHOLD IS A REFUSAL, not a default. Exit 2, nothing
#       deleted.
#   S10 a $TMPDIR harness workspace that no process holds open is deleted; one
#       held open is kept.
#   S11 the verdict line exits 3 while anything is undecidable — undecidable is
#       a failure, never a footnote beside a success-shaped count.
#
# Exit 0 = every case passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SCRIPT_DIR/scratch-reaper.sh"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/scratch-reaper-test.XXXXXX")" && pwd -P)"
KILL_LIST=""
cleanup() {
    # Reaped as well as killed: an unreaped job prints "Terminated: 15" AFTER
    # the summary line, which is the last thing a reader should see.
    for p in $KILL_LIST; do
        kill "$p" >/dev/null 2>&1 || true
        wait "$p" >/dev/null 2>&1 || true
    done
    rm -rf "$SANDBOX"
}
trap cleanup EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$REAPER" ] || { echo "FATAL: missing $REAPER" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

echo "=== scratch-reaper tests ==="

# ---------------------------------------------------------------------------
# THE PROCESS NAME IS UNIQUE TO THIS RUN, and that is what makes this suite
# hermetic. The reaper reads the MACHINE-WIDE process table, which is shared
# state: the mutation harness runs eight copies of this suite at once, each
# starting session processes of its own, and under the shared name `claude`
# every run saw the others' processes as unattributed and correctly answered
# INDETERMINATE for everything. Three mutants then scored green against a
# reaper that was deleting nothing — the exact green-for-the-wrong-reason this
# suite exists to refuse, arriving through the suite itself.
#
# SCRATCH_SESSION_PROCESS_NAMES is declared per world, so the shipped code path
# is byte-for-byte the production one and only this run's processes are in it.
#
# A REAL PROCESS — `exec -a "$SUITE_PROC" /bin/sleep`. It is /bin/sleep,
# it is in the process table under that name, it has a genuine start time, and
# it can be killed to make a genuinely dead one. The reaper reads it with the
# same ps call it uses in production and cannot tell it from a session.
#
# TWO EARLIER SHAPES WERE MEASURED AND BOTH LIED:
#   * `cp /bin/sleep $sandbox/claude` — macOS SIGKILLs the copy of a signed
#     platform binary. The process was dead before the reaper looked, which
#     made a liveness test pass for the wrong reason.
#   * `PID=$(start_claude)` — the background job starts inside the command
#     substitution's SUBSHELL, and every KILL_LIST append made there is thrown
#     away with it. The pid came back; the bookkeeping did not.
# The pid is therefore returned in a variable set by the CURRENT shell.
# ---------------------------------------------------------------------------
SUITE_PROC="zsr${$}claude"
LAST_CLAUDE=""
start_claude() {           # -> LAST_CLAUDE
    ( exec -a "$SUITE_PROC" /bin/sleep 600 ) >/dev/null 2>&1 &
    LAST_CLAUDE=$!
    KILL_LIST="$KILL_LIST $LAST_CLAUDE"
}

register() {               # <sessions-dir> <pid> <session-id>
    local sd="$1" pid="$2" sid="$3" start
    mkdir -p "$sd"
    start="$(LC_ALL=C LANG=C TZ=UTC0 ps -o lstart= -p "$pid" | tr -s ' ' | sed 's/^ *//;s/ *$//')"
    python3 - "$sd/$pid.json" "$pid" "$sid" "$start" <<'PY'
import json, sys
path, pid, sid, start = sys.argv[1:5]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"pid": int(pid), "sessionId": sid, "procStart": start,
               "cwd": "/", "kind": "interactive"}, fh)
PY
}

# ---------------------------------------------------------------------------
# A SANDBOX WORLD: its own scratch root, its own sessions registry, its own
# config file. The config is a FILE and not exported variables, because the
# shipped script sources its declarations from a file and a test that bypassed
# that would not be testing the shipped path.
# ---------------------------------------------------------------------------
# EVERY SESSION PROCESS THIS SUITE HAS ALREADY STARTED IS REGISTERED IN EACH
# NEW WORLD, with a filler session id: an earlier case's process is still
# running, and an unregistered running process is a correct INDETERMINATE and a
# suite that has stopped testing anything. Measured on the first run, where the
# operator's own live session did exactly that to all 22 cases.
attribute_running_claudes() {   # <sessions-dir>
    local sd="$1" pid i=0
    for pid in $(LC_ALL=C LANG=C TZ=UTC0 ps -Ao pid=,comm= \
                 | awk -v want="$SUITE_PROC" \
                       '{ n=split($2, p, "/"); if (p[n] == want) print $1 }'); do
        i=$((i + 1))
        register "$sd" "$pid" "$(printf 'f0000000-0000-0000-0000-%012d' "$i")"
    done
}

world() {                  # <name> -> exports W_*
    W_ROOT="$SANDBOX/$1"
    W_SCRATCH="$W_ROOT/scratch"
    W_SESSIONS="$W_ROOT/sessions"
    W_CFG="$W_ROOT/orchestration.config"
    W_HOME="$W_ROOT/claude"
    W_TMP="$W_ROOT/tmp"
    W_NIGHTLY="$W_ROOT/nightly"
    mkdir -p "$W_SCRATCH" "$W_SESSIONS" "$W_HOME/state" "$W_TMP" "$W_NIGHTLY"
    {
        echo 'SCRATCH_REAPER_ENABLE="1"'
        echo "SCRATCH_SESSION_PROCESS_NAMES=\"$SUITE_PROC\""
        echo "SCRATCH_CLAUDE_ROOTS=\"$W_SCRATCH\""
        echo 'SCRATCH_TMP_PATTERNS="richos-*-workspace"'
        echo 'SCRATCH_AGE_FLOOR_MINUTES="0"'
        echo "SCRATCH_NIGHTLY_DIR=\"$W_NIGHTLY\""
        echo 'SCRATCH_NIGHTLY_KEEP="3"'
        echo 'SCRATCH_NOTICE_BYTES="1"'
        echo 'SCRATCH_REAPER_HOURS="4"'
        echo 'SCRATCH_REAPER_MINUTE="40"'
    } >"$W_CFG"
    attribute_running_claudes "$W_SESSIONS"
}

run() {                    # run the reaper in the current world
    SCRATCH_REAPER_CONFIG="$W_CFG" \
    RICHOS_SESSIONS_DIR="$W_SESSIONS" \
    CLAUDE_CONFIG_DIR="$W_HOME" \
    TMPDIR="$W_TMP" \
    bash "$REAPER" "$@" 2>&1
}

SID_LIVE="11111111-1111-1111-1111-111111111111"
SID_DEAD="22222222-2222-2222-2222-222222222222"

# ===========================================================================
# S1 / S1b — the live session survives, and the same thing dead does not
# ===========================================================================
world live
start_claude; PID_LIVE="$LAST_CLAUDE"
register "$W_SESSIONS" "$PID_LIVE" "$SID_LIVE"
mkdir -p "$W_SCRATCH/-a-project/$SID_LIVE/scratchpad"
echo payload >"$W_SCRATCH/-a-project/$SID_LIVE/scratchpad/work.txt"

OUT="$(run --apply)"
if [ -f "$W_SCRATCH/-a-project/$SID_LIVE/scratchpad/work.txt" ]; then
    ok "S1  a live session's scratch survives --apply"
else
    bad "S1  a live session's scratch was DELETED while its process was running"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# The positive control. Same directory, same contents; the process is killed
# and its registration left behind exactly as a crashed session leaves it.
kill "$PID_LIVE" >/dev/null 2>&1 || true
wait "$PID_LIVE" 2>/dev/null || true
mkdir -p "$W_SCRATCH/-a-project/$SID_LIVE/scratchpad"
echo payload >"$W_SCRATCH/-a-project/$SID_LIVE/scratchpad/work.txt"
OUT="$(run --apply)"
if [ ! -e "$W_SCRATCH/-a-project/$SID_LIVE" ]; then
    ok "S1b POSITIVE CONTROL: the same scratch with the process gone IS deleted"
else
    bad "S1b the dead session's scratch survived — S1 proves nothing"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# ===========================================================================
# S2 — a registered workspace survives
# ===========================================================================
world registered
mkdir -p "$W_SCRATCH/-a-project/$SID_DEAD/scratchpad/workspace"
echo work >"$W_SCRATCH/-a-project/$SID_DEAD/scratchpad/workspace/file.txt"
mkdir -p "$W_HOME/state/workspaces/agents"
python3 - "$W_HOME/state/workspaces/agents/a.json" \
          "$W_SCRATCH/-a-project/$SID_DEAD/scratchpad/workspace" <<'PY'
import json, sys
path, wt = sys.argv[1:3]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"name": "someone", "worktree": wt, "workspaces": [wt]}, fh)
PY
OUT="$(run --apply)"
if [ -f "$W_SCRATCH/-a-project/$SID_DEAD/scratchpad/workspace/file.txt" ]; then
    ok "S2  a REGISTERED workspace inside dead scratch survives (wall 3)"
else
    bad "S2  a registered workspace was deleted"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi
case "$OUT" in
    *"REGISTERED workspace"*) ok "S2b the refusal NAMES the registration" ;;
    *) bad "S2b the refusal did not name the registration"
       printf '%s\n' "$OUT" | sed 's/^/        /' ;;
esac

# ===========================================================================
# S3 / S11 — INDETERMINATE survives, is named, and costs exit 3
# ===========================================================================
world indeterminate
mkdir -p "$W_SCRATCH/-a-project/$SID_DEAD/scratchpad"
echo payload >"$W_SCRATCH/-a-project/$SID_DEAD/scratchpad/work.txt"
start_claude; PID_UNATTRIBUTED="$LAST_CLAUDE"     # running, named by NO session file
OUT="$(run --apply)"; RC=$?
if [ -f "$W_SCRATCH/-a-project/$SID_DEAD/scratchpad/work.txt" ]; then
    ok "S3  scratch an unattributed claude process could own is NOT deleted"
else
    bad "S3  INDETERMINATE was collapsed into dead and the scratch was deleted"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi
case "$OUT" in
    *"named by no session file"*|*"named by NO session file"*)
        ok "S3b the reason NAMES the unattributed process" ;;
    *) bad "S3b the undecidable entry carried no named reason"
       printf '%s\n' "$OUT" | sed 's/^/        /' ;;
esac
case "$OUT" in
    *"undecidable=0"*) bad "S11 undecidable was reported as zero while one stood" ;;
    *undecidable=*)    ok "S11 the verdict line carries the undecidable count" ;;
    *) bad "S11 no verdict line" ;;
esac
run --apply >/dev/null 2>&1; RC=$?
if [ "$RC" = "3" ]; then
    ok "S11b exit 3 while anything is undecidable"
else
    bad "S11b exit was $RC, not 3, with an undecidable entry standing"
fi
kill "$PID_UNATTRIBUTED" >/dev/null 2>&1 || true
wait "$PID_UNATTRIBUTED" 2>/dev/null || true

# ===========================================================================
# S4 — a .git in the tree survives
# ===========================================================================
world repo
mkdir -p "$W_SCRATCH/-a-project/$SID_DEAD/scratchpad/checkout/.git"
echo ref >"$W_SCRATCH/-a-project/$SID_DEAD/scratchpad/checkout/.git/HEAD"
OUT="$(run --apply)"
if [ -f "$W_SCRATCH/-a-project/$SID_DEAD/scratchpad/checkout/.git/HEAD" ]; then
    ok "S4  a tree containing a .git survives (wall 2)"
else
    bad "S4  a checkout inside dead scratch was deleted"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# ===========================================================================
# S5 — the log carries every deleted path
# ===========================================================================
world logged
for n in 1 2 3; do
    sid="3333333$n-3333-3333-3333-333333333333"
    mkdir -p "$W_SCRATCH/-a-project/$sid/scratchpad"
    echo x >"$W_SCRATCH/-a-project/$sid/scratchpad/f"
done
run --apply >/dev/null
LOG="$W_HOME/state/scratch-reaper.log"
MISSING=0
for n in 1 2 3; do
    sid="3333333$n-3333-3333-3333-333333333333"
    grep -q "$W_SCRATCH/-a-project/$sid" "$LOG" 2>/dev/null || MISSING=$((MISSING + 1))
done
if [ "$MISSING" = "0" ]; then
    ok "S5  every deleted path is named in $LOG"
else
    bad "S5  $MISSING deleted path(s) never reached the log"
fi
if grep -q "bytes=" "$LOG" 2>/dev/null && grep -q "why=" "$LOG" 2>/dev/null; then
    ok "S5b each log line carries bytes and the reason it qualified"
else
    bad "S5b log lines carry no bytes/why"
fi
if grep -q "verdict:" "$LOG" 2>/dev/null; then
    ok "S5c the run ends with a verdict line in the log"
else
    bad "S5c no verdict line in the log"
fi

# ===========================================================================
# S6 — the dry run IS the plan
# ===========================================================================
world identical
for n in 1 2; do
    sid="4444444$n-4444-4444-4444-444444444444"
    mkdir -p "$W_SCRATCH/-a-project/$sid/scratchpad"
    echo x >"$W_SCRATCH/-a-project/$sid/scratchpad/f"
done
DRY="$(run --dry-run)"
APPLIED="$(run --apply)"
# --apply adds exactly one line, at the end.
if [ "$DRY" = "$(printf '%s\n' "$APPLIED" | sed '$d')" ]; then
    ok "S6  --apply prints the dry run's plan byte for byte, plus one line"
else
    bad "S6  the applied plan differs from the plan that was shown"
    diff <(printf '%s\n' "$DRY") <(printf '%s\n' "$APPLIED" | sed '$d') \
        | sed 's/^/        /' | head -20
fi
case "$APPLIED" in
    *"applied: deleted="*) ok "S6b the added line is the applied summary" ;;
    *) bad "S6b --apply did not report what it did" ;;
esac

# ===========================================================================
# S7 — the orphan rule, both ways
# ===========================================================================
world orphans
touch -t 202001010000 "$W_SCRATCH/ancient.out"        # before any process
echo fresh >"$W_SCRATCH/fresh.out"                    # after every process
start_claude; PID_KEEP="$LAST_CLAUDE"
register "$W_SESSIONS" "$PID_KEEP" "$SID_LIVE"
sleep 1
echo newer >"$W_SCRATCH/newer.out"
OUT="$(run --apply)"
if [ ! -e "$W_SCRATCH/ancient.out" ]; then
    ok "S7  a scratch-root file older than every running claude process is deleted"
else
    bad "S7  the ancient orphan survived"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi
if [ -f "$W_SCRATCH/newer.out" ]; then
    ok "S7b a file written AFTER a running process started is kept"
else
    bad "S7b a file a running session could own was deleted"
fi
kill "$PID_KEEP" >/dev/null 2>&1 || true
wait "$PID_KEEP" 2>/dev/null || true

# ===========================================================================
# S8 — nightly retention
# ===========================================================================
world nightly
mkdir -p "$W_NIGHTLY/releases" "$W_NIGHTLY/logs" "$W_NIGHTLY/source" "$W_NIGHTLY/runtime"
echo src >"$W_NIGHTLY/source/keep.txt"
echo rt  >"$W_NIGHTLY/runtime/keep.txt"
for n in 1 2 3 4 5; do
    mkdir -p "$W_NIGHTLY/releases/v$n"
    echo build >"$W_NIGHTLY/releases/v$n/app"
    touch -t "2026090${n}0000" "$W_NIGHTLY/releases/v$n" "$W_NIGHTLY/releases/v$n/app"
done
OUT="$(run --apply)"
KEPT=0
for n in 3 4 5; do [ -d "$W_NIGHTLY/releases/v$n" ] && KEPT=$((KEPT + 1)); done
GONE=0
for n in 1 2; do [ ! -e "$W_NIGHTLY/releases/v$n" ] && GONE=$((GONE + 1)); done
if [ "$KEPT" = "3" ] && [ "$GONE" = "2" ]; then
    ok "S8  the newest 3 releases are kept and the older 2 are deleted"
else
    bad "S8  retention kept=$KEPT of 3 newest, deleted=$GONE of 2 oldest"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi
if [ -f "$W_NIGHTLY/source/keep.txt" ] && [ -f "$W_NIGHTLY/runtime/keep.txt" ]; then
    ok "S8b the nightly source checkout and runtime are never touched"
else
    bad "S8b the reaper reached into the nightly source or runtime"
fi

# ===========================================================================
# S9 — an undeclared threshold refuses
# ===========================================================================
world undeclared
mkdir -p "$W_SCRATCH/-a-project/$SID_DEAD/scratchpad"
echo x >"$W_SCRATCH/-a-project/$SID_DEAD/scratchpad/f"
grep -v SCRATCH_AGE_FLOOR_MINUTES "$W_CFG" >"$W_CFG.tmp" && mv "$W_CFG.tmp" "$W_CFG"
OUT="$(run --apply)"; RC=$?
if [ "$RC" = "2" ] && [ -f "$W_SCRATCH/-a-project/$SID_DEAD/scratchpad/f" ]; then
    ok "S9  an undeclared threshold is exit 2 and nothing is deleted"
else
    bad "S9  exit was $RC with a threshold undeclared"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi
case "$OUT" in
    *SCRATCH_AGE_FLOOR_MINUTES*) ok "S9b the refusal names the undeclared value" ;;
    *) bad "S9b the refusal did not name the missing declaration" ;;
esac

# ===========================================================================
# S10 — a temp workspace nobody holds open
# ===========================================================================
world tmpworkspaces
mkdir -p "$W_TMP/richos-abandoned-workspace" "$W_TMP/richos-held-workspace"
echo x >"$W_TMP/richos-abandoned-workspace/f"
echo x >"$W_TMP/richos-held-workspace/f"
if command -v lsof >/dev/null 2>&1; then
    # `exec` inside the backgrounded subshell, so $! is the pid of the process
    # that ends up SITTING IN the directory. Backgrounding inside the subshell
    # instead leaves the child orphaned the moment the subshell exits, and it
    # was measured dying before lsof ever saw it.
    ( cd "$W_TMP/richos-held-workspace" && exec -a "$SUITE_PROC" /bin/sleep 600 ) >/dev/null 2>&1 &
    HELD=$!
    KILL_LIST="$KILL_LIST $HELD"
    sleep 1
    OUT="$(run --apply)"
    if [ ! -e "$W_TMP/richos-abandoned-workspace" ]; then
        ok "S10  an abandoned harness workspace is deleted"
    else
        bad "S10  the abandoned harness workspace survived"
        printf '%s\n' "$OUT" | sed 's/^/        /'
    fi
    if [ -f "$W_TMP/richos-held-workspace/f" ]; then
        ok "S10b a workspace a process is sitting in is kept"
    else
        bad "S10b a held workspace was deleted out from under a process"
    fi
    kill "$HELD" >/dev/null 2>&1 || true
    wait "$HELD" >/dev/null 2>&1 || true
else
    ok "S10  SKIPPED — lsof is not on this host, and without it the reaper is
        required to answer INDETERMINATE rather than delete"
    OUT="$(run)"
    case "$OUT" in
        *"lsof could not answer"*) ok "S10b no lsof means INDETERMINATE, not deletion" ;;
        *) bad "S10b without lsof the temp-workspace class did not say so" ;;
    esac
fi

# --- THE MUTATION HARNESS RUNS FROM THE SUITE IT MUTATES -------------------
# run-all-tests.sh discovers *.test.sh; a *.mutation.sh is invisible to it, and
# eight harnesses in this engine were once run by nothing at all. It matters
# more here than usual: MOST OF THE CASES ABOVE ARE THINGS THAT MUST NOT
# HAPPEN, and every one of them passes against a reaper that deletes nothing.
# The harness is what proves they are not passing for that reason.
#
# ITS FAILURE IS THIS SUITE'S FAILURE, and a MISSING harness is a failure and
# never a skip. RICHOS_MUTATION_INNER is the only thing between this and an
# infinite regress — the harness exports it before running any copy of this
# suite, so never remove one half without the other.
if [ -z "${RICHOS_MUTATION_INNER:-}" ]; then
    echo ""
    echo "=== running the mutation harness: scratch-reaper.mutation.sh ==="
    if [ -x "$SCRIPT_DIR/scratch-reaper.mutation.sh" ]; then
        "$SCRIPT_DIR/scratch-reaper.mutation.sh" || FAIL=$((FAIL + 1))
    else
        echo "  FAIL  MUT. scratch-reaper.mutation.sh is missing or not executable — IT DID NOT RUN"
        FAIL=$((FAIL + 1))
    fi
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
