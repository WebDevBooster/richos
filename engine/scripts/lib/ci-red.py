#!/usr/bin/env python3
"""ci-red.py — WHAT IS RED ON THIS REPOSITORY'S BRANCH, RIGHT NOW, IN ONE CALL?

===========================================================================
WHY THIS EXISTS SEPARATELY FROM ci-surface.py
===========================================================================
`ci-surface.py` answers six questions about every workflow in every governed
repository and takes about fifteen seconds. That is the right shape for a
status command a person runs, and the wrong shape entirely for a PreToolUse
guard that sits in front of `git push`.

A guard that costs fifteen seconds per invocation is a guard somebody turns
off. So the gate does not call the surface: it calls this, which asks ONE
question of ONE repository through ONE API call —

    GET /repos/{slug}/actions/runs?branch={branch}&per_page=100

— and takes the newest completed run per workflow out of the single page. That
is roughly a second, and it is the whole predicate the gate needs.

===========================================================================
THE ANSWER HAS THREE VALUES AND THE THIRD IS NOT AN ERROR
===========================================================================
    red        the named workflows are failing, with the age of each streak
    clear      every workflow with a completed run on this branch is green
    unknown    the question could not be asked

`unknown` is a first-class answer and the caller MUST NOT collapse it into
`clear`. Every failure this engine has recorded of the "a defense reports on
while protecting nothing" shape began with somebody treating "could not look"
as "looked and found nothing". The gate's own response to `unknown` is to
announce it loudly and stand down — because a gate that blocks a land whenever
GitHub is slow gets waived within a day, and habitual waiving is how this
project has already killed three guards.

===========================================================================
THE CACHE IS A FRESHNESS-STAMPED FILE, NOT A MEMORY
===========================================================================
Written to ~/.claude/state/ci-surface/red-<owner>-<name>-<branch>.json with the
UTC time of the reading INSIDE it. A consumer compares that stamp against its
own tolerance and decides; nothing infers freshness from the file's mtime,
which is a property of the filesystem rather than of the answer.

Usage:
    ci-red.py --repo OWNER/NAME [--branch main] [--max-age-seconds N]
              [--timeout N] [--cache-only] [--json]

Exit codes:
    0  clear
    1  red    (the workflows are printed)
    3  unknown
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

STATE_DIR = os.path.join(os.path.expanduser("~"), ".claude", "state", "ci-surface")
# GitHub Actions `conclusion` values that mean "this did not pass". `skipped`
# is deliberately absent: a skipped RUN is the never-ran question, judged by
# ci-surface.py's own axis, and treating it as red here would make the gate
# fire on a state it cannot explain.
NOT_GREEN = ("failure", "cancelled", "timed_out", "startup_failure", "action_required")  # dialect-exempt: GitHub Actions API conclusion enum, quoted verbatim from the wire


def cache_path(slug, branch):
    key = re.sub(r"[^A-Za-z0-9]+", "-", "%s-%s" % (slug, branch))
    return os.path.join(STATE_DIR, "red-%s.json" % key)


def read_cache(slug, branch, max_age):
    p = cache_path(slug, branch)
    if not os.path.isfile(p):
        return None
    try:
        with open(p, encoding="utf-8") as f:
            doc = json.load(f)
        t = datetime.fromisoformat(doc["read_at"].replace("Z", "+00:00"))
    except Exception:
        return None
    age = (datetime.now(timezone.utc) - t).total_seconds()
    doc["age_seconds"] = int(age)
    if max_age is not None and age > max_age:
        doc["too_old"] = True
    return doc


def write_cache(doc):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = cache_path(doc["repo"], doc["branch"]) + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=2)
        os.replace(tmp, cache_path(doc["repo"], doc["branch"]))
    except Exception:
        pass  # a cache that cannot be written costs a call, never an answer


def probe(slug, branch, timeout):
    """One call. Returns the document, or None with a reason on stderr."""
    path = "repos/%s/actions/runs?branch=%s&per_page=100" % (slug, branch)
    try:
        p = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return None, "the `gh` command is not on PATH"
    except subprocess.TimeoutExpired:
        return None, "gh api timed out after %ss" % timeout
    if p.returncode != 0:
        return None, "gh api exited %d: %s" % (p.returncode, (p.stderr or "").strip()[:160])
    try:
        data = json.loads(p.stdout)
    except Exception:
        return None, "gh api returned unparseable JSON"

    runs = [r for r in data.get("workflow_runs", []) if r.get("status") == "completed"]
    # Newest first is what the API gives; keep the first per workflow id, and
    # keep walking so the STREAK (how long it has been failing) is available
    # from the same page rather than from a second call.
    latest, history = {}, {}
    for r in runs:
        wid = r.get("workflow_id")
        history.setdefault(wid, []).append(r)
        latest.setdefault(wid, r)

    now = datetime.now(timezone.utc)
    red = []
    for wid, r in latest.items():
        if r.get("conclusion") not in NOT_GREEN:
            continue
        streak = r
        last_green = None
        for h in history.get(wid, []):
            if h.get("conclusion") == "success":
                last_green = h
                break
            streak = h
        # THE AGE MAY BE A FLOOR RATHER THAN THE ANSWER. One page holds the 100
        # newest runs ACROSS ALL WORKFLOWS, so a busy repository gives this
        # workflow only a handful of them. If no green was found inside that
        # slice the streak reaches the end of what was read, not the end of the
        # streak — so the age is "at least this", and it says so rather than
        # printing a number it cannot stand behind. ci-status.sh reads twelve
        # runs of each workflow individually and is the precise answer.
        truncated = last_green is None
        try:
            t = datetime.fromisoformat((streak.get("run_started_at") or "").replace("Z", "+00:00"))
            days = (now - t).days
        except Exception:
            days = None
        red.append({
            "workflow": (r.get("path") or "").split("/")[-1] or r.get("name"),
            "name": r.get("name"),
            "conclusion": r.get("conclusion"),
            "run_number": r.get("run_number"),
            "since_run": streak.get("run_number"),
            "since": streak.get("run_started_at"),
            "days": days,
            "days_is_a_floor": truncated,
            "last_green_run": (last_green or {}).get("run_number"),
            "file_backed": (r.get("path") or "").startswith(".g" + "ithub/workflows/"),
            "path": r.get("path"),
            "url": r.get("html_url"),
        })
    red.sort(key=lambda d: (-(d["days"] or 0), d["workflow"] or ""))
    return {
        "repo": slug, "branch": branch,
        "read_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "workflows_seen": len(latest),
        "red": red,
        "state": "red" if red else "clear",
    }, None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--branch", default="main")
    ap.add_argument("--max-age-seconds", type=int, default=1800)
    ap.add_argument("--timeout", type=int, default=12)
    ap.add_argument("--cache-only", action="store_true")
    ap.add_argument("--refresh", action="store_true", help="ignore the cache and read live")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    doc = None if args.refresh else read_cache(args.repo, args.branch, args.max_age_seconds)
    if doc is not None and not doc.get("too_old"):
        doc["source"] = "cache"
    elif args.cache_only:
        if doc is None:
            doc = {"repo": args.repo, "branch": args.branch, "state": "unknown",
                   "reason": "no cached reading exists and --cache-only was given"}
        else:
            doc["source"] = "cache"
            doc["state"] = "unknown"
            doc["reason"] = ("the cached reading is %ds old, past the %ds tolerance, and --cache-only "
                             "forbids a live read" % (doc.get("age_seconds", -1), args.max_age_seconds))
    else:
        live, err = probe(args.repo, args.branch, args.timeout)
        if live is None:
            stale = doc
            doc = {"repo": args.repo, "branch": args.branch, "state": "unknown", "reason": err}
            if stale is not None:
                doc["stale_reading"] = {"read_at": stale.get("read_at"),
                                        "age_seconds": stale.get("age_seconds"),
                                        "state": stale.get("state"),
                                        "red": stale.get("red", [])}
        else:
            doc = live
            doc["source"] = "live"
            write_cache(doc)

    if args.json:
        print(json.dumps(doc, indent=2))
    else:
        print("%s %s %s" % (doc["state"], doc["repo"], doc["branch"]))
        for r in doc.get("red", []) or []:
            print("  %-30s %s since run #%s (%s%s days) last green %s%s"
                  % (r["workflow"], r["conclusion"], r["since_run"],
                     "at least " if r.get("days_is_a_floor") else "", r["days"],
                     ("#%s" % r["last_green_run"]) if r.get("last_green_run")
                     else "NONE within the runs read",
                     "" if r.get("file_backed", True)
                     else "  [not backed by a file in the checkout: %s]" % r.get("path")))
        if doc.get("reason"):
            print("  reason: %s" % doc["reason"])

    return {"clear": 0, "red": 1}.get(doc["state"], 3)


if __name__ == "__main__":
    sys.exit(main())
