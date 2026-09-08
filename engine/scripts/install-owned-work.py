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

script = Path(__file__).resolve().parent / 'lib/owned-session.py'
spec = importlib.util.spec_from_file_location('owned', script)
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)


def install(workspace, runner):
    root = Path(workspace).resolve(strict=True)
    binary = Path(runner).resolve(strict=True)
    if not os.access(binary, os.X_OK):
        raise ValueError('Runner is not executable')
    target = root / '.claude/settings.local.json'
    with owned.locked(target.with_suffix('.owned-lock')):
        original = json.loads(target.read_text()) if target.exists() else {}
        # Preserve user/local permissions and unrelated hooks byte-semantically.
        hooks = original.setdefault('hooks', {})
        for event, mode in [('UserPromptSubmit', 'capture'), ('SessionStart', 'capture'), ('SessionStart', 'audit'), ('Stop', 'audit'), ('StopFailure', 'audit')]:
            command = 'python3 ' + shlex.quote(str(script)) + ' ' + mode
            groups = hooks.setdefault(event, [])
            found = [h for group in groups for h in group.get('hooks', []) if 'lib/owned-session.py' in h.get('command', '') and h['command'].endswith(' ' + mode)]
            config = {'type': 'command', 'command': command, 'timeout': 3900 if mode == 'audit' else 15}
            if mode == 'audit':
                config['asyncRewake'] = True
            if found:
                for h in found:
                    h.clear()
                    h.update(config)
            else:
                groups.append({'hooks': [config]})
        owned.atomic(target, original)
        owned.atomic(root / owned.CONFIG, {'version': 1, 'enabled': True, 'runner': str(binary), 'decision_policy': 'dependency'})
    return target


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('workspace')
    p.add_argument('runner')
    args = p.parse_args()
    print(install(args.workspace, args.runner))
