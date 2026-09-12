#!/usr/bin/env python3
"""unlanded-branches.py -- WORK THAT IS FINISHED AND IS NOT ON MAIN.

===========================================================================
THE DEFECT
===========================================================================
On 2026-09-06 a session ended reporting "Everything is clean and pushed" while
SIX finished branches sat outside main -- one of them the fix for the CEO's own
complaint that the app steals keyboard focus. Both checks that session ran were
green and both were CORRECT: the working tree WAS clean, and `main` DID match
`origin/main`.

    NEITHER OF THOSE TWO FACTS CAN SEE AN UNLANDED BRANCH, AND BETWEEN THEM
    THEY ARE THE ENTIRE VOCABULARY OF "CLEAN".

`git status` reports the index and the working tree. `git rev-parse main
origin/main` reports one ref against its upstream. A commit sitting on
`teammate-branch` is invisible to both, forever, and the report written from
them is not a lie -- it is an answer to a question nobody asked.

The prose fix landed the same day (engine/skills/rich-lander/SKILL.md 5,
commit 934f127). This file exists because prose is not the fix: this project's
own record has a nine-entry public-root rule, written down, that a file reached
the live public front page past, hours after launch.

===========================================================================
WHAT COUNTS AS UNLANDED WORK -- decided by measurement, not by argument
===========================================================================
The brief that ordered this file was explicit that signal quality IS the job: a
notice that names every branch on the machine is noise, and noise is how a
guard dies. So each narrowing below is a MEASURED number from this machine on
2026-09-06, and the command that produced it is named so the next reader can
re-run it rather than trust the row.

  201  local branches across the five git repositories under ~/ab
       (femcboost 97, richos 88, richos-hq 13, prospects 1,
        li-profile-data-grabber 2)
         git -C <repo> for-each-ref --format='%(refname:short)' refs/heads/

    3  of those have at least one commit not reachable from their own trunk
         git -C <repo> for-each-ref --no-merged=<trunk> refs/heads/
       femcboost worktree-agent-a44e6817bce90ed1c  1 commit   3.4 days
       femcboost worktree-agent-ae878902f589b3815  1 commit   3.4 days
       richos    echo-opus-hm1                     2 commits  0.0 days

    3  survive the second narrowing as well -- commits not reachable from the
       REMOTE trunk either (`git rev-list --count <b> --not <trunk>
       origin/<trunk>`), which suppresses a branch that landed and was pushed
       while the local trunk sat behind its upstream. It removes nothing today
       and it can only ever make this quieter, never louder.

    2  survive the liveness narrowing, and this is the one that decides what
       the operator actually sees at a turn end. The two femcboost branches are
       the `BLOCKED.md` escalations of 2026-09-02: their worktrees are still on
       disk, UNLOCKED, which is the reaper's own positive evidence that the
       agent is gone. `echo-opus-hm1` is a teammate that is running right now.

  THE FIRST FILTER IS WORTH 67x AND COSTS NOTHING. "Branch exists" and "branch
  holds work that is not on main" differ by a factor of 67 on this machine, and
  the 198 it removes are not judgment calls -- they are branches whose every
  commit main already contains.

  THERE IS NO AGE CUTOFF, AND THAT IS DELIBERATE. The obvious next narrowing is
  "and the commits are recent". Measured, EVERY branch ahead of trunk on this
  machine is under four days old, so a cutoff would be a threshold tuned
  against an empty set -- it would remove nothing today and would silently
  remove the finding on the day one matters. Age is CARRIED (it is in every
  finding and in the operator's line) and it decides nothing. A number that
  orders a list is a fact; the same number used as a cutoff is a guess.

===========================================================================
LIVENESS IS THE NARROWING THAT MAKES THIS QUIET ENOUGH TO SURVIVE
===========================================================================
A running teammate's branch is ahead of main BY DESIGN. Announcing it every
turn would name six or seven branches through the middle of every session, and
within a day the line is one the eye skips -- which is the failure this engine
has already recorded three times under three different names.

The incident, though, is specifically about FINISHED work: six branches whose
agents were done. So the predicate is not "ahead of main", it is

    AHEAD OF MAIN, AND NOTHING LIVE IS HOLDING IT.

Liveness is read off the same evidence the worktree reaper is required to use,
and never off a roster (2026-08-31: the roster said `completed`, the lock said
otherwise, and the lock was right):

  1. the branch is checked out in a worktree of its own repository that git
     reports as `locked` -> ALIVE. This is the native-isolation case.
  2. otherwise the ledger (~/.claude/state/worktree-ledger.jsonl) names the
     teammate that registered this branch; that teammate's NATIVE isolation
     worktree, in whichever repository the session is seated in, is present and
     `locked` -> ALIVE. This is the cross-repository case, and it is the common
     one: a hand-rolled worktree takes no git lock of its own, so its owner's
     liveness has never been readable from the tree it is standing in.
  3. anything else -> REPORTED. Includes a present-but-unlocked worktree (the
     reaper's own positive NOT-ALIVE evidence), a worktree that is gone, and a
     branch the ledger has never heard of.

WHAT THIS CANNOT SEE, said here rather than engineered around. If the harness
ever leaves a native worktree locked after its agent ends, that agent's branch
stays silent here. The failure is toward silence, which is the direction this
whole file is arguing against -- so it is stated, and it is bounded: the same
lock is what `remove-agent-worktree.sh` and the reaper refuse to act against,
so a lingering lock is already a condition this engine treats as a defect
elsewhere and would not go unnoticed.

===========================================================================
WHICH REPOSITORIES
===========================================================================
The entity root's MAIN CHECKOUT (never the worktree a hook happens to run in),
plus every repository the worktree ledger records this SESSION as having
prepared or registered a worktree in, plus anything named in
UNLANDED_BRANCHES_EXTRA_REPOS. Measured for this session: femcboost (the seat)
and richos (where every teammate is actually working) -- exactly the two, and
the cross-repository one is the one a seat-only rule would have missed.

With no session id the sweep still runs against the entity root and SAYS SO
(`session_scope: "entity-only"`), because a narrower sweep reported in the same
words as a full one is the defect this engine names most often.

===========================================================================
OUTPUT
===========================================================================
JSON on stdout (--format json, the default), a human report (--format text),
one operator line (--format line), or a KEY<TAB>value block for a shell caller
(--format hook). Exit 0 for json/text/hook; --format line exits 3 when there is
something to say and 0 when there is not, so a caller can branch on the exit
code without parsing anything.

`--format hook` exists so the Stop hook does not have to spawn a SECOND python3
to read this one's JSON. Its keys are STATUS, REASON, KEY, N, NLIVE, SCOPE,
SUMMARY, one per line, value after a tab, and no value may contain a newline --
which is why SUMMARY is built as one line everywhere else in this file.
"""

import argparse
import json
import os
import subprocess
import sys
import time

# RICHOS_WORKTREE_LEDGER is the SAME override scripts/lib/worktree-ledger.py
# already uses, deliberately: one file, one environment variable. A second name
# for one path is a second thing to keep in step with the first, and the tests
# that point this into a sandbox are the tests that point that into a sandbox.
DEFAULT_LEDGER = (os.environ.get("RICHOS_WORKTREE_LEDGER")
                  or os.path.join(os.path.expanduser("~"), ".claude", "state",
                                  "worktree-ledger.jsonl"))
# KEPT ONLY AS THE NAMES A READER MAY SEE IN A MESSAGE. Nothing decides a
# landed/unlanded verdict from this tuple any more: `trunk_of` asks
# workspaces.py for the branch RECORDED for the body of work (point 14).
TRUNK_NAMES = ("main", "master")
GIT_TIMEOUT = 20
# Six is where one line stops being readable. The rest are counted, never lost,
# and the lint script prints all of them. Same number, same reason, as
# notice-unstarted-rows.sh.
MAX_NAMED = 6


def git(root, args, timeout=GIT_TIMEOUT):
    """stdout of `git -C <root> <args>`, or None if git failed at all."""
    try:
        res = subprocess.run(["git", "-C", root] + list(args),
                             capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None
    if res.returncode != 0:
        return None
    return res.stdout


def main_checkout(path):
    """The repository's MAIN checkout, from any worktree of it.

    A hook fires with cwd inside an agent worktree as often as not, and
    `--show-toplevel` there answers with the worktree. `--git-common-dir` is
    the one that always names the real .git, which is what every other
    resolver in this engine uses for the same reason.
    """
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
    # A bare repository has no checkout to land into.
    return None


def read_ledger(path, limit_bytes=32 * 1024 * 1024):
    """[record] from the append-only worktree ledger; [] if unreadable.

    Bounded, tail-first: the ledger is 10k lines today and only grows, and a
    turn-end hook that reads an unbounded file is a turn-end hook that will one
    day time out. Losing the OLDEST rows is the right direction to lose in --
    ownership is a question about recent agents.
    """
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > limit_bytes:
                fh.seek(size - limit_bytes)
                fh.readline()  # discard the partial line the seek landed in
            raw = fh.read().decode("utf-8", "replace")
    except Exception:
        return []
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if isinstance(rec, dict):
            out.append(rec)
    return out


def session_repos(entity_root, session_id, ledger, extra):
    """(sorted repo list, scope) -- the repositories this session has touched."""
    found = []
    scope = "session"

    seat = main_checkout(entity_root)
    if seat:
        found.append(seat)

    if session_id:
        for rec in ledger:
            if rec.get("session_id") != session_id:
                continue
            if rec.get("event") not in ("registered", "prepared"):
                continue
            repo = rec.get("repo") or ""
            if not repo or not os.path.isdir(repo):
                continue
            mc = main_checkout(repo)
            if mc:
                found.append(mc)
    else:
        scope = "entity-only"

    for token in (extra or "").split(":"):
        token = token.strip()
        if token and os.path.isdir(token):
            mc = main_checkout(token)
            if mc:
                found.append(mc)

    return sorted(set(found)), scope


def worktrees_of(repo):
    """({branch: (path, locked)}, [(path, locked)]) for one repository."""
    out = git(repo, ["worktree", "list", "--porcelain"])
    by_branch, all_trees = {}, []
    if out is None:
        return by_branch, all_trees
    state = {"path": None, "branch": None, "locked": False}

    def flush():
        if state["path"] is None:
            return
        all_trees.append((state["path"], state["locked"]))
        if state["branch"]:
            by_branch[state["branch"]] = (state["path"], state["locked"])

    for line in out.splitlines():
        if line.startswith("worktree "):
            flush()
            state = {"path": line[len("worktree "):], "branch": None,
                     "locked": False}
        elif line.startswith("branch refs/heads/"):
            state["branch"] = line[len("branch refs/heads/"):]
        elif line.startswith("locked"):
            state["locked"] = True
    flush()
    return by_branch, all_trees


def trunk_of(repo):
    """The branch a branch here is measured as UNLANDED against — asked of the
    library, never decided here.

    Point 14: "Every part of the system that needs to know whether work has
    landed asks the same question: is it in the branch recorded for this work?
    None of them is allowed its own answer, and none of them assumes main."
    This used to walk TRUNK_NAMES and pick whichever of `main`/`master` existed,
    which is a second answer: in a repository whose work integrates on a dev
    branch, every branch already merged onto that dev branch was reported here
    as unlanded.

    None means ABSTAIN — the caller says it cannot answer and names the
    recording command, and it never falls back to a trunk name.

    Loading the library by path is a duplicated LOADER, not a duplicated
    ANSWER: there is one implementation of the question and it is
    workspaces.py's."""
    lib = os.path.join(os.path.dirname(os.path.abspath(__file__)), "workspaces.py")
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("workspaces_answer", lib)
        ws = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ws)
        branch, _tip, why_not = ws.integration_for(repo)
    except Exception:
        return None
    if why_not or not branch:
        return None
    return branch


def ahead_branches(repo, trunk):
    """[(branch, tip, committer_epoch, n_commits)] genuinely ahead of trunk.

    Two git calls for the whole repository plus one per SURVIVOR -- the wide
    `--no-merged` sweep is 0.24s over 97 branches on this machine, where a
    rev-list per branch would be 97 forks.
    """
    out = git(repo, ["for-each-ref", "--no-merged=" + trunk,
                     "--format=%(refname:short)\t%(committerdate:unix)"
                     "\t%(objectname)", "refs/heads/"])
    if out is None:
        return None
    has_remote = git(repo, ["rev-parse", "--verify", "--quiet",
                            "refs/remotes/origin/" + trunk]) is not None
    exclude = [trunk] + (["origin/" + trunk] if has_remote else [])

    rows = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        branch, ts, tip = parts
        if branch == trunk:
            continue
        cnt = git(repo, ["rev-list", "--count", branch, "--not"] + exclude)
        if cnt is None:
            continue
        try:
            n = int(cnt.strip())
        except ValueError:
            continue
        if n <= 0:
            continue
        try:
            epoch = int(ts)
        except ValueError:
            epoch = 0
        rows.append((branch, tip, epoch, n))
    return rows


def native_lock_index(ledger, cache):
    """{(session_id, teammate): True} for teammates holding a LOCKED native tree.

    The native isolation worktree is the only lock a cross-repository teammate
    ever takes, and it lives in the SESSION's repository rather than the one the
    teammate is working in -- which is the whole reason a hand-rolled worktree
    could never be judged from where it stands.
    """
    index = {}
    for rec in ledger:
        if rec.get("event") != "registered" or rec.get("class") != "native":
            continue
        wt = rec.get("worktree") or ""
        repo = rec.get("repo") or ""
        key = (rec.get("session_id") or "", rec.get("teammate") or "")
        if not wt or not repo or not key[1]:
            continue
        if repo not in cache:
            _, trees = worktrees_of(repo)
            cache[repo] = {os.path.realpath(p): lk for p, lk in trees}
        if cache[repo].get(os.path.realpath(wt)):
            index[key] = True
    return index


def owners_of(ledger, repo, branch):
    """[(session_id, teammate, agent_id)] that ever registered this branch."""
    out = []
    real = os.path.realpath(repo)
    for rec in ledger:
        if rec.get("event") not in ("registered", "prepared"):
            continue
        if rec.get("branch") != branch:
            continue
        rrepo = rec.get("repo") or ""
        if rrepo and os.path.realpath(rrepo) != real:
            continue
        out.append((rec.get("session_id") or "", rec.get("teammate") or "",
                    rec.get("agent_id") or ""))
    return out


def sweep(entity_root, session_id="", ledger_path=None, extra="", now=None):
    now = now if now is not None else time.time()
    ledger_path = ledger_path or DEFAULT_LEDGER
    ledger = read_ledger(ledger_path)
    repos, scope = session_repos(entity_root, session_id, ledger, extra)

    result = {
        "status": "swept",
        "reason": "",
        "session_scope": scope,
        "session": session_id,
        "ledger": ledger_path,
        "ledger_rows": len(ledger),
        "repos": [],
        "findings": [],
        # The branches this sweep deliberately stays QUIET about. Kept rather
        # than counted, because "found nothing" and "found six and judged every
        # one of them live" are the two states a silence hides, and the lint
        # script's whole job is making that difference visible by hand.
        "live": [],
        "n_findings": 0,
        "n_live": 0,
        "key": "",
        "summary": "",
    }

    if not repos:
        result["status"] = "stand-down"
        result["reason"] = ("no git repository resolved from %r, so there is "
                            "nothing whose main this could compare against"
                            % entity_root)
        return result

    lock_cache = {}
    native_locks = native_lock_index(ledger, lock_cache)

    for repo in repos:
        trunk = trunk_of(repo)
        row = {"repo": repo, "label": os.path.basename(repo),
               "trunk": trunk, "n_ahead": 0, "note": ""}
        if trunk is None:
            # NOT silence. A repository with no main and no master is one this
            # check cannot answer for, and an unanswerable repository reported
            # as clean is the shape of every defect this engine is built out of.
            row["note"] = ("no branch is recorded as the one this repository's work "
                           "integrates on, so 'has this landed?' has no reference to be "
                           "asked against (point 14). Record it: workspaces.sh "
                           "integration --repo %s --branch <main|dev/...> --why "
                           "'<this body of work>'" % repo)
            result["repos"].append(row)
            result["status"] = "partial"
            continue

        rows = ahead_branches(repo, trunk)
        if rows is None:
            row["note"] = "git refused to enumerate its branches"
            result["repos"].append(row)
            result["status"] = "partial"
            continue

        by_branch, _ = worktrees_of(repo)
        for branch, tip, epoch, n in rows:
            wt_path, wt_locked = by_branch.get(branch, (None, False))
            owners = owners_of(ledger, repo, branch)

            live_reason = ""
            if wt_locked:
                live_reason = "its worktree %s is locked" % wt_path
            else:
                for sid, teammate, _agent in owners:
                    if native_locks.get((sid, teammate)):
                        live_reason = ("%s holds a locked native isolation "
                                       "worktree" % teammate)
                        break

            teammate = ""
            for _sid, name, _agent in owners:
                if name:
                    teammate = name
                    break

            if wt_path is None:
                state = "no-worktree"
            elif wt_locked:
                state = "locked"
            else:
                state = "unlocked"

            finding = {
                "repo": repo,
                "label": os.path.basename(repo),
                "branch": branch,
                "tip": tip[:12],
                "commits": n,
                "age_days": (round(max(0.0, (now - epoch) / 86400.0), 1)
                             if epoch else None),
                "teammate": teammate,
                "worktree": wt_path,
                "worktree_state": state,
                "live": bool(live_reason),
                "live_reason": live_reason,
                "trunk": trunk,
            }
            row["n_ahead"] += 1
            if live_reason:
                result["n_live"] += 1
                result["live"].append(finding)
            else:
                result["findings"].append(finding)
        result["repos"].append(row)

    # This session's own teammates first, then most recent, then most commits.
    # A finding is a thing to go and land, so the ordering answers "which one
    # first?" rather than sorting by an attribute nobody acts on.
    this_session = set()
    if session_id:
        for rec in ledger:
            if rec.get("session_id") == session_id and rec.get("branch"):
                this_session.add((os.path.realpath(rec.get("repo") or "/"),
                                  rec["branch"]))
    for f in result["findings"] + result["live"]:
        f["this_session"] = (os.path.realpath(f["repo"]),
                             f["branch"]) in this_session
    result["findings"].sort(
        key=lambda f: (not f["this_session"],
                       f["age_days"] if f["age_days"] is not None else 1e9,
                       -f["commits"], f["label"], f["branch"]))

    result["n_findings"] = len(result["findings"])
    result["key"] = "|".join("%s/%s@%s" % (f["label"], f["branch"], f["tip"])
                             for f in result["findings"])
    result["summary"] = summary_line(result)
    return result


def summary_line(result):
    """The one sentence the operator reads. Empty when there is nothing to say."""
    if not result["findings"]:
        return ""
    named = []
    for f in result["findings"][:MAX_NAMED]:
        bits = "%s %s (%d commit%s" % (f["label"], f["branch"], f["commits"],
                                       "" if f["commits"] == 1 else "s")
        if f["age_days"] is not None:
            bits += ", %sd" % f["age_days"]
        if f["teammate"]:
            bits += ", %s" % f["teammate"]
        named.append(bits + ")")
    more = ""
    if result["n_findings"] > MAX_NAMED:
        more = " (+%d more)" % (result["n_findings"] - MAX_NAMED)
    live = ""
    if result["n_live"]:
        live = (" %d other branch(es) are ahead of main and held by a live "
                "teammate, which is normal and is not counted here."
                % result["n_live"])
    return ("UNLANDED WORK, NOBODY HOLDING IT - %d branch(es) ahead of main "
            "that no live worktree claims: %s%s. `git status` and "
            "`main == origin/main` are both TRUE while these exist and neither "
            "can see them, so do not end on the word clean.%s "
            "Detail: scripts/unlanded-branches-lint.sh"
            % (result["n_findings"], "; ".join(named), more, live))


def text_report(result):
    out = ["=== unlanded work: branches ahead of main that no live worktree holds ==="]
    out.append("  status         : %s" % result["status"])
    if result["reason"]:
        out.append("  reason         : %s" % result["reason"])
    out.append("  session        : %s (%s)"
               % (result["session"] or "<none>", result["session_scope"]))
    out.append("  ledger         : %s (%d rows read)"
               % (result["ledger"], result["ledger_rows"]))
    out.append("")
    for row in result["repos"]:
        out.append("  %-28s trunk=%-8s ahead=%d%s"
                   % (row["label"], row["trunk"] or "<none>", row["n_ahead"],
                      ("   " + row["note"]) if row["note"] else ""))
    out.append("")
    if not result["findings"]:
        if result["n_live"]:
            out.append("  Nothing is stranded. %d branch(es) are ahead of main and each"
                       % result["n_live"])
            out.append("  is held by a live teammate, which is what work in progress")
            out.append("  looks like.")
        else:
            out.append("  Nothing ahead of main anywhere this session has touched.")
        out.append("")
    for f in result["findings"]:
        out.append("  %s  %s" % (f["label"], f["branch"]))
        out.append("      %d commit(s) ahead of %s, tip %s, %s days old"
                   % (f["commits"], f["trunk"], f["tip"],
                      f["age_days"] if f["age_days"] is not None else "?"))
        out.append("      owner    : %s" % (f["teammate"] or "not in the ledger"))
        out.append("      worktree : %s (%s)"
                   % (f["worktree"] or "gone", f["worktree_state"]))
        out.append("      land it  : git -C %s merge %s" % (f["repo"], f["branch"]))
        out.append("      or read  : git -C %s log --oneline %s..%s"
                   % (f["repo"], f["trunk"], f["branch"]))
        out.append("")
    # DELIBERATELY QUIET, SHOWN ANYWAY. The notice never names these, and a
    # person reading this by hand must be able to tell "the sweep found
    # nothing" from "the sweep found six and judged every one of them live" --
    # those are the two states a silence hides, and only one of them is health.
    if result["live"]:
        out.append("  ahead of main and NOT reported, because something live holds them:")
        for f in result["live"]:
            out.append("      %-12s %-34s %d commit(s)  %s"
                       % (f["label"], f["branch"], f["commits"],
                          f["live_reason"]))
        out.append("")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--entity-root", required=True)
    ap.add_argument("--session", default="")
    ap.add_argument("--ledger", default=None)
    ap.add_argument("--extra-repos", default="")
    ap.add_argument("--format", choices=("json", "text", "line", "hook"),
                    default="json")
    args = ap.parse_args(argv)

    result = sweep(args.entity_root, args.session, args.ledger,
                   args.extra_repos)

    if args.format == "json":
        sys.stdout.write(json.dumps(result, indent=2) + "\n")
        return 0
    if args.format == "text":
        sys.stdout.write(text_report(result) + "\n")
        return 0
    if args.format == "hook":
        def one(v):
            return str(v).replace("\n", " ").replace("\t", " ")
        for k, v in (("STATUS", result["status"]),
                     ("REASON", result["reason"]),
                     ("SCOPE", result["session_scope"]),
                     ("N", result["n_findings"]),
                     ("NLIVE", result["n_live"]),
                     ("KEY", result["key"]),
                     ("SUMMARY", result["summary"])):
            sys.stdout.write("%s\t%s\n" % (k, one(v)))
        return 0
    if result["summary"]:
        sys.stdout.write(result["summary"] + "\n")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
