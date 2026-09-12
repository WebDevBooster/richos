#!/usr/bin/env python3
"""Seven cases, one command, against ANY scripts/lib/workspaces.py.

    python3 -B workspace-attribution-seven-cases.probe.py <path-to-workspaces.py> [case ...]

Run it against the parent (`git show 65dad4d4:engine/scripts/lib/workspaces.py`)
and against the branch; the DIFFERENCE is the proof. It imports no engine test
file and drives the library through the same entry points the hooks use:

    PreToolUse  (matcherless)  guard-sealed-worktree.sh  -> barrier()
    PostToolUse (matcherless)  observe-created-refs.sh   -> observe()
    SubagentStart / PostToolUse[Agent] / SubagentStop    -> record_start /
                                                           bind_agent / record_end

A library that has no `observe` (the parent) is driven with the PreToolUse half
alone, which is all it had; nothing is faked on its behalf.

    1 stray                 a branch created in a workspace and never checked
                            out goes with the agent
    2 side-branch           a side branch committed to and switched away from
                            blocks the land until it is merged or discarded
    3 borrowed              a pre-existing branch the agent only checked out
                            survives a discard
    4 rich                  a branch Rich cuts in the main checkout is never
                            the agent's
    5 two-agents            two agents in one repository both land cleanly;
                            neither takes the other's refs
    6 dev-branch            work merged into the dev branch but not main counts
                            as landed, and its workspaces and branches are
                            deleted
    7 merged-nowhere        work merged nowhere does not count as landed

EVERYTHING IS SANDBOXED. HOME, CLAUDE_CONFIG_DIR, TMPDIR, GIT_CONFIG_GLOBAL and
RICHOS_WORKSPACES_DIR are redirected into a temporary directory that is removed
at the end; the operator's real registry, sessions and repositories are never
read or written. Exit 0 when every case selected holds, 1 otherwise.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import time

CASES = ["stray", "side-branch", "borrowed", "rich", "two-agents", "dev-branch", "merged-nowhere"]


def run(*args, **kw):
    r = subprocess.run(list(args), capture_output=True, text=True, env=os.environ.copy())
    if kw.get("check", True) and r.returncode != 0:
        raise AssertionError("%s failed: %s %s" % (args, r.stdout, r.stderr))
    return r.stdout.strip()


def out(label, value):
    print("    %-34s %s" % (label, value))


class Sandbox(object):
    def __init__(self, lib):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="ws-seven-"))
        os.environ["HOME"] = os.path.join(self.root, "home")
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(self.root, "home", ".claude")
        os.environ["TMPDIR"] = os.path.join(self.root, "tmp")
        os.environ.pop("RICHOS_WORKSPACES_DIR", None)
        os.environ.pop("RICHOS_SESSION_ID", None)
        os.environ["RICHOS_WORKSPACES_SPAWN_WINDOW"] = "0"
        os.environ["RICHOS_WORKSPACES_RETRY_BASE"] = "0"
        os.makedirs(os.environ["CLAUDE_CONFIG_DIR"])
        os.makedirs(os.environ["TMPDIR"])
        gc = os.path.join(self.root, "home", ".gitconfig")
        with open(gc, "w") as f:
            f.write("[user]\n\tname = probe\n\temail = probe@example.invalid\n"
                    "[init]\n\tdefaultBranch = main\n")
        os.environ["GIT_CONFIG_GLOBAL"] = gc
        spec = importlib.util.spec_from_file_location("workspaces_under_test", lib)
        self.ws = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.ws)
        self.procs = []
        self.entity = self.repo("entity")
        self.other = self.repo("other")
        self.sid = "sess-probe-11111111"
        self.session(self.sid, self.entity)

    def repo(self, name):
        p = os.path.join(self.root, name)
        os.makedirs(p)
        run("git", "init", "-q", "-b", "main", p)
        with open(os.path.join(p, "README"), "w") as f:
            f.write("x\n")
        run("git", "-C", p, "add", "-A")
        run("git", "-C", p, "commit", "-q", "-m", "init")
        return p

    def session(self, sid, cwd):
        pr = subprocess.Popen(["sleep", "600"])
        self.procs.append(pr)
        os.environ["RICHOS_SESSION_PID"] = str(pr.pid)
        time.sleep(0.05)
        self.ws.record_session_start(sid, cwd)

    def close(self):
        for pr in self.procs:
            try:
                pr.kill()
                pr.wait()
            except OSError:
                pass
        shutil.rmtree(self.root, ignore_errors=True)

    # --- the entry points the hooks use ----------------------------------
    def make_cc(self, name, repo=None, base="HEAD"):
        repo = repo or self.other
        path = os.path.join(self.root, os.path.basename(repo) + "-wt", name)
        self.ws.register_cc(self.sid, name, repo, path, "cc/" + name)
        run("git", "-C", repo, "worktree", "add", "-q", path, "-b", "cc/" + name, base)
        self.ws.confirm_cc(self.sid, name, path, True)
        return path

    def spawn(self, name, cc=None):
        prompt = "do it\n" + ("cross-repo-worktree: %s\n" % cc if cc else "")
        self.ws.register_spawn({"session_id": self.sid, "tool_use_id": "tu-" + name,
                                "tool_name": "Agent",
                                "tool_input": {"name": name, "subagent_type": "zach",
                                               "prompt": prompt, "isolation": "worktree"}},
                               self.entity)
        aid = "a" + name.replace("-", "")[:12] + "0000"
        npath = os.path.join(self.entity, ".claude", "worktrees", "agent-" + aid)
        run("git", "-C", self.entity, "worktree", "add", "-q", npath, "-b", "worktree-agent-" + aid)
        self.ws.record_start(self.sid, aid, npath, "zach")
        self.ws.bind_agent(self.sid, "tu-" + name, aid, self.entity)
        return aid, npath

    def pre(self, aid):
        return self.ws.barrier({"session_id": self.sid, "agent_id": aid})

    def post(self, aid):
        if not hasattr(self.ws, "observe"):
            return []          # the parent has no second half; nothing is faked for it
        return self.ws.observe({"session_id": self.sid, "agent_id": aid,
                                "hook_event_name": "PostToolUse", "tool_name": "Bash"})

    def call(self, aid):
        v = self.pre(aid)
        self.post(aid)
        return v

    def commit(self, path, fname):
        with open(os.path.join(path, fname), "w") as f:
            f.write("work\n")
        run("git", "-C", path, "add", fname)
        run("git", "-C", path, "commit", "-q", "-m", "work " + fname)

    def finish(self, aid):
        self.ws.record_end(self.sid, aid, "SubagentStop")

    def rec(self, name):
        return self.ws.load_agent(self.ws.named_key(self.sid, name)) or {}

    def created(self, name):
        return sorted(b for _r, b in (tuple(x) for x in (self.rec(name).get("created_branches") or [])))

    def branches(self, repo):
        return sorted(run("git", "-C", repo, "for-each-ref", "--format=%(refname:short)",
                          "refs/heads").split())

    def land(self, name):
        try:
            self.ws.land(name, self.sid)
            return "landed"
        except Exception as e:                                  # SpecError, by design
            return "REFUSED: %s" % str(e)[:160]

    def dev(self, repo, branch, why):
        """Record the branch this work integrates on (point 14), if the library
        under test has the mechanism at all."""
        run("git", "-C", repo, "branch", branch)
        if not hasattr(self.ws, "record_integration"):
            return False
        self.ws.record_integration(repo, branch, why, self.sid)
        return True

    def ff(self, repo, onto, branch):
        run("git", "-C", repo, "branch", "-f", onto, run("git", "-C", repo, "rev-parse", branch))


# ---------------------------------------------------------------------------
def case_stray(s):
    """1. A branch created in a workspace and never checked out goes with the agent."""
    aid, npath = s.spawn("zach-opus-p1")
    s.call(aid)
    s.pre(aid)
    s.commit(npath, "own.txt")
    run("git", "-C", npath, "branch", "spare")          # checked out NOWHERE
    s.post(aid)
    out("created_branches", s.created("zach-opus-p1"))
    s.finish(aid)
    verdict = s.land("zach-opus-p1")
    out("land before the stray is merged", verdict)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land after its branch is merged", s.land("zach-opus-p1"))
    after = s.branches(s.entity)
    out("branches after the land", after)
    return "spare" not in after


def case_side_branch(s):
    """2. A side branch committed to and switched away from blocks the land."""
    aid, npath = s.spawn("zach-opus-p2")
    s.pre(aid)
    run("git", "-C", npath, "checkout", "-q", "-b", "tmpwork")
    s.commit(npath, "side.txt")
    run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
    s.post(aid)
    out("created_branches", s.created("zach-opus-p2"))
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    held = s.land("zach-opus-p2")
    out("land with the side branch out", held)
    pend = sorted(i["name"] for i in s.ws.pending(s.sid, s.entity, scan=True))
    out("pending", pend)
    log = run("git", "-C", s.entity, "log", "--format=%s", "main")
    out("its side-branch commit in main", "work side.txt" in log)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "tmpwork")
    out("land once it is merged", s.land("zach-opus-p2"))
    return held.startswith("REFUSED") and "tmpwork" in held and pend == ["zach-opus-p2"]


def case_borrowed(s):
    """3. A pre-existing branch the agent only checked out survives a discard."""
    keep = os.path.join(s.root, "human-wt")
    run("git", "-C", s.entity, "worktree", "add", "-q", keep, "-b", "human/keep")
    s.commit(keep, "human.txt")
    tip = run("git", "-C", s.entity, "rev-parse", "human/keep")
    run("git", "-C", s.entity, "worktree", "remove", "--force", keep)
    aid, npath = s.spawn("zach-opus-p3")
    s.pre(aid)
    run("git", "-C", npath, "checkout", "-q", "human/keep")      # borrowed, not created
    s.post(aid)
    s.call(aid)                                                  # and still on it at its next call
    out("created_branches", s.created("zach-opus-p3"))
    s.finish(aid)                                                # ...and at its end of run
    s.ws.discard("zach-opus-p3", "the reviewer rejected the approach",
                 not_ceo_ordered="a probe of branch attribution, not the CEO's order", me=s.sid)
    alive = "human/keep" in s.branches(s.entity)
    out("human/keep survived the discard", alive)
    out("its tip is unchanged", alive and run("git", "-C", s.entity, "rev-parse", "human/keep") == tip)
    return alive


def case_rich(s):
    """4. A branch Rich cuts in the main checkout is never the agent's."""
    aid, npath = s.spawn("zach-opus-p4")
    s.call(aid)
    s.commit(npath, "own.txt")
    s.pre(aid)
    run("git", "-C", s.entity, "branch", "rich/notes")
    look = os.path.join(s.root, "rich-look")
    run("git", "-C", s.entity, "worktree", "add", "-q", look, "-b", "rich/look")
    s.commit(look, "rich.txt")                                   # his own unlanded commit
    s.post(aid)
    out("created_branches", s.created("zach-opus-p4"))
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land", s.land("zach-opus-p4"))
    after = s.branches(s.entity)
    out("branches after the land", after)
    return "rich/notes" in after and "rich/look" in after and s.created("zach-opus-p4") == []


def case_two_agents(s):
    """5. Two agents in one repository both land cleanly; neither takes the other's."""
    a_cc = s.make_cc("zach-opus-p5a")
    aid_a, npath_a = s.spawn("zach-opus-p5a", cc=a_cc)
    s.pre(aid_a)                                                 # A's call is open...
    b_cc = s.make_cc("zach-opus-p5b")                            # ...while all of B appears
    aid_b, npath_b = s.spawn("zach-opus-p5b", cc=b_cc)
    s.call(aid_b)
    s.commit(npath_b, "b.txt")
    s.commit(b_cc, "bcc.txt")
    s.post(aid_a)
    out("A.created_branches", s.created("zach-opus-p5a"))
    out("B.created_branches", s.created("zach-opus-p5b"))
    s.commit(npath_a, "a.txt")
    s.commit(a_cc, "acc.txt")
    s.finish(aid_a)
    s.finish(aid_b)
    for aid in (aid_a, aid_b):
        run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    for b in ("cc/zach-opus-p5a", "cc/zach-opus-p5b"):
        run("git", "-C", s.other, "merge", "-q", "--no-edit", b)
    la, lb = s.land("zach-opus-p5a"), s.land("zach-opus-p5b")
    out("land A", la)
    out("land B", lb)
    out("entity branches after", s.branches(s.entity))
    out("other branches after", s.branches(s.other))
    return la == "landed" and lb == "landed" and s.branches(s.other) == ["main"]


def case_dev_branch(s):
    """6. Work merged into the dev branch but not main counts as landed."""
    recorded = s.dev(s.entity, "dev/work", "the workspace-spec round")
    out("integration branch recorded", recorded and "dev/work" or "(the library has no record)")
    aid, npath = s.spawn("zach-opus-p6")
    s.call(aid)
    s.commit(npath, "own.txt")
    s.finish(aid)
    s.ff(s.entity, "dev/work", "worktree-agent-" + aid)          # merged onto the dev branch only
    log = run("git", "-C", s.entity, "log", "--format=%s", "main")
    out("in main", "work own.txt" in log)
    verdict = s.land("zach-opus-p6")
    out("land", verdict)
    out("workspace gone", not os.path.exists(npath))
    out("branch gone", "worktree-agent-" + aid not in s.branches(s.entity))
    return verdict == "landed" and not os.path.exists(npath)


def case_merged_nowhere(s):
    """7. Work merged nowhere does not count as landed."""
    s.dev(s.entity, "dev/work", "the workspace-spec round")
    aid, npath = s.spawn("zach-opus-p7")
    s.call(aid)
    s.commit(npath, "own.txt")
    s.finish(aid)
    verdict = s.land("zach-opus-p7")
    out("land", verdict)
    pend = sorted(i["name"] for i in s.ws.pending(s.sid, s.entity, scan=True))
    out("pending", pend)
    out("workspace still there", os.path.exists(npath))
    return verdict.startswith("REFUSED") and pend == ["zach-opus-p7"] and os.path.exists(npath)


RUNNERS = dict(zip(CASES, [case_stray, case_side_branch, case_borrowed, case_rich,
                           case_two_agents, case_dev_branch, case_merged_nowhere]))


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    lib = os.path.abspath(argv[0])
    wanted = argv[1:] or CASES
    bad = [c for c in wanted if c not in RUNNERS]
    if bad:
        sys.stderr.write("unknown case(s): %s\nknown: %s\n" % (", ".join(bad), ", ".join(CASES)))
        return 2
    print("workspaces.py under test: %s" % lib)
    failures = []
    for name in wanted:
        print("\n=== %d %s — %s" % (CASES.index(name) + 1, name, RUNNERS[name].__doc__.splitlines()[0]))
        s = Sandbox(lib)
        try:
            ok = bool(RUNNERS[name](s))
        except Exception as e:                                   # a case that cannot even run
            ok = False
            out("EXCEPTION", "%s: %s" % (type(e).__name__, str(e)[:200]))
        finally:
            s.close()
        print("    VERDICT                            %s" % ("HOLDS" if ok else "BROKEN"))
        if not ok:
            failures.append(name)
    print("\n=== %d/%d cases hold%s" % (len(wanted) - len(failures), len(wanted),
                                        ("; BROKEN: " + ", ".join(failures)) if failures else ""))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
