#!/usr/bin/env python3
"""The operator probes, inside a disposable test VM guest (run by run-probes.py, never on a host).

Operator back-end spec r3 §5. Each probe is one short `claude` session driven over
stream-json exactly as the app will drive his lead, with its CONTROL in the same run. A probe
whose control does not behave as its premise says is reported PREMISE-FALSE, loudly, and never
as a pass. Results: `<payload>/results/<probe>.json` (verdict, measurements), plus the redacted
frames of every session (`<probe>-<session>.jsonl`) and `summary.json`.

Nothing here reads or records a credential. Frames are written with account fields removed, and
environments are recorded as NAMES only.

Python 3.9 compatible: this runs under the guest's /usr/bin/python3.
"""
import argparse
import json
import os
from pathlib import Path
import pty
import queue
import re
import select
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid

GUEST_CLAUDE = '/Users/admin/.local/bin/claude'
# The spec's allowlist (r3 (i)), captured by `enable.sh` from his terminal.
ALLOWLIST = ['PATH', 'LANG', 'USER', 'LOGNAME', 'SHELL', 'JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT',
             'HOMEBREW_PREFIX', 'HOMEBREW_CELLAR', 'HOMEBREW_REPOSITORY', 'INFOPATH', 'GIT_EDITOR',
             'COREPACK_ENABLE_AUTO_PIN']
# The harness's one addition, stated: `claude` updates itself, and a lead that updated itself
# mid-probe would stop being the version this run records (testvm/lib.sh, TESTVM_CLAUDE_PIN).
HARNESS_PIN = {'DISABLE_AUTOUPDATER': '1'}
PROBE_MODEL = 'sonnet'
UNIQUE_CLAUDE_MD = 'The fixture watchword is PERIWINKLE-4417.'
UNIQUE_MEMORY = 'The fixture memory token is AMBER-2291.'
ACCOUNT_KEYS = {'account', 'email', 'emailAddress', 'organization', 'organizationName', 'organizationUuid',
                'accountUuid', 'subscriptionType', 'oauthAccount'}


# ---------------------------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------------------------

def now():
    return time.time()


def run(args, env=None, cwd=None, timeout=120, input_text=None):
    r = subprocess.run(args, env=env, cwd=cwd, timeout=timeout, input=input_text, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return r.returncode, r.stdout, r.stderr


def redact(value):
    """Drop account fields anywhere in a frame, and anything shaped like an email address."""
    if isinstance(value, dict):
        return {k: ('<removed>' if k in ACCOUNT_KEYS else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    if isinstance(value, str):
        return re.sub(r'[\w.+-]+@[\w-]+\.[\w.-]+', '<email>', value)
    return value


def slug(path):
    return re.sub(r'[^A-Za-z0-9]', '-', str(path))


class Paths(object):
    def __init__(self, payload):
        self.payload = Path(payload)
        self.home = self.payload / 'home'
        self.claude_dir = self.home / '.claude'
        self.ab = self.home / 'ab'
        self.market = self.ab / 'richos'
        self.engine = self.market / 'richos' / 'engine'
        self.entity = self.ab / 'femcboost'
        self.remote = self.payload / 'remote.git'
        self.results = self.payload / 'results'
        self.work = self.payload / 'work'
        self.contract = self.work / 'operator-contract.md'
        self.stub_mcp = self.work / 'operator_stub_mcp.py'
        self.stub_calls = self.work / 'operator-stub-calls.jsonl'
        self.app_engine_plugin = self.work / 'app-engine-plugin'


# ---------------------------------------------------------------------------------------------
# the stand-in for the app's report server: records calls, answers every report
# ---------------------------------------------------------------------------------------------

STUB_MCP = r'''
import json, sys, time
LOG = sys.argv[1]
def reply(i, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": i, "result": result}) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    try:
        m = json.loads(line)
    except Exception:
        continue
    i, method = m.get("id"), m.get("method")
    if i is None:
        continue
    if method == "initialize":
        reply(i, {"protocolVersion": m.get("params", {}).get("protocolVersion", "2025-06-18"),
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "richos_operator", "version": "probe"}})
    elif method == "tools/list":
        reply(i, {"tools": [{"name": "report", "description": "Tell the CEO something.",
                             "inputSchema": {"type": "object", "properties": {"kind": {"type": "string"},
                                             "text": {"type": "string"}}, "required": ["kind", "text"]}}]})
    elif method == "tools/call":
        with open(LOG, "a") as f:
            f.write(json.dumps({"at": time.time(), "params": m.get("params")}) + "\n")
        reply(i, {"content": [{"type": "text", "text": "{\"recorded\": true}"}], "isError": False})
    else:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": i, "error": {"code": -32601, "message": "no"}}) + "\n")
        sys.stdout.flush()
'''


# ---------------------------------------------------------------------------------------------
# the fixture: his entity, his memory, his engine, a repository with an SSH remote
# ---------------------------------------------------------------------------------------------

def login_environment():
    """The guest's own terminal environment: a login shell's, as enable.sh would capture it."""
    code, out, err = run(['/bin/zsh', '-lic', 'env -0'], timeout=60)
    if code != 0:
        raise RuntimeError('the guest login shell could not be read: ' + err)
    env = {}
    for item in out.split('\0'):
        if '=' in item:
            k, v = item.split('=', 1)
            env[k] = v
    return env


def stored_environment(login):
    """What enable.sh stores (r3 (i)): the allowlisted names present in his terminal."""
    stored = {k: login[k] for k in ALLOWLIST if k in login}
    stored.setdefault('LANG', 'en_US.UTF-8')
    return stored


def git(cwd, *args):
    code, out, err = run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgSign=false',
                          '-c', 'user.name=Probe', '-c', 'user.email=probe@example.invalid'] + list(args),
                         cwd=str(cwd), timeout=120)
    if code != 0:
        raise RuntimeError('git %s: %s' % (' '.join(args), err))
    return out.strip()


def setup_fixture(p, record):
    for d in (p.results, p.work, p.ab):
        d.mkdir(parents=True, exist_ok=True)
    # ---- the engine, as a directory marketplace, as his terminal registers it --------------
    if not p.engine.is_dir():
        p.market.mkdir(parents=True, exist_ok=True)
        code, _, err = run(['tar', '-xf', str(p.payload / 'probes' / 'engine.tar'), '-C', str(p.market)])
        if code != 0:
            raise RuntimeError('engine archive did not unpack: ' + err)
    # ---- the entity: orchestration.config, CLAUDE.md with a unique line, two agents --------
    p.entity.mkdir(parents=True, exist_ok=True)
    (p.entity / 'orchestration.config').write_text(
        '# Probe fixture entity.\nMODEL_TIERS="fable > opus > sonnet > haiku"\nMODEL_CEILING="opus"\n'
        'ALLOWED_MODELS="opus sonnet haiku"\n')
    (p.entity / 'CLAUDE.md').write_text('# Probe fixture\n\n' + UNIQUE_CLAUDE_MD + '\n')
    agents = p.entity / '.claude' / 'agents'
    agents.mkdir(parents=True, exist_ok=True)
    for name in ('alpha', 'beta'):
        (agents / (name + '.md')).write_text(
            '---\nname: %s\ndescription: Probe teammate %s. Runs exactly the shell command its brief names.\n'
            'model: sonnet\ntools: Bash\n---\nYou are a probe teammate. Run exactly the one Bash command your '
            'brief names, in the foreground, then reply with the single word finished.\n' % (name, name))
    (p.entity / '.claude' / 'settings.local.json').write_text(json.dumps(
        {'env': {'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS': '1'}}, indent=1) + '\n')
    (p.entity / '.gitignore').write_text('/.claude/worktrees/*\n')
    if not (p.entity / '.git').is_dir():
        git(p.entity, 'init', '-q', '-b', 'main')
        git(p.entity, 'add', '-A')
        git(p.entity, 'commit', '-q', '-m', 'Probe fixture')
    # ---- his auto memory ----------------------------------------------------------------------
    memory = p.claude_dir / 'projects' / slug(p.entity) / 'memory'
    memory.mkdir(parents=True, exist_ok=True)
    (memory / 'MEMORY.md').write_text('# Memory\n\n- ' + UNIQUE_MEMORY + '\n')
    # ---- user settings: the engine plugin, and no first-run prompts ---------------------------
    settings = {
        'extraKnownMarketplaces': {'richos-local': {'source': {'source': 'directory', 'path': str(p.market)}}},
        'enabledPlugins': {'richos-engine@richos-local': True},
        'skipDangerousModePermissionPrompt': True,
    }
    (p.claude_dir / 'settings.json').write_text(json.dumps(settings, indent=1) + '\n')
    config_path = p.home / '.claude.json'
    config = json.loads(config_path.read_text()) if config_path.exists() else {}
    config.update({'hasCompletedOnboarding': True, 'theme': 'dark', 'bypassPermissionsModeAccepted': True})
    config.setdefault('projects', {})[str(p.entity)] = {'hasTrustDialogAccepted': True,
                                                         'hasCompletedProjectOnboarding': True}
    config_path.write_text(json.dumps(config, indent=1) + '\n')
    # ---- the operator contract and the report server stand-in -------------------------------
    p.contract.write_text('You are the operator lead for this fixture. CLAUDE.md wins on any question of '
                          'substance. Use richos_operator.report to tell the CEO about a land, a file or a question.\n')
    p.stub_mcp.write_text(STUB_MCP)
    plugin = p.app_engine_plugin / '.claude-plugin'
    plugin.mkdir(parents=True, exist_ok=True)
    (plugin / 'plugin.json').write_text(json.dumps({'name': 'richos-app-engine', 'version': '1.2.0'}) + '\n')
    # ---- a repository with an SSH fixture remote (P8) ----------------------------------------
    ssh = Path('/Users/admin/.ssh')
    ssh.mkdir(mode=0o700, exist_ok=True)
    key = ssh / 'id_probe'
    if not key.exists():
        code, _, err = run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key), '-C', 'operator-probe'])
        if code != 0:
            raise RuntimeError('ssh-keygen: ' + err)
        with open(ssh / 'authorized_keys', 'a') as f:
            f.write((ssh / 'id_probe.pub').read_text())
        os.chmod(str(ssh / 'authorized_keys'), 0o600)
        with open(ssh / 'config', 'a') as f:
            f.write('\nHost probe-remote\n  HostName 127.0.0.1\n  User admin\n  IdentityFile %s\n'
                    '  StrictHostKeyChecking accept-new\n  UserKnownHostsFile %s\n' % (key, ssh / 'probe_known_hosts'))
    if not p.remote.is_dir():
        git(p.payload, 'init', '-q', '--bare', str(p.remote))
        git(p.entity, 'remote', 'add', 'origin', 'probe-remote:' + str(p.remote))
    # ---- the plugin, installed the way his terminal installed it ------------------------------
    env = dict(os.environ, HOME=str(p.home), **HARNESS_PIN)
    env.pop('CLAUDE_CONFIG_DIR', None)
    for args in (['plugin', 'marketplace', 'add', str(p.market)], ['plugin', 'install', 'richos-engine@richos-local']):
        code, out, err = run([GUEST_CLAUDE] + args, env=env, cwd=str(p.entity), timeout=180)
        record.setdefault('plugin_install', []).append({'args': args, 'exit': code, 'said': (out + err)[-600:]})


# ---------------------------------------------------------------------------------------------
# survey: what the guest has, recorded before any probe is believed
# ---------------------------------------------------------------------------------------------

def survey(p):
    facts = {}
    for label, args in [('python3', ['/usr/bin/python3', '--version']), ('git', ['git', '--version']),
                        ('claude', [GUEST_CLAUDE, '--version']), ('sw_vers', ['sw_vers']),
                        ('launchctl_ssh_auth_sock', ['/bin/launchctl', 'getenv', 'SSH_AUTH_SOCK']),
                        ('darwin_user_temp_dir', ['getconf', 'DARWIN_USER_TEMP_DIR']),
                        ('whoami', ['whoami'])]:
        try:
            code, out, err = run(args, timeout=60)
            facts[label] = {'exit': code, 'out': out.strip()[-400:], 'err': err.strip()[-200:]}
        except Exception as error:  # noqa: BLE001
            facts[label] = {'error': repr(error)}
    login = login_environment()
    facts['login_env_names'] = sorted(login)
    facts['login_path'] = login.get('PATH')
    for tool in ('python3', 'git', 'gh', 'java', 'node', 'brew'):
        code, out, _ = run(['/bin/zsh', '-lc', 'command -v ' + tool], timeout=30)
        facts['which_' + tool] = out.strip() if code == 0 else None
    facts['credentials_bytes'] = (p.claude_dir / '.credentials.json').stat().st_size \
        if (p.claude_dir / '.credentials.json').exists() else 0
    code, out, err = run(['ssh', '-o', 'BatchMode=yes', 'probe-remote', 'true'], timeout=60)
    facts['ssh_probe_remote'] = {'exit': code, 'err': err.strip()[-300:]}
    return facts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--payload', required=True)
    ap.add_argument('--engine-commit', required=True)
    ap.add_argument('--only', default='')
    ap.add_argument('--survey', action='store_true')
    ap.add_argument('--probe-timeout', type=int, default=900)
    a = ap.parse_args()
    p = Paths(a.payload)
    p.results.mkdir(parents=True, exist_ok=True)
    setup = {'engine_commit': a.engine_commit}
    try:
        setup_fixture(p, setup)
    except Exception as error:  # noqa: BLE001
        setup['error'] = repr(error)
        (p.results / 'setup.json').write_text(json.dumps(setup, indent=1) + '\n')
        print('SETUP FAILED: ' + repr(error))
        return 2
    setup['survey'] = survey(p)
    (p.results / 'setup.json').write_text(json.dumps(setup, indent=1) + '\n')
    print(json.dumps(setup, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
