#!/usr/bin/env python3
"""Frank's probe for the recorded-CREATION round (84e12d32).

    python3 -B certification-frank-recorded-attribution-2026-09-12-probe.py <path-to-workspaces.py> [case ...]

Self-contained: it imports no engine test file and no other probe. It drives the
library through the same entry points the two hooks use —

    PreToolUse  (matcherless)  guard-sealed-worktree.sh -> barrier()
    PostToolUse (matcherless)  observe-created-refs.sh  -> observe()

— and differs from the engineer's own seven-case probe in exactly one respect:
it does not assume that every ref an agent creates comes into existence BETWEEN
the two halves of one of its tool calls. On this machine, two things say
otherwise.

    MEASURED HERE, 2026-09-12. A Bash call issued with run_in_background
    returned to the model at t=1789203115.2 and its process was still working at
    t=1789203118.3 — three seconds after the tool call, and therefore after its
    PostToolUse, had ended. Anything such a process creates is created outside
    every window.

    DOCUMENTED BY THE INSTALLED PLATFORM. "PostToolUse fires per-tool and may
    run concurrently for parallel tool calls; PostToolBatch fires exactly once
    with the full batch." -- strings(1) of
    /Users/alex/.local/share/claude/versions/2.1.269. (Honesty: I did NOT
    observe this. Two Bash calls issued in one block ran serially here, 0.3 s
    apart. The background overhang above is the path I could observe.)

    "Subagent identifier. Present only when the hook fires from within a
     subagent (e.g., a tool called by an AgentTool worker)."     -- same binary

CASES
    outside-stray       a branch that comes into existence outside the pre/post
                        bracket is attributed to nobody and survives the land
    outside-side        the same, with a side branch: land() says landed and the
                        commit is in no integration branch
    floor-trap          the point-14 floor writes the main checkout's own branch
                        at first registration; recording the real dev branch
                        afterwards cannot move an agent already registered, and
                        its land refuses forever
    floor-control       the same work with the branch recorded BEFORE the first
                        registration lands cleanly (so the trap is the floor's,
                        not the dev branch's)
    no-floor-self-heals with NO record at all, a late recording DOES reach the
                        land — which is what the floor takes away
    floor-timing        WHERE the floor actually reads the branch: the session's
                        start, not the first workspace registration
    rich-at-my-tip      the declared cost, measured: a ref Rich cuts at the
                        agent's own unlanded tip during its call is attributed
                        to the agent, and a discard deletes it
    serial-stray        the same stray as case 1, calls NOT overlapped: holds
    serial-side         the same side branch, calls NOT overlapped: holds
    serial-rename       the agent's own branch renamed inside one call: holds

EVERYTHING IS SANDBOXED. HOME, CLAUDE_CONFIG_DIR, TMPDIR, GIT_CONFIG_GLOBAL and
RICHOS_WORKSPACES_DIR are redirected into a temporary directory removed at the
end. The operator's real registry, sessions and repositories are never read or
written. Exit 0 when every case selected reaches its EXPECTED verdict, 1
otherwise. A case whose expectation is "the build fails here" says so in its
name and in its printed expectation, so a green run is never mistaken for a
clean build.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import time

CASES = ["outside-stray", "outside-side", "floor-trap", "floor-control",
         "no-floor-self-heals", "floor-timing", "rich-at-my-tip", "serial-stray",
         "serial-side", "serial-rename"]



def run(*args, **kw):
    r = subprocess.run(list(args), capture_output=True, text=True, env=os.environ.copy())
    if kw.get("check", True) and r.returncode != 0:
        raise AssertionError("%s failed: %s %s" % (args, r.stdout, r.stderr))
    return r.stdout.strip()


def out(label, value):
    print("    %-38s %s" % (label, value))


class Sandbox(object):
    def __init__(self, lib, before_session=None):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="frank-c3-"))
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
        spec = importlib.util.spec_from_file_location("wsut", lib)
        self.ws = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.ws)
        self.procs = []
        self.entity = self.repo("entity")
        # The floor is fired by record_session_start -> _remember_repo ->
        # _ensure_integration, so anything that must precede it happens here.
        if before_session:
            before_session(self)
        self.sid = "sess-frank-c3000001"
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

    def pre(self, aid):
        """One tool call's FIRST half."""
        return self.ws.barrier({"session_id": self.sid, "agent_id": aid})

    def post(self, aid):
        """One tool call's SECOND half."""
        if not hasattr(self.ws, "observe"):
            return []
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
        except Exception as e:
            return "REFUSED: %s" % str(e)[:200]

    def pending(self):
        return sorted(i["name"] for i in self.ws.pending(self.sid, self.entity, scan=True))


# ---------------------------------------------------------------------------
# 1 and 2: a ref that appears outside the bracket. The snapshot is written at
# every Pre and UNLINKED at the Post, so a ref that comes into existence after a
# Post and before the next Pre is in the NEXT snapshot before anything compares:
# it is never new, and it is never anyone's. Modelled here as a call that ends,
# then the ref appearing, then the next call — which is what a backgrounded
# command does, measured at the top of this file.
# ---------------------------------------------------------------------------
def case_outside_stray(s):
    """A stray that appears outside the bracket is attributed to nobody.

    EXPECTED (what the build should do): 'spare' is attributed and gone after
    the land. Point 3: "any branch an agent created"; point 10: "None is left
    behind." """
    aid, npath = s.spawn("zach-opus-q1")
    s.call(aid)
    s.commit(npath, "own.txt")
    # The agent backgrounds a command; its tool call ends; the command then
    # creates the branch; the agent's next tool call starts.
    s.call(aid)                                    # the backgrounded call ends
    run("git", "-C", npath, "branch", "spare")     # its process, still running
    s.call(aid)                                    # the next call
    out("created_branches", s.created("zach-opus-q1"))
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land", s.land("zach-opus-q1"))
    after = s.branches(s.entity)
    out("branches after the land", after)
    out("pending after the land", s.pending())
    return "spare" not in after


def case_outside_side(s):
    """A side branch that appears outside the bracket strands its commits.

    EXPECTED: the land is REFUSED until the side branch is merged or discarded.
    Point 5: "everything it produced is landed"; point 8: "Deletion therefore
    never loses anything that was meant to land." """
    aid, npath = s.spawn("zach-opus-q2")
    s.call(aid)                                                    # the backgrounded call ends
    run("git", "-C", npath, "checkout", "-q", "-b", "sidework")
    s.commit(npath, "side.txt")
    run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
    s.call(aid)                                                    # the next call
    out("created_branches", s.created("zach-opus-q2"))
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    verdict = s.land("zach-opus-q2")
    out("land", verdict)
    log = run("git", "-C", s.entity, "log", "--format=%s", "main")
    out("its side commit is in main", "work side.txt" in log)
    out("branches after the land", s.branches(s.entity))
    out("pending after the land", s.pending())
    return verdict.startswith("REFUSED")


# ---------------------------------------------------------------------------
# 3 and 4: point 14's floor.
# ---------------------------------------------------------------------------
def case_floor_trap(s):
    """The floor freezes the WRONG branch onto an agent, and recording the real
    one afterwards cannot move it.

    EXPECTED: work merged onto the branch this work integrates on is landed and
    its workspaces are deleted. Point 14: "'it cannot go to main yet' is never a
    reason for anything to be left behind or for point 5 to be blocked." """
    run("git", "-C", s.entity, "branch", "dev/workspace-spec")
    # Rich has not recorded anything yet. The first registration fires the floor.
    aid, npath = s.spawn("zach-opus-q3")
    rec = s.ws.integration_record(s.entity) or {}
    out("floor wrote", "%s (source: %s)" % (rec.get("branch"), rec.get("source")))
    out("agent's frozen copy", (s.rec("zach-opus-q3").get("integration") or {}))
    s.call(aid)
    s.commit(npath, "own.txt")
    s.finish(aid)
    # Rich now records the branch this body of work really integrates on.
    s.ws.record_integration(s.entity, "dev/workspace-spec", "the workspace-spec round", s.sid)
    rec2 = s.ws.integration_record(s.entity) or {}
    out("Rich recorded", "%s (source: %s)" % (rec2.get("branch"), rec2.get("source")))
    run("git", "-C", s.entity, "branch", "-f", "dev/workspace-spec",
        run("git", "-C", s.entity, "rev-parse", "worktree-agent-" + aid))
    out("merged onto dev/workspace-spec", True)
    out("in main", "work own.txt" in run("git", "-C", s.entity, "log", "--format=%s", "main"))
    verdict = s.land("zach-opus-q3")
    out("land", verdict)
    out("workspace still there", os.path.exists(npath))
    out("pending (point 5 blocks on this)", s.pending())
    return verdict == "landed"


def case_floor_control(s):
    """The control: the same work, recorded BEFORE the first registration.

    EXPECTED: landed. This is the case the engineer's own probe runs, and it is
    what isolates the trap above to the floor rather than to dev branches."""
    run("git", "-C", s.entity, "branch", "dev/workspace-spec")
    s.ws.record_integration(s.entity, "dev/workspace-spec", "the workspace-spec round", s.sid)
    aid, npath = s.spawn("zach-opus-q4")
    rec = s.ws.integration_record(s.entity) or {}
    out("record", "%s (source: %s)" % (rec.get("branch"), rec.get("source")))
    out("agent's frozen copy", (s.rec("zach-opus-q4").get("integration") or {}))
    s.call(aid)
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "branch", "-f", "dev/workspace-spec",
        run("git", "-C", s.entity, "rev-parse", "worktree-agent-" + aid))
    verdict = s.land("zach-opus-q4")
    out("land", verdict)
    out("workspace gone", not os.path.exists(npath))
    return verdict == "landed"


def _detach_entity(s):
    """Run before the session is recorded: a detached main checkout gives the
    floor no branch to read, which is the library's own only way of having no
    record at all."""
    run("git", "-C", s.entity, "branch", "dev/workspace-spec")
    run("git", "-C", s.entity, "checkout", "-q", "--detach",
        run("git", "-C", s.entity, "rev-parse", "HEAD"))


def case_no_floor_self_heals(s):
    """With NO record at all, a late recording DOES reach the land.

    The main checkout is detached before the session is recorded, so the floor
    has no branch to read and writes nothing — the library's own only path to no
    record. It isolates what the floor changes: with no record,
    integration_target falls through to the repository's LIVE record, so
    recording the dev branch after the agent is registered still lands it.
    EXPECTED: landed."""
    out("record at session start", s.ws.integration_record(s.entity) or "(none)")
    aid, npath = s.spawn("zach-opus-q9")          # still detached: no branch to read
    out("record after registration", s.ws.integration_record(s.entity) or "(none)")
    out("agent's frozen copy", (s.rec("zach-opus-q9").get("integration") or {}) or "(none)")
    s.call(aid)
    s.commit(npath, "own.txt")
    s.finish(aid)
    out("land with no record at all", s.land("zach-opus-q9"))
    s.ws.record_integration(s.entity, "dev/workspace-spec", "the workspace-spec round", s.sid)
    run("git", "-C", s.entity, "branch", "-f", "dev/workspace-spec",
        run("git", "-C", s.entity, "rev-parse", "worktree-agent-" + aid))
    verdict = s.land("zach-opus-q9")
    out("land after Rich records the dev branch", verdict)
    out("workspace gone", not os.path.exists(npath))
    return verdict == "landed"


def _branch_off(s):
    """Run before the session is recorded: the main checkout sits on a branch
    that is NOT the one it will be on when the first agent is registered."""
    run("git", "-C", s.entity, "checkout", "-q", "-b", "whatever-rich-was-on")


def case_floor_timing(s):
    """WHERE the floor actually reads the branch.

    The commit message says the floor reads the main checkout's own branch "at
    the registration of the first workspace in that repository". EXPECTED, on
    that description: the record names the branch the checkout is on when the
    agent is registered. What it names instead is the branch it was on when the
    SESSION was recorded, because record_session_start calls _remember_repo."""
    out("record at session start", (s.ws.integration_record(s.entity) or {}).get("branch"))
    run("git", "-C", s.entity, "checkout", "-q", "main")          # Rich moves on
    aid, _npath = s.spawn("zach-opus-qa")
    rec = s.ws.integration_record(s.entity) or {}
    out("main checkout's branch at registration", "main")
    out("record after registration", "%s (source: %s)" % (rec.get("branch"), rec.get("source")))
    out("agent's frozen copy", (s.rec("zach-opus-qa").get("integration") or {}))
    return rec.get("branch") == "main"


# ---------------------------------------------------------------------------
# 5: the declared indistinguishable case, measured rather than accepted.
# ---------------------------------------------------------------------------
def case_rich_at_my_tip(s):
    """A ref Rich cuts AT the agent's own unlanded tip DURING its call.

    The engineer declares this one cannot be told apart and bounds it. This
    measures the bound: what the land does, and what a discard does to Rich's
    branch. EXPECTED here is only that the two claims he makes are true — the
    land refuses while it is unlanded, and the discard records the tip it
    deletes."""
    aid, npath = s.spawn("zach-opus-q5")
    s.call(aid)
    s.commit(npath, "own.txt")
    s.pre(aid)
    tip = run("git", "-C", npath, "rev-parse", "HEAD")
    run("git", "-C", s.entity, "branch", "rich/rescue", tip)     # Rich, at the agent's tip
    s.post(aid)
    out("created_branches", s.created("zach-opus-q5"))
    s.finish(aid)
    held = s.land("zach-opus-q5")
    out("land while rich/rescue is unmerged", held)
    s.ws.discard("zach-opus-q5", "the reviewer rejected the approach",
                 not_ceo_ordered="a probe of attribution, not the CEO's order", me=s.sid)
    after = s.branches(s.entity)
    out("branches after the discard", after)
    rec = s.rec("zach-opus-q5")
    disp = rec.get("disposition") or {}
    deleted = [b for b in (rec.get("branches_deleted") or [])] or disp.get("branches") or []
    out("the record of what was deleted", deleted or "(none on the record)")
    ev = os.path.join(os.environ["RICHOS_WORKSPACES_DIR"], "events.jsonl")
    tipped = False
    if os.path.exists(ev):
        with open(ev) as f:
            body = f.read()
        tipped = tip[:12] in body
        out("the deleted tip is in the event log", tipped)
    out("rich/rescue survived", "rich/rescue" in after)
    return held.startswith("REFUSED") and tipped


# ---------------------------------------------------------------------------
# 6, 7, 8: the same three shapes with the calls NOT overlapped. These are the
# control for everything above: the mechanism does work when one call is open.
# ---------------------------------------------------------------------------
def case_serial_stray(s):
    """The stray, one call at a time. EXPECTED: attributed and deleted."""
    aid, npath = s.spawn("zach-opus-q6")
    s.call(aid)
    s.pre(aid)
    s.commit(npath, "own.txt")
    run("git", "-C", npath, "branch", "spare")
    s.post(aid)
    out("created_branches", s.created("zach-opus-q6"))
    s.finish(aid)
    out("land before its branch is merged", s.land("zach-opus-q6"))
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    out("land after", s.land("zach-opus-q6"))
    after = s.branches(s.entity)
    out("branches after the land", after)
    return "spare" not in after


def case_serial_side(s):
    """The side branch, one call at a time. EXPECTED: the land is held."""
    aid, npath = s.spawn("zach-opus-q7")
    s.pre(aid)
    run("git", "-C", npath, "checkout", "-q", "-b", "sidework")
    s.commit(npath, "side.txt")
    run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
    s.post(aid)
    out("created_branches", s.created("zach-opus-q7"))
    s.commit(npath, "own.txt")
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "worktree-agent-" + aid)
    held = s.land("zach-opus-q7")
    out("land with the side branch out", held)
    return held.startswith("REFUSED") and "sidework" in held


def case_serial_rename(s):
    """The agent renames its OWN branch inside one call. EXPECTED: the new name
    goes with it (point 10, "every workspace and branch it has")."""
    aid, npath = s.spawn("zach-opus-q8")
    s.call(aid)
    s.pre(aid)
    s.commit(npath, "own.txt")
    run("git", "-C", npath, "branch", "-m", "worktree-agent-" + aid, "renamed-work")
    s.post(aid)
    out("created_branches", s.created("zach-opus-q8"))
    s.finish(aid)
    run("git", "-C", s.entity, "merge", "-q", "--no-edit", "renamed-work")
    out("land", s.land("zach-opus-q8"))
    after = s.branches(s.entity)
    out("branches after the land", after)
    return "renamed-work" not in after


RUNNERS = dict(zip(CASES, [case_outside_stray, case_outside_side, case_floor_trap,
                           case_floor_control, case_no_floor_self_heals, case_floor_timing,
                           case_rich_at_my_tip, case_serial_stray, case_serial_side,
                           case_serial_rename]))
BEFORE = {"no-floor-self-heals": _detach_entity, "floor-timing": _branch_off}


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
        s = Sandbox(lib, BEFORE.get(name))
        try:
            ok = bool(RUNNERS[name](s))
        except Exception as e:
            ok = False
            out("EXCEPTION", "%s: %s" % (type(e).__name__, str(e)[:300]))
        finally:
            s.close()
        print("    VERDICT                                %s" % ("HOLDS" if ok else "BROKEN"))
        if not ok:
            failures.append(name)
    print("\n=== %d/%d cases hold%s" % (len(wanted) - len(failures), len(wanted),
                                        ("; BROKEN: " + ", ".join(failures)) if failures else ""))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
