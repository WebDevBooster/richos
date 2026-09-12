#!/usr/bin/env python3
"""Two holes, five cases, one command, against ANY scripts/lib/workspaces.py.

    python3 -B workspace-call-window-and-recorded-target.probe.py \\
        <path-to-workspaces.py> [case ...]

Run it against the parent (`git show 84e12d32:engine/scripts/lib/workspaces.py`)
and against the branch; the DIFFERENCE is the proof. It imports no engine test
file and drives the library through the same entry points the hooks use:

    PreToolUse  (matcherless)  guard-sealed-worktree.sh  -> barrier()
    PostToolUse (matcherless)  observe-created-refs.sh   -> observe()
    SubagentStart / PostToolUse[Agent] / SubagentStop    -> record_start /
                                                           bind_agent / record_end

ITEM 1 — THE CREATION WINDOW IS ONE SLOT PER AGENT.  At 84e12d32 the snapshot a
Pre takes is written to one path per AGENT and the first Post to arrive consumes
it. An agent's own calls overlap (this project's instructions require independent
calls to be issued in one block, and a backgrounded Bash call was measured
returning 4.0 s before its process finished), so Pre(A) Pre(B) Post(A) Post(B)
loses a whole window: a ref created in call B is attributed to nobody.

    1 concurrent-refs   both refs the agent creates across two overlapping calls
                        of its OWN are attributed; neither window is lost. Run
                        with the platform's call ids AND with none, because the
                        pairing must not depend on the caller supplying them.
    2 concurrent-side   with real work on a side branch created in that shape,
                        the land is REFUSED and the item is pending -- the
                        failure being ended is `land()` reporting LANDED over a
                        commit that reached no integration branch (points 5, 8).

ITEM 2 — THE INFERRED INTEGRATION FALLBACK.  At 84e12d32 a "first-registration"
floor read the main checkout's current branch, wrote it down as the recorded
fact and froze a copy onto every agent registered afterwards. Recording the real
branch afterwards could not reach an agent already in flight: its land refused
forever and its workspace was left behind (point 14, point 5).

    3 no-record-refuses with NO integration branch recorded, the land REFUSES and
                        NAMES the command that records it; nothing is inferred
                        from what the main checkout happens to be on.
    4 late-record-heals after Rich records the branch, that same land SUCCEEDS --
                        for an agent registered BEFORE the record existed. This
                        is the comparison that decides item 2: the refusal heals
                        and the floor's record never did.
    5 no-floor-written  a registration writes no integration record and freezes
                        nothing onto the agent. The floor is gone, not bypassed.

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

CASES = ["concurrent-refs", "concurrent-side", "no-record-refuses",
         "late-record-heals", "no-floor-written"]


def run(*args, **kw):
    r = subprocess.run(list(args), capture_output=True, text=True, env=os.environ.copy())
    if kw.get("check", True) and r.returncode != 0:
        raise AssertionError("%s failed: %s %s" % (args, r.stdout, r.stderr))
    return r.stdout.strip()


def out(label, value):
    print("    %-38s %s" % (label, value))


class Sandbox(object):
    def __init__(self, lib, record_main=True):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="ws-window-"))
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
        spec = importlib.util.spec_from_file_location("workspaces_under_test", lib)
        self.ws = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.ws)
        self.procs = []
        self.entity = self.repo("entity")
        self.sid = "sess-window-33333333"
        self.session(self.sid, self.entity)
        if record_main:
            # Point 14, the form the page asks for: Rich records the branch this
            # body of work integrates on, before the first agent is spawned.
            self.ws.record_integration(self.entity, "main", "the probe's body of work", self.sid)

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
        """One tool call's FIRST half, carrying the platform's id for THIS call."""
        payload = {"session_id": self.sid, "agent_id": aid}
        if call:
            payload["tool_use_id"] = call
        return self.ws.barrier(payload)

    def post(self, aid, call=""):
        """The SAME call's SECOND half: the same tool_use_id at both ends."""
        if not hasattr(self.ws, "observe"):
            return []              # a library with no second half; nothing is faked
        payload = {"session_id": self.sid, "agent_id": aid,
                   "hook_event_name": "PostToolUse", "tool_name": "Bash"}
        if call:
            payload["tool_use_id"] = call
        return self.ws.observe(payload)

    def call(self, aid, c=""):
        self.pre(aid, c)
        return self.post(aid, c)

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
        """The verdict, in full: a refusal's WHOLE message is the evidence (it
        has to name the command that records the branch), so it is never
        truncated here -- only when it is printed."""
        try:
            self.ws.land(name, self.sid)
            return "landed"
        except Exception as e:                                  # SpecError, by design
            return "REFUSED: %s" % e

    def pending(self):
        return sorted(i["name"] for i in self.ws.pending(self.sid, self.entity, scan=True))


# ---------------------------------------------------------------------------
# ITEM 1 — the window is one per CALL
# ---------------------------------------------------------------------------
def _overlapped(s, name, ids, tag):
    """Pre(A) Pre(B) <ref in A> Post(A) <ref in B> Post(B), with the call ids
    `ids` (('','') drives the same shape with no ids at all)."""
    a, b = ids
    aid, npath = s.spawn(name)
    s.call(aid, "tu-warm-" + tag if a else "")
    s.commit(npath, "own.txt")
    s.pre(aid, a)                                        # call A opens
    s.pre(aid, b)                                        # call B opens alongside it
    run("git", "-C", npath, "branch", tag + "-in-call-a")   # created while A is open
    s.post(aid, a)                                       # A closes
    run("git", "-C", npath, "branch", tag + "-in-call-b")   # created while B is open
    s.post(aid, b)                                       # B closes
    return aid, npath


def case_concurrent_refs(s):
    """1. Two of one agent's own calls open at once: BOTH refs are attributed."""
    _overlapped(s, "zach-opus-w1", ("tu-A", "tu-B"), "keyed")
    with_ids = s.created("zach-opus-w1")
    out("with the platform's call ids", with_ids)
    _overlapped(s, "zach-opus-w2", ("", ""), "unkeyed")
    no_ids = s.created("zach-opus-w2")
    out("with no call ids at all (arrival order)", no_ids)
    ok = with_ids == ["keyed-in-call-a", "keyed-in-call-b"] \
        and no_ids == ["unkeyed-in-call-a", "unkeyed-in-call-b"]
    out("both windows survived, both ways", ok)
    return ok


def case_concurrent_side(s):
    """2. Real work on a side branch created in that window: the land is REFUSED."""
    aid, npath = s.spawn("zach-opus-w3")
    s.call(aid, "tu-warm")
    s.pre(aid, "tu-A")                                   # call A opens
    s.pre(aid, "tu-B")                                   # call B opens alongside it
    s.post(aid, "tu-A")                                  # A closes first
    run("git", "-C", npath, "checkout", "-q", "-b", "tmpwork")
    s.commit(npath, "side.txt")                          # real work, inside call B
    run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
    s.post(aid, "tu-B")                                  # B closes
    out("created_branches", s.created("zach-opus-w3"))
    side = run("git", "-C", s.entity, "rev-parse", "tmpwork")
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    verdict = s.land("zach-opus-w3")
    out("land", verdict[:150])
    out("its side-branch commit in main",
        "work side.txt" in run("git", "-C", s.entity, "log", "--format=%s", "main"))
    out("pending (point 5 holds the turn)", s.pending())
    out("the side commit is still on tmpwork", side == run("git", "-C", s.entity, "rev-parse", "tmpwork"))
    held = verdict.startswith("REFUSED") and "tmpwork" in verdict and s.pending() == ["zach-opus-w3"]
    # ...and merging it is what lands it, with nothing left behind (point 10)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "tmpwork")
    out("land once tmpwork is merged", s.land("zach-opus-w3"))
    after = s.branches(s.entity)
    out("branches after the land", after)
    return held and after == ["main"]


# ---------------------------------------------------------------------------
# ITEM 2 — the target is RECORDED, never inferred, and the refusal HEALS
# ---------------------------------------------------------------------------
def case_no_record_refuses(s):
    """3. No integration branch recorded: the land REFUSES and names the command."""
    out("main checkout is on", run("git", "-C", s.entity, "rev-parse", "--abbrev-ref", "HEAD"))
    out("integration record", s.ws.integration_record(s.entity))
    aid, npath = s.spawn("zach-opus-w4")
    s.call(aid, "tu-1")
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)  # in main!
    verdict = s.land("zach-opus-w4")
    out("land (its work IS in main)", verdict[:150])
    out("names the recording command", "workspaces.sh integration" in verdict)
    out("pending (nothing is lost)", s.pending())
    out("workspace still there", os.path.exists(npath))
    return (verdict.startswith("REFUSED") and "workspaces.sh integration" in verdict
            and s.pending() == ["zach-opus-w4"] and os.path.exists(npath))


def case_late_record_heals(s):
    """4. Recorded AFTER the agent was registered: the same land then SUCCEEDS."""
    run("git", "-C", s.entity, "branch", "dev/work")
    out("integration record at spawn time", s.ws.integration_record(s.entity))
    aid, npath = s.spawn("zach-opus-w5")               # registered with NO record
    out("frozen on the agent record", s.rec("zach-opus-w5").get("integration"))
    s.call(aid, "tu-1")
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "branch", "-f", "dev/work",
        run("git", "-C", npath, "rev-parse", "HEAD"))  # merged onto the dev branch only
    first = s.land("zach-opus-w5")
    out("land before the branch is recorded", first[:150])
    s.ws.record_integration(s.entity, "dev/work", "this body of work", s.sid)
    out("Rich records it afterwards",
        {k: s.ws.integration_record(s.entity)[k] for k in ("branch", "source")})
    second = s.land("zach-opus-w5")
    out("the SAME land, after the recording", second)
    out("workspace gone", not os.path.exists(npath))
    out("branch gone", "worktree-agent-" + aid not in s.branches(s.entity))
    out("nothing pending", s.pending())
    return first.startswith("REFUSED") and second == "landed" and not os.path.exists(npath)


def case_no_floor_written(s):
    """5. A registration writes no integration record and freezes nothing."""
    out("record before anything happens", s.ws.integration_record(s.entity))
    aid, npath = s.spawn("zach-opus-w6")
    out("record after a registration", s.ws.integration_record(s.entity))
    out("frozen on the agent record", s.rec("zach-opus-w6").get("integration"))
    recs = s.ws.all_integration_records()
    out("every integration record", recs)
    out("none has source first-registration",
        not any((r or {}).get("source") == "first-registration" for r in recs.values()))
    return (s.ws.integration_record(s.entity) is None
            and not s.rec("zach-opus-w6").get("integration")
            and not any((r or {}).get("source") == "first-registration" for r in recs.values()))


RUNNERS = dict(zip(CASES, [case_concurrent_refs, case_concurrent_side,
                           case_no_record_refuses, case_late_record_heals,
                           case_no_floor_written]))
# Cases 3, 4 and 5 are about the state where NOTHING is recorded, so their
# sandbox does not record it; 1 and 2 are about the window, so theirs does.
NO_RECORD = {"no-record-refuses", "late-record-heals", "no-floor-written"}


def main(argv):
    if not argv:
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 2
    lib = os.path.abspath(argv[0])
    print("workspaces.py under test: %s" % lib)
    wanted = argv[1:] or CASES
    unknown = [c for c in wanted if c not in RUNNERS]
    if unknown:
        sys.stderr.write("unknown case(s): %s\nknown: %s\n" % (", ".join(unknown), ", ".join(CASES)))
        return 2
    bad = []
    for name in CASES:
        if name not in wanted:
            continue
        print("\n=== %d %s — %s" % (CASES.index(name) + 1, name,
                                    RUNNERS[name].__doc__.splitlines()[0]))
        s = Sandbox(lib, record_main=name not in NO_RECORD)
        try:
            ok = bool(RUNNERS[name](s))
        except Exception as e:
            ok = False
            out("EXCEPTION", "%s: %s" % (type(e).__name__, str(e)[:300]))
        finally:
            s.close()
        print("    VERDICT                                %s" % ("HOLDS" if ok else "BROKEN"))
        if not ok:
            bad.append(name)
    print("\n=== %d/%d cases hold%s" % (len(wanted) - len(bad), len(wanted),
                                        ("; BROKEN: " + ", ".join(bad)) if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
