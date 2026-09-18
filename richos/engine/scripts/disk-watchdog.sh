#!/usr/bin/env bash
#
# disk-watchdog.sh — THE DISK IS WATCHED WHETHER OR NOT ANYBODY IS LOOKING.
#
# ===========================================================================
# WHY THIS IS A SEPARATE PROGRAM FROM THE SWEEPER
# ===========================================================================
# CEO, 2026-09-18 (ceo-decisions §54 addendum 1), verbatim: "Yeah, a separate
# disk watchdog is needed because the CEO needs to be alerted in case the disk
# storage gets close to running out FOR ANY REASON."
#
# "For any reason" is the whole specification. A watchdog built into the cleanup
# mechanism can only report the free space that mechanism knows about, and the
# disk can fill from a video export, a Time Machine local snapshot, an Xcode
# simulator runtime, or a download — none of which any sweeper will ever see.
# So this program reads `df` and nothing else. It does not call the sweeper, read
# the sweeper's state, or care whether the sweeper has ever run.
#
# ===========================================================================
# ...AND ADDENDUM 2 SAYS IT SHOULD NEVER FIRE
# ===========================================================================
# "But ideally, the disk watchdog will NEVER bark because the RichOS app failed
# to clean up its garbage. The RichOS app must always clean up its garbage
# automatically, no matter what."
#
# So every alert is CLASSIFIED. If the space is going to RichOS's own scratch —
# the allocator root, the declared legacy families, the session scratchpads —
# the alert says "RichOS garbage (DEFECT)", because that is a bug report about
# us and not a disk warning. Anything else says "other". The two want completely
# different responses and an alert that conflated them would get the wrong one.
#
# ===========================================================================
# TWO AUDIENCES, DIFFERENT THRESHOLDS, DIFFERENT CHANNELS
# ===========================================================================
#   RICH   — a MASSIVE ALERT in the session, at every session start and every
#            turn end, below DISK_RICH_ALERT_GB or on a drop of
#            DISK_DROP_ALERT_GB, repeated every turn until it clears. Earliest,
#            because Rich can act without interrupting anybody.
#   THE CEO — a macOS user notification ON THE MACHINE, at DISK_CEO_NOTIFY_GB
#            and again at DISK_CEO_URGENT_GB, at most once a day per level.
#            `osascript -e 'display notification'` needs no app running and no
#            session open, which is exactly why it is the channel: this fires
#            from launchd at 3 AM with nobody logged into anything.
#
# THE DROP THRESHOLD IS THE ONE THAT WOULD HAVE CAUGHT 2026-09-17. 105 GB
# arrived over a few hours while the volume still had 49 GB free — under an
# absolute floor alone the first warning would have come very late. At a
# 15-minute interval, 20 GB between readings is 80 GB/hour, which nothing
# legitimate on this machine does and the mutation harness demonstrably did.
#
# ===========================================================================
# USAGE
# ===========================================================================
#   disk-watchdog.sh                 take a reading, alert if due, update state
#   disk-watchdog.sh --json          the current state, as JSON
#   disk-watchdog.sh --alert         ONLY the alert block, empty if all clear.
#                                    This is what the session hooks call.
#   disk-watchdog.sh --status        one human line per volume
#   disk-watchdog.sh --install       schedule it (launchd, every 15 min)
#   disk-watchdog.sh --uninstall     unschedule it
#   disk-watchdog.sh --installed     exit 0 if scheduled, 1 if not
#
# EXIT CODES
#   0  every watched volume is above every threshold
#   1  an alert condition holds (Rich's threshold, or a drop)
#   2  a declaration is missing, or df could not be read
#
# ===========================================================================
# THE STATE FILE IS THE INTERFACE
# ===========================================================================
# $DISK_STATE_JSON (declared; ~/.claude/state/disk-watchdog.json) carries the
# current reading, the previous one, the alert state and the classification. The
# RichOS app reads it for its timeline line; the session hooks read it so a turn
# end costs one file read rather than a df; and it is what makes "repeated once a
# day" possible at all, since a launchd job has no memory of its last run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${DISK_WATCHDOG_CONFIG:-$ENGINE_ROOT/orchestration.config}"

LABEL="com.richos.disk-watchdog"
LAUNCHD_DIR="${RICHOS_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$LAUNCHD_DIR/$LABEL.plist"

MODE="check"
while [ $# -gt 0 ]; do
    case "$1" in
        --json)      MODE="json" ;;
        --alert)     MODE="alert" ;;
        --status)    MODE="status" ;;
        --install)   MODE="install" ;;
        --uninstall) MODE="uninstall" ;;
        --installed) MODE="installed" ;;
        --check)     MODE="check" ;;
        --help|-h)   sed -n '2,78p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           : ;;
    esac
    shift
done

if [ ! -f "$CONFIG" ]; then
    echo "disk-watchdog: no orchestration.config at $CONFIG — every threshold" >&2
    echo "  this job uses is declared there with the measurement that chose it." >&2
    exit 2
fi
# shellcheck disable=SC1090
. "$CONFIG" >/dev/null 2>&1 || true

STATE="${DISK_STATE_JSON:-$HOME/.claude/state/disk-watchdog.json}"
STATE="${STATE/#\~/$HOME}"
LOG="${DISK_WATCHDOG_LOG:-$HOME/.claude/state/disk-watchdog.log}"

# ---------------------------------------------------------------------------
# --uninstall / --installed / --install
# ---------------------------------------------------------------------------
if [ "$MODE" = "uninstall" ]; then
    if command -v launchctl >/dev/null 2>&1 && [ -z "${RICHOS_LAUNCH_AGENTS_DIR:-}" ]; then
        launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    fi
    rm -f "$PLIST"
    echo "✓ unscheduled $LABEL"
    exit 0
fi

if [ "$MODE" = "installed" ]; then
    [ -f "$PLIST" ] && exit 0
    exit 1
fi

if [ "$MODE" = "install" ]; then
    # NEVER SCHEDULE FROM A LINKED WORKTREE OR A TEMPORARY DIRECTORY. The plist
    # bakes in this script's absolute path; an agent worktree is deleted at land
    # time, and from that moment the job fires on time, every time, and executes
    # nothing. A watchdog that stopped running looks exactly like a disk that
    # never gets low. Same refusal, same words, as scratch-reaper.sh.
    _WT_MARKER="$ENGINE_ROOT/../.g""it"
    if [ -f "$_WT_MARKER" ] || case "$ENGINE_ROOT" in
            /tmp/*|/private/tmp/*|/private/var/folders/*|*/.claude/worktrees/*) true ;;
            *) false ;; esac; then
        {
            echo "REFUSING TO SCHEDULE FROM HERE."
            echo "  engine: $ENGINE_ROOT"
            echo "  This is a linked worktree or a temporary directory. The plist would"
            echo "  bake in a path that stops existing at land time, and the job would go"
            echo "  on firing every 15 minutes against nothing."
            echo "  Install it from the MAIN checkout instead."
        } >&2
        exit 2
    fi
    MINUTES="${DISK_WATCHDOG_MINUTES:-}"
    if [ -z "$MINUTES" ]; then
        echo "disk-watchdog: DISK_WATCHDOG_MINUTES is not declared in $CONFIG." >&2
        exit 2
    fi
    mkdir -p "$LAUNCHD_DIR" "$HOME/.claude/state"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0">'
        echo '<dict>'
        echo "    <key>Label</key><string>$LABEL</string>"
        echo '    <key>ProgramArguments</key>'
        echo '    <array>'
        echo '        <string>/bin/bash</string>'
        echo "        <string>$SCRIPT_DIR/disk-watchdog.sh</string>"
        echo '    </array>'
        # StartInterval, not StartCalendarInterval: this is a RATE alarm, and a
        # rate alarm needs an even gap between readings. A calendar schedule
        # would make the drop threshold mean different things at different times
        # of day.
        echo "    <key>StartInterval</key><integer>$((MINUTES * 60))</integer>"
        echo '    <key>RunAtLoad</key><true/>'
        echo "    <key>StandardOutPath</key><string>$HOME/.claude/state/disk-watchdog.launchd.log</string>"
        echo "    <key>StandardErrorPath</key><string>$HOME/.claude/state/disk-watchdog.launchd.log</string>"
        echo '</dict>'
        echo '</plist>'
    } >"$PLIST"
    if command -v launchctl >/dev/null 2>&1 && [ -z "${RICHOS_LAUNCH_AGENTS_DIR:-}" ]; then
        launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
        launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || \
            launchctl load "$PLIST" >/dev/null 2>&1 || true
    fi
    echo "✓ scheduled $LABEL every $MINUTES minutes"
    echo "  plist: $PLIST"
    exit 0
fi

if [ "${DISK_WATCHDOG_ENABLE:-1}" = "0" ]; then
    [ "$MODE" = "alert" ] || echo "disk-watchdog: STOOD DOWN by DISK_WATCHDOG_ENABLE=0."
    exit 0
fi

# ---------------------------------------------------------------------------
# Everything below is one python program, and that is deliberate.
# ---------------------------------------------------------------------------
# The reading, the drop arithmetic against the previous reading, the
# once-a-day-per-level bookkeeping, the classification and the JSON write are
# ONE atomic read-modify-write of the state file. Split across shell and python
# the file would be read, reasoned about, and written back with a window in the
# middle — and two launchd ticks overlapping (a slow `du` on a loaded machine)
# would each miss the other's notification record and notify the CEO twice.
#
# python3 is not a new dependency: it is what the reaper, the mega-lander and
# the ECS adapters already require, and macOS ships it.
if ! command -v python3 >/dev/null 2>&1; then
    echo "disk-watchdog: python3 is required and is not on PATH" >&2
    exit 2
fi

# EVERY DECLARATION IS EXPORTED, and this is a bug fixed rather than a style.
#
# Sourcing orchestration.config makes these SHELL variables, which a python
# child cannot see. The first run of this program therefore read NONE of its
# declarations — and it looked like it worked, because the fallback for
# DISK_PRIMARY_VOLUME in disk-watchdog.py is the same string the config
# declares, so the primary volume was reported correctly. What gave it away was
# /Volumes/E1TB silently missing from the output: DISK_EXTRA_VOLUMES fell back
# to empty, and an empty list of extra volumes is indistinguishable from a
# volume that is not mounted.
#
# A DEFAULT THAT HAPPENS TO MATCH THE DECLARATION HIDES BROKEN WIRING. That is
# the general lesson and it is why disk-watchdog.test.sh case W1 declares a
# deliberately UNUSUAL threshold and asserts it comes back out of --json: a test
# using the real numbers would pass against a program reading none of them.
export DISK_WATCHDOG_ENABLE DISK_PRIMARY_VOLUME DISK_EXTRA_VOLUMES
export DISK_RICH_ALERT_GB DISK_DROP_ALERT_GB
export DISK_CEO_NOTIFY_GB DISK_CEO_URGENT_GB DISK_CEO_REPEAT_HOURS
export DISK_SCALE_EXTRA_VOLUMES DISK_WATCHDOG_MINUTES
export DISK_CONSUMER_CANDIDATES DISK_STATE_JSON
# Read to classify the shortfall as ours or not, and to report the sweeper's
# standing failures. OBSERVED, never invoked: this job must not depend on the
# sweeper, only look at what it left behind.
export SCRATCH_ROOT_NAME SCRATCH_CLAUDE_ROOTS SCRATCH_FAILURES_STATE

MODE="$MODE" STATE="$STATE" LOG="$LOG" exec python3 "$SCRIPT_DIR/lib/disk-watchdog.py"
