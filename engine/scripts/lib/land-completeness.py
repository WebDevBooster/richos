#!/usr/bin/env python3
"""land-completeness.py — IS THE LAST LAND ACTUALLY FINISHED?

Answers, for one repository, the four questions
`docs/plans/land-completeness-2026-09-10.md` §5 requires of a reporting
surface, and answers them in a way that cannot round a gap to silence:

  1. which lands are incomplete
  2. which worktrees are registered without a live owner
  3. which branches are merged and unreclaimed
  4. WHICH OF THOSE IT COULD NOT DECIDE

This is the analysis half. `scripts/land-completeness.sh` is the command a
person runs; `scripts/hooks/guard-ci-red-lands.sh` calls the same module at the
one moment the answer changes what happens next — a land.

===========================================================================
THE FINDING THAT SHAPED THE PREDICATE, AND IT NEARLY KILLED THE DESIGN
===========================================================================
The obvious predicate is "a worktree whose owner is NOT-ALIVE". Measured
against real state on 2026-09-10, that predicate FIRES ALMOST NEVER, and the
reason is structural rather than incidental:

    python3 scripts/lib/worktree-ledger.py judge \
        --entity /Users/alex/ab/femcboost \
        --worktree /Users/alex/ab/richos-wt/zach-opus-prem1 --no-write
    -> INDETERMINATE
       "no native isolation worktree is registered for agent ... while its
        session pid 8799 is still running; decidable once that session ends
        (absence is not a termination signal)"

An agent's native isolation worktree — the thing that carries the lock — is
DESTROYED AT LAND TIME. That is the whole reason `worktree-ledger.py` exists.
So the moment a land completes, its author becomes permanently INDETERMINATE
for as long as the session lives, and every worktree the CURRENT session
created is INDETERMINATE by construction. A gate keyed on NOT-ALIVE would
therefore have been silent through all twenty-two of the consecutive lands
that produced this requirement, and would only ever have fired on residue
inherited from a session that had already exited.

    A GATE THAT CANNOT FIRE ON THE INCIDENT IT WAS WRITTEN FOR IS NOT A GATE.

===========================================================================
SO THE EVIDENCE IS THE MERGE, AND LIVENESS ONLY EVER EXCUSES
===========================================================================
This module never claims an agent is dead. It claims two facts, both of them
checkable, neither of them an inference about a process:

    THE BRANCH IS AN ANCESTOR OF main      (git says so)
    THE WORKTREE IS STILL REGISTERED       (git worktree list says so)

A merged branch whose worktree is still registered is an incomplete land by
definition — the merge already happened, so whatever the directory is for, it
is not for work that has yet to land. Liveness enters in ONE direction only:

    owner ALIVE (a native isolation worktree LOCKED by a running pid)
        -> EXEMPT. Its author is still working; the follow-up commit is real.

INDETERMINATE does not exempt, and that is a deliberate departure from how the
REAPER treats the same verdict. The difference is what the verdict authorizes:

    the reaper DELETES.   Deleting live work is unrecoverable, so it demands
                          positive evidence of death and treats INDETERMINATE
                          as "do not touch". That rule is correct and this work
                          does not weaken it by one clause.
    this REFUSES A LAND.  It removes nothing. Its worst case when it is wrong
                          is one sentence of explanation on a command line.

Costs that differ by that much do not get the same evidence bar. What this
never does is *report* INDETERMINATE as death: the verdict is carried through
to the output verbatim, and the status command prints it in its own column.

===========================================================================
THE THREE THINGS THIS DELIBERATELY WILL NOT DO
===========================================================================
1. AN UNMERGED BRANCH IS NEVER NAMED AS RESIDUE. R3, and 2026-09-10 is the
   proof: two agents were killed on an inference and one's only commit
   survived solely because it sat on an unmerged branch that nothing was
   permitted to touch. Unmerged appears in this report as `retained-unmerged`,
   which is a first-class disposition with a reason attached, and it can never
   become an `incomplete-land`.

2. A WORKTREE WITH NO OWNERSHIP RECORD IS NEVER BLOCKED ON. Five worktrees on
   this machine belong to a Codex CLI that this ledger will never hear about.
   They are reported as `unowned` — loudly, in the unknown column, never
   rounded to clean — but a gate that refuses on them would be refusing on a
   fact it had not established, which is how `guard-ci-red-lands.sh` argues
   itself into allowing when it cannot look, and how g11/g12/g13 died.

3. NOTHING IS INFERRED FROM A NAME. Ownership is by exact worktree path, as
   `worktree-ledger.py` requires: names are reusable across sessions and a
   verdict keyed on one can name a later, unrelated tree.

===========================================================================
WHAT IT DOES NOT EXAMINE — written by the person who built it
===========================================================================
* Worktrees of OTHER repositories. One call, one repository. The status
  command takes several and reports each separately.
* Whether a removed worktree's ARTIFACTS were collected first. That is a
  separate step of the land sequence with its own script
  (`collect-worktree-artifacts.sh`) and this cannot see whether it ran.
* Whether an unmerged branch SHOULD have been merged. It reports that it is
  unmerged and stops; deciding is a person's job.
* Remote branches. Merge status is judged against the LOCAL main, because the
  local main is what the next land merges into.
* A worktree registered in git but whose directory has been deleted from disk
  by hand. It is reported as `missing-on-disk`, in the unknown column, because
  `git worktree list` still carries it and something has to say so.
"""

import importlib.util
import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))

# Dispositions. §5 demands removed / retained-with-a-reason / unknown, and
# insists that RETAINED SILENTLY is the defect — so every one of these carries
# its reason into the output rather than being a bare label.
INCOMPLETE_LAND = "incomplete-land"      # merged + registered + not alive -> the gate
LIVE = "live"                            # retained: its owner is running
RETAINED_UNMERGED = "retained-unmerged"  # retained: never swept, by rule
QUARANTINED = "quarantined"              # retained: retired by workspace-retire, registered by design
UNOWNED = "unowned"                      # unknown: no ownership record
UNKNOWN_MERGE = "unknown-merge"          # unknown: merge status undecidable
MISSING_ON_DISK = "missing-on-disk"      # unknown: registered, not present
UNRECLAIMED_BRANCH = "unreclaimed-branch"          # merged ref, no worktree
RETAINED_UNMERGED_BRANCH = "retained-unmerged-branch"

BLOCKING = (INCOMPLETE_LAND,)
UNKNOWN_CLASSES = (UNOWNED, UNKNOWN_MERGE, MISSING_ON_DISK)


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _ledger_module():
    """The ownership record, imported rather than shelled out to.

    One process for the whole report: `judge` is called once per worktree and a
    subprocess apiece would put a dozen python starts inside a PreToolUse hook
    that has to answer inside its timeout.
    """
    try:
        return _load("worktree_ledger", os.path.join(HERE, "worktree-ledger.py"))
    except Exception:
        return None


def _git(repo, *args):
    """A git read. Returns (ok, output). NEVER raises — a repository that
    cannot be read has to become an `unknown` line in the report, not a
    traceback that takes the whole answer with it."""
    try:
        p = subprocess.run(("git", "-C", repo) + args, capture_output=True,
                           text=True, timeout=15)
        return p.returncode == 0, (p.stdout or "").strip()
    except Exception as exc:
        return False, str(exc)


def _worktrees(repo):
    """Every LINKED worktree of `repo`, with its branch.

    THE MAIN CHECKOUT IS EXCLUDED BY IDENTITY, NOT BY COMPARING IT TO THE PATH
    WE WERE HANDED, and that distinction is a bug this had. `git worktree list`
    reports the whole set from ANY member of it, so when this is called with a
    LINKED worktree as `repo` — which happens whenever the status command is run
    from inside one, i.e. every time an agent runs it — excluding
    `realpath(repo)` removes the caller's own directory and leaves the MAIN
    CHECKOUT in the list. It was then judged like an agent's worktree: on
    2026-09-10 a multi-repository run reported `/Users/alex/ab/richos` itself,
    on branch `main`, as an undecided item.

    Removing a main checkout is not a step of any land, so it is excluded on the
    two facts git itself provides: it is always the FIRST record, and its `.git`
    is a DIRECTORY where a linked worktree's is a FILE. Either alone would do;
    both are used because the cost is nothing and the failure mode is naming the
    operator's own checkout as residue.
    """
    ok, out = _git(repo, "worktree", "list", "--porcelain")
    if not ok:
        return None
    entries, cur = [], {}
    for line in out.split("\n"):
        if line.startswith("worktree "):
            if cur:
                entries.append(cur)
            cur = {"path": line[len("worktree "):].strip(), "branch": "", "locked": False,
                   "lock_line": "", "detached": False}
        elif line.startswith("branch "):
            cur["branch"] = line[len("branch "):].strip().replace("refs/heads/", "")
        elif line.startswith("locked"):
            cur["locked"] = True
            cur["lock_line"] = line[len("locked"):].strip()
        elif line.strip() == "detached":
            cur["detached"] = True
    if cur:
        entries.append(cur)
    return [e for i, e in enumerate(entries)
            if i != 0 and not os.path.isdir(os.path.join(e["path"], ".git"))]


def _merge_status(repo, branch, main):
    """merged / unmerged / None.

    `merge-base --is-ancestor` and nothing else: it answers "is every commit of
    this branch already in main", which is the only question that matters for
    deciding whether the directory is still holding unlanded work. None means
    the question could not be answered, and None is never rounded.
    """
    if not branch:
        return None
    try:
        p = subprocess.run(("git", "-C", repo, "merge-base", "--is-ancestor", branch, main),
                           capture_output=True, text=True, timeout=15)
    except Exception:
        return None
    if p.returncode == 0:
        return "merged"
    if p.returncode == 1:
        return "unmerged"
    return None


def _entities_for(worktree, records, mod, repo):
    """Which repositories' worktree LOCKS can speak for this worktree's owner?

    THE ENTITY IS THE OWNER'S SESSION REPOSITORY, NOT THE WORKTREE'S. A
    cross-repository worktree in `richos-wt/` is owned by an agent whose native
    isolation worktree — the one that carries the lock — lives in its SESSION's
    repository, which is usually a different one entirely. Judging such a path
    with `--entity <the worktree's own repo>` finds no native worktree and
    returns INDETERMINATE for a LIVE agent. Verified on 2026-09-10 against a
    running agent: `--entity /Users/alex/ab/richos` said INDETERMINATE and
    `--entity /Users/alex/ab/femcboost` said ALIVE, for the same path, at the
    same moment.

    So every repository the owner has a registration in is asked, and ALIVE
    from any of them is decisive — a lock held by a running process is
    positive evidence of life wherever it is found.

    ROUND 15 (2026-09-11): the same join now lives INSIDE the judge
    (worktree-ledger._lock_entities — the ledger's native rows, the
    transaction's own native member, then the caller's entity), so a single
    call with the wrong entity can no longer reach the terminal record while
    a shell is locked elsewhere. This list is kept as a second, cheaper
    reading for the report; it is no longer what protects the verdict.
    """
    ents = [repo]
    try:
        regs = mod.registrations(records, worktree=worktree)
        ids = {r.get("agent_id") for r in regs if r.get("agent_id")}
        for rec in records:
            if rec.get("agent_id") in ids and rec.get("repo"):
                if rec["repo"] not in ents:
                    ents.append(rec["repo"])
    except Exception:
        pass
    return ents


def _judge_owner(worktree, records, mod, repo, liveness):
    """ALIVE / NOT-ALIVE / INDETERMINATE / UNRESOLVED, with its reason.

    `liveness` IS NOT OPTIONAL AND ITS ABSENCE IS NOT A DEGRADED MODE — it is a
    silently wrong one. `worktree-ledger.judge()` takes the liveness module as a
    keyword argument that DEFAULTS TO None, and with None it cannot read a
    worktree lock, so every verdict it can still reach is INDETERMINATE. Called
    that way this report classified a RUNNING AGENT'S OWN WORKTREE as an
    incomplete land, on 2026-09-10, against live state: the exemption that
    exists to protect live work was off, and nothing said so. The module is
    therefore loaded once by `analyze()` and passed explicitly, and if it cannot
    be loaded every owner becomes UNRESOLVED — which never blocks — rather than
    INDETERMINATE, which does.
    """
    if mod is None:
        return "UNRESOLVED", "the ownership ledger could not be loaded", []
    if liveness is None:
        return "UNRESOLVED", ("the liveness module could not be loaded, so no worktree lock could "
                              "be read and NO owner was judged"), []
    best, reason, ids = None, "", []
    for entity in _entities_for(worktree, records, mod, repo):
        try:
            res = mod.judge(entity, worktree, [], records, None, liveness, False, None)
        except Exception as exc:
            best, reason = best or "UNRESOLVED", "judging failed: %s" % exc
            continue
        v, why = res.get("verdict"), res.get("reason") or ""
        # The agent ids the judgment rested on ride along, so a blocking row
        # can print a remover command that actually runs (round 14, O1: the
        # gate printed a bare path, which exits 2 with usage).
        for aid in res.get("agent_ids") or []:
            if aid and aid not in ids:
                ids.append(aid)
        if v == "ALIVE":
            return v, why, ids
        if best is None or (best == "UNRESOLVED" and v != "UNRESOLVED"):
            best, reason = v, why
    return (best or "UNRESOLVED"), reason, ids


def main_checkout(path):
    """The MAIN CHECKOUT of whatever repository `path` belongs to.

    A main checkout and every linked worktree of it share one repository and one
    worktree list, so they are the same subject and must resolve to one name.
    Without this the status command double-counted: run from inside an agent's
    worktree it resolves `git rev-parse --show-toplevel` to that worktree, the
    ownership ledger separately yields the main checkout, and both enumerate the
    identical set — 2026-09-10 reported `repositories: 6` and 50 worktrees over
    what were really four repositories.

    `--git-common-dir` is the same for every member of a repository, which is
    exactly the identity wanted; its parent is the main checkout. Anything that
    cannot be resolved is returned unchanged rather than guessed at.
    """
    ok, common = _git(path, "rev-parse", "--git-common-dir")
    if not ok or not common:
        return path
    if not os.path.isabs(common):
        common = os.path.join(path, common)
    root = os.path.dirname(os.path.abspath(common))
    return root if os.path.isdir(root) else path


def integration_branch(repo):
    """(branch, why_not) — THE ONE ANSWER, asked of the library and never kept
    here. Point 14: "Every part of the system that needs to know whether work
    has landed asks the same question: is it in the branch recorded for this
    work? None of them is allowed its own answer, and none of them assumes
    main."

    This used to default to the string "main", which is exactly an answer of its
    own: on a repository whose work integrates on a dev branch it reported
    unmerged worktrees that had landed perfectly well. Where nothing is
    recorded, it ABSTAINS and names the recording command; it never guesses.

    Loading the library by path is duplicated across the consumers. That is a
    duplicated LOADER, not a duplicated ANSWER: there is still exactly one
    implementation of the question, and it is workspaces.py's."""
    lib = os.path.join(os.path.dirname(os.path.abspath(__file__)), "workspaces.py")
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("workspaces_answer", lib)
        ws = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ws)
        branch, _tip, why_not = ws.integration_for(repo)
    except Exception as e:                       # the library itself is unreadable
        return "", ("the branch this work integrates on could not be read from %s: %s" % (lib, e))
    return branch, why_not


def analyze(repo, main="", ledger=None):
    """The whole answer for one repository.

    `main` is the branch to measure against. Empty means ASK THE LIBRARY, which
    is what every caller should do; passing one explicitly is a caller naming
    the branch, which is different from this file keeping a default."""
    if os.path.isdir(repo):
        repo = main_checkout(repo)
    abstain = ""
    if not main:
        main, abstain = integration_branch(repo)
    report = {
        "repo": repo,
        "main": main,
        "abstained": abstain,
        "worktrees": [],
        "branches": [],
        "not_examined": [],
        "counts": {},
    }

    if not os.path.isdir(repo):
        report["not_examined"].append(
            {"what": repo, "why": "not a directory — the whole repository went unexamined"})
        report["counts"] = _counts(report)
        return report

    ok, head = _git(repo, "rev-parse", "--short", "HEAD")
    report["head"] = head if ok else ""
    if abstain:
        # ABSTAIN, never assume main (point 14). Nothing is recorded as the
        # branch this work integrates on, so there is no fact to test a land
        # against and "landed" would go back to meaning whatever main happens
        # to have. Every item is reported UNEXAMINED with the command that
        # would settle it, which is a verdict a reader can act on; a guess
        # dressed as a merge status is not.
        report["not_examined"].append({"what": repo, "why": abstain})
        report["counts"] = _counts(report)
        return report
    ok_main, _ = _git(repo, "rev-parse", "--verify", main)
    if not ok_main:
        report["not_examined"].append(
            {"what": "%s (%s)" % (repo, main),
             "why": "the branch '%s' does not resolve, so NO merge status could be decided for "
                    "any branch or worktree in this repository" % main})
        report["counts"] = _counts(report)
        return report

    mod = _ledger_module()
    records = []
    liveness = None
    if mod is not None:
        try:
            records = mod.read_all(ledger)
        except Exception as exc:
            report["not_examined"].append(
                {"what": "the ownership ledger",
                 "why": "could not be read (%s), so EVERY owner below is unknown" % exc})
        try:
            liveness = mod._liveness_module()
        except Exception:
            liveness = None
        if liveness is None:
            report["not_examined"].append(
                {"what": "every worktree lock in this repository",
                 "why": "the liveness module could not be loaded, so no owner could be shown to "
                        "be ALIVE; every owner below is reported UNRESOLVED and nothing is "
                        "blocked on"})
    else:
        report["not_examined"].append(
            {"what": "every owner in this repository",
             "why": "the ownership ledger module could not be loaded"})

    entries = _worktrees(repo)
    if entries is None:
        report["not_examined"].append(
            {"what": "%s worktree list" % repo,
             "why": "`git worktree list` failed, so no worktree in this repository was examined"})
        entries = []

    seen_branches = set()
    for e in entries:
        path, branch = e["path"], e["branch"]
        if branch:
            seen_branches.add(branch)
        present = os.path.isdir(path)
        merged = _merge_status(repo, branch, main) if branch else None
        owner, why, owner_ids = _judge_owner(path, records, mod, repo, liveness)
        quarantined = "/.richos-retired/" in (path.rstrip("/") + "/")

        # ORDER MATTERS AND IS THE SAFETY ARGUMENT. Live first, so a running
        # agent is never named. Unmerged next, so R3's protection outranks
        # every other consideration including a missing directory. Only then
        # can anything become blocking.
        if owner == "ALIVE":
            disp, reason = LIVE, "its owner is running: %s" % why
        elif quarantined:
            # A workspace remove-agent-worktree / workspace-retire has already
            # preserved, verified and RENAMED to quarantine. That route keeps
            # the git registration by design (repaired to the quarantine path;
            # `workspace-retire.py sweep` owns registration removal), so the
            # tree is still in `git worktree list` on a merged branch with no
            # ownership record for its new path. Until round 14 this report
            # called it `unowned` and could not decide it -- four such trees
            # on 2026-09-10 (O1). It is decided: retired, not a land, not
            # residue, and never blocking.
            disp, reason = QUARANTINED, (
                "renamed to quarantine by the retired workspace-retire route (removed 2026-09-11); "
                "still registered with git; not a land, not residue")
        elif merged == "unmerged":
            disp, reason = RETAINED_UNMERGED, (
                "its branch has commits that are NOT in %s — never swept, by rule, and never "
                "reported as residue. READ IT before removing anything." % main)
        elif merged is None:
            disp, reason = UNKNOWN_MERGE, (
                "the merge status of '%s' could not be decided, so this worktree was NOT judged"
                % (branch or "(detached)"))
        elif not present:
            disp, reason = MISSING_ON_DISK, (
                "git still registers this worktree but the directory is not there; `git worktree "
                "prune` is the resolution, and until then nothing here was judged")
        elif owner == "UNRESOLVED":
            disp, reason = UNOWNED, (
                "no ownership record for this exact path, so whose it is was NOT established: %s"
                % why)
        else:
            disp, reason = INCOMPLETE_LAND, (
                "'%s' is already merged into %s and its worktree is still registered; owner "
                "verdict %s — %s" % (branch, main, owner, why))

        report["worktrees"].append({
            "path": path, "branch": branch, "merged": merged, "present": present,
            "locked": e["locked"], "owner": owner, "owner_reason": why,
            "owner_agent_ids": owner_ids,
            "disposition": disp, "reason": reason,
        })

    # ------------------------------------------------------------------
    # BRANCHES ARE A DIFFERENT OBJECT FROM WORKTREES (R4)
    # ------------------------------------------------------------------
    # Removing a directory leaves the ref behind. The nightly lane removes both
    # and reported `worktrees_removed=34 branches_deleted=34`; the hand-run
    # reaper removes neither ref. So both are counted, separately, and a merged
    # branch whose worktree is already gone is a NAMED benign state rather than
    # silence.
    ok, out = _git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/")
    if not ok:
        report["not_examined"].append(
            {"what": "%s branches" % repo,
             "why": "the ref list could not be read, so NO branch was examined"})
    else:
        for branch in [b for b in out.split("\n") if b.strip()]:
            if branch == main or branch in seen_branches:
                continue
            merged = _merge_status(repo, branch, main)
            if merged == "merged":
                disp, reason = UNRECLAIMED_BRANCH, (
                    "merged into %s and its worktree is already gone — benign, and named rather "
                    "than silent" % main)
            elif merged == "unmerged":
                disp, reason = RETAINED_UNMERGED_BRANCH, (
                    "has commits not in %s and no worktree — never swept, by rule" % main)
            else:
                disp, reason = UNKNOWN_MERGE, "its merge status could not be decided"
            report["branches"].append({"branch": branch, "merged": merged,
                                       "disposition": disp, "reason": reason})

    report["counts"] = _counts(report)
    return report


def _counts(report):
    c = {"worktrees": len(report["worktrees"]), "branches": len(report["branches"]),
         "incomplete_lands": 0, "live": 0, "retained_unmerged": 0, "quarantined": 0, "unknown": 0,
         "unreclaimed_branches": 0, "retained_unmerged_branches": 0,
         "not_examined": len(report["not_examined"])}
    for w in report["worktrees"]:
        d = w["disposition"]
        if d == INCOMPLETE_LAND:
            c["incomplete_lands"] += 1
        elif d == LIVE:
            c["live"] += 1
        elif d == RETAINED_UNMERGED:
            c["retained_unmerged"] += 1
        elif d == QUARANTINED:
            c["quarantined"] += 1
        elif d in UNKNOWN_CLASSES:
            c["unknown"] += 1
    for b in report["branches"]:
        d = b["disposition"]
        if d == UNRECLAIMED_BRANCH:
            c["unreclaimed_branches"] += 1
        elif d == RETAINED_UNMERGED_BRANCH:
            c["retained_unmerged_branches"] += 1
        elif d in UNKNOWN_CLASSES:
            c["unknown"] += 1
    return c


def blocking_items(report):
    """What a gate would refuse over. Exactly the incomplete lands, never the
    unknowns and never the unmerged."""
    return [w for w in report["worktrees"] if w["disposition"] in BLOCKING]


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(prog="land-completeness.py")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--main", default="",
                    help="the branch to measure against. Omit it and the branch RECORDED for "
                         "this body of work is asked of scripts/lib/workspaces.py (point 14); "
                         "there is no default of 'main' and never was one that was right.")
    ap.add_argument("--ledger", default=None)
    a = ap.parse_args()
    print(json.dumps(analyze(a.repo, a.main, a.ledger), indent=2))
