import argparse
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

from common import Refusal, run, shellcheck
import driver
import rust
import state


class Execution(unittest.TestCase):
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
             patch('driver.fcntl.flock', side_effect=AssertionError('parent lock probe')), \
             patch('driver.os.getloadavg', side_effect=AssertionError('parent load probe')):
            driver.external_preflight(Path('/nonexistent-state'))

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

    def test_green_state_and_changes(self):
        with tempfile.TemporaryDirectory(prefix='lint-state-') as tmp:
            directory = Path(tmp)
            root = directory / 'checkout'
            root.mkdir()
            args = argparse.Namespace(state_dir=directory, nightly=True, bootstrap=False, lower=False)
            rows = {'src.rs': {'language': 'rust', 'role': 'production'}}
            calls = []
            with patch('driver.rust.tauri_inputs', return_value='first') as inputs, \
                 patch('driver.rust.collect', side_effect=lambda *a: (calls.append(a) or ({}, []))), \
                 patch('driver.enforce'), patch('driver.checked', return_value='revision'):
                driver.tauri(root, args, rows, {}, {})
                driver.tauri(root, args, rows, {}, {})
                self.assertEqual(len(calls), 1)
                for changed in ('core-changed', 'tauri-changed', 'toolchain-changed', 'lint-changed'):
                    inputs.return_value = changed
                    driver.tauri(root, args, rows, {}, {})
                self.assertEqual(len(calls), 5)
                path = directory / 'lint-tauri-green.json'
                before = path.read_bytes()
                inputs.return_value = 'timeout-inputs'
                with patch('driver.rust.collect', side_effect=subprocess.TimeoutExpired('cargo', 180)), self.assertRaises(subprocess.TimeoutExpired):
                    driver.tauri(root, args, rows, {}, {})
                self.assertEqual(path.read_bytes(), before)
                path.write_text('corrupt')
                driver.tauri(root, args, rows, {}, {})
                self.assertTrue(state.green(path, 'timeout-inputs'))
            with self.assertRaises(Refusal):
                state.save(root / 'green.json', 'x', 'revision', root)
