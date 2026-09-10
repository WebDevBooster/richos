#!/usr/bin/env bash
#
# ci-latest-on-main.sh — A NAMED, DATED FALLBACK. NOT THE CI CHECK.
#
# ===========================================================================
# READ THIS BEFORE EXTENDING IT
# ===========================================================================
# The real check is scripts/lib/ci-surface.py, which judges every workflow on
# SIX axes — slow, red, skipped, never-run, stale, and green-that-proves-
# nothing — because every one of those has already reached the founder's screen
# before it reached anybody else's. It was being written by another engineer on
# the day the `ci` row of owned-systems.declaration was declared, and it had
# not landed.
#
# This file exists so that the inventory had a TRUE answer that day rather than
# a hole. It implements ONE axis, the cheapest: the latest run of each workflow
# on the branch that lands, and how long since that workflow was last green.
#
# IT IS DECLARED AS A FALLBACK, NOT AS A SECOND IMPLEMENTATION. The `check:`
# line of the `ci` row names ci-surface.py FIRST; this runs only while that file
# is absent, and the report always prints which command answered. WHEN
# ci-surface.py LANDS, THE CORRECT CHANGE IS TO DELETE THE ` :: ` CLAUSE FROM
# THE DECLARATION AND DELETE THIS FILE. No consumer is touched by that, which
# is the whole reason the preference list is data.
#
# Do not add axes here. Adding the second axis is how a stopgap becomes the
# duplicate that drifts.
#
# ===========================================================================
# EXIT CODES
# ===========================================================================
#   0  every workflow with a run on the branch is green
#   1  at least one is red, each named with the age of its last green
#   2  UNKNOWN — gh is absent, unauthenticated, or the repository has no
#      remote this can be asked about. Never 0: an unaskable question and a
#      green answer are not the same thing, and the runner reads 2 as UNKNOWN
#      because the `ci` row declares `unknown-exit: 2`.
#
# Options: --repo <owner/name> (default: the origin of the current checkout)
#          --branch <name>     (default: main)

set -eo pipefail

REPO=""
BRANCH="main"
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)   REPO="${2:-}"; shift 2 ;;
        --branch) BRANCH="${2:-main}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'ci-latest-on-main.sh: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done

command -v gh >/dev/null 2>&1 || { echo "UNKNOWN: gh is not on PATH, so CI cannot be asked about" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "UNKNOWN: python3 is not on PATH" >&2; exit 2; }

if [ -z "$REPO" ]; then
    URL="$(git remote get-url origin 2>/dev/null || true)"
    [ -n "$URL" ] || { echo "UNKNOWN: this checkout has no origin remote" >&2; exit 2; }
    REPO="$(printf '%s' "$URL" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
fi

RUNS="$(gh run list --repo "$REPO" --branch "$BRANCH" --limit 200 \
        --json workflowName,conclusion,createdAt,headSha,status 2>/dev/null || true)"
[ -n "$RUNS" ] || { echo "UNKNOWN: gh returned nothing for $REPO on $BRANCH" >&2; exit 2; }

printf '%s' "$RUNS" | REPO="$REPO" BRANCH="$BRANCH" python3 -c '
import json, os, sys, datetime

try:
    runs = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write("UNKNOWN: the run list could not be parsed: %s\n" % exc)
    sys.exit(2)
if not isinstance(runs, list) or not runs:
    sys.stderr.write("UNKNOWN: no run at all was returned\n")
    sys.exit(2)

now = datetime.datetime.now(datetime.timezone.utc)
def ts(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)

# A RUN STILL IN FLIGHT IS NOT A VERDICT. The first version of this file read
# `conclusion: null` as "not success" and reported a workflow RED while it was
# running — a false red, which is the one defect a red-detector cannot afford:
# it is the fastest way to teach an operator to skim past this output. So the
# judgment is taken from the latest COMPLETED run, and a run in flight is
# mentioned and not counted.
latest, last_green, running = {}, {}, {}
for r in runs:
    wf = r.get("workflowName") or "?"
    when = ts(r["createdAt"])
    if r.get("status") != "completed":
        if wf not in running or when > running[wf]:
            running[wf] = when
        continue
    if wf not in latest or when > latest[wf][0]:
        latest[wf] = (when, r.get("conclusion"), (r.get("headSha") or "")[:9])
    if r.get("conclusion") == "success":
        if wf not in last_green or when > last_green[wf]:
            last_green[wf] = when

red = 0
for wf in sorted(set(list(latest) + list(running))):
    if wf not in latest:
        print("in flight  %s/%s — running now, no completed run on %s in this window"
              % (os.environ["REPO"], wf, os.environ["BRANCH"]))
        continue
    when, concl, sha = latest[wf]
    tail = " (a newer run is in flight)" if wf in running and running[wf] > when else ""
    if concl == "success":
        print("green      %s/%s at %s%s" % (os.environ["REPO"], wf, sha, tail))
        continue
    red += 1
    green = last_green.get(wf)
    age = ("last green %.0f days ago" % ((now - green).total_seconds() / 86400.0)
           if green else "no green run at all in the last %d runs on %s"
           % (len(runs), os.environ["BRANCH"]))
    print("RED        %s/%s on %s — latest completed run %s at %s, %s%s"
          % (os.environ["REPO"], wf, os.environ["BRANCH"], concl or "no conclusion",
             sha, age, tail))
sys.exit(1 if red else 0)
'
