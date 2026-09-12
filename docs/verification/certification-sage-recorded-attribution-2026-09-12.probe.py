#!/usr/bin/env python3
"""Sage's independent probe of cc/zach-opus-g1 @ 84e12d32 — the certification's
evidence, runnable against any scripts/lib/workspaces.py.

    python3 -B certification-sage-recorded-attribution-2026-09-12.probe.py \
        [<path-to-workspaces.py>] [S1 S2 ...]

It reuses the harness shape of the round's own seven-case probe and drives the
library through the same entry points the hooks use, but asks questions that
probe does not ask. Fully sandboxed: HOME, CLAUDE_CONFIG_DIR, TMPDIR,
GIT_CONFIG_GLOBAL and RICHOS_WORKSPACES_DIR all live in a temporary directory
removed at the end; the operator's real registry is never read or written.

    S1  reflog-privacy   is $GIT_DIR/logs/HEAD per-worktree? (declared item 1)
    S2  floor-vs-dev     main checkout on main, work integrates on a dev branch,
                         Rich records it AFTER the first registration
    S3  parallel-calls   two tool calls open at once (Pre,Pre,Post,Post)
    S4  borrowed-tip     a ref cut at a tip the agent only BORROWED
    S5  rich-then-commits Rich cuts at the agent's tip in the window, then
                         commits on it after the agent's run ended
    S6  no-floor-recovers  S2 with the main checkout detached
    S7  reflog-ab        is the BRANCH reflog message location-free?
    S8  floor-at-session-start  when is the floor actually written?
    S9  no-record-recovers  no record at all: does recording it after recover?

Each case prints its observations and then EXPECTATION HELD, where the
expectation is the one stated in the certification. Exit 0 when every selected
case held, 1 otherwise. S2, S3, S4, S5, S6 and S8 are expected NOT to hold at
84e12d32 — that is the finding, not a broken probe.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import time

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                   "engine", "scripts", "lib", "workspaces.py")


def run(*args, **kw):
    r = subprocess.run(list(args), capture_output=True, text=True, env=os.environ.copy())
    if kw.get("check", True) and r.returncode != 0:
        raise AssertionError("%s failed: %s %s" % (args, r.stdout, r.stderr))
    return r.stdout.strip()


def out(label, value):
    print("    %-34s %s" % (label, value))


class Sandbox(object):
    def __init__(self, lib=LIB):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="sage-probe-"))
        os.environ["HOME"] = os.path.join(self.root, "home")
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(self.root, "home", ".claude")
        os.environ["TMPDIR"] = os.path.join(self.root, "tmp")
        os.environ["RICHOS_WORKSPACES_DIR"] = os.path.join(self.root, "registry")
        os.environ.pop("RICHOS_SESSION_ID", None)
        os.environ["RICHOS_WORKSPACES_SPAWN_WINDOW"] = "0"
        os.environ["RICHOS_WORKSPACES_RETRY_BASE"] = "0"
        os.makedirs(os.environ["CLAUDE_CONFIG_DIR"])
        os.makedirs(os.environ["TMPDIR"])
        os.makedirs(os.environ["RICHOS_WORKSPACES_DIR"])
        gc = os.path.join(self.root, "home", ".gitconfig")
        with open(gc, "w") as f:
            f.write("[user]\n\tname = probe\n\temail = probe@example.invalid\n"
                    "[init]\n\tdefaultBranch = main\n")
        os.environ["GIT_CONFIG_GLOBAL"] = gc
        spec = importlib.util.spec_from_file_location("ws_under_test", lib)
        self.ws = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.ws)
        self.procs = []
        self.entity = self.repo("entity")
        self.other = self.repo("other")
        self.sid = "sess-sage-22222222"
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
        return self.ws.observe({"session_id": self.sid, "agent_id": aid,
                                "hook_event_name": "PostToolUse", "tool_name": "Bash"})

    def call(self, aid):
        self.pre(aid)
        return self.post(aid)

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
        except Exception as e:
            return "REFUSED: %s" % str(e)[:220]


# ---------------------------------------------------------------------------
def s1_reflog_privacy(s):
    """Is the per-workspace HEAD reflog private, and is the branch reflog not?"""
    aid, npath = s.spawn("zach-opus-s1")
    s.commit(npath, "own.txt")
    run("git", "-C", npath, "branch", "spare")
    admin = os.path.join(s.entity, ".git", "worktrees", "agent-" + aid)
    head_log = os.path.join(admin, "logs", "HEAD")
    shared_head_log = os.path.join(s.entity, ".git", "logs", "HEAD")
    branch_log = os.path.join(s.entity, ".git", "logs", "refs", "heads", "spare")
    out("per-workspace logs/HEAD", os.path.relpath(head_log, s.entity) + " exists=" + str(os.path.exists(head_log)))
    out("main checkout's own logs/HEAD", "exists=" + str(os.path.exists(shared_head_log)))
    same = os.path.exists(shared_head_log) and os.path.samefile(head_log, shared_head_log)
    out("are they the same file?", same)
    wt_commit = run("git", "-C", npath, "rev-parse", "HEAD")
    out("commit made in the workspace", wt_commit[:12])
    out("in the workspace's own HEAD reflog",
        wt_commit in open(head_log).read())
    out("in the MAIN CHECKOUT's HEAD reflog",
        os.path.exists(shared_head_log) and wt_commit in open(shared_head_log).read())
    out("branch reflog of the stray", open(branch_log).read().strip()[-70:] if os.path.exists(branch_log) else "(none)")
    # the same branch, created in the MAIN CHECKOUT, for comparison
    run("git", "-C", s.entity, "branch", "spare2", wt_commit)
    b2 = os.path.join(s.entity, ".git", "logs", "refs", "heads", "spare2")
    out("branch reflog of a Rich-cut ref", open(b2).read().strip()[-70:] if os.path.exists(b2) else "(none)")
    return not same


def s2_floor_vs_dev(s):
    """The floor writes `main`; the work integrates on a dev branch recorded after."""
    out("main checkout branch at first registration",
        run("git", "-C", s.entity, "rev-parse", "--abbrev-ref", "HEAD"))
    run("git", "-C", s.entity, "branch", "dev/work")
    aid, npath = s.spawn("zach-opus-s2")          # <-- first registration in this repo
    rec = s.ws.integration_record(s.entity)
    out("integration.json after registration", {k: rec[k] for k in ("branch", "source")})
    out("frozen on the agent record", s.rec("zach-opus-s2").get("integration"))
    s.ws.record_integration(s.entity, "dev/work", "the workspace-spec round", s.sid)
    out("Rich records it afterwards",
        {k: s.ws.integration_record(s.entity)[k] for k in ("branch", "source")})
    out("still frozen on the agent record", s.rec("zach-opus-s2").get("integration"))
    s.call(aid)
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "branch", "-f", "dev/work",
        run("git", "-C", npath, "rev-parse", "HEAD"))       # merged onto the dev branch
    verdict = s.land("zach-opus-s2")
    out("land after merging onto dev/work", verdict)
    pend = sorted(i["name"] for i in s.ws.pending(s.sid, s.entity, scan=False))
    out("pending (point 5 gate)", pend)
    out("workspace still on disk", os.path.exists(npath))
    return verdict == "landed"


def s3_parallel_calls(s):
    """Two tool calls open at once: Pre(A) Pre(B) Post(A) Post(B)."""
    aid, npath = s.spawn("zach-opus-s3")
    s.call(aid)
    s.commit(npath, "own.txt")
    s.pre(aid)                       # call A starts
    s.pre(aid)                       # call B starts (overwrites the snapshot)
    s.post(aid)                      # call A ends: consumes the snapshot
    run("git", "-C", npath, "branch", "spare")   # call B creates a branch
    s.post(aid)                      # call B ends: no snapshot left
    out("created_branches", s.created("zach-opus-s3"))
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land", s.land("zach-opus-s3"))
    after = s.branches(s.entity)
    out("branches after the land", after)
    out("scan calls the stray unregistered work",
        sorted(i["name"] for i in s.ws.pending(s.sid, s.entity, scan=True)))
    return "spare" not in after


def s4_borrowed_tip(s):
    """A ref cut at a commit the agent only BORROWED (never made)."""
    keep = os.path.join(s.root, "human-wt")
    run("git", "-C", s.entity, "worktree", "add", "-q", keep, "-b", "human/keep")
    s.commit(keep, "human.txt")
    tip = run("git", "-C", s.entity, "rev-parse", "human/keep")
    run("git", "-C", s.entity, "worktree", "remove", "--force", keep)
    aid, npath = s.spawn("zach-opus-s4")
    s.pre(aid)
    run("git", "-C", npath, "checkout", "-q", "human/keep")   # borrowed
    run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
    s.post(aid)
    out("created_branches after borrowing", s.created("zach-opus-s4"))
    s.pre(aid)
    run("git", "-C", s.entity, "branch", "rich/backup", tip)  # Rich cuts at the BORROWED tip
    s.post(aid)
    out("created_branches after Rich's cut", s.created("zach-opus-s4"))
    out("the agent made no commit of its own", run("git", "-C", npath, "rev-parse", "HEAD") ==
        run("git", "-C", s.entity, "rev-parse", "main"))
    return "rich/backup" not in s.created("zach-opus-s4")


def s5_rich_then_commits(s):
    """Rich cuts at the agent's tip inside the window, then commits on it later."""
    aid, npath = s.spawn("zach-opus-s5")
    s.call(aid)
    s.commit(npath, "own.txt")
    tip = run("git", "-C", npath, "rev-parse", "HEAD")
    s.pre(aid)
    run("git", "-C", s.entity, "branch", "rich/rescue", tip)  # the indistinguishable case
    s.post(aid)
    out("created_branches", s.created("zach-opus-s5"))
    s.finish(aid)
    look = os.path.join(s.root, "rich-look")
    run("git", "-C", s.entity, "worktree", "add", "-q", look, "rich/rescue")
    s.commit(look, "rich-own.txt")                           # Rich's own work, after the run
    run("git", "-C", s.entity, "worktree", "remove", "--force", look)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    verdict = s.land("zach-opus-s5")
    out("land after the agent's work is merged", verdict)
    out("branches now", s.branches(s.entity))
    d = s.ws.discard("zach-opus-s5", "the only other way to end pending work",
                     not_ceo_ordered="a probe, not the CEO's order", me=s.sid)
    out("discard recorded tips", sorted(d["tips"]))
    out("branches after the discard", s.branches(s.entity))
    out("Rich's commit still reachable from any ref",
        run("git", "-C", s.entity, "branch", "--contains", "HEAD", check=False) or "(gone)")
    return verdict == "landed"


def s6_no_floor_recovers(s):
    """The same sequence as S2 with no floor written: does it recover?

    It does not, and the reason is the finding S8 states: the floor was already
    written at SESSION START, so detaching the main checkout before the first
    registration cannot suppress it. S9 is the genuine no-record case."""
    run("git", "-C", s.entity, "branch", "dev/work")
    run("git", "-C", s.entity, "checkout", "-q", "--detach")     # no branch to read
    out("main checkout branch at first registration",
        run("git", "-C", s.entity, "rev-parse", "--abbrev-ref", "HEAD"))
    aid, npath = s.spawn("zach-opus-s6")
    out("integration.json after registration", s.ws.integration_record(s.entity))
    out("frozen on the agent record", s.rec("zach-opus-s6").get("integration"))
    s.ws.record_integration(s.entity, "dev/work", "the workspace-spec round", s.sid)
    out("Rich records it afterwards",
        {k: s.ws.integration_record(s.entity)[k] for k in ("branch", "source")})
    s.call(aid)
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "branch", "-f", "dev/work",
        run("git", "-C", npath, "rev-parse", "HEAD"))
    verdict = s.land("zach-opus-s6")
    out("land after merging onto dev/work", verdict)
    out("workspace gone", not os.path.exists(npath))
    return verdict == "landed"


def s7_reflog_ab(s):
    """Is the branch reflog message the same wherever the ref is cut?"""
    aid, npath = s.spawn("zach-opus-s7")
    s.commit(npath, "own.txt")
    wtb = "worktree-agent-" + aid
    run("git", "-C", npath, "branch", "from-inside", wtb)
    run("git", "-C", s.entity, "branch", "from-main-checkout", wtb)
    base = os.path.join(s.entity, ".git", "logs", "refs", "heads")
    a = open(os.path.join(base, "from-inside")).read().strip()
    b = open(os.path.join(base, "from-main-checkout")).read().strip()
    out("cut INSIDE the workspace", a.split("\t", 1)[1])
    out("cut in the MAIN CHECKOUT", b.split("\t", 1)[1])
    out("messages identical", a.split("\t", 1)[1] == b.split("\t", 1)[1])
    out("either names where it was cut",
        ("worktrees" in a) or ("worktrees" in b) or npath in a or npath in b)
    return a.split("\t", 1)[1] == b.split("\t", 1)[1]


def s8_floor_at_session_start(s):
    """WHEN is the floor written — at first registration, or at session start?"""
    rec = s.ws.integration_record(s.entity)
    out("integration record before any registration", rec and {k: rec[k] for k in ("branch", "source")})
    out("workspaces registered so far", [r.get("name") for r in s.ws.all_agents(include_done=True)])
    ev = os.path.join(s.ws.state_dir(), "events.jsonl")
    for line in open(ev).read().splitlines():
        if "integration-recorded" in line or "session-start" in line:
            out("event", line[:150])
    return rec is None


def s9_no_record_recovers(s):
    """No record at registration: Rich records the dev branch after, and lands."""
    run("git", "-C", s.entity, "branch", "dev/work")
    run("git", "-C", s.entity, "checkout", "-q", "--detach")
    os.unlink(os.path.join(s.ws.state_dir(), "integration.json"))   # no record at all
    aid, npath = s.spawn("zach-opus-s9")
    out("integration.json after registration", s.ws.integration_record(s.entity))
    out("frozen on the agent record", s.rec("zach-opus-s9").get("integration"))
    s.ws.record_integration(s.entity, "dev/work", "the workspace-spec round", s.sid)
    out("Rich records it afterwards",
        {k: s.ws.integration_record(s.entity)[k] for k in ("branch", "source")})
    s.call(aid)
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "branch", "-f", "dev/work",
        run("git", "-C", npath, "rev-parse", "HEAD"))
    verdict = s.land("zach-opus-s9")
    out("land after merging onto dev/work", verdict)
    out("workspace gone", not os.path.exists(npath))
    return verdict == "landed"


def s10_parallel_side_branch(s):
    """The same window as S3, with real work on the side branch (case 2's shape)."""
    aid, npath = s.spawn("zach-opus-s10")
    s.call(aid)
    s.pre(aid)                       # call A starts
    s.pre(aid)                       # call B starts
    s.post(aid)                      # call A ends: the one snapshot is consumed
    run("git", "-C", npath, "checkout", "-q", "-b", "tmpwork")
    s.commit(npath, "side.txt")      # work, on a branch nobody will attribute
    run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
    s.post(aid)                      # call B ends: no snapshot left
    side = run("git", "-C", s.entity, "rev-parse", "tmpwork")
    out("created_branches", s.created("zach-opus-s10"))
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land", s.land("zach-opus-s10"))
    out("its side-branch commit in main",
        "work side.txt" in run("git", "-C", s.entity, "log", "--format=%s", "main"))
    out("branches after the land", s.branches(s.entity))
    out("pending after the land", sorted(i["name"] for i in s.ws.pending(s.sid, s.entity, scan=True)))
    out("the side commit is still only on tmpwork",
        side == run("git", "-C", s.entity, "rev-parse", "tmpwork"))
    return "tmpwork" not in s.branches(s.entity)


RUNNERS = [("S1 reflog-privacy", s1_reflog_privacy),
           ("S2 floor-vs-dev", s2_floor_vs_dev),
           ("S3 parallel-calls", s3_parallel_calls),
           ("S4 borrowed-tip", s4_borrowed_tip),
           ("S5 rich-then-commits", s5_rich_then_commits),
           ("S6 no-floor-recovers", s6_no_floor_recovers),
           ("S7 reflog-ab", s7_reflog_ab),
           ("S8 floor-at-session-start", s8_floor_at_session_start),
           ("S9 no-record-recovers", s9_no_record_recovers),
           ("S10 parallel-side-branch", s10_parallel_side_branch)]


def main(argv):
    lib = LIB
    if argv and argv[0].endswith(".py"):
        lib = os.path.abspath(argv[0])
        argv = argv[1:]
    print("workspaces.py under test: %s" % lib)
    wanted = argv or [n.split()[0] for n, _f in RUNNERS]
    bad = []
    for name, fn in RUNNERS:
        if name.split()[0] not in wanted:
            continue
        print("\n=== %s — %s" % (name, fn.__doc__.splitlines()[0]))
        s = Sandbox(lib)
        try:
            ok = bool(fn(s))
        except Exception as e:
            ok = False
            out("EXCEPTION", "%s: %s" % (type(e).__name__, str(e)[:300]))
        finally:
            s.close()
        print("    EXPECTATION HELD                   %s" % ok)
        if not ok:
            bad.append(name)
    print("\n=== held: %d/%d%s" % (len(wanted) - len(bad), len(wanted),
                                   ("; NOT HELD: " + ", ".join(bad)) if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
