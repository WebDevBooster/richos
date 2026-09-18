#!/usr/bin/env bash
#
# notice-disk-alert.sh — RICH IS TOLD, AT EVERY SESSION START AND EVERY TURN
#                        END, UNTIL IT CLEARS.
#
# ===========================================================================
# WHAT THIS IS
# ===========================================================================
# CEO, 2026-09-18 (ceo-decisions §54), verbatim: "...if the clean-up fails or
# impossible for some reason, then Rich must get a MASSIVE ALERT about it and get
# on with manually deleting the garbage if it fails to be deleted automatically."
#
# The launchd timer takes the readings and notifies the CEO. THIS is the other
# half — the half that reaches Rich inside the session, where the work happens.
# It reads `disk-watchdog.sh --alert` and says nothing at all when that says
# nothing, which on a healthy machine is always.
#
# Registered on BOTH SessionStart and Stop, and it renders differently on each,
# because the two channels are not the same shape:
#
#   SessionStart — systemMessage + additionalContext, which take a BLOCK. Rich
#                  gets the whole alert: every volume, every stuck path, the top
#                  consumers, the classification and what to do.
#   Stop         — ONE LINE. The host prefixes each line with "Stop says: ", so
#                  a block renders as noise; the turn end gets a summary and
#                  points at the full reading.
#
# ===========================================================================
# WHY THIS ONE DEFEATS THE DE-DUPLICATION EVERY OTHER Stop NOTICE HONORS
# ===========================================================================
# stop-hook-notice.sh exists because "a condition repeated under every turn is a
# condition the eye is trained to skip", and almost every caller is right to
# announce on entry and then go quiet.
#
# THIS CALLER IS THE EXCEPTION AND THE CEO NAMED IT: the alert is "repeated every
# turn until the condition clears". That is an explicit instruction to be
# wallpaper until somebody fixes it, and it is the correct trade for this one
# condition — a disk with 20 GB left does not become less urgent because it was
# mentioned last turn, and the failure mode of going quiet is that the machine
# stops working mid-task.
#
# It is done through stop_notice_abnormal_recurring with a one-second interval
# rather than by bypassing the library, so the announcement is still LEDGERED and
# still visible to everything that audits Stop notices. One second means "every
# turn" in practice, and saying so here is cheaper than a private code path.
#
# ===========================================================================
# IT NEVER BLOCKS AND IT NEVER COSTS A DF
# ===========================================================================
# `--alert` reads the state file the launchd job writes; it takes no reading of
# its own and, critically, never WRITES the state file. A turn end that moved the
# reading forward would destroy the baseline the 20 GB drop arithmetic subtracts
# from, silently turning a 15-minute rate alarm into a per-turn-end one that can
# never see a drop. disk-watchdog.test.sh W14 is that property.
#
# Every exit is 0. A notice that takes the session down with it is worse than no
# notice.

set -uo pipefail

EVENT="SessionStart"
while [ $# -gt 0 ]; do
    case "$1" in
        --event) EVENT="${2:-SessionStart}"; shift ;;
        *)       : ;;
    esac
    shift
done

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HOOK_DIR/.." && pwd)"
WD="$SCRIPTS/disk-watchdog.sh"

[ -x "$WD" ] || exit 0

# stdin is drained on the Stop path because the host writes the payload there and
# a hook that leaves it unread can make the host block. Done unconditionally and
# with a timeout, the way the other notices do it.
PAYLOAD=""
if [ "$EVENT" = "Stop" ]; then
    PAYLOAD="$(timeout 2 cat 2>/dev/null || true)"
fi

BODY="$(bash "$WD" --alert 2>/dev/null || true)"

if [ -z "$BODY" ]; then
    # Nothing wrong. On Stop, tell the ledger the condition has CLEARED, so the
    # next entry into it announces again instead of being de-duplicated against
    # a state that ended hours ago.
    if [ "$EVENT" = "Stop" ] && [ -f "$SCRIPTS/lib/stop-hook-notice.sh" ]; then
        # shellcheck source=../lib/stop-hook-notice.sh
        . "$SCRIPTS/lib/stop-hook-notice.sh" 2>/dev/null || exit 0
        stop_notice_init "notice-disk-alert.sh" "" "$PAYLOAD" 2>/dev/null || exit 0
        stop_notice_normal 2>/dev/null || true
    fi
    exit 0
fi

if [ "$EVENT" = "Stop" ]; then
    [ -f "$SCRIPTS/lib/stop-hook-notice.sh" ] || exit 0
    # shellcheck source=../lib/stop-hook-notice.sh
    . "$SCRIPTS/lib/stop-hook-notice.sh" 2>/dev/null || exit 0
    stop_notice_init "notice-disk-alert.sh" "" "$PAYLOAD" 2>/dev/null || exit 0

    # ONE LINE, assembled from the block. The interesting facts are the volume
    # lines, the stuck-path count and the classification; the "what to do"
    # section is left for SessionStart and for --status.
    SUMMARY="$(printf '%s\n' "$BODY" | python3 -c '
import re, sys
text = sys.stdin.read()
vols, stuck, klass, notinstalled, stopped = [], "", "", False, False
for line in text.splitlines():
    s = line.strip()
    if "NOT INSTALLED" in s:
        notinstalled = True
    if "STOPPED REPORTING" in s:
        stopped = True
    m = re.match(r"^(/\S+) — (.+?) FREE of (\S+ \S+) \(([\d.]+)%\): (.*)$", s)
    if m:
        vols.append("%s %s free (%s%%) — %s" % (m.group(1), m.group(2),
                                                m.group(4), m.group(5)))
    m = re.match(r"^(\d+) GARBAGE PATH\(S\) COULD NOT BE DELETED", s)
    if m:
        stuck = "%s path(s) could not be deleted (delete BY HAND)" % m.group(1)
    if s.startswith("CLASSIFICATION:"):
        klass = s.split(":", 1)[1].strip()
parts = []
if notinstalled:
    parts.append("THE DISK WATCHDOG IS NOT INSTALLED — nothing is watching free space")
if stopped:
    parts.append("THE DISK WATCHDOG HAS STOPPED REPORTING")
parts.extend(vols)
if stuck:
    parts.append(stuck)
if klass:
    parts.append("classification: " + klass)
print(" | ".join(parts) if parts else "disk alert standing")
' 2>/dev/null || echo "disk alert standing")"

    # THE STATE KEY IS THE CONDITION, NOT THE NUMBER. Keying on free bytes would
    # make every reading a new state and defeat the ledger entirely; keying on
    # WHICH conditions hold means the recurrence below is what drives repetition,
    # which is the behavior that was actually asked for.
    KEY="$(printf '%s' "$BODY" | grep -c 'MASSIVE ALERT')"
    stop_notice_abnormal_recurring "disk-alert:$KEY" \
        "MASSIVE ALERT — DISK: $SUMMARY. Full reading: scripts/disk-watchdog.sh --status ; reclaim: scripts/scratch-sweep.sh" \
        1 2>/dev/null || true
    exit 0
fi

# --- SessionStart: the whole block, on both channels ------------------------
# systemMessage for the operator and additionalContext for the model, which is
# the pair session-start-escalations.sh uses. NEVER stderr: measured 2026-09-14
# to reach no channel at all at SessionStart
# (docs/verification/check-census-2026-09-14.md).
BODY="$BODY" python3 -c '
import json, os
body = os.environ.get("BODY", "")
print(json.dumps({
    "systemMessage": body,
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": body,
    },
}))
' 2>/dev/null || true
exit 0
