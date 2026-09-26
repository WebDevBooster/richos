#!/usr/bin/env python3
"""Small real-lock fixtures for per-permit integration priority."""
import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import threading
from types import SimpleNamespace
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

    def age(self, budget, seconds=121):
        admission = budget.admission
        admission.since = time.monotonic() - seconds
        with open(admission.marker) as source:
            record = json.load(source)
        record["since"] = admission.since
        # Preserve the leased inode; replacing it would represent another owner.
        with open(admission.marker, "w") as out:
            json.dump(record, out)

    def test_waiting_integration_gets_next_permit_before_old_background(self):
        background = self.budget(self.linked)
        holder = self.take(background)
        self.assertIsNone(self.take(background))
        self.age(background)
        integration = self.budget(self.main)
        self.assertIsNone(self.take(integration))
        # Age does not grant a background request an exception to priority.
        holder.release()
        self.assertIsNone(self.take(background))
        token = self.take(integration)
        self.assertIsNotNone(token)
        token.release()
        self.assertIsNotNone(self.take(background))

    def test_aged_background_reserves_next_opportunity_after_integration(self):
        holder = self.take(self.budget(self.linked))
        old = self.budget(self.linked)
        self.assertIsNone(self.take(old))
        self.age(old)
        newer = self.budget(self.linked)
        integration = self.budget(self.main)
        self.assertIsNone(self.take(integration))
        holder.release()
        for b in (old, newer):
            self.assertIsNone(self.take(b))
        self.take(integration).release()
        self.assertIsNone(self.take(newer))
        self.take(old).release()
        self.assertIsNotNone(self.take(newer))

    def test_failed_attempt_preserves_background_age(self):
        self.take(self.budget(self.linked))
        queued = self.budget(self.linked)
        self.assertIsNone(self.take(queued))
        self.age(queued)
        since = queued.admission.since
        self.assertIsNone(self.take(queued))
        self.assertEqual(queued.admission.since, since)

    def test_crashed_aged_background_cannot_reserve_capacity(self):
        marker = Path(self.machine) / "admission" / "wait-dead.json"
        background = self.budget(self.linked)
        marker.write_text(json.dumps({"main": False, "since": time.monotonic() - 500,
                                      "pid": os.getpid(), "birth": "old generation"}))
        self.assertIsNotNone(self.take(background))
        self.assertFalse(marker.exists())

    def test_disjoint_permits_do_not_block_background_progress(self):
        old = self.budget(self.linked)
        old.admission.permits = ["token-000"]
        old.admission.register()
        self.age(old)
        newer = self.budget(self.linked)
        newer.admission.permits = ["token-001"]
        self.assertTrue(newer.admission.begin())
        newer.admission.attempted(False)

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

    def test_timing_separates_real_admission_wait_and_preserves_failure(self):
        holder = self.take(self.budget(self.linked))
        timer = threading.Timer(.4, holder.release)
        timing = self.root / "timing.json"
        cleanups = []
        devices = SimpleNamespace(cleanup_run_simulators=lambda run: cleanups.append(run) or [])
        with patch.dict(os.environ, {"RICHOS_WORKER_TOKENS": "", "RICHOS_WORKER_SLOT_HELD": ""}), \
                patch.object(worker_tokens, "machine_directory", return_value=self.machine), \
                patch.dict(sys.modules, {"testdevices": devices}):
            timer.start()
            try:
                rc = worker_tokens.machine_command([sys.executable, "-c", "raise SystemExit(7)"],
                                                   timing=str(timing))
            finally:
                timer.join()
        report = json.loads(timing.read_text())
        self.assertEqual((rc, report["exit"]), (7, 7))
        self.assertTrue(report["admitted"])
        self.assertGreaterEqual(report["admission_seconds"], .3)
        self.assertGreater(report["execution_seconds"], 0)
        self.assertEqual(len(cleanups), 1)
        self.assertIsNotNone(self.take(self.budget(self.linked)))

    def test_timed_nested_command_preserves_callers_borrow_slot(self):
        holder = self.take(self.budget(self.linked))
        timing = self.root / "nested-timing.json"
        slot = self.root / "observed-slot"
        with patch.dict(os.environ, {"RICHOS_WORKER_TOKENS": self.machine,
                                     "RICHOS_WORKER_SLOT_HELD": "1",
                                     "RICHOS_WORKER_BORROW_LOCK": holder.path + ".child"}):
            rc = worker_tokens.machine_command(
                [sys.executable, "-c", "import os,sys; open(sys.argv[1],'w').write("
                 "os.environ['RICHOS_WORKER_BORROW_LOCK'])", str(slot)], timing=str(timing))
        self.assertEqual(rc, 0)
        self.assertEqual(slot.read_text(), holder.path + ".child")
        self.assertEqual(self.budget(self.linked).held(), 1)


if __name__ == "__main__":
    unittest.main()
