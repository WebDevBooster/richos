#!/usr/bin/env python3
"""mem-walk.py — what a walk's guest actually uses in memory, sampled inside the guest while the walk runs.

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      mem-walk.py --out DIR [--every SECONDS] -- spelling-walk.py --out DIR2 ...

run-walk.py passes the owned VM name as the first argument; mem-walk.py hands it on as the inner
walk's first argument, runs that walk in the foreground and returns its exit code.

WHY. A guest is given TESTVM_RAM_MB (lib.sh) and the host must keep that much free for
it (slots.py's memory admission). On this 24 GB Mac two such guests do not fit beside the usual
load (measured 2026-09-27 18:56Z: 120 MB/s swap-out). What a guest NEEDS is a measurement, not
the allocation: this samples, every --every seconds while the walk runs, inside the guest:

  used_mb       app memory + wired + compressed, as Activity Monitor counts "Memory Used"
                (vm_stat: anonymous - purgeable + wired down + occupied by compressor)
  need_mb       total less the kernel's own available level (kern.memorystatus_level), the
                same measure slots.py admits a guest by on the host
  swapouts      the guest's own cumulative swap-outs (vm_stat): any rise means the guest is short
  top           the resident size of the app (richos-tauri) and every claude process

and on the host the VM processes' resident memory, CPU, memory pressure, available memory and
swap-out (reserve.host_sample). Writes <out>/mem.json with every sample and
the peaks. Nothing here quits anything: run-walk.py's stop.sh does (CEO §54).
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import reserve  # noqa: E402
from relaunch import guest  # noqa: E402
from slots import guest_ram_mb, vm_resident_mb  # noqa: E402

PROBE = ('vm_stat; echo "hw.memsize: $(sysctl -n hw.memsize)"; '
         'echo "memorystatus_level: $(sysctl -n kern.memorystatus_level)"; '
         "ps -A -o rss=,comm= | awk '$2 ~ /(^|\\/)(richos-tauri|claude)$/ {print \"proc: \" $0}'")


def parse(text):
    """One probe's output -> the sample fields (pure, so the suite tests it on recorded text)."""
    page = int(re.search(r'page size of (\d+) bytes', text).group(1))
    pages = {k.strip().lower(): int(v) for k, v in re.findall(r'^"?([A-Za-z -]+)"?:\s+(\d+)\.', text, re.M)}
    total = int(re.search(r'hw.memsize: (\d+)', text).group(1))
    level = int(re.search(r'memorystatus_level: (\d+)', text).group(1))
    used = (pages.get('anonymous pages', 0) - pages.get('pages purgeable', 0) + pages.get('pages wired down', 0)
            + pages.get('pages occupied by compressor', 0)) * page
    procs = []
    for rss, comm in re.findall(r'^proc:\s+(\d+)\s+(\S.*)$', text, re.M):
        procs.append({'name': comm.rsplit('/', 1)[-1], 'rss_mb': round(int(rss) / 1024)})
    return {'total_mb': round(total / 1048576), 'used_mb': round(used / 1048576),
            'need_mb': round(total / 1048576 * (100 - level) / 100), 'available_percent': level,
            'swapouts': pages.get('swapouts', 0), 'top': procs}


def main():
    argv = sys.argv[1:]
    if '--' not in argv:
        sys.exit('mem-walk.py: the inner walk goes after --')
    cut = argv.index('--')
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--every', type=float, default=5, help='seconds between samples (at least 2)')
    a = p.parse_args(argv[:cut])
    inner = argv[cut + 1:]
    if not inner or a.every < 2:
        p.error('an inner walk is required after --, and --every is at least 2 seconds')
    a.out.mkdir(parents=True, exist_ok=True)
    samples, stop = [], threading.Event()

    def sample():
        while not stop.is_set():
            at = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
            try:
                row = parse(guest(a.vm, PROBE, 20))
                h = reserve.host_sample()
                row.update(at=at, host_vm_resident_mb=[round(r) for r in vm_resident_mb()],
                           host={'cpu_busy_percent': round(h['cpu_user_percent'] + h['cpu_system_percent'], 1),
                                 'memory_pressure': h['memory_pressure'], 'available_percent': h['memory_free_percent'],
                                 'swapout_mb_per_s': round(h['swapout_mb_per_s'], 1)})
                samples.append(row)
            except Exception as exc:  # noqa: BLE001 - a missed sample is recorded, never fatal to the walk
                samples.append({'at': at, 'error': str(exc)[:200]})
            stop.wait(a.every)

    sampler = threading.Thread(target=sample, daemon=True)
    sampler.start()
    began = time.monotonic()
    rc = subprocess.run([inner[0], a.vm, *inner[1:]]).returncode
    stop.set()
    sampler.join(timeout=30)
    good = [s for s in samples if 'error' not in s]
    peaks = {}
    if good:
        peaks = {'used_mb': max(s['used_mb'] for s in good), 'need_mb': max(s['need_mb'] for s in good),
                 'min_available_percent': min(s['available_percent'] for s in good),
                 'swapouts_during_walk': good[-1]['swapouts'] - good[0]['swapouts'],
                 'host_vm_resident_mb': max((max(s['host_vm_resident_mb'] or [0]) for s in good), default=0),
                 'app_rss_mb': max((t['rss_mb'] for s in good for t in s['top'] if t['name'] == 'richos-tauri'),
                                   default=0),
                 'claude_rss_mb_total': max((sum(t['rss_mb'] for t in s['top'] if t['name'] == 'claude')
                                             for s in good), default=0)}
    record = {'vm': a.vm, 'ram_mb': guest_ram_mb(), 'inner': inner,
              'inner_exit': rc, 'seconds': round(time.monotonic() - began), 'samples': samples,
              'sample_errors': len(samples) - len(good), 'peaks': peaks}
    (a.out / 'mem.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'ram_mb': record['ram_mb'], 'inner_exit': rc, 'peaks': peaks}), flush=True)
    return rc


if __name__ == '__main__':
    sys.exit(main())
