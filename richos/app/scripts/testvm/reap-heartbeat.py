#!/usr/bin/env python3
"""heartbeat.py: a harmless test command. It writes a few small files into the folder it is given,
and does nothing else.

  python3 heartbeat.py beat NAME DIR [--seconds N]

It writes DIR/NAME.id once: its own process id, process group, session and start time, as one
line of JSON. Then it writes the current time to DIR/NAME.beat every 0.2 seconds, until N seconds
have passed (with no --seconds, until it is stopped). When it ends by itself it writes
DIR/NAME.done. It prints one line when it starts and one when it finishes.
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


def main(argv):
    seconds = 0.0
    if '--seconds' in argv:
        i = argv.index('--seconds')
        seconds = float(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    if argv[:1] == ['beat'] and len(argv) == 3:
        return beat(argv[1], argv[2], seconds)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
