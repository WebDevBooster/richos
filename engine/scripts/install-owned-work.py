#!/usr/bin/env python3
"""Install only the owned-outcome integration, retaining all existing settings.
Explicit install is separate from building/reviewing the worktree.
"""
import argparse
import importlib.util
import json
import hashlib
import os
from pathlib import Path
import stat
import tempfile
import subprocess


def ignore_local_config(root):
    # Machine paths do not belong in an adopter's commits. Keep the exclusion
    # local to Git; do not add another entry to the repository root.
    result = subprocess.run(['git', '-C', str(root), 'rev-parse', '--git-path', 'info/exclude'],
                            capture_output=True, text=True)
    if result.returncode == 0:
        tracked = subprocess.run(['git', '-C', str(root), 'ls-files', '--error-unmatch',
                                  '--', '.claude/owned-work.json'], capture_output=True)
        if tracked.returncode == 0:
            raise ValueError('Machine-specific .claude/owned-work.json is tracked; untrack it before adopting this workspace')
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


# Keep repository settings identical across machines and checkout locations.
# The engine installer owns this per-user pointer; never aim it at this script's
# checkout as a side effect of workspace adoption.
ENGINE_COMMAND_ROOT = '${CLAUDE_CONFIG_DIR:-$HOME/.claude}/richos-engine/scripts/lib'
DISPATCH_COMMAND = 'python3 "' + ENGINE_COMMAND_ROOT + '/owned-dispatch.py" "${CLAUDE_PROJECT_DIR:-$PWD}"'


def write_settings(path, data):
    """Atomic readable settings, preserving the operator's existing file mode."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            os.fchmod(output.fileno(), mode)
            json.dump(data, output, ensure_ascii=False, indent=2)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


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
        for event, mode in [('UserPromptSubmit', 'capture'), ('SessionStart', 'capture'), ('SessionStart', 'audit'), ('Stop', 'audit'), ('StopFailure', 'audit'), ('PermissionRequest', 'permission'), ('PreToolUse', 'question'), ('PreToolUse', 'tool'), ('Notification', 'observe')]:
            command = 'python3 "' + ENGINE_COMMAND_ROOT + '/owned-session.py" ' + mode
            groups = hooks.setdefault(event, [])
            found = [h for group in groups for h in group.get('hooks', []) if 'lib/owned-session.py' in h.get('command', '') and h['command'].endswith(' ' + mode)]
            config = {'type': 'command', 'command': command, 'timeout': 3900 if mode == 'audit' else 180 if mode in ('question', 'permission') else 15}
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
        dispatch = script.with_name('owned-dispatch.py')
        dispatch_command = DISPATCH_COMMAND
        groups = hooks.setdefault('PreToolUse', [])
        found = [h for group in groups if group.get('matcher') == 'Agent' for h in group.get('hooks', []) if 'lib/owned-dispatch.py' in h.get('command', '')]
        dispatch_hook = {'type': 'command', 'command': dispatch_command, 'timeout': 240}
        if found:
            for hook in found:
                hook.clear(); hook.update(dispatch_hook)
        else:
            groups.append({'matcher': 'Agent', 'hooks': [dispatch_hook]})
        ignore_local_config(root)
        # Hook first, ownership marker second. A crash cannot make the engine
        # skip while no direct adapter hook has been installed.
        write_settings(target, original)
        owned.atomic(root / owned.CONFIG, {'version': 1, 'enabled': True, 'runner': str(binary),
                    'decision_policy': 'dependency', 'permission_policy': permission_policy,
                    'dispatch_owner': 'adapter', 'dispatch_command': dispatch_command,
                    'dispatch_script_sha256': hashlib.sha256(dispatch.read_bytes()).hexdigest()})
    return target


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('workspace')
    p.add_argument('runner')
    p.add_argument('--permission-policy', choices=['native', 'deny'], default=None,
                   help='Native first recovers using existing permissions and exposes real prompts only after source-bound necessity review (default). Deny explicitly refuses every new permission request; it never grants authority. Reinstall preserves an explicit existing choice.')
    args = p.parse_args()
    print(install(args.workspace, args.runner, args.permission_policy))
