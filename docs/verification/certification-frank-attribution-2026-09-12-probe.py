#!/usr/bin/env python3
"""Frank's probe — the ONE fix at e8524b6b: a branch is the agent's because git
reports it checked out at one of that agent's own registered workspace paths.

Every case below is written so that a FAILURE is a sentence of the CEO's page
(docs/plans/worktree-spec-2026-09-11.md) not being true of the build. Each test's
docstring quotes the sentence it is holding the build to.

Runs inside the shipped suite's own sandbox (workspaces.test.py's Env redirects
HOME and CLAUDE_CONFIG_DIR into a temporary directory and builds throwaway git
repositories), so the operator's real registry is never read or written.

    python3 docs/verification/certification-frank-attribution-2026-09-12-probe.py
"""
import importlib.util, os, sys, unittest

HERE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                    "engine", "scripts", "lib")
sys.path.insert(0, HERE)
spec = importlib.util.spec_from_file_location("wstest", os.path.join(HERE, "workspaces.test.py"))
T = importlib.util.module_from_spec(spec); spec.loader.exec_module(T)
ws = T.ws


class ProbeC2(T.Base):

    # ---- B1: the declared cost, measured -------------------------------
    def test_b1_a_plain_git_branch_in_the_workspace_is_left_behind_forever(self):
        """Point 10: "every workspace and branch it has is deleted, as one. None
        is left behind." Point 3: "any branch an agent created ... counts as
        finished work of an ended session and is handled under point 5."

        The engineer declares this cost. This measures whether anything at all
        picks the branch up afterwards."""
        aid, npath = self.spawn("zach-opus-n1")
        self.tool_call(aid)
        T.run("git", "-C", npath, "branch", "spare-work")     # created, never checked out
        self.commit(npath)
        self.tool_call(aid)
        self.finish(aid)
        self.merge(self.entity, "worktree-agent-" + aid)
        ws.land("zach-opus-n1", self.sid)
        after = T.branches(self.entity)
        pend = self.names()
        print("\nB1 branches after land:", after)
        print("B1 pending after land  :", pend)
        self.assertNotIn("spare-work", after,
                         "a branch the agent created is left behind, and the pending list is %s" % pend)

    def test_b2_a_cc_named_stray_is_handled_by_the_unregistered_scan(self):
        """Point 3, hole 6: an unregistered cc/ branch "counts as finished work
        of an ended session and is handled under point 5." This is the BOUND on
        B1 and B3: a cc/-NAMED stray is caught by the scan even when nothing
        attributed it. The stray here carries a commit of its own, so it cannot
        be disposed of by being already in main."""
        aid, npath = self.spawn("zach-opus-n2")
        self.tool_call(aid)
        T.run("git", "-C", npath, "checkout", "-q", "-b", "cc/zach-opus-n2-spare")
        self.commit(npath, "spare.txt")
        own = "worktree-agent-" + aid
        T.run("git", "-C", npath, "checkout", "-q", own)
        self.commit(npath)
        self.tool_call(aid)
        self.finish(aid)
        self.merge(self.entity, own)
        ws.land("zach-opus-n2", self.sid)
        pend = self.names()
        after = T.branches(self.entity)
        print("\nB2 branches after land:", after)
        print("B2 pending after land  :", pend)
        self.assertTrue("cc/zach-opus-n2-spare" not in after or any(n.startswith("orphan-") for n in pend),
                        "a cc/-named stray is neither attributed, nor deleted, nor listed: %s / %s"
                        % (after, pend))

    def test_b7_the_point_5_gate_refuses_a_spawn_while_such_a_branch_is_pending(self):
        """THE BOUND ON B4, and it is a real one: point 5's "while any finished
        agent's work is neither landed nor discarded, Rich can neither start new
        work nor end his turn." A branch the scan has ALREADY listed cannot be
        handed to a new agent at all — the spawn is refused. So B4's window is
        only a branch that becomes unattached while an agent is already
        running."""
        T.run("git", "-C", self.other, "branch", "cc/zach-opus-earlier")
        stray = os.path.join(self.env.root, "earlier-wt")
        T.run("git", "-C", self.other, "worktree", "add", "-q", stray, "cc/zach-opus-earlier")
        self.commit(stray, "earlier-work.txt")
        T.run("git", "-C", self.other, "worktree", "remove", "--force", stray)
        ws._remember_repo(self.other)
        before = self.names()
        print("\nB7 pending before      :", before)

        cc = self.make_cc("zach-opus-n7")
        refused = ""
        try:
            self.spawn("zach-opus-n7", cc=cc)
        except ws.SpecError as e:
            refused = str(e).splitlines()[0]
        print("B7 spawn refused with  :", refused or "(NOT REFUSED)")
        self.assertTrue(refused, "a new agent could be spawned while that branch sat pending")

    # ---- B3: the same blind spot, but the branch carries COMMITS --------
    def test_b3_a_branch_the_agent_worked_on_and_switched_away_from_strands_its_commits(self):
        """Point 5: "Rich lands 100% of everything after the agent is finished —
        guaranteed." Point 10: "None is left behind." Point 8: "Deletion
        therefore never loses anything that was meant to land."

        The agent cuts a branch, commits on it, and switches back — all inside
        ONE tool call, which is the normal way a shell command is chained. At the
        next observation nothing of it is checked out, so possession sees
        nothing, and the commit is not in the agent's own branch either."""
        aid, npath = self.spawn("zach-opus-n3")
        self.tool_call(aid)
        own = "worktree-agent-" + aid
        T.run("git", "-C", npath, "checkout", "-q", "-b", "side-work")
        self.commit(npath, "side.txt")
        tip = T.run("git", "-C", npath, "rev-parse", "side-work").stdout.strip()
        T.run("git", "-C", npath, "checkout", "-q", own)      # back to its own branch
        self.commit(npath, "main-work.txt")
        self.tool_call(aid)                                   # the next observation
        rec = self.rec("zach-opus-n3")
        print("\nB3 created_branches    :", rec.get("created_branches"))
        self.finish(aid)
        self.merge(self.entity, own)
        res = ws.land("zach-opus-n3", self.sid)
        after = T.branches(self.entity)
        print("B3 land ->", res)
        print("B3 branches after land :", after)
        print("B3 pending after land  :", self.names())
        print("B3 the stranded commit :", tip)
        self.assertNotIn("side-work", after,
                         "a branch carrying a commit that is in NO landed branch is left behind")

    # ---- B4: possession of a branch that is NOT the agent's ------------
    def test_b4_a_branch_the_agent_merely_checked_out_becomes_its_own(self):
        """Point 8: "Deletion therefore never loses anything that was meant to
        land." A branch that already existed, which this agent only checked out
        to look at, is attributed to it by possession and deleted with it."""
        # ORDER MATTERS, and it is the realistic one: the agent is already
        # running when the other branch becomes unattached (its owner's
        # workspace was removed and its branch left). The point-5 gate refuses a
        # NEW spawn while such a branch is listed, so this is the window the gate
        # cannot close — and it is the state /Users/alex/ab/richos is in as this
        # is written (cc/zach-opus-f4 and cc/zach-opus-f9, neither in main,
        # attached to no workspace, while two review agents work in that repo).
        cc = self.make_cc("zach-opus-n4")
        aid, npath = self.spawn("zach-opus-n4", cc=cc)
        self.tool_call(aid)

        T.run("git", "-C", self.other, "branch", "cc/zach-opus-gone")
        stray = os.path.join(self.env.root, "stray-wt")
        T.run("git", "-C", self.other, "worktree", "add", "-q", stray, "cc/zach-opus-gone")
        self.commit(stray, "someone-elses-work.txt")
        lost_tip = T.run("git", "-C", stray, "rev-parse", "HEAD").stdout.strip()
        T.run("git", "-C", self.other, "worktree", "remove", "--force", stray)
        T.run("git", "-C", cc, "checkout", "-q", "cc/zach-opus-gone")   # only looks at it
        self.tool_call(aid)
        rec = self.rec("zach-opus-n4")
        print("\nB4 created_branches    :", rec.get("created_branches"))
        T.run("git", "-C", cc, "checkout", "-q", "cc/zach-opus-n4")
        self.commit(npath)
        self.finish(aid)
        ws.discard("zach-opus-n4", "probe of possession attribution",
                   not_ceo_ordered="a probe branch, not CEO-ordered", me=self.sid)
        after = T.branches(self.other)
        print("B4 branches after discard:", after)
        print("B4 the lost tip          :", lost_tip)
        self.assertIn("cc/zach-opus-gone", after,
                      "another piece of pending work was deleted because this agent looked at it")

    def test_b5_a_branch_the_agent_checked_out_holds_its_land_hostage(self):
        """Point 5: "Rich lands 100% of everything after the agent is finished —
        guaranteed. ... Every time, all of it, no exceptions, no deferral."
        A land that refuses because of a branch the agent did not create leaves
        the item landable by nothing Rich can do to the agent's own work."""
        cc = self.make_cc("zach-opus-n5")
        aid, npath = self.spawn("zach-opus-n5", cc=cc)
        self.tool_call(aid)

        T.run("git", "-C", self.other, "branch", "cc/zach-opus-old")
        stray = os.path.join(self.env.root, "old-wt")
        T.run("git", "-C", self.other, "worktree", "add", "-q", stray, "cc/zach-opus-old")
        self.commit(stray, "not-in-main.txt")
        T.run("git", "-C", self.other, "worktree", "remove", "--force", stray)
        T.run("git", "-C", cc, "checkout", "-q", "cc/zach-opus-old")
        self.tool_call(aid)
        T.run("git", "-C", cc, "checkout", "-q", "cc/zach-opus-n5")
        self.commit(npath)
        self.commit(cc)
        self.finish(aid)
        self.merge(self.entity, "worktree-agent-" + aid)
        self.merge(self.other, "cc/zach-opus-n5")
        try:
            res = ws.land("zach-opus-n5", self.sid)
            print("\nB5 land ->", res)
        except ws.SpecError as e:
            print("\nB5 land REFUSED:", e)
            raise AssertionError("the agent's own work cannot be landed: %s" % e)

    # ---- B6: the fix's own claim, under a rename ------------------------
    def test_b6_the_agents_own_branch_renamed_in_its_workspace_still_goes_with_it(self):
        """Point 10: "every workspace and branch it has is deleted, as one. None
        is left behind." A rename keeps the ref checked out at the agent's own
        path, so possession should see it."""
        aid, npath = self.spawn("zach-opus-n6")
        self.tool_call(aid)
        T.run("git", "-C", npath, "branch", "-m", "worktree-agent-" + aid, "renamed-work")
        self.commit(npath)
        self.tool_call(aid)
        rec = self.rec("zach-opus-n6")
        print("\nB6 created_branches    :", rec.get("created_branches"))
        self.finish(aid)
        self.merge(self.entity, "renamed-work")
        res = ws.land("zach-opus-n6", self.sid)
        after = T.branches(self.entity)
        print("B6 land ->", res)
        print("B6 branches after land :", after)
        print("B6 pending after land  :", self.names())
        self.assertNotIn("renamed-work", after, "the renamed branch is left behind")


if __name__ == "__main__":
    unittest.main(verbosity=2, argv=[sys.argv[0]], exit=False)
