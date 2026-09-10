#!/usr/bin/env python3
"""land-disposition.py -- FINISHED WORK IS LANDED, OR IT IS HELD FOR A WRITTEN
                          REASON. THERE IS NO THIRD STATE.

===========================================================================
THE DEFECT, IN THE CEO'S OWN MODEL
===========================================================================
He put the lifecycle as two events:

    1. an agent is spawned      -> a workspace is registered
    2. the work is landed       -> the workspace is deleted

Event 2 has TWO HALVES, and only the second half is built. The reclamation lane
implements "delete what is landed" and implements it correctly: it runs
`merge-base --is-ancestor <tip> main` and returns `hold` when that fails, so an
unmerged branch is never touched. That refusal is right and this file does not
weaken it by one line.

NOTHING IMPLEMENTS OR ENFORCES THE FIRST HALF. Landing is manual and depends on
the orchestrator's attention. When that attention fails, the workspace enters
`hold` and stays there SILENTLY AND WITHOUT BOUND. There is no deadline, no
demand, and nobody it belongs to.

On 2026-09-10 that is exactly what happened: five finished agents, five held
workspaces, no land. The CEO found them by looking at the branch list in his own
IDE -- one of them `echo-opus-win1`, seven commits, the off-screen-window fix he
had already asked about twice.

    AN UNBOUNDED SILENT HOLD IS A DEFECT WITH NO OWNER AND NO CLOCK.

===========================================================================
WHAT THIS ADDS: A DISPOSITION, NOT AN ALARM
===========================================================================
The first attempt at this was a louder notice, and it was the wrong fix -- an
alarm about a hold does not give the hold an owner. What is missing is a
REQUIREMENT ON THE WORK ITSELF. For every piece of finished work, exactly one of
these must be true AND RECORDED, and absence is not one of them:

    LANDED    the branch is an ancestor of main. Proved, never asserted:
              `merge-base --is-ancestor`. Nothing further is owed -- the
              existing reclamation takes it from there.

    HELD, WITH A STATED REASON  a durable record naming WHY this work is not
              landed and what would change that: a conflict that needs
              judgment, a decision that is the CEO's, superseded, abandoned.
              A written string, authored by a person. Not a state.

    NOTHING ELSE. Finished, not landed, no reason written down is THE DEFECT,
              and it is the thing that has to stop being possible to leave
              lying around.

The disposition attaches to the WORK -- the branch and the repository it lives
in -- and not to a turn, a session or an agent. So it survives restarts, and it
does not depend on anybody being present when it is written or when it is read.

===========================================================================
THE SUBSTRATE IS THE ESCALATION LEDGER, AND WHY NOT A NEW ONE
===========================================================================
    ~/.claude/state/escalations.jsonl

Nothing new is invented. That ledger already has every property this needs and
its own header argues against a second one in the same breath -- "two ledgers
written by one writer and read by nobody is how the waiver count reached 251".

  * It lives OUTSIDE every repository, worktree and session directory, so a
    demand about a branch survives the session that raised it and the branch
    never having been merged. That is the same reason it exists at all.
  * IT ALREADY GETS LOUDER. An outstanding escalation crosses age buckets at
    1 hour, 24 hours and 72 hours, and every crossing is a state change the
    turn-end notice announces again. A demand nobody answers does not fade.
  * It is already read by TWO checks that do not depend on anyone looking:
    session-start-escalations.sh at every session start, notice-escalations.sh
    at every turn end.
  * `escalate.sh ack <id> --disposition "<at least 30 characters>"` IS the
    "held with a stated reason" record, already built, already refusing an
    acknowledgement with nothing in it -- "a dismissal wearing a ledger row".
  * Its row schema ALREADY carries `repo`, `branch` and `head`. Work-bound
    escalations were anticipated; this is the first thing to use them.
  * `state: work-complete` already means "the work is DONE and this is a record,
    NOT a stall", which is precisely what an unlanded finished branch is.

===========================================================================
AUTO-SATISFACTION IS THE PART THAT KEEPS THIS ALIVE
===========================================================================
A demand that has to be acknowledged BY HAND for every branch that later lands
is a demand that gets acknowledged reflexively, and a check that is waived by
reflex is dead -- three of them (`g11`, `g12`, `g13`) died that way here in a
single day.

So a demand closes ITSELF the moment its work lands. Every demand records the
branch TIP it was raised about, and satisfaction is
`merge-base --is-ancestor <tip> main` -- against the TIP OBJECT, never the ref,
so it still answers after the branch has been deleted by the reclamation lane.
The ack it writes is a fact with a SHA in it, not an opinion:

    "LANDED: tip <sha> is an ancestor of main at <sha> ... closed by
     land-disposition.py, which established it rather than being told it."

And when the tip object is GONE -- garbage collected, or a branch deleted
before it landed -- the demand is NOT closed and NOT quietly dropped. It is
reported as UNDECIDED, by name, because a checker that could not look has found
nothing and proved nothing (R5).

===========================================================================
THE THRESHOLD, AND WHY THERE IS ONE AT ALL
===========================================================================
A demand raised the instant an agent finishes would raise one for every branch
on the machine -- around seven a day, twenty on a busy one -- almost all of them
landing within minutes and auto-closing. Twenty raise/close pairs a day into a
ledger whose real volume is two a week would destroy the signal of the lane it
is borrowing. So a demand waits.

HOW LONG IS MEASURED, by `scripts/land-disposition-measure.py`, which is the
derivation rather than a note about one -- re-run it and get today's answer.
Against 1114 teammate landings across five repositories the standing time is
p50 0.025 h, p90 0.523 h, p95 1.338 h, and the entire upper tail above one hour
is:

    1.01 1.03 1.09 1.25 1.69 1.70 2.10 2.29 2.63 2.92 | 3.95 5.63 6.90 6.93
    12.45 44.61 47.44

    THE DEFAULT IS 3 HOURS: the only whole hour between the longest landing
    that was followed by a land in the same working session (2.92 h, richos
    zach-opus-ob1) and the shortest of the branches the CEO found in his IDE
    (3.95 h, richos echo-opus-win1).

Both endpoints are OBSERVED VALUES and the choice between them is named as a
judgment rather than dressed as a rule. The measuring script deliberately
proposes NOTHING: the rule that used to answered 44 hours against this same
corpus, because p99 is 9.36 h and the tail above it is made entirely of
strandings, so the widest gap in it is the gap between two of them. The tail of
the landing history IS the defect the threshold is meant to catch, which is why
no rule over that history alone can find the edge, and why any rule that
produces the right answer here was tuned until it did.

At 3 hours, 7 of those 1114 landings would have carried a demand (0.628%), and
six of the seven are strandings on the record -- the five of 2026-09-10 and a
Reed brief written 2026-08-31 that reached main on 2026-09-02. The seventh, an
ECS README at 5.63 h, is arguable. Nothing here reclassifies any of them to
reach a prettier number.

===========================================================================
WHAT IS NEVER DEMANDED, AND WHY EACH ONE IS A DECISION
===========================================================================
LIVE WORK. A branch a live worktree holds is work in progress, not a hold. The
liveness rule is inherited whole from unlanded-branches.py, which reads the same
evidence the reaper is required to use -- the lock, never a roster.

YOUNG WORK. Under the threshold, nothing is said. This is the legitimate case
and it is most of them: a land in progress, a turn ending to ask the CEO a
question, an agent still writing its last commit.

`codex/` BRANCHES. Named in the report, NEVER demanded on, and never the reason
anything is refused. They are the CEO's by permanent ruling
(`richos-hq/wiki/ceo-decisions.md` 31) and their disposition is therefore
already stated: they are his to land or not. Demanding one every turn would be
re-asking a question the record has already answered, which is a failure this
project has recorded under its own name. The report says that in those words
rather than staying silent about them -- silence would be indistinguishable
from not having looked.

===========================================================================
WHAT THIS NEVER DOES
===========================================================================
IT NEVER SWEEPS, DELETES, MERGES OR MOVES ANYTHING. Its entire write surface is
one append to one JSONL file. It runs `merge-base`, `rev-parse`, `for-each-ref`,
`worktree list` and `cat-file` -- readers, all of them. An unmerged branch is
untouched by construction and land-disposition.test.sh asserts that
mechanically, by refusing the presence of a mutating git verb in this file,
rather than by anyone remembering.

IT NEVER BLOCKS A TURN. `land-completeness-2026-09-10.md` R6 requires anything
blocking to be measured against real turns first, and the measurement above
argues the other way: the escalation ledger ALREADY escalates, so a block would
add refusals without adding pressure. R7 is satisfied for free -- the recovery
path (`escalate.sh ack`) does not run through anything this could break.

===========================================================================
OUTPUT
===========================================================================
--format json (default) | text | hook | line. `--demand` is the only mode that
writes; without it this is strictly a report, which is how it should be run by
hand while reading.

THE EXIT CODE MEANS THE SAME THING IN EVERY FORMAT, deliberately: 0 nothing is
owed, 3 something is owed, 4 nothing could be examined. A caller that wants the
verdict never has to parse the report, and the report and the code can never
disagree because they are produced from one sweep. 4 is not 0 for the reason
this whole file exists -- an unexamined main and a clean one must not share an
answer.
"""

import argparse
import json
import os
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# Loaded by path rather than by name: this directory is not a package and the
# two siblings are the analysis this file is built on top of. A failure to load
# either is REPORTED, never worked around -- a disposition check that silently
# lost its finding source would report an empty world as a clean one.
_IMPORT_ERROR = ""
try:
    import importlib.util as _ilu

    def _load(modname, filename):
        spec = _ilu.spec_from_file_location(modname, os.path.join(_HERE, filename))
        mod = _ilu.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    unlanded = _load("_ld_unlanded", "unlanded-branches.py")
    escalations = _load("_ld_escalations", "escalations.py")
except Exception as exc:  # pragma: no cover - exercised by the test suite
    unlanded = None
    escalations = None
    _IMPORT_ERROR = "%s: %s" % (type(exc).__name__, exc)

# The kind marker that makes a demand distinguishable from a teammate's own
# escalation in the shared ledger. Readers that do not know about it are
# unaffected: every escalations.py reader uses .get() and ignores extra keys.
KIND = "land-disposition"

DEFAULT_DEMAND_HOURS = 3.0

# Six is where one line stops being readable; the rest are counted, never lost.
# Same number and same reason as unlanded-branches.py and notice-unstarted-rows.
MAX_NAMED = 6

# A ceiling on writes per invocation. Not a rate limit for its own sake: this
# runs from a turn-end hook, and a bug that raised one demand per branch per
# turn would fill the ledger it is borrowing before anybody noticed. Six is the
# most that can be named in one line anyway, so a seventh raise this turn would
# be a row nothing announced.
MAX_RAISES_PER_RUN = 6

CEO_OWNED_PREFIXES = ("codex/",)


def git(root, args, timeout=20):
    """stdout of a READ-ONLY git call, or None. See the header: this module has
    no mutating git verb in it and the test suite refuses one."""
    try:
        res = subprocess.run(["git", "-C", root] + list(args),
                             capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None
    if res.returncode != 0:
        return None
    return res.stdout


def is_ancestor(repo, tip, trunk):
    """True / False / None. None means UNDECIDED and is never rounded to False.

    Answered against the TIP OBJECT rather than a ref, so it still answers
    after the reclamation lane has deleted the branch that pointed at it.
    """
    if not tip:
        return None
    if git(repo, ["cat-file", "-e", tip + "^{commit}"]) is None:
        return None
    try:
        res = subprocess.run(
            ["git", "-C", repo, "merge-base", "--is-ancestor", tip, trunk],
            capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    if res.returncode == 0:
        return True
    if res.returncode == 1:
        return False
    return None


def trunk_sha(repo, trunk):
    out = git(repo, ["rev-parse", "--verify", "--quiet", trunk])
    return out.strip() if out else ""


def ceo_owned(branch):
    return any(branch.startswith(p) for p in CEO_OWNED_PREFIXES)


def demands(rows):
    """Every land-disposition demand ever raised, newest last."""
    return [r for r in rows
            if r.get("event") == "Escalation" and r.get("kind") == KIND]


def acked_ids(rows):
    return set(str(r.get("id")) for r in rows
               if r.get("event") == "EscalationAck" and r.get("id"))


def ack_for(rows, rid):
    """The first acknowledgement of an id, or None. The first is the one that
    settled it; later ones are additions to a decision already made."""
    for r in rows:
        if r.get("event") == "EscalationAck" and str(r.get("id")) == str(rid):
            return r
    return None


def _demand_row(repo, branch, tip, teammate, worktree, age_hours, commits,
                session_id, now=None):
    """The ledger row. Built here rather than through escalations.build_row so
    the `kind`, `repo`, `branch` and `head` fields are all set on one object and
    the shape is readable in one place."""
    when = now or escalations.utcnow()
    title = ("Finished work is neither landed nor held for a reason: %s %s"
             % (os.path.basename(repo), branch))
    # THE ID IS DERIVED FROM THE WORK, NOT FROM WHO RAISED IT.
    #
    # escalations.make_id hashes (teammate, title, worktree) and prefixes a
    # one-second timestamp, which is right for a teammate raising a question and
    # WRONG here: two demands about the same branch at two different tips share
    # all three inputs, so when they are raised inside the same second they get
    # THE SAME ID. Then one acknowledgement closes both, and the ledger cannot
    # say which tip was disposed of.
    #
    # That is not hypothetical -- land-disposition.test.sh D22 reproduced it on
    # the first run, two rows, identical ids, different heads. So the tip goes
    # into the hash: identity here is (repository, branch, tip), which is
    # exactly the thing a disposition is about.
    ident = escalations.make_id(when, os.path.realpath(repo), branch, tip)
    row = {
        "event": "Escalation",
        "kind": KIND,
        "id": ident,
        "raised": escalations.iso(when),
        "teammate": teammate or "",
        "worktree": worktree or "",
        "branch": branch,
        "repo": repo,
        "head": tip,
        "state": "work-complete",
        "for": "lead",
        "title": title,
        "question": (
            "Land %s (%d commit%s, standing %.1fh, nothing live holds it), or "
            "acknowledge this with the REASON it is held and what would change "
            "that: `escalate.sh ack <id> --disposition \"...\"`."
            % (branch, commits, "" if commits == 1 else "s", age_hours)),
        "tried": (
            "Established, not assumed: the branch has %d commit(s) that main "
            "does not contain, and no live worktree holds it (the lock, never a "
            "roster). Raised by land-disposition.py after %.1fh, which is longer "
            "than every landing on this machine that was followed by a land in "
            "the same working session."
            % (commits, age_hours)),
        "meanwhile": (
            "Nothing is blocked and nothing has been swept: this demand is a "
            "record with a clock on it. It CLOSES ITSELF the moment %s is an "
            "ancestor of main, so landing the work is the whole answer and no "
            "acknowledgement is needed for that case." % (tip[:12] or branch)),
        "record": "",
        "session_id": session_id or "",
        "actor": "land-disposition.py",
    }
    return row


def superseded(rows, repo, branch, rid):
    """Is this demand's (repo, branch) already carrying a NEWER demand?

    A branch that gains a commit gets a new demand, deliberately -- that is new
    work now at risk. Without this the OLD demand would stand forever: its tip
    is not an ancestor of main and never will be on its own, so auto-
    satisfaction can never reach it, and the escalation ladder would get louder
    every day about a demand that has been answered by a newer one. Found by
    land-disposition.test.sh case D09, which is exactly what a paired test is
    for.
    """
    real = os.path.realpath(repo or "/")
    seen_self = False
    for d in demands(rows):
        if os.path.realpath(d.get("repo") or "/") != real:
            continue
        if (d.get("branch") or "") != branch:
            continue
        if str(d.get("id")) == str(rid):
            seen_self = True
            continue
        if seen_self:
            return str(d.get("id"))
    return ""


def satisfy(rows, path=None, now=None):
    """Close every outstanding demand whose work has since landed, or that a
    newer demand for the same work has replaced.

    Returns (closed, undecided). `undecided` is a demand whose tip object can no
    longer be read -- NOT closed, NOT dropped, and named in the report.
    """
    closed, undecided = [], []
    open_ids = acked_ids(rows)
    for d in demands(rows):
        rid = str(d.get("id") or "")
        if not rid or rid in open_ids:
            continue
        newer = superseded(rows, d.get("repo") or "", d.get("branch") or "", rid)
        if newer:
            ack = {"event": "EscalationAck", "id": rid,
                   "acked": escalations.iso(now or escalations.utcnow()),
                   "disposition": (
                       "SUPERSEDED by %s: the branch advanced past tip %s, so "
                       "this demand is about work a newer demand now covers. "
                       "Closed by land-disposition.py; the newer one still "
                       "stands." % (newer, (d.get("head") or "")[:12] or "?")),
                   "actor": "land-disposition.py", "kind": KIND,
                   "session_id": ""}
            try:
                escalations.append_row(ack, path)
            except Exception as exc:
                undecided.append({"id": rid, "repo": d.get("repo") or "",
                                  "branch": d.get("branch") or "",
                                  "why": "superseded, but the ack could not be "
                                         "written (%s)" % type(exc).__name__})
                continue
            closed.append({"id": rid, "repo": os.path.basename(d.get("repo") or ""),
                           "branch": d.get("branch") or "",
                           "tip": (d.get("head") or "")[:12],
                           "trunk_head": "superseded by %s" % newer})
            rows.append(ack)
            continue
        repo, tip = d.get("repo") or "", d.get("head") or ""
        branch = d.get("branch") or ""
        if not repo or not os.path.isdir(repo):
            undecided.append({"id": rid, "repo": repo, "branch": branch,
                              "why": "the repository is not on this machine"})
            continue
        trunk = "main" if git(repo, ["rev-parse", "--verify", "--quiet",
                                     "refs/heads/main"]) else "master"
        verdict = is_ancestor(repo, tip, trunk)
        if verdict is None:
            undecided.append({
                "id": rid, "repo": repo, "branch": branch,
                "why": ("tip %s cannot be read in this repository, so whether "
                        "this landed is UNKNOWN -- not clean" % (tip[:12] or "?"))})
            continue
        if not verdict:
            continue
        head = trunk_sha(repo, trunk)
        disposition = (
            "LANDED: tip %s is an ancestor of %s at %s in %s. Closed by "
            "land-disposition.py, which established this with `merge-base "
            "--is-ancestor` rather than being told it."
            % (tip[:12], trunk, head[:12] or "?", os.path.basename(repo)))
        ack = {"event": "EscalationAck", "id": rid,
               "acked": escalations.iso(now or escalations.utcnow()),
               "disposition": disposition, "actor": "land-disposition.py",
               "kind": KIND, "session_id": ""}
        try:
            escalations.append_row(ack, path)
        except Exception as exc:
            undecided.append({"id": rid, "repo": repo, "branch": branch,
                              "why": "landed, but the ack could not be written "
                                     "(%s)" % type(exc).__name__})
            continue
        closed.append({"id": rid, "repo": os.path.basename(repo),
                       "branch": branch, "tip": tip[:12], "trunk_head": head[:12]})
        rows.append(ack)
    return closed, undecided


def classify(findings, rows, threshold_hours):
    """One item per finding, with the state that decides what is owed."""
    known = {}
    open_ids = acked_ids(rows)
    for d in demands(rows):
        key = (os.path.realpath(d.get("repo") or "/"), d.get("branch") or "",
               (d.get("head") or "")[:40])
        known[key] = d

    items = []
    for f in findings:
        age_h = (f["age_days"] * 24.0) if f.get("age_days") is not None else None
        key = (os.path.realpath(f["repo"]), f["branch"], f["tip"][:40])
        # The finding carries a 12-character tip; demands record the full one.
        prior = None
        for (r, b, t), d in known.items():
            if r == key[0] and b == key[1] and t.startswith(f["tip"][:12]):
                prior = d
                break
        item = dict(f)
        item["age_hours"] = round(age_h, 2) if age_h is not None else None
        item["demand_id"] = str(prior.get("id")) if prior else ""
        item["reason"] = ""
        item["reason_by"] = ""
        if ceo_owned(f["branch"]):
            item["state"] = "ceo-owned"
        elif prior is not None and str(prior.get("id")) in open_ids:
            ack = ack_for(rows, prior.get("id"))
            item["state"] = "held"
            item["reason"] = (ack or {}).get("disposition", "")
            item["reason_by"] = (ack or {}).get("actor", "")
        elif prior is not None:
            item["state"] = "demanded"
        elif age_h is None:
            # No committer date to age from. Not rounded to young: an item this
            # cannot date is one it cannot decide about, and R5 says so.
            item["state"] = "undated"
        elif age_h > threshold_hours:
            item["state"] = "undisposed"
        else:
            item["state"] = "young"
        items.append(item)
    order = {"undisposed": 0, "demanded": 1, "undated": 2, "held": 3,
             "young": 4, "ceo-owned": 5}
    items.sort(key=lambda i: (order.get(i["state"], 9),
                              -(i["age_hours"] or 0), i["label"], i["branch"]))
    return items


def run(entity_root, session_id="", ledger_path=None, extra="",
        threshold_hours=DEFAULT_DEMAND_HOURS, demand=False,
        escalation_ledger=None, now=None):
    now = now if now is not None else time.time()
    result = {"status": "swept", "reason": "", "threshold_hours": threshold_hours,
              "demand_mode": bool(demand), "items": [], "raised": [],
              "closed": [], "undecided": [], "not_examined": [],
              "n_undisposed": 0, "n_demanded": 0, "n_held": 0, "n_young": 0,
              "n_ceo_owned": 0, "n_deferred": 0, "key": "", "summary": ""}

    if unlanded is None or escalations is None:
        result["status"] = "cannot-run"
        result["reason"] = (
            "the analysis this is built on could not be loaded (%s). NOTHING "
            "WAS EXAMINED, which is not the same as nothing being owed."
            % _IMPORT_ERROR)
        result["summary"] = (
            "LAND-DISPOSITION CHECK DID NOT RUN: %s Do not read this as a clean "
            "main; it is an unexamined one." % result["reason"])
        return result

    sweep = unlanded.sweep(entity_root, session_id, ledger_path, extra, now)
    result["sweep_status"] = sweep["status"]
    result["repos"] = sweep["repos"]
    result["n_live"] = sweep["n_live"]
    # DELIBERATELY QUIET, CARRIED ANYWAY. "found nothing owed" and "found three
    # and judged every one of them live" are the two states one silence hides,
    # and only one of them is health. Same argument as unlanded-branches.py.
    result["live"] = sweep["live"]
    if sweep["status"] == "stand-down":
        result["status"] = "stand-down"
        result["reason"] = sweep["reason"]
        result["summary"] = (
            "LAND-DISPOSITION CHECK SWEPT NOTHING: %s. This is not a clean "
            "main; it is an unread one." % sweep["reason"])
        return result
    for row in sweep["repos"]:
        if row.get("note"):
            result["not_examined"].append({"repo": row["repo"], "why": row["note"]})
    if sweep["status"] == "partial":
        result["status"] = "partial"

    rows, bad = escalations.read_rows(escalation_ledger)
    if rows is None:
        result["status"] = "cannot-run"
        result["reason"] = (
            "the escalation ledger at %s could not be read, so whether a "
            "disposition exists is UNKNOWN for every finding."
            % escalations.ledger_path())
        result["summary"] = (
            "LAND-DISPOSITION CHECK DID NOT RUN: %s" % result["reason"])
        return result
    result["ledger_malformed"] = bad

    if demand:
        closed, undecided = satisfy(rows, escalation_ledger, None)
        result["closed"] = closed
        result["undecided"].extend(undecided)

    items = classify(sweep["findings"], rows, threshold_hours)

    if demand:
        raised = 0
        for item in items:
            if item["state"] != "undisposed":
                continue
            if raised >= MAX_RAISES_PER_RUN:
                item["state"] = "undisposed-deferred"
                continue
            row = _demand_row(item["repo"], item["branch"], item["tip"],
                              item.get("teammate", ""), item.get("worktree") or "",
                              item["age_hours"] or 0.0, item["commits"],
                              session_id)
            try:
                escalations.append_row(row, escalation_ledger)
            except Exception as exc:
                result["undecided"].append({
                    "id": "", "repo": item["repo"], "branch": item["branch"],
                    "why": ("A DISPOSITION WAS OWED AND THE DEMAND COULD NOT BE "
                            "WRITTEN (%s). This finding has no clock on it."
                            % type(exc).__name__)})
                continue
            rows.append(row)
            item["state"] = "demanded"
            item["demand_id"] = row["id"]
            result["raised"].append({"id": row["id"], "repo": item["label"],
                                     "branch": item["branch"],
                                     "age_hours": item["age_hours"]})
            raised += 1

    result["items"] = items
    for i in items:
        st = i["state"]
        if st == "undisposed" or st == "undisposed-deferred":
            result["n_undisposed"] += 1
            # COUNTED SEPARATELY, because "six demands were raised" and "six
            # were raised and three more were owed and were not" are different
            # facts and only one of them is the truth on a busy day. Found by
            # land-disposition.test.sh D17, where the overflow was real and
            # invisible.
            if st == "undisposed-deferred":
                result["n_deferred"] += 1
        elif st == "demanded":
            result["n_demanded"] += 1
        elif st == "held":
            result["n_held"] += 1
        elif st == "young":
            result["n_young"] += 1
        elif st == "ceo-owned":
            result["n_ceo_owned"] += 1
    result["key"] = "|".join(
        "%s/%s@%s:%s" % (i["label"], i["branch"], i["tip"], i["state"])
        for i in items if i["state"] in ("undisposed", "undisposed-deferred",
                                         "demanded", "undated"))
    result["summary"] = summary_line(result)
    return result


def summary_line(result):
    """The one sentence a turn end shows. Empty when nothing is owed."""
    owed = [i for i in result["items"]
            if i["state"] in ("undisposed", "undisposed-deferred", "demanded",
                              "undated")]
    if not owed:
        return ""
    named = []
    for i in owed[:MAX_NAMED]:
        bit = "%s %s (%d commit%s" % (i["label"], i["branch"], i["commits"],
                                      "" if i["commits"] == 1 else "s")
        if i["age_hours"] is not None:
            bit += ", %.1fh" % i["age_hours"]
        if i.get("teammate"):
            bit += ", %s" % i["teammate"]
        if i["demand_id"]:
            bit += ", demand %s" % i["demand_id"]
        named.append(bit + ")")
    more = ""
    if len(owed) > MAX_NAMED:
        more = " (+%d more)" % (len(owed) - MAX_NAMED)
    tail = ""
    if result["n_held"]:
        tail += (" %d other finding(s) are HELD with a written reason, which is "
                 "a disposition and is not a defect." % result["n_held"])
    if result["n_ceo_owned"]:
        tail += (" %d codex/ branch(es) are the CEO's by ruling 31 and are "
                 "never demanded on." % result["n_ceo_owned"])
    if result["n_deferred"]:
        tail += (" %d of these are owed a demand that was NOT written this run "
                 "(the per-run ceiling); they are named above and are not lost."
                 % result["n_deferred"])
    if result["undecided"]:
        tail += (" %d demand(s) COULD NOT BE DECIDED and are listed by "
                 "land-disposition.sh." % len(result["undecided"]))
    return ("FINISHED WORK WITH NO DISPOSITION - %d piece(s) of work are "
            "neither landed nor held for a written reason: %s%s. Land it, or "
            "say why it is held: `escalate.sh ack <id> --disposition \"...\"`. "
            "A demand closes itself when the work lands.%s "
            "Detail: scripts/land-disposition.sh"
            % (len(owed), "; ".join(named), more, tail))


def text_report(result):
    out = ["=== finished work: landed, or held for a written reason ==="]
    out.append("  status          : %s" % result["status"])
    if result.get("reason"):
        out.append("  reason          : %s" % result["reason"])
    out.append("  demand after    : %g hour(s)" % result["threshold_hours"])
    out.append("  mode            : %s"
               % ("DEMAND (writes to the escalation ledger)" if result["demand_mode"]
                  else "report only (writes nothing)"))
    if result.get("ledger_malformed"):
        out.append("  ** %d malformed line(s) in the escalation ledger were skipped"
                   % result["ledger_malformed"])
    out.append("")
    for row in result.get("repos", []):
        out.append("  %-28s trunk=%-8s ahead=%d%s"
                   % (row["label"], row["trunk"] or "<none>", row["n_ahead"],
                      ("   " + row["note"]) if row["note"] else ""))
    out.append("")
    if not result["items"]:
        out.append("  Nothing is standing outside main that no live worktree holds.")
        if result.get("n_live"):
            out.append("  %d branch(es) are ahead of main and each is held by a live"
                       % result["n_live"])
            out.append("  teammate, which is what work in progress looks like.")
        out.append("")
    for i in result["items"]:
        out.append("  [%s]  %s  %s" % (i["state"].upper(), i["label"], i["branch"]))
        out.append("      %d commit(s) ahead of %s, tip %s, %s hours standing"
                   % (i["commits"], i["trunk"], i["tip"],
                      i["age_hours"] if i["age_hours"] is not None else "?"))
        out.append("      owner    : %s" % (i.get("teammate") or "not in the ledger"))
        out.append("      worktree : %s (%s)"
                   % (i.get("worktree") or "gone", i.get("worktree_state")))
        if i["demand_id"]:
            out.append("      demand   : %s" % i["demand_id"])
        if i["state"] == "held":
            out.append("      REASON   : %s" % i["reason"])
            out.append("      written by: %s" % (i["reason_by"] or "<unrecorded>"))
        elif i["state"] == "ceo-owned":
            out.append("      NOT DEMANDED: the codex/ prefix is the CEO's by "
                       "ceo-decisions.md 31.")
            out.append("      Its disposition is already stated -- it is his to "
                       "land or not -- so")
            out.append("      asking again every turn would be re-asking a "
                       "settled question.")
        elif i["state"] == "young":
            out.append("      Nothing owed yet: under the %g-hour threshold. This "
                       "is the legitimate" % result["threshold_hours"])
            out.append("      case -- a land in progress, a turn ending on a "
                       "question, a last commit.")
        elif i["state"] == "undated":
            out.append("      UNDECIDED: no committer date to age this from, so "
                       "whether a disposition")
            out.append("      is owed is UNKNOWN. Not rounded to 'young'.")
        else:
            out.append("      land it  : git -C %s merge %s" % (i["repo"], i["branch"]))
            out.append("      or read  : git -C %s log --oneline %s..%s"
                       % (i["repo"], i["trunk"], i["branch"]))
            out.append("      or hold  : escalate.sh ack %s --disposition \"<why "
                       "this is not landed and what would change that>\""
                       % (i["demand_id"] or "<id>"))
        out.append("")
    if result["raised"]:
        out.append("  demands RAISED this run:")
        for r in result["raised"]:
            out.append("      %s  %s %s  (%.1fh)"
                       % (r["id"], r["repo"], r["branch"], r["age_hours"] or 0))
        out.append("")
    if result["closed"]:
        out.append("  demands CLOSED this run, because the work landed:")
        for c in result["closed"]:
            out.append("      %s  %s %s  tip %s is an ancestor of %s"
                       % (c["id"], c["repo"], c["branch"], c["tip"], c["trunk_head"]))
        out.append("")
    if result.get("live"):
        out.append("  ahead of main and NOTHING IS OWED, because something live "
                   "holds them:")
        for f in result["live"]:
            out.append("      %-12s %-34s %d commit(s)  %s"
                       % (f["label"], f["branch"], f["commits"], f["live_reason"]))
        out.append("")
    # PRINTED EVEN WHEN EMPTY. R5: a checker that could not look has found
    # nothing and proved nothing, and the two must never share a silence.
    out.append("  COULD NOT DECIDE (%d):" % len(result["undecided"]))
    for u in result["undecided"]:
        out.append("      %s %s %s -- %s"
                   % (u.get("id") or "<no id>", os.path.basename(u.get("repo") or ""),
                      u.get("branch") or "", u["why"]))
    if not result["undecided"]:
        out.append("      (nothing was undecidable)")
    out.append("")
    out.append("  NOT EXAMINED (%d):" % len(result["not_examined"]))
    for n in result["not_examined"]:
        out.append("      %s -- %s" % (n["repo"], n["why"]))
    if not result["not_examined"]:
        out.append("      (every repository in scope answered)")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--entity-root", required=True)
    ap.add_argument("--session", default="")
    ap.add_argument("--ledger", default=None,
                    help="the worktree ownership ledger")
    ap.add_argument("--escalation-ledger", default=None)
    ap.add_argument("--extra-repos", default="")
    ap.add_argument("--threshold-hours", type=float, default=None)
    ap.add_argument("--demand", action="store_true",
                    help="raise a demand for undisposed work and close demands "
                         "whose work has landed. Without this, writes nothing.")
    ap.add_argument("--format", choices=("json", "text", "line", "hook"),
                    default="json")
    args = ap.parse_args(argv)

    threshold = args.threshold_hours
    if threshold is None:
        try:
            threshold = float(os.environ.get("LAND_DISPOSITION_DEMAND_HOURS",
                                             DEFAULT_DEMAND_HOURS))
        except ValueError:
            threshold = DEFAULT_DEMAND_HOURS

    result = run(args.entity_root, args.session, args.ledger, args.extra_repos,
                 threshold, args.demand, args.escalation_ledger)

    # ONE SWEEP, ONE VERDICT, EVERY FORMAT. Computed before rendering so the
    # printed report and the exit code are two views of the same result rather
    # than two runs that can disagree.
    if result["status"] in ("cannot-run", "stand-down"):
        verdict = 4
    elif result["n_undisposed"] or result["n_demanded"] or result["undecided"]:
        verdict = 3
    else:
        verdict = 0

    if args.format == "json":
        sys.stdout.write(json.dumps(result, indent=2) + "\n")
        return verdict
    if args.format == "text":
        sys.stdout.write(text_report(result) + "\n")
        return verdict
    if args.format == "hook":
        def one(v):
            return str(v).replace("\n", " ").replace("\t", " ")
        for k, v in (("STATUS", result["status"]),
                     ("REASON", result.get("reason", "")),
                     ("N", result["n_undisposed"] + result["n_demanded"]),
                     ("NHELD", result["n_held"]),
                     ("NYOUNG", result["n_young"]),
                     ("NCEO", result["n_ceo_owned"]),
                     ("NDEFERRED", result["n_deferred"]),
                     ("NRAISED", len(result["raised"])),
                     ("NCLOSED", len(result["closed"])),
                     ("NUNDECIDED", len(result["undecided"])),
                     ("KEY", result["key"]),
                     ("SUMMARY", result["summary"])):
            sys.stdout.write("%s\t%s\n" % (k, one(v)))
        return verdict
    if result["summary"]:
        sys.stdout.write(result["summary"] + "\n")
    return verdict


if __name__ == "__main__":
    sys.exit(main())
