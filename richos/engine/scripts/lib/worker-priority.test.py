#!/usr/bin/env python3
"""Small real-lock fixtures for per-permit integration priority."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import engine_pass
import worker_tokens


class Priority(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="worker-priority-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.main = self.root / "main"
        self.main.mkdir()
        for argv in (["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "fixture"]):
            subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=fixture",
                            "-c", "user.email=fixture@example.invalid", *argv], cwd=self.main,
                           check=True, capture_output=True)
        self.linked = self.root / "linked"
        subprocess.run(["git", "-C", str(self.main), "worktree", "add", "-q", "-b", "fixture",
                        str(self.linked)], check=True, capture_output=True)
        self.machine = str(self.root / "machine")
        worker_tokens.init(self.machine, 1)
        self.budgets = []
        self.tokens = []
        self.addCleanup(self.release)

    def release(self):
        for token in self.tokens:
            token.release()
        for budget in self.budgets:
            budget.close()

    def budget(self, checkout):
        budget = worker_tokens.Budget(self.machine, shared=False)
        budget.admission = engine_pass.Admission(self.machine, str(checkout))
        self.budgets.append(budget)
        return budget

    def take(self, budget):
        token = budget.try_acquire()
        if token:
            self.tokens.append(token)
        return token

    def test_waiting_integration_gets_next_permit_before_old_background(self):
        background = self.budget(self.linked)
        holder = self.take(background)
        integration = self.budget(self.main)
        self.assertIsNone(self.take(integration))
        # Age does not grant a background request an exception to priority.
        background.admission.since = -1000
        holder.release()
        self.assertIsNone(self.take(background))
        token = self.take(integration)
        self.assertIsNotNone(token)
        token.release()
        self.assertIsNotNone(self.take(background))

    def test_all_integration_waiters_keep_priority_until_admitted(self):
        background = self.budget(self.linked)
        holder = self.take(background)
        mains = [self.budget(self.main), self.budget(self.main)]
        for b in mains:
            self.assertIsNone(self.take(b))
        holder.release()
        for b in mains:
            self.assertIsNone(self.take(background))
            self.take(b).release()
        self.assertIsNotNone(self.take(background))

    def test_nested_work_can_borrow_held_permit_but_cannot_expand(self):
        background = self.budget(self.linked)
        holder = self.take(background)
        integration = self.budget(self.main)
        self.assertIsNone(self.take(integration))
        self.assertIsNone(self.take(background))
        borrowed = background._try_free(holder.path + ".child")
        self.assertIsNotNone(borrowed)
        borrowed.release()
        self.assertEqual(background.held(), 1)

    def test_crashed_waiter_releases_kernel_priority(self):
        background = self.budget(self.linked)
        code = ("import engine_pass,sys,time; "
                "a=engine_pass.Admission(sys.argv[1],sys.argv[2]); "
                "assert a.begin(); print('ready',flush=True); time.sleep(60)")
        p = subprocess.Popen([sys.executable, "-c", code, self.machine, str(self.main)],
                             cwd=Path(__file__).parent, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(p.stdout.readline().strip(), "ready")
            self.assertIsNone(self.take(background))
        finally:
            p.kill()
            p.wait(timeout=5)
            p.stdout.close()
        self.assertIsNotNone(self.take(background))

    def test_mac_slot_refuses_missing_ssd_without_creating_fallback(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(engine_pass.sys, "platform", "darwin"), \
                patch.object(engine_pass.os.path, "ismount", return_value=False), \
                patch.object(engine_pass.os, "makedirs") as create:
            with self.assertRaisesRegex(RuntimeError, "/Volumes/E1TB"):
                engine_pass.directory()
            create.assert_not_called()


if __name__ == "__main__":
    unittest.main()
