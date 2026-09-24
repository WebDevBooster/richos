#!/usr/bin/env python3
"""The operator probes, inside a disposable test VM guest (run by run-probes.py, never on a host).

Operator back-end spec r3 §5 (richos-hq docs/plans/2026-09-24-operator-back-end-spec-r3.md).
Each probe is one short `claude` session driven over stream-json the way the app will drive
his lead, with its CONTROL in the same run. Verdicts:

  PASS           the pass condition held AND the control behaved as its premise says
  FAIL           the control behaved, and the pass condition did not hold
  PREMISE-FALSE  the control did not behave as the premise says; nothing can be concluded
  NOT-RUN        something the probe needs is absent (named); nothing was concluded
  RECORDED       a measurement probe with no pass line (P11, P14): the numbers are the result
  ERROR          the harness itself failed; the traceback is recorded

Results: `<payload>/results/<probe>.json`, the redacted frames of every session
(`<probe>-<session>.jsonl`, account fields removed), and `summary.json`. Environments are
recorded as NAMES only; no value of any variable is written, except the few non-secret
facts a probe exists to read (CLAUDE_CODE_ENTRYPOINT, a pid, a path).

Python 3.9 compatible: this runs under the guest's /usr/bin/python3.
"""
import argparse
import fcntl
import glob
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import threading
import time
import traceback
import uuid

GUEST_CLAUDE = '/Users/admin/.local/bin/claude'
# The spec's allowlist (r3 (i)), captured by `enable.sh` from his terminal.
ALLOWLIST = ['PATH', 'LANG', 'USER', 'LOGNAME', 'SHELL', 'JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT',
             'HOMEBREW_PREFIX', 'HOMEBREW_CELLAR', 'HOMEBREW_REPOSITORY', 'INFOPATH', 'GIT_EDITOR',
             'COREPACK_ENABLE_AUTO_PIN']
# The harness's one addition, stated: `claude` updates itself, and a lead that updated itself
# mid-probe would stop being the version this run records (testvm/lib.sh, TESTVM_CLAUDE_PIN).
HARNESS_PIN = {'DISABLE_AUTOUPDATER': '1'}
# The app's own additions (r3 (i)): the claim id, and the supervisor's pid variable.
APP_NAMES = ['HOME', 'SSH_AUTH_SOCK', 'TMPDIR', 'RICHOS_OPERATOR_LEAD']
SUPERVISOR_NAMES = ['RICHOS_SESSION_PID']
# Names any Python adds to its own environment on macOS (operator_profile.rs,
# INTERPRETER_ADDED_NAMES, measured 2026-09-24).
INTERPRETER_NAMES = ['__CF_USER_TEXT_ENCODING', 'LC_CTYPE']
# Most probes measure the platform, not the model, so they run on the cheaper model. P7 runs
# on his own model at his own context size (r3 §5).
PROBE_MODEL = 'sonnet'
HIS_MODEL = 'claude-opus-5-5[1m]'
UNIQUE_CLAUDE_MD = 'The fixture watchword is PERIWINKLE-4417.'
UNIQUE_MEMORY = 'The fixture memory token is AMBER-2291.'
ACCOUNT_KEYS = {'account', 'email', 'emailAddress', 'organization', 'organizationName', 'organizationUuid',
                'accountUuid', 'subscriptionType', 'oauthAccount'}
HOOK_EVENTS = {'SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure',
               'Stop', 'StopFailure', 'SubagentStart', 'SubagentStop', 'Notification', 'PreCompact', 'PostCompact',
               'TeammateIdle', 'TaskCompleted'}


# =============================================================================================
# small helpers
# =============================================================================================

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


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def children_of(pid):
    """Direct children, by parent pid: processes this harness's own child created."""
    code, out, _ = run(['ps', '-A', '-o', 'pid=,ppid='], timeout=30)
    kids = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == str(pid):
            kids.append(int(parts[0]))
    return kids


def pgid_of(pid):
    try:
        return os.getpgid(pid)
    except OSError:
        return None


def names_file(path):
    try:
        return sorted(set(l.strip() for l in Path(path).read_text().splitlines() if l.strip()))
    except OSError:
        return None


# =============================================================================================
# the frame reading the app does (a port of operator_frames.rs and operator_profile.rs)
# =============================================================================================

def system_messages(stdout):
    def message(value):
        text = value.get('systemMessage') if isinstance(value, dict) else None
        return text if isinstance(text, str) and text.strip() else None
    try:
        value = json.loads(stdout.strip())
        m = message(value)
        return [m] if m else []
    except ValueError:
        pass
    found = []
    for line in stdout.splitlines():
        line = line.strip()
        if line.startswith('{'):
            try:
                m = message(json.loads(line))
            except ValueError:
                m = None
            if m:
                found.append(m)
    return found


def alarms_in(frame):
    if not isinstance(frame, dict) or frame.get('type') != 'system':
        return []
    sub = frame.get('subtype')
    if sub == 'hook_response':
        seen = []
        for text in system_messages(frame.get('stdout') or ''):
            if text not in seen:
                seen.append(text)
        return [{'text': t, 'frame': 'hook_response', 'hook_event': frame.get('hook_event'),
                 'hook_name': frame.get('hook_name')} for t in seen]
    if sub == 'informational':
        text = frame.get('content')
        if isinstance(text, str) and text.strip():
            return [{'text': text, 'frame': 'informational', 'level': frame.get('level')}]
    return []


def dedupe_key(text):
    text = text.strip()
    if ' says: ' in text:
        speaker, rest = text.split(' says: ', 1)
        if not re.search(r'\s', speaker) and speaker.split(':')[0] in HOOK_EVENTS:
            return rest.strip()
    return text


def parse_banner(text):
    """operator_profile::parse_banner: the person's short line first (what arrives as a
    systemMessage), then the model's long summary."""
    m = re.match(r'\s*RichOS engine (\S+): ENFORCEMENT ACTIVE for (.*?) \((\d+)/(\d+) guards, engine at (.*?), root via ',
                 text, re.S)
    if m:
        return {'version': m.group(1), 'engine_root': m.group(5), 'governing': m.group(2),
                'guard_count': int(m.group(3)), 'guard_expected': int(m.group(4))}
    m = re.match(r'\s*RichOS engine (\S+) ACTIVE\. Engine: (.*?)\. Governing: (.*?) \(resolved via .*?\)\. '
                 r'(?:.* )?(\d+)/(\d+) guards present', text, re.S)
    if not m:
        return None
    return {'version': m.group(1), 'engine_root': m.group(2), 'governing': m.group(3),
            'guard_count': int(m.group(4)), 'guard_expected': int(m.group(5))}


def init_check(init, banner, declared_engine):
    """The (b) init check, as operator_profile::init_check decides it (fences excluded: the
    engine has no fence status command yet, r3 §11 item 4)."""
    plugins = [x.get('name') for x in (init or {}).get('plugins') or []]
    if plugins.count('richos-engine') != 1:
        return 'refuse', 'richos-engine listed %d times' % plugins.count('richos-engine')
    if 'richos-app-engine' in plugins:
        return 'refuse', 'richos-app-engine loaded beside his'
    if 'mcp__richos_operator__report' not in ((init or {}).get('tools') or []):
        return 'refuse', 'no report tool'
    if not banner:
        return 'refuse', 'no ACTIVE banner'
    if '/.claude/plugins/cache/' in banner['engine_root'] or \
            os.path.realpath(banner['engine_root']) != os.path.realpath(declared_engine):
        return 'refuse', 'engine root %s' % banner['engine_root']
    if banner['guard_count'] != banner['guard_expected']:
        return 'refuse', 'guards %d/%d' % (banner['guard_count'], banner['guard_expected'])
    return 'open', None


# =============================================================================================
# the fixture: his entity, his memory, his engine, a repository with an SSH remote
# =============================================================================================

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
    if not p.engine.is_dir():
        p.market.mkdir(parents=True, exist_ok=True)
        code, _, err = run(['tar', '-xf', str(p.payload / 'probes' / 'engine.tar'), '-C', str(p.market)])
        if code != 0:
            raise RuntimeError('engine archive did not unpack: ' + err)
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
    memory = p.claude_dir / 'projects' / slug(p.entity) / 'memory'
    memory.mkdir(parents=True, exist_ok=True)
    (memory / 'MEMORY.md').write_text('# Memory\n\n- ' + UNIQUE_MEMORY + '\n')
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
    p.contract.write_text('You are the operator lead for this fixture. CLAUDE.md wins on any question of '
                          'substance. Use richos_operator.report to tell the CEO about a land, a file or a question.\n')
    p.stub_mcp.write_text(STUB_MCP)
    plugin = p.app_engine_plugin / '.claude-plugin'
    plugin.mkdir(parents=True, exist_ok=True)
    (plugin / 'plugin.json').write_text(json.dumps({'name': 'richos-app-engine', 'version': '1.2.0'}) + '\n')
    ssh = Path('/Users/admin/.ssh')
    ssh.mkdir(mode=0o700, exist_ok=True)
    key = ssh / 'id_probe'
    if not key.exists():
        code, _, err = run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key), '-C', 'operator-probe'])
        if code != 0:
            raise RuntimeError('ssh-keygen: ' + err)
        with open(str(ssh / 'authorized_keys'), 'a') as f:
            f.write((ssh / 'id_probe.pub').read_text())
        os.chmod(str(ssh / 'authorized_keys'), 0o600)
        with open(str(ssh / 'config'), 'a') as f:
            f.write('\nHost probe-remote\n  HostName 127.0.0.1\n  User admin\n  IdentityFile %s\n'
                    '  StrictHostKeyChecking accept-new\n  UserKnownHostsFile %s\n' % (key, ssh / 'probe_known_hosts'))
    if not p.remote.is_dir():
        git(p.payload, 'init', '-q', '--bare', str(p.remote))
        git(p.entity, 'remote', 'add', 'origin', 'probe-remote:' + str(p.remote))
        git(p.entity, 'push', '-q', '-u', 'origin', 'main')
    env = dict(os.environ, HOME=str(p.home), **HARNESS_PIN)
    env.pop('CLAUDE_CONFIG_DIR', None)
    for args in (['plugin', 'marketplace', 'add', str(p.market)], ['plugin', 'install', 'richos-engine@richos-local']):
        code, out, err = run([GUEST_CLAUDE] + args, env=env, cwd=str(p.entity), timeout=180)
        record.setdefault('plugin_install', []).append({'args': args, 'exit': code, 'said': (out + err)[-600:]})


def derive_ssh_auth_sock():
    """r3 (i): `launchctl getenv SSH_AUTH_SOCK`. From an ssh session in the guest that is empty,
    because ssh runs outside the GUI login's launchd domain (measured in the survey run); the
    app runs inside it. So the GUI session's own agent socket is found by its launchd path,
    owned by this user, and the method is recorded with the value."""
    code, out, _ = run(['/bin/launchctl', 'getenv', 'SSH_AUTH_SOCK'], timeout=30)
    if code == 0 and out.strip().startswith('/'):
        return out.strip(), 'launchctl getenv'
    mine = [s for s in glob.glob('/private/tmp/com.apple.launchd.*/Listeners') if os.stat(s).st_uid == os.getuid()]
    if len(mine) == 1:
        return mine[0], 'the GUI session launchd socket path (launchctl getenv is empty over ssh)'
    return None, 'not derivable (%d candidate sockets)' % len(mine)


def python3_for_supervisor(path):
    """operator_profile::resolve_python: the first python3 on the stored PATH that is not the
    xcrun shim."""
    for d in path.split(':'):
        c = os.path.join(d, 'python3')
        if d.startswith('/') and os.access(c, os.X_OK) and c != '/usr/bin/python3':
            return c
    return '/usr/bin/python3'


class Context(object):
    def __init__(self, p, timeout):
        self.p = p
        self.timeout = timeout
        self.login = login_environment()
        self.stored = {k: self.login[k] for k in ALLOWLIST if k in self.login}
        self.stored.setdefault('LANG', 'en_US.UTF-8')
        self.ssh_auth_sock, self.ssh_method = derive_ssh_auth_sock()
        code, out, _ = run(['getconf', 'DARWIN_USER_TEMP_DIR'])
        self.tmpdir = out.strip()
        self.python = python3_for_supervisor(self.stored['PATH'])

    def lead_env(self, claim='probe-claim'):
        """operator_profile::environment, built from empty, plus the harness pin."""
        env = dict(self.stored)
        env['HOME'] = str(self.p.home)
        if self.ssh_auth_sock:
            env['SSH_AUTH_SOCK'] = self.ssh_auth_sock
        env['TMPDIR'] = self.tmpdir
        env['RICHOS_OPERATOR_LEAD'] = claim
        env.update(HARNESS_PIN)
        return env

    def mcp_config(self):
        return json.dumps({'mcpServers': {'richos_operator': {
            'type': 'stdio', 'command': self.python, 'args': [str(self.p.stub_mcp), str(self.p.stub_calls)]}}})

    def lead_args(self, session_id=None, resume=None, model=PROBE_MODEL, sources='user,project,local', extra=None,
                  disallow=('AskUserQuestion',)):
        """operator_profile::child_args, in order, plus --model. `disallow` extends the one
        --disallowed-tools flag rather than adding a second one."""
        args = ['--print', '--input-format=stream-json', '--output-format=stream-json', '--include-partial-messages',
                '--verbose', '--include-hook-events', '--setting-sources', sources]
        args += ['--resume', resume] if resume else ['--session-id', session_id or str(uuid.uuid4())]
        args += ['--permission-prompt-tool', 'stdio', '--dangerously-skip-permissions',
                 '--disallowed-tools'] + list(disallow) + ['--model', model]
        args += list(extra or [])
        args += ['--append-system-prompt-file', str(self.p.contract), '--mcp-config', self.mcp_config()]
        return args

    def front_desk_args(self, session_id):
        """native.rs child_args: the product front desk's own invocation."""
        return ['--print', '--input-format=stream-json', '--output-format=stream-json', '--include-partial-messages',
                '--verbose', '--setting-sources', '', '--no-session-persistence', '--session-id', session_id,
                '--permission-prompt-tool', 'stdio', '--model', PROBE_MODEL]

    def supervisor(self):
        return [self.python, '-B', str(self.p.engine / 'scripts' / 'provider-supervisor.py')]

    def supervisor_reaps(self):
        text = (self.p.engine / 'scripts' / 'provider-supervisor.py').read_text()
        return '--reap-descendants' in text

    def liveness(self, target):
        """agent-liveness.sh from HIS engine (B9), with his environment, from outside the lead."""
        env = dict(self.stored, HOME=str(self.p.home), CLAUDE_PROJECT_DIR=str(self.p.entity))
        code, out, err = run(['/bin/bash', str(self.p.engine / 'scripts' / 'agent-liveness.sh'), '--entity',
                              str(self.p.entity), '--json', target], env=env, cwd=str(self.p.entity), timeout=60)
        verdict = {0: 'NOT-ALIVE', 10: 'ALIVE', 11: 'INDETERMINATE'}.get(code, 'exit %d' % code)
        try:
            detail = json.loads(out)
        except ValueError:
            detail = {'stdout': out[-800:], 'stderr': err[-800:]}
        return verdict, detail

    def worktrees(self):
        code, out, _ = run(['git', '-C', str(self.p.entity), 'worktree', 'list', '--porcelain'], timeout=30)
        rows, row = [], {}
        for line in out.splitlines() + ['']:
            if not line.strip():
                if row:
                    rows.append(row)
                row = {}
                continue
            key, _, value = line.partition(' ')
            row[key] = value if value else True
        return [r for r in rows if '/.claude/worktrees/' in r.get('worktree', '')]


# =============================================================================================
# a lead, driven over stream-json as the app will drive it
# =============================================================================================

OWNER = r'''
import os, subprocess, sys, time
# Stands in for the app: the supervisor's parent. Killing this process is the app's death.
child = subprocess.Popen(sys.argv[2:], start_new_session=True)
open(sys.argv[1], "w").write(str(child.pid))
child.wait()
'''


class Lead(object):
    """One `claude` session. `permission` is how a `can_use_tool` is answered ('allow', as the
    permission desk would for a lead in bypass mode, or 'deny'); every other control request
    the child makes is answered with an error, as native.rs does. `owner=True` puts a stand-in
    for the app between this harness and the supervisor, so the app's death can be caused."""

    def __init__(self, ctx, probe, name, args, env=None, supervised=True, reap=False, cwd=None,
                 permission='allow', owner=False):
        self.ctx, self.probe, self.name = ctx, probe, name
        self.supervised = supervised
        self.frames = []
        self.requests = []
        self.permission = permission
        self.cond = threading.Condition()
        self.closed = False
        command = (ctx.supervisor() + (['--reap-descendants'] if reap else []) if supervised else []) + [GUEST_CLAUDE] + args
        self.owner_pidfile = None
        if owner:
            self.owner_pidfile = ctx.p.work / ('%s-%s.supervisor.pid' % (probe, name))
            owner_script = ctx.p.work / 'owner.py'
            owner_script.write_text(OWNER)
            command = [ctx.python, '-B', str(owner_script), str(self.owner_pidfile)] + command
        self.stderr_path = ctx.p.results / ('%s-%s.stderr.txt' % (probe, name))
        self.proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(str(self.stderr_path), 'w'), cwd=str(cwd or ctx.p.entity),
                                     env=env if env is not None else ctx.lead_env(), start_new_session=True,
                                     text=True, bufsize=1)
        self.started = time.time()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def supervisor_pid(self):
        """The supervisor's pid: this harness's own child, or the owner stand-in's."""
        if not self.owner_pidfile:
            return self.proc.pid
        for _ in range(50):
            if self.owner_pidfile.exists() and self.owner_pidfile.read_text().strip().isdigit():
                return int(self.owner_pidfile.read_text().strip())
            time.sleep(0.1)
        return None

    def _answer(self, frame):
        req = frame.get('request') or {}
        rid = frame.get('request_id')
        self.requests.append({'t': round(time.time() - self.started, 3), 'subtype': req.get('subtype'),
                              'tool_name': req.get('tool_name'), 'input_keys': sorted((req.get('input') or {}).keys())})
        if req.get('subtype') == 'can_use_tool':
            body = {'behavior': 'allow', 'updatedInput': req.get('input') or {}} if self.permission == 'allow' else \
                {'behavior': 'deny', 'message': 'Denied by the probe.'}
            reply = {'type': 'control_response', 'response': {'subtype': 'success', 'request_id': rid, 'response': body}}
        else:
            reply = {'type': 'control_response', 'response': {'subtype': 'error', 'request_id': rid,
                                                              'error': 'Not implemented by the probe harness.'}}
        try:
            self.send(reply)
        except (BrokenPipeError, ValueError):
            pass

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                frame = json.loads(line)
            except ValueError:
                continue
            if frame.get('type') == 'control_request':
                self._answer(frame)
            with self.cond:
                self.frames.append((time.time(), frame))
                self.cond.notify_all()
        with self.cond:
            self.closed = True
            self.cond.notify_all()

    def send(self, obj):
        self.proc.stdin.write(json.dumps(obj) + '\n')
        self.proc.stdin.flush()

    def user(self, text, priority=None):
        mid = str(uuid.uuid4())
        msg = {'type': 'user', 'uuid': mid, 'message': {'role': 'user', 'content': [{'type': 'text', 'text': text}]}}
        if priority:
            msg['priority'] = priority
        self.send(msg)
        return mid

    def control(self, subtype, **fields):
        rid = 'req_' + uuid.uuid4().hex[:10]
        request = dict(subtype=subtype, **fields)
        self.send({'type': 'control_request', 'request_id': rid, 'request': request})
        return rid

    def wait(self, pred, timeout, start=0):
        deadline = time.time() + timeout
        index = start
        with self.cond:
            while True:
                while index < len(self.frames):
                    t, f = self.frames[index]
                    if pred(f):
                        return index, t, f
                    index += 1
                remaining = deadline - time.time()
                if remaining <= 0 or self.closed:
                    return None
                self.cond.wait(min(remaining, 1.0))

    def initialize(self):
        rid = self.control('initialize', hooks={})
        got = self.wait(lambda f: f.get('type') == 'control_response'
                        and (f.get('response') or {}).get('request_id') == rid, 60)
        return bool(got) and got[2]['response'].get('subtype') == 'success'

    def result_after(self, start, timeout):
        return self.wait(lambda f: f.get('type') == 'result', timeout, start)

    def count(self):
        with self.cond:
            return len(self.frames)

    def all_frames(self):
        with self.cond:
            return [f for _, f in self.frames]

    def init_frame(self):
        for f in self.all_frames():
            if f.get('type') == 'system' and f.get('subtype') == 'init':
                return f
        return None

    def alarms(self):
        found = []
        for f in self.all_frames():
            found.extend(alarms_in(f))
        return found

    def text(self, start=0):
        with self.cond:
            frames = [f for _, f in self.frames[start:]]
        out = []
        for f in frames:
            if f.get('type') == 'assistant':
                for block in (f.get('message') or {}).get('content') or []:
                    if block.get('type') == 'text':
                        out.append(block.get('text', ''))
        return '\n'.join(out)

    def claude_pid(self):
        if not self.supervised:
            return self.proc.pid
        sup = self.supervisor_pid()
        kids = children_of(sup) if sup else []
        return kids[0] if kids else None

    def close(self, grace=15):
        try:
            self.proc.stdin.close()
        except Exception:  # noqa: BLE001
            pass
        try:
            self.proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            # Owned: the group of the process this harness started, never a name.
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(self.proc.pid, sig)
                except ProcessLookupError:
                    break
                try:
                    self.proc.wait(timeout=5)
                    break
                except subprocess.TimeoutExpired:
                    continue
        self.save()

    def save(self):
        path = self.ctx.p.results / ('%s-%s.jsonl' % (self.probe, self.name))
        with self.cond:
            rows = list(self.frames)
        with open(str(path), 'w') as f:
            for t, frame in rows:
                if frame.get('type') == 'control_response' and \
                        (frame.get('response') or {}).get('response', {}).get('account') is not None:
                    frame = {'type': 'control_response', 'response': {'subtype': frame['response'].get('subtype'),
                                                                      'request_id': frame['response'].get('request_id'),
                                                                      'response': '<initialize reply removed>'}}
                f.write(json.dumps({'t': round(t - self.started, 3), 'frame': redact(frame)}) + '\n')


def session_record(p, session_id=None, pid=None):
    for path in glob.glob(str(p.claude_dir / 'sessions' / '*.json')):
        try:
            d = json.loads(Path(path).read_text())
        except (OSError, ValueError):
            continue
        if (session_id and d.get('sessionId') == session_id) or (pid and d.get('pid') == pid):
            return {k: d.get(k) for k in ('pid', 'kind', 'entrypoint', 'cwd', 'sessionId', 'version')}
    return None


def ask(lead, text, timeout, priority=None):
    start = lead.count()
    lead.user(text, priority=priority)
    got = lead.result_after(start, timeout)
    return start, got


# Said honestly, because it is true, and because a lead that is not told refuses (run 2, P8:
# "has the shape of reconnaissance/exfiltration"). The probe measures the lead's platform, so
# the lead is told it is a probe.
FIXTURE_NOTE = ('This session is an automated probe of the operator setup, running in a disposable test virtual '
                'machine that is deleted after the run. The folders, the files and the git remote here are scratch '
                'fixtures made for this probe (the remote is a bare repository on this same machine). Nothing here is '
                'shared or real. The request below is the probe\'s measurement; please carry it out exactly as written. ')


def do(lead, text, timeout, priority=None):
    """A request the lead must carry out, with the fixture note in front of it."""
    return ask(lead, FIXTURE_NOTE + text, timeout, priority)


def tool_uses(lead, start, name=None):
    return [b for f in lead.all_frames()[start:] if f.get('type') == 'assistant'
            for b in (f.get('message') or {}).get('content') or []
            if b.get('type') == 'tool_use' and (name is None or b.get('name') == name)]


# =============================================================================================
# teammates, started the way his lead starts them: spawn.sh, then the Agent call it prints
# =============================================================================================

def brief(ctx, name, seconds):
    path = ctx.p.work / ('brief-%s.md' % name)
    path.write_text('Run exactly this Bash command in the foreground and wait for it to finish: sleep %d\n'
                    'Then reply with the single word finished. Do nothing else.\n' % seconds)
    return path


def spawn_teammate(ctx, lead, name, agent_type, seconds, timeout=300):
    """Returns (task_id, worktree_path, detail). The lead runs spawn.sh and makes the Agent call
    with run_in_background, exactly as his terminal's lead does (engine-status banner)."""
    before = set(r['worktree'] for r in ctx.worktrees())
    command = '%s %s --repo %s --type %s --brief %s --model sonnet' % (
        ctx.p.engine / 'scripts' / 'spawn.sh', name, ctx.p.entity, agent_type, brief(ctx, name, seconds))
    start, got = do(lead, (
        'Start one teammate. Step 1: run exactly this Bash command and read its standard output:\n%s\n'
        'Step 2: its standard output is one JSON object of Agent tool parameters. Call the Agent tool ONCE with '
        'exactly those parameters, adding run_in_background set to true. Step 3: reply with the single word '
        'started. Do nothing else. If step 1 refuses, reply with its full refusal text instead.' % command), timeout)
    frames = lead.all_frames()[start:]
    agent_use = None
    for f in frames:
        if f.get('type') == 'assistant':
            for block in (f.get('message') or {}).get('content') or []:
                if block.get('type') == 'tool_use' and block.get('name') in ('Agent', 'Task') and \
                        (block.get('input') or {}).get('name') == name:
                    agent_use = block
    task_id = None
    for f in frames:
        if f.get('type') == 'system' and f.get('subtype') == 'task_started' and agent_use and \
                f.get('tool_use_id') == agent_use.get('id'):
            task_id = f.get('task_id')
    after = [r for r in ctx.worktrees() if r['worktree'] not in before]
    detail = {'agent_call': bool(agent_use), 'task_id': task_id, 'new_worktrees': after,
              'lead_said': lead.text(start)[-1500:], 'turn_ended': bool(got)}
    return task_id, (after[0]['worktree'] if len(after) == 1 else None), detail


# =============================================================================================
# the probes
# =============================================================================================

PROBES = []


def probe(pid):
    def register(fn):
        PROBES.append((pid, fn))
        return fn
    return register


@probe('P1')
def p1(ctx, r):
    main = Lead(ctx, 'P1', 'lead', ctx.lead_args())
    try:
        r['initialize'] = main.initialize()
        ask(main, 'Reply with exactly the word ready.', 180)
        init = main.init_frame()
        banners = [parse_banner(dedupe_key(a['text'])) for a in main.alarms()]
        banner = next((b for b in banners if b), None)
        r['plugins'] = [{'name': x.get('name'), 'path': x.get('path'), 'source': x.get('source')}
                        for x in (init or {}).get('plugins') or []]
        r['banner'] = banner
        r['declared_engine'] = str(ctx.p.engine)
        r['plugin_root_note'] = ('CLAUDE_PLUGIN_ROOT is set only inside the plugin\'s own hooks; the banner\'s '
                                 'Engine: is that hook resolving its own root (resolve_engine_root(SCRIPT_DIR)), '
                                 'which is the same fact, read off the wire.')
        r['main_check'] = init_check(init, banner, ctx.p.engine)
    finally:
        main.close()
    control = Lead(ctx, 'P1', 'control-app-engine', ctx.lead_args(extra=['--plugin-dir', str(ctx.p.app_engine_plugin)]))
    try:
        control.initialize()
        ask(control, 'Reply with exactly the word ready.', 180)
        cinit = control.init_frame()
        cbanner = next((b for b in (parse_banner(dedupe_key(a['text'])) for a in control.alarms()) if b), None)
        r['control_plugins'] = [x.get('name') for x in (cinit or {}).get('plugins') or []]
        r['control_check'] = init_check(cinit, cbanner, ctx.p.engine)
    finally:
        control.close()
    if 'richos-app-engine' not in r['control_plugins']:
        return 'PREMISE-FALSE', 'the control run did not load the app engine plugin, so the init check was not tested'
    if r['control_check'][0] != 'refuse':
        return 'FAIL', 'the init check opened a lead with the app engine loaded'
    if r['main_check'][0] != 'open':
        return 'FAIL', 'the lead did not pass the init check: ' + str(r['main_check'][1])
    return 'PASS', 'richos-engine loaded once from %s; the app-engine control was refused' % (banner or {}).get('engine_root')


def interactive_session(ctx, r, seconds_for_record=60):
    """An interactive `claude` in a pseudo-terminal, as his terminal runs it. Returns
    (pid, fd, record) with the session still running; the caller ends it."""
    env = dict(ctx.stored, HOME=str(ctx.p.home), TERM='xterm-256color', **HARNESS_PIN)
    if ctx.ssh_auth_sock:
        env['SSH_AUTH_SOCK'] = ctx.ssh_auth_sock
    env['TMPDIR'] = ctx.tmpdir
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(str(ctx.p.entity))
        os.execve(GUEST_CLAUDE, [GUEST_CLAUDE, '--dangerously-skip-permissions', '--model', PROBE_MODEL], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 160, 0, 0))
    screen = []
    deadline = time.time() + seconds_for_record
    record = None
    while time.time() < deadline and record is None:
        drain(fd, screen, 1.0)
        record = session_record(ctx.p, pid=pid)
    return pid, fd, record, screen


def drain(fd, screen, seconds):
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            screen.append(chunk.decode('utf-8', 'replace'))


def type_into(fd, text, screen):
    os.write(fd, text.encode())
    drain(fd, screen, 1.0)
    os.write(fd, b'\r')


def end_interactive(pid, fd):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)  # owned: the pid pty.fork returned
        except ProcessLookupError:
            break
        for _ in range(20):
            done, _ = os.waitpid(pid, os.WNOHANG)
            if done:
                break
            time.sleep(0.25)
        else:
            continue
        break
    try:
        os.close(fd)
    except OSError:
        pass


@probe('P2')
def p2(ctx, r):
    # ---- the records: a lead, the front desk, an interactive session, and a print-mode
    #      claude started from that interactive session's tool shell ------------------------
    sid = str(uuid.uuid4())
    lead = Lead(ctx, 'P2', 'lead', ctx.lead_args(session_id=sid))
    fd_sid = str(uuid.uuid4())
    desk_env = dict(ctx.stored, HOME=str(ctx.p.home), TMPDIR=ctx.tmpdir, **HARNESS_PIN)
    desk = Lead(ctx, 'P2', 'front-desk', ctx.front_desk_args(fd_sid), env=desk_env, supervised=False)
    ipid = ifd = None
    try:
        lead.initialize()
        desk.initialize()
        ask(lead, 'Reply with exactly the word ready.', 180)
        ask(desk, 'Reply with exactly the word ready.', 180)
        r['lead_record'] = session_record(ctx.p, session_id=sid)
        r['front_desk_record'] = session_record(ctx.p, session_id=fd_sid) or \
            session_record(ctx.p, pid=desk.proc.pid)
        ipid, ifd, irecord, screen = interactive_session(ctx, r)
        r['interactive_record'] = irecord
        env_file = ctx.p.work / 'p2-interactive-tool-env.txt'
        type_into(ifd, 'Run exactly this Bash command and nothing else, then reply done: env -0 > %s' % env_file, screen)
        deadline = time.time() + 180
        while time.time() < deadline and not (env_file.exists() and env_file.stat().st_size > 0):
            drain(ifd, screen, 1.0)
        tool_env = {}
        if env_file.exists():
            for item in env_file.read_text().split('\0'):
                if '=' in item:
                    k, v = item.split('=', 1)
                    tool_env[k] = v
        r['interactive_tool_shell_names'] = sorted(tool_env)
        r['interactive_tool_shell_entrypoint'] = tool_env.get('CLAUDE_CODE_ENTRYPOINT')
        if tool_env:
            nested_sid = str(uuid.uuid4())
            nested = Lead(ctx, 'P2', 'print-from-tool-shell',
                          ['--print', '--input-format=stream-json', '--output-format=stream-json', '--verbose',
                           '--session-id', nested_sid, '--model', PROBE_MODEL], env=tool_env, supervised=False)
            try:
                nested.initialize()
                ask(nested, 'Reply with exactly the word ready.', 180)
                r['print_from_tool_shell_record'] = session_record(ctx.p, session_id=nested_sid) or \
                    session_record(ctx.p, pid=nested.proc.pid)
            finally:
                nested.close()
        (ctx.p.results / 'P2-interactive-screen.txt').write_text(re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', ''.join(screen))[-20000:])
        # ---- the agent: visible and unreaped while it runs, NOT-ALIVE after ------------------
        task_id, worktree, detail = spawn_teammate(ctx, lead, 'probe-sonnet-p2a', 'alpha', 60)
        r['spawn'] = detail
        if worktree:
            r['liveness_running'] = ctx.liveness(worktree)
            second = Lead(ctx, 'P2', 'second-session', ctx.lead_args())
            try:
                second.initialize()
                ask(second, 'Reply with exactly the word ready.', 180)
                texts = [a['text'] for a in second.alarms()]
                r['second_session_alarms_mentioning_reap_or_indeterminate'] = [
                    t[:600] for t in texts if re.search(r'INDETERMINATE|reap', t, re.I)]
            finally:
                second.close()
            r['worktree_still_there_after_second_session'] = any(w['worktree'] == worktree for w in ctx.worktrees())
            done = lead.wait(lambda f: f.get('type') == 'system' and f.get('subtype') == 'task_notification'
                             and f.get('task_id') == task_id, 240)
            r['agent_ended'] = bool(done) and done[2].get('status')
            time.sleep(5)
            r['liveness_after'] = ctx.liveness(worktree)
    finally:
        if ipid:
            end_interactive(ipid, ifd)
        desk.close()
        lead.close()
    lead_ep = (r.get('lead_record') or {}).get('entrypoint')
    ctl_ep = (r.get('interactive_record') or {}).get('entrypoint')
    if ctl_ep != 'cli':
        return 'PREMISE-FALSE', 'the interactive control recorded entrypoint %r, not cli' % ctl_ep
    problems = []
    if lead_ep != 'sdk-cli':
        problems.append('the lead recorded entrypoint %r' % lead_ep)
    if r.get('spawn', {}).get('task_id') is None:
        problems.append('no teammate could be started for the liveness half (see spawn)')
    else:
        if (r.get('liveness_running') or [None])[0] != 'ALIVE':
            problems.append('liveness while running: %s' % (r.get('liveness_running') or [None])[0])
        if (r.get('liveness_after') or [None])[0] != 'NOT-ALIVE':
            problems.append('liveness after: %s' % (r.get('liveness_after') or [None])[0])
        if r.get('second_session_alarms_mentioning_reap_or_indeterminate'):
            problems.append('the second session reported reaping or INDETERMINATE')
        if not r.get('worktree_still_there_after_second_session'):
            problems.append('the agent worktree was gone after the second session started')
    if problems:
        return 'FAIL', '; '.join(problems)
    return 'PASS', 'lead entrypoint sdk-cli, interactive cli; front desk record: %s' % (
        'present' if r.get('front_desk_record') else 'ABSENT')


@probe('P3')
def p3(ctx, r):
    lead = Lead(ctx, 'P3', 'lead', ctx.lead_args())
    try:
        lead.initialize()
        task_id, worktree, detail = spawn_teammate(ctx, lead, 'probe-sonnet-p3a', 'alpha', 240)
        r['spawn'] = detail
        if not worktree:
            return 'NOT-RUN', 'no teammate could be started (see spawn)'
        start = lead.count()
        lead.user(FIXTURE_NOTE + 'Run exactly this Bash command in the foreground and wait for it: sleep 90. Then reply slept.')
        got = lead.wait(lambda f: f.get('type') == 'assistant' and any(
            b.get('type') == 'tool_use' and b.get('name') == 'Bash' for b in (f.get('message') or {}).get('content') or []),
            120, start)
        r['lead_in_shell'] = bool(got)
        lead.user('Reply with exactly: QUEUED-MARK')
        time.sleep(3)
        r['interrupt_sent_at'] = time.time() - lead.started
        lead.control('interrupt')
        ended = lead.result_after(start, 60)
        r['turn_ended'] = bool(ended) and ended[2].get('subtype')
        time.sleep(5)
        r['liveness_after_interrupt'] = ctx.liveness(worktree)
        r['worktree_locked'] = any(w['worktree'] == worktree and 'locked' in w for w in ctx.worktrees())
        r['agent_notified_stopped'] = any(f.get('subtype') == 'task_notification' and f.get('task_id') == task_id
                                          for f in lead.all_frames())
        later = lead.wait(lambda f: f.get('type') == 'result', 60, (ended[0] + 1) if ended else start)
        r['queued_message_answered'] = 'QUEUED-MARK' in lead.text(start)
        r['queued_turn_ran'] = bool(later)
    finally:
        lead.close()
    if not r.get('lead_in_shell'):
        return 'PREMISE-FALSE', 'the lead never started the shell command, so the interrupt did not land mid-command'
    if r['liveness_after_interrupt'][0] == 'ALIVE' and r['worktree_locked'] and not r['agent_notified_stopped'] \
            and r['turn_ended']:
        return 'PASS', 'the lead turn ended and the agent stayed ALIVE with its lock held'
    return 'FAIL', 'after the interrupt: liveness %s, locked %s, stopped %s, turn ended %s' % (
        r['liveness_after_interrupt'][0], r['worktree_locked'], r['agent_notified_stopped'], r['turn_ended'])


def two_teammates(ctx, lead, r, tag):
    a_id, a_wt, a_detail = spawn_teammate(ctx, lead, 'probe-sonnet-%sa' % tag, 'alpha', 400)
    b_id, b_wt, b_detail = spawn_teammate(ctx, lead, 'probe-sonnet-%sb' % tag, 'beta', 400)
    r['spawn_a'], r['spawn_b'] = a_detail, b_detail
    return (a_id, a_wt), (b_id, b_wt)


def wait_not_alive(ctx, worktree, seconds):
    began = time.time()
    last = None
    while time.time() - began < seconds:
        last = ctx.liveness(worktree)
        if last[0] == 'NOT-ALIVE':
            return round(time.time() - began, 2), last
        time.sleep(1)
    return None, last


@probe('P4')
def p4(ctx, r):
    lead = Lead(ctx, 'P4', 'lead', ctx.lead_args())
    try:
        lead.initialize()
        (a_id, a_wt), (b_id, b_wt) = two_teammates(ctx, lead, r, 'p4')
        if not (a_wt and b_wt):
            return 'NOT-RUN', 'two teammates could not be started (see spawn_a, spawn_b)'
        t0 = time.time()
        start = lead.count()
        lead.user(FIXTURE_NOTE + 'Stop the teammate named probe-sonnet-p4a, and ONLY that one: first run exactly this Bash command: '
                  '%s probe-sonnet-p4a --entity %s --ceo-word \'stop p4a\' ; then make the TaskStop call it prints. '
                  'Do not stop probe-sonnet-p4b. Then reply stopped.' % (ctx.p.engine / 'scripts' / 'stop.sh', ctx.p.entity))
        r['seconds_to_not_alive'], r['liveness_a'] = wait_not_alive(ctx, a_wt, 180)
        lead.result_after(start, 180)
        r['liveness_b'] = ctx.liveness(b_wt)
        r['lead_said'] = lead.text(start)[-1500:]
        r['taskstop_calls'] = [b.get('input') for f in lead.all_frames()[start:] if f.get('type') == 'assistant'
                               for b in (f.get('message') or {}).get('content') or []
                               if b.get('type') == 'tool_use' and b.get('name') == 'TaskStop']
        r['elapsed_total'] = round(time.time() - t0, 2)
    finally:
        lead.close()
    if not r['taskstop_calls']:
        return 'FAIL', 'the lead made no TaskStop call'
    if r['seconds_to_not_alive'] is not None and r['liveness_b'][0] == 'ALIVE':
        return 'PASS', 'NOT-ALIVE in %s s, the other agent ALIVE' % r['seconds_to_not_alive']
    return 'FAIL', 'a: %s after %s s, b: %s' % (r['liveness_a'][0], r['seconds_to_not_alive'], r['liveness_b'][0])


@probe('P5')
def p5(ctx, r):
    lead = Lead(ctx, 'P5', 'lead', ctx.lead_args())
    try:
        lead.initialize()
        task_id, worktree, detail = spawn_teammate(ctx, lead, 'probe-sonnet-p5a', 'alpha', 20)
        r['spawn'] = detail
        if not task_id:
            return 'NOT-RUN', 'no teammate could be started (see spawn)'
        results_before = sum(1 for f in lead.all_frames() if f.get('type') == 'result')
        mark = lead.count()
        # Nothing is sent from here on. A new turn must start by itself when the agent ends.
        new_turn = lead.wait(lambda f: f.get('type') == 'result', 300, mark)
        r['platform_started_turn'] = bool(new_turn)
        r['seconds_to_new_turn'] = round(new_turn[1] - lead.frames[mark][0], 2) if new_turn and mark < lead.count() else None
        events = [f.get('hook_event') for f in lead.all_frames() if f.get('type') == 'system'
                  and f.get('subtype') in ('hook_started', 'hook_response')]
        r['hook_events_seen'] = sorted(set(e for e in events if e))
        r['results_before'] = results_before
    finally:
        lead.close()
    fired = {'TeammateIdle', 'TaskCompleted'} & set(r['hook_events_seen'])
    r['teammate_hooks_fired'] = sorted(fired)
    if not r['platform_started_turn']:
        return 'FAIL', 'no turn started after the agent ended, with nothing sent'
    if fired != {'TeammateIdle', 'TaskCompleted'}:
        return 'FAIL', 'a platform turn started, but TeammateIdle/TaskCompleted fired: %s' % sorted(fired)
    return 'PASS', 'a platform turn started with nothing sent; TeammateIdle and TaskCompleted fired'


@probe('P6')
def p6(ctx, r):
    def teams():
        found = {}
        for path in glob.glob(str(ctx.p.claude_dir / 'teams' / '*' / 'config.json')):
            try:
                found[path] = json.loads(Path(path).read_text())
            except (OSError, ValueError):
                found[path] = None
        return found
    before = teams()
    lead = Lead(ctx, 'P6', 'lead', ctx.lead_args())
    try:
        lead.initialize()
        task_id, worktree, detail = spawn_teammate(ctx, lead, 'probe-sonnet-p6a', 'alpha', 15)
        r['spawn'] = detail
        after = teams()
        r['team_configs_new'] = sorted(set(after) - set(before))
        r['member_named'] = any('probe-sonnet-p6a' in json.dumps(v) for v in after.values())
    finally:
        lead.close()
    control_before = teams()
    control = Lead(ctx, 'P6', 'control-no-project-settings', ctx.lead_args(sources='user'))
    try:
        control.initialize()
        cinit_start, _ = ask(control, 'Reply with exactly the word ready.', 180)
        cinit = control.init_frame() or {}
        r['control_tools_include_team_tools'] = sorted(t for t in cinit.get('tools') or []
                                                       if t in ('TeamCreate', 'TeamDelete', 'SendMessage'))
        r['lead_tools_include_team_tools'] = sorted(t for t in (lead.init_frame() or {}).get('tools') or []
                                                    if t in ('TeamCreate', 'TeamDelete', 'SendMessage'))
        r['control_team_configs_new'] = sorted(set(teams()) - set(control_before))
    finally:
        control.close()
    if r['control_tools_include_team_tools'] == r['lead_tools_include_team_tools']:
        return 'PREMISE-FALSE', ('the control without project settings offered the same team tools, so the switch '
                                 'cannot be told apart from the default')
    if not task_id or not r['member_named']:
        return 'FAIL', 'the named teammate did not appear in a team configuration'
    return 'PASS', 'a named teammate spawned and its team configuration was written'


def filler_files(ctx, count, kib):
    folder = ctx.p.work / 'p7-files'
    folder.mkdir(exist_ok=True)
    words = ['anchor', 'basalt', 'cinder', 'dune', 'ember', 'fjord', 'glacier', 'harbor', 'island', 'juniper']
    for i in range(count):
        path = folder / ('part-%03d.txt' % i)
        if path.exists():
            continue
        lines = []
        n = 0
        while n < kib * 1024:
            line = 'part %d line %d %s %s %s %d\n' % (i, len(lines), words[len(lines) % 10], words[(len(lines) * 7) % 10],
                                                        words[(len(lines) * 3 + i) % 10], (len(lines) * 7919 + i) % 100003)
            lines.append(line)
            n += len(line)
        path.write_text(''.join(lines))
    return folder


@probe('P7')
def p7(ctx, r):
    sid = str(uuid.uuid4())
    # 60 files of 60 KiB: each stays under the Read tool's per-call token cap (about 21k tokens
    # at the ~2.9 characters per token this text runs at), and together they pass 1M tokens,
    # so automatic compaction must happen before the last one is read.
    folder = filler_files(ctx, 60, 60)
    hook_log = ctx.p.work / 'p7-sessionstart.jsonl'
    settings = ctx.p.work / 'p7-settings.json'
    settings.write_text(json.dumps({'hooks': {'SessionStart': [{'hooks': [{'type': 'command',
        'command': '/bin/cat >> %s; echo >> %s' % (hook_log, hook_log)}]}]}}))
    lead = Lead(ctx, 'P7', 'lead', ctx.lead_args(session_id=sid, model=HIS_MODEL, extra=['--settings', str(settings)]))
    usage = []
    try:
        lead.initialize()
        start, got = do(lead, 'Read every file in %s with the Read tool, ten files per message in parallel, '
                               'until all 60 are read. Do not summarize them. Then reply with exactly: ALL-READ' % folder,
                         ctx.timeout * 3)
        compacted = [f for f in lead.all_frames() if f.get('type') == 'system' and
                     f.get('subtype') in ('compact_boundary', 'status') and 'compact' in json.dumps(f)]
        r['compaction_frames'] = compacted[:5]
        r['auto_compacted'] = any((f.get('compact_metadata') or {}).get('trigger') == 'auto' for f in compacted)
        s2, _ = ask(lead, 'Answer with only the two tokens, nothing else: the fixture watchword, and the fixture memory token.', 300)
        r['answer_after_compaction'] = lead.text(s2)[-300:]
        usage = [f.get('usage') for f in lead.all_frames() if f.get('type') == 'result']
    finally:
        lead.close()
    r['usage_per_turn'] = usage
    resumed = Lead(ctx, 'P7', 'resumed', ctx.lead_args(resume=sid, model=HIS_MODEL, extra=['--settings', str(settings)]))
    try:
        resumed.initialize()
        s3, _ = ask(resumed, 'What was the exact word you replied with after reading the files? Reply with only it.', 300)
        r['answer_after_resume'] = resumed.text(s3)[-300:]
    finally:
        resumed.close()
    sources = []
    if hook_log.exists():
        for line in hook_log.read_text().splitlines():
            try:
                sources.append(json.loads(line).get('source'))
            except ValueError:
                pass
    r['sessionstart_sources'] = sources
    both = 'PERIWINKLE-4417' in r['answer_after_compaction'] and 'AMBER-2291' in r['answer_after_compaction']
    if not r['auto_compacted']:
        return 'FAIL', 'no automatic compaction was observed at this context size'
    if not both or 'resume' not in sources or 'ALL-READ' not in r['answer_after_resume']:
        return 'FAIL', 'after compaction/resume: tokens %s, sources %s, resumed answer %r' % (
            both, sources, r['answer_after_resume'][:60])
    return 'PASS', 'compacted automatically, both lines survived, resumed with source resume'


@probe('P8')
def p8(ctx, r):
    names_out = ctx.p.work / 'p8-lead-names.txt'
    hook_out = ctx.p.work / 'p8-hook-tools.txt'
    facts_out = ctx.p.work / 'p8-lead-facts.txt'
    settings = ctx.p.work / 'p8-settings.json'
    settings.write_text(json.dumps({'hooks': {'PreToolUse': [{'matcher': 'Bash', 'hooks': [{'type': 'command',
        'command': 'for t in python3 git gh java; do command -v $t; done > %s' % hook_out}]}]}}))
    env = ctx.lead_env()
    planted = dict(os.environ)
    planted['ANTHROPIC_API_KEY'] = 'planted-by-the-probe-not-a-key'
    r['app_environment_had_planted_key'] = 'ANTHROPIC_API_KEY' in planted
    lead = Lead(ctx, 'P8', 'lead', ctx.lead_args(extra=['--settings', str(settings)]), env=env)
    try:
        lead.initialize()
        # The push goes to a NEW branch on the fixture remote, so nothing is written into the
        # entity's main checkout; what is proven is the SSH path from the lead's environment.
        start, got = do(lead, (
            'Run exactly this one Bash command and then reply done:\n'
            'env | cut -d= -f1 | sort > %s; { echo "TMPFILE=$(mktemp)"; echo "CLAUDE_PID=$CLAUDE_PID"; '
            'git -C %s push -q origin HEAD:refs/heads/probe-p8 && echo PUSH=ok || echo PUSH=failed; } > %s 2>&1'
        ) % (names_out, ctx.p.entity, facts_out), 300)
        r['claude_pid'] = lead.claude_pid()
        r['lead_ran_the_command'] = bool(tool_uses(lead, start, 'Bash'))
        r['lead_said'] = lead.text(start)[-600:]
    finally:
        lead.close()
    lead_names = names_file(names_out) or []
    r['lead_tool_shell_names'] = lead_names
    facts = {}
    for line in (facts_out.read_text().splitlines() if facts_out.exists() else []):
        if '=' in line:
            k, v = line.split('=', 1)
            facts[k] = v
    r['push'] = facts.get('PUSH')
    r['tmpfile_under_tmpdir'] = facts.get('TMPFILE', '').startswith(ctx.tmpdir.rstrip('/'))
    r['claude_pid_matches'] = facts.get('CLAUDE_PID') == str(r.get('claude_pid'))
    code, out, _ = run(['/bin/zsh', '-lc', 'for t in python3 git gh java; do command -v $t; done'], timeout=60)
    r['terminal_tools'] = out.split()
    r['hook_tools'] = hook_out.read_text().split() if hook_out.exists() else None
    # ---- the control: what claude sets in a tool shell by itself --------------------------
    control_names = ctx.p.work / 'p8-control-names.txt'
    bare = {'HOME': str(ctx.p.home), 'PATH': ctx.stored['PATH']}
    bare.update(HARNESS_PIN)
    control = Lead(ctx, 'P8', 'control-bare', ctx.lead_args(), env=bare, supervised=False)
    try:
        control.initialize()
        do(control, 'Run exactly this one Bash command and then reply done: env | cut -d= -f1 | sort > %s' % control_names, 300)
    finally:
        control.close()
    claude_own = sorted(set(names_file(control_names) or []) - set(bare))
    r['names_claude_sets_itself'] = claude_own
    expected = sorted(set(k for k in ALLOWLIST if k in env) | set(APP_NAMES) | set(SUPERVISOR_NAMES) |
                      set(HARNESS_PIN))
    r['expected_names'] = expected
    measured = sorted(set(lead_names) - set(claude_own) - {'PWD', 'OLDPWD', 'SHLVL', '_'})
    r['measured_names_minus_claude_own'] = measured
    r['extra'] = sorted(set(measured) - set(expected))
    r['missing'] = sorted(set(expected) - set(measured))
    r['planted_key_reached_lead'] = 'ANTHROPIC_API_KEY' in lead_names
    r['ssh_auth_sock_method'] = ctx.ssh_method
    if not r['lead_ran_the_command']:
        return 'PREMISE-FALSE', 'the lead did not run the measuring command, so nothing was measured'
    if not control_names.exists():
        return 'PREMISE-FALSE', 'the control session recorded no names, so claude\'s own names are unknown'
    problems = []
    if r['push'] != 'ok':
        problems.append('the push failed')
    if not r['tmpfile_under_tmpdir']:
        problems.append('mktemp did not land under the derived TMPDIR')
    if not r['claude_pid_matches']:
        problems.append('CLAUDE_PID %s is not the lead pid %s' % (facts.get('CLAUDE_PID'), r.get('claude_pid')))
    if r['hook_tools'] != r['terminal_tools']:
        problems.append('tools in a hook %s differ from the terminal %s' % (r['hook_tools'], r['terminal_tools']))
    if r['planted_key_reached_lead']:
        problems.append('the planted ANTHROPIC_API_KEY reached the lead')
    if r['extra'] or r['missing']:
        problems.append('set equality: extra %s, missing %s' % (r['extra'], r['missing']))
    return ('FAIL', '; '.join(problems)) if problems else ('PASS', 'set equality held; push ok; TMPDIR and CLAUDE_PID right')


@probe('P9')
def p9(ctx, r):
    q = 'Answer from what you already know, without looking anything up: the fixture watchword, and the fixture ' \
        'memory token. Reply with only the two tokens, nothing else. If you do not know one, write UNKNOWN in its place.'
    # Run 2 showed a control finding the CLAUDE.md token by searching the fixture with its
    # tools. What is being measured is what LOADED, so no run of this probe may look anything up.
    no_lookup = ('AskUserQuestion', 'Bash', 'Read', 'Grep', 'Glob', 'Task', 'Agent', 'WebFetch', 'WebSearch',
                 'NotebookRead', 'ToolSearch')
    r['tools_withheld_in_every_run'] = list(no_lookup)
    lead = Lead(ctx, 'P9', 'lead', ctx.lead_args(disallow=no_lookup))
    try:
        lead.initialize()
        s, _ = ask(lead, q, 180)
        r['answer'] = lead.text(s)[-300:]
    finally:
        lead.close()
    # r3's control. Run 1 (2026-09-25) found it answers both tokens: --setting-sources '' does
    # not stop CLAUDE.md or auto memory from loading. It is kept and recorded as that finding.
    control = Lead(ctx, 'P9', 'control-r3-no-setting-sources', ctx.lead_args(sources='', disallow=no_lookup))
    try:
        control.initialize()
        s, _ = ask(control, q, 180)
        r['r3_control_answer'] = control.text(s)[-300:]
    finally:
        control.close()
    # A control that can fail: what the product front desk does to keep them out
    # (engine_profile.rs: claudeMdExcludes and autoMemoryEnabled false, plus the variable).
    excludes = json.dumps({'claudeMdExcludes': ['**/CLAUDE.md', '**/CLAUDE.local.md', '**/.claude/rules/**'],
                           'autoMemoryEnabled': False})
    env = dict(ctx.lead_env(), CLAUDE_CODE_DISABLE_AUTO_MEMORY='1')
    working = Lead(ctx, 'P9', 'control-excluded', ctx.lead_args(sources='', extra=['--settings', excludes],
                                                                disallow=no_lookup), env=env)
    try:
        working.initialize()
        s, _ = ask(working, q, 180)
        r['control_answer'] = working.text(s)[-300:]
    finally:
        working.close()
    tokens = ('PERIWINKLE-4417', 'AMBER-2291')
    r['r3_control_answered'] = [t for t in tokens if t in r['r3_control_answer']]
    if any(t in r['control_answer'] for t in tokens):
        return 'PREMISE-FALSE', 'even with both excluded the control answered a token'
    if all(t in r['answer'] for t in tokens):
        return 'PASS', ('both lines answered natively; the excluded control answered neither. r3\'s own control '
                        '(--setting-sources \'\') answered %s, so it cannot serve as a control' % r['r3_control_answered'])
    return 'FAIL', 'the lead answered %r' % r['answer'][:120]


@probe('P10')
def p10(ctx, r):
    settings = ctx.p.work / 'p10-settings.json'
    def say(marker):
        return {'type': 'command', 'command': 'echo \'{"systemMessage":"%s"}\'' % marker}
    settings.write_text(json.dumps({'hooks': {
        'SessionStart': [{'hooks': [say('PROBE-P10-SESSIONSTART')]}],
        'PreToolUse': [{'matcher': 'Bash', 'hooks': [say('PROBE-P10-PRETOOLUSE')]}],
        'Stop': [{'hooks': [say('PROBE-P10-STOP'),
                            {'type': 'command', 'command': 'echo PROBE-P10-STDERR >&2; exit 0'}]}]}}))
    lead = Lead(ctx, 'P10', 'lead', ctx.lead_args(extra=['--settings', str(settings)]))
    try:
        lead.initialize()
        ask(lead, 'Run the Bash command true, then reply with exactly: ok', 180)
        time.sleep(3)
        alarms = lead.alarms()
        frames = lead.all_frames()
    finally:
        lead.close()
    r['alarms'] = [{'text': a['text'][:300], 'frame': a['frame'], 'hook_event': a.get('hook_event'),
                    'level': a.get('level')} for a in alarms]
    r['hook_frame_shapes'] = sorted(set('%s:%s' % (f.get('subtype'), ','.join(sorted(f.keys())))
                                        for f in frames if f.get('type') == 'system'
                                        and f.get('subtype') in ('hook_started', 'hook_progress', 'hook_response',
                                                                 'informational')))
    r['meta_assistant_frames'] = sum(1 for f in frames if f.get('type') == 'assistant' and f.get('is_meta'))
    def seen(marker, frame=None):
        return any(marker in a['text'] and (frame is None or a['frame'] == frame) for a in alarms)
    r['sessionstart'] = seen('PROBE-P10-SESSIONSTART')
    r['pretooluse'] = seen('PROBE-P10-PRETOOLUSE')
    r['stop_hook_response'] = seen('PROBE-P10-STOP', 'hook_response')
    r['stop_informational'] = seen('PROBE-P10-STOP', 'informational')
    r['stderr_as_alarm'] = seen('PROBE-P10-STDERR')
    r['stderr_anywhere_on_the_wire'] = any('PROBE-P10-STDERR' in json.dumps(f) for f in frames)
    r['banner'] = next((b for b in (parse_banner(dedupe_key(a['text'])) for a in alarms) if b), None)
    if r['stderr_as_alarm']:
        return 'PREMISE-FALSE', 'the stderr control appeared as an alarm'
    ok = r['sessionstart'] and r['pretooluse'] and r['stop_hook_response'] and r['stop_informational'] and r['banner']
    if ok:
        return 'PASS', 'SessionStart, PreToolUse and Stop arrived; Stop also as informational; banner readable'
    return 'FAIL', 'missing: %s' % [k for k in ('sessionstart', 'pretooluse', 'stop_hook_response',
                                               'stop_informational', 'banner') if not r[k]]


@probe('P11')
def p11(ctx, r):
    lead = Lead(ctx, 'P11', 'lead', ctx.lead_args())
    try:
        lead.initialize()
        ask(lead, 'Reply with exactly the word ready.', 180)
        lead_tools = sorted((lead.init_frame() or {}).get('tools') or [])
    finally:
        lead.close()
    r['lead_tools'] = lead_tools
    ipid, ifd, record, screen = interactive_session(ctx, r)
    tools_out = ctx.p.work / 'p11-interactive-tools.txt'
    try:
        type_into(ifd, 'Write the exact name of every tool you can call, one per line and nothing else, into the '
                       'file %s using the Write tool. Then reply done.' % tools_out, screen)
        deadline = time.time() + 240
        while time.time() < deadline and not (tools_out.exists() and tools_out.stat().st_size > 0):
            drain(ifd, screen, 1.0)
        time.sleep(3)
    finally:
        end_interactive(ipid, ifd)
    interactive = names_file(tools_out) or []
    r['interactive_tools_model_reported'] = interactive
    r['missing_from_lead'] = sorted(set(interactive) - set(lead_tools))
    r['only_in_lead'] = sorted(set(lead_tools) - set(interactive))
    disposition = {'AskUserQuestion': 'replaced by report(question): disallowed on purpose, spec (n)'}
    r['dispositions'] = {t: disposition.get(t, 'NEEDS A DISPOSITION FROM RICH') for t in r['missing_from_lead']}
    if not interactive:
        return 'PREMISE-FALSE', 'the interactive session did not list its tools'
    return 'RECORDED', '%d tools only in his terminal, each with a disposition in the result' % len(r['missing_from_lead'])


@probe('P12')
def p12(ctx, r):
    lead = Lead(ctx, 'P12', 'lead', ctx.lead_args())
    try:
        lead.initialize()
        (a_id, a_wt), (b_id, b_wt) = two_teammates(ctx, lead, r, 'p12')
        r['task_id_map'] = {'probe-sonnet-p12a': a_id, 'probe-sonnet-p12b': b_id}
        r['mapping_frame'] = 'system/task_started.tool_use_id -> the Agent tool_use block whose input.name is the teammate'
        if not (a_id and b_id and a_wt and b_wt):
            return 'NOT-RUN', 'two teammates could not be started or mapped (see spawn_a, spawn_b)'
        start = lead.count()
        lead.user(FIXTURE_NOTE + 'Run exactly this Bash command in the foreground and wait for it: sleep 45. Then reply slept.')
        busy = lead.wait(lambda f: f.get('type') == 'assistant' and any(
            b.get('type') == 'tool_use' and b.get('name') == 'Bash' for b in (f.get('message') or {}).get('content') or []),
            120, start)
        r['lead_in_shell'] = bool(busy)
        rid = lead.control('stop_task', task_id=a_id)
        reply = lead.wait(lambda f: f.get('type') == 'control_response' and
                          (f.get('response') or {}).get('request_id') == rid, 30)
        r['stop_task_reply'] = redact(reply[2]) if reply else None
        r['seconds_to_not_alive'], r['liveness_a'] = wait_not_alive(ctx, a_wt, 120)
        r['liveness_b'] = ctx.liveness(b_wt)
        done = lead.result_after(start, 120)
        r['lead_turn_result'] = done[2].get('subtype') if done else None
        r['lead_said'] = lead.text(start)[-400:]
        r['notification_a'] = [f.get('status') for f in lead.all_frames()
                               if f.get('subtype') == 'task_notification' and f.get('task_id') == a_id]
    finally:
        lead.close()
    detail = (r.get('liveness_a') or [None, {}])[1]
    r['signal_that_decided'] = json.dumps(detail)[:1500]
    if not r['lead_in_shell']:
        return 'PREMISE-FALSE', 'the lead never started its shell command, so stop_task did not land mid-turn'
    ok = r['seconds_to_not_alive'] is not None and r['liveness_b'][0] == 'ALIVE' and 'slept' in r['lead_said']
    if ok:
        return 'PASS', 'NOT-ALIVE in %s s; the other ALIVE; the lead\'s command finished' % r['seconds_to_not_alive']
    return 'FAIL', 'a: %s after %s s; b: %s; lead said %r' % ((r.get('liveness_a') or [None])[0], r['seconds_to_not_alive'],
                                                              r['liveness_b'][0], r['lead_said'][-80:])


def priority_order(ctx, r, key, use_priority):
    lead = Lead(ctx, 'P13', key, ctx.lead_args())
    try:
        lead.initialize()
        start = lead.count()
        lead.user(FIXTURE_NOTE + 'Run exactly this Bash command in the foreground and wait for it: sleep 25. Then reply with exactly: A-DONE')
        lead.wait(lambda f: f.get('type') == 'assistant' and any(
            b.get('type') == 'tool_use' and b.get('name') == 'Bash' for b in (f.get('message') or {}).get('content') or []),
            120, start)
        lead.user('Reply with exactly: MARK-B', priority='later' if use_priority else None)
        lead.user('Reply with exactly: MARK-C', priority='later' if use_priority else None)
        lead.user('Reply with exactly: MARK-D', priority='now' if use_priority else None)
        deadline = time.time() + 300
        while time.time() < deadline:
            text = lead.text(start)
            if all(m in text for m in ('MARK-B', 'MARK-C', 'MARK-D')):
                break
            time.sleep(2)
        text = lead.text(start)
    finally:
        lead.close()
    order = sorted((text.find(m), m) for m in ('A-DONE', 'MARK-B', 'MARK-C', 'MARK-D') if m in text)
    r[key + '_order'] = [m for _, m in order]
    return r[key + '_order']


@probe('P13')
def p13(ctx, r):
    main = priority_order(ctx, r, 'with-priority', True)
    control = priority_order(ctx, r, 'control-no-priority', False)
    if control and control[-1] != 'MARK-D':
        return 'PREMISE-FALSE', 'without priority, MARK-D was not handled last: %s' % control
    if main.index('MARK-D') < main.index('MARK-B') and main.index('MARK-D') < main.index('MARK-C') \
            if all(m in main for m in ('MARK-B', 'MARK-C', 'MARK-D')) else False:
        return 'PASS', 'now before later: %s; control %s' % (main, control)
    return 'FAIL', 'order with priority %s; control %s' % (main, control)


@probe('P14')
def p14(ctx, r):
    # Every question the platform still asks is answered NO, so nothing protected is written.
    lead = Lead(ctx, 'P14', 'lead', ctx.lead_args(), permission='deny')
    try:
        lead.initialize()
        # Three writes Claude Code is known to guard even in bypass mode: inside .git, a project
        # settings file, and an editor settings file. Each is scratch in this fixture. The
        # probe answers NO to every question, so nothing is actually written.
        start, got = do(lead, (
            'Make these three tool calls, one each, then reply done. It is expected that some of them are refused; '
            'that refusal is what the probe records. 1) Use the Write tool to create %s containing: probe note. '
            '2) Use the Write tool to create %s containing: {"probeMarker": true}. '
            '3) Use the Write tool to create %s containing: {}.') % (
            ctx.p.entity / '.git' / 'info' / 'probe-note.txt',
            ctx.p.entity / '.claude' / 'settings.json',
            ctx.p.entity / '.vscode' / 'settings.json'), 300)
        r['lead_said'] = lead.text(start)[-800:]
        r['tool_calls'] = [(b.get('name'), (b.get('input') or {}).get('file_path'))
                           for f in lead.all_frames()[start:] if f.get('type') == 'assistant'
                           for b in (f.get('message') or {}).get('content') or [] if b.get('type') == 'tool_use']
    finally:
        lead.close()
    r['requests_that_reached_the_host'] = lead.requests
    r['written'] = {str(x): x.exists() for x in (ctx.p.entity / '.git' / 'info' / 'probe-note.txt',
                                                  ctx.p.entity / '.claude' / 'settings.json',
                                                  ctx.p.entity / '.vscode' / 'settings.json')}
    if not r['tool_calls']:
        return 'PREMISE-FALSE', 'the lead made none of the three calls, so nothing could reach the host'
    return 'RECORDED', '%d control request(s) reached the host: %s' % (
        len(lead.requests), sorted(set('%s/%s' % (q['subtype'], q['tool_name']) for q in lead.requests)))


@probe('P15')
def p15(ctx, r):
    reaps = ctx.supervisor_reaps()
    r['supervisor_has_reap_descendants'] = reaps
    runs = [('control-no-reap', False)] + ([('reap', True)] if reaps else [])
    for key, reap in runs:
        rec = r.setdefault(key, {})
        fg, bg = ctx.p.work / ('p15-%s-fg.txt' % key), ctx.p.work / ('p15-%s-bg.txt' % key)
        # The trigger is the app's death (r3 (q) item 2: "the owner's death"): the owner
        # stand-in between this harness and the supervisor is killed, by its own pid.
        lead = Lead(ctx, 'P15', key, ctx.lead_args(), reap=reap, owner=True)
        recorded = []
        try:
            lead.initialize()
            rec['supervisor_pid'] = lead.supervisor_pid()
            rec['supervisor_pgid'] = pgid_of(rec['supervisor_pid']) if rec['supervisor_pid'] else None
            start = lead.count()
            lead.user(FIXTURE_NOTE + ('Make these two Bash calls, in this order. First, with run_in_background set to true: '
                       'bash -c \'echo self=$$ pgid=$(ps -o pgid= -p $$) tty=$(ps -o tty= -p $$) > %s; '
                       '(sleep 600 & echo grandchild=$! >> %s); sleep 600\'\n'
                       'Second, in the foreground: bash -c \'echo self=$$ pgid=$(ps -o pgid= -p $$) tty=$(ps -o tty= -p $$) > %s; '
                       '(sleep 600 & echo grandchild=$! >> %s); sleep 600\'') % (bg, bg, fg, fg))
            deadline = time.time() + 180
            while time.time() < deadline and not (fg.exists() and bg.exists() and
                                                  'grandchild' in fg.read_text() and 'grandchild' in bg.read_text()):
                time.sleep(1)
            rec['claude_pid'] = lead.claude_pid()
            rec['lead_pgid'] = pgid_of(rec['claude_pid']) if rec['claude_pid'] else None
            if rec['claude_pid']:
                recorded.append(('lead', rec['claude_pid']))
            for label, path in (('fg', fg), ('bg', bg)):
                values = dict(x.split('=', 1) for x in path.read_text().split() if '=' in x) if path.exists() else {}
                rec[label] = values
                for k in ('self', 'grandchild'):
                    if values.get(k, '').strip().isdigit():
                        recorded.append((label + '-' + k, int(values[k])))
            rec['own_group'] = {label: rec.get(label, {}).get('pgid', '').strip() not in ('', str(rec['lead_pgid']))
                                for label in ('fg', 'bg')}
            os.kill(lead.proc.pid, signal.SIGKILL)  # owned: the app stand-in this harness started
            grace = 5  # OPERATOR_REAP_GRACE's default (r3 (q) item 2)
            time.sleep(grace + 1)
            rec['alive_after_grace_plus_one'] = {name: alive(pid) for name, pid in recorded}
        finally:
            lead.close(grace=5)
            for name, pid in recorded:
                if alive(pid):
                    try:
                        os.kill(pid, signal.SIGKILL)  # owned: a pid our own lead or its command recorded
                    except ProcessLookupError:
                        pass
    control = r['control-no-reap']
    if not control.get('alive_after_grace_plus_one', {}).get('bg-self'):
        return 'PREMISE-FALSE', 'without --reap-descendants the background command did not survive, so the control shows nothing'
    if not reaps:
        return 'NOT-RUN', ('the process groups are recorded (own group: %s); the reap half needs provider-supervisor.py '
                           '--reap-descendants, which this engine does not have yet (r3 (q), zach)') % control.get('own_group')
    survivors = [n for n, a in r['reap']['alive_after_grace_plus_one'].items() if a]
    return ('PASS', 'all gone within the grace period plus one second') if not survivors else \
        ('FAIL', 'still alive: %s' % survivors)


# =============================================================================================
# driver
# =============================================================================================

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
    except Exception:  # noqa: BLE001
        setup['error'] = traceback.format_exc()
        (p.results / 'setup.json').write_text(json.dumps(setup, indent=1) + '\n')
        print('SETUP FAILED:\n' + setup['error'])
        return 2
    code, out, _ = run([GUEST_CLAUDE, '--version'])
    setup['claude_version'] = out.strip()
    ctx = Context(p, a.probe_timeout)
    setup['ssh_auth_sock_method'] = ctx.ssh_method
    setup['supervisor_python'] = ctx.python
    setup['stored_names'] = sorted(ctx.stored)
    (p.results / 'setup.json').write_text(json.dumps(setup, indent=1) + '\n')
    if a.survey:
        print(json.dumps(setup, indent=1))
        return 0
    wanted = [x.strip() for x in a.only.split(',') if x.strip()]
    summary = {'claude_version': setup['claude_version'], 'engine_commit': a.engine_commit, 'probes': {}}
    worst = 0
    for pid, fn in PROBES:
        if wanted and pid not in wanted:
            continue
        record = {'probe': pid, 'claude_version': setup['claude_version'], 'started': time.time()}
        print('=== %s' % pid, flush=True)
        try:
            verdict, why = fn(ctx, record)
        except Exception:  # noqa: BLE001
            verdict, why = 'ERROR', traceback.format_exc()[-3000:]
        record.update(verdict=verdict, why=why, seconds=round(time.time() - record['started'], 1))
        (p.results / ('%s.json' % pid)).write_text(json.dumps(redact(record), indent=1, default=str) + '\n')
        summary['probes'][pid] = {'verdict': verdict, 'why': why if verdict != 'ERROR' else why.splitlines()[-1]}
        print('%s %s: %s' % (pid, verdict, summary['probes'][pid]['why']), flush=True)
        if verdict in ('FAIL', 'PREMISE-FALSE'):
            worst = max(worst, 1)
        if verdict == 'ERROR':
            worst = 2
    (p.results / 'summary.json').write_text(json.dumps(summary, indent=1) + '\n')
    return worst


if __name__ == '__main__':
    sys.exit(main())
