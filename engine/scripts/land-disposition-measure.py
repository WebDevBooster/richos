#!/usr/bin/env python3
"""land-disposition-measure.py -- HOW LONG DOES FINISHED WORK ACTUALLY SIT?

===========================================================================
WHY THIS IS A SCRIPT AND NOT A NUMBER IN A HEADER
===========================================================================
`land-disposition.py` demands a written disposition for finished work that has
been standing longer than a threshold. A threshold is the part of a check that
is easiest to get wrong and hardest to argue about afterwards, and this project
has a recent, specific injury from exactly that: a quota alarm shipped with a
4x safety multiplier chosen out of thin air and fired claiming a budget "could
be 104%" when the real movement was zero.

So the threshold is DERIVED, here, from this machine's own landing history, and
this file is the derivation rather than a note about one. Anybody can re-run it
and get today's answer instead of the answer that was true when it was written:

    scripts/land-disposition-measure.py                # every governed repo
    scripts/land-disposition-measure.py --repo <path>  # one, repeatable
    scripts/land-disposition-measure.py --json

===========================================================================
WHAT IS MEASURED, AND WHY THIS QUANTITY
===========================================================================
For every landing on trunk that has two parents, the SECOND parent is the tip
of the branch that was landed and the merge commit is the moment it arrived.

    standing time  =  (merge committer date) - (branch tip committer date)

That is exactly "how long did work that was finished sit outside main", because
a teammate's last commit IS its finish (`Engineers commit on their branch and
report SHAs as their final step`). It is a slight OVER-estimate of the interval
this engine can act on -- the agent may still have been alive for part of it,
and the demand stays silent while a live worktree holds the branch -- so a
threshold derived from it is conservative in the safe direction: it will demand
LATER than the data strictly requires, never earlier.

Only TEAMMATE branches count. A branch is a teammate branch when the landing
subject names one, by the two conventions this project actually uses:

    <role>-<model>-<identifier>   zach-opus-dor1, sage-fable-r3, echo-opus-win1
    worktree-agent-<hex>          the platform's own native-isolation name

Anything else -- a pull merge, a round folder, a hand-made branch -- is left OUT
rather than guessed at, and the count of what was skipped is printed. A corpus
that quietly included a routine merge of the remote trunk would measure the age
of that trunk and call it a landing delay.

===========================================================================
THIS SCRIPT DOES NOT PROPOSE A THRESHOLD, AND THAT IS THE FINDING
===========================================================================
It was written to. The first version searched for the widest gap in the tail
above the 99th percentile and proposed the whole hour inside it. Run against
this machine it proposed FORTY-FOUR HOURS, and it was not a coding mistake --
the rule was doing exactly what it was told:

      2.92 h   richos      zach-opus-ob1          <- longest ordinary landing
      3.95 h   richos      echo-opus-win1         <- the CEO's window fix
      5.63 h   femcboost   worktree-agent-a42f58
      6.90 h   richos      zach-opus-dor1
      6.93 h   richos-hq   zach-opus-prem1
     12.45 h   femcboost   worktree-agent-a69a63
     44.61 h   femcboost   worktree-agent-a66286
     47.44 h   richos      echo-opus-dr1

The 99th percentile of this corpus is 9.36 hours, so "the tail above p99" is
made ENTIRELY of strandings, and the widest gap inside it is the gap between
two strandings. Relative gaps pick the same place. A gap searched between p90
and p99 picks 5 hours, which would have stayed silent about the window fix --
the one branch this whole exercise exists because he found himself.

    THE TAIL OF THE LANDING HISTORY IS MADE OF THE DEFECT THE THRESHOLD IS
    MEANT TO CATCH, SO NO RULE OVER THAT HISTORY ALONE CAN FIND THE EDGE.

Every rule that produces the right answer here does so because it was tuned
until it did, and a rule tuned to its own answer is the laundering this project
keeps recording: a judgment made once and quoted as data forever. So the
proposal was deleted rather than tuned.

What the script does instead is put a person in a position to choose in one
look, and to be held to the choice:

  1. the whole upper tail, sorted and NAMED, so the valley is read rather than
     asserted;
  2. the cost curve -- how many landings a demand would have fired on at each
     candidate hour;
  3. for the threshold actually in force (--threshold, defaulting to the
     configured one), EVERY LANDING IT WOULD HAVE DEMANDED, BY NAME. Seven
     names a reader can judge one at a time beats any rate, because the
     question "was this one a false positive?" is answerable about a name and
     is not answerable about a percentage.

The choice in force, and its reasoning, live in orchestration.config next to
the value -- not here, so that a changed value cannot leave a stale argument
behind in a header.

Exit codes: 0 measured; 2 nothing measurable (no repository, no landings).
"""

import argparse
import json
import os
import re
import subprocess
import sys

TRUNKS = ("main", "master")
ROLES = ("zach", "sage", "mark", "norm", "ace", "tom", "ray", "urban", "kai",
         "echo", "iris", "andy", "isaac", "quint", "art", "josh", "frank",
         "will", "vic", "reed", "clark", "dean", "linda", "sara", "jenny",
         "hugh", "gavin", "smith", "sterling", "finn", "grant")
MODELS = ("fable", "opus", "sonnet", "haiku")
TEAMMATE_NAME = re.compile(
    r"\b((?:%s)-(?:%s)-[A-Za-z0-9]+)\b" % ("|".join(ROLES), "|".join(MODELS)))
NATIVE_NAME = re.compile(r"\b(worktree-agent-[0-9a-f]{6,})\b")

DEFAULT_LEDGER = (os.environ.get("RICHOS_WORKTREE_LEDGER")
                  or os.path.join(os.path.expanduser("~"), ".claude", "state",
                                  "worktree-ledger.jsonl"))


def git(root, args, timeout=60):
    try:
        res = subprocess.run(["git", "-C", root] + list(args),
                             capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None
    if res.returncode != 0:
        return None
    return res.stdout


def main_checkout(path):
    if not path or not os.path.isdir(path):
        return None
    out = git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    if out is None:
        return None
    common = out.strip()
    if not common:
        return None
    if os.path.basename(common) == ".git":
        return os.path.realpath(os.path.dirname(common))
    return None


def ledger_repos(path=None):
    """Every repository the ownership ledger has ever registered a worktree in.

    Read off the durable record rather than scanned for, the same way
    land-completeness.sh chooses its repositories: a scan of $HOME would invent
    governance over repositories nobody asked about.
    """
    path = path or DEFAULT_LEDGER
    found = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if not isinstance(rec, dict):
                    continue
                repo = rec.get("repo") or ""
                if repo and os.path.isdir(repo):
                    mc = main_checkout(repo)
                    if mc:
                        found.append(mc)
    except Exception:
        return []
    return sorted(set(found))


def trunk_of(repo):
    for name in TRUNKS:
        if git(repo, ["rev-parse", "--verify", "--quiet",
                      "refs/heads/" + name]) is not None:
            return name
    return None


def landings(repo, trunk):
    """[(sha, merge_epoch, tip_epoch, subject)] for every two-parent landing."""
    out = git(repo, ["log", "--merges", "--format=%H\t%ct\t%P\t%s", trunk])
    if out is None:
        return None
    rows = []
    tips = {}
    parents = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        sha, ct, par, subj = parts[0], parts[1], parts[2], "\t".join(parts[3:])
        p = par.split()
        if len(p) < 2:
            continue
        parents.append((sha, int(ct), p[1], subj))
    if not parents:
        return []
    # One batch call for every second parent's date, rather than one fork each.
    batch = git(repo, ["log", "--no-walk", "--format=%H %ct"] +
                sorted(set(p[2] for p in parents)))
    if batch is None:
        return None
    for line in batch.splitlines():
        bits = line.split()
        if len(bits) == 2:
            tips[bits[0]] = int(bits[1])
    for sha, ct, tip, subj in parents:
        if tip in tips:
            rows.append((sha, ct, tips[tip], subj))
    return rows


def teammate_branch(subject):
    m = TEAMMATE_NAME.search(subject) or NATIVE_NAME.search(subject)
    return m.group(1) if m else None


def pct(values, q):
    if not values:
        return None
    v = sorted(values)
    i = (len(v) - 1) * q / 100.0
    lo = int(i)
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (i - lo)


def measure(repos, threshold_hours=0.0, corpus_rule="", reproduce_command=""):
    result = {"repos": [], "landings": [], "skipped_not_teammate": 0,
              "unreadable": [], "threshold_hours": threshold_hours,
              "corpus_rule": corpus_rule or "(not stated)",
              "reproduce_command": reproduce_command or "(not stated)"}
    for repo in repos:
        trunk = trunk_of(repo)
        if trunk is None:
            result["unreadable"].append(
                {"repo": repo, "why": "no local main or master"})
            continue
        rows = landings(repo, trunk)
        if rows is None:
            result["unreadable"].append(
                {"repo": repo, "why": "git refused to read its landing history"})
            continue
        n_team = 0
        for sha, mt, tip, subj in rows:
            branch = teammate_branch(subj)
            if not branch:
                result["skipped_not_teammate"] += 1
                continue
            n_team += 1
            result["landings"].append({
                "repo": os.path.basename(repo), "sha": sha[:12], "branch": branch,
                "landed_epoch": mt, "tip_epoch": tip,
                "standing_hours": round((mt - tip) / 3600.0, 4), "subject": subj,
            })
        tip = git(repo, ["rev-parse", "--short=12", trunk])
        result["repos"].append({"repo": repo, "label": os.path.basename(repo),
                                "trunk": trunk, "landings": len(rows),
                                "teammate_landings": n_team,
                                "trunk_tip": (tip or "?").strip()})
    hours = [r["standing_hours"] for r in result["landings"]]
    result["n"] = len(hours)
    if hours:
        result["percentiles"] = {("p%s" % q): round(pct(hours, q), 4)
                                 for q in (50, 75, 90, 95, 99, 100)}
        result["demand_rate"] = []
        for t in (1, 2, 3, 4, 6, 8, 12, 24, 48):
            n = sum(1 for h in hours if h > t)
            result["demand_rate"].append(
                {"threshold_hours": t, "landings_over": n,
                 "rate_percent": round(100.0 * n / len(hours), 3)})
        # WHICH REPOSITORIES ARE ONLY DENOMINATOR? A repository holding a
        # meaningful share of the corpus with nothing above the threshold
        # shrinks every rate and changes no decision. It is exactly what
        # produced 0.628% where the same seven landings are 2.703%.
        threshold = result.get("threshold_hours") or 0
        result["dilution"] = []
        for row in result["repos"]:
            if not row["teammate_landings"]:
                continue
            mine = [r["standing_hours"] for r in result["landings"]
                    if r["repo"] == row["label"]]
            if not mine:
                continue
            above = sum(1 for h in mine if h > threshold)
            share = 100.0 * len(mine) / len(hours)
            if above == 0 and share >= 10.0:
                result["dilution"].append(dict(
                    row, share_percent=round(share, 1),
                    slowest_hours=round(max(mine), 3), above_threshold=above))
    return result


def text_report(result):
    out = ["=== how long finished work stands before it lands ==="]
    # THE PROVENANCE BLOCK, first, because a number quoted without it is how
    # 0.628% was published (2026-09-10). The docstring cited THIS script as its
    # derivation; re-run as cited the answer is 2.703%. The gap is one flag: the
    # original run added `--repo /Users/alex/ab/prospects` by hand, which is 857
    # of the 1,114 landings and is in no ownership-ledger row, so no re-run of
    # the cited command could ever have reproduced it.
    #
    # So the corpus now prints the command that reproduces IT, exactly, and a
    # quotation of any number below carries the corpus with it or it is
    # incomplete.
    out.append("  corpus chosen by : %s" % result["corpus_rule"])
    out.append("  reproduce EXACTLY THIS corpus with:")
    out.append("      %s" % result["reproduce_command"])
    out.append("")
    for row in result["repos"]:
        out.append("  %-28s trunk=%-7s landings=%-5d teammate=%-5d tip=%s"
                   % (row["label"], row["trunk"], row["landings"],
                      row["teammate_landings"], row.get("trunk_tip", "?")))
    for row in result["unreadable"]:
        out.append("  NOT EXAMINED: %s -- %s" % (row["repo"], row["why"]))
    out.append("")
    out.append("  teammate landings measured : %d      <- THE DENOMINATOR of every rate below"
               % result["n"])
    out.append("  landings skipped (subject names no teammate branch): %d"
               % result["skipped_not_teammate"])
    if not result["n"]:
        out.append("")
        out.append("  NOTHING MEASURED. This is not a threshold of zero; it is no answer.")
        return "\n".join(out)
    out.append("")
    for k in ("p50", "p75", "p90", "p95", "p99", "p100"):
        v = result["percentiles"][k]
        out.append("      %-5s %9.3f h  (%8.1f min)" % (k, v, v * 60))
    out.append("")
    out.append("  THE UPPER TAIL, every landing above one hour, sorted -- the valley is")
    out.append("  meant to be READ here rather than taken on trust:")
    tail = sorted((r for r in result["landings"] if r["standing_hours"] > 1.0),
                  key=lambda r: r["standing_hours"])
    if not tail:
        out.append("      (nothing stood longer than an hour)")
    for r in tail:
        out.append("      %8.2f h   %-11s %-34s %s"
                   % (r["standing_hours"], r["repo"], r["branch"][:34], r["sha"]))
    out.append("")
    out.append("  NO THRESHOLD IS PROPOSED HERE, deliberately. The rule that used to")
    out.append("  propose one answered 44 hours against this same corpus, because the")
    out.append("  tail it searched is made entirely of strandings. The header carries")
    out.append("  the working. Choose from the tail above and the cost below, and put")
    out.append("  the reason next to the value in orchestration.config.")
    out.append("")
    out.append("  what a demand would have cost at each candidate:")
    for row in result["demand_rate"]:
        out.append("      %5gh : %4d of %d landings would have been demanded (%.3f%%)"
                   % (row["threshold_hours"], row["landings_over"], result["n"],
                      row["rate_percent"]))
    # DILUTION. A repository that lands fast and often contributes a large
    # DENOMINATOR and nothing to the tail, so every rate above it shrinks
    # without any behavior changing. That is not a hypothetical: `prospects`
    # is 857 of the 1,114 landings the published 0.628% was measured over, its
    # SLOWEST landing is 0.81 h — below the tail cut — and dropping it moves
    # the same seven demanded landings from 0.628% to 2.703%. The seven names
    # never changed. Only the denominator did.
    if result.get("dilution"):
        out.append("")
        out.append("  DILUTION WARNING -- these repositories are a large part of the")
        out.append("  denominator and contribute NOTHING above the threshold, so they")
        out.append("  shrink every rate above without any behavior differing:")
        for row in result["dilution"]:
            out.append("      %-28s %4d of %d landings (%.1f%%), slowest %.2f h, %d above %gh"
                       % (row["label"], row["teammate_landings"], result["n"],
                          row["share_percent"], row["slowest_hours"],
                          row["above_threshold"], result["threshold_hours"]))
        out.append("      A rate is only comparable with another rate over the SAME corpus.")
    if result.get("at_threshold") is not None:
        t = result["threshold_hours"]
        named = result["at_threshold"]
        out.append("")
        out.append("  AT THE THRESHOLD IN FORCE (%g h) THESE %d LANDINGS WOULD HAVE BEEN"
                   % (t, len(named)))
        out.append("  DEMANDED. Judge them ONE AT A TIME -- that question is answerable")
        out.append("  about a name and is not answerable about a percentage:")
        for r in named:
            out.append("      %8.2f h   %-11s %-34s %s"
                       % (r["standing_hours"], r["repo"], r["branch"][:34], r["sha"]))
        if not named:
            out.append("      (none)")
    out.append("")
    out.append("  READ THE TAIL BEFORE TRUSTING THE RATE. Some of those long landings")
    out.append("  are themselves strandings -- work that was finished and forgotten and")
    out.append("  later found by hand. A demand fired on one of those is a TRUE positive")
    out.append("  wearing a false one's clothes, and this script will not decide which is")
    out.append("  which for you: that is a judgment, and a judgment made once is quoted as")
    out.append("  data forever.")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--repo", action="append", default=[])
    ap.add_argument("--ledger", default=None)
    ap.add_argument("--threshold", type=float, default=None,
                    help="hours; names every landing a demand would have fired "
                         "on. Defaults to LAND_DISPOSITION_DEMAND_HOURS.")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    threshold = args.threshold
    if threshold is None:
        try:
            threshold = float(os.environ.get("LAND_DISPOSITION_DEMAND_HOURS", "3"))
        except ValueError:
            threshold = 3.0

    repos = []
    for r in args.repo:
        mc = main_checkout(os.path.abspath(os.path.expanduser(r)))
        if mc:
            repos.append(mc)
    if not repos:
        repos = ledger_repos(args.ledger)
    repos = sorted(set(repos))

    if not repos:
        sys.stderr.write(
            "land-disposition-measure: no repository resolved. NOTHING WAS MEASURED,\n"
            "  which is not the same as a threshold of zero. Name one with --repo.\n")
        return 2

    rule = ("the repositories named with --repo on the command line"
            if args.repo else
            "every repository the ownership ledger (%s) has ever registered a "
            "worktree in -- A MOVING CORPUS: the ledger only grows, so this "
            "same command answers over more repositories tomorrow than today"
            % (args.ledger or DEFAULT_LEDGER))
    command = "python3 %s %s--threshold %g" % (
        os.path.relpath(os.path.abspath(__file__), os.getcwd())
        if os.path.abspath(__file__).startswith(os.getcwd()) else os.path.abspath(__file__),
        "".join("--repo %s " % r for r in repos), threshold)
    result = measure(repos, threshold_hours=threshold, corpus_rule=rule,
                     reproduce_command=command)
    result["threshold_hours"] = threshold
    result["at_threshold"] = sorted(
        (r for r in result["landings"] if r["standing_hours"] > threshold),
        key=lambda r: r["standing_hours"])
    if args.json:
        sys.stdout.write(json.dumps(result, indent=2) + "\n")
    else:
        sys.stdout.write(text_report(result) + "\n")
    return 0 if result["n"] else 2


if __name__ == "__main__":
    sys.exit(main())
