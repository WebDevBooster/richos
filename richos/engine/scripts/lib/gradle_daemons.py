#!/usr/bin/env python3
"""A Gradle daemon kept warm for ONE workspace, and ended with it (2026-10-02).

    gradle_daemons.py status                 every recorded daemon, alive or not
    gradle_daemons.py stop --workspace PATH  end that workspace's daemons now

WHY. Until 2026-10-02 native-work.py ran every Gradle build with --no-daemon, and the
engine's supervisor (proc_tree.py) ends every descendant when a build command ends, so each
build started its JVM cold: a no-op Android release build cost 6.4-11.9 s, and an agent's job
makes a median of 5 Gradle builds (mean 8.8).

WHO A DAEMON BELONGS TO. One workspace (the git checkout a build runs in):
  - It is started in a registry that workspace alone uses
    (org.gradle.daemon.registry.base = GRADLE_USER_HOME/richos-daemons/<key>), so only that
    workspace's later builds can find it; another agent's build never connects to it.
  - proc_tree's supervisor releases it at the end of the build that started it only when it
    is a PROVEN member of that build's tree (birth generation tracked from the build's start)
    AND Gradle recorded it as a daemon in that registry (daemon-<pid>.out.log, written at its
    start). Its descendants go with it. Everything else the build started is ended exactly as
    before. A process name never decides anything.
  - It is recorded here by PID and birth generation, and every signal re-reads the generation.

HOW ITS CPU IS COUNTED WHILE IT IS ALIVE.
  - Watchdog: it is registered with cpu_guard as a native-build root in its workspace's group,
    with the grant of the build it last served (re-granted at every admission that reuses it).
    Its CPU and its children's count with the build's own tree against ONE grant; above the
    grant, the ordinary per-process rule applies to it. It is never an unregistered process.
  - Admission: native-work admits on total host CPU (user + system) and memory pressure, which
    include the daemon like everything else. An idle daemon uses no measurable CPU and holds
    no machine worker and no compiler lane; a build that uses it holds both, as every build
    does. Its heap (-Xmx1536m) stays resident until it ends: memory pressure counts it.

HOW IT ENDS. Its own idle timeout (org.gradle.daemon.idletimeout, 2 minutes, set by
native-work on every build) after the workspace's last build; at once when the workspace is
landed or discarded (mega-lander/workspaces.py stop_processes() stops what owned_pids()
returns, then forget() drops the record and the registry); at once when a build needs a
different processor count (prepare()); or by hand with `stop --workspace`.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

import operator_fences

IDLE_TIMEOUT_MS = 120000
# Restart a warm daemon for more processors only when the grant has grown by this many:
# a cold start costs a few seconds; a narrower daemon costs that only on large compiles.
WIDEN_AT = 2
STOP_GRACE = 10.0
LOG = re.compile(r'daemon-(\d+)\.out\.log$')


def directory():
    return Path(os.environ.get('RICHOS_GRADLE_DAEMONS') or
                Path.home() / '.richos-nightly' / 'gradle-daemons-v1')


def workspace_of(path):
    """The git checkout `path` is in (its realpath); `path` itself outside a checkout."""
    path = os.path.realpath(path)
    try:
        top = subprocess.run(['git', '-C', path, 'rev-parse', '--show-toplevel'],
                             capture_output=True, text=True, timeout=30)
        if top.returncode == 0 and top.stdout.strip():
            return os.path.realpath(top.stdout.strip())
    except (OSError, subprocess.TimeoutExpired):
        pass
    return path


def key(workspace):
    return hashlib.sha256(os.path.realpath(workspace).encode()).hexdigest()[:16]


def gradle_home(env=None):
    env = os.environ if env is None else env
    return env.get('GRADLE_USER_HOME') or str(Path.home() / '.gradle')


def registry(workspace, home):
    return str(Path(home) / 'richos-daemons' / key(workspace))


def released_path(registry_dir):
    """Where proc_tree's supervisor writes what it released (beside the registry, not in it)."""
    return str(registry_dir).rstrip('/') + '.released.json'


def record_path(workspace):
    return directory() / (key(workspace) + '.json')


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (FileNotFoundError, ValueError):
        return default


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.%d.new' % os.getpid())
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    os.replace(tmp, path)


def load(workspace):
    return read_json(record_path(workspace))


def announced(registry_dir):
    """{pid: log mtime} for every daemon Gradle recorded in this registry (any version)."""
    found = {}
    try:
        versions = os.listdir(registry_dir)
    except OSError:
        return found
    for version in versions:
        folder = os.path.join(registry_dir, version)
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for name in names:
            match = LOG.fullmatch(name)
            if match:
                try:
                    found[int(match.group(1))] = os.stat(os.path.join(folder, name)).st_mtime
                except OSError:
                    pass
    return found


def started_seconds(generation):
    """Whole seconds since the epoch from a precise generation ("darwin:<sec>:<usec>"), or None."""
    try:
        return int(str(generation).split(':')[1])
    except (IndexError, ValueError):
        return None


def is_announced_daemon(pid, generation, registry_dir):
    """Gradle recorded THIS process (not an earlier holder of its PID) as a daemon here: the
    log named after its PID was written at or after its start."""
    mtime = announced(registry_dir).get(pid)
    start = started_seconds(generation)
    return mtime is not None and (start is None or mtime >= start - 1)


def live(record):
    """{pid: info} for the record's daemons that are still the same processes."""
    alive = {}
    for raw, info in ((record or {}).get('daemons') or {}).items():
        row = operator_fences.proc(int(raw), precise=True)
        if row and not row['zombie'] and row['start'] == info.get('generation'):
            alive[int(raw)] = info
    return alive


def descendants(pids):
    """Live descendants of `pids` by the CURRENT parent links, with their generations."""
    import proc_tree
    rows = proc_tree.process_rows()
    found = {pid: rows[pid][2] for pid in pids if pid in rows}
    grew = True
    while grew:
        grew = False
        for pid, (parent, _group, generation) in rows.items():
            if pid not in found and parent in found and generation:
                found[pid] = generation
                grew = True
    return found


def end(members, grace=STOP_GRACE):
    """TERM, wait, KILL: only processes whose generation still matches. Returns survivors."""
    def matching():
        return {pid: gen for pid, gen in members.items()
                if (row := operator_fences.proc(pid, precise=True)) and not row['zombie'] and row['start'] == gen}
    for pid in matching():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + grace
    while matching() and time.monotonic() < deadline:
        time.sleep(0.1)
    for pid in matching():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while matching() and time.monotonic() < deadline:
        time.sleep(0.05)
    return sorted(matching())


def stop(workspace, grace=STOP_GRACE):
    """End the workspace's daemons and their descendants; drop the record when none survive."""
    alive = live(load(workspace))
    members = descendants(alive) if alive else {}
    for pid, info in alive.items():
        members.setdefault(pid, info['generation'])
    survivors = end(members, grace) if members else []
    if not survivors:
        forget([workspace])
    return {'stopped': sorted(members), 'survivors': survivors}


def prepare(workspace, home, processors):
    """Plan this build's daemon: reuse the workspace's warm one when the grant still covers it
    and would not widen it by WIDEN_AT processors or more; otherwise end it and start fresh.
    Returns {'registry', 'processors', 'reused', 'stopped'}."""
    processors = max(1, int(processors))
    record = load(workspace) or {}
    alive = live(record)
    reg = record.get('registry') or registry(workspace, home)
    if alive:
        held = max(int(info.get('processors', 1)) for info in alive.values())
        if held <= processors < held + WIDEN_AT and reg == registry(workspace, home):
            return {'registry': reg, 'processors': held, 'reused': True, 'stopped': []}
        result = stop(workspace)
        if result['survivors']:
            raise RuntimeError('the warm Gradle daemon of %s did not stop: %s' % (workspace, result['survivors']))
        return {'registry': registry(workspace, home), 'processors': processors, 'reused': False,
                'stopped': result['stopped']}
    return {'registry': registry(workspace, home), 'processors': processors, 'reused': False, 'stopped': []}


def regrant(workspace, cores, register):
    """Re-register the workspace's live daemons with the grant of the build about to use them."""
    for pid in live(load(workspace)):
        try:
            register(pid, 'gradle daemon: ' + workspace, cores)
        except (ValueError, RuntimeError):
            pass


def adopt(workspace, plan, cores, register):
    """After a build: record the daemon(s) its supervisor released, register each with the
    watchdog in the workspace's group. Returns the live daemons now recorded."""
    reg = plan['registry']
    path = Path(released_path(reg))
    released = read_json(path, {}).get('released') or []
    path.unlink(missing_ok=True)
    record = load(workspace) or {}
    daemons = {str(pid): info for pid, info in live(record).items()}
    for item in released:
        daemons[str(item['pid'])] = {'generation': item['generation'], 'processors': plan['processors'],
                                     'adopted_at': time.time()}
    record = {'workspace': workspace, 'registry': reg, 'daemons': daemons, 'grant': cores, 'updated': time.time()}
    alive = live(record)
    record['daemons'] = {str(pid): info for pid, info in alive.items()}
    if record['daemons']:
        write_json(record_path(workspace), record)
    else:
        record_path(workspace).unlink(missing_ok=True)
    for pid in alive:
        try:
            register(pid, 'gradle daemon: ' + workspace, cores)
        except (ValueError, RuntimeError):
            pass
    return alive


def records():
    out = []
    for path in sorted(directory().glob('*.json')):
        record = read_json(path)
        if isinstance(record, dict) and record.get('workspace'):
            out.append(record)
    return out


def within(workspace, paths):
    workspace = os.path.realpath(workspace)
    for path in paths:
        path = os.path.realpath(path)
        if workspace == path or workspace.startswith(path + os.sep):
            return True
    return False


def owned_pids(paths):
    """The live daemons recorded for workspaces at or inside `paths` (generation-checked)."""
    pids = []
    for record in records():
        if within(record['workspace'], paths):
            pids.extend(live(record))
    return sorted(set(pids))


def forget(paths):
    """Drop the records (and their private registries) of workspaces at or inside `paths`
    that have no live daemon left. A record with a live daemon is kept: it is still owned."""
    dropped = []
    for record in records():
        if not within(record['workspace'], paths) or live(record):
            continue
        record_path(record['workspace']).unlink(missing_ok=True)
        reg = record.get('registry')
        if reg and Path(reg).parent.name == 'richos-daemons':
            shutil.rmtree(reg, ignore_errors=True)
            Path(released_path(reg)).unlink(missing_ok=True)
        dropped.append(record['workspace'])
    return dropped


def main(argv):
    if argv[:1] == ['status']:
        rows = []
        for record in records():
            alive = live(record)
            rows.append({'workspace': record['workspace'], 'registry': record.get('registry'),
                         'grant': record.get('grant'),
                         'daemons': [{'pid': int(pid), 'alive': int(pid) in alive, **info}
                                     for pid, info in (record.get('daemons') or {}).items()]})
        print(json.dumps(rows, indent=2))
        return 0
    if argv[:2] == ['stop', '--workspace'] and len(argv) == 3:
        result = stop(workspace_of(argv[2]))
        print(json.dumps(result))
        return 1 if result['survivors'] else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
