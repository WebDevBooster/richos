#!/usr/bin/env python3
"""Copy one or more probe runs' results into a private verification folder, bounded.

  record.py --into <richos-hq>/docs/verification/<date>-operator-probes RUN_DIR [RUN_DIR ...]

Later runs win: a probe's newest result replaces an older one, so the folder holds the last
measurement of each probe plus every run's report. Results come from run-probes.py already
redacted (no account data; environments as names only); this adds one more bound: any string
longer than MAX_STRING characters inside a session's frames is cut, and the cut is marked in
place with its original length, because a 1M-token session (P7) is tens of megabytes of file
text nobody reads and the record is about the frames around it.

Never writes into the public repository: it refuses a destination inside a Git work tree whose
remote is the public richos repository.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

MAX_STRING = 4000


def bound(value):
    if isinstance(value, dict):
        return {k: bound(v) for k, v in value.items()}
    if isinstance(value, list):
        return [bound(v) for v in value]
    if isinstance(value, str) and len(value) > MAX_STRING:
        return value[:MAX_STRING] + '… [cut by record.py: %d characters in the run]' % len(value)
    return value


def public(dest):
    top = subprocess.run(['git', '-C', str(dest), 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    if top.returncode:
        return False
    remote = subprocess.run(['git', '-C', str(dest), 'remote', 'get-url', 'origin'], capture_output=True, text=True)
    return remote.returncode == 0 and remote.stdout.strip().rstrip('/').endswith(('/richos', '/richos.git', ':richos.git'))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--into', type=Path, required=True)
    ap.add_argument('runs', nargs='+', type=Path)
    a = ap.parse_args()
    dest = a.into.resolve()
    dest.mkdir(parents=True, exist_ok=True)
    if public(dest):
        sys.exit('refusing: %s is inside the public richos repository; probe results are private evidence' % dest)
    summary = {}
    for run in a.runs:
        results = run / 'results'
        if not results.is_dir():
            sys.exit('%s has no results folder' % run)
        (dest / 'runs').mkdir(exist_ok=True)
        for name in ('run-report.json', 'guest-driver.log'):
            if (run / name).exists():
                shutil.copyfile(run / name, dest / 'runs' / ('%s-%s' % (run.name, name)))
        run_summary = json.loads((results / 'summary.json').read_text()) if (results / 'summary.json').exists() else {}
        probes = list((run_summary.get('probes') or {}).keys())
        for probe in probes:
            for old in dest.glob('%s.json' % probe):
                old.unlink()
            for old in dest.glob('%s-*' % probe):
                old.unlink()
            for src in results.glob('%s*' % probe):
                if not (src.name == '%s.json' % probe or src.name.startswith('%s-' % probe)):
                    continue
                if src.suffix == '.jsonl':
                    with open(src) as fin, open(dest / src.name, 'w') as fout:
                        for line in fin:
                            row = json.loads(line)
                            fout.write(json.dumps(bound(row)) + '\n')
                else:
                    shutil.copyfile(src, dest / src.name)
            summary[probe] = dict(run_summary['probes'][probe], run=run.name,
                                  claude_version=run_summary.get('claude_version'),
                                  engine_commit=run_summary.get('engine_commit'))
        if (results / 'setup.json').exists():
            shutil.copyfile(results / 'setup.json', dest / 'runs' / ('%s-setup.json' % run.name))
    merged = dest / 'summary.json'
    existing = json.loads(merged.read_text()) if merged.exists() else {}
    existing.update(summary)
    merged.write_text(json.dumps(dict(sorted(existing.items(), key=lambda kv: int(kv[0][1:]))), indent=1) + '\n')
    print(json.dumps(existing, indent=1))


if __name__ == '__main__':
    main()
