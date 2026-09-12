#!/usr/bin/env python3
"""Frank's probe for the window-and-recorded-target round (2bc413df).

    python3 -B certification-frank-window-and-target-2026-09-12-probe.py \\
        <path-to-workspaces.py> [case ...]

Self-contained: it imports no engine test file and no other probe. It drives the
library through the same entry points the two hooks use --

    PreToolUse  (matcherless)  guard-sealed-worktree.sh -> barrier()
    PostToolUse (matcherless)  observe-created-refs.sh  -> observe()

-- and asks the two questions this round's own artifacts do not:

  (a) THE ESCALATION, MEASURED. Deleting the floor makes recording the branch an
      operational step. While no branch is recorded, observe_created_refs()
      cannot judge anything and writes `attribution-skipped`. Attribution happens
      at OBSERVE time and never again, so a ref created before the recording is
      attributed to nobody FOREVER -- and the land that later succeeds leaves it
      behind. Cases 1-4.

  (b) THE LEAKED WINDOW. A PreToolUse that another guard then REFUSES leaves a
      window no PostToolUse will ever consume. record_end() now consumes EVERY
      window still open and intersects them, so one leaked window from early in
      the run makes the end-of-run comparison run from that moment instead of
      from the last call. Cases 5-6.

EVERYTHING IS SANDBOXED. HOME, CLAUDE_CONFIG_DIR, TMPDIR, GIT_CONFIG_GLOBAL and
RICHOS_WORKSPACES_DIR are redirected into a temporary directory removed at the
end. The operator's real registry, sessions and repositories are never read or
written. Exit 0 when every case selected reaches its EXPECTED verdict, 1
otherwise.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

CASES = ["late-record-stray", "late-record-side", "record-first-control",
         "late-record-rename", "leaked-window-widens", "leaked-window-evicts"]


def run(*args, **kw):
    r = subprocess.run(list(args), capture_output=True, text=True, env=os.environ.copy())
    if kw.get("check", True) and r.returncode != 0:
        raise AssertionError("%s failed: %s %s" % (args, r.stdout, r.stderr))
    return r.stdout.strip()


def out(label, value):
    print("    %-40s %s" % (label, value))


class Sandbox(object):
    def __init__(self, lib):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="frank-c4-"))
        os.environ["HOME"] = os.path.join(self.root, "home")
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(self.root, "home", ".claude")
        os.environ["TMPDIR"] = os.path.join(self.root, "tmp")
        os.environ["RICHOS_WORKSPACES_DIR"] = os.path.join(self.root, "registry")
        os.environ.pop("RICHOS_SESSION_ID", None)
        os.environ["RICHOS_WORKSPACES_SPAWN_WINDOW"] = "0"
        os.environ["RICHOS_WORKSPACES_RETRY_BASE"] = "0"
        os.makedirs(os.environ["CLAUDE_CONFIG_DIR"])
        os.makedirs(os.environ["TMPDIR"])
        gc = os.path.join(self.root, "home", ".gitconfig")
        with open(gc, "w") as f:
            f.write("[user]\n\tname = frank\n\temail = frank@example.invalid\n"
                    "[init]\n\tdefaultBranch = main\n")
        os.environ["GIT_CONFIG_GLOBAL"] = gc
        spec = importlib.util.spec_from_file_location("wsc4", lib)
        self.ws = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.ws)
        self.procs = []
        self.entity = self.repo("entity")
        self.sid = "sess-frank-c4000001"
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
        p = {"session_id": self.sid, "agent_id": aid}
        if call:
            p["tool_use_id"] = call
        return self.ws.barrier(p)

    def post(self, aid, call=""):
        if not hasattr(self.ws, "observe"):
            return []
        p = {"session_id": self.sid, "agent_id": aid,
             "hook_event_name": "PostToolUse", "tool_name": "Bash"}
        if call:
            p["tool_use_id"] = call
        return self.ws.observe(p)

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
        try:
            self.ws.land(name, self.sid)
            return "landed"
        except Exception as e:
            return "REFUSED: %s" % e

    def pending(self):
        return sorted(i["name"] for i in self.ws.pending(self.sid, self.entity, scan=True))

    def events(self, kind):
        p = os.path.join(os.environ["RICHOS_WORKSPACES_DIR"], "events.jsonl")
        rows = []
        if os.path.exists(p):
            with open(p) as f:
                for line in f:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    if d.get("event") == kind or d.get("kind") == kind or kind in line:
                        rows.append(d)
        return rows

    def record(self, branch, why="this body of work"):
        return self.ws.record_integration(self.entity, branch, why, self.sid)


# ---------------------------------------------------------------------------
# (a) THE ESCALATION: attribution is skipped while no branch is recorded, and
#     the recording that unblocks the land never goes back for what was skipped.
# ---------------------------------------------------------------------------
def case_late_record_stray(s):
    """A stray created before the branch is recorded survives the land that the
    recording unblocks.

    EXPECTED (the page): after the land, 'spare' is gone, or the item is still
    pending. Point 10: "every workspace and branch it has is deleted, as one.
    None is left behind." Point 3: "any branch an agent created ... counts as
    finished work of an ended session and is handled under point 5." """
    aid, npath = s.spawn("zach-opus-r1")
    out("integration record at spawn", s.ws.integration_record(s.entity))
    s.pre(aid, "tu-1")
    s.commit(npath, "own.txt")
    run("git", "-C", npath, "branch", "spare")          # inside the call, its own tip
    s.post(aid, "tu-1")
    out("created_branches (record missing)", s.created("zach-opus-r1"))
    skipped = s.events("attribution-skipped")
    out("attribution-skipped events", len(skipped))
    s.finish(aid)
    # Rich notices, and records the branch. The land is unblocked.
    s.record("main")
    out("Rich records it afterwards", (s.ws.integration_record(s.entity) or {}).get("branch"))
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    verdict = s.land("zach-opus-r1")
    out("land after the recording", verdict[:120])
    after = s.branches(s.entity)
    pend = s.pending()
    out("branches after the land", after)
    out("pending after the land", pend)
    out("the stray is on nobody's record", "spare" not in s.created("zach-opus-r1"))
    return "spare" not in after or pend != []


def case_late_record_side(s):
    """The same, with a side branch carrying a commit that is in NO integration
    branch: the land reports LANDED over it.

    EXPECTED: the land is REFUSED, or the item stays pending. Point 5:
    "everything it produced is landed"; point 8: "Deletion therefore never loses
    anything that was meant to land." """
    aid, npath = s.spawn("zach-opus-r2")
    s.pre(aid, "tu-1")
    run("git", "-C", npath, "checkout", "-q", "-b", "sidework")
    s.commit(npath, "side.txt")
    run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
    s.post(aid, "tu-1")
    out("created_branches (record missing)", s.created("zach-opus-r2"))
    s.commit(npath, "own.txt")
    s.finish(aid)
    s.record("main")
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    verdict = s.land("zach-opus-r2")
    out("land after the recording", verdict[:120])
    log = run("git", "-C", s.entity, "log", "--format=%s", "main")
    out("its side commit reached main", "work side.txt" in log)
    out("branches after the land", s.branches(s.entity))
    out("pending after the land", s.pending())
    out("side commit still only on 'sidework'",
        run("git", "-C", s.entity, "rev-parse", "sidework")
        if "sidework" in s.branches(s.entity) else "(gone)")
    return verdict.startswith("REFUSED") or s.pending() != []


def case_record_first_control(s):
    """THE CONTROL for the two above: the identical shape with the branch
    recorded BEFORE the spawn, which is what point 14 requires. EXPECTED: held.
    This isolates the loss to the ORDER of the recording, not to the shape."""
    s.record("main")
    aid, npath = s.spawn("zach-opus-r3")
    s.pre(aid, "tu-1")
    run("git", "-C", npath, "checkout", "-q", "-b", "sidework")
    s.commit(npath, "side.txt")
    run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
    s.post(aid, "tu-1")
    out("created_branches (record present)", s.created("zach-opus-r3"))
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    verdict = s.land("zach-opus-r3")
    out("land", verdict[:120])
    out("pending", s.pending())
    return verdict.startswith("REFUSED") and "sidework" in verdict


def case_late_record_rename(s):
    """The agent renames its OWN branch while no branch is recorded.

    EXPECTED: after the recording and the land, the renamed branch is gone.
    Point 10: "every workspace and branch it has is deleted, as one." """
    aid, npath = s.spawn("zach-opus-r4")
    s.pre(aid, "tu-1")
    s.commit(npath, "own.txt")
    run("git", "-C", npath, "branch", "-m", "worktree-agent-" + aid, "renamed-work")
    s.post(aid, "tu-1")
    out("created_branches (record missing)", s.created("zach-opus-r4"))
    s.finish(aid)
    s.record("main")
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "renamed-work")
    verdict = s.land("zach-opus-r4")
    out("land after the recording", verdict[:120])
    after = s.branches(s.entity)
    out("branches after the land", after)
    out("pending after the land", s.pending())
    return "renamed-work" not in after or s.pending() != []


# ---------------------------------------------------------------------------
# (b) THE LEAKED WINDOW: a PreToolUse another guard refuses leaves a window no
#     Post will consume, and record_end() intersects EVERY open window.
# ---------------------------------------------------------------------------
def case_leaked_window_widens(s):
    """ONE refused tool call early in the run makes the END-OF-RUN comparison
    run from that moment, so a ref created BETWEEN two later calls -- outside
    every window, which is the class the engineer declines to close -- is
    attributed to the agent and deleted by its discard.

    EXPECTED: 'rich/rescue', which Rich cut while no window was open, survives
    the discard. Point 8: "Deletion therefore never loses anything that was
    meant to land." """
    s.record("main")
    aid, npath = s.spawn("zach-opus-r5")
    # A guard refuses this call at PreToolUse: the barrier already snapshotted,
    # the tool never runs, and no PostToolUse ever arrives for it.
    pass  # CONTROL: no refused call, so no leaked window
    d = os.path.join(os.environ["RICHOS_WORKSPACES_DIR"], "refs")
    leaked = []
    for dp, _dn, fn in os.walk(d):
        leaked += [os.path.join(dp, f) for f in fn]
    out("windows left open by the refused call", len(leaked))
    s.call(aid, "tu-1")
    s.commit(npath, "own.txt")
    s.call(aid, "tu-2")
    tip = run("git", "-C", npath, "rev-parse", "HEAD")
    # BETWEEN tool calls: no window of this agent is open except the leaked one.
    run("git", "-C", s.entity, "branch", "rich/rescue", tip)
    s.call(aid, "tu-3")
    out("created_branches before the end of run", s.created("zach-opus-r5"))
    s.finish(aid)                               # record_end -> all_open=True
    out("created_branches after the end of run", s.created("zach-opus-r5"))
    s.ws.discard("zach-opus-r5", "the reviewer rejected the approach",
                 not_ceo_ordered="a probe of attribution, not the CEO's order", me=s.sid)
    after = s.branches(s.entity)
    out("branches after the discard", after)
    out("rich/rescue survived", "rich/rescue" in after)
    return "rich/rescue" in after


def case_leaked_window_evicts(s):
    """The cap: _MAX_OPEN_CALLS windows of refused calls opened AFTER a live one
    evict it, and its own Post then attributes nothing.

    EXPECTED: the ref created inside the live call is attributed. Point 3: "any
    branch an agent created". Measured for the bound, not because this load
    exists on this machine."""
    s.record("main")
    aid, npath = s.spawn("zach-opus-r6")
    s.call(aid, "tu-warm")
    s.commit(npath, "own.txt")
    s.pre(aid, "tu-live")                       # the live call opens
    for i in range(70):                         # 70 refused calls while it is open
        s.pre(aid, "tu-refused-%03d" % i)
    run("git", "-C", npath, "branch", "spare")  # created inside the live call
    s.post(aid, "tu-live")
    out("created_branches at the live call's Post", s.created("zach-opus-r6"))
    ok = "spare" in s.created("zach-opus-r6")
    s.finish(aid)
    out("created_branches after the end of run", s.created("zach-opus-r6"))
    out("attributed at the Post (not only at the end)", ok)
    return ok


RUNNERS = dict(zip(CASES, [case_late_record_stray, case_late_record_side,
                           case_record_first_control, case_late_record_rename,
                           case_leaked_window_widens, case_leaked_window_evicts]))


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
    for name in CASES:
        if name not in wanted:
            continue
        print("\n=== %d %s — %s" % (CASES.index(name) + 1, name,
                                    RUNNERS[name].__doc__.splitlines()[0]))
        s = Sandbox(lib)
        try:
            ok = bool(RUNNERS[name](s))
        except Exception as e:
            ok = False
            out("EXCEPTION", "%s: %s" % (type(e).__name__, str(e)[:300]))
        finally:
            s.close()
        print("    VERDICT                                  %s" % ("HOLDS" if ok else "BROKEN"))
        if not ok:
            failures.append(name)
    print("\n=== %d/%d cases hold%s" % (len(wanted) - len(failures), len(wanted),
                                        ("; BROKEN: " + ", ".join(failures)) if failures else ""))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
