#!/usr/bin/env python3
"""Persistent, per-user CPU circuit breaker. This is not a kernel CPU quota.

Ownership is explicit PID + birth identity, then observed ancestry, retained across
reparenting. Names never authorize signals. Sample CPU *time deltas*, not ps's
smoothed %cpu. Never signal a registered session, an unrelated process or a reused PID.
"""
import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

STATE = Path(os.environ.get('RICHOS_CPU_GUARD_STATE', '/Volumes/E1TB/state/richos/cpu-guard'))
INTERVAL = 2.0
WINDOW = 10.0
JOB_CORES = 3.0
TOTAL_FRACTION = .60
LABEL = 'com.richos.cpu-guard'


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.%s.new' % os.getpid())
    tmp.write_text(json.dumps(value))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def seconds(value):
    days, _, rest = value.partition('-')
    total = int(days) * 86400 if rest else 0
    parts = (rest or days).split(':')
    for i, part in enumerate(reversed(parts)):
        total += float(part) * 60 ** i
    return total


def processes():
    result = subprocess.run(['ps', '-ax', '-o', 'uid=,pid=,ppid=,time=,lstart=,comm='],
                            capture_output=True, text=True, check=True, timeout=5,
                            env={**os.environ, 'LC_ALL': 'C', 'TZ': 'UTC0'})
    rows = {}
    for line in result.stdout.splitlines():
        f = line.split(None, 9)
        if len(f) != 10 or int(f[0]) != os.getuid():
            continue
        rows[int(f[1])] = dict(parent=int(f[2]), cpu=seconds(f[3]),
                              birth=' '.join(f[4:9]), name=f[9])
    return rows


def register(pid, label, role='session'):
    rows = processes()
    if pid not in rows:
        raise ValueError('owner process is not alive or not owned by this user')
    record = dict(pid=pid, birth=rows[pid]['birth'], label=label, role=role)
    write_json(STATE / 'roots' / ('%s.json' % pid), record)
    return record


def event(message, **details):
    record = dict(at=time.time(), message=message, **details)
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / 'events.jsonl').open('a') as out:
        out.write(json.dumps(record) + '\n')
    write_json(STATE / 'alert.json', record)


def healthy():
    row = read_json(STATE / 'heartbeat.json', {})
    return time.time() - row.get('at', 0) < 12 and row.get('ok') is True


def host_ticks():
    if sys.platform != 'darwin':
        return None
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    library.mach_host_self.restype = ctypes.c_uint
    ticks = (ctypes.c_uint * 4)()
    count = ctypes.c_uint(4)
    if library.host_statistics(library.mach_host_self(), 3, ctypes.byref(ticks), ctypes.byref(count)):
        raise RuntimeError('host CPU counters unavailable')
    return list(ticks)


class Watch:
    def __init__(self):
        self.owned = read_json(STATE / 'owned.json', {})
        self.previous = {}
        self.last = None
        self.over = {}
        self.total_since = None
        self.pending = {}
        self.host_since = None
        self.reported_at = 0
        self.unowned_rates = {}

    def sample(self, rows, now, host_busy=0):
        roots = {}
        for path in (STATE / 'roots').glob('*.json'):
            rec = read_json(path)
            if rec and rows.get(rec['pid'], {}).get('birth') == rec['birth']:
                roots[rec['pid']] = rec
            elif rec:
                path.unlink(missing_ok=True)
        owned = {int(p): rec for p, rec in self.owned.items()
                 if rows.get(int(p), {}).get('birth') == rec['birth']}
        for pid, rec in roots.items():
            owned[pid] = dict(birth=rec['birth'], owner=rec['label'], root=pid)
        changed = True
        while changed:
            changed = False
            for pid, row in rows.items():
                if pid not in owned and row['parent'] in owned:
                    owned[pid] = {**owned[row['parent']], 'birth': row['birth']}
                    changed = True
        # Emulator launchers detach between samples. Their registry supplies the
        # exact generation; registry names or executable names alone do not.
        registry = Path(os.environ.get('RICHOS_TEST_DEVICES_DIR', str(Path.home() / '.claude/state/test-devices')))
        for path in registry.glob('*.json'):
            rec = read_json(path, {})
            gen = rec.get('generation') or {}
            pid = gen.get('pid')
            if rec.get('kind') == 'android-emulator' and pid in rows and rows[pid]['birth'] == gen.get('start'):
                owned[pid] = dict(birth=gen['start'], owner=rec.get('id'), root=pid)
        self.owned = {str(p): rec for p, rec in owned.items()}
        elapsed = now - self.last if self.last is not None else 0
        rates = {}
        for pid, rec in owned.items():
            old = self.previous.get(pid)
            if old and old['birth'] == rec['birth'] and elapsed > 0:
                rates[pid] = max(0, rows[pid]['cpu'] - old['cpu']) / elapsed
        self.unowned_rates = {pid: max(0, row['cpu'] - self.previous[pid]['cpu']) / elapsed
                              for pid, row in rows.items() if pid not in owned and elapsed > 0
                              and pid in self.previous and self.previous[pid]['birth'] == row['birth']}
        self.previous, self.last = rows, now
        # Sessions stay alive. A registered workload root may itself be stopped.
        protected = {p for p, r in roots.items() if r['role'] == 'session'} | {os.getpid()}
        allowed = set(owned) - protected - set(self.pending)
        total = sum(rates.get(p, 0) for p in allowed)
        if total > (os.cpu_count() or 4) * TOTAL_FRACTION or (host_busy >= 85 and total >= .5):
            self.total_since = self.total_since if self.total_since is not None else now
        else:
            self.total_since = None
        candidates = []
        for pid in allowed:
            rate = rates.get(pid, 0)
            if rate > JOB_CORES:
                self.over.setdefault((pid, rows[pid]['birth']), now)
            else:
                self.over.pop((pid, rows[pid]['birth']), None)
            since = self.over.get((pid, rows[pid]['birth']))
            if since is not None and now - since >= WINDOW:
                candidates.append(pid)
        if self.total_since is not None and now - self.total_since >= WINDOW and allowed:
            candidates.append(max(allowed, key=lambda p: rates.get(p, 0)))
        self.over = {k: v for k, v in self.over.items() if k[0] in allowed and rows[k[0]]['birth'] == k[1]}
        return sorted(set(candidates), key=lambda p: rates.get(p, 0), reverse=True), rates, protected

    def stop(self, pid, rows, protected, rates):
        # Expand only observed descendants. Never killpg on a potentially shared group.
        targets = {pid}
        while True:
            more = {p for p, row in rows.items() if row['parent'] in targets}
            if more <= targets:
                break
            targets |= more
        targets -= protected
        fresh = processes()
        signalled = {}
        for p in targets:
            if fresh.get(p, {}).get('birth') != rows[p]['birth']:
                continue
            try:
                os.kill(p, signal.SIGTERM)
                signalled[p] = rows[p]['birth']
                self.pending[p] = (rows[p]['birth'], time.monotonic() + 3)
            except ProcessLookupError:
                pass
        if not signalled:
            return
        event('CPU circuit breaker stopped an owned workload', pid=pid,
              executable=rows[pid]['name'], owner=self.owned[str(pid)]['owner'],
              cores=round(rates.get(pid, 0), 2), sustained_seconds=WINDOW,
              signalled=signalled)

    def reap(self, rows, now):
        for pid, row in rows.items():
            if pid not in self.pending and row['parent'] in self.pending:
                self.pending[pid] = (row['birth'], self.pending[row['parent']][1])
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for pid, (birth, deadline) in list(self.pending.items()):
            if rows.get(pid, {}).get('birth') != birth:
                del self.pending[pid]
            elif now >= deadline:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                del self.pending[pid]


def watch(engine):
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / 'watch.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        watcher = Watch()
        collector, collect_at = None, 0
        ticks_before = host_ticks()
        while True:
            try:
                rows = processes()
                now = time.monotonic()
                ticks = host_ticks()
                busy = 0
                if ticks is not None and ticks_before is not None:
                    delta = [(b-a) % 2**32 for a,b in zip(ticks_before, ticks)]
                    busy = 100 * (1 - delta[2]/sum(delta)) if sum(delta) else 0
                ticks_before = ticks
                candidates, rates, protected = watcher.sample(rows, now, busy)
                watcher.reap(rows, now)
                if candidates:
                    watcher.stop(candidates[0], rows, protected, rates)
                    watcher.total_since = None
                if busy >= 85:
                    watcher.host_since = watcher.host_since if watcher.host_since is not None else now
                    if not candidates and now-watcher.host_since >= WINDOW and now-watcher.reported_at >= 300:
                        top = sorted(watcher.unowned_rates, key=watcher.unowned_rates.get, reverse=True)[:3]
                        if top:
                            event('Host CPU is high; unregistered processes reported without signals',
                                  host_busy=round(busy,1), processes=[dict(pid=p,executable=rows[p]['name'],
                                  cores=round(watcher.unowned_rates[p],2)) for p in top])
                            watcher.reported_at = now
                else:
                    watcher.host_since = None
                write_json(STATE / 'owned.json', watcher.owned)
                write_json(STATE / 'heartbeat.json', dict(at=time.time(), ok=True,
                           pid=os.getpid(), owned=len(watcher.owned), host_busy=round(busy, 1)))
                if collector is not None and collector.poll() is not None:
                    if collector.returncode:
                        event('Device lease collector failed', exit_code=collector.returncode)
                    collector = None
                pressure = (watcher.host_since is not None and now-watcher.host_since >= WINDOW)
                if (now >= collect_at or pressure) and collector is None:
                    args = [sys.executable, str(Path(engine) / 'scripts/lib/testdevices.py'), 'expire-leases']
                    if pressure:
                        args.append('--pressure')
                        watcher.host_since = now
                    collector = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=sys.stderr)
                    collect_at = now + 15
            except Exception as exc:
                event('CPU watchdog sampling failed', error=str(exc))
                write_json(STATE / 'heartbeat.json', dict(at=time.time(), ok=False, error=str(exc)))
            time.sleep(INTERVAL)


def install(engine):
    if not os.path.ismount('/Volumes/E1TB'):
        raise RuntimeError('Mount /Volumes/E1TB first')
    runtime = STATE / 'runtime'
    runtime.mkdir(parents=True, exist_ok=True)
    target = runtime / 'cpu_guard.py'
    shutil.copy2(__file__, target)
    agent = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
    config = dict(Label=LABEL, ProgramArguments=['/usr/bin/python3', '-B', str(target), 'watch', str(Path(engine).resolve())],
                  RunAtLoad=True, KeepAlive=True, ThrottleInterval=5, ProcessType='Background',
                  EnvironmentVariables={'RICHOS_CPU_GUARD_STATE': str(STATE), 'LC_ALL': 'C'},
                  StandardOutPath='/dev/null', StandardErrorPath='/dev/null')
    agent.parent.mkdir(parents=True, exist_ok=True)
    with agent.open('wb') as out:
        plistlib.dump(config, out)
    domain = 'gui/%s' % os.getuid()
    subprocess.run(['launchctl', 'bootout', domain + '/' + LABEL], capture_output=True)
    subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], check=True)
    # A standalone user hook also covers cached/older engine plugins. The
    # canonical engine dispatcher is deliberately not a second registration.
    settings = Path.home() / '.claude/settings.json'
    original = settings.read_bytes() if settings.exists() else b'{}'
    backup = STATE / ('claude-settings-before-' + time.strftime('%Y%m%dT%H%M%S') + '.json')
    backup.write_bytes(original)
    backup.chmod(0o600)
    data = json.loads(original)
    hooks = data.setdefault('hooks', {})
    for name, matcher, action in [('PreToolUse', 'Bash', 'hook'), ('SessionStart', None, 'notice-json'), ('Stop', None, 'notice-json')]:
        entries = hooks.setdefault(name, [])
        command = '/usr/bin/python3 -B ' + shlex.quote(str(target)) + ' ' + action
        if not any(h.get('command') == command for e in entries for h in e.get('hooks', [])):
            entry = {'hooks': [{'type': 'command', 'command': command, 'timeout': 10}]}
            if matcher: entry['matcher'] = matcher
            entries.append(entry)
    write_json(settings, data)
    print(str(agent))


def shell_text(command):
    # Data in a quoted heredoc is not shell syntax. Shell-fed heredocs are
    # checked separately; malformed quoting outside them remains a refusal.
    lines = command.splitlines(keepends=True)
    output, bodies, i = [], [], 0
    while i < len(lines):
        line = lines[i]
        output.append(line)
        matches = list(re.finditer(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z_0-9]*)\1", line))
        i += 1
        for match in matches:
            body = []
            while i < len(lines) and lines[i].strip() != match.group(2):
                body.append(lines[i]); i += 1
            if i == len(lines):
                output.extend(body)
                break
            i += 1
            if re.search(r"(?:^|[;|&]\s*)(?:bash|sh|zsh)(?:\s|$)", line):
                bodies.append(''.join(body))
    return ''.join(output), bodies


def forbidden(command):
    """Conservative shell command-head check, not an arbitrary-code sandbox."""
    command, bodies = shell_text(command)
    for body in bodies:
        reason = forbidden(body)
        if reason: return reason
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|()\n')
        lexer.whitespace = ' \t\r'
        lexer.whitespace_split = True
        words = list(lexer)
    except ValueError:
        return 'unparseable shell command'
    chunks, chunk = [], []
    for word in words + [';']:
        if word and all(c in ';&|()\n' for c in word):
            if chunk: chunks.append(chunk)
            chunk = []
        else:
            chunk.append(word)
    for part in chunks:
        while part and (('=' in part[0] and not part[0].startswith('/')) or part[0] in ('then', 'do', 'exec', 'command', 'env', 'nohup', 'time', '!')):
            part.pop(0)
        if not part: continue
        name = os.path.basename(part[0])
        if name in ('bash', 'zsh', 'sh'):
            if '-c' in part:
                i = part.index('-c')
                if len(part) > i+1:
                    reason = forbidden(part[i+1])
                    if reason: return reason
            if len(part) > 1 and os.path.basename(part[1]) == 'gradlew': return 'gradlew'
        if name in ('nice', 'timeout'):
            rest = [p for p in part[1:] if not p.startswith('-') and not p.isdigit()]
            if rest:
                reason = forbidden(shlex.join(rest))
                if reason: return reason
        if name in ('gradle', 'gradlew', 'emulator') or name.startswith('qemu-system-'):
            if not any(p in part for p in ('--version', '-version', '--help', '-help', '-help-all', '--stop', '-list-avds')):
                return name
        if name == 'xcodebuild' and not any(p in part for p in ('-version', '-list', '-showsdks', '-showBuildSettings', '-help')):
            return name
        if name == 'swift' and len(part) > 1 and part[1] in ('build', 'test'): return 'swift ' + part[1]
        if name in ('xcrun', 'simctl') and 'boot' in part and (name == 'simctl' or 'simctl' in part): return 'simctl boot'
    return None


def hook():
    payload = json.load(sys.stdin)
    if payload.get('tool_name') != 'Bash':
        return 0
    # Fixture engine hooks must never enroll a real test runner or mutate real state.
    if os.environ.get('CLAUDE_CONFIG_DIR') and Path(os.environ['CLAUDE_CONFIG_DIR']).resolve() != (Path.home() / '.claude').resolve():
        return 0
    if Path.home().resolve() != Path(pwd.getpwuid(os.getuid()).pw_dir).resolve():
        return 0
    rows = processes()
    pid = os.getppid()
    for _ in range(30):
        row = rows.get(pid)
        if not row: break
        if os.path.basename(row['name']) == 'claude':
            register(pid, 'Claude session ' + str(payload.get('session_id', pid)))
            break
        pid = row['parent']
    reason = forbidden(payload.get('tool_input', {}).get('command', ''))
    if reason:
        print('CPU guard: direct %s is refused. Use randroid, rios or native-work.py -- COMMAND so admission and cleanup apply.' % reason, file=sys.stderr)
        return 2
    alert = read_json(STATE / 'alert.json')
    if alert:
        marker = STATE / 'notices' / (str(payload.get('session_id', 'unknown')).replace('/', '_') + '.json')
        previous = read_json(marker, {})
        if alert.get('at') != previous.get('at'):
            print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                             'additionalContext': 'CPU GUARD ALERT: ' + json.dumps(alert)}}))
            write_json(marker, {'at': alert.get('at')})
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['watch', 'install', 'register', 'hook', 'status', 'notice', 'notice-json'])
    parser.add_argument('args', nargs='*')
    a = parser.parse_args()
    if a.action == 'watch': return watch(a.args[0])
    if a.action == 'install': return install(a.args[0])
    if a.action == 'register': print(json.dumps(register(int(a.args[0]), a.args[1], a.args[2] if len(a.args)>2 else 'session')))
    if a.action == 'hook': return hook()
    if a.action == 'status':
        print(json.dumps(dict(healthy=healthy(), heartbeat=read_json(STATE/'heartbeat.json'), alert=read_json(STATE/'alert.json'))))
        return 0 if healthy() else 1
    if a.action in ('notice', 'notice-json'):
        alert = read_json(STATE/'alert.json')
        message = ''
        if not healthy(): message = 'CPU GUARD UNHEALTHY: native build and device admission is closed.'
        if alert: message += ' CPU GUARD ALERT: ' + json.dumps(alert)
        if message:
            if a.action == 'notice-json':
                payload = json.load(sys.stdin)
                result = {'systemMessage': message.strip()}
                if payload.get('hook_event_name') == 'SessionStart':
                    result['hookSpecificOutput'] = {'hookEventName':'SessionStart', 'additionalContext':message.strip()}
                print(json.dumps(result))
            else:
                print(message.strip())
    return 0


if __name__ == '__main__':
    sys.exit(main())
