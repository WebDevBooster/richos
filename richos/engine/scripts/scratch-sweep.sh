#!/usr/bin/env bash
#
# scratch-sweep.sh — ONE COMMAND. THE RICHOS APP CLEANS UP AFTER ITSELF.
#
# ===========================================================================
# WHY THIS EXISTS SEPARATELY FROM scratch-reaper.sh
# ===========================================================================
# CEO, 2026-09-18 (ceo-decisions §54 addendum 2): "But ideally, the disk
# watchdog will NEVER bark because the RichOS app failed to clean up its
# garbage. The RichOS app must always clean up its garbage automatically, no
# matter what."
#
# A watchdog that barks about RichOS's own garbage is reporting a DEFECT, not
# doing its job. The app is the thing that made the garbage, so the app is the
# thing that should have removed it — before any timer, any session, or any
# person is involved.
#
# scratch-reaper.sh is an OPERATOR'S tool: it defaults to printing a plan,
# takes flags, installs a launchd job, and prints prose for a human reading it
# at 3 AM. None of that is what an application wants. This is the APPLICATION'S
# entry point onto exactly the same mechanism: one command, one line of JSON,
# safe to call constantly, safe to call concurrently, and it never asks anybody
# anything.
#
# IT IS AN ENTRY POINT AND NOT A SECOND SWEEPER, and that distinction is the
# whole design. Every deletion still goes through scripts/lib/scratch-reaper.py
# — the same four walls, the same three-valued liveness proof, the same ledger,
# the same log, the same mutation harness holding it all down. A second
# implementation would mean two sets of walls to keep in step, and the one that
# nobody was reading would be the one that deleted somebody's work.
#
# ===========================================================================
# THE CONTRACT THE APP CODES AGAINST
# ===========================================================================
#   scripts/scratch-sweep.sh                sweep now. One line of JSON.
#   scripts/scratch-sweep.sh --dry-run      decide, delete nothing. Same JSON.
#   scripts/scratch-sweep.sh --quiet        sweep, print nothing, exit code only.
#
# STDOUT IS EXACTLY ONE LINE OF JSON, always, on every exit path including
# every failure. An app parsing this never has to handle "sometimes prose":
#
#   {"ok":true,"swept":12,"freed_bytes":1802240,"freed_human":"1.7 MB",
#    "undecidable":0,"failures":0,"skipped":false,"reason":"",
#    "engine":"/path/to/engine","log":"/path/to/scratch-reaper.log"}
#
#   ok           false only when something needs a HUMAN. A sweep that decided
#                everything and deleted nothing is ok:true — the common case on
#                a clean machine, and it must not look like a problem.
#   skipped      true when another sweep already held the lock. NOT a failure:
#                the work is being done by the process that holds it.
#   undecidable  entries a live owner or a wall protected. Non-zero is the
#                signal the watchdog turns into an alert.
#   failures     deletions that were attempted and did not work. This is the
#                "clean-up failed" case in the CEO's rule, and it is the one
#                that must reach a person.
#
# EXIT CODES, for a caller that does not want to parse anything:
#   0  swept, or skipped because another sweep holds the lock
#   1  something failed and a human should see it
#   2  the engine or its declarations could not be found
#   3  something was UNDECIDABLE
#
# WHEN THE APP CALLS IT: at boot, whenever an assignment settles, and on quit.
# That wiring belongs to the app engineer; this file is the contract it wires to.
# Calling it every few seconds is harmless — the lock collapses concurrent calls
# and a sweep with nothing to do is one directory listing.
#
# ===========================================================================
# NO SESSION, NO TIMER, NO TERMINAL
# ===========================================================================
# Nothing here reads a session id, a project directory, an entity root, or any
# environment a Claude session sets up; and nothing here depends on the launchd
# job existing. The app can call it with an empty environment. That is the point
# of addendum 2: the backstops (the timer, Rich's session hooks) stay, but they
# are backstops, and the app is not allowed to rely on them.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAPER="$SCRIPT_DIR/scratch-reaper.sh"

APPLY="--apply"
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) APPLY="" ;;
        --apply)   APPLY="--apply" ;;
        --quiet)   QUIET=1 ;;
        --json)    : ;;   # the only output format there is; accepted so a
                          # caller can say it out loud
        --help|-h) sed -n '2,78p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         : ;;   # An unknown flag is IGNORED rather than fatal. This is
                          # called by an application that may be a version ahead
                          # or behind; refusing to sweep because of an argument
                          # nobody understands would mean not sweeping at all,
                          # which is the only outcome worse than sweeping badly.
    esac
    shift
done

# ---------------------------------------------------------------------------
# emit — ONE LINE OF JSON AND NOTHING ELSE, then exit.
# ---------------------------------------------------------------------------
# Every exit path in this file goes through here, which is what makes "stdout is
# always one line of JSON" true rather than aspirational.
emit() { # <exit-code> <ok> <swept> <freed> <freed_human> <undecidable> <failures> <skipped> <reason>
    if [ "$QUIET" = "0" ]; then
        printf '{"ok":%s,"swept":%s,"freed_bytes":%s,"freed_human":"%s","undecidable":%s,"failures":%s,"skipped":%s,"reason":"%s","engine":"%s","log":"%s"}\n' \
            "$2" "$3" "$4" "$5" "$6" "$7" "$8" \
            "$(printf '%s' "$9" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]/ /g')" \
            "$ENGINE_ROOT" "${LOGPATH:-}"
    fi
    exit "$1"
}

if [ ! -x "$REAPER" ]; then
    emit 2 false 0 0 "0 B" 0 0 false "no scratch-reaper.sh at $REAPER"
fi

LOGPATH="${SCRATCH_REAPER_LOG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/scratch-reaper.log}"

# Noted BEFORE the sweep, so the numbers reported afterwards can be read from
# only the bytes this run appended. See the note above the FAILURES block.
LOG_SIZE_BEFORE=0
if [ -f "$LOGPATH" ]; then
    LOG_SIZE_BEFORE="$(wc -c <"$LOGPATH" 2>/dev/null | tr -d ' ')"
    [ -n "$LOG_SIZE_BEFORE" ] || LOG_SIZE_BEFORE=0
fi

# ---------------------------------------------------------------------------
# THE LOCK — so the app may call this as often as it likes
# ---------------------------------------------------------------------------
# The app is told to call this at boot, at every settle and on quit, so two
# calls overlapping is the normal case and not an edge. Two sweeps racing would
# each measure a tree the other is deleting and report failures for paths that
# had in fact just been removed by its sibling — a log full of alarms about
# success.
#
# flock(2) VIA PYTHON, which is what the machine already has: macOS ships no
# flock(1). A lock FILE with a pid in it would be the wrong thing here, because
# it survives a kill -9 and then nothing ever sweeps again — the exact shape of
# failure this whole body of work exists to remove.
#
# A LOCK THIS CANNOT TAKE IS NOT AN ERROR. Somebody else is doing the work.
LOCKFILE="${TMPDIR:-/tmp}/richos-scratch-sweep.lock"
LOCKED=0
if command -v python3 >/dev/null 2>&1; then
    python3 - "$LOCKFILE" <<'PY' >/dev/null 2>&1
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(9)                     # held by another sweep
sys.exit(0)
PY
    [ $? -eq 9 ] && LOCKED=1
fi
if [ "$LOCKED" = "1" ]; then
    emit 0 true 0 0 "0 B" 0 0 true "another sweep holds the lock and is doing this work"
fi

# The lock above proved it was takeable and then dropped it when that python
# exited, which is a race this deliberately does not try to close with shell
# alone. The sweep itself runs UNDER the lock, held by the python that wraps it,
# so the window is inside one process rather than between two.
OUT=""
RC=0
if command -v python3 >/dev/null 2>&1; then
    OUT="$(python3 - "$LOCKFILE" "$REAPER" $APPLY <<'PY'
import fcntl, os, subprocess, sys
lock, reaper = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(9)
r = subprocess.run(["bash", reaper] + args, capture_output=True, text=True)
sys.stdout.write(r.stdout)
sys.stderr.write(r.stderr)
sys.exit(r.returncode)
PY
    )"; RC=$?
else
    OUT="$(bash "$REAPER" $APPLY 2>&1)"; RC=$?
fi

if [ "$RC" = "9" ]; then
    emit 0 true 0 0 "0 B" 0 0 true "another sweep took the lock first"
fi

# ---------------------------------------------------------------------------
# read the reaper's own verdict rather than inventing one
# ---------------------------------------------------------------------------
# `applied: deleted=N freed=X log=...` and
# `verdict: ... undecidable=N` are the reaper's words. Parsing them keeps ONE
# source of truth for what happened; recomputing it here would let the two
# disagree, and the log would be the only place anybody could tell which was
# lying.
SWEPT="$(printf '%s' "$OUT" | sed -n 's/.*applied: deleted=\([0-9]*\).*/\1/p' | tail -1)"
FREED_H="$(printf '%s' "$OUT" | sed -n 's/.*applied: deleted=[0-9]* freed=\([^ ]* [A-Za-z]*\) .*/\1/p' | tail -1)"
UNDEC="$(printf '%s' "$OUT" | sed -n 's/.*verdict:.* undecidable=\([0-9]*\).*/\1/p' | tail -1)"
[ -n "$SWEPT" ]  || SWEPT=0
[ -n "$UNDEC" ]  || UNDEC=0
[ -n "$FREED_H" ] || FREED_H="0 B"

# ---------------------------------------------------------------------------
# FAILURES AND FREED BYTES COME FROM THE LINES *THIS RUN* APPENDED
# ---------------------------------------------------------------------------
# Failures come from the LOG rather than from the exit code, because a run can
# delete 900 things, fail on one, and still be worth reporting as mostly-fine
# with one thing for a person.
#
# BUT ONLY THIS RUN'S LINES COUNT, and the first version of this got it wrong in
# a way worth recording: it read `tail -40` of the log unconditionally, so a
# --dry-run — which appends nothing at all — reported `freed_bytes:159744`
# copied from the previous --apply. A number lifted from an earlier run and
# presented as this one's result is the stale-artifact failure this project has
# a whole freshness contract about, and it would have been reported to the app
# as space that had just come back.
#
# So the log's length is noted BEFORE the sweep and only bytes beyond that
# offset are read. A dry run therefore reports zero freed and zero failures,
# because a dry run freed nothing and attempted nothing — which is true.
FAILURES=0
FREED_B=0
if [ -n "$APPLY" ] && [ -f "$LOGPATH" ]; then
    NEWLINES="$(tail -c "+$((LOG_SIZE_BEFORE + 1))" "$LOGPATH" 2>/dev/null)"
    F="$(printf '%s' "$NEWLINES" | sed -n 's/.*verdict:.* failures=\([0-9]*\).*/\1/p' | tail -1)"
    [ -n "$F" ] && FAILURES="$F"
    B="$(printf '%s' "$NEWLINES" | sed -n 's/.*verdict: deleted=[0-9]* freed=\([0-9]*\) .*/\1/p' | tail -1)"
    [ -n "$B" ] && FREED_B="$B"
fi

OK=true
REASON=""
EXIT=0
if [ "$RC" = "2" ]; then
    OK=false; EXIT=2
    REASON="the reaper refused: a threshold is not declared or its liveness primitive is missing"
elif [ "${FAILURES:-0}" -gt 0 ] 2>/dev/null; then
    OK=false; EXIT=1
    REASON="$FAILURES deletion(s) FAILED — this is the CEO rule's clean-up-failed case and needs a person"
elif [ "$RC" = "3" ] || [ "${UNDEC:-0}" -gt 0 ] 2>/dev/null; then
    # NOT ok:false. Undecidable means a live owner or a wall protected
    # something, which is the mechanism working. It is reported so the watchdog
    # can decide, and it sets exit 3 so a caller that only reads exit codes is
    # not told everything was decided when it was not.
    EXIT=3
    REASON="$UNDEC entr(ies) undecidable — a live owner or a wall protected them"
fi

emit "$EXIT" "$OK" "${SWEPT:-0}" "${FREED_B:-0}" "$FREED_H" "${UNDEC:-0}" \
     "${FAILURES:-0}" false "$REASON"
