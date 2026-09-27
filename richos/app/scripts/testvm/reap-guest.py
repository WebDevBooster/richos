#!/usr/bin/env python3
"""reap-guest.py — the guest-side half of reap-walk.py. Pushed into the guest; never run on the host.

  reap-guest.py beat NAME DIR [--seconds N]
      A tool command for Rich to run. It records ITSELF in DIR/NAME.id, as JSON on one line:
      {"name", "pid", "pgid", "sid", "start"} (start = its start time from `ps -o lstart=`, an
      identity rather than a clock), then writes the guest's time to DIR/NAME.beat every 0.2 s
      until --seconds pass (default: forever), and on a natural end writes DIR/NAME.done.
      Nothing is inferred about it: the harness grades only commands that recorded themselves.

  reap-guest.py watch DIR OUT [--seconds N]
      The death watcher. Every 50 ms it reads DIR/*.id and, for each recorded process, notes on
      the guest's clock (ms) the first moment `kill(pid, 0)` says it is gone, or its pid answers
      with a different start. One JSON line per event in OUT: {"kind": "watch-start"},
      {"kind": "seen", "name", ...identity}, {"kind": "gone", "name", "t_ms"}.

  reap-guest.py group PGID
      Prints the pids still in process group PGID, one per line (none: nothing printed).

  reap-guest.py record OUT [--seconds N]
      Every 0.5 s for N seconds (default 120), appends the guest's time and its process table
      (pid, ppid, pgid, session, command) to OUT: what a lease actually started, when.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def start_of(pid):
    r = subprocess.run(['/bin/ps', '-o', 'lstart=', '-p', str(pid)], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ''


def beat(name, directory, seconds):
    d = Path(directory)
    d.mkdir(parents=True, exist_ok=True)
    me = {'name': name, 'pid': os.getpid(), 'pgid': os.getpgrp(), 'sid': os.getsid(0), 'start': start_of(os.getpid())}
    tmp = d / (name + '.id.tmp')
    tmp.write_text(json.dumps(me) + '\n')
    os.replace(tmp, d / (name + '.id'))
    print('%s is running as pid %d in process group %d' % (name, me['pid'], me['pgid']), flush=True)
    end = time.monotonic() + seconds if seconds else None
    while end is None or time.monotonic() < end:
        (d / (name + '.beat')).write_text('%d\n' % int(time.time() * 1000))
        time.sleep(0.2)
    (d / (name + '.done')).write_text('%d\n' % int(time.time() * 1000))
    print('%s finished' % name, flush=True)


def alive(pid, start):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    now = start_of(pid)
    return bool(now) and now == start


def watch(directory, out, seconds):
    d = Path(directory)
    seen, gone = {}, set()
    end = time.monotonic() + seconds
    with open(out, 'a', encoding='utf-8') as fh:
        def emit(row):
            row['t_ms'] = int(time.time() * 1000)
            fh.write(json.dumps(row, sort_keys=True) + '\n')
            fh.flush()
        emit({'kind': 'watch-start'})
        while time.monotonic() < end:
            for path in sorted(d.glob('*.id')):
                try:
                    me = json.loads(path.read_text())
                except (OSError, ValueError):
                    continue
                key = (me['name'], me['pid'], me['start'])
                if key not in seen:
                    seen[key] = me
                    emit(dict(me, kind='seen'))
                if key not in gone and not alive(me['pid'], me['start']):
                    gone.add(key)
                    emit({'kind': 'gone', 'name': me['name'], 'pid': me['pid'], 'pgid': me['pgid']})
            time.sleep(0.05)


def group(pgid):
    r = subprocess.run(['/bin/ps', '-A', '-o', 'pid=,pgid=,stat='], capture_output=True, text=True, check=True)
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and int(parts[1]) == pgid and not parts[2].startswith('Z'):
            print(parts[0])


def record(out, seconds):
    end = time.monotonic() + seconds
    with open(out, 'a', encoding='utf-8') as fh:
        while time.monotonic() < end:
            r = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,sess=,command='], capture_output=True, text=True)
            fh.write('@ %d\n' % int(time.time() * 1000))
            fh.write(''.join(line[:220] + '\n' for line in r.stdout.splitlines()))
            fh.flush()
            time.sleep(0.5)


def main(argv):
    seconds = 0.0
    if '--seconds' in argv:
        i = argv.index('--seconds')
        seconds = float(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    if argv[:1] == ['beat'] and len(argv) == 3:
        return beat(argv[1], argv[2], seconds)
    if argv[:1] == ['watch'] and len(argv) == 3:
        return watch(argv[1], argv[2], seconds or 3600)
    if argv[:1] == ['group'] and len(argv) == 2:
        return group(int(argv[1]))
    if argv[:1] == ['record'] and len(argv) == 2:
        return record(argv[1], seconds or 120)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
