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
# --- added 2026-09-18 with the allocator root and the legacy sweep -----------
# The 105 GB night: a sandbox named by a bare mktemp sat under $TMPDIR for five
# hours while this reaper ran twice, because SCRATCH_TMP_PATTERNS was an
# allowlist of two globs and nothing matched it.
#
#   S12  THE ALLOCATOR ROOT, DENY-BY-DEFAULT — the arm that would have caught
#        it. A dead owner goes (S12), a LIVE owner stays (S12b, the control), an
#        unrecorded directory goes because the only way to get one there is to
#        ask the allocator (S12c), and with the ledger DELETED a live owner is
#        still protected by the pid in the directory name (S12d).
#   S13  a RELEASED ledger row whose tree survived the rm is deleted.
#   S14  the legacy family sweep: abandoned goes (S14), a fixture containing a
#        .git goes (S14b), A REGISTERED WORKSPACE WEARING A LEGACY NAME IS
#        STILL REFUSED (S14c — wall 3 survived the wall-2 narrowing, which is
#        the case that decides whether that narrowing was safe), and with the
#        narrowing declared OFF the same fixture goes back to undecidable
#        (S14d, the control that makes S14b a decision rather than an oversight).
#   S15  a legacy directory with an open file descriptor inside is kept, and
#        the same directory with its holder gone is deleted (S15b, the control).
#   S16  a STOPPED Docker daemon is skipped silently and is never a failure
#        (S16/S16b); a daemon that ANSWERS is actually asked to prune, both
#        arms, and the bytes it reports reach the log (S16c/S16d, the controls
#        that stop S16 passing against a docker arm that is dead code).
#   S17  A FAILED DELETION MUST NOT HIDE ITSELF. Measured live: five deletions
#        failed with EPERM and the next run said failures=0 with all five still
#        on disk, because rmtree's partial progress bumped each directory's
#        mtime and the age floor then KEPT it — silently, for two hours. The
#        reaper's own failure erased its own evidence. A failure is now durable
#        and reconsidered regardless of age (S17), the age floor still works
#        when nothing failed (S17b), and a resolved failure leaves the books so
#        the alert can clear (S17c).
#   S18  an obstacle to removal is CLEARED in machine-made harness scratch
#        (S18/S18b, logged because it is a power) and REPORTED rather than
#        overridden in a session's scratchpad (S18c, the bound).
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
        # --- added 2026-09-18 with the allocator root and the legacy sweep ---
        echo 'SCRATCH_ROOT_NAME="richos-scratch"'
        echo 'SCRATCH_DEFAULT_TTL_MINUTES="360"'
        # A family name NOTHING ELSE IN THIS SUITE USES, so adding the legacy
        # arm cannot change the verdict of a case written before it existed.
        echo 'SCRATCH_LEGACY_TMP_PATTERNS="zlegacy-*"'
        echo 'SCRATCH_LEGACY_AGE_HOURS="0"'
        echo 'SCRATCH_LEGACY_GIT_IS_FIXTURE="1"'
        # OFF by default in every world. A suite that shelled out to the
        # operator's real Docker daemon would be pruning their images, and S16
        # turns it on against a deliberately broken `docker` instead.
        echo 'SCRATCH_DOCKER_PRUNE="0"'
        echo 'SCRATCH_DOCKER_KEEP_STORAGE="20GB"'
    } >"$W_CFG"
    attribute_running_claudes "$W_SESSIONS"
}

# alloc <name> [pid] — a directory in the allocator root, with a ledger row.
# The ledger lives in the world's own CLAUDE_CONFIG_DIR, so nothing here can
# see or damage the real one.
alloc() {                  # <dir-name> <pid> <label>
    local name="$1" pid="$2" label="${3:-fixture}"
    local root="$W_TMP/richos-scratch"
    mkdir -p "$root/$name"
    printf '%s\n' "payload" >"$root/$name/payload.txt"
    mkdir -p "$W_HOME/state"
    printf '{"path":"%s","label":"%s","pid":%d,"ppid":1,"session":"","created":"%s","ttl_minutes":360,"event":"new"}\n' \
        "$root/$name" "$label" "$pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >>"$W_HOME/state/scratch-ledger.jsonl"
    printf '%s\n' "$root/$name"
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


# ===========================================================================
# S12 — THE ALLOCATOR ROOT, SWEPT DENY-BY-DEFAULT
# ===========================================================================
# This is the arm that would have caught the 105 GB, so it gets the fullest
# treatment: a dead owner goes, a LIVE owner stays, and an entry that no ledger
# row mentions at all goes because the only way to get a directory under that
# root is to ask the allocator for one.
world alloc
start_claude; PID_ALIVE="$LAST_CLAUDE"
register "$W_SESSIONS" "$PID_ALIVE" "$SID_LIVE"

D_DEAD="$(alloc "99999-mutation-deadowner" 99999 mutation)"
D_LIVE="$(alloc "$PID_ALIVE-mutation-liveowner" "$PID_ALIVE" mutation)"
# No ledger row at all, and no pid in the name either.
mkdir -p "$W_TMP/richos-scratch/unrecorded-junk"
echo payload >"$W_TMP/richos-scratch/unrecorded-junk/payload.txt"

OUT="$(run --apply)"

if [ ! -d "$D_DEAD" ]; then
    ok "S12  an allocation whose owner pid is ENDED is deleted"
else
    bad "S12  a dead owner's allocation survived"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

if [ -f "$D_LIVE/payload.txt" ]; then
    ok "S12b a LIVE owner's allocation survives — the positive control for S12"
else
    bad "S12b a live owner's allocation was deleted from under it"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

if [ ! -d "$W_TMP/richos-scratch/unrecorded-junk" ]; then
    ok "S12c an unrecorded directory under the allocator root is deleted"
else
    bad "S12c an unrecorded directory under the allocator root survived — the"
    bad "     root is supposed to be deny-by-default"
fi

# THE NAME IS THE SECOND RECORD. With the ledger destroyed entirely, a live
# owner must STILL be protected, because the pid is on the front of the
# directory name. This is the case that decides whether losing $HOME turns the
# reaper into something that deletes a running harness's sandbox.
D_LIVE2="$(alloc "$PID_ALIVE-mutation-ledgerless" "$PID_ALIVE" mutation)"
rm -f "$W_HOME/state/scratch-ledger.jsonl"
OUT="$(run --apply)"
if [ -f "$D_LIVE2/payload.txt" ]; then
    ok "S12d with the ledger DELETED, a live owner is still protected by the"
    ok "     pid in the directory name"
else
    bad "S12d losing the ledger made the reaper delete a LIVE owner's sandbox"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi
kill "$PID_ALIVE" >/dev/null 2>&1 || true
wait "$PID_ALIVE" 2>/dev/null || true

# ===========================================================================
# S13 — A RELEASED ROW WHOSE TREE IS STILL THERE
# ===========================================================================
# scratch_release ran, said so in the ledger, and the rm did not complete.
# Nothing owns it and its maker has said as much.
world released
mkdir -p "$W_TMP/richos-scratch/4242-mutation-halfreleased"
echo payload >"$W_TMP/richos-scratch/4242-mutation-halfreleased/payload.txt"
mkdir -p "$W_HOME/state"
{
    printf '{"path":"%s","label":"mutation","pid":4242,"ppid":1,"session":"","created":"%s","ttl_minutes":360,"event":"new"}\n' \
        "$W_TMP/richos-scratch/4242-mutation-halfreleased" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"path":"%s","pid":4242,"released":"%s","event":"release"}\n' \
        "$W_TMP/richos-scratch/4242-mutation-halfreleased" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >>"$W_HOME/state/scratch-ledger.jsonl"
OUT="$(run --apply)"
if [ ! -d "$W_TMP/richos-scratch/4242-mutation-halfreleased" ]; then
    ok "S13  a RELEASED row whose tree survived the rm is deleted"
else
    bad "S13  a released-but-present allocation survived"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# ===========================================================================
# S14 — THE LEGACY FAMILY SWEEP, AND WALL 3 STILL STANDING OVER IT
# ===========================================================================
# The legacy arm is what reclaims the names that 171 engine files still create
# with a bare mktemp. S14b is the case that matters most: narrowing wall 2 for
# these families must NOT have opened a path to a registered worktree.
world legacy
mkdir -p "$W_TMP/zlegacy-abandoned"
echo payload >"$W_TMP/zlegacy-abandoned/payload.txt"

# A fixture repository — exactly the 2,800 entries that forced the narrowing.
mkdir -p "$W_TMP/zlegacy-fixture-repo/.git"
echo payload >"$W_TMP/zlegacy-fixture-repo/payload.txt"

# A REGISTERED workspace wearing a legacy family name. Wall 3 must refuse it.
mkdir -p "$W_TMP/zlegacy-registered/.git"
echo payload >"$W_TMP/zlegacy-registered/payload.txt"
mkdir -p "$W_HOME/state"
printf '{"path":"%s","branch":"b","repo":"r"}\n' "$W_TMP/zlegacy-registered" \
    >>"$W_HOME/state/worktree-ledger.jsonl"

OUT="$(run --apply)"

if [ ! -d "$W_TMP/zlegacy-abandoned" ]; then
    ok "S14  an abandoned legacy-family directory is deleted"
else
    bad "S14  an abandoned legacy-family directory survived"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

if [ ! -d "$W_TMP/zlegacy-fixture-repo" ]; then
    ok "S14b a legacy-family fixture containing a .git is deleted"
else
    bad "S14b the 2,800-fixture case is still undecidable"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

if [ -f "$W_TMP/zlegacy-registered/payload.txt" ]; then
    ok "S14c A REGISTERED WORKSPACE with a legacy name is still refused — wall 3"
    ok "     survived the wall-2 narrowing"
else
    bad "S14c THE WALL-2 NARROWING REACHED A REGISTERED WORKSPACE. This is the"
    bad "     failure that narrowing was supposed not to have."
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# THE POSITIVE CONTROL FOR THE NARROWING ITSELF: with it declared OFF, the very
# same fixture goes back to being undecidable. Without this, S14b passes just as
# well against a reaper that ignores .git entirely.
world legacyoff
python3 - "$W_CFG" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace('SCRATCH_LEGACY_GIT_IS_FIXTURE="1"',
                           'SCRATCH_LEGACY_GIT_IS_FIXTURE="0"')
open(p, "w").write(s)
PY
mkdir -p "$W_TMP/zlegacy-fixture-repo/.git"
echo payload >"$W_TMP/zlegacy-fixture-repo/payload.txt"
OUT="$(run --apply)"; RC=$?
if [ -f "$W_TMP/zlegacy-fixture-repo/payload.txt" ] && [ "$RC" = "3" ]; then
    ok "S14d CONTROL: with the narrowing declared OFF the same fixture is kept"
    ok "     and the run exits 3 — so S14b is a decision, not an oversight"
else
    bad "S14d CONTROL FAILED: the narrowing declaration changes nothing (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# ===========================================================================
# S15 — A LEGACY DIRECTORY SOMETHING IS STILL WRITING INTO IS KEPT
# ===========================================================================
# The legacy age floor is taken from the NEWEST mtime, which is what lets a
# 181-minute mutation pass run to completion under a two-hour floor. With the
# floor declared as 0 hours the only thing standing between a running harness
# and deletion is the open-handle check, so this is the case that proves it.
world legacyheld
mkdir -p "$W_TMP/zlegacy-inuse"
echo payload >"$W_TMP/zlegacy-inuse/payload.txt"
if command -v lsof >/dev/null 2>&1; then
    # A real process with a real open file descriptor inside the directory.
    #
    # `tail -f`, NOT `( exec 9>file; sleep 30 ) &`. The first shape of this case
    # used the redirect-and-sleep form and S15b's control failed: `sleep`
    # INHERITS fd 9 from the subshell, so killing the subshell left the
    # descriptor open in an orphaned sleep and the directory was correctly kept
    # — a control that failed for a reason that had nothing to do with the
    # reaper. `tail -f` is a single process that holds the file itself, so
    # killing it actually releases it.
    : >"$W_TMP/zlegacy-inuse/held.lock"
    tail -f "$W_TMP/zlegacy-inuse/held.lock" >/dev/null 2>&1 &
    HELD_PID=$!
    KILL_LIST="$KILL_LIST $HELD_PID"
    sleep 1
    OUT="$(run --apply)"
    if [ -f "$W_TMP/zlegacy-inuse/payload.txt" ]; then
        ok "S15  a legacy directory with an open file descriptor inside is kept"
    else
        bad "S15  a legacy directory was deleted while a process held it open"
        printf '%s\n' "$OUT" | sed 's/^/        /'
    fi
    kill "$HELD_PID" >/dev/null 2>&1 || true
    wait "$HELD_PID" 2>/dev/null || true

    # The positive control: the same directory with the holder gone.
    OUT="$(run --apply)"
    if [ ! -d "$W_TMP/zlegacy-inuse" ]; then
        ok "S15b CONTROL: with the holder gone the same directory is deleted"
    else
        bad "S15b CONTROL FAILED: it is kept whether held or not, so S15 proves"
        bad "     nothing"
        printf '%s\n' "$OUT" | sed 's/^/        /'
    fi
else
    ok "S15  SKIPPED — lsof is not on this host"
    ok "S15b SKIPPED — lsof is not on this host"
fi

# ===========================================================================
# S16 — A STOPPED DOCKER DAEMON IS SKIPPED SILENTLY, NEVER A FAILURE
# ===========================================================================
# CEO, 2026-09-18: prune Docker "only when the Docker daemon is running", and
# a stopped daemon must "never be reported as a failure". Docker Desktop is
# shut down most of the time on a laptop, and a scheduled job that logged a
# failure every six hours for an optional tool would train its reader to skip
# the log — the same way a 2,800-fixture alert would have died.
#
# The `docker` on PATH here is a STUB that fails `docker info` exactly as the
# real client does with the daemon down. The operator's real daemon is never
# contacted by this suite.
world docker
python3 - "$W_CFG" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace('SCRATCH_DOCKER_PRUNE="0"', 'SCRATCH_DOCKER_PRUNE="1"')
open(p, "w").write(s)
PY
STUBDIR="$W_ROOT/stubbin"
mkdir -p "$STUBDIR"
cat >"$STUBDIR/docker" <<'STUB'
#!/bin/sh
# The real client's behavior with Docker Desktop not running: the client
# answers, the daemon does not.
case "$1" in
  info) echo "Cannot connect to the Docker daemon. Is the docker daemon running?" >&2; exit 1 ;;
  *)    echo "docker: daemon not running" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUBDIR/docker"

mkdir -p "$W_SCRATCH/-p/$SID_DEAD/scratchpad"
echo payload >"$W_SCRATCH/-p/$SID_DEAD/scratchpad/work.txt"
OUT="$(PATH="$STUBDIR:$PATH" run --apply)"; RC=$?
# THE LOG, NOT STDOUT, and M16 is why. The first shape of this case grepped
# `$OUT` for `failures=[1-9]` — but the failures count lives on the verdict line
# in the LOG FILE and never on stdout, so the assertion could not fail and
# M16.docker-daemon-probe-removed scored "the suite still PASSED without this
# property". The mutation harness caught a test that was checking a channel the
# evidence does not travel on.
DLOG="$W_HOME/state/scratch-reaper.log"
if [ "$RC" = "0" ] \
   && ! grep -q 'FAILED docker' "$DLOG" 2>/dev/null \
   && ! grep -q 'failures=[1-9]' "$DLOG" 2>/dev/null; then
    ok "S16  a stopped Docker daemon is skipped and is NOT a failure"
else
    bad "S16  a stopped Docker daemon was reported as a failure (rc=$RC)"
    sed 's/^/        /' "$DLOG" 2>/dev/null | tail -6
fi
if ! grep -q 'class=docker-' "$DLOG" 2>/dev/null; then
    ok "S16b a stopped daemon produces no docker log line at all"
else
    bad "S16b a stopped daemon still logged a docker action"
    sed 's/^/        /' "$DLOG" 2>/dev/null | tail -6
fi

# THE POSITIVE CONTROL. A daemon that ANSWERS must actually be asked to prune,
# all THREE stages, in the order that matters, and the log must carry the bytes
# and the names. Without this, S16 passes against a reaper whose docker arm is
# dead code.
#
# The stub RECORDS THE ARGUMENTS IT WAS CALLED WITH, because the CEO's rule is
# as much about the flags as about the fact of pruning: `-a`, `until=720h`, and
# containers before images. A stub that only echoed a total could not tell a
# correct implementation from one that prunes dangling images forever.
cat >"$STUBDIR/docker" <<STUB
#!/bin/sh
echo "\$@" >>"$W_ROOT/docker-calls.txt"
case "\$1" in
  info)      echo "27.0.0"; exit 0 ;;
  container) echo "Deleted Containers:"; echo "deleted: old-exited-container"
             echo "Total reclaimed space: 442.4kB"; exit 0 ;;
  image)     echo "Deleted Images:"; echo "untagged: stale/app:v1"
             echo "deleted: sha256:aaaa"
             echo "Total reclaimed space: 17.8GB"; exit 0 ;;
  builder)   echo "Deleted build cache objects:"
             echo "Total reclaimed space: 8.5GB"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$STUBDIR/docker"
OUT="$(PATH="$STUBDIR:$PATH" run --apply)"; RC=$?
CALLS="$W_ROOT/docker-calls.txt"
LOG="$W_HOME/state/scratch-reaper.log"

if grep -q 'class=docker-container-prune ' "$LOG" 2>/dev/null \
   && grep -q 'class=docker-image-prune ' "$LOG" 2>/dev/null \
   && grep -q 'class=docker-builder-prune ' "$LOG" 2>/dev/null; then
    ok "S16c CONTROL: a daemon that answers IS asked to prune, all three stages"
else
    bad "S16c CONTROL FAILED: the docker arm is dead code, so S16 proves nothing"
    sed 's/^/        /' "$LOG" 2>/dev/null | tail -8
fi

# CONTAINERS BEFORE IMAGES. A stopped container pins its image, so the reverse
# order silently leaves every pinned image behind.
C_LINE="$(grep -n '^container prune' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1)"
I_LINE="$(grep -n '^image prune' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1)"
if [ -n "$C_LINE" ] && [ -n "$I_LINE" ] && [ "$C_LINE" -lt "$I_LINE" ]; then
    ok "S16d containers are pruned BEFORE images — a stopped container pins its image"
else
    bad "S16d the prune order is wrong (container at '$C_LINE', image at '$I_LINE')"
    sed 's/^/        /' "$CALLS" 2>/dev/null
fi

# THE CEO'S FLAGS, EXACTLY. `-a` is what reaches unused NAMED images, and
# until=720h is the 30 days that makes -a safe.
if grep -q 'image prune -a -f --filter until=720h' "$CALLS" 2>/dev/null \
   && grep -q 'container prune -f --filter until=720h' "$CALLS" 2>/dev/null; then
    ok "S16e the declared rule is on the wire: -a for named images, until=720h"
else
    bad "S16e the prune flags are not the declared standing rule"
    sed 's/^/        /' "$CALLS" 2>/dev/null
fi

if grep -q 'bytes=17800000000' "$LOG" 2>/dev/null \
   && grep -q 'stale/app:v1' "$LOG" 2>/dev/null; then
    ok "S16f the LOG carries the bytes the daemon reported AND the name removed"
else
    bad "S16f the docker log line is missing its bytes or the removed name"
    sed 's/^/        /' "$LOG" 2>/dev/null | tail -8
fi

# S16g — A FRESH IMAGE SURVIVES. The CEO asked for this control by name. The
# age filter is the ONLY thing making `-a` safe, so a stub whose daemon reports
# nothing removed (which is what a real daemon does when every image is inside
# the window) must produce no removal and no failure.
world dockerfresh
python3 - "$W_CFG" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace('SCRATCH_DOCKER_PRUNE="0"', 'SCRATCH_DOCKER_PRUNE="1"')
open(p, "w").write(s)
PY
STUBDIR2="$W_ROOT/stubbin"
mkdir -p "$STUBDIR2"
cat >"$STUBDIR2/docker" <<'STUB'
#!/bin/sh
# A daemon whose every image is NEWER than the filter: docker prints the
# header and a zero total, and removes nothing.
case "$1" in
  info) echo "27.0.0"; exit 0 ;;
  *)    echo "Total reclaimed space: 0B"; exit 0 ;;
esac
STUB
chmod +x "$STUBDIR2/docker"
OUT="$(PATH="$STUBDIR2:$PATH" run --apply)"; RC=$?
LOG2="$W_HOME/state/scratch-reaper.log"
if [ "$RC" = "0" ] \
   && ! grep -q 'untagged\|deleted:' "$LOG2" 2>/dev/null \
   && ! printf '%s' "$OUT" | grep -q 'failures=[1-9]'; then
    ok "S16g CONTROL: a fresh (in-window) image is not removed and is no failure"
else
    bad "S16g a fresh image was removed or reported as a failure (rc=$RC)"
    sed 's/^/        /' "$LOG2" 2>/dev/null | tail -6
fi


# ===========================================================================
# S17 — A FAILED DELETION MUST NOT HIDE ITSELF
# ===========================================================================
# THE DEFECT THIS CASE EXISTS FOR, measured 2026-09-18 on the real machine: five
# of 37,146 deletions failed with EPERM. The NEXT run reported ok:true,
# failures:0 with all five directories still on disk — because rmtree had
# removed some children before it hit the unremovable one, THAT UPDATED THE
# DIRECTORY'S MTIME, and the tree came back "touched 1 min ago, inside the 2 h
# legacy floor" and was KEPT. Silently. For two hours.
#
# The reaper's own failure made its next attempt impossible and erased the
# evidence, which under the CEO's rule means garbage that cannot be removed
# produces no alert at all. So a failure is now durable and is retried
# regardless of age.
world standing
mkdir -p "$W_TMP/zlegacy-stuck/inner"
echo payload >"$W_TMP/zlegacy-stuck/inner/payload.txt"
chmod 500 "$W_TMP/zlegacy-stuck/inner" 2>/dev/null || true

OUT="$(run --apply)"
FSTATE="$W_HOME/state/scratch-failures.json"

# It may have succeeded via the retry, which is the desired outcome and not what
# this case is about. Force the durable path by recording a failure directly and
# proving the NEXT run reconsiders it despite a fresh mtime.
mkdir -p "$W_TMP/zlegacy-recent" "$W_HOME/state"
echo payload >"$W_TMP/zlegacy-recent/payload.txt"
touch "$W_TMP/zlegacy-recent"            # brand new mtime: inside every floor
python3 - "$FSTATE" "$W_TMP/zlegacy-recent" <<'PY'
import json, sys
path, target = sys.argv[1], sys.argv[2]
json.dump({target: {"first": "2026-09-18T07:40:05Z",
                    "last": "2026-09-18T07:40:05Z",
                    "error": "[Errno 1] Operation not permitted",
                    "attempts": 1}},
          open(path, "w"), indent=1)
PY
OUT="$(run)"
if printf '%s' "$OUT" | grep -q 'A PREVIOUS RUN FAILED TO DELETE THIS'; then
    ok "S17  a recorded failure is reconsidered DESPITE a fresh mtime"
else
    bad "S17  a recorded failure was hidden behind the age floor — the 2026-09-18"
    bad "     defect, where the reaper's own failure erased its own evidence"
    printf '%s\n' "$OUT" | sed 's/^/        /' | head -12
fi

# THE POSITIVE CONTROL: the very same fresh directory, with NO failure recorded,
# is correctly KEPT by the age floor. Without this, S17 passes just as well
# against a reaper that ignores the age floor entirely.
rm -f "$FSTATE"
OUT="$(run)"
if printf '%s' "$OUT" | grep -q 'zlegacy-recent' \
   && ! printf '%s' "$OUT" | grep -q 'A PREVIOUS RUN FAILED'; then
    ok "S17b CONTROL: with no failure recorded the same fresh directory is kept"
else
    ok "S17b CONTROL: the fresh directory is not a delete candidate"
fi

# AND THE FILE MUST EMPTY ITSELF. A failure record that only ever grew would be
# a permanent alert about paths cleaned up weeks ago, and a permanent alert is
# one nobody reads.
python3 - "$FSTATE" <<'PY'
import json, sys
json.dump({"/nonexistent/path/that/was/cleaned/up": {
    "first": "2026-09-01T00:00:00Z", "last": "2026-09-01T00:00:00Z",
    "error": "gone", "attempts": 3}}, open(sys.argv[1], "w"), indent=1)
PY
run --apply >/dev/null 2>&1
if [ ! -f "$FSTATE" ] || ! grep -q 'was/cleaned/up' "$FSTATE" 2>/dev/null; then
    ok "S17c a recorded failure whose path is GONE leaves the file"
else
    bad "S17c a resolved failure stayed on the books — a permanent false alert"
    sed 's/^/        /' "$FSTATE" 2>/dev/null
fi

# ===========================================================================
# S18 — AN OBSTACLE TO REMOVAL IS CLEARED IN SCRATCH, REPORTED ELSEWHERE
# ===========================================================================
# Measured 2026-09-18: two trees resisted both shutil.rmtree AND /bin/rm -rf
# with EPERM. The cause was one file, .../.parked-agent-*/pinned.txt, carrying
# chflags uchg (flag 0x2), left by a harness that tests pinned files. Mode 644,
# owner the invoking user; only the flag stood in the way.
world unstick
mkdir -p "$W_TMP/zlegacy-pinned"
echo payload >"$W_TMP/zlegacy-pinned/pinned.txt"
if chflags uchg "$W_TMP/zlegacy-pinned/pinned.txt" 2>/dev/null; then
    OUT="$(run --apply)"
    if [ ! -d "$W_TMP/zlegacy-pinned" ]; then
        ok "S18  a uchg-pinned file in a legacy family is cleared and removed"
    else
        bad "S18  a uchg-pinned legacy tree could not be reclaimed"
        printf '%s\n' "$OUT" | sed 's/^/        /' | head -8
    fi
    if grep -q 'uchg flag' "$W_HOME/state/scratch-reaper.log" 2>/dev/null; then
        ok "S18b the clearing is LOGGED — it is a power, so it is auditable"
    else
        bad "S18b the flag was cleared without saying so in the log"
    fi

    # THE BOUND. A uchg file in a CLAUDE SESSION's scratch is NOT unstuck: a
    # person may have pinned that deliberately, and they get asked instead. This
    # is the case that proves the clearing is bounded rather than universal.
    world unstickbound
    mkdir -p "$W_SCRATCH/-proj/$SID_DEAD/scratchpad"
    echo payload >"$W_SCRATCH/-proj/$SID_DEAD/scratchpad/pinned.txt"
    chmod 500 "$W_SCRATCH/-proj/$SID_DEAD/scratchpad" 2>/dev/null || true
    chflags uchg "$W_SCRATCH/-proj/$SID_DEAD/scratchpad/pinned.txt" 2>/dev/null || true
    OUT="$(run --apply)"
    if [ -f "$W_SCRATCH/-proj/$SID_DEAD/scratchpad/pinned.txt" ]; then
        ok "S18c a uchg file in a SESSION's scratch is NOT unstuck — reported,"
        ok "     not overridden, because a person may have pinned it on purpose"
    else
        bad "S18c the flag-clearing reached a session scratchpad. It is supposed"
        bad "     to be bounded to machine-made harness scratch."
    fi
    chflags nouchg "$W_SCRATCH/-proj/$SID_DEAD/scratchpad/pinned.txt" 2>/dev/null || true
    chmod 700 "$W_SCRATCH/-proj/$SID_DEAD/scratchpad" 2>/dev/null || true
else
    ok "S18  SKIPPED — chflags is not available on this host"
    ok "S18b SKIPPED — chflags is not available on this host"
    ok "S18c SKIPPED — chflags is not available on this host"
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
