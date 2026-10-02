import argparse
import json
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

    def test_a_group_of_exiting_orphans_rejecting_the_signal_is_not_a_lint_refusal(self):
        # Nightly 20261002T171147Z-3893b3f9: "Lint refused: [Errno 1] Operation not permitted".
        # macOS answers killpg with EPERM while a group's orphaned members are being reaped;
        # alive() already counts that as present, and the signal that followed raised it.
        answers = {'probe': [PermissionError(1, 'Operation not permitted')]}
        def killpg(pid, sig):
            if sig == 0:
                raise answers['probe'].pop(0) if answers['probe'] else ProcessLookupError(3, 'No such process')
            raise PermissionError(1, 'Operation not permitted')
        with patch('common.os.killpg', side_effect=killpg):
            result, _ = run([sys.executable, '-c', 'pass'], cwd=Path.cwd(), timeout=10)
        self.assertEqual(result.returncode, 0)

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
            with patch('rust.run_cargo', return_value=(result, .1)), self.assertRaises(Refusal):
                rust.collect(Path.cwd(), [['cargo', 'clippy']])

    def fake_cargo(self, tmp, body):
        """A stand-in `cargo` that ends with one successful Clippy build in JSON."""
        path = Path(tmp) / 'cargo'
        path.write_text('#!/bin/sh\n' + body +
                        'echo \'{"reason":"compiler-artifact"}\'\n'
                        'echo \'{"reason":"build-finished","success":true}\'\n')
        path.chmod(0o755)
        return [[str(path)]]

    def test_compiler_errors_in_json_are_printed_when_compilation_fails(self):
        output = json.dumps({"reason": "compiler-message", "message": {
            "level": "error", "message": "wrong arguments", "rendered": "error[E0061]: wrong arguments at model_provisioning.rs:90"}})
        result = subprocess.CompletedProcess([], 1, output, "could not compile: 2 previous errors")
        with patch('rust.run_cargo', return_value=(result, .1)), \
                self.assertRaisesRegex(Refusal, "error\\[E0061\\].*model_provisioning.rs:90"):
            rust.collect(Path.cwd(), [['cargo', 'clippy']])

    def test_waiting_for_cargos_lock_is_not_clippys_time(self):
        # Audit R12: the Tauri cap counted Cargo's lock wait, so a Clippy queued behind another
        # build spent its cap before it started. Here the lock is held past the whole cap and
        # the work itself is two echo lines: Clippy must pass, and the wait must be reported.
        with tempfile.TemporaryDirectory(prefix='lint-cargo-lock-') as tmp:
            commands = self.fake_cargo(tmp, 'echo "    Blocking waiting for file lock on build directory" >&2\n'
                                            'sleep 4\n')
            self.assertEqual(rust.collect(Path(tmp), commands, time.monotonic() + 3), ({}, []))
            clock = {}
            rust.collect(Path(tmp), commands, time.monotonic() + 3, clock)
            self.assertGreaterEqual(clock['lock_wait'], 3.5)

    def test_clippys_own_work_past_the_cap_still_times_out(self):
        with tempfile.TemporaryDirectory(prefix='lint-cargo-work-') as tmp:
            commands = self.fake_cargo(tmp, 'exec sleep 60\n')
            with self.assertRaises(subprocess.TimeoutExpired):
                rust.collect(Path(tmp), commands, time.monotonic() + .5)

    def test_a_lock_held_past_the_hang_guard_is_refused_by_name(self):
        with tempfile.TemporaryDirectory(prefix='lint-cargo-hang-') as tmp:
            commands = self.fake_cargo(tmp, 'echo "    Blocking waiting for file lock on package cache" >&2\n'
                                            'exec sleep 60\n')
            with patch('rust.LOCK_WAIT_GUARD', .5), \
                    self.assertRaisesRegex(TimeoutError, "Cargo's lock was still held"):
                rust.collect(Path(tmp), commands, time.monotonic() + 30)

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
