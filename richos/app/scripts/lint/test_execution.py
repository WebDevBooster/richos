import argparse
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from common import Refusal, run, shellcheck
import driver
import rust


class Execution(unittest.TestCase):
    def test_lock_wait_counts_toward_command_deadline(self):
        with tempfile.TemporaryDirectory(prefix='lint-cache-lock-') as tmp:
            path = Path(tmp) / 'cache.lock'
            command = [sys.executable, '-c',
                       'import fcntl,sys; f=open(sys.argv[1]); fcntl.flock(f,fcntl.LOCK_EX); print("acquired")', str(path)]
            with path.open('w') as owner:
                fcntl.flock(owner, fcntl.LOCK_EX)
                with self.assertRaises(subprocess.TimeoutExpired):
                    run(command, cwd=tmp, timeout=.2)
            result, _ = run(command, cwd=tmp, timeout=2)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), 'acquired')

    def test_missing_tool(self):
        with self.assertRaises(FileNotFoundError):
            run(['/nonexistent/lint-tool'], cwd=Path.cwd())

    def test_empty_scan(self):
        with self.assertRaises(Refusal):
            shellcheck(Path.cwd(), {})

    def test_compilation_and_output_failures(self):
        for code, out in ((1, ''), (0, 'not json'), (0, ''),
                          (0, '{"reason":"build-finished","success":false}')):
            result = subprocess.CompletedProcess([], code, out, 'fixture compile error')
            with patch('rust.run', return_value=(result, .1)), self.assertRaises(Refusal):
                rust.collect(Path.cwd(), [['cargo', 'clippy']])

    def test_nested_gate_never_probes_parent_lock_or_load(self):
        with patch.dict(os.environ, {'RICHOS_NIGHTLY_RUN_ID': 'fixture'}), \
             patch('fcntl.flock', side_effect=AssertionError('parent lock probe')), \
             patch('os.getloadavg', side_effect=AssertionError('parent load probe')), \
             patch('driver.inventory', return_value={}), patch('driver.versions', return_value={}), \
             patch('driver.fast_was_run', return_value=True), patch('driver.tauri') as check:
            self.assertEqual(driver.main(['--all', '--suite-results', 'fixture.json']), 0)
            check.assert_called_once()

    def test_deadline_stops_owned_child(self):
        with tempfile.TemporaryDirectory(prefix='lint-owned-') as tmp:
            pidfile = Path(tmp) / 'child.pid'
            source = '''import os,signal,time,sys
child=os.fork()
if child == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True: time.sleep(1)
open(sys.argv[1], 'w').write(str(child))
while True: time.sleep(1)
'''
            started = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired):
                run([sys.executable, '-c', source, pidfile], cwd=tmp, timeout=.3)
            self.assertLess(time.monotonic() - started, 6)
            child = int(pidfile.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)

    def test_tauri_always_runs_with_same_deadline_budget(self):
        args = argparse.Namespace(bootstrap=False, lower=False)
        rows = {'src.rs': {'language': 'rust', 'role': 'production'}}
        with patch('driver.rust.lint_rules', return_value={'fixture': 'blocking'}), \
             patch('driver.rust.collect', return_value=({}, [])) as collect, \
             patch('driver.enforce') as enforce:
            for _ in range(2):
                report = {}
                driver.tauri(Path.cwd(), args, rows, {}, report)
                remaining = collect.call_args.args[2] - time.monotonic()
                self.assertGreater(remaining, 170)
                self.assertLessEqual(remaining, 180)
                self.assertIn('seconds', report['tauri'])
            self.assertEqual(collect.call_count, 2)
            self.assertEqual(enforce.call_count, 2)
            collect.side_effect = subprocess.TimeoutExpired('cargo', 180)
            with self.assertRaises(subprocess.TimeoutExpired):
                driver.tauri(Path.cwd(), args, rows, {}, {})
            self.assertEqual(enforce.call_count, 2)

    def test_tauri_refuses_when_budget_expires_after_collection(self):
        with patch('driver.time.monotonic', side_effect=[0, 179, 181]), \
             patch('driver.rust.collect', return_value=({}, [])), \
             patch('driver.rust.lint_rules', return_value={}), patch('driver.enforce'), \
             self.assertRaises(TimeoutError):
            driver.tauri(Path.cwd(), argparse.Namespace(), {}, {}, {})
