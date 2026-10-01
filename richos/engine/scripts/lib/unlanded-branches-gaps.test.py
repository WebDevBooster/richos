#!/usr/bin/env python3
"""unlanded-branches.sweep must not drop what git or the ledger would not show it.

Hunt P5-08 (part 5): an unreadable ledger, a failed worktree list and a failed
per-branch count each used to make branches disappear (or live work look
stranded) while the sweep still ended "swept". Each is now listed under
NOT EXAMINED and the status is `partial`, which every consumer already renders
as "not a clean main".

Case 1 is the control: the same fixture, nothing failing, reports the stranded
branch. Case 3 pins the reason the code had for tolerating a ledger that does
not exist yet: nothing was ever recorded, which is an answer, not a gap.
"""
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("unlanded_branches", os.path.join(HERE, "unlanded-branches.py"))
ub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ub)


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)


class UnlandedGaps(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="unlanded-gaps."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = os.path.join(self.tmp, "repo")
        run("git", "init", "-q", "-b", "main", self.repo)
        for key, fallback in (("user.email", "tester@example.invalid"), ("user.name", "tester")):
            got = subprocess.run(["git", "config", key], capture_output=True, text=True).stdout.strip()
            run("git", "config", key, got or fallback, cwd=self.repo)
        with open(os.path.join(self.repo, "a.txt"), "w") as fh:
            fh.write("one\n")
        run("git", "add", "-A", cwd=self.repo)
        run("git", "commit", "-q", "-m", "base", cwd=self.repo)
        run("git", "checkout", "-q", "-b", "stranded", cwd=self.repo)
        with open(os.path.join(self.repo, "b.txt"), "w") as fh:
            fh.write("work\n")
        run("git", "add", "-A", cwd=self.repo)
        run("git", "commit", "-q", "-m", "stranded work", cwd=self.repo)
        run("git", "checkout", "-q", "main", cwd=self.repo)
        self.ledger = os.path.join(self.tmp, "ledger.jsonl")
        with open(self.ledger, "w") as fh:
            fh.write("")
        p = mock.patch.object(ub, "trunk_of", lambda repo: "main")
        p.start()
        self.addCleanup(p.stop)

    def sweep(self, ledger=None):
        return ub.sweep(self.repo, "", ledger or self.ledger, "")

    def why(self, res):
        return " | ".join(ne["why"] for ne in res["not_examined"])

    def test_1_control_the_fixture_does_find_the_stranded_branch(self):
        res = self.sweep()
        self.assertEqual([f["branch"] for f in res["findings"]], ["stranded"])
        self.assertEqual(res["not_examined"], [])
        self.assertEqual(res["status"], "swept")

    def test_2_an_unreadable_ledger_is_not_examined_not_empty(self):
        os.remove(self.ledger)
        os.mkdir(self.ledger)            # exists, cannot be read as a file
        res = self.sweep()
        self.assertEqual(res["status"], "partial")
        self.assertIn("ledger could not be read", self.why(res))
        self.assertNotEqual(res["unexamined"], "")

    def test_3_a_ledger_that_does_not_exist_yet_is_still_an_answer(self):
        res = self.sweep(os.path.join(self.tmp, "never-written.jsonl"))
        self.assertEqual(res["status"], "swept")
        self.assertEqual(res["not_examined"], [])

    def test_4_a_branch_whose_count_fails_is_named_not_dropped(self):
        real = ub.git

        def fail_count(root, args, timeout=ub.GIT_TIMEOUT):
            if args[:1] == ["rev-list"]:
                return None
            return real(root, args, timeout)

        with mock.patch.object(ub, "git", fail_count):
            res = self.sweep()
        self.assertEqual(res["status"], "partial")
        self.assertEqual(res["findings"], [])
        self.assertIn("stranded", self.why(res))
        self.assertIn("NOT judged", self.why(res))

    def test_5_a_failed_worktree_list_does_not_call_held_work_stranded(self):
        real = ub.git

        def fail_list(root, args, timeout=ub.GIT_TIMEOUT):
            if args[:2] == ["worktree", "list"]:
                return None
            return real(root, args, timeout)

        with mock.patch.object(ub, "git", fail_list):
            res = self.sweep()
        self.assertEqual(res["status"], "partial")
        self.assertEqual(res["findings"], [])
        self.assertIn("worktree list", self.why(res))


if __name__ == "__main__":
    unittest.main(verbosity=2)
