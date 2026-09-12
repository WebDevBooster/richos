#!/usr/bin/env python3
"""Sage's probe for the runner round — the live half of the c3 probe it replaces.

    python3 -B certification-sage-runner-round-2026-09-12.probe.py \
        [<path-to-engine/scripts/lib/workspaces.py>] [R1 R2 ...]

WHY THIS FILE EXISTS, AND IT IS NOT A SECOND COPY OF ANYTHING
-----------------------------------------------------------------------------
`certification-sage-recorded-attribution-2026-09-12.probe.py` is retired in
`docs/verification/workspace-probe-retirements.tsv` by me, its author, on
2026-09-12. Four of its ten cases had premises the build deleted with my own
approval — the first-registration floor, and a fixture that lands with no
integration branch recorded, which point 14 now requires before the first agent
is spawned. Five of its cases were GREEN, and one asks a question that is still
open. RETIRING A FILE RETIRES EVERY CASE IN IT, including the green ones, and a
retirement that quietly drops five live assertions would recreate exactly the
regression class the runner was built to end: an assertion nothing re-asks.

So the live half is carried forward here, re-stated against the build as it now
is, and two properties this round INTRODUCED are asked for the first time.

    R1  reflog-privacy       (was S1, unchanged) a workspace's HEAD reflog is
                             its own; the branch reflog is not
    R2  borrowed-tip         (was S4, unchanged) a ref cut at a tip the agent
                             only BORROWED is not the agent's
    R3  reflog-ab            (was S7, unchanged) the branch reflog message does
                             not say where the ref was cut
    R4  record-heals         (replaces S2, S6, S8, S9) nothing is recorded and
                             nothing is inferred before the first spawn; the
                             land refuses and NAMES the recording command;
                             recording it afterwards makes the same land succeed
    R5  parallel-calls       (replaces S3) two of the agent's own calls open at
                             once, a stray created in the second: attributed and
                             deleted with the agent
    R6  parallel-side-work   (replaces S10, with the predicate from my own c4
                             case A) the same window with REAL WORK on the side
                             branch: the harm is a land that reports LANDED with
                             nothing pending, not a branch that survives
    R7  correction-in-flight (NEW — point 14, this round's item 3) correcting
                             the current body of work's branch reaches an agent
                             already registered
    R8  second-body          (NEW — point 14, this round's item 3) STARTING a
                             second body of work never moves the first one's
                             agents
    R9  eviction             (NEW — the reversal this round measured) a burst of
                             refused calls evicting a live call's window does not
                             cost that call its attribution
    R10 rich-at-my-tip       (was S5, narrowed) a ref RICH cuts at the agent's
                             own unlanded tip is out of this round's scope. What
                             is IN scope is asserted: the discard ends the
                             pending state and RECORDS every tip it deleted.
                             The out-of-scope half is printed, never asserted.

Fully sandboxed: HOME, CLAUDE_CONFIG_DIR, TMPDIR, GIT_CONFIG_GLOBAL and
RICHOS_WORKSPACES_DIR all live in a temporary directory removed at the end. The
operator's registry at ~/.claude/state/workspaces is never read or written.

Each case prints its observations and then EXPECTATION HELD. Exit 0 when every
selected case held, 1 otherwise.
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
    """Two repositories, a live session, and — unless a case is ABOUT the
    absence of the record — the body of work recorded before the first spawn,
    which is the order point 14 asks for."""

    def __init__(self, lib, record=True):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="sage-runner-probe-"))
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
        self.sid = "sess-sage-runner-1"
        self.session(self.sid, self.entity)
        if record:
            self.ws.record_integration(self.entity, "main", "the runner round", self.sid)
            self.ws.record_integration(self.other, "main", "the runner round", self.sid)

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

    def spawn(self, name):
        self.ws.register_spawn({"session_id": self.sid, "tool_use_id": "tu-" + name,
                                "tool_name": "Agent",
                                "tool_input": {"name": name, "subagent_type": "zach",
                                               "prompt": "do it\n", "isolation": "worktree"}},
                               self.entity)
        aid = "a" + name.replace("-", "")[:12] + "0000"
        npath = os.path.join(self.entity, ".claude", "worktrees", "agent-" + aid)
        run("git", "-C", self.entity, "worktree", "add", "-q", npath, "-b", "worktree-agent-" + aid)
        self.ws.record_start(self.sid, aid, npath, "zach")
        self.ws.bind_agent(self.sid, "tu-" + name, aid, self.entity)
        return aid, npath

    def pre(self, aid, call=""):
        return self.ws.barrier({"session_id": self.sid, "agent_id": aid, "tool_use_id": call})

    def post(self, aid, call=""):
        return self.ws.observe({"session_id": self.sid, "agent_id": aid, "tool_use_id": call,
                                "hook_event_name": "PostToolUse", "tool_name": "Bash"})

    def call(self, aid, c="tu-warm"):
        self.pre(aid, c)
        return self.post(aid, c)

    def commit(self, path, fname):
        with open(os.path.join(path, fname), "w") as f:
            f.write("work " + fname + "\n")
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

    def pending(self, scan=False):
        return sorted(i["name"] for i in self.ws.pending(self.sid, self.entity, scan=scan))

    def land(self, name):
        try:
            self.ws.land(name, self.sid)
            return "landed"
        except Exception as e:
            return "REFUSED: %s" % str(e)


# ---------------------------------------------------------------------------
def r1_reflog_privacy(s):
    """A workspace's own HEAD reflog is private to it; the branch reflog is not."""
    aid, npath = s.spawn("zach-opus-r1")
    s.commit(npath, "own.txt")
    run("git", "-C", npath, "branch", "spare")
    admin = os.path.join(s.entity, ".git", "worktrees", "agent-" + aid)
    head_log = os.path.join(admin, "logs", "HEAD")
    shared_head_log = os.path.join(s.entity, ".git", "logs", "HEAD")
    out("per-workspace logs/HEAD exists", os.path.exists(head_log))
    same = os.path.exists(shared_head_log) and os.path.samefile(head_log, shared_head_log)
    out("is it the main checkout's own file?", same)
    wt_commit = run("git", "-C", npath, "rev-parse", "HEAD")
    out("its commit is in its own HEAD reflog", wt_commit in open(head_log).read())
    out("and in the MAIN CHECKOUT's HEAD reflog",
        os.path.exists(shared_head_log) and wt_commit in open(shared_head_log).read())
    return not same


def r2_borrowed_tip(s):
    """A ref cut at a commit the agent only BORROWED is never the agent's."""
    keep = os.path.join(s.root, "human-wt")
    run("git", "-C", s.entity, "worktree", "add", "-q", keep, "-b", "human/keep")
    s.commit(keep, "human.txt")
    tip = run("git", "-C", s.entity, "rev-parse", "human/keep")
    run("git", "-C", s.entity, "worktree", "remove", "--force", keep)
    aid, npath = s.spawn("zach-opus-r2")
    s.pre(aid, "tu-1")
    run("git", "-C", npath, "checkout", "-q", "human/keep")
    run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
    s.post(aid, "tu-1")
    out("created_branches after borrowing", s.created("zach-opus-r2"))
    s.pre(aid, "tu-2")
    run("git", "-C", s.entity, "branch", "rich/backup", tip)
    s.post(aid, "tu-2")
    out("created_branches after Rich's cut", s.created("zach-opus-r2"))
    return "rich/backup" not in s.created("zach-opus-r2")


def r3_reflog_ab(s):
    """The branch reflog message is the same wherever the ref is cut."""
    aid, npath = s.spawn("zach-opus-r3")
    s.commit(npath, "own.txt")
    wtb = "worktree-agent-" + aid
    run("git", "-C", npath, "branch", "from-inside", wtb)
    run("git", "-C", s.entity, "branch", "from-main-checkout", wtb)
    base = os.path.join(s.entity, ".git", "logs", "refs", "heads")
    a = open(os.path.join(base, "from-inside")).read().strip().split("\t", 1)[1]
    b = open(os.path.join(base, "from-main-checkout")).read().strip().split("\t", 1)[1]
    out("cut INSIDE the workspace", a)
    out("cut in the MAIN CHECKOUT", b)
    out("either names where it was cut", ("worktrees" in a) or ("worktrees" in b))
    return a == b


def r4_record_heals(s):
    """Nothing recorded: nothing is inferred, the refusal NAMES the command, and
    recording the dev branch afterwards makes the SAME land succeed."""
    run("git", "-C", s.entity, "branch", "dev/work")
    out("main checkout is on", run("git", "-C", s.entity, "rev-parse", "--abbrev-ref", "HEAD"))
    out("record before any registration", s.ws.integration_record(s.entity))
    aid, npath = s.spawn("zach-opus-r4")
    out("record after the registration", s.ws.integration_record(s.entity))
    out("frozen onto the agent record", s.rec("zach-opus-r4").get("integration"))
    s.call(aid)
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "branch", "-f", "dev/work",
        run("git", "-C", npath, "rev-parse", "HEAD"))
    first = s.land("zach-opus-r4")
    out("land with nothing recorded", first[:100])
    named = "workspaces.sh integration" in first
    out("the refusal names the recording command", named)
    s.ws.record_integration(s.entity, "dev/work", "the runner round", s.sid)
    second = s.land("zach-opus-r4")
    out("land after Rich records dev/work", second)
    out("workspace gone", not os.path.exists(npath))
    out("its branch gone", ("worktree-agent-" + aid) not in s.branches(s.entity))
    return (first.startswith("REFUSED") and named and second == "landed"
            and not os.path.exists(npath)
            and ("worktree-agent-" + aid) not in s.branches(s.entity)
            and not s.rec("zach-opus-r4").get("integration"))


def r5_parallel_calls(s):
    """Two of the agent's own calls open at once; a stray created in the second."""
    aid, npath = s.spawn("zach-opus-r5")
    s.call(aid)
    s.commit(npath, "own.txt")
    s.pre(aid, "tu-A")
    s.pre(aid, "tu-B")
    s.post(aid, "tu-A")
    run("git", "-C", npath, "branch", "spare")
    s.post(aid, "tu-B")
    out("created_branches", s.created("zach-opus-r5"))
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land", s.land("zach-opus-r5")[:100])
    after = s.branches(s.entity)
    out("branches after the land", after)
    out("the point-3 sweep still names work", s.pending(scan=True))
    return "spare" not in after


def r6_parallel_side_work(s):
    """The same window with REAL WORK on the side branch. The harm is a land that
    reports LANDED with nothing pending — my own c4 case A's predicate, not the
    c3 probe's demand that the branch be gone. A branch carrying a commit that
    reached no integration branch must NOT be deleted (point 8)."""
    aid, npath = s.spawn("zach-opus-r6")
    s.call(aid)
    s.pre(aid, "tu-A")
    s.pre(aid, "tu-B")
    s.post(aid, "tu-A")
    run("git", "-C", npath, "checkout", "-q", "-b", "tmpwork")
    s.commit(npath, "side.txt")
    run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
    s.post(aid, "tu-B")
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    verdict = s.land("zach-opus-r6")
    pend = s.pending()
    out("created_branches", s.created("zach-opus-r6"))
    out("land", verdict[:100])
    out("the side commit reached main",
        "work side.txt" in run("git", "-C", s.entity, "log", "--format=%s", "main"))
    out("pending after the land", pend)
    harm = verdict == "landed" and pend == []
    out("HARM (landed + nothing pending)", harm)
    if verdict.startswith("REFUSED"):
        run("git", "-C", s.entity, "merge", "-q", "--no-edit", "tmpwork")
        out("land once tmpwork is merged", s.land("zach-opus-r6"))
        out("branches after that land", s.branches(s.entity))
    return not harm


def r7_correction_in_flight(s):
    """Point 14: a CORRECTION to the current body of work's branch reaches an
    agent already registered. Without it a mis-recorded branch could never be
    put right and the land would refuse forever — 'it cannot go to main yet' is
    never a reason for anything to be left behind."""
    aid, npath = s.spawn("zach-opus-r7")             # bound to the body recorded as main
    out("bound to", (s.rec("zach-opus-r7").get("integration_work") or {}))
    s.call(aid)
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "branch", "dev/work", run("git", "-C", npath, "rev-parse", "HEAD"))
    before = s.land("zach-opus-r7")
    out("land while the record still says main", before[:100])
    s.ws.record_integration(s.entity, "dev/work", "this work cannot reach main yet",
                            s.sid, correct=True)
    out("the record now", (s.ws.integration_record(s.entity) or {}).get("branch"))
    out("bodies of work", sorted((s.ws.all_bodies_of_work() or {}).keys()))
    after = s.land("zach-opus-r7")
    out("land after the correction", after)
    out("workspace gone", not os.path.exists(npath))
    return (before.startswith("REFUSED") and after == "landed"
            and len(s.ws.all_bodies_of_work() or {}) == 2)      # one per repository


def r8_second_body(s):
    """Point 14: STARTING a second body of work in the same repository never
    moves the first one's agents onto it. Point 5 permits the second to start
    while the first one's agents are still running."""
    aid, npath = s.spawn("zach-opus-r8")             # body one: main
    bound = dict(s.rec("zach-opus-r8").get("integration_work") or {})
    out("bound to", sorted(bound.values()))
    s.call(aid)
    s.commit(npath, "own.txt")
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    run("git", "-C", s.entity, "branch", "dev/two")
    s.ws.record_integration(s.entity, "dev/two", "a SECOND body of work", s.sid)
    out("the repository's current body", (s.ws.integration_record(s.entity) or {}).get("branch"))
    out("still bound to", sorted(dict(s.rec("zach-opus-r8").get("integration_work") or {}).values()))
    s.finish(aid)
    verdict = s.land("zach-opus-r8")
    out("land (its work is in main, not dev/two)", verdict[:100])
    out("workspace gone", not os.path.exists(npath))
    return (verdict == "landed"
            and dict(s.rec("zach-opus-r8").get("integration_work") or {}) == bound)


def r9_eviction(s):
    """A burst of REFUSED PreToolUse calls evicts the live call's window by the
    count cap. The ref created in that live call must still be attributed —
    this round measured the age-based cap as buying nothing over the unpaired-
    Post fallback, and reverted it. This is the case that reversal rests on.

    IT ASSERTS ATTRIBUTION AT THE END OF THE CALL, NOT AT THE END OF THE RUN,
    and the difference is measured rather than assumed: with the fallback
    removed the ref is attributed to nobody at the Post and the end-of-run pass
    still recovers it, so the OUTCOME at the land is the same either way. What
    the fallback buys is that `created_branches` is right WHILE the agent is
    running, which is what the point-3 sweep and any in-flight decision read.
    The post-finish value is printed beside it so the two are never confused."""
    aid, npath = s.spawn("zach-opus-r9")
    s.call(aid)
    s.commit(npath, "own.txt")
    s.pre(aid, "tu-live")                             # the live call opens
    for i in range(80):                               # refused: Pre, never a Post
        s.pre(aid, "tu-refused-%03d" % i)
    slots = len([n for n in os.listdir(os.path.join(s.ws.state_dir(), "refs",
                                                    s.ws._key_segment(s.rec("zach-opus-r9")["key"])))
                 if n.endswith(".json") and n != "latest.json"])
    out("open windows after 81 Pres (cap 64)", slots)
    out("the live call's window survived",
        os.path.exists(os.path.join(s.ws.state_dir(), "refs",
                                    s.ws._key_segment(s.rec("zach-opus-r9")["key"]),
                                    "c.tu-live.json")))
    run("git", "-C", npath, "branch", "spare")        # created inside the live call
    s.post(aid, "tu-live")
    made = s.created("zach-opus-r9")                  # read BEFORE the land files the record
    out("created_branches at the Post", made)
    s.finish(aid)
    out("created_branches after the run ended", s.created("zach-opus-r9"))
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land", s.land("zach-opus-r9")[:100])
    after = s.branches(s.entity)
    out("branches after the land", after)
    return "spare" in made and "spare" not in after


def r10_rich_at_my_tip(s):
    """A ref RICH cuts at the agent's own unlanded tip, which he then commits on
    after the run ended. It is attributed to the agent and this round declares
    it OUT OF SCOPE, so the probe does not assert it away.

    What IS asserted is point 7's half: the discard ends the pending state and
    RECORDS every tip it deleted, so nothing is left neither landed nor
    discarded and the deleted tip is on the record."""
    aid, npath = s.spawn("zach-opus-r10")
    s.call(aid)
    s.commit(npath, "own.txt")
    tip = run("git", "-C", npath, "rev-parse", "HEAD")
    s.pre(aid, "tu-1")
    run("git", "-C", s.entity, "branch", "rich/rescue", tip)
    s.post(aid, "tu-1")
    out("created_branches", s.created("zach-opus-r10"))
    s.finish(aid)
    look = os.path.join(s.root, "rich-look")
    run("git", "-C", s.entity, "worktree", "add", "-q", look, "rich/rescue")
    s.commit(look, "rich-own.txt")
    richs = run("git", "-C", s.entity, "rev-parse", "rich/rescue")
    run("git", "-C", s.entity, "worktree", "remove", "--force", look)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land", s.land("zach-opus-r10")[:100])
    d = s.ws.discard("zach-opus-r10", "a probe, ending the pending state",
                     not_ceo_ordered="a probe, nobody ordered it", me=s.sid)
    tips = sorted(d.get("tips") or {})
    out("the discard RECORDED these tips", tips)
    out("Rich's own commit is on that record", any(richs in str(v) or richs == v
                                                   for v in (d.get("tips") or {}).values()))
    out("[OUT OF SCOPE] rich/rescue survived", "rich/rescue" in s.branches(s.entity))
    out("pending after the discard", s.pending())
    return bool(tips) and s.pending() == []


RUNNERS = [("R1 reflog-privacy", r1_reflog_privacy, True),
           ("R2 borrowed-tip", r2_borrowed_tip, True),
           ("R3 reflog-ab", r3_reflog_ab, True),
           ("R4 record-heals", r4_record_heals, False),
           ("R5 parallel-calls", r5_parallel_calls, True),
           ("R6 parallel-side-work", r6_parallel_side_work, True),
           ("R7 correction-in-flight", r7_correction_in_flight, True),
           ("R8 second-body", r8_second_body, True),
           ("R9 eviction", r9_eviction, True),
           ("R10 rich-at-my-tip", r10_rich_at_my_tip, True)]


def main(argv):
    lib = LIB
    if argv and argv[0].endswith(".py"):
        lib = os.path.abspath(argv[0])
        argv = argv[1:]
    print("workspaces.py under test: %s" % lib)
    wanted = argv or [n.split()[0] for n, _f, _r in RUNNERS]
    bad = []
    for name, fn, record in RUNNERS:
        if name.split()[0] not in wanted:
            continue
        print("\n=== %s — %s" % (name, fn.__doc__.splitlines()[0]))
        s = Sandbox(lib, record=record)
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
