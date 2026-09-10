#!/usr/bin/env bash
#
# ci-run-record-check.sh — refuse a commit that has NO run record at all.
#
# ===========================================================================
# THE FAILURE THIS EXISTS FOR: ABSENCE READS AS SUCCESS
# ===========================================================================
# Every other check in this engine asks "did the verification pass?". This one
# asks the question nothing else asks: "did the verification HAPPEN?"
#
# They are not the same question, and the difference is not theoretical here.
# GitHub Free allows 20 concurrent jobs ACCOUNT-WIDE — shared, in this account,
# with six other active workflows — and per GitHub's own documentation a run
# that exceeds the limit is DROPPED rather than queued. A dropped run leaves NO
# RECORD: no red cross, no yellow dot, no entry in `gh run list`. It leaves the
# commit exactly as it looked before anyone pushed it.
#
# So every tool that answers "is main green?" by looking up the LATEST run
# answers with the previous commit's result. A dropped run is not reported as a
# failure; it is reported as the last success, forever, and the more shards a
# workflow declares the likelier it is to be the workflow that gets dropped.
# The engine's own workflow spent 2026-08-30 to 2026-09-01 completing in three
# seconds with a billing error, and that at least produced twelve red crosses.
# This failure mode produces nothing to look at.
#
# ===========================================================================
# WHAT IT COMPARES, AND WHY PUSH EVENTS RATHER THAN COMMITS
# ===========================================================================
# A workflow with `on: push` runs once per PUSH, against the pushed HEAD — not
# once per commit. So "every commit has a run" is a FALSE requirement: five
# commits pushed together correctly produce one run, and a check built on the
# commit list would cry wolf on every batch and be switched off within a week.
#
# The exact object is the push. `GET /repos/{owner}/{repo}/events` carries
# PushEvent entries with the head SHA of each push, for public repositories,
# for 90 days. Every push to the watched branch must have a run of the watched
# workflow whose `head_sha` is that push's head. A push with no such run is a
# DROPPED RUN, named with the command that re-dispatches it.
#
# WHEN THE EVENT FEED CANNOT BE READ, the check degrades to a strictly weaker
# but still true predicate — THE BRANCH TIP MUST HAVE A RUN — and says out loud
# which predicate it used. It never degrades to silence: a run-record check that
# cannot read its sources and exits 0 is the very defect it is here to catch.
#
# ===========================================================================
# THE GRACE PERIOD IS NOT A FUDGE
# ===========================================================================
# A push made 30 seconds ago has a run that has not appeared in the API yet.
# Failing on it would make this check red on every run, so a push newer than
# --grace-minutes is reported as PENDING and does not fail. That window is the
# only tolerance here, it is stated on every run, and it is deliberately short:
# the dropped-run failure this catches is permanent, so waiting 20 minutes to
# be sure costs nothing and a longer window buys nothing.
#
# Usage:
#   ci-run-record-check.sh --repo <owner/name> --workflow <file.yml>
#                          [--branch main] [--grace-minutes 20] [--limit 100]
#                          [--since YYYY-MM-DD]
#
#   --since is the day the `push:` trigger was restored. Pushes before it
#   correctly have no run and are counted, named in one line, and not failed
#   on — without it this check is red on its first execution over 95 historical
#   pushes, and a check that is red on arrival is a check nobody reads.
#
#   Offline / testing — every source can be supplied as a file, so the logic is
#   testable without a network and without a token:
#       --events-json <f>   the /events payload
#       --runs-json <f>     the workflow-runs payload
#       --tip <sha>         the branch tip, when events are unavailable
#
# Exit codes:
#   0  every push in the window has a run record (pending ones are named)
#   1  at least one push has NO run record — each is named
#   2  the sources could not be read, so no answer was reached. NEVER silent.
# ===========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO=""; WORKFLOW=""; BRANCH="main"; GRACE=20; LIMIT=100
EVENTS_JSON=""; RUNS_JSON=""; TIP=""; SINCE=""

die() { echo "ERROR: ci-run-record-check.sh: $1" >&2; exit "${2:-2}"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo) [ "$#" -ge 2 ] || die "--repo needs owner/name"; REPO="$2"; shift 2 ;;
        --workflow) [ "$#" -ge 2 ] || die "--workflow needs a file name"; WORKFLOW="$2"; shift 2 ;;
        --branch) [ "$#" -ge 2 ] || die "--branch needs a name"; BRANCH="$2"; shift 2 ;;
        --grace-minutes) [ "$#" -ge 2 ] || die "--grace-minutes needs a number"; GRACE="$2"; shift 2 ;;
        --limit) [ "$#" -ge 2 ] || die "--limit needs a number"; LIMIT="$2"; shift 2 ;;
        --since) [ "$#" -ge 2 ] || die "--since needs an ISO date"; SINCE="$2"; shift 2 ;;
        --events-json) [ "$#" -ge 2 ] || die "--events-json needs a path"; EVENTS_JSON="$2"; shift 2 ;;
        --runs-json) [ "$#" -ge 2 ] || die "--runs-json needs a path"; RUNS_JSON="$2"; shift 2 ;;
        --tip) [ "$#" -ge 2 ] || die "--tip needs a sha"; TIP="$2"; shift 2 ;;
        -h|--help) sed -n '/^# Usage:/,/^# =\{10,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unrecognized argument '$1' — see --help" ;;
    esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-run-record.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- gather ----------------------------------------------------------------
# `gh api` when it is available and authenticated; plain curl with GITHUB_TOKEN
# otherwise, because a scheduled workflow has a token but need not have gh.
api() { # <path> <output-file>
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh api "$1" > "$2" 2>"$WORK/api.err" && return 0
    fi
    if [ -n "${GITHUB_TOKEN:-}" ] && command -v curl >/dev/null 2>&1; then
        curl -sSf -H "Authorization: Bearer $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github+json" \
             "https://api.github.com/$1" > "$2" 2>"$WORK/api.err" && return 0
    fi
    return 1
}

SOURCE="events"
if [ -n "$EVENTS_JSON" ]; then
    [ -f "$EVENTS_JSON" ] || die "--events-json: no such file: $EVENTS_JSON"
    cp "$EVENTS_JSON" "$WORK/events.json"
else
    [ -n "$REPO" ] || die "--repo is required unless --events-json is supplied."
    if ! api "repos/$REPO/events?per_page=$LIMIT" "$WORK/events.json"; then
        SOURCE="tip"
        printf 'NOTE: the event feed could not be read (%s). Falling back to the weaker predicate:\n' \
               "$(head -1 "$WORK/api.err" 2>/dev/null || printf 'no gh, no GITHUB_TOKEN')" >&2
        printf '      the branch tip must have a run. Pushes before it are NOT checked by this run.\n' >&2
    fi
fi

if [ -n "$RUNS_JSON" ]; then
    [ -f "$RUNS_JSON" ] || die "--runs-json: no such file: $RUNS_JSON"
    cp "$RUNS_JSON" "$WORK/runs.json"
else
    [ -n "$REPO" ] || die "--repo is required unless --runs-json is supplied."
    [ -n "$WORKFLOW" ] || die "--workflow is required unless --runs-json is supplied."
    api "repos/$REPO/actions/workflows/$WORKFLOW/runs?per_page=$LIMIT" "$WORK/runs.json" \
        || die "could not read the run list for $WORKFLOW in $REPO. No answer was reached, and this check does not exit 0 without one." 2
fi

if [ "$SOURCE" = "tip" ] && [ -z "$TIP" ]; then
    if api "repos/$REPO/commits/$BRANCH" "$WORK/tip.json"; then
        TIP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sha",""))' "$WORK/tip.json")"
    fi
    [ -n "$TIP" ] || die "neither the event feed nor the branch tip could be read for $REPO@$BRANCH." 2
fi

# --- compare ---------------------------------------------------------------
python3 "$SCRIPT_DIR/lib/ci-run-records.py" \
    --events "$WORK/events.json" \
    --runs "$WORK/runs.json" \
    --branch "$BRANCH" \
    --grace-minutes "$GRACE" \
    --source "$SOURCE" \
    --workflow "${WORKFLOW:-the workflow}" \
    --repo "${REPO:-<repo>}" \
    ${SINCE:+--since "$SINCE"} \
    ${TIP:+--tip "$TIP"}
