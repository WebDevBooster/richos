#!/usr/bin/env python3
"""smoke-walk.py — the app booted in this run's guest is alive, and what the host carried meanwhile.

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      smoke-walk.py --out DIR [--observe SECONDS]

run-walk.py passes the owned VM name as the first argument.

WHAT IT ANSWERS. The smallest real-app question a guest can be asked: did run.sh's launch leave the
app process running in this guest (its recorded pid, read back by name in the guest), and how
many windows does it have. With --observe it then stays for that many seconds, still one run,
sampling the host every 10 s (reserve.host_sample: CPU split, memory pressure, free memory,
swap-out), the running guests (tart's own list) and each VM process's resident memory, so two
runs side by side record what two guests cost this Mac. It quits nothing itself: run-walk.py quits the app by its pid, stops the
guest and deletes the clone (CEO §54).

Writes <out>/smoke.json. Exit 0 when the app is alive with at least one window, else 1.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import reserve  # noqa: E402
from relaunch import guest  # noqa: E402
from slots import running_guests, vm_resident_mb  # noqa: E402


def utc():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--observe', type=float, default=0, help='seconds to stay and sample the host (at most 1800)')
    a = p.parse_args()
    if not 0 <= a.observe <= 1800:
        p.error('--observe must be from 0 to 1800 seconds')
    a.out.mkdir(parents=True, exist_ok=True)
    state = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm'))) / 'run' / a.vm
    pid = (state / 'app.pid').read_text().strip()
    if not pid.isdigit():
        raise SystemExit('recorded app pid is not numeric')
    record = {'vm': a.vm, 'slot': (state / 'slot').read_text().strip(), 'started': utc(), 'app_pid': int(pid)}
    command = guest(a.vm, f'ps -p {pid} -o comm= 2>/dev/null || true')
    record['app_alive'] = command.endswith('/richos-tauri')
    windows = guest(a.vm, "osascript -e 'tell application \"System Events\" to count windows of "
                          f"(first process whose unix id is {pid})' 2>/dev/null || echo 0")
    record['windows'] = int(windows) if windows.isdigit() else 0
    samples = []
    deadline = time.monotonic() + a.observe
    while True:
        s = reserve.host_sample()
        samples.append({'at': utc(), 'running_guests': running_guests(),
                        'vm_resident_mb': [round(r) for r in vm_resident_mb()],
                        'cpu_busy_percent': round(s['cpu_user_percent'] + s['cpu_system_percent'], 1),
                        'memory_pressure': s['memory_pressure'], 'memory_free_percent': s['memory_free_percent'],
                        'swapout_mb_per_s': round(s['swapout_mb_per_s'], 1), 'swap_used_mb': round(s['swap_used_mb'])})
        if time.monotonic() >= deadline:
            break
        time.sleep(min(10, max(0, deadline - time.monotonic())))
    record['host'] = samples
    record['ended'] = utc()
    (a.out / 'smoke.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({k: record[k] for k in ('vm', 'slot', 'app_alive', 'windows')}))
    return 0 if record['app_alive'] and record['windows'] >= 1 else 1


if __name__ == '__main__':
    sys.exit(main())
