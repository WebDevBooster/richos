#!/usr/bin/env python3
"""workspaces.test.py — one test per numbered point of the CEO's workspace spec
(docs/plans/worktree-spec-2026-09-11.md), each named after its point.

Every test runs in temporary git repositories with HOME and CLAUDE_CONFIG_DIR
redirected into a temporary directory: the operator's real ledger, sessions,
teams and worktrees are never read or written. A session is a real process
(`sleep`) whose pid the registry records, so "its process no longer exists"
is a fact the operating system reports, not a fixture flag.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import threading
from unittest.mock import patch
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "workspaces.py")

os.environ["RICHOS_WORKSPACES_RETRY_BASE"] = "0"
os.environ["RICHOS_WORKSPACES_STOP_GRACE"] = "1"
os.environ["RICHOS_WORKSPACES_SPAWN_WINDOW"] = "0"
spec = importlib.util.spec_from_file_location("workspaces", LIB)
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)


def run(*args, **kw):
    cwd = kw.pop("cwd", None)
    r = subprocess.run(list(args), cwd=cwd, capture_output=True, text=True, env=os.environ.copy())
    if kw.get("check", True) and r.returncode != 0:
        raise AssertionError("%s failed: %s %s" % (args, r.stdout, r.stderr))
    return r


class Env(object):
    """A sandbox: HOME, CLAUDE_CONFIG_DIR, repositories, session processes."""

    def __init__(self):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="ws-spec-"))
        self.home = os.path.join(self.root, "home")
        os.makedirs(self.home)
        self.saved = {k: os.environ.get(k) for k in ("HOME", "CLAUDE_CONFIG_DIR", "RICHOS_WORKSPACES_DIR",
                                                     "RICHOS_SESSION_PID", "RICHOS_SESSIONS_DIR",
                                                     "RICHOS_SESSION_ID", "GIT_CONFIG_GLOBAL")}
        os.environ["HOME"] = self.home
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(self.home, ".claude")
        os.environ.pop("RICHOS_WORKSPACES_DIR", None)
        os.environ.pop("RICHOS_SESSION_ID", None)
        gc = os.path.join(self.home, ".gitconfig")
        with open(gc, "w") as f:
            f.write("[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n")
        os.environ["GIT_CONFIG_GLOBAL"] = gc
        self.procs = []

    def repo(self, name):
        p = os.path.join(self.root, name)
        os.makedirs(p)
        run("git", "init", "-q", "-b", "main", p)
        with open(os.path.join(p, ".gitignore"), "w") as f:
            f.write(".env\nbuild/\n")
        with open(os.path.join(p, "README"), "w") as f:
            f.write("x\n")
        run("git", "-C", p, "add", "-A")
        run("git", "-C", p, "commit", "-q", "-m", "init")
        return p

    def session(self, sid, cwd):
        """A running session: a real process, recorded at its start (point 12)."""
        pr = subprocess.Popen(["sleep", "600"])
        self.procs.append(pr)
        os.environ["RICHOS_SESSION_PID"] = str(pr.pid)
        time.sleep(0.05)
        ws.record_session_start(sid, cwd)
        return pr

    def use(self, pr):
        os.environ["RICHOS_SESSION_PID"] = str(pr.pid)

    def close(self):
        for pr in self.procs:
            try:
                pr.kill()
                pr.wait()
            except OSError:
                pass
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        subprocess.run(["chmod", "-R", "u+w", self.root], capture_output=True)
        shutil.rmtree(self.root, ignore_errors=True)


def worktrees(repo):
    return [e["path"] for e in ws.worktree_list(repo)]


def branches(repo):
    return run("git", "-C", repo, "for-each-ref", "--format=%(refname:short)", "refs/heads").stdout.split()


class Base(unittest.TestCase):
    def setUp(self):
        self.env = Env()
        self.entity = self.env.repo("entity")
        self.other = self.env.repo("other")
        self.sid = "sess-aaaaaaaa-1111"
        self.sess = self.env.session(self.sid, self.entity)
        # Point 14: "The branch a body of work integrates on is RECORDED when
        # that work starts, before its first agent is spawned. Nothing infers it
        # and nothing guesses it." Nothing in the library derives this any more,
        # so the fixture records it exactly as Rich does — one command, before
        # the first spawn. A test that wants the no-record case removes it.
        ws.record_integration(self.entity, "main", "the fixture's body of work", self.sid)
        ws.record_integration(self.other, "main", "the fixture's body of work", self.sid)

    def tearDown(self):
        self.env.close()

    # --- the spawn, exactly as the hooks see it ---------------------------
    def make_cc(self, name, repo=None, base="HEAD"):
        repo = repo or self.other
        path = os.path.join(self.env.root, os.path.basename(repo) + "-wt", name)
        ws.register_cc(self.sid, name, repo, path, "cc/" + name)
        run("git", "-C", repo, "worktree", "add", "-q", path, "-b", "cc/" + name, base)
        ws.confirm_cc(self.sid, name, path, True)
        return path

    def spawn(self, name, cc=None, extra="", native=True, agent_id=None, sid=None):
        sid = sid or self.sid
        prompt = "do it\n" + ("cross-repo-worktree: %s\n" % cc if cc else "") + extra
        payload = {"session_id": sid, "tool_use_id": "tu-" + name, "tool_name": "Agent",
                   "tool_input": {"name": name, "subagent_type": "zach", "prompt": prompt,
                                  "isolation": "worktree" if native else ""}}
        ws.register_spawn(payload, self.entity)
        aid = agent_id or ("a" + name.replace("-", "")[:12] + "0000")
        npath = os.path.join(self.entity, ".claude", "worktrees", "agent-" + aid)
        if native:
            run("git", "-C", self.entity, "worktree", "add", "-q", npath, "-b", "worktree-agent-" + aid)
            ws.record_start(sid, aid, npath, "zach")
        ws.bind_agent(sid, "tu-" + name, aid, self.entity)
        return aid, npath

    def commit(self, path, fname="work.txt", text="work\n"):
        with open(os.path.join(path, fname), "w") as f:
            f.write(text)
        run("git", "-C", path, "add", fname)
        run("git", "-C", path, "commit", "-q", "-m", "work " + fname)

    def merge(self, repo, branch):
        run("git", "-C", repo, "merge", "-q", "--no-edit", branch)

    def spawn_readonly(self, agent_id, subagent_type="Explore", name=""):
        """A read-only spawn, exactly as the hooks make it: the guard registers
        it (no workspace, no name contract) and PostToolUse binds its id."""
        tuid = "tu-ro-" + agent_id
        payload = {"session_id": self.sid, "tool_use_id": tuid, "tool_name": "Agent",
                   "tool_input": {"subagent_type": subagent_type, "name": name,
                                  "prompt": "Find where the login button is defined."}}
        ws.register_readonly(payload, self.entity)
        ws.bind_agent(self.sid, tuid, agent_id, self.entity)
        return agent_id

    def pre(self, aid, call=""):
        """The FIRST half of one of the worker's own tool calls, exactly as the
        catch-all PreToolUse hook makes it: a payload carrying the platform's
        agent id and this call's own `tool_use_id`. It takes the snapshot
        creation is measured against (point 3)."""
        payload = {"session_id": self.sid, "agent_id": aid}
        if call:
            payload["tool_use_id"] = call
        return ws.barrier(payload)

    def post(self, aid, tool="Bash", call=""):
        """The SECOND half, exactly as the catch-all PostToolUse hook makes it.
        Together the two are one tool call, and a ref that appeared in between
        was created by this agent. The call id is the SAME string at both halves,
        which is what lets two of one agent's calls be open at once."""
        payload = {"session_id": self.sid, "agent_id": aid, "tool_name": tool,
                   "hook_event_name": "PostToolUse"}
        if call:
            payload["tool_use_id"] = call
        return ws.observe(payload)

    def tool_call(self, aid, call=""):
        """A whole tool call: both halves, with nothing in between."""
        verdict = self.pre(aid, call)
        self.post(aid, call=call)
        return verdict

    def created(self, name, sid=None):
        return sorted(b for _r, b in (tuple(x) for x in
                                      (self.rec(name, sid) or {}).get("created_branches") or []))

    def finish(self, aid):
        ws.record_end(self.sid, aid, "SubagentStop")

    def rec(self, name, sid=None):
        return ws.load_agent(ws.named_key(sid or self.sid, name))

    def names(self, sid=None):
        return sorted(i["name"] for i in ws.pending(sid or self.sid, self.entity, scan=True))


# ===========================================================================
class Point01_CcNaming(Base):
    """1. Every non-native Claude workspace is named cc/."""

    def test_point_01_every_non_native_workspace_is_named_cc(self):
        path = self.make_cc("zach-opus-p1")
        self.assertIn(path, worktrees(self.other))
        self.assertIn("cc/zach-opus-p1", branches(self.other))
        with self.assertRaises(ws.SpecError):
            ws.register_cc(self.sid, "zach-opus-p1b", self.other, os.path.join(self.env.root, "x"), "feature/x")

    def test_point_01_only_cc_non_native_workspaces_are_the_systems_concern(self):
        run("git", "-C", self.other, "worktree", "add", "-q", os.path.join(self.env.root, "mine"), "-b", "human/x")
        ws.pending(self.sid, self.entity, scan=True)
        self.assertEqual([a for a in ws.all_agents() if a.get("orphan")], [])
        self.assertIn(os.path.join(self.env.root, "mine"), worktrees(self.other))


class Point02_Codex(Base):
    """2. codex/ is never touched."""

    def test_point_02_codex_is_never_touched(self):
        cpath = os.path.join(self.env.root, "codex-wt")
        run("git", "-C", self.other, "worktree", "add", "-q", cpath, "-b", "codex/fix")
        run("git", "-C", self.other, "branch", "codex/other")
        # never listed as unregistered work
        self.assertEqual(self.names(), [])
        # never spawned into
        payload = {"session_id": self.sid, "tool_use_id": "tu-c", "tool_name": "Agent",
                   "tool_input": {"name": "zach-opus-c", "prompt": "cross-repo-worktree: %s\n" % cpath,
                                  "isolation": "worktree"}}
        with self.assertRaises(ws.SpecError):
            ws.register_spawn(payload, self.entity)
        # never deleted, even named directly
        self.assertFalse(ws.delete_branch(self.other, "codex/other")[0])
        ok, why = ws.remove_workspace({"path": cpath, "repo": self.other})
        self.assertFalse(ok)
        self.assertIn("codex/", why)
        # and a land in the same repository leaves it alone
        cc = self.make_cc("zach-opus-c2")
        aid, _n = self.spawn("zach-opus-c2", cc=cc)
        self.finish(aid)
        ws.pending(self.sid, self.entity, scan=True)
        self.assertIn(cpath, worktrees(self.other))
        self.assertIn("codex/fix", branches(self.other))
        self.assertIn("codex/other", branches(self.other))


class Point03_TwoEvents(Base):
    """3. Two events, nothing else."""

    def test_point_03_failed_registration_means_no_spawn(self):
        # a cross-repo spawn naming a workspace nobody registered
        rogue = os.path.join(self.env.root, "rogue")
        run("git", "-C", self.other, "worktree", "add", "-q", rogue, "-b", "cc/rogue")
        payload = {"session_id": self.sid, "tool_use_id": "tu-r", "tool_name": "Agent",
                   "tool_input": {"name": "zach-opus-r", "prompt": "cross-repo-worktree: %s\n" % rogue,
                                  "isolation": "worktree"}}
        with self.assertRaises(ws.SpecError):
            ws.register_spawn(payload, self.entity)
        # and a registration that cannot read its session's process is refused
        os.environ["RICHOS_SESSION_PID"] = "999999"
        with self.assertRaises(ws.SpecError):
            ws.register_cc(self.sid, "zach-opus-r2", self.other, os.path.join(self.env.root, "r2"), "cc/r2")

    def test_point_03_unregistered_workspace_and_branch_are_finished_work(self):
        wt = os.path.join(self.env.root, "other-wt", "stray")
        run("git", "-C", self.other, "worktree", "add", "-q", wt, "-b", "cc/stray")
        self.commit(wt)
        run("git", "-C", self.entity, "branch", "worktree-agent-deadbeef00")
        run("git", "-C", self.entity, "checkout", "-q", "worktree-agent-deadbeef00")
        self.commit(self.entity, "native.txt")
        run("git", "-C", self.entity, "checkout", "-q", "main")
        ws._remember_repo(self.other)
        names = self.names()
        self.assertEqual(len(names), 2, names)
        self.assertTrue(all(n.startswith("orphan-") for n in names))

    # --- point 3, "any branch an agent created": WHOSE branch is it? ------
    # Attribution is read from the agent's OWN workspace and nowhere else. Two
    # agents in one repository is the normal case, and a repository-wide look
    # cannot tell "this agent made this ref" from "this ref appeared while this
    # agent happened to be running".

    def test_point_03_another_live_agents_branch_is_never_attributed(self):
        """B's branches are B's while A is running -- INCLUDING when every one of
        them appears DURING one of A's own tool calls, which is the hard case and
        the normal one: Rich spawns B while A works. Attributing them to A
        refused A's land (B's branch is not in main) and then DELETED them on a
        discard -- against point 8, "deletion therefore never loses anything that
        was meant to land", and point 5's guarantee for B.

        A has produced nothing of its own when its call closes, so it has no
        unlanded commit for anything to be on one line of history with, and
        nothing in the window is its own however it got there (filter 4)."""
        a_cc = self.make_cc("zach-opus-a1")
        aid_a, npath_a = self.spawn("zach-opus-a1", cc=a_cc)
        self.pre(aid_a)                                      # A's own call opens
        b_cc = self.make_cc("zach-opus-b1")                  # ...and inside it, all of B:
        aid_b, npath_b = self.spawn("zach-opus-b1", cc=b_cc)
        self.tool_call(aid_b)
        self.commit(npath_b, "b.txt")
        self.commit(b_cc, "bcc.txt")
        run("git", "-C", self.entity, "branch", "b-side", "worktree-agent-" + aid_b)
        self.post(aid_a)                                     # A's call closes: none of it is A's
        self.assertEqual(self.created("zach-opus-a1"), [])
        self.commit(npath_a, "a.txt")
        self.commit(a_cc, "acc.txt")
        self.finish(aid_a)                                   # nor at A's end-of-run signal
        self.assertEqual(self.created("zach-opus-a1"), [])
        self.merge(self.entity, "worktree-agent-" + aid_a)
        self.merge(self.other, "cc/zach-opus-a1")
        ws.land("zach-opus-a1", self.sid)                    # never held up by a branch of B's
        self.assertIn("cc/zach-opus-b1", branches(self.other))
        self.assertIn("worktree-agent-" + aid_b, branches(self.entity))
        self.assertIn("b-side", branches(self.entity))
        self.assertTrue(os.path.exists(b_cc))
        self.assertTrue(os.path.exists(npath_b))

    def test_point_03_a_continuing_agents_branch_is_never_its_predecessors(self):
        """THE ONE SHAPE WHERE ANOTHER AGENT'S REF IS ON THIS AGENT'S OWN LINE OF
        HISTORY, and the record is the only thing that tells them apart.

        Point 7: unfinished work is continued by a new agent, so the new agent's
        workspace is cut FROM the old agent's branch and its commits descend from
        the old agent's. Rich creates that workspace while the old agent is still
        in a tool call (create-teammate-worktree.sh runs before the spawn), so it
        is new, it is not landed, and it IS related to A's work -- every filter
        but one lets it through. The one that stops it is the record: a ref
        registered to another agent is never this agent's."""
        a_cc = self.make_cc("zach-opus-c1")
        aid_a, _npath_a = self.spawn("zach-opus-c1", cc=a_cc)
        self.tool_call(aid_a)
        self.commit(a_cc, "a.txt")                           # A's own unlanded work
        self.pre(aid_a)
        b_cc = self.make_cc("zach-opus-c2", base="cc/zach-opus-c1")   # cut from A's branch
        self.commit(b_cc, "b.txt")                           # and built on top of it
        self.post(aid_a)
        self.assertEqual(self.created("zach-opus-c1"), [])
        self.finish(aid_a)
        self.merge(self.other, "cc/zach-opus-c1")
        ws.land("zach-opus-c1", self.sid)                    # not held up by B's branch
        self.assertIn("cc/zach-opus-c2", branches(self.other))
        self.assertTrue(os.path.exists(b_cc))

    def test_point_03_a_branch_rich_cuts_in_the_main_checkout_is_never_the_agents(self):
        """Rich's own refs are not the system's concern (point 1) and are never
        deleted with an agent -- neither one he cuts in the main checkout nor one
        he checks out and commits on in a workspace of his own. Both are cut
        INSIDE one of the agent's own tool calls, while the agent has unlanded
        work of its own: co-occurrence in time is not authorship, so two
        different filters have to hold.

        `rich/notes` sits at the integration tip, so it carries nothing that is
        not landed and there is nothing at stake in it (filter 3). `rich/look`
        carries a commit of Rich's that is NOT landed -- and is on a line of
        history of his own rather than the agent's, so it is not the agent's
        either (filter 4)."""
        aid, npath = self.spawn("zach-opus-m1")
        self.tool_call(aid)
        self.commit(npath)                                   # the agent's own unlanded work
        self.pre(aid)                                        # its next call opens
        run("git", "-C", self.entity, "branch", "rich/notes")          # in the main checkout
        look = os.path.join(self.env.root, "rich-look")
        run("git", "-C", self.entity, "worktree", "add", "-q", look, "-b", "rich/look")
        self.commit(look, "rich.txt")                        # Rich's own commit, in no branch of the agent's
        self.post(aid)                                       # the call closes
        self.assertEqual(self.created("zach-opus-m1"), [])
        self.finish(aid)
        self.merge(self.entity, "worktree-agent-" + aid)
        ws.land("zach-opus-m1", self.sid)
        self.assertIn("rich/notes", branches(self.entity))
        self.assertIn("rich/look", branches(self.entity))
        self.assertTrue(os.path.exists(look))

    def test_point_03_two_agents_in_one_repository_both_land_their_own_refs(self):
        """The normal case, end to end: both land automatically (point 4) and
        neither takes the other's refs, so neither is left undecided (point 5)."""
        aid_a, pa = self.spawn("zach-opus-t1")
        self.tool_call(aid_a)
        aid_b, pb = self.spawn("zach-opus-t2")
        self.tool_call(aid_b)
        self.commit(pa, "a.txt")
        self.commit(pb, "b.txt")
        self.tool_call(aid_a)
        self.tool_call(aid_b)
        self.assertEqual(self.rec("zach-opus-t1")["created_branches"], [])
        self.assertEqual(self.rec("zach-opus-t2")["created_branches"], [])
        self.finish(aid_a)
        self.finish(aid_b)
        self.merge(self.entity, "worktree-agent-" + aid_a)
        self.merge(self.entity, "worktree-agent-" + aid_b)
        self.assertEqual(self.names(), [])
        for name, aid, path in (("zach-opus-t1", aid_a, pa), ("zach-opus-t2", aid_b, pb)):
            self.assertTrue(os.path.exists(ws.done_path(ws.named_key(self.sid, name))), name)
            self.assertFalse(os.path.exists(path), name)
            self.assertNotIn("worktree-agent-" + aid, branches(self.entity))

    def test_point_03_claude_worktree_sessions_are_not_allowed(self):
        wt = os.path.join(self.entity, ".claude", "worktrees", "my-session")
        run("git", "-C", self.entity, "worktree", "add", "-q", wt, "-b", "worktree-my-session")
        sid2 = "sess-worktree-2222"
        self.env.session(sid2, wt)
        kind, why = ws.barrier({"session_id": sid2, "tool_name": "Bash"})
        self.assertEqual(kind, "FORBIDDEN", why)
        self.assertEqual(ws.barrier({"session_id": self.sid, "tool_name": "Bash"})[0], "LEAD")


class Point04_LandedMeansDeleted(Base):
    """4. Landed means the workspace AND the branch are deleted — automatically."""

    def test_point_04_landed_means_workspace_and_branch_deleted_automatically(self):
        aid, npath = self.spawn("zach-opus-p4")
        self.commit(npath)
        self.finish(aid)
        self.assertEqual(self.names(), ["zach-opus-p4"])   # finished, not landed: pending
        self.merge(self.entity, "worktree-agent-" + aid)
        self.assertEqual(self.names(), [])                 # landed: nothing undecided
        self.assertNotIn(npath, worktrees(self.entity))
        self.assertFalse(os.path.exists(npath))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))
        self.assertEqual(self.rec("zach-opus-p4")["disposition"]["kind"], "landed")


class Point05_Guarantee(Base):
    """5. Rich lands 100% of everything after the agent is finished — guaranteed."""

    def _pending_one(self):
        aid, npath = self.spawn("zach-opus-p5")
        self.commit(npath)
        self.finish(aid)
        return aid, npath

    def test_point_05_no_new_work_while_finished_work_is_pending(self):
        self._pending_one()
        with self.assertRaises(ws.SpecError) as cm:
            self.spawn("zach-opus-new")
        self.assertIn("zach-opus-p5", str(cm.exception))
        # work whose only purpose is landing it is allowed
        self.spawn("zach-opus-fix", extra="lands-pending: zach-opus-p5\n")

    def test_point_05_no_turn_end_while_finished_work_is_pending(self):
        self._pending_one()
        ok, msg = ws.gate_stop({"session_id": self.sid}, self.entity)
        self.assertFalse(ok)
        self.assertIn("zach-opus-p5", msg)

    def test_point_05_answering_the_ceo_names_the_pending_work(self):
        """The NEGATIVE case comes FIRST: the one allowance is spent by the
        reply that uses it, and a refusal after that would be for the wrong
        reason (round 8: a mutant that let a notification count as the CEO
        survived the old order, because the second gate call was refused for
        the spent allowance, not for the notification)."""
        self._pending_one()
        tr = os.path.join(self.env.root, "t.jsonl")
        # a notification is not the CEO — stamped as the platform stamps it
        with open(tr, "w") as f:
            f.write(json.dumps({"type": "user", "origin": {"kind": "task-notification"}, "promptSource": "system",
                                "queueSkipAttachments": True,
                                "message": {"role": "user", "content": "<task-notification>x</task-notification>"}}) + "\n")
        ok, _m = ws.gate_stop({"session_id": self.sid, "transcript_path": tr,
                               "last_assistant_message": "Pending: zach-opus-p5."}, self.entity)
        self.assertFalse(ok)
        with open(tr, "w") as f:
            f.write(json.dumps({"type": "user", "origin": {"kind": "human"}, "promptSource": "typed",
                                "message": {"role": "user", "content": "stop everything"}}) + "\n")
        ok, _m = ws.gate_stop({"session_id": self.sid, "transcript_path": tr,
                               "last_assistant_message": "Stopping. Pending: zach-opus-p5."}, self.entity)
        self.assertTrue(ok)

    def test_point_05_the_gate_answers_inside_its_budget(self):
        """"This is a guarantee, not a habit: it holds whether or not Rich
        remembers." The gate runs inside hook timeouts the platform enforces by
        CANCELING the hook and DISCARDING its output, while its work grows with
        the backlog. So it answers inside a budget: the item it could not check
        stays pending, which is the safe answer AND the cheap one, and it says
        which items those were rather than going quiet. No time is asserted
        here — only that an exhausted budget still yields a decision,
        announced, and lands nothing by guess."""
        aid, npath = self._pending_one()
        self.merge(self.entity, "worktree-agent-" + aid)     # it would auto-land
        os.environ["RICHOS_WORKSPACES_GATE_BUDGET"] = "0"
        try:
            ok, msg = ws.gate_stop({"session_id": self.sid}, self.entity)
            self.assertFalse(ok)                             # a decision, not a dead hook
            self.assertIn("zach-opus-p5", msg)               # and it names the item
            self.assertIn("budget", msg)                     # and says why it is still pending
            self.assertIsNone(self.rec("zach-opus-p5")["disposition"])
            self.assertTrue(os.path.exists(npath))
            with self.assertRaises(ws.SpecError):            # the spawn half answers too
                self.spawn("zach-opus-nb")
        finally:
            os.environ.pop("RICHOS_WORKSPACES_GATE_BUDGET", None)
        # with its budget the same call decides the other way, on the same facts
        self.assertTrue(ws.gate_stop({"session_id": self.sid}, self.entity)[0])
        self.assertFalse(os.path.exists(npath))

    def test_point_05_the_answer_allowance_is_spent_once_per_item(self):
        """"...the reply names the pending work, WHICH IS HANDLED RIGHT AFTER."
        Naming it again is not handling it: the allowance is spent per item and
        returns only when that item has moved."""
        _aid, npath = self._pending_one()
        tr = os.path.join(self.env.root, "allowance.jsonl")
        with open(tr, "w") as f:
            f.write(json.dumps({"type": "user", "origin": {"kind": "human"}, "promptSource": "typed",
                                "message": {"role": "user", "content": "what is the state of things?"}}) + "\n")
        answer = {"session_id": self.sid, "transcript_path": tr,
                  "last_assistant_message": "Answering. Pending: zach-opus-p5 — handled right after."}
        self.assertTrue(ws.gate_stop(dict(answer), self.entity)[0])     # the one allowance
        ok, msg = ws.gate_stop(dict(answer), self.entity)               # the same reply, nothing handled
        self.assertFalse(ok)
        self.assertIn("already used its one allowance", msg)
        self.assertIn("zach-opus-p5", msg)
        self.commit(npath, "left-behind.txt")                           # the item MOVES
        self.assertTrue(ws.gate_stop(dict(answer), self.entity)[0])     # so it may be named again
        self.assertFalse(ws.gate_stop(dict(answer), self.entity)[0])    # and it is spent again

    def test_point_05_waiting_items_allow_turn_end_but_not_new_work(self):
        self._pending_one()
        ws.wait("zach-opus-p5", "outside", "GitHub is down", "CEO-TODOs 9.9", self.sid)
        self.assertTrue(ws.gate_stop({"session_id": self.sid}, self.entity)[0])
        with self.assertRaises(ws.SpecError):
            self.spawn("zach-opus-new2")
        with self.assertRaises(ws.SpecError):
            ws.wait("zach-opus-p5", "outside", "x", "", self.sid)   # must be on his TODO list

    def test_point_05_a_ceo_discard_question_blocks_nothing_else(self):
        """"that one item then waits on him, is on his TODO list, and blocks
        nothing else" — the other pending items still land and the turn may
        end — AND "New work stays blocked either way", whose own parenthesis
        names the CEO's word. Both sentences hold at once (round 8, item 7)."""
        aid2, npath2 = self.spawn("zach-opus-other")        # a second agent, running while nothing is pending
        aid, npath = self.spawn("zach-opus-ceo", extra="ceo-ordered: 'Implement spec.'\n")
        self.commit(npath)
        self.finish(aid)
        ws.wait("zach-opus-ceo", "ceo-discard", "May I discard the rejected spec branch?", "CEO-TODOs 1.1", self.sid)
        self.assertTrue(ws.gate_stop({"session_id": self.sid}, self.entity)[0])   # the turn may end
        with self.assertRaises(ws.SpecError) as cm:                              # new work stays blocked
            self.spawn("zach-opus-unrelated")
        self.assertIn("zach-opus-ceo", str(cm.exception))
        # "blocks nothing else": the second agent finishes, is merged, and lands
        # on its own while the first still waits on him.
        self.commit(npath2, "other.txt")
        self.finish(aid2)
        self.merge(self.entity, "worktree-agent-" + aid2)
        self.assertTrue(ws.gate_stop({"session_id": self.sid}, self.entity)[0])
        self.assertFalse(os.path.exists(npath2))
        self.assertEqual(ws.load_agent(ws.named_key(self.sid, "zach-opus-other"))["disposition"]["kind"], "landed")
        self.assertIsNone(self.rec("zach-opus-ceo")["disposition"])              # still waiting on his word

    def test_point_05_an_agent_started_to_land_it_lets_the_turn_end(self):
        self._pending_one()
        self.spawn("zach-opus-helper", extra="lands-pending: zach-opus-p5\n")
        self.assertTrue(ws.gate_stop({"session_id": self.sid}, self.entity)[0])

    def test_point_05_the_next_session_starts_with_it(self):
        self._pending_one()
        self.sess.kill()
        self.sess.wait()
        s2 = self.env.session("sess-bbbbbbbb-2222", self.entity)
        ctx, _n = ws.lifecycle({"hook_event_name": "SessionStart", "session_id": "sess-bbbbbbbb-2222",
                                "cwd": self.entity}, self.entity)
        self.assertIn("zach-opus-p5", ctx)
        self.assertIn("FIRST", ctx)


class Point06_Native(Base):
    """6. Native workspaces get exactly the same treatment."""

    def test_point_06_native_workspaces_registered_at_spawn_and_deleted_on_land(self):
        aid, npath = self.spawn("zach-opus-p6")
        r = self.rec("zach-opus-p6")
        self.assertEqual([w["path"] for w in r["workspaces"] if w["kind"] == "native"], [npath])
        self.finish(aid)
        self.assertEqual(self.names(), [])                  # produced nothing: landed, deleted
        self.assertFalse(os.path.exists(npath))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))

    def test_point_06_subagentstart_before_the_agent_result(self):
        payload = {"session_id": self.sid, "tool_use_id": "tu-s", "tool_name": "Agent",
                   "tool_input": {"name": "zach-opus-s", "prompt": "x", "isolation": "worktree"}}
        ws.register_spawn(payload, self.entity)
        aid = "aorderfirst0001"
        npath = os.path.join(self.entity, ".claude", "worktrees", "agent-" + aid)
        run("git", "-C", self.entity, "worktree", "add", "-q", npath, "-b", "worktree-agent-" + aid)
        ws.record_start(self.sid, aid, npath, "zach")
        self.assertEqual(ws.barrier({"session_id": self.sid, "agent_id": aid})[0], "REGISTERED")
        ws.bind_agent(self.sid, "tu-s", aid, self.entity)
        r = self.rec("zach-opus-s")
        self.assertEqual(r["agent_id"], aid)
        self.assertEqual(len(r["workspaces"]), 1)


class Point07_LandedOrDiscarded(Base):
    """7. Finished work ends in exactly one of two ways — landed or discarded."""

    def test_point_07_discard_deletes_with_the_reason_recorded(self):
        aid, npath = self.spawn("zach-opus-d")
        self.commit(npath)
        self.finish(aid)
        with self.assertRaises(ws.SpecError):
            ws.discard("zach-opus-d", "reviewer rejected it", me=self.sid)   # must say whose order
        ws.discard("zach-opus-d", "reviewer rejected it", not_ceo_ordered="Rich's own cleanup task", me=self.sid)
        self.assertFalse(os.path.exists(npath))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))
        d = self.rec("zach-opus-d")["disposition"]
        self.assertEqual((d["kind"], d["reason"]), ("discarded", "reviewer rejected it"))
        self.assertTrue(d["tips"])
        self.assertEqual(self.names(), [])

    def test_point_07_ceo_ordered_work_needs_his_word(self):
        aid, npath = self.spawn("zach-opus-o", extra="ceo-ordered: 'Implement spec.'\n")
        self.commit(npath)
        self.finish(aid)
        with self.assertRaises(ws.SpecError):
            ws.discard("zach-opus-o", "half done and superseded", not_ceo_ordered="it was not his order at all", me=self.sid)
        ws.discard("zach-opus-o", "half done and superseded", ceo_word="yes, drop it", me=self.sid)
        self.assertFalse(os.path.exists(npath))

    def test_point_07_an_agent_that_produced_nothing_counts_as_landed(self):
        cc = self.make_cc("zach-opus-n")
        aid, npath = self.spawn("zach-opus-n", cc=cc)
        self.finish(aid)
        self.assertEqual(self.names(), [])
        self.assertEqual(self.rec("zach-opus-n")["disposition"]["kind"], "landed")
        self.assertFalse(os.path.exists(cc) or os.path.exists(npath))

    def test_point_07_an_agent_with_no_workspaces_at_all_is_landed_not_pending(self):
        """The precondition registering read-only agents depends on: land()
        returns landed for an EMPTY workspace list rather than raising. If it
        raised, every Explore spawn would become a pending item nothing could
        end, and point 5 would block the CEO's turn ends forever."""
        aid = self.spawn_readonly("anoworkspaces01")
        rec = ws.load_agent(ws.key_for_id(aid))
        self.assertEqual(rec["workspaces"], [])
        ws.record_end(self.sid, aid, "SubagentStop")
        self.assertEqual(ws.land(rec["key"], self.sid), {"landed": True})
        self.assertEqual(self.names(), [])
        self.assertTrue(ws.gate_stop({"session_id": self.sid}, self.entity)[0])

    def test_point_07_unfinished_work_is_continued_by_a_new_agent(self):
        cc = self.make_cc("zach-opus-old")
        aid, npath = self.spawn("zach-opus-old", cc=cc)
        self.commit(cc)
        self.finish(aid)
        cc2 = self.make_cc("zach-opus-new", base="cc/zach-opus-old")
        aid2, npath2 = self.spawn("zach-opus-new", cc=cc2, extra="continues: zach-opus-old\n")
        # the old workspaces are deleted when the new agent starts; its branch stays
        self.assertFalse(os.path.exists(cc) or os.path.exists(npath))
        self.assertIn("cc/zach-opus-old", branches(self.other))
        self.assertEqual(self.rec("zach-opus-old")["disposition"]["kind"], "continued")
        self.commit(cc2, "more.txt")
        self.finish(aid2)
        self.merge(self.other, "cc/zach-opus-new")
        self.assertEqual(self.names(), [])
        self.assertNotIn("cc/zach-opus-old", branches(self.other))
        self.assertNotIn("cc/zach-opus-new", branches(self.other))
        self.assertEqual(self.rec("zach-opus-old")["disposition"]["kind"], "landed")


class Point08_NothingUncommitted(Base):
    """8. Nothing uncommitted is ever landed."""

    def test_point_08_nothing_uncommitted_is_ever_landed(self):
        aid, npath = self.spawn("zach-opus-u")
        self.commit(npath)
        with open(os.path.join(npath, "left.txt"), "w") as f:
            f.write("uncommitted\n")
        self.finish(aid)
        self.merge(self.entity, "worktree-agent-" + aid)
        self.assertEqual(self.names(), ["zach-opus-u"])      # not landed automatically
        with self.assertRaises(ws.SpecError) as cm:
            ws.land("zach-opus-u", self.sid)
        self.assertIn("uncommitted", str(cm.exception))
        self.assertTrue(os.path.exists(os.path.join(npath, "left.txt")))
        # Rich commits what it left to its branch, then it lands
        run("git", "-C", npath, "add", "left.txt")
        run("git", "-C", npath, "commit", "-q", "-m", "left")
        self.merge(self.entity, "worktree-agent-" + aid)
        self.assertEqual(self.names(), [])

    def test_point_08_ignored_files_it_needs(self):
        aid, npath = self.spawn("zach-opus-i")
        os.makedirs(os.path.join(npath, "build"))
        with open(os.path.join(npath, "build", "report.html"), "w") as f:
            f.write("evidence\n")
        self.finish(aid)
        with self.assertRaises(ws.SpecError) as cm:
            ws.land("zach-opus-i", self.sid)
        self.assertIn("ignored", str(cm.exception))
        ws.land("zach-opus-i", self.sid, ignored_ok="build output, regenerated by the next run")
        self.assertFalse(os.path.exists(npath))


class Point08b_BorrowedBranch(Base):
    """8. "Deletion therefore never loses anything that was meant to land" --
    in the destructive direction."""

    def test_point_08_a_pre_existing_branch_the_agent_only_checked_out_survives(self):
        """A branch that was already there, carrying somebody else's unlanded
        commit, which the agent merely CHECKS OUT in its own workspace. Under
        attribution by possession it became the agent's: its land was refused
        because that branch is not in main, and its discard deleted the branch
        with `git branch -D`. A ref that already existed is never the agent's,
        however long the agent holds it -- it is not in the record as created by
        anyone, and creation is the only thing that attributes."""
        keep = os.path.join(self.env.root, "human-wt")
        run("git", "-C", self.entity, "worktree", "add", "-q", keep, "-b", "human/keep")
        self.commit(keep, "human.txt")                       # not in main, and not the agent's
        tip = run("git", "-C", self.entity, "rev-parse", "human/keep").stdout.strip()
        run("git", "-C", self.entity, "worktree", "remove", "--force", keep)
        aid, npath = self.spawn("zach-opus-bb")
        self.pre(aid)
        run("git", "-C", npath, "checkout", "-q", "human/keep")      # borrowed, not created
        self.post(aid)
        self.tool_call(aid)                                          # still on it at its next call
        self.assertEqual(self.created("zach-opus-bb"), [])
        self.finish(aid)                                             # ...and at its end of run
        self.assertEqual(self.created("zach-opus-bb"), [])
        ws.discard("zach-opus-bb", "the reviewer rejected the approach",
                   not_ceo_ordered="an internal experiment", me=self.sid)
        self.assertIn("human/keep", branches(self.entity))
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "human/keep").stdout.strip(), tip)
        self.assertFalse(os.path.exists(npath))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))


class Point09_NeverWritesAgain(Base):
    """9. A finished agent never writes again."""

    def test_point_09_a_finished_agent_is_refused_every_tool(self):
        aid, npath = self.spawn("zach-opus-l")
        self.assertEqual(ws.barrier({"session_id": self.sid, "agent_id": aid, "tool_name": "Edit"})[0],
                         "REGISTERED")
        self.commit(npath)
        self.finish(aid)
        for tool in ("Read", "Bash", "Edit"):
            self.assertEqual(ws.barrier({"session_id": self.sid, "agent_id": aid, "tool_name": tool})[0],
                             "FINISHED")
        self.merge(self.entity, "worktree-agent-" + aid)
        self.assertEqual(self.names(), [])
        # restarted after its workspace is gone: still refused
        self.assertEqual(ws.barrier({"session_id": self.sid, "agent_id": aid, "tool_name": "Write"})[0],
                         "FINISHED")

    def test_point_09_a_restarted_read_only_agent_is_refused_every_tool(self):
        """A read-only type needs no workspace, so the spawn guard exempted it
        from isolation — and, by the same early return, from registration. The
        lock-out finds an agent through its registration, so it never fired for
        one. Explore's allowlist is every tool except Edit/Write/NotebookEdit:
        it carries Bash, so a restarted finished Explore could write."""
        aid = self.spawn_readonly("aexplorero0001")
        self.assertEqual(ws.barrier({"session_id": self.sid, "agent_id": aid,
                                     "tool_name": "Bash"})[0], "REGISTERED")
        ws.record_end(self.sid, aid, "SubagentStop")
        for tool in ("Read", "Bash", "Grep"):
            self.assertEqual(ws.barrier({"session_id": self.sid, "agent_id": aid,
                                         "tool_name": tool})[0], "FINISHED")
        # and it blocks nothing: it produced nothing, so it is already landed
        self.assertEqual(self.names(), [])
        self.assertTrue(ws.gate_stop({"session_id": self.sid}, self.entity)[0])
        self.assertEqual(ws.barrier({"session_id": self.sid, "agent_id": aid,
                                     "tool_name": "Bash"})[0], "FINISHED")

    def test_point_09_a_paused_agent_is_not_locked_out(self):
        aid, npath = self.spawn("zach-opus-pz")
        ws.pause("zach-opus-pz", "the quota reset", self.sid)
        self.finish(aid)
        self.assertEqual(ws.barrier({"session_id": self.sid, "agent_id": aid})[0], "REGISTERED")

    def test_point_09_every_process_it_started_is_stopped_before_deletion(self):
        aid, npath = self.spawn("zach-opus-pr")
        pr = subprocess.Popen(["sleep", "300"], cwd=npath)
        self.env.procs.append(pr)
        time.sleep(0.2)
        self.finish(aid)
        self.assertEqual(self.names(), [])
        pr.wait(timeout=10)
        self.assertIsNotNone(pr.returncode)
        self.assertFalse(os.path.exists(npath))
        ev = open(os.path.join(ws.state_dir(), "events.jsonl")).read()
        self.assertIn('"event": "processes-stopped"', ev)


class LandingShutdown(Base):
    def shutdown_writer(self, path, commit=False):
        code = """import signal, pathlib, subprocess, sys, time
commit = sys.argv[1] == 'commit'
def stopped(*args):
    pathlib.Path('shutdown-result.txt').write_text('result flushed on shutdown\\n')
    if commit:
        subprocess.run(['git', 'add', 'shutdown-result.txt'], check=True)
        subprocess.run(['git', 'commit', '-qm', 'shutdown result'], check=True)
    print('FLUSHED', flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM, stopped)
print('READY', flush=True)
while True: time.sleep(.1)
"""
        pr = subprocess.Popen([sys.executable, '-c', code, 'commit' if commit else 'write'],
                              cwd=path, stdout=subprocess.PIPE, text=True)
        self.env.procs.append(pr)
        self.assertEqual(pr.stdout.readline().strip(), 'READY')
        # Reap immediately so the OS liveness check does not observe a zombie.
        threading.Thread(target=pr.wait, daemon=True).start()
        return pr

    def check_shutdown(self, commit):
        name = 'zach-opus-flush'
        cc = self.make_cc(name)
        aid, native = self.spawn(name, cc)
        pr = self.shutdown_writer(cc, commit)
        self.finish(aid)
        with self.assertRaises(ws.SpecError):
            ws.land(name, self.sid)
        self.assertEqual(pr.stdout.readline().strip(), 'FLUSHED')
        self.assertTrue(os.path.exists(os.path.join(cc, 'shutdown-result.txt')))
        self.assertTrue(os.path.isdir(native))
        self.assertFalse(self.rec(name).get('disposition'))
        if not commit:
            self.commit(cc, 'shutdown-result.txt', 'result flushed on shutdown\n')
        self.merge(self.other, 'cc/' + name)
        ws.land(name, self.sid)
        self.assertFalse(os.path.exists(cc))
        self.assertFalse(os.path.exists(native))

    def test_land_preserves_a_file_flushed_during_shutdown(self):
        self.check_shutdown(False)

    def test_land_rechecks_commits_made_during_shutdown(self):
        self.check_shutdown(True)

    def check_retry(self, commit):
        name = 'zach-opus-retry'
        aid, path = self.spawn(name)
        self.finish(aid)
        with patch.object(ws, 'remove_workspace', return_value=(False, 'simulated disk refusal')):
            ws.land(name, self.sid)
        self.assertTrue(self.rec(name)['deletion'])
        if commit:
            self.commit(path, 'later.txt', 'new work after the first land check\n')
        else:
            with open(os.path.join(path, 'later.txt'), 'w') as f:
                f.write('new work after the first land check\n')
        ws.retry_due()
        self.assertTrue(os.path.isfile(os.path.join(path, 'later.txt')))
        self.assertIn('worktree-agent-' + aid, branches(self.entity))
        self.assertFalse(self.rec(name).get('disposition'))
        self.assertIn(name, self.names())

    def test_retry_preserves_new_uncommitted_work(self):
        self.check_retry(False)

    def test_retry_preserves_new_unmerged_commits(self):
        self.check_retry(True)


class Point10_AllTogether(Base):
    """10. All of an agent's workspaces go together."""

    def test_point_10_a_cross_repository_agent_loses_both_workspaces_as_one(self):
        cc = self.make_cc("zach-opus-x")
        aid, npath = self.spawn("zach-opus-x", cc=cc)
        self.commit(cc)
        self.finish(aid)
        self.merge(self.other, "cc/zach-opus-x")
        self.assertEqual(self.names(), [])
        self.assertFalse(os.path.exists(cc))
        self.assertFalse(os.path.exists(npath))
        self.assertNotIn("cc/zach-opus-x", branches(self.other))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))
        self.assertTrue(os.path.exists(ws.done_path(ws.named_key(self.sid, "zach-opus-x"))))

    def test_point_10_branches_created_in_a_workspace_go_with_it(self):
        """"Any branch an agent created" (point 3) -- and `git branch spare`
        CREATES one. It checks nothing out, so possession could not see it and it
        was left behind, against point 10's "none is left behind". Creation is
        recorded instead: the ref is absent when the agent's tool call starts,
        present when it ends, and carries the agent's own unlanded work."""
        aid, npath = self.spawn("zach-opus-b")
        self.tool_call(aid)
        self.pre(aid)
        run("git", "-C", npath, "checkout", "-q", "-b", "side-branch")
        self.commit(npath, "side.txt")
        run("git", "-C", npath, "branch", "plain-branch")    # checked out NOWHERE, still created
        self.post(aid)
        self.assertEqual(self.created("zach-opus-b"), ["plain-branch", "side-branch"])
        self.finish(aid)
        ws.discard("zach-opus-b", "not wanted any more", not_ceo_ordered="a probe of branch attribution", me=self.sid)
        self.assertNotIn("side-branch", branches(self.entity))
        self.assertNotIn("plain-branch", branches(self.entity))
        self.assertFalse(os.path.exists(npath))

    def test_point_03_a_ref_created_after_the_last_post_is_still_the_agents(self):
        """Point 3 ("any branch an agent created") with point 9 ("every process
        it started is stopped before its workspaces are deleted"): a
        backgrounded process outlives its tool call, so a ref it creates
        appears AFTER that call's PostToolUse consumed the window. The end-of-run
        signal compares once more against the LAST snapshot the agent took, so
        the ref is the agent's and goes with its work (round 8, item 8; the one
        red probe of round 7, esc-20260912T225456Z-d34bf4e6)."""
        aid, npath = self.spawn("zach-opus-late")
        self.commit(npath, "late.txt")
        self.tool_call(aid, "tu-late-1")                      # a whole call: its window is consumed
        self.assertEqual(self.created("zach-opus-late"), [])
        run("git", "-C", npath, "branch", "late/side")        # created after the last PostToolUse
        self.finish(aid)                                      # the end signal is the last observation
        self.assertEqual(self.created("zach-opus-late"), ["late/side"])
        with self.assertRaises(ws.SpecError) as e:            # it holds the land while unmerged
            ws.land("zach-opus-late", self.sid)
        self.assertIn("late/side", str(e.exception))
        self.merge(self.entity, "worktree-agent-" + aid)
        ws.land("zach-opus-late", self.sid)
        self.assertNotIn("late/side", branches(self.entity))
        self.assertFalse(os.path.exists(npath))

    def test_point_03_a_backgrounded_calls_ref_after_its_post_is_still_the_agents(self):
        """Point 3 with point 9. A Bash call the platform stamped
        `run_in_background` has, by the platform's own word, a process still
        running after its PostToolUse. Its window is kept open and judged —
        against its OWN before-set — at the agent's next observation, so the
        ref that process creates after the Post, which the next call's snapshot
        already holds, is still the agent's (round 8, item 8: the RED probe's
        two cases). The same ref cut by Rich between two ordinary CLOSED calls
        stays Rich's (test_point_08_a_branch_that_existed_before_the_call_is_
        never_created_in_it): git cannot tell the two apart, and the stamped
        field is what separates them."""
        aid, npath = self.spawn("zach-opus-bg")
        self.commit(npath, "bg.txt")
        self.pre(aid, "tu-bg")
        ws.observe({"session_id": self.sid, "agent_id": aid, "tool_name": "Bash",
                    "hook_event_name": "PostToolUse", "tool_use_id": "tu-bg",
                    "tool_input": {"command": "sleep 3 && git branch bg/side", "run_in_background": True}})
        run("git", "-C", npath, "branch", "bg/side")          # the process, after its call's Post
        self.tool_call(aid, "tu-next")                        # the next call: snapshot holds it; its Post judges the background window
        self.assertEqual(self.created("zach-opus-bg"), ["bg/side"])
        self.finish(aid)
        with self.assertRaises(ws.SpecError) as e:
            ws.land("zach-opus-bg", self.sid)
        self.assertIn("bg/side", str(e.exception))
        self.merge(self.entity, "worktree-agent-" + aid)
        ws.land("zach-opus-bg", self.sid)
        self.assertNotIn("bg/side", branches(self.entity))

    def test_point_10_a_side_branch_switched_away_from_blocks_the_land(self):
        """Work committed on a branch the agent then switched away from. Nothing
        attributed it, so `land()` reported SUCCESS, `pending()` listed nothing,
        and the agent's commit was in no integration branch: point 5's "everything
        it produced is landed", and point 8's "deletion therefore never loses
        anything that was meant to land", both broken quietly.

        All of it in ONE tool call, which is the case a window between two calls
        cannot see: by the time anything looks, the agent is back on its own
        branch and that branch is empty. Its workspace's own HEAD reflog still
        carries the commit it made, which is what makes the side branch its own."""
        aid, npath = self.spawn("zach-opus-sb")
        self.pre(aid)
        run("git", "-C", npath, "checkout", "-q", "-b", "sidework")
        self.commit(npath, "side.txt")
        run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
        self.post(aid)
        self.assertEqual(self.created("zach-opus-sb"), ["sidework"])
        self.commit(npath, "own.txt")
        self.finish(aid)
        self.merge(self.entity, "worktree-agent-" + aid)     # its own branch is in...
        with self.assertRaises(ws.SpecError) as e:
            ws.land("zach-opus-sb", self.sid)                # ...the side branch is not
        self.assertIn("sidework", str(e.exception))
        self.assertEqual(self.names(), ["zach-opus-sb"])     # so it stays pending (point 5)
        self.assertTrue(os.path.exists(npath))
        self.merge(self.entity, "sidework")                  # merged: nothing is lost
        self.assertEqual(self.names(), [])                   # and it lands on its own (point 4)
        self.assertNotIn("sidework", branches(self.entity))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))
        self.assertFalse(os.path.exists(npath))

    def test_point_10_a_branch_rich_cut_from_its_branch_is_not_the_agents(self):
        """"Deletion therefore never loses anything that was meant to land"
        (point 8). git writes `branch: Created from ...` whoever ran it, so a
        copy Rich cuts to rescue the work used to be deleted with the agent —
        or, carrying a commit of its own, used to hold its land hostage."""
        aid, npath = self.spawn("zach-opus-r")
        self.tool_call(aid)
        self.commit(npath)
        self.tool_call(aid)
        self.finish(aid)
        # the platform restarts finished agents (point 9), so the pair can open
        # AFTER the run has ended -- and both halves refuse a finished agent,
        # which is what keeps Rich's rescue his.
        self.assertEqual(self.pre(aid)[0], "FINISHED")
        # Rich rescues the work: a copy cut inside the agent's own workspace,
        # with a commit of his own on top, after the agent's run has ended.
        run("git", "-C", npath, "checkout", "-q", "-b", "rescue-rich")
        self.commit(npath, "rescued.txt")
        self.post(aid)
        self.assertEqual(self.created("zach-opus-r"), [])
        run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
        self.merge(self.entity, "worktree-agent-" + aid)
        ws.land("zach-opus-r", self.sid)                     # not held hostage by rescue-rich
        self.assertIn("rescue-rich", branches(self.entity))  # and not deleted with the agent
        self.assertFalse(os.path.exists(npath))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))


class Point11_Finished(Base):
    """11. "Finished" means the agent's run has ended and Rich did not pause it."""

    def test_point_11_finished_means_run_ended_and_not_paused(self):
        aid, _n = self.spawn("zach-opus-f")
        r = self.rec("zach-opus-f")
        self.assertEqual(ws.finished_state(r)[:2], (False, False))
        self.finish(aid)
        self.assertEqual(ws.finished_state(self.rec("zach-opus-f"))[:2], (True, False))

    def test_point_11_a_recorded_pause_is_not_finished_and_resumes(self):
        aid, _n = self.spawn("zach-opus-q")
        ws.lifecycle({"hook_event_name": "PostToolUse", "tool_name": "SendMessage", "session_id": self.sid,
                      "tool_input": {"to": "zach-opus-q", "message": "commit and hold\npause-until: the CEO's answer"}},
                     self.entity)
        self.finish(aid)
        self.assertEqual(ws.finished_state(self.rec("zach-opus-q"))[:2], (False, True))
        self.assertEqual(self.names(), [])
        ws.lifecycle({"hook_event_name": "PostToolUse", "tool_name": "SendMessage", "session_id": self.sid,
                      "tool_input": {"to": "zach-opus-q", "message": "go on"}}, self.entity)
        self.assertEqual(ws.finished_state(self.rec("zach-opus-q"))[:2], (False, False))

    def test_point_11_a_pause_with_nothing_named_is_pending(self):
        aid, _n = self.spawn("zach-opus-e")
        ws.pause("zach-opus-e", "", self.sid)
        self.finish(aid)
        self.assertEqual(self.names(), ["zach-opus-e"])

    def test_point_11_handed_in_then_ended_is_finished_even_if_paused(self):
        aid, _n = self.spawn("zach-opus-h")
        ws.pause("zach-opus-h", "the quota reset", self.sid)
        ws.lifecycle({"hook_event_name": "TaskCompleted", "session_id": self.sid, "teammate_name": "zach-opus-h"},
                     self.entity)
        self.finish(aid)
        self.assertTrue(ws.finished_state(self.rec("zach-opus-h"))[0])

    def test_point_11_a_stopped_pause_is_finished(self):
        aid, _n = self.spawn("zach-opus-st")
        ws.pause("zach-opus-st", "the CEO's answer", self.sid)
        self.finish(aid)
        ws.stop("zach-opus-st", "no longer wanted", self.sid)
        self.assertTrue(ws.finished_state(self.rec("zach-opus-st"))[0])
        # and a TaskStop result is the platform's own signal
        aid2, _n2 = self.spawn("zach-opus-ts", extra="lands-pending: zach-opus-st\n")
        ws.lifecycle({"hook_event_name": "PostToolUse", "tool_name": "TaskStop", "session_id": self.sid,
                      "tool_response": json.dumps({"task_id": aid2, "message": "stopped"})}, self.entity)
        self.assertTrue(ws.finished_state(self.rec("zach-opus-ts"))[0])


class Point12_Sessions(Base):
    """12. An agent cannot outlive its session."""

    def test_point_12_session_end_recorded_finishes_its_agents(self):
        self.spawn("zach-opus-se")
        ws.lifecycle({"hook_event_name": "SessionEnd", "session_id": self.sid, "reason": "exit"}, self.entity)
        self.assertTrue(ws.finished_state(self.rec("zach-opus-se"))[0])

    def test_point_12_process_gone_finishes_its_agents(self):
        aid, npath = self.spawn("zach-opus-cr")
        self.commit(npath)
        self.sess.kill()
        self.sess.wait()
        fin, _p, why = ws.finished_state(self.rec("zach-opus-cr"))
        self.assertTrue(fin)
        self.assertIn("no longer exists", why)
        s2 = self.env.session("sess-next-3333", self.entity)
        self.assertEqual(sorted(i["name"] for i in ws.pending("sess-next-3333", self.entity)), ["zach-opus-cr"])

    def test_point_12_a_reused_process_number_is_not_the_session(self):
        self.spawn("zach-opus-ru")
        path = ws.session_path(self.sid)
        rec = json.load(open(path))
        rec["pid_start"] = "Thu Jan  1 00:00:00 1970"
        ws.write_json(path, rec)
        fin, _p, why = ws.finished_state(self.rec("zach-opus-ru"))
        self.assertTrue(fin)
        self.assertIn("no longer session", why)

    def test_point_12_two_sessions_each_handle_their_own(self):
        aid, npath = self.spawn("zach-opus-a1")
        self.commit(npath)
        self.finish(aid)
        s2 = self.env.session("sess-other-4444", self.entity)
        self.assertEqual(ws.pending("sess-other-4444", self.entity), [])
        self.env.use(self.sess)
        self.assertEqual(sorted(i["name"] for i in ws.pending(self.sid, self.entity)), ["zach-opus-a1"])


class Point13_Retry(Base):
    """13. A failed deletion is retried automatically until it succeeds."""

    def test_point_13_a_failed_deletion_is_retried_until_it_succeeds(self):
        aid, npath = self.spawn("zach-opus-rt")
        self.commit(npath)
        self.finish(aid)
        self.merge(self.entity, "worktree-agent-" + aid)
        parent = os.path.dirname(npath)
        os.chmod(parent, 0o555)                              # a disk that refuses the delete
        try:
            self.assertEqual(self.names(), [])               # landed: it does not block Rich
            r = self.rec("zach-opus-rt")
            self.assertEqual(r["disposition"]["kind"], "landed")
            self.assertEqual(r["deletion"]["attempts"], 1)
            self.assertTrue(os.path.exists(npath))
            for _ in range(ws.RETRY_TELL_CEO_AFTER):
                ws.retry_due()
            self.assertTrue(ws.keeps_failing())               # only now does the CEO hear of it
            ok, msg = ws.gate_stop({"session_id": self.sid}, self.entity)
            self.assertIn("TELL THE CEO", msg)
        finally:
            os.chmod(parent, 0o755)
        ws.retry_due()
        self.assertFalse(os.path.exists(npath))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))
        self.assertIsNone(ws.load_agent(ws.named_key(self.sid, "zach-opus-rt"))["deletion"])


class Point14_IntegrationBranch(Base):
    """14. Landed doesn't always mean landed on main."""

    def dev_branch(self, repo, name="dev/work", why="the workspace-spec round"):
        """A body of work whose dev branch is RECORDED before its first agent,
        exactly as the page requires: the record happens first, and nothing
        afterwards infers or re-derives it."""
        run("git", "-C", repo, "branch", name)
        return ws.record_integration(repo, name, why, self.sid)

    def ff(self, repo, onto, branch):
        """Merge `branch` onto `onto` without checking it out: a fast-forward,
        which is what a merge of an agent's branch onto its dev branch is when
        the dev branch has not moved. The main checkout stays on main throughout,
        which is the whole point -- main never learns of this work."""
        tip = run("git", "-C", repo, "rev-parse", branch).stdout.strip()
        run("git", "-C", repo, "branch", "-f", onto, tip)

    def test_point_14_work_merged_onto_its_dev_branch_counts_as_landed(self):
        """"Landing means merged into the branch this work integrates on ... When
        the work cannot reach main yet ... it is that work's dev branch. Rich
        merges each finished agent's work onto it and deletes that agent's
        workspaces and branches under point 4, exactly as in any other land."

        Before this, land() resolved the target with `git rev-parse HEAD` in the
        main checkout, so work merged onto a dev branch was reported NOT LANDED
        for as long as the dev branch stayed out of main -- and its workspaces
        and branches sat there, against point 4."""
        self.dev_branch(self.entity)
        self.dev_branch(self.other, "dev/other-work")
        cc = self.make_cc("zach-opus-i1")
        aid, npath = self.spawn("zach-opus-i1", cc=cc)
        self.commit(npath, "native.txt")
        self.commit(cc, "cc.txt")
        self.finish(aid)
        self.ff(self.entity, "dev/work", "worktree-agent-" + aid)
        self.ff(self.other, "dev/other-work", "cc/zach-opus-i1")
        # main has none of it, in either repository, and that is not a reason to
        # leave anything behind
        main_log = run("git", "-C", self.entity, "log", "--format=%s", "main").stdout
        self.assertNotIn("work native.txt", main_log)
        self.assertEqual(self.names(), [])                   # landed automatically (point 4)
        self.assertTrue(os.path.exists(ws.done_path(ws.named_key(self.sid, "zach-opus-i1"))))
        self.assertFalse(os.path.exists(npath))
        self.assertFalse(os.path.exists(cc))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))
        self.assertNotIn("cc/zach-opus-i1", branches(self.other))

    def test_point_14_work_merged_nowhere_is_not_landed(self):
        """The other half, and the reason the record is a branch rather than a
        waiver: work that reached NEITHER main nor its dev branch is not landed,
        it is pending (point 5), and its workspace and branch stay until Rich
        merges or discards it (point 7)."""
        self.dev_branch(self.entity)
        aid, npath = self.spawn("zach-opus-i2")
        self.commit(npath, "unmerged.txt")
        self.finish(aid)
        self.assertEqual(self.names(), ["zach-opus-i2"])     # not landed by itself
        with self.assertRaises(ws.SpecError) as e:
            ws.land("zach-opus-i2", self.sid)
        self.assertIn("dev/work", str(e.exception))          # it names the recorded target
        self.assertTrue(os.path.exists(npath))
        self.assertIn("worktree-agent-" + aid, branches(self.entity))
        # and merging it onto the recorded branch is what lands it
        self.ff(self.entity, "dev/work", "worktree-agent-" + aid)
        ws.land("zach-opus-i2", self.sid)
        self.assertFalse(os.path.exists(npath))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))

    def test_point_14_two_of_one_agents_own_calls_open_at_once_keep_both_windows(self):
        """Points 3 and 10 through point 14's target: "any branch an agent
        created" ... "None is left behind." An agent's own calls OVERLAP. With
        one snapshot slot per agent the second window was lost, and a side branch
        created in it took real commits out of every integration branch while
        land() still reported LANDED. The window is keyed by the CALL, so
        Pre(A) Pre(B) Post(A) Post(B) attributes both."""
        aid, npath = self.spawn("zach-opus-i5")
        self.tool_call(aid, call="tu-warm")
        self.commit(npath, "own.txt")
        self.pre(aid, call="tu-A")                       # call A opens
        self.pre(aid, call="tu-B")                       # call B opens alongside it
        run("git", "-C", npath, "branch", "spare")       # created inside call A
        self.post(aid, call="tu-A")                      # A closes: its own window
        run("git", "-C", npath, "checkout", "-q", "-b", "tmpwork")
        self.commit(npath, "side.txt")                   # real work, inside call B
        run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
        self.post(aid, call="tu-B")                      # B closes: its own window
        self.assertEqual(self.created("zach-opus-i5"), ["spare", "tmpwork"])
        # A call whose PostToolUse never arrives (the agent's run ends inside it)
        # still has its window: the end-of-run signal is the LAST observation and
        # it consumes every window still open, not one of them.
        self.pre(aid, call="tu-C")
        run("git", "-C", npath, "branch", "never-closed")
        self.finish(aid)
        self.assertEqual(self.created("zach-opus-i5"), ["never-closed", "spare", "tmpwork"])
        self.merge(self.entity, "worktree-agent-" + aid)
        # tmpwork carries a commit that reached no integration branch, so the
        # land is REFUSED and the work is pending rather than silently lost.
        with self.assertRaises(ws.SpecError) as e:
            ws.land("zach-opus-i5", self.sid)
        self.assertIn("tmpwork", str(e.exception))
        self.assertEqual(self.names(), ["zach-opus-i5"])
        self.assertIn("tmpwork", branches(self.entity))
        self.merge(self.entity, "tmpwork")
        ws.land("zach-opus-i5", self.sid)
        self.assertNotIn("tmpwork", branches(self.entity))   # point 10: none left behind
        self.assertNotIn("spare", branches(self.entity))
        self.assertNotIn("never-closed", branches(self.entity))

    def test_point_03_a_refused_call_never_widens_the_window_to_the_whole_run(self):
        """Points 3 and 8. A PreToolUse another guard REFUSES leaves a window no
        PostToolUse will ever consume. The end-of-run pass consumed every open
        window and INTERSECTED them, so one leak at minute one turned the last
        comparison of the run into "everything that appeared while this agent
        existed" — and a branch RICH cut between two of the agent's calls came
        back as the agent's and was destroyed by its discard, against point 8's
        "Deletion therefore never loses anything that was meant to land." """
        ws.record_integration(self.entity, "main", "this body of work", self.sid)
        aid, npath = self.spawn("zach-opus-w1")
        self.pre(aid, call="tu-refused")          # refused: no Post will ever come
        self.tool_call(aid, call="tu-1")
        self.commit(npath, "own.txt")
        self.tool_call(aid, call="tu-2")
        tip = run("git", "-C", npath, "rev-parse", "HEAD").stdout.strip()
        # BETWEEN tool calls, at the agent's own tip: Rich's, not the agent's.
        run("git", "-C", self.entity, "branch", "rich/rescue", tip)
        self.tool_call(aid, call="tu-3")
        self.finish(aid)                          # consumes every window still open
        self.assertEqual(self.created("zach-opus-w1"), [])
        ws.discard("zach-opus-w1", "the reviewer rejected the approach",
                   not_ceo_ordered="a test of attribution", me=self.sid)
        self.assertIn("rich/rescue", branches(self.entity))

    def test_point_08_a_branch_that_existed_before_the_call_is_never_created_in_it(self):
        """Point 8, in the destructive direction: "Deletion therefore never
        loses anything that was meant to land."

        This is the case where the SNAPSHOT is the only thing standing between
        somebody else's branch and `git branch -D`. Rich cuts a bookmark at the
        agent's own unlanded tip BEFORE the call opens, so every other filter
        waves it through: it is not the main checkout's branch, not on any other
        agent's record, not the agent's own workspace branch, not already in the
        integration branch, and it sits exactly on the agent's line of work.
        Only "it was already there when this call started" keeps it out.

        It is written down because an empty before-set was measured killing NO
        shipped test, which made the first half of the pair an unproven claim."""
        aid, npath = self.spawn("zach-opus-w2")
        self.tool_call(aid, call="tu-warm")
        self.commit(npath, "own.txt")
        tip = run("git", "-C", npath, "rev-parse", "HEAD").stdout.strip()
        run("git", "-C", self.entity, "branch", "rich/bookmark", tip)   # BEFORE the call
        self.pre(aid, call="tu-1")
        run("git", "-C", npath, "branch", "spare")                      # inside the call
        self.post(aid, call="tu-1")
        self.assertEqual(self.created("zach-opus-w2"), ["spare"])
        self.finish(aid)
        ws.discard("zach-opus-w2", "the reviewer rejected the approach",
                   not_ceo_ordered="a test of attribution", me=self.sid)
        self.assertIn("rich/bookmark", branches(self.entity))
        self.assertNotIn("spare", branches(self.entity))

    def test_point_03_a_post_that_carries_no_call_id_still_ends_a_call(self):
        """Point 3. The platform does not always put `tool_use_id` on both
        halves. A Pre keyed / Post unkeyed pair used to find nothing at either
        end, so the ref created inside that call was attributed to nobody until
        the end of the run and, once the run had ended, to nobody at all."""
        ws.record_integration(self.entity, "main", "this body of work", self.sid)
        aid, npath = self.spawn("zach-opus-w3")
        self.tool_call(aid, call="tu-warm")
        self.commit(npath, "own.txt")
        self.pre(aid, call="tu-A")                           # Pre KEYED
        run("git", "-C", npath, "branch", "keyed-pre-only")
        self.post(aid)                                       # Post UNKEYED
        self.pre(aid)                                        # Pre UNKEYED
        run("git", "-C", npath, "branch", "unkeyed-pre-only")
        self.post(aid, call="tu-B")                          # Post KEYED
        self.assertEqual(self.created("zach-opus-w3"),
                         ["keyed-pre-only", "unkeyed-pre-only"])

    def test_point_14_attribution_never_waits_for_the_record(self):
        """Points 5, 8 and 10 through point 14. Attribution happens once, at the
        end of a tool call. While no integration branch was recorded it did not
        happen AT ALL: the refs were written to an `attribution-skipped` event
        nothing read, recording the branch afterwards unblocked the land and
        never went back for them, and land() then reported success over a commit
        that had reached no integration branch."""
        # THE NO-TARGET CASE, since round 7: a spawn with no record is refused
        # (point 14), so the way an agent's target goes missing is the recorded
        # branch ceasing to exist after the spawn. Attribution must still happen.
        run("git", "-C", self.entity, "branch", "dev/next")
        ws.record_integration(self.entity, "dev/next", "this body of work", self.sid)
        aid, npath = self.spawn("zach-opus-w4")
        run("git", "-C", self.entity, "branch", "-D", "dev/next")   # the target is gone
        self.assertTrue(ws.integration_target([self.rec("zach-opus-w4")], self.entity)[2])
        self.pre(aid, call="tu-1")
        run("git", "-C", npath, "checkout", "-q", "-b", "sidework")
        self.commit(npath, "side.txt")                       # real work, no target
        run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
        run("git", "-C", npath, "branch", "spare")
        self.post(aid, call="tu-1")
        self.assertEqual(self.created("zach-opus-w4"), ["sidework", "spare"])
        self.commit(npath, "own.txt")
        self.finish(aid)
        # Rich corrects the branch afterwards and merges the agent's own branch.
        ws.record_integration(self.entity, "main", "this body of work", self.sid, correct=True)
        self.merge(self.entity, "worktree-agent-" + aid)
        with self.assertRaises(ws.SpecError) as e:
            ws.land("zach-opus-w4", self.sid)                # the stranded commit is named
        self.assertIn("sidework", str(e.exception))
        self.assertEqual(self.names(), ["zach-opus-w4"])
        self.merge(self.entity, "sidework")
        ws.land("zach-opus-w4", self.sid)
        self.assertNotIn("sidework", branches(self.entity))  # point 10: none left behind
        self.assertNotIn("spare", branches(self.entity))

    def test_point_14_a_tip_the_agent_only_borrowed_is_not_its_work(self):
        """Points 3 and 8. With no record there is no integration branch to
        subtract, so the floor is each workspace's OWN starting commit and the
        only commits that count are the ones it MADE. Without both, the base
        commit counts as the agent's work, every ref descends from it, and a ref
        Rich cuts at a commit the agent merely checked out becomes the agent's
        — and is deleted with it."""
        run("git", "-C", self.entity, "worktree", "add", "-q",
            os.path.join(self.env.root, "human-wt"), "-b", "human/keep")
        self.commit(os.path.join(self.env.root, "human-wt"), "human.txt")
        tip = run("git", "-C", self.entity, "rev-parse", "human/keep").stdout.strip()
        run("git", "-C", self.entity, "worktree", "remove", "--force",
            os.path.join(self.env.root, "human-wt"))
        # the no-target case (see test_point_14_attribution_never_waits_for_the_record)
        run("git", "-C", self.entity, "branch", "dev/next")
        ws.record_integration(self.entity, "dev/next", "this body of work", self.sid)
        aid, npath = self.spawn("zach-opus-w5")
        run("git", "-C", self.entity, "branch", "-D", "dev/next")
        self.pre(aid, call="tu-1")
        run("git", "-C", npath, "checkout", "-q", "human/keep")     # BORROWED, never made
        run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
        self.post(aid, call="tu-1")
        self.pre(aid, call="tu-2")
        run("git", "-C", self.entity, "branch", "rich/backup", tip)  # Rich, at that tip
        self.post(aid, call="tu-2")
        self.assertEqual(self.created("zach-opus-w5"), [])

    def test_point_14_the_integration_branch_is_recorded_never_inferred(self):
        """"The branch a body of work integrates on is RECORDED when that work
        starts, before its first agent is spawned. NOTHING INFERS IT AND NOTHING
        GUESSES IT." So: a land with no record REFUSES and names the command;
        nothing is derived from what the main checkout happens to be on; nothing
        is frozen onto an agent; and the live record is the only answer, which is
        why recording it late REACHES an agent that was spawned before it."""
        self.assertEqual(ws.integration_record(self.entity)["branch"], "main")
        self.assertEqual(ws.integration_record(self.entity)["source"], "recorded")
        # NO RECORD AT ALL: THE SPAWN IS REFUSED, naming the command — "RECORDED
        # when that work starts, BEFORE its first agent is spawned." Round 6's
        # reading ("the land refuses later, and heals") was ruled a guess by
        # both reviewers: an agent bound to nothing was judged at land time
        # against whichever body of work was current, so a second recording in
        # between moved its verdict. Nothing is derived from what the main
        # checkout happens to be on, and a session start infers nothing either.
        os.unlink(os.path.join(ws.state_dir(), "integration.json"))
        ws.record_session_start(self.sid, self.entity)          # infers nothing (the old floor fired here)
        self.assertIsNone(ws.integration_record(self.entity))
        with self.assertRaises(ws.SpecError) as e0:
            self.spawn("zach-opus-i3")
        self.assertIn("workspaces.sh integration", str(e0.exception))
        self.assertIn("point 14", str(e0.exception))
        self.assertIsNone(self.rec("zach-opus-i3"))             # the spawn did not happen (point 3)
        self.assertIsNone(ws.integration_record(self.entity))   # and the refusal recorded nothing
        with self.assertRaises(ws.SpecError) as e1:             # the workspace half is refused too
            self.make_cc("zach-opus-i3")
        self.assertIn("workspaces.sh integration", str(e1.exception))
        self.assertIsNone(self.rec("zach-opus-i3"))
        # RICH RECORDS THE BRANCH, AND THE SAME SPAWN SUCCEEDS — bound, by id, to
        # the body of work that was current AT ITS SPAWN, and to nothing else.
        run("git", "-C", self.entity, "branch", "dev/next")
        first = ws.record_integration(self.entity, "dev/next", "this body of work", self.sid)
        aid, npath = self.spawn("zach-opus-i3")
        self.assertEqual(self.rec("zach-opus-i3")["integration_work"][self.entity], first["id"])
        self.assertNotIn("integration", self.rec("zach-opus-i3"))   # no branch frozen onto it
        self.commit(npath, "i3.txt")
        self.finish(aid)
        # A LATER, UNRELATED RECORDING DOES NOT MOVE IT (the reviewers' S1–S4):
        # a second body of work starts in the same repository, and this agent
        # still lands against dev/next.
        run("git", "-C", self.entity, "branch", "dev/other")
        ws.record_integration(self.entity, "dev/other", "an unrelated body of work", self.sid)
        self.merge(self.entity, "worktree-agent-" + aid)         # onto main: not its branch
        with self.assertRaises(ws.SpecError) as e2:
            ws.land("zach-opus-i3", self.sid)
        self.assertIn("dev/next", str(e2.exception))
        self.ff(self.entity, "dev/next", "worktree-agent-" + aid)
        ws.land("zach-opus-i3", self.sid)
        self.assertFalse(os.path.exists(npath))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))
        # an agent's own workspace branch is never an integration branch
        with self.assertRaises(ws.SpecError):
            ws.record_integration(self.entity, "cc/zach-opus-i3", "wrong kind of branch", self.sid)
        # A CORRECTION REACHES AN AGENT IN FLIGHT. Nothing is frozen onto the
        # agent at its registration: it is bound to the BODY OF WORK by id, and
        # that work's branch is read live, so correcting the branch corrects
        # every agent bound to it. That is what a derived or frozen answer could
        # never do, and it is why the binding is an id and not a branch name.
        ws.record_integration(self.entity, "main", "back to main for a moment", self.sid)
        aid2, npath2 = self.spawn("zach-opus-i4")
        self.commit(npath2, "i4.txt")
        run("git", "-C", self.entity, "branch", "dev/later")
        ws.record_integration(self.entity, "dev/later", "it was the wrong branch",
                              self.sid, correct=True)
        self.finish(aid2)
        self.merge(self.entity, "worktree-agent-" + aid2)     # onto main: the OLD value
        with self.assertRaises(ws.SpecError) as e2:
            ws.land("zach-opus-i4", self.sid)
        self.assertIn("dev/later", str(e2.exception))
        self.assertTrue(os.path.exists(npath2))
        self.ff(self.entity, "dev/later", "worktree-agent-" + aid2)
        ws.land("zach-opus-i4", self.sid)
        self.assertFalse(os.path.exists(npath2))

    def test_point_14_never_refuses_a_path_that_is_not_a_repository(self):
        """A REFUSAL WHOSE REMEDY CANNOT BE RUN IS NOT A FLOOR. Point 14 records
        A BRANCH; a directory that is not a git repository has none, has no land
        to measure, and `record_integration` refuses it outright. So the spawn
        gate must not demand a record there: until it stopped, an entity root
        that was not a repository was refused every spawn forever, and the one
        command its refusal named refused in turn —

            spawn  exit 2  "no branch is recorded ... Record it, then spawn:
                            workspaces.sh integration --repo <dir> --branch ..."
            remedy exit 2  "the repository <dir> could not be resolved from git"

        — which is the shape this file deleted the first-registration floor for:
        "with NO record at all the refusal HEALS". This one could not. Nothing
        about a real repository is relaxed: the sibling assertion below is the
        control, and every other point-14 case still refuses."""
        plain = os.path.join(self.env.root, "not-a-repo")
        os.makedirs(plain)
        self.assertEqual(ws.main_checkout(plain), "")             # git resolves nothing here
        with self.assertRaises(ws.SpecError) as e:                # so the remedy cannot be run
            ws.record_integration(plain, "main", "impossible", self.sid)
        self.assertIn("could not be resolved from git", str(e.exception))
        payload = {"session_id": self.sid, "tool_use_id": "tu-plain", "tool_name": "Agent",
                   "tool_input": {"name": "zach-opus-plain1", "subagent_type": "zach",
                                  "prompt": "do it", "isolation": "worktree"}}
        ws.register_spawn(payload, plain)                         # allowed: nothing to record
        self.assertIsNotNone(self.rec("zach-opus-plain1"))
        self.assertEqual(self.rec("zach-opus-plain1").get("integration_work", {}), {})
        # THE CONTROL: a real repository with its record removed is still refused,
        # and still named, so this is an exemption for non-repositories only.
        os.unlink(os.path.join(ws.state_dir(), "integration.json"))
        with self.assertRaises(ws.SpecError) as e2:
            self.spawn("zach-opus-plain2")
        self.assertIn("workspaces.sh integration", str(e2.exception))
        self.assertIn("point 14", str(e2.exception))

    def test_point_14_a_record_bound_to_nothing_is_refused_never_guessed(self):
        """Point 14: "Nothing infers it and nothing guesses it." The one kind of
        record that is never spawned through the guard — a workspace the
        point-3 sweep found unregistered — can exist while nothing is recorded.
        Its land REFUSES and names the command; it never reads whichever body
        of work happens to be current at land time (round 6's "heals later",
        which both reviewers reproduced moving a land verdict). It binds at the
        first sweep after a body of work exists, by id, once, and then lands."""
        os.unlink(os.path.join(ws.state_dir(), "integration.json"))
        raw = os.path.join(self.env.root, "raw-cc")
        run("git", "-C", self.entity, "worktree", "add", "-q", raw, "-b", "cc/raw-hand")
        self.commit(raw, "raw.txt")
        self.assertEqual(self.names(), ["orphan-raw-cc"])            # found, unregistered
        orphan = [r for r in ws.all_agents() if r.get("name") == "orphan-raw-cc"][0]
        self.assertNotIn("integration_work", orphan)                 # bound to nothing
        with self.assertRaises(ws.SpecError) as e:
            ws.land("orphan-raw-cc", self.sid)
        self.assertIn("bound to no body of work", str(e.exception))
        self.assertIn("workspaces.sh integration", str(e.exception))
        # Rich records main, and merges the branch. WITHOUT A SWEEP the record is
        # still bound to nothing, and the land still refuses: it does not read
        # "current" now that a current one exists — that would be the guess.
        ws.record_integration(self.entity, "main", "this body of work", self.sid)
        self.merge(self.entity, "cc/raw-hand")
        with self.assertRaises(ws.SpecError) as e2:
            ws.land("orphan-raw-cc", self.sid)
        self.assertIn("bound to no body of work", str(e2.exception))
        self.assertTrue(os.path.exists(raw))
        # The next sweep binds it — recorded on it by id — and, being merged,
        # it lands on its own (point 4).
        self.assertEqual(self.names(), [])
        self.assertFalse(os.path.exists(raw))
        self.assertNotIn("cc/raw-hand", branches(self.entity))
        done = ws.load_agent(orphan["key"])
        self.assertEqual(done["disposition"]["kind"], "landed")
        self.assertEqual(done["integration_work"][self.entity], ws.integration_record(self.entity)["id"])

    def test_point_14_a_recorded_branch_moved_in_an_agents_call_is_reported_and_left_alone(self):
        """Round 8, item 2, as amended on 2026-09-14. The recorded branch moved
        by an UNNAMED verb — the checkout doorway, then a commit — during an
        agent's call is REPORTED at the call's PostToolUse and the ref is left
        exactly where it is: the engine never moves a protected ref back, since
        the shape of the result cannot tell an agent's doorway from Rich's own
        land, and the write it used to make moved refs/heads/main in richos
        three times in one night (docs/verification/
        ref-write-forensics-2026-09-14.md). A DELETION is still put back, with a
        create-only write that carries a reflog message. The lead's legitimate
        move (a descendant carrying none of the agent's work) is not even
        reported."""
        run("git", "-C", self.entity, "branch", "dev/rec")
        ws.record_integration(self.entity, "dev/rec", "body of work on a dev branch", self.sid)
        tip = run("git", "-C", self.entity, "rev-parse", "dev/rec").stdout.strip()
        aid, npath = self.spawn("zach-opus-mv")
        self.commit(npath, "mv.txt")
        self.pre(aid, "tu-1")
        run("git", "-C", npath, "checkout", "-q", "dev/rec")                  # the doorway
        run("git", "-C", npath, "commit", "-q", "--allow-empty", "-m", "moved unnamed")
        moved = run("git", "-C", npath, "rev-parse", "HEAD").stdout.strip()
        self.post(aid, call="tu-1")
        run("git", "-C", npath, "checkout", "-q", "worktree-agent-" + aid)
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "dev/rec").stdout.strip(), moved)
        hist = [h for h in self.rec("zach-opus-mv").get("history") or []
                if h.get("fact") == "protected ref moved (reported, not restored)"]
        self.assertEqual([(h["branch"], h["tip"], h["found"]) for h in hist], [("dev/rec", tip, moved)])
        # The deleted case: re-created at the tip the snapshot recorded, and the
        # write says who made it — an anonymous ref write is what cost a day.
        run("git", "-C", self.entity, "branch", "-f", "dev/rec", tip)
        self.pre(aid, "tu-2")
        run("git", "-C", self.entity, "update-ref", "-d", "refs/heads/dev/rec")   # deleted, from the main checkout
        self.post(aid, call="tu-2")
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "dev/rec").stdout.strip(), tip)
        self.assertIn("richos engine: protected ref restored",
                      run("git", "-C", self.entity, "reflog", "show", "dev/rec").stdout)
        self.pre(aid, "tu-3")
        lead = run("git", "-C", self.entity, "commit-tree", tip + "^{tree}", "-p", tip, "-m",
                   "the lead lands a finished agent's work").stdout.strip()
        run("git", "-C", self.entity, "branch", "-f", "dev/rec", lead)              # the lead's move: a descendant, not this agent's work
        self.post(aid, call="tu-3")
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "dev/rec").stdout.strip(), lead)
        # And his land is not even reported: exactly two protected-ref facts on
        # the record, the move and the deletion, in that order.
        self.assertEqual([h["fact"] for h in self.rec("zach-opus-mv").get("history") or []
                          if str(h.get("fact", "")).startswith("protected ref")],
                         ["protected ref moved (reported, not restored)", "protected ref restored"])

    def test_point_14_the_engine_never_moves_the_recorded_branch_when_two_agents_run(self):
        """THE 2026-09-14 INCIDENT, as a test. Events 3, 4 and 5 of
        docs/verification/ref-write-forensics-2026-09-14.md: the engine moved
        refs/heads/main three times, twice within twelve seconds in opposite
        directions, while Rich was landing. Nothing was lost only because the
        second write happened to go forwards.

        The condition, which needs no attacker and no unusual verb — it is the
        NORMAL case of two agents running while the lead lands:

          A opens a call while main is at T0;
          Rich merges A's finished work, main -> T1;
          B opens a call while main is at T1;
          A's Post fires, then B's.

        A's window says T0, B's says T1, so under the old rule A "restored" main
        to T0 (dropping Rich's merge) and B "restored" it to T1 — each write
        manufacturing the condition the next one fired on. Now: two reports, no
        writes, main exactly where Rich left it, and B has nothing to report at
        all because nobody moved anything."""
        a_id, a_path = self.spawn("zach-opus-os1", agent_id="aosc000000000001")
        b_id, b_path = self.spawn("zach-opus-os2", agent_id="bosc000000000002")
        self.commit(a_path, "a.txt")
        self.commit(b_path, "b.txt")
        t0 = run("git", "-C", self.entity, "rev-parse", "main").stdout.strip()
        self.pre(a_id, "tu-a")                                   # A's window: main at T0
        self.merge(self.entity, "worktree-agent-" + a_id)        # Rich lands A's work
        t1 = run("git", "-C", self.entity, "rev-parse", "main").stdout.strip()
        self.assertNotEqual(t0, t1)
        self.pre(b_id, "tu-b")                                   # B's window: main at T1
        self.post(a_id, call="tu-a")
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "main").stdout.strip(), t1)
        self.post(b_id, call="tu-b")
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "main").stdout.strip(), t1)
        # Rich's merge is still reachable, and no ref write went in without a
        # reflog message — the signature of the three real events.
        self.assertEqual(run("git", "-C", self.entity, "merge-base", "--is-ancestor", t1, "main",
                             check=False).returncode, 0)
        reflog = run("git", "-C", self.entity, "reflog", "show", "main").stdout.splitlines()
        self.assertEqual([ln for ln in reflog if ln.rstrip().endswith(":")], [])
        # Reported, not silent: A saw it, B had nothing to see.
        self.assertEqual([h["branch"] for h in self.rec("zach-opus-os1").get("history") or []
                          if h.get("fact") == "protected ref moved (reported, not restored)"], ["main"])
        self.assertEqual([h for h in self.rec("zach-opus-os2").get("history") or []
                          if str(h.get("fact", "")).startswith("protected ref")], [])

    def test_point_14_a_recorded_branch_is_protected_in_its_own_repository_only(self):
        """§4 of the forensics: the protected set was keyed by branch NAME across
        every body of work, so `main` recorded for one repository protected —
        and made restorable — `refs/heads/main` in every other. Three bodies of
        work on the operator's machine, all three integrating on `main`.

        Keyed by (repository, branch), the tips an agent's window records for a
        repository are that repository's own protected refs."""
        # The same branch NAME exists in both repositories; it is the recorded
        # integration branch of one body of work, in one of them.
        run("git", "-C", self.entity, "branch", "dev/shared-name")
        run("git", "-C", self.other, "branch", "dev/shared-name")
        ws.record_integration(self.entity, "dev/shared-name", "the entity's dev branch", self.sid)
        other_refs = ws._local_refs(self.other)
        self.assertIn("dev/shared-name", other_refs)
        self.assertNotIn("dev/shared-name", ws._protected_tips(self.other, other_refs))
        self.assertIn("dev/shared-name", ws._protected_tips(self.entity, ws._local_refs(self.entity)))
        # Each repository keeps its own: both recorded `main`, and both are
        # protected where they were recorded.
        self.assertIn("main", ws._protected_tips(self.other, other_refs))

    def test_point_14_the_leads_land_after_the_agents_last_call_is_not_undone(self):
        """Round 8, item 2 — the bound measured on Sage's runner-round case R8:
        with NO call open, Rich fast-forwards the recorded branch to the agent's
        OWN tip (his land of its work, made after its last call and before its
        end signal). The end-of-run observation compares against the last
        snapshot, which is minutes old; "a descendant carrying the agent's own
        work" is the agent's doorway only INSIDE a window, so outside one it is
        left alone and the land proceeds."""
        aid, npath = self.spawn("zach-opus-ff")
        self.tool_call(aid, "tu-1")
        self.commit(npath, "ff.txt")
        self.tool_call(aid, "tu-2")                            # the last call closes
        self.merge(self.entity, "worktree-agent-" + aid)       # the lead's fast-forward of main to the agent's tip
        tip = run("git", "-C", self.entity, "rev-parse", "main").stdout.strip()
        self.finish(aid)                                       # the end signal: no window open
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "main").stdout.strip(), tip)
        # Nor is it REPORTED. Since 2026-09-14 nothing here writes a ref, so the
        # whole value of the windowed rule is that the check stays silent about
        # the lead's ordinary land: a report that fires on every land is alarm
        # fatigue, and this check only earns attention by being rare.
        self.assertEqual([h for h in self.rec("zach-opus-ff").get("history") or []
                          if str(h.get("fact", "")).startswith("protected ref")], [])
        ws.land("zach-opus-ff", self.sid)
        self.assertFalse(os.path.exists(npath))

    def test_point_02_a_codex_ref_deleted_in_an_agents_call_is_restored_and_a_move_is_reported(self):
        """Round 8, item 3, as amended on 2026-09-14: a codex/ ref DELETED during
        an agent's call is put back — point 2 says a codex/ branch is never
        deleted without the CEO's express word, the deletion is unambiguous, and
        re-creating it at the tip it held loses nothing. A MOVE is reported and
        left alone: the engine stopped moving protected refs after its own
        "restores" moved refs/heads/main three times in richos
        (docs/verification/ref-write-forensics-2026-09-14.md), and a move cannot
        be put back without deciding whose write it was.

        And a registered agent's Write/Edit aimed inside a codex/ workspace is
        refused by the lock-out (the only hook that sees it), while the lead's
        passes."""
        run("git", "-C", self.entity, "branch", "codex/keep")
        cx = os.path.join(self.env.root, "codex-wt")
        run("git", "-C", self.entity, "worktree", "add", "-q", cx, "-b", "codex/live")
        tip = run("git", "-C", self.entity, "rev-parse", "codex/keep").stdout.strip()
        aid, npath = self.spawn("zach-opus-cx")
        self.commit(npath, "cx.txt")
        mine = run("git", "-C", npath, "rev-parse", "HEAD").stdout.strip()
        self.pre(aid, "tu-1")
        run("git", "-C", self.entity, "branch", "-f", "codex/keep", mine)          # a mover the guard did not see
        self.post(aid, call="tu-1")
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "codex/keep").stdout.strip(), mine)
        self.assertEqual([h["branch"] for h in self.rec("zach-opus-cx").get("history") or []
                          if h.get("fact") == "protected ref moved (reported, not restored)"], ["codex/keep"])
        run("git", "-C", self.entity, "branch", "-f", "codex/keep", tip)
        self.pre(aid, "tu-2")
        run("git", "-C", self.entity, "update-ref", "-d", "refs/heads/codex/keep")
        self.post(aid, call="tu-2")
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "codex/keep").stdout.strip(), tip)
        self.assertEqual(ws.barrier({"session_id": self.sid, "agent_id": aid, "tool_name": "Edit",
                                     "tool_input": {"file_path": os.path.join(cx, "README")}})[0], "CODEX")
        self.assertEqual(ws.barrier({"session_id": self.sid, "agent_id": aid, "tool_name": "Write",
                                     "tool_input": {"file_path": os.path.join(cx, "sub", "new.txt")}})[0], "CODEX")
        self.assertEqual(ws.barrier({"session_id": self.sid, "agent_id": aid, "tool_name": "Edit",
                                     "tool_input": {"file_path": os.path.join(npath, "README")}})[0], "REGISTERED")
        self.assertEqual(ws.barrier({"session_id": self.sid, "tool_name": "Edit",
                                     "tool_input": {"file_path": os.path.join(cx, "README")}})[0], "LEAD")

    def test_point_02_the_restore_of_a_deleted_ref_is_create_only_and_never_clobbers(self):
        """The one write this check still makes is CREATE-ONLY: the empty old
        value in `git update-ref -m <msg> --no-deref <ref> <tip> ""` means the
        ref must not exist. So a ref somebody re-created between the deletion and
        the check — at a different tip, and deliberately — is not clobbered, the
        attempt is recorded as a failure rather than forced, and the write can
        never oscillate with another agent's."""
        run("git", "-C", self.entity, "branch", "codex/race")
        tip = run("git", "-C", self.entity, "rev-parse", "codex/race").stdout.strip()
        aid, npath = self.spawn("zach-opus-cr")
        self.commit(npath, "cr.txt")
        other_tip = run("git", "-C", npath, "rev-parse", "HEAD").stdout.strip()
        self.pre(aid, "tu-1")
        run("git", "-C", self.entity, "update-ref", "-d", "refs/heads/codex/race")
        run("git", "-C", self.entity, "branch", "codex/race", other_tip)       # re-created, elsewhere
        self.post(aid, call="tu-1")
        # Seen as a move, not a deletion — and a move is never written.
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "codex/race").stdout.strip(), other_tip)
        self.assertEqual([h["fact"] for h in self.rec("zach-opus-cr").get("history") or []
                          if str(h.get("fact", "")).startswith("protected ref")],
                         ["protected ref moved (reported, not restored)"])
        # And the engine's own write refuses while the ref exists, rather than
        # forcing it — the property, asked of the line that carries it.
        rc, _o, err = ws._recreate_deleted_ref(self.entity, "codex/race", tip, "zach-opus-cr")
        self.assertNotEqual(rc, 0)
        self.assertIn("already exists", err)
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "codex/race").stdout.strip(), other_tip)
        # With the ref gone it succeeds, at the tip it held, and says who wrote it.
        run("git", "-C", self.entity, "update-ref", "-d", "refs/heads/codex/race")
        rc, _o, err = ws._recreate_deleted_ref(self.entity, "codex/race", tip, "zach-opus-cr")
        self.assertEqual(rc, 0, err)
        self.assertEqual(run("git", "-C", self.entity, "rev-parse", "codex/race").stdout.strip(), tip)
        self.assertIn("richos engine: protected ref restored",
                      run("git", "-C", self.entity, "reflog", "show", "codex/race").stdout)

    def test_point_14_a_second_body_of_work_never_moves_the_first_ones_agents(self):
        """Point 14: "the branch THIS WORK integrates on." Point 5 permits a
        second body of work to start in a repository while the first one's
        agents are still running. The record used to have one slot per
        REPOSITORY, so recording the second body's branch moved the first
        body's running agents onto it retroactively: their work was merged onto
        the branch they were spawned for, their land was measured against a
        branch they had never heard of, it refused forever, and their
        workspaces were stranded — against point 14's own "'it cannot go to
        main yet' is never a reason for anything to be left behind"."""
        run("git", "-C", self.entity, "branch", "dev/first")
        first = ws.record_integration(self.entity, "dev/first", "body of work ONE", self.sid)
        aid, npath = self.spawn("zach-opus-b1")
        self.commit(npath, "one.txt")
        # A SECOND body of work starts in the same repository while that agent
        # is still running, and Rich records its branch as point 14 requires.
        run("git", "-C", self.entity, "branch", "dev/second")
        second = ws.record_integration(self.entity, "dev/second", "body of work TWO", self.sid)
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(ws.integration_record(self.entity)["branch"], "dev/second")
        # The first body's agent is still bound to the FIRST body of work.
        self.finish(aid)
        self.ff(self.entity, "dev/first", "worktree-agent-" + aid)
        ws.land("zach-opus-b1", self.sid)
        self.assertFalse(os.path.exists(npath))
        self.assertNotIn("worktree-agent-" + aid, branches(self.entity))
        self.assertEqual(self.names(), [])
        # And an agent of the SECOND body lands against the second branch.
        aid2, npath2 = self.spawn("zach-opus-b2")
        self.commit(npath2, "two.txt")
        self.finish(aid2)
        self.ff(self.entity, "dev/second", "worktree-agent-" + aid2)
        ws.land("zach-opus-b2", self.sid)
        self.assertFalse(os.path.exists(npath2))
        # The superseded body of work is still readable — an agent spawned for
        # it lands against it, so it is not history.
        self.assertIn(first["id"], ws.all_bodies_of_work())


class _Result(unittest.TextTestResult):
    """Prints `  PASS  <test>` / `  FAIL  <test>` so the mutation harness
    (workspaces.mutation.sh) can tell which point went red."""

    def addSuccess(self, test):
        super().addSuccess(test)
        self.stream.write("  PASS  %s\n" % test._testMethodName)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.stream.write("  FAIL  %s\n" % test._testMethodName)

    def addError(self, test, err):
        super().addError(test, err)
        self.stream.write("  FAIL  %s (error)\n" % test._testMethodName)


if __name__ == "__main__":
    # No arguments: every point. Arguments: the named classes or tests only,
    # e.g. `workspaces.test.py Point05_Guarantee` -- one point's proof.
    runner = unittest.TextTestRunner(stream=sys.stdout, verbosity=0, resultclass=_Result)
    loader = unittest.defaultTestLoader
    names = [a for a in sys.argv[1:] if a]
    suite = (loader.loadTestsFromNames(names, sys.modules[__name__]) if names
             else loader.loadTestsFromModule(sys.modules[__name__]))
    result = runner.run(suite)
    print("=== workspaces spec tests: %d run, %d failed ===" % (
        result.testsRun, len(result.failures) + len(result.errors)))
    sys.exit(0 if result.wasSuccessful() else 1)
