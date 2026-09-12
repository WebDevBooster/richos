#!/usr/bin/env python3
"""Frank's probe — fix 2 (branch attribution), the four failures behind
NOT CERTIFIED in certification-frank-four-fixes-2026-09-12.md.

Runs entirely inside the shipped suite's own sandbox: workspaces.test.py's Env
redirects HOME and CLAUDE_CONFIG_DIR into a temporary directory and builds
throwaway git repositories, so the operator's real registry is never touched.
Every step is the hooks' own call path (register_cc, register_spawn,
record_start, bind_agent, barrier).

    python3 docs/verification/certification-frank-four-fixes-2026-09-12-probe.py

All four tests are expected to FAIL at e41e00f9 and to pass once a branch is
the agent's because that agent made it, rather than because it appeared while
that agent was running."""
import importlib.util, os, sys, unittest

HERE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                    "engine", "scripts", "lib")
sys.path.insert(0, HERE)
spec = importlib.util.spec_from_file_location("wstest", os.path.join(HERE, "workspaces.test.py"))
T = importlib.util.module_from_spec(spec); spec.loader.exec_module(T)
ws = T.ws


class ProbeA(T.Base):
    def test_a1_another_agents_branch_is_attributed_to_this_one(self):
        ccA = self.make_cc("zach-opus-a1")
        aidA, nA = self.spawn("zach-opus-a1", cc=ccA)
        self.assertEqual(self.tool_call(aidA)[0], "REGISTERED")   # A's window opens
        # ---- meanwhile, the lead spawns a SECOND agent into the same repos ----
        ccB = self.make_cc("zach-opus-b1")
        aidB, nB = self.spawn("zach-opus-b1", cc=ccB)
        self.tool_call(aidA)                                      # A's next tool call
        recA = self.rec("zach-opus-a1")
        print("\nA.created_branches =", recA.get("created_branches"))
        print("B's own branches    =", [("cc/zach-opus-b1"), ("worktree-agent-" + aidB)])
        got = set(b for _r, b in (tuple(x) for x in recA.get("created_branches") or []))
        self.assertEqual(got, set(), "B's branches were attributed to A: %s" % sorted(got))

    def test_a2_land_of_A_is_held_hostage_by_the_other_agents_branch(self):
        ccA = self.make_cc("zach-opus-a2")
        aidA, nA = self.spawn("zach-opus-a2", cc=ccA)
        self.tool_call(aidA)
        ccB = self.make_cc("zach-opus-b2")
        aidB, nB = self.spawn("zach-opus-b2", cc=ccB)
        self.tool_call(aidA)
        # A finishes with everything committed and merged
        self.commit(nA); self.commit(ccA)
        self.finish(aidA)
        self.merge(self.entity, "worktree-agent-" + aidA)
        self.merge(self.other, "cc/zach-opus-a2")
        # B carries on working and commits on its own branch
        self.commit(nB, "b-work.txt")
        try:
            res = ws.land("zach-opus-a2", self.sid)
            print("\nland(A) ->", res)
        except ws.SpecError as e:
            print("\nland(A) REFUSED:", e)
            raise AssertionError("A's land is blocked by another agent's branch: %s" % e)

    def test_a3_a_branch_the_lead_cuts_in_the_main_checkout_is_the_agents(self):
        ccA = self.make_cc("zach-opus-a3")
        aidA, nA = self.spawn("zach-opus-a3", cc=ccA)
        self.tool_call(aidA)
        T.run("git", "-C", self.other, "branch", "keep-cc-a3", "cc/zach-opus-a3")  # the lead's own
        self.tool_call(aidA)
        recA = self.rec("zach-opus-a3")
        print("\nA.created_branches =", recA.get("created_branches"))
        got = set(b for _r, b in (tuple(x) for x in recA.get("created_branches") or []))
        self.assertNotIn("keep-cc-a3", got,
                         "the lead's rescue branch cut in the MAIN CHECKOUT was attributed to the agent")

    def test_a4_discard_of_A_deletes_the_other_agents_branch(self):
        ccA = self.make_cc("zach-opus-a4")
        aidA, nA = self.spawn("zach-opus-a4", cc=ccA)
        self.tool_call(aidA)
        T.run("git", "-C", self.other, "branch", "cc/zach-opus-b4")   # a branch that is not A's
        self.tool_call(aidA)
        self.finish(aidA)
        ws.discard("zach-opus-a4", "probe of branch attribution", not_ceo_ordered="a probe branch, not CEO-ordered", me=self.sid)
        after = T.branches(self.other)
        print("\nbranches after discard(A):", after)
        self.assertIn("cc/zach-opus-b4", after, "a branch that was never A's was deleted with A")


if __name__ == "__main__":
    unittest.main(verbosity=2, argv=[sys.argv[0]], exit=False)
