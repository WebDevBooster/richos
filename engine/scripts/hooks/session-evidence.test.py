"""Regression coverage for the live session failures, with synthetic inputs."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
HOOKS = ROOT / 'engine/scripts/hooks'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


shell = load('shell_evidence', HOOKS / 'shell-evidence.py')
ingress = load('ingress', HOOKS / 'commit-ceo-inputs.py')
manifest = load('manifest', HOOKS / 'turn-manifest.py')
rust = load('rust_summary', ROOT / 'app/scripts/rust-test-summary.py')


class SessionEvidence(unittest.TestCase):
    def rewrite(self, command):
        payload = {'tool_name': 'Bash', 'tool_input': {'command': command, 'timeout': 4000, 'run_in_background': True}}
        output = shell.rewrite(payload)['hookSpecificOutput']
        self.assertNotIn('permissionDecision', output)
        self.assertEqual(output['updatedInput']['timeout'], 4000)
        self.assertTrue(output['updatedInput']['run_in_background'])
        return output['updatedInput']['command']

    def test_original_failures_are_reproduced_and_fixed_in_bash_and_zsh(self):
        for interpreter in ('/bin/bash', '/bin/zsh'):
            for command in ('false | tail -1', 'false; echo finished',
                            "python3 -c 'raise SystemExit(7)' 2>&1 | head -9", 'definitely_missing_test_command_xyz | tail -3'):
                with self.subTest(shell=interpreter, command=command):
                    old = subprocess.run([interpreter, '-c', command], capture_output=True)
                    self.assertEqual(old.returncode, 0)
                    new = subprocess.run([interpreter, '-c', self.rewrite(command)], capture_output=True)
                    self.assertNotEqual(new.returncode, 0)
                    self.assertNotIn(b'finished', new.stdout)

    def test_success_and_explicit_failure_handling_work(self):
        for cmd in ('printf hello | cat', 'if false; then exit 9; else printf expected; fi', 'false || printf expected'):
            result = subprocess.run(['/bin/bash', '-c', self.rewrite(cmd)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rewriting_is_idempotent_and_non_bash_is_unchanged(self):
        rewritten = self.rewrite('printf hello')
        self.assertEqual(shell.rewrite({'tool_name': 'Bash', 'tool_input': {'command': rewritten}}), {})
        self.assertEqual(shell.rewrite({'tool_name': 'Read', 'tool_input': {'file_path': '/tmp/doc'}}), {})

    def test_real_wrapper_and_registration(self):
        p = subprocess.run(['bash', str(HOOKS / 'shell-evidence.sh')], input=json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'false | tail -1'}}), text=True, capture_output=True)
        self.assertEqual(p.returncode, 0)
        self.assertTrue(json.loads(p.stdout)['hookSpecificOutput']['updatedInput']['command'].startswith(shell.PREFIX))
        config = json.loads((ROOT / 'engine/hooks/hooks.json').read_text())
        matches = [(e, g.get('matcher')) for e, groups in config['hooks'].items() for g in groups
                   for h in g['hooks'] if 'shell-evidence.sh' in h.get('command', '')]
        self.assertEqual(matches, [('PreToolUse', 'Bash')])

    def test_task_notification_does_not_become_a_handover(self):
        raw = '<task-notification><output-file>/tmp/claude-501/project/session/tasks/id.output</output-file></task-notification>'
        self.assertEqual(ingress.candidates(raw), [])
        self.assertIn(('/tmp/real-spec.md', 'absolute'), ingress.candidates(raw + '\nPlease read /tmp/real-spec.md'))

    def test_root_and_directories_do_not_reach_ledger(self):
        with tempfile.TemporaryDirectory() as tmp:
            payload = {'prompt': f'Look at `/` and `{tmp}`', 'cwd': tmp, 'session_id': 'fixture'}
            env = dict(os.environ, RICHOS_INGRESS_STATE_DIR=tmp)
            run = subprocess.run(['python3', str(HOOKS / 'commit-ceo-inputs.py')], input=json.dumps(payload), text=True, capture_output=True, env=env)
            self.assertEqual(run.returncode, 0, run.stderr)
            result = json.loads(run.stdout)
            self.assertEqual(result['reported'], [])
            self.assertEqual(result['refused'], [])
            self.assertEqual(json.loads((Path(tmp) / 'ceo-inputs.jsonl').read_text())['reported'], [])

    def test_historical_noise_is_retired_but_real_unheld_file_remains(self):
        script = (HOOKS / 'notice-ceo-inputs-unheld.sh').read_text()
        # Execute the actual embedded reader over the same historical ledger shape.
        code = script.split("UNRESOLVED=\"$(LEDGER=\"$LEDGER\" python3 -c '\n", 1)[1].split("\n' 2>/dev/null)", 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            artifact = path / 'tmp/claude-501/project/session/tasks/id.output'
            artifact.parent.mkdir(parents=True)
            artifact.write_text('generated result')
            real = path / 'real-spec.md'
            real.write_text('real document')
            ledger = path / 'ledger.jsonl'
            ledger.write_text(json.dumps({'reported': ['/', tmp, str(artifact), str(real)]}) + '\n')
            run = subprocess.run(['python3', '-c', code], env=dict(os.environ, LEDGER=str(ledger)), capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout.count('UNHELD\t'), 1, run.stdout)
            self.assertIn(str(real), run.stdout)

    def test_manifest_does_not_call_unverified_bash_output_ok(self):
        result = {'content': 'a failing test was hidden by a pipeline', 'is_error': False}
        self.assertEqual(manifest.status_of(result, 'Bash')[0], 'RETURNED')
        self.assertEqual(manifest.status_of(dict(result, is_error=True), 'Bash')[0], 'ERROR')
        self.assertIn('not verified', manifest.render([('id', 'Bash')], {'id': result}))

    def test_rust_doc_tests_are_counted_separately(self):
        text = 'Running unittests\ntest result: ok. 932 passed; 0 failed; 4 ignored;\n   Doc-tests example\ntest result: ok. 5 passed; 0 failed; 0 ignored;\n'
        result = rust.summarize(text)
        self.assertEqual(result['ordinary']['total'], 936)
        self.assertEqual(result['ordinary']['passed'], 932)
        self.assertEqual(result['documentation']['passed'], 5)
        self.assertFalse(result['process_exit_verified'])
        with self.assertRaises(ValueError):
            rust.summarize('error: Cargo.toml not found')


if __name__ == '__main__':
    unittest.main()
