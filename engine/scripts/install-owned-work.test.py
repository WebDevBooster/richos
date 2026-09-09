#!/usr/bin/env python3
"""Portable adoption checks. All engine pointers and workspaces are temporary."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-owned-work.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class PortableInstall(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='richos portable ')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.workspace = self.base/'workspace with spaces'
        self.workspace.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.workspace)], check=True)
        self.runner = self.base/'installed runner'
        self.runner.write_text('#!/bin/sh\nexit 0\n')
        self.runner.chmod(0o700)
        self.engine = self.base/'stable engine with spaces'
        self.lib = self.engine/'scripts/lib'
        self.lib.mkdir(parents=True)
        (self.engine/'scripts/hooks').mkdir()
        for name in ('owned-session.py', 'owned-dispatch.py'):
            shutil.copyfile(Path(installer.script).with_name(name), self.lib/name)
        self.config = self.base/'config with spaces $literal'
        self.config.mkdir()
        (self.config/'richos-engine').symlink_to(self.engine, target_is_directory=True)
        self.env = dict(os.environ, CLAUDE_CONFIG_DIR=str(self.config), CLAUDE_PROJECT_DIR=str(self.workspace))

    def settings(self):
        return self.workspace/'.claude/settings.local.json'

    def install(self):
        installer.install(self.workspace, self.runner)
        return json.loads(self.settings().read_text())

    def verify(self):
        policy = Path(installer.script).with_name('owned-work-policy.sh')
        return subprocess.run(['bash', '-c', '. "$1"; SCRIPT_DIR="$2"; owned_work_adapter_dispatch_installed "$3"',
                               'bash', str(policy), str(self.engine/'scripts/hooks'), str(self.workspace)],
                              cwd=self.workspace, env=self.env, capture_output=True).returncode == 0

    def test_migration_is_readable_portable_idempotent_and_preserves_unrelated_settings(self):
        original = {'permissions': {'allow': ['Read', 'Bash(git status:*)'], 'deny': ['Bash(rm:*)']},
                    'env': {'CUSTOM': 'unchanged'}, 'custom': [1, {'keep': True}],
                    'hooks': {'Stop': [{'matcher': '*', 'hooks': [
                        {'type': 'command', 'command': 'echo keep', 'timeout': 9},
                        {'type': 'command', 'command': 'python3 /Users/old/worktree/engine/scripts/lib/owned-session.py audit'}]}],
                        'PreToolUse': [{'matcher': 'Agent', 'hooks': [{'type': 'command',
                            'command': 'python3 /Users/old/worktree/engine/scripts/lib/owned-dispatch.py /Users/old/project'}]}]}}
        self.settings().parent.mkdir()
        self.settings().write_text(json.dumps(original))
        self.settings().chmod(0o640)
        settings = self.install()
        for key in ('permissions', 'env', 'custom'):
            self.assertEqual(settings[key], original[key])
        self.assertEqual(settings['hooks']['Stop'][0]['hooks'][0], original['hooks']['Stop'][0]['hooks'][0])
        text = self.settings().read_text()
        self.assertNotIn('/Users/', text)
        self.assertNotIn(str(self.base), text)
        self.assertIn('\n  "permissions":', text)
        self.assertEqual(self.settings().stat().st_mode & 0o777, 0o640)
        self.install()
        self.assertEqual(self.settings().read_text(), text)
        self.assertTrue(self.verify())
        ignored = subprocess.run(['git', '-C', str(self.workspace), 'check-ignore', '.claude/owned-work.json'], capture_output=True)
        self.assertEqual(ignored.returncode, 0)

    def test_real_shell_resolves_pointer_and_current_workspace_after_move(self):
        settings = self.install()
        moved = self.base/'moved workspace $literal `false`'
        self.workspace.rename(moved)
        self.workspace = moved
        self.env['CLAUDE_PROJECT_DIR'] = str(moved)
        commands = [hook['command'] for groups in settings['hooks'].values() for group in groups for hook in group['hooks']]
        self.assertEqual(len(commands), 10)
        fake_bin = self.base/'probe bin'
        fake_bin.mkdir()
        probe = fake_bin/'python3'
        probe.write_text('#!'+sys.executable+'\nimport json,os,sys\nprint(json.dumps({"args":sys.argv[1:],"cwd":os.getcwd()}))\n')
        probe.chmod(0o700)
        env = dict(self.env, PATH=str(fake_bin)+os.pathsep+os.environ['PATH'])
        for command in commands:
            result = subprocess.run(['bash', '-c', command], cwd=moved, env=env, capture_output=True, text=True, check=True)
            observed = json.loads(result.stdout)
            self.assertEqual(observed['cwd'], str(moved))
            self.assertTrue(observed['args'][0].startswith(str(self.config/'richos-engine/scripts/lib')))
            if 'owned-dispatch.py' in command:
                self.assertEqual(observed['args'][1], str(moved))
        env.pop('CLAUDE_PROJECT_DIR', None)
        command = installer.DISPATCH_COMMAND
        result = subprocess.run(['bash', '-c', command], cwd=moved, env=env, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)['args'][1], str(moved))
        self.assertTrue(self.verify())

    def test_home_pointer_fallback_and_dispatch_verifier_detects_runtime_drift(self):
        self.install()
        home = self.base/'different home'
        home.mkdir()
        (home/'.claude').symlink_to(self.config, target_is_directory=True)
        self.env.pop('CLAUDE_CONFIG_DIR', None)
        self.env['HOME'] = str(home)
        self.assertTrue(self.verify())
        with (self.lib/'owned-dispatch.py').open('a') as output:
            output.write('\n# changed installed runtime\n')
        self.assertFalse(self.verify())

    def test_tracked_machine_config_is_refused_before_settings_change(self):
        self.settings().parent.mkdir()
        self.settings().write_text('{"env":{"KEEP":"same"}}\n')
        marker = self.workspace/'.claude/owned-work.json'
        marker.write_text('{}')
        subprocess.run(['git', '-C', str(self.workspace), 'add', '.claude/owned-work.json'], check=True)
        before = self.settings().read_bytes()
        with self.assertRaisesRegex(ValueError, 'Machine-specific .* is tracked'):
            self.install()
        self.assertEqual(self.settings().read_bytes(), before)
        self.assertEqual(marker.read_text(), '{}')

    def test_verifier_never_evaluates_project_command(self):
        self.install()
        marker = self.workspace/'.claude/owned-work.json'
        config = json.loads(marker.read_text())
        config['dispatch_command'] = installer.DISPATCH_COMMAND+'; touch injected'
        marker.write_text(json.dumps(config))
        self.assertFalse(self.verify())
        self.assertFalse((self.workspace/'injected').exists())


if __name__ == '__main__':
    unittest.main()
