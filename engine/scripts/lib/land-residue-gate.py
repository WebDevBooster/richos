#!/usr/bin/env python3
"""land-residue-gate.py — G2/G3. THE CHECK THAT RUNS AT A LAND.

Reads one repository's land-completeness report, matches any acknowledgement
carried on the command line, and answers whether this land proceeds.

    --repo <path>       the repository the land is about to go into
    --branch <name>     the branch it lands into (default: main)
    --command <text>    the command line, for the acknowledgement
    --ack-log <path>    where accepted acknowledgements are recorded
    --enforce 0|1       1 refuses, 0 announces and allows

    exit 0  nothing to say, or announced and allowed
    exit 2  REFUSED

===========================================================================
IT SHIPS WITH --enforce 0 AND THAT IS NOT TIMIDITY
===========================================================================
`docs/plans/land-completeness-2026-09-10.md` G4 keeps installation approval with
the founder: he sees the measured rate and the acknowledgement's shape BEFORE
anything blocks, and there is no implicit approval from a merge or from silence.
So the shipped default announces and allows. Everything else is built, measured
and demonstrated in both directions; arming it is one committed, diffable line.

The measured rate he is being shown, re-derivable with
`scripts/land-completeness-measure.py`: over lands since the ownership ledger
began, 17.7% would have been refused, 7.6% would have been refused by a naive
version and are exempted because their owner held a running lock, and 61% were
undecidable and are never refused at all.

===========================================================================
THE ACKNOWLEDGEMENT, AND WHY IT IS SHAPED LIKE THE CI-RED ONE
===========================================================================
    land-residue-ack: <worktree or branch> — <why this land cannot wait>

It is read off the COMMAND LINE, which puts the claim in the transcript next to
the act it excuses, and satisfies R7 — THE ESCAPE HATCH MAY NOT LIVE INSIDE THE
BREAK. This gate fires on a fact it established from git and the ledger; the
command line is readable in exactly that state. (The converse case is handled
before this ever runs: a payload the host cannot parse is classified `not a
land` and this is never reached, so there is no state in which the gate fires
and the hatch cannot be typed.)

Every clause narrows it, and every one of them is the lesson from a guard this
project has already had to kill:

  * IT MUST NAME SOMETHING ACTUALLY LEFT BEHIND. An ack naming a worktree that
    is not residue is refused and says so — it is either a typo about to let a
    land through on a mistake, or a copy from an earlier land, which is the
    habit this counts.
  * IT MUST CARRY A REASON. Under 15 characters is a marker, not a reason, and
    a bare marker exempts nothing — the same discipline `dialect-exempt:` and
    `ci-red-ack:` already carry.
  * ONE ACK DOES NOT COVER THE OTHERS. Three items left behind take three acks,
    which is exactly as much typing as there are things to explain.
  * EVERY ACCEPTED ACK IS LOGGED AND COUNTED BACK AT YOU. The fifth ack for the
    same worktree prints "this is ack number 5", which turns a habit into
    evidence without blocking anybody's day. g11/g12/g13 died of habitual
    waiving that nothing was counting.
"""

import argparse
import importlib.util
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def names_for(item):
    """Every string this piece of residue can honestly be called: its branch,
    its directory name, and its full path.

    An ack is a human typing. Refusing `zach-opus-prem1` because the path is
    `/Users/alex/ab/richos-wt/zach-opus-prem1` would be pedantry that teaches
    people to distrust the gate rather than to use it.
    """
    out = set()
    for v in (item.get("branch"), os.path.basename(item.get("path") or ""),
              item.get("path")):
        if v:
            out.add(str(v).strip().lower())
    return out


def parse_acks(command):
    acks = []
    for m in re.finditer(r"land-residue-ack:\s*([^\n#]+)", command or ""):
        body = m.group(1).strip().rstrip("'\"")
        parts = re.split(r"\s*(?:—|--|:)\s*", body, maxsplit=1)
        who = parts[0].strip()
        why = parts[1].strip() if len(parts) > 1 else ""
        acks.append((who, why))
    return acks


def ack_history(log_path, repo):
    """How often has each item already been acked HERE? Read before anything is
    written, so a count printed in a refusal is history and not this attempt."""
    hist = {}
    try:
        with open(log_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3 and parts[1] == repo:
                    hist[parts[2].lower()] = hist.get(parts[2].lower(), 0) + 1
    except Exception:
        pass
    return hist


def main(argv=None):
    ap = argparse.ArgumentParser(prog="land-residue-gate.py")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--branch", default="main")
    ap.add_argument("--command", default="")
    ap.add_argument("--ack-log", default=os.path.expanduser(
        "~/.claude/state/land-residue-acks.log"))
    ap.add_argument("--enforce", default="0")
    args = ap.parse_args(argv)

    enforce = str(args.enforce).strip().lower() in ("1", "true", "yes", "on")

    try:
        lc = _load("land_completeness", os.path.join(HERE, "land-completeness.py"))
    except Exception as exc:
        # CANNOT LOOK IS NOT A FINDING. Announce and allow, for the reason
        # guard-ci-red-lands.sh argues at length about its own probe: blocking
        # on this gate's own malfunction would teach everyone to work around it.
        sys.stderr.write(
            "=== LAND-COMPLETENESS CHECK: COULD NOT LOOK — THE LAND IS ALLOWED ===\n"
            "  The analyzer could not be loaded (%s), so nothing was checked. This is NOT\n"
            "  'the last land was clean'.\n" % exc)
        return 0

    try:
        report = lc.analyze(args.repo, args.branch)
    except Exception as exc:
        sys.stderr.write(
            "=== LAND-COMPLETENESS CHECK: COULD NOT LOOK — THE LAND IS ALLOWED ===\n"
            "  The analysis raised %s, so nothing was checked and nothing is proven clean.\n"
            "  Answer it yourself:  engine/scripts/land-completeness.sh --repo %s\n"
            % (exc, args.repo))
        return 0

    items = lc.blocking_items(report)
    counts = report.get("counts", {})

    if not items:
        # Silent in the ordinary case — a working guard says nothing. The
        # unknown count is NOT a reason to speak here: it is the status
        # command's job to carry it, and a line printed at every land would be
        # read past within a day, which is how the worktree notice that was
        # already on his screen got read past on 2026-09-10.
        return 0

    acks = parse_acks(args.command)
    hist = ack_history(args.ack_log, args.repo)

    problems, accepted = [], []
    for it in items:
        match = None
        for who, why in acks:
            if who.strip().lower() in names_for(it):
                match = (who, why)
                break
        if match is None:
            problems.append((it, "not acknowledged"))
        elif len(match[1]) < 15:
            problems.append((it, "acknowledged with a reason of %d characters (%r) — that is a "
                                 "marker, not a reason" % (len(match[1]), match[1])))
        else:
            accepted.append((it, match[1]))

    all_names = set()
    for it in items:
        all_names |= names_for(it)
    stray = [(w, r) for w, r in acks if w.strip().lower() not in all_names]

    key = lambda it: (it.get("branch") or os.path.basename(it.get("path") or "")).lower()

    if not problems:
        try:
            os.makedirs(os.path.dirname(args.ack_log), exist_ok=True)
            with open(args.ack_log, "a", encoding="utf-8") as f:
                for it, why in accepted:
                    f.write("%s\t%s\t%s\t%s\n" % (
                        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), args.repo,
                        key(it), why.replace("\t", " ")))
        except Exception:
            pass
        sys.stderr.write("=== LAND-COMPLETENESS CHECK: allowed on a declared acknowledgement ===\n")
        for it, why in accepted:
            n = hist.get(key(it), 0)
            sys.stderr.write("  %s — %s\n" % (key(it), why))
            if n >= 2:
                sys.stderr.write(
                    "      THIS IS ACKNOWLEDGEMENT NUMBER %d FOR THIS WORKTREE. A hatch used %d\n"
                    "      times is not an exception any more; it is a worktree being carried.\n"
                    "      Remove it or say, once, in the record, that it is being kept.\n"
                    % (n + 1, n + 1))
        for w, _r in stray:
            sys.stderr.write(
                "  NOTE: the acknowledgement named %r, which is not left behind. Check the name —\n"
                "        one that matches nothing excuses nothing, and did not have to be written.\n"
                % w)
        return 0

    # -----------------------------------------------------------------------
    # THE FINDING
    # -----------------------------------------------------------------------
    head = ("=== THE PREVIOUS LAND IS NOT FINISHED — THIS LAND IS REFUSED ==="
            if enforce else
            "=== THE PREVIOUS LAND IS NOT FINISHED — REPORTING ONLY, THIS LAND IS ALLOWED ===")
    w = sys.stderr.write
    w("%s\n\n" % head)
    w("  %s (%s)\n\n" % (args.repo, args.branch))
    for it, why in problems:
        n = hist.get(key(it), 0)
        w("    %s\n" % it["path"])
        w("        branch %s is already merged into %s, and the worktree is still registered\n"
          % (it["branch"], args.branch))
        w("        owner %s — %s\n" % (it["owner"], (it.get("owner_reason") or "")[:220]))
        if n:
            w("        ALREADY ACKNOWLEDGED %d TIME(S) in this repository.\n" % n)
        if why != "not acknowledged":
            w("        the acknowledgement was rejected: %s\n" % why)
        w("\n")

    w("  NOT NAMED ABOVE, AND DELIBERATELY: %d worktree(s) whose owner holds a running lock,\n"
      % counts.get("live", 0))
    w("  %d whose branch is UNMERGED and is never swept by rule, and %d this check could not\n"
      % (counts.get("retained_unmerged", 0), counts.get("unknown", 0)))
    w("  decide. None of those is refused; the full picture, including them, is:\n")
    w("      engine/scripts/land-completeness.sh --repo %s\n\n" % args.repo)

    w("  WHY THIS FIRES AT A LAND. Every land step carrying a gate was satisfied on every land\n")
    w("  on 2026-09-10 — merges refused by row currency, pushes by the in-flight notice, stale\n")
    w("  checksums by the integrity probe. The one step with no gate was skipped on all of\n")
    w("  them, ten-plus times in a row, and the founder spent a working day watching finished\n")
    w("  agents sit on his screen as live rows. Attention follows enforcement.\n\n")

    w("  THE THREE WAYS FORWARD, in the order they should be preferred:\n\n")
    w("  1. FINISH THE LAND. It is two commands per item and it clears this for everybody:\n")
    for it, _why in problems:
        w("       engine/scripts/collect-worktree-artifacts.sh %s\n" % it["path"])
        w("       engine/scripts/remove-agent-worktree.sh %s\n" % it["path"])
    w("\n")
    w("  2. SAY WHY IT IS KEPT. Add one comment to the command, naming EACH item:\n\n")
    w("       git merge ...   # land-residue-ack: %s — <why this is kept>\n\n"
      % key(problems[0][0]))
    w("     A bare marker exempts nothing. Every accepted acknowledgement is logged to\n")
    w("       %s\n" % args.ack_log)
    w("     and the count is printed back at you, so a hatch that becomes a habit says so.\n\n")
    w("  3. IF THE OWNER IS ACTUALLY STILL RUNNING, this gate is wrong and wants to know.\n")
    w("     A live agent holds a LOCKED native isolation worktree and is exempt automatically;\n")
    w("     if one is running without that lock, that is the bug to report, not to work around.\n")

    if not enforce:
        w("\n  REPORTING ONLY. LAND_COMPLETENESS_ENFORCE is not set, so this land proceeds and\n")
        w("  nothing above was blocked. Arming it is the founder's call and his alone.\n")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
