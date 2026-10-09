#!/usr/bin/env python3
"""app_review.py: WHERE THE APP'S SECOND REVIEWS LIVE, AND THE MID-JOB VERDICT A WORKER IS TOLD.

Slice 4 of richos-hq docs/plans/2026-10-09-automatic-second-review-and-t3-ideas.md, with Sage's
check beside it (...-sage-check.md §2 catches 2 and 7, §4 row 4). His words (ruling §113): "A
regular RichOS user can never be expected anything even remotely close to that. So, this all
must be completely automated."

Two readers, one module, so they can never disagree about which ledger holds a worker's
verdicts:
  * review_watch.py in app mode (AppWorld), the host's own child, which starts mid-job reviews
    and writes their verdicts through second-review into app_paths()["ledger"];
  * scripts/app-engine-hook.py, which runs at every tool call of the app's workers and tells a
    worker, once, a changes-requested verdict about its own branch.

Deliberately small and import-light: the hook loads it on a worker's tool calls.
"""

import json
import os
import re

# The triggers of a review made while the work is still running (review_watch.py MID_JOB).
MID_JOB = ("long-job", "quiet")
REVIEW_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
EVIDENCE_CHARS = 600


def app_paths(app_state):
    """Under the app's own engine state, never ~/.claude (plan §2.4: "In the app, the same
    ledger under the app's own data folder")."""
    root = os.path.realpath(app_state)
    return {"watch": os.path.join(root, "review-watch"),
            "reviews": os.path.join(root, "second-review"),
            "ledger": os.path.join(root, "second-review", "reviews.jsonl"),
            "delivered": os.path.join(root, "review-watch", "delivered")}


def _rows(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    rows.append(r)
    except OSError:
        pass
    return rows


def _answer(row):
    try:
        with open(os.path.join(row.get("record") or "", "verdict.json"), encoding="utf-8") as f:
            v = json.load(f)
        return (v.get("answer") or {}) if isinstance(v, dict) else {}
    except (OSError, ValueError, AttributeError):
        return {}


def _flat(text, limit):
    return " ".join(str(text or "").split())[:limit]


def mid_job_notice(app_state, spaces):
    """THE MID-JOB VERDICT, DELIVERED ONCE TO THE WORKER IT IS ABOUT (plan §2.5, "Changes
    requested, mid-job"). `spaces` is [(repository, branch)] of the worker whose tool call this
    is. Every changes-requested mid-job verdict on one of those branches not delivered yet is
    claimed by creating <delivered>/<review id> exclusively, so two tool calls at once deliver
    it once between them. The text to add to the worker's context, or "" when nothing is new.

    A pass is not delivered: it asks nothing of the worker. A handover verdict is not either:
    the worker has ended, and in the app its handover is the coordinator's reviewer's."""
    paths = app_paths(app_state)
    wanted = set((os.path.realpath(r), b) for r, b in spaces if r and b)
    if not wanted or not os.path.isfile(paths["ledger"]):
        return ""
    out = []
    for row in _rows(paths["ledger"]):
        if row.get("trigger") not in MID_JOB or row.get("verdict") != "changes-requested":
            continue
        if (os.path.realpath(row.get("repo") or ""), row.get("branch")) not in wanted:
            continue
        rid = str(row.get("id") or "")
        if not REVIEW_ID.match(rid):
            continue
        os.makedirs(paths["delivered"], mode=0o700, exist_ok=True)
        try:
            os.close(os.open(os.path.join(paths["delivered"], rid), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        except FileExistsError:
            continue
        answer = _answer(row)
        lines = ["A second review of your work so far asked for changes. An independent reviewer read your "
                 "commits up to %s against the user's own words while you work. Nothing was stopped, and your "
                 "work is reviewed again when you hand it over. Its findings:" % str(row.get("tip"))[:12]]
        for f in answer.get("findings") or []:
            lines.append("- P%s %s (%s): %s" % (f.get("priority"), _flat(f.get("title"), 200),
                                                ", ".join(f.get("files") or []), _flat(f.get("evidence"), EVIDENCE_CHARS)))
        if not answer.get("findings"):
            lines.append("- (no itemized finding; the reviewer's summary: %s)" % _flat(answer.get("summary"), EVIDENCE_CHARS))
        lines.append("Fix what applies to the work you have claimed as done, in your own workspace.")
        out.append("\n".join(lines))
    return "\n\n".join(out)
