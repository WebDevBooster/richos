#!/usr/bin/env python3
"""AX shell/deadline contracts against owned stub processes, never a VM."""
import json
import importlib.util
from unittest.mock import patch
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))


class Contracts(unittest.TestCase):
    def deadline(self, code, host=True):
        with tempfile.TemporaryDirectory(prefix='ax-contract-') as directory:
            env = dict(os.environ, TMPDIR=directory, HOME=directory, CLAUDE_CONFIG_DIR=directory)
            argv = [sys.executable, '-B', str(HERE/'ax-deadline.py')]
            if host:
                argv += ['--host']
            result = subprocess.run(argv + ['2', sys.executable, '-c', code],
                                    input='', text=True, capture_output=True, env=env, timeout=6)
            self.assertEqual(list(Path(directory).iterdir()), [], 'supervisor scratch must be removed')
            return result

    def test_preflight_timeout_classification_precedes_partial_output(self):
        r = self.deadline('import time;print("partial",flush=True);time.sleep(10)')
        self.assertEqual(r.returncode, 124)
        self.assertEqual(json.loads(r.stdout.splitlines()[0])['error'], 'preflight_deadline')
        self.assertIn('partial', r.stdout)

    def test_transport_and_guest_are_distinct(self):
        phase = 'import os,json,time;from pathlib import Path;'
        phase += 'p=Path(os.environ["TESTVM_AX_PHASE_FILE"]);'
        phase += 'p.write_text(p.read_text()+json.dumps({"phase":"transport","at":time.monotonic()})+"\\n");'
        for guest in (False, True):
            code = phase
            if guest:
                code += 'Path(os.environ["TESTVM_AX_LOG_FILE"]).write_text(json.dumps({"ax_phase":"guest"}));'
            r = self.deadline(code+'time.sleep(10)')
            self.assertEqual(r.returncode, 124)
            self.assertEqual(json.loads(r.stdout.splitlines()[0])['error'],
                             'guest_deadline' if guest else 'transport_deadline')

    def test_guest_timeout_and_owned_child_cleanup(self):
        r = self.deadline('import os,time;print("owned_pid="+str(os.getpid()),flush=True);time.sleep(10)', host=False)
        self.assertEqual(r.returncode, 124)
        self.assertEqual(json.loads(r.stdout.splitlines()[0])['error'], 'guest_deadline')
        pid = int(next(line.split('=')[1] for line in r.stdout.splitlines() if line.startswith('owned_pid=')))
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_nonzero_exit_preserved_and_timing_reported(self):
        r = self.deadline('import sys;print("evidence");sys.exit(7)')
        self.assertEqual(r.returncode, 7)
        self.assertEqual(r.stdout.strip(), 'evidence')
        timing = json.loads(r.stderr.splitlines()[-1])
        self.assertTrue(timing['ax_timing'])
        self.assertGreaterEqual(timing['total_seconds'], 0)

    def test_shell_preserves_structured_error_and_selector_parameters(self):
        with tempfile.TemporaryDirectory(prefix='ax-contract-') as directory:
            root = Path(directory)
            stub = root/'guest.sh'
            stub.write_text('#!/bin/sh\ncat > "$PROGRAM"\ncat "$FIXTURE"\n')
            stub.chmod(0o700)
            fixture = root/'fixture'
            fixture.write_text('{"meta":true,"nodes":1}\n{"error":"notfound","near_matches":[{"role":"AXCheckBox"}]}\n')
            env = dict(os.environ, TMPDIR=directory, HOME=directory, CLAUDE_CONFIG_DIR=directory,
                       TESTVM_ROOT=str(root/'state'), TESTVM_GUEST_EXEC=str(stub),
                       PROGRAM=str(root/'program'), FIXTURE=str(fixture))
            args = ['bash', str(HERE/'ax.sh'), 'fixture', 'click', '--app', 'Fixture',
                    '--id', 'route-choice', '--expect', 'value=1', '--json']
            r = subprocess.run(args, capture_output=True, text=True, env=env, timeout=22)
            self.assertEqual(r.returncode, 1, r.stdout+r.stderr)
            self.assertEqual(json.loads(r.stdout.splitlines()[0])['error'], 'notfound')
            params = json.loads((root/'program').read_text().splitlines()[0][len('var AX_PARAMS = '):-1])
            self.assertEqual(params['id'], 'route-choice')
            self.assertEqual(params['expect'], {'value':'1'})
            self.assertFalse(params['first'])
            self.assertFalse(list(root.glob('testvm-ax-*')))
            legacy = subprocess.run(args[:-3]+['--json'], capture_output=True, text=True, env=env, timeout=22)
            self.assertEqual(legacy.returncode, 1, legacy.stdout+legacy.stderr)
            legacy_params = json.loads((root/'program').read_text().splitlines()[0][len('var AX_PARAMS = '):-1])
            self.assertIsNone(legacy_params['expect'])
            (root/'program').unlink()
            bad = subprocess.run(args[:-3]+['--expect','unknown=1','--json'],
                                 capture_output=True, text=True, env=env, timeout=22)
            self.assertNotEqual(bad.returncode, 0)
            self.assertFalse((root/'program').exists(), 'invalid expectations must not reach guest')


    def test_consumer_uses_exact_names_and_preserves_json_failure(self):
        spec = importlib.util.spec_from_file_location('delta_walk', HERE/'delta-walk.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        walk = module.Walk.__new__(module.Walk)
        walk.vm = 'fixture'
        success = subprocess.CompletedProcess([], 0, '{"clicked":true}\n', '')
        with patch.object(module.subprocess, 'run', return_value=success) as invoke:
            walk.press('Scenario A')
            argv = invoke.call_args.args[0]
            self.assertNotIn('--first', argv)
            self.assertNotIn('--contains', argv)
            self.assertNotIn('--role', argv)
        failure = subprocess.CompletedProcess([], 1, '{"error":"notfound"}\n', 'unrelated prose')
        with patch.object(module.subprocess, 'run', return_value=failure):
            walk.optional_press('Missing')
        failure.stdout = '{"error":"blocked"}\n'
        with patch.object(module.subprocess, 'run', return_value=failure):
            with self.assertRaises(module.Failure) as caught:
                walk.optional_press('Missing')
            self.assertEqual(caught.exception.status, 'blocked')


if __name__ == '__main__':
    unittest.main()
