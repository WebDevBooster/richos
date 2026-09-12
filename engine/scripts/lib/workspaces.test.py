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
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "workspaces.py")

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

    def tool_call(self, aid):
        """One of the worker's own tool calls, exactly as the PreToolUse hook
        makes it: a payload carrying the platform's agent id."""
        return ws.barrier({"session_id": self.sid, "agent_id": aid})

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
        """B's branches are B's while A is running. Attributing them to A
        refused A's land (B's branch is not in main) and then DELETED them on a
        discard -- against point 8, "deletion therefore never loses anything
        that was meant to land", and point 5's guarantee for B."""
        a_cc = self.make_cc("zach-opus-a1")
        aid_a, npath_a = self.spawn("zach-opus-a1", cc=a_cc)
        self.tool_call(aid_a)                                # A is working
        b_cc = self.make_cc("zach-opus-b1")                  # B is spawned while A works
        aid_b, npath_b = self.spawn("zach-opus-b1", cc=b_cc)
        self.tool_call(aid_b)
        self.commit(npath_b, "b.txt")
        self.tool_call(aid_a)                                # A's next call: none of B's is A's
        self.assertEqual(self.rec("zach-opus-a1")["created_branches"], [])
        self.commit(npath_a, "a.txt")
        self.finish(aid_a)                                   # nor at A's end-of-run signal
        self.assertEqual(self.rec("zach-opus-a1")["created_branches"], [])
        self.merge(self.entity, "worktree-agent-" + aid_a)
        self.merge(self.other, "cc/zach-opus-a1")
        ws.land("zach-opus-a1", self.sid)                    # never held up by a branch of B's
        self.assertIn("cc/zach-opus-b1", branches(self.other))
        self.assertIn("worktree-agent-" + aid_b, branches(self.entity))
        self.assertTrue(os.path.exists(b_cc))
        self.assertTrue(os.path.exists(npath_b))

    def test_point_03_a_branch_rich_cuts_in_the_main_checkout_is_never_the_agents(self):
        """Rich's own refs are not the system's concern (point 1) and are never
        deleted with an agent -- neither one he cuts in the main checkout nor one
        he checks out in a workspace of his own."""
        aid, npath = self.spawn("zach-opus-m1")
        self.tool_call(aid)
        run("git", "-C", self.entity, "branch", "rich/notes")          # in the main checkout
        look = os.path.join(self.env.root, "rich-look")
        run("git", "-C", self.entity, "worktree", "add", "-q", look, "-b", "rich/look")
        self.tool_call(aid)
        self.assertEqual(self.rec("zach-opus-m1")["created_branches"], [])
        self.commit(npath)
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
        self._pending_one()
        tr = os.path.join(self.env.root, "t.jsonl")
        with open(tr, "w") as f:
            f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "stop everything"}}) + "\n")
        ok, _m = ws.gate_stop({"session_id": self.sid, "transcript_path": tr,
                               "last_assistant_message": "Stopping. Pending: zach-opus-p5."}, self.entity)
        self.assertTrue(ok)
        # a notification is not the CEO
        with open(tr, "w") as f:
            f.write(json.dumps({"type": "user", "message": {"role": "user",
                                                            "content": "<task-notification>x</task-notification>"}}) + "\n")
        ok, _m = ws.gate_stop({"session_id": self.sid, "transcript_path": tr,
                               "last_assistant_message": "Pending: zach-opus-p5."}, self.entity)
        self.assertFalse(ok)

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
            f.write(json.dumps({"type": "user", "message": {"role": "user",
                                                            "content": "what is the state of things?"}}) + "\n")
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
        aid, npath = self.spawn("zach-opus-ceo", extra="ceo-ordered: 'Implement spec.'\n")
        self.commit(npath)
        self.finish(aid)
        ws.wait("zach-opus-ceo", "ceo-discard", "May I discard the rejected spec branch?", "CEO-TODOs 1.1", self.sid)
        self.assertTrue(ws.gate_stop({"session_id": self.sid}, self.entity)[0])
        self.spawn("zach-opus-unrelated")                    # new work is not blocked by it

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
        """A branch the agent made IN ITS OWN WORKSPACE goes with it: git says
        the ref is checked out at the path the agent's registration recorded, so
        it is the agent's as a fact about its own workspace.

        AND THE COST OF SAYING ONLY THAT, OUT LOUD: `git branch plain-branch`
        checks nothing out, and git records nowhere that it was run inside this
        workspace -- not in the workspace's HEAD reflog, not in the new ref's. So
        it is NOT attributed and is left behind. Deliberate: an unattributed
        branch that is nobody's concern (point 1) is a stray; a MISattributed one
        is another agent's work deleted (point 8)."""
        aid, npath = self.spawn("zach-opus-b")
        self.tool_call(aid)
        run("git", "-C", npath, "checkout", "-q", "-b", "side-branch")
        self.commit(npath, "side.txt")
        run("git", "-C", npath, "branch", "plain-branch")    # checked out nowhere: not the agent's
        self.tool_call(aid)                                 # observed, in its own workspace
        self.assertEqual([tuple(x) for x in self.rec("zach-opus-b")["created_branches"]],
                         [(self.entity, "side-branch")])
        self.finish(aid)
        self.assertIn("side-branch", branches(self.entity))
        ws.discard("zach-opus-b", "not wanted any more", not_ceo_ordered="a probe of branch attribution", me=self.sid)
        self.assertNotIn("side-branch", branches(self.entity))
        self.assertIn("plain-branch", branches(self.entity))   # the accepted cost, stated

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
        # Rich rescues the work: a copy cut inside the agent's own workspace,
        # with a commit of his own on top, after the agent's run has ended.
        run("git", "-C", npath, "checkout", "-q", "-b", "rescue-rich")
        self.commit(npath, "rescued.txt")
        # the platform restarts finished agents (point 9); a restarted agent's
        # call is refused, and it observes nothing either -- so Rich's branch is
        # his even while it is the one checked out in the agent's old workspace
        self.assertEqual(self.tool_call(aid)[0], "FINISHED")
        self.assertEqual(self.rec("zach-opus-r")["created_branches"], [])
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
