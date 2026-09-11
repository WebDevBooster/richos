#!/usr/bin/env python3
"""ci-run-records.py — match pushes against workflow runs, and name what is missing.

The comparison half of `ci-run-record-check.sh`, separated so it can be tested
against captured payloads with no network and no token. The reasoning it
encodes, once:

  A PUSH IS THE UNIT, NOT A COMMIT. `on: push` fires once per push, against the
  pushed head. Five commits in one push correctly produce one run, so a check
  built on commits reports four false gaps per batch and gets switched off.

  A MISSING RUN IS NOT A FAILED RUN. A run that exists and failed is somebody's
  bug and is visible. A run that never existed is invisible, and every tool that
  reads "the latest run" reports the PREVIOUS commit's verdict in its place.
  That is the case here.

  A PUSH INSIDE THE GRACE WINDOW IS PENDING, NOT MISSING. Its run may not have
  reached the API yet. Named on every run so the tolerance is never invisible.

  NO ANSWER IS NOT A PASS. If the payloads cannot be read, this exits 2 with the
  reason. A run-record check that goes quiet when its sources fail is the defect
  it exists to catch, one level out.
"""
import argparse
import datetime
import json
import sys


def load(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        sys.stderr.write("ci-run-records.py: cannot read %s (%s): %s\n" % (what, path, exc))
        raise SystemExit(2)


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def pushes_from_events(events, branch):
    """(sha, created_at) for every PushEvent onto `branch`, newest first."""
    out = []
    if not isinstance(events, list):
        return out
    want = "refs/heads/%s" % branch
    for ev in events:
        if not isinstance(ev, dict) or ev.get("type") != "PushEvent":
            continue
        payload = ev.get("payload") or {}
        if payload.get("ref") != want:
            continue
        head = payload.get("head")
        if not head:
            continue
        out.append((head, parse_ts(ev.get("created_at"))))
    return out


def runs_index(runs):
    """head_sha -> the newest run for it."""
    index = {}
    items = (runs or {}).get("workflow_runs") if isinstance(runs, dict) else runs
    if not isinstance(items, list):
        return index
    for run in items:
        if not isinstance(run, dict):
            continue
        sha = run.get("head_sha")
        if not sha:
            continue
        prev = index.get(sha)
        if prev is None or str(run.get("created_at") or "") > str(prev.get("created_at") or ""):
            index[sha] = run
    return index


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--events", required=True)
    ap.add_argument("--runs", required=True)
    ap.add_argument("--branch", default="main")
    ap.add_argument("--grace-minutes", type=float, default=20.0)
    ap.add_argument("--source", default="events", choices=("events", "tip"))
    # THE WINDOW HAS A START DATE, AND IT IS DECLARED RATHER THAN INFERRED.
    # This repository has 95 pushes to main with no run, for the entirely
    # correct reason that `push:` was not a trigger when they were made. A
    # check that reported those as dropped runs would be red on its first
    # execution and every one after it, which is how a check gets ignored. So
    # the caller declares the day the trigger was restored; pushes before it
    # are outside the promise and are counted, named in one line, and not
    # failed on. Deriving it from the run history instead would be circular:
    # if every run were dropped there would be no history to derive from.
    ap.add_argument("--since", default="",
                    help="ISO date; pushes before it are outside the watched window")
    ap.add_argument("--tip", default="")
    ap.add_argument("--workflow", default="the workflow")
    ap.add_argument("--repo", default="<repo>")
    args = ap.parse_args(argv)

    runs = runs_index(load(args.runs, "the run list"))
    now = datetime.datetime.now(datetime.timezone.utc)
    cutoff = now - datetime.timedelta(minutes=args.grace_minutes)

    if args.source == "tip":
        if not args.tip:
            sys.stderr.write("ci-run-records.py: --source tip needs --tip <sha>\n")
            return 2
        checked = [(args.tip, None)]
        predicate = ("the branch tip has a run record (the event feed was unreadable, so "
                     "earlier pushes were NOT checked)")
    else:
        events = load(args.events, "the event feed")
        checked = pushes_from_events(events, args.branch)
        predicate = "every push to %s in the event feed has a run record" % args.branch
        if not checked:
            # Zero pushes is not zero problems: it means the feed carried none
            # for this branch, which on an active branch is itself suspicious.
            # Reported, not silently green.
            print("ci-run-record-check: NO pushes to %s were found in the event feed for %s."
                  % (args.branch, args.repo))
            print("  Nothing could be checked. That is not the same as nothing being wrong: on a branch")
            print("  that receives pushes, an empty feed means the feed is the thing that is broken.")
            return 2

    since = parse_ts(args.since + "T00:00:00+00:00") if args.since and "T" not in args.since \
        else parse_ts(args.since)
    if args.since and since is None:
        sys.stderr.write("ci-run-records.py: --since %r is not an ISO date\n" % args.since)
        return 2

    missing = []
    pending = []
    found = []
    before_window = []
    seen = set()
    for sha, when in checked:
        if sha in seen:
            continue
        seen.add(sha)
        if since is not None and when is not None and when < since:
            before_window.append((sha, when))
            continue
        run = runs.get(sha)
        if run is not None:
            found.append((sha, run))
        elif when is not None and when > cutoff:
            pending.append((sha, when))
        else:
            missing.append((sha, when))

    print("ci-run-record-check: %s / %s" % (args.repo, args.workflow))
    print("  predicate: %s" % predicate)
    print("  grace: %g minute(s); %d push(es) examined, %d with a run, %d pending, %d MISSING"
          % (args.grace_minutes, len(seen), len(found), len(pending), len(missing)))
    if before_window:
        print("  %d push(es) predate %s and are outside the watched window — the trigger was not on"
              % (len(before_window), args.since))
        print("     for them, so their absence of a run is correct and is not a finding.")

    for sha, when in pending:
        print("  PENDING  %s (pushed %s — inside the grace window)" % (sha[:12], when))

    if not missing:
        for sha, run in found[:5]:
            print("  ok       %s -> run %s (%s)"
                  % (sha[:12], run.get("id"), run.get("conclusion") or run.get("status")))
        return 0

    sys.stderr.write("\n✗ %d push(es) to %s have NO run of %s at all.\n\n"
                     % (len(missing), args.branch, args.workflow))
    for sha, when in missing:
        sys.stderr.write("    %s   pushed %s\n" % (sha, when if when else "(time unknown)"))
    sys.stderr.write(
        "\n  A MISSING run is not a failing run. Nothing shows a cross for these commits, and any\n"
        "  tool that reads 'the latest run' is reporting an EARLIER commit's verdict for them.\n"
        "  The usual cause is GitHub's account-wide 20-job concurrency limit, which DROPS runs\n"
        "  rather than queueing them.\n\n"
        "  Find out why it was dropped, then give it a run. A workflow_dispatch ref must be a\n"
        "  BRANCH OR TAG, never a bare SHA, so a superseded push cannot be re-dispatched in place:\n"
        "      git push origin <sha>:refs/heads/rerun/<sha8>\n"
        "      gh workflow run %s --repo %s --ref rerun/<sha8>\n"
        "  If the gap is permanent and nothing is at risk, move --since past it AND SAY WHY in\n"
        "  the workflow file; a check red over history nobody can change is a check nobody reads.\n\n"
        % (args.workflow, args.repo))
    return 1


if __name__ == "__main__":
    sys.exit(main())
