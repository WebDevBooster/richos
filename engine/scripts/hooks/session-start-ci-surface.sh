#!/usr/bin/env bash
#
# session-start-ci-surface.sh — SessionStart notice. Never blocks.
#
# ===========================================================================
# WHAT THIS IS FOR, AND WHAT IT IS DELIBERATELY NOT
# ===========================================================================
# The gate (guard-ci-red-lands.sh) makes red cost something at the land. The
# watch (ci-surface-watch.sh) reads the whole surface unattended. Neither of
# them puts a single word in front of a person, so on a machine where nobody
# lands anything for a week, both work perfectly and nobody learns anything.
#
# This is the third leg. It is a NOTICE, it blocks nothing, and it is narrow on
# purpose, because a session-start banner that says something every time is a
# banner people stop reading — and this engine already carries eight of them.
#
# IT SAYS NOTHING AT ALL unless one of exactly two things is true:
#
#   1. RED IS STANDING in a governed repository, with the age of each streak.
#      Red for thirteen days is the fact that started all of this, and an age
#      is what makes it obviously wrong rather than merely present.
#
#   2. THE UNATTENDED WATCH IS NOT WORKING — it reported `degraded` or
#      `ineffective`, or it has not run at all, or it is not installed. This is
#      the "who watches the watchman" leg and it is the one most likely to
#      matter: a scheduled job that quietly stops is indistinguishable from a
#      clean surface, and the job this whole subsystem is modeled against has
#      been firing daily and reclaiming nothing for weeks.
#
# The other five axes are NOT in this notice. They are real, they are reported
# in full by `ci-status.sh`, and putting forty UNDECLARED lines on a session
# banner would guarantee nobody reads the two lines that matter today.
#
# ===========================================================================
# IT READS THE CACHE AND NEVER THE NETWORK
# ===========================================================================
# A SessionStart hook that makes API calls adds seconds to the start of every
# session, and a slow start is how a notice gets removed. Everything here comes
# off files the watch already wrote. If those files are absent or stale, THAT
# IS THE FINDING and it says so — the absence of a reading is exactly what
# case 2 is about.

set -uo pipefail

STATE_DIR="${CI_SURFACE_STATE_DIR:-$HOME/.claude/state/ci-surface}"
command -v python3 >/dev/null 2>&1 || exit 0

NOTICE="$(STATE_DIR="$STATE_DIR" python3 - <<'PY' 2>/dev/null || true
import glob, json, os, sys
from datetime import datetime, timezone

state_dir = os.environ["STATE_DIR"]
lines = []

# --- 2. is the watch working? ----------------------------------------------
watch_state = os.path.join(state_dir, "watch-state.json")
plist = os.path.expanduser("~/Library/LaunchAgents/com.richos.ci-surface-watch.plist")
if not os.path.exists(plist):
    lines.append("the unattended CI watch is NOT INSTALLED on this machine, so nothing reads the "
                 "workflow surface unless somebody chooses to. Install it from the MAIN checkout: "
                 "<main>/engine/scripts/ci-surface-watch.sh --install")
else:
    try:
        with open(watch_state, encoding="utf-8") as f:
            st = json.load(f)
        t = datetime.fromisoformat(st["last_pass"].replace("Z", "+00:00"))
        hours = (datetime.now(timezone.utc) - t).total_seconds() / 3600.0
        if st.get("last_verdict") != "effective":
            lines.append("the unattended CI watch last reported `%s`, not effective — it ran and it "
                         "did not work. Read why: tail -1 %s/watch.log"
                         % (st.get("last_verdict"), state_dir))
        elif hours > 14:
            lines.append("the unattended CI watch has not completed a pass in %.0f hours (it is "
                         "scheduled three times a day). A scheduled job that quietly stopped looks "
                         "exactly like a clean surface." % hours)
    except Exception:
        lines.append("the unattended CI watch is installed but has left NO state behind, so it has "
                     "either never completed a pass or cannot write to %s. Either way nothing is "
                     "being read." % state_dir)

# --- 1. is anything red? ---------------------------------------------------
red_rows, unread = [], []
for p in sorted(glob.glob(os.path.join(state_dir, "red-*.json"))):
    try:
        with open(p, encoding="utf-8") as f:
            doc = json.load(f)
    except Exception:
        continue
    if doc.get("state") == "red":
        for r in doc.get("red", []):
            red_rows.append((doc["repo"], r))
    elif doc.get("state") not in ("clear",):
        unread.append(doc.get("repo", os.path.basename(p)))

if red_rows:
    # Oldest first: the age is the argument. A workflow red for fifty days is a
    # different statement from one red since this morning, and sorting by age
    # puts the indefensible ones where the eye lands.
    red_rows.sort(key=lambda t: -((t[1].get("days") or 0)))
    # THE CAP IS ANNOUNCED WHENEVER IT BITES. The first version showed eight
    # and printed the count as eleven, so three red workflows — all of them in
    # the repository the reader was most likely to care about — were dropped
    # between a number and a list that disagreed with it. A truncation nobody
    # is told about is the same object as a scanner reporting clean over a
    # corpus it did not finish reading.
    CAP = 12
    lines.append("CI IS RED — %d workflow(s)%s:"
                 % (len(red_rows),
                    ", oldest first" if len(red_rows) <= CAP
                    else ", the %d oldest of them shown here" % CAP))
    for repo, r in red_rows[:CAP]:
        lines.append("    %-24s %-26s %s%s day(s), since run #%s"
                     % (repo, r.get("workflow"),
                        "at least " if r.get("days_is_a_floor") else "",
                        r.get("days"), r.get("since_run")))
    if len(red_rows) > CAP:
        lines.append("    ... and %d more, all of them in ci-status.sh" % (len(red_rows) - CAP))
if unread:
    lines.append("%d repositor(y/ies) could not be read at all: %s — not clear, UNREAD"
                 % (len(unread), ", ".join(sorted(set(unread)))))

if lines:
    print("\n".join(lines))
PY
)"

[ -n "$NOTICE" ] || exit 0

{
    echo "=== CI SURFACE ==="
    printf '%s\n' "$NOTICE" | sed 's/^/  /'
    echo "  Everything, on all six axes, in one command:  engine/scripts/ci-status.sh"
} >&2
exit 0
