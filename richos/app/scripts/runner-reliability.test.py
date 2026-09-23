#!/usr/bin/env python3
"""Failure-injection checks for the proof runner's ownership and admission boundaries."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / 'engine/scripts/lib'))
import proc_tree
import worker_tokens
spec = importlib.util.spec_from_file_location('proof_run', HERE / 'proof-run.py')
pr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pr)


class Reliability(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='runner-faults.')
        self.path = Path(self.tmp.name)
        self.children = []

    def tearDown(self):
        for p in self.children:
            if p.poll() is None:
                proc_tree.kill_tree(p.pid, .1)
            p.wait(timeout=5)
        self.tmp.cleanup()

    def wait_file(self, path):
        until = time.monotonic() + 10
        while time.monotonic() < until:
            if path.exists() and path.read_text().strip():
                return int(path.read_text())
            time.sleep(.05)
        self.fail('child did not start: ' + str(path))

    def wait_gone(self, pid):
        until = time.monotonic() + 12
        while time.monotonic() < until:
            if not proc_tree._alive([pid]):
                return
            time.sleep(.1)
        self.fail('owned child survived: ' + str(pid))

    def test_success_cleans_detached_reparented_child_and_preserves_unrelated(self):
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(60)'])
        self.children.append(unrelated)
        record = self.path / 'detached'
        script = ('import subprocess,sys; p=subprocess.Popen([sys.executable,"-c",'
                  '"import time;time.sleep(60)"],start_new_session=True); '
                  'open(sys.argv[1],"w").write(str(p.pid))')
        result = subprocess.run(proc_tree.command([sys.executable, '-c', script, str(record)]), timeout=15)
        self.assertEqual(result.returncode, 0)
        self.wait_gone(self.wait_file(record))
        self.assertIsNone(unrelated.poll())

    def test_shell_pipeline_retains_normal_sigpipe_behavior(self):
        result = subprocess.run(proc_tree.command(['bash', '-c',
            'LC_ALL=C tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c 12']),
            capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stdout), 12)

    def test_success_cleans_background_protected_binary(self):
        record = self.path / 'background'
        script = 'sleep 60 & echo $! > "$1"'
        result = subprocess.run(proc_tree.command(['bash', '-c', script, 'fixture', str(record)]), timeout=15)
        self.assertEqual(result.returncode, 0)
        self.wait_gone(self.wait_file(record))

    def test_sigkill_owner_still_cleans_command_and_releases_lease(self):
        budget = self.path / 'budget'
        worker_tokens.init(budget, 1)
        record = self.path / 'child'
        script = 'import os,sys,time;open(sys.argv[1],"w").write(str(os.getpid()));time.sleep(60)'
        wrapper = subprocess.Popen([sys.executable, worker_tokens.__file__, 'run', str(budget), '--',
                                    sys.executable, '-c', script, str(record)], start_new_session=True)
        self.children.append(wrapper)
        child = self.wait_file(record)
        self.assertEqual(worker_tokens.Budget(budget).held(), 1)
        wrapper.kill()
        wrapper.wait(timeout=5)
        self.wait_gone(child)
        until = time.monotonic() + 5
        while worker_tokens.Budget(budget).held() and time.monotonic() < until:
            time.sleep(.05)
        self.assertEqual(worker_tokens.Budget(budget).held(), 0)

    def test_separate_runs_share_capacity_and_cannot_resize_live_locks(self):
        machine = self.path / 'machine'
        worker_tokens.init(machine, 2)
        held = []
        try:
            for name in ('one', 'two'):
                local = self.path / name
                worker_tokens.init(local, 4)
                held.append(worker_tokens.Budget(local, runner=True, shared=machine).try_acquire())
            third = self.path / 'three'
            worker_tokens.init(third, 4)
            self.assertIsNone(worker_tokens.Budget(third, runner=True, shared=machine).try_acquire())
            with self.assertRaises(ValueError):
                worker_tokens.init(machine, 1)
            self.assertEqual(worker_tokens.Budget(machine).held(), 2)
        finally:
            for token in held:
                token.release()

    def test_borrow_files_do_not_create_extra_capacity(self):
        budget = self.path / 'budget'
        worker_tokens.init(budget, 1)
        parent = worker_tokens.Budget(budget).try_acquire()
        try:
            borrow = worker_tokens.Budget._try_free(parent.path + '.child')
            self.assertEqual(len(worker_tokens.Budget(budget).files), 1)
            self.assertIsNone(worker_tokens.Budget(budget).try_acquire())
            borrow.release()
        finally:
            parent.release()

    def test_full_machine_budget_has_bounded_admission(self):
        machine = self.path / 'machine'
        with patch.dict(os.environ, {'RICHOS_MACHINE_WORKERS': str(machine)}):
            worker_tokens.machine_directory()
            budget = worker_tokens.Budget(machine, runner=True)
            held = [budget.try_acquire() for _ in budget.files]
            try:
                args = SimpleNamespace(capacity=1, sample_every=.1, max_cpu=80, keep_going=False,
                                       admission_wait=.1, deadline=1, budget=1)
                item = pr.Item('must wait', str(self.path), [sys.executable, '-c', 'raise Exception("ran")'])
                sample = dict(cpu_user_percent=1, cpu_system_percent=1, memory_pressure='normal', swapout_mb_per_s=0)
                elapsed = pr.run([item], args, str(self.path / 'logs'), sampler=lambda: sample)
                self.assertEqual(item.state, 'not-admitted')
                self.assertIsNone(item.proc)
                self.assertLess(elapsed, 3)
            finally:
                for token in held:
                    token.release()

    def test_first_failure_cancels_pending_checks(self):
        args = SimpleNamespace(capacity=1, sample_every=.1, max_cpu=80, keep_going=False,
                               admission_wait=1, deadline=2, budget=1)
        failed = pr.Item('bad', str(self.path), [sys.executable, '-c', 'raise SystemExit(7)'], weight=2)
        pending = pr.Item('pending', str(self.path), [sys.executable, '-c', 'raise Exception("ran")'], weight=1)
        sample = dict(cpu_user_percent=1, cpu_system_percent=1, memory_pressure='normal', swapout_mb_per_s=0)
        with patch.dict(os.environ, {'RICHOS_MACHINE_WORKERS': str(self.path / 'machine')}):
            pr.run([failed, pending], args, str(self.path / 'logs'), sampler=lambda: sample)
        self.assertEqual(failed.rc, 7)
        self.assertEqual(pending.state, 'cancelled')
        self.assertIsNone(pending.proc)

    def test_kernel_saturation_refuses_admission(self):
        from types import SimpleNamespace
        sample = dict(cpu_user_percent=30, cpu_system_percent=66, memory_pressure='normal', swapout_mb_per_s=0)
        self.assertFalse(pr.admitted(SimpleNamespace(max_cpu=80), lambda: sample)[0])

    def test_unknown_option_cannot_be_ignored_with_saved_commands(self):
        commands = self.path / 'commands'
        commands.write_text('cd richos/app && bash -c "exit 0"\n')
        result = subprocess.run([sys.executable, str(HERE / 'proof-run.py'), '--commands', str(commands),
                                 '--low-priority', '--log-dir', str(self.path / 'logs')], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unexpected arguments', result.stderr)

    def test_active_and_failed_evidence_survives_rotation(self):
        for i in range(6):
            directory = self.path / ('20260923T00000%dZ' % i)
            directory.mkdir()
            if i:
                (directory / 'summary.json').write_text(json.dumps({'checks': [{'result': 'failed' if i == 1 else 'passed'}]}))
        pr.rotate(self.path)
        self.assertTrue((self.path / '20260923T000000Z').exists())
        self.assertTrue((self.path / '20260923T000001Z').exists())
        self.assertFalse((self.path / '20260923T000002Z').exists())

    def test_existing_log_directory_is_not_overwritten(self):
        logs = self.path / 'logs'
        logs.mkdir()
        sentinel = logs / 'summary.json'
        sentinel.write_text('evidence')
        result = subprocess.run([sys.executable, str(HERE / 'proof-run.py'), '--log-dir', str(logs), '--dry-run'],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), 'evidence')


if __name__ == '__main__':
    unittest.main(verbosity=2)
