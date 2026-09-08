#!/usr/bin/env python3
"""Install only the owned-outcome integration, retaining all existing settings.
Explicit install is separate from building/reviewing the worktree.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess


def ignore_local_config(root):
    # Machine paths do not belong in an adopter's commits. Keep the exclusion
    # local to Git; do not add another entry to the repository root.
    result = subprocess.run(['git', '-C', str(root), 'rev-parse', '--git-path', 'info/exclude'],
                            capture_output=True, text=True)
    if result.returncode == 0:
        path = Path(result.stdout.strip())
        if not path.is_absolute():
            path = root / path
        rules = ['/.claude/owned-work.json', '/.claude/settings.local.owned-lock']
    else:
        path = root / '.claude/.gitignore'
        rules = ['owned-work.json', 'settings.local.owned-lock']
    path.parent.mkdir(parents=True, exist_ok=True)
    prior = path.read_text() if path.exists() else ''
    additions = [rule for rule in rules if rule not in prior.splitlines()]
    if additions:
        with path.open('a') as f:
            f.write(('\n' if prior and not prior.endswith('\n') else '') + '\n'.join(additions) + '\n')
            f.flush()
            os.fsync(f.fileno())

script = Path(__file__).resolve().parent / 'lib/owned-session.py'
spec = importlib.util.spec_from_file_location('owned', script)
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)


def install(workspace, runner, permission_policy=None):
    root = Path(workspace).resolve(strict=True)
    binary = Path(runner).resolve(strict=True)
    if not os.access(binary, os.X_OK):
        raise ValueError('Runner is not executable')
    target = root / '.claude/settings.local.json'
    prior_config = root / owned.CONFIG
    with owned.locked(target.with_suffix('.owned-lock')):
        if permission_policy is None:
            previous = json.loads(prior_config.read_text()) if prior_config.exists() else {}
            permission_policy = previous.get('permission_policy', 'native')
        if permission_policy not in ('native', 'deny'):
            raise ValueError('Permission policy must be native or deny')
        original = json.loads(target.read_text()) if target.exists() else {}
        # Preserve user/local permissions and unrelated hooks byte-semantically.
        hooks = original.setdefault('hooks', {})
        for event, mode in [('UserPromptSubmit', 'capture'), ('SessionStart', 'capture'), ('SessionStart', 'audit'), ('Stop', 'audit'), ('StopFailure', 'audit'), ('PermissionRequest', 'permission'), ('PreToolUse', 'question'), ('Notification', 'observe')]:
            command = 'python3 ' + shlex.quote(str(script)) + ' ' + mode
            groups = hooks.setdefault(event, [])
            found = [h for group in groups for h in group.get('hooks', []) if 'lib/owned-session.py' in h.get('command', '') and h['command'].endswith(' ' + mode)]
            config = {'type': 'command', 'command': command, 'timeout': 3900 if mode == 'audit' else 180 if mode == 'question' else 15}
            if mode == 'audit':
                config['asyncRewake'] = True
            if found:
                for h in found:
                    h.clear()
                    h.update(config)
            else:
                group = {'hooks': [config]}
                if mode == 'question': group['matcher'] = 'AskUserQuestion'
                if mode == 'observe': group['matcher'] = 'permission_prompt'
                groups.append(group)
        ignore_local_config(root)
        owned.atomic(target, original)
        owned.atomic(root / owned.CONFIG, {'version': 1, 'enabled': True, 'runner': str(binary), 'decision_policy': 'dependency', 'permission_policy': permission_policy})
    return target


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('workspace')
    p.add_argument('runner')
    p.add_argument('--permission-policy', choices=['native', 'deny'], default=None,
                   help='Native preserves real permission prompts (default). Deny explicitly refuses every new permission request; it never grants authority. Reinstall preserves an explicit existing choice.')
    args = p.parse_args()
    print(install(args.workspace, args.runner, args.permission_policy))
