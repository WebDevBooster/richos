#!/usr/bin/env python3
"""Run the operator back-end probes in a disposable test VM guest, never on the host.

Operator back-end spec r3 §5 (richos-hq docs/plans/2026-09-24-operator-back-end-spec-r3.md):
fifteen probes, each one short `claude` session with its control in the same run, run in
the test VM (CEO ruling §65, §68 point 5). This file is the host half: it takes the test
VM's guest lock and the CPU admission (CEO ruling §77, the same `reserve.reservation` the
walk runner uses), boots ONE fresh clone with `testvm/run.sh --no-app` (the host's claude
synced in, the host's login pushed, no app launched), copies in this harness and a
`git archive` of the engine at a named commit, runs `guest_probes.py` inside the guest in
the foreground, pulls the results back, and deletes the clone however the run ends (§54).

  run-probes.py --out DIR [--only P1,P2,...] [--engine-rev REV] [--wait SECONDS] [--survey]

Exit: the guest driver's exit code (0 when every probe that ran PASSED; 1 when any FAILED
or its premise was false; 2 for a harness failure), or 75 when admission was refused.

Results are private evidence: they go to the caller's --out, and from there to richos-hq
`docs/verification/`, never into this public repository. The guest driver records frames
with account data removed and environment NAMES only, never values.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
TESTVM = HERE.parent / 'testvm'
REPO = HERE.parents[3]
sys.path.insert(0, str(TESTVM))
from reserve import reservation  # noqa: E402


def sh(args, timeout=None, **kw):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout, **kw)


def guest(vm, command, timeout=120):
    result = sh([str(TESTVM / 'guest.sh'), vm, command], timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'guest command failed ({result.returncode}): {command}\n{result.stderr}{result.stdout}')
    return result.stdout.strip()


def running_clones():
    listing = sh(['bash', '-c', '. "$1/lib.sh"; preflight_tart >/dev/null; tart list --format json', 'probes', str(TESTVM)],
                 timeout=30)
    if listing.returncode:
        raise RuntimeError('tart could not be asked what is running: ' + listing.stderr)
    base = os.environ.get('TESTVM_BASE_VM', 'richos-base')
    return [r.get('Name') for r in json.loads(listing.stdout)
            if r.get('Source') == 'local' and r.get('Running') and r.get('Name') != base]


def engine_archive(rev, into):
    """The engine exactly as committed at `rev`, with the marketplace file that makes it a
    directory marketplace, as his terminal registers it (`~/.claude/settings.json`)."""
    sha = sh(['git', '-C', str(REPO), 'rev-parse', rev], timeout=30)
    if sha.returncode:
        raise RuntimeError(f'{rev} is not a commit in {REPO}')
    sha = sha.stdout.strip()
    tar = into / 'engine.tar'
    made = sh(['git', '-C', str(REPO), 'archive', '--format=tar', '-o', str(tar), sha,
               '.claude-plugin', 'richos/engine'], timeout=300)
    if made.returncode:
        raise RuntimeError('git archive failed: ' + made.stderr)
    return sha, tar


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--out', type=Path, required=True, help='host folder the results are pulled into')
    p.add_argument('--only', default='', help='comma-separated probe ids (default: all)')
    p.add_argument('--engine-rev', default='HEAD', help='the engine commit the guest runs (default HEAD)')
    p.add_argument('--wait', type=float, default=0, help='CPU admission wait, seconds (reserve.py rules)')
    p.add_argument('--survey', action='store_true', help='record the guest toolset only, run no probe')
    p.add_argument('--probe-timeout', type=int, default=900, help='seconds per probe inside the guest')
    a = p.parse_args()

    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    vm = 'probes-' + uuid.uuid4().hex[:12]
    root = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm')))
    report = {'vm': vm, 'started': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'outcome': 'harness failure'}

    def interrupted(signum, frame):
        raise KeyboardInterrupt('interrupted by signal ' + str(signum))
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)

    try:
        with reservation(lock=root / 'guest.lock', wait_seconds=a.wait):
            busy = running_clones()
            if busy:
                raise BlockingIOError('another clone is running (' + ', '.join(busy) + '); guest admission refused')
            with tempfile.TemporaryDirectory(prefix='operator-probes-', dir=os.environ.get('TMPDIR')) as scratch:
                scratch = Path(scratch)
                home = scratch / 'home'
                home.mkdir()
                sha, engine_tar = engine_archive(a.engine_rev, scratch)
                report['engine_commit'] = sha
                bundle = scratch / 'probes.tar'
                with tarfile.open(bundle, 'w') as t:
                    t.add(str(HERE / 'guest_probes.py'), arcname='probes/guest_probes.py')
                    t.add(str(engine_tar), arcname='probes/engine.tar')
                boot = subprocess.Popen([str(TESTVM / 'run.sh'), '--no-app', '--no-tailnet', '--vm', vm, '--home', str(home)],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
                try:
                    boot_out, boot_err = boot.communicate(timeout=480)
                except subprocess.TimeoutExpired:
                    os.killpg(boot.pid, signal.SIGTERM)
                    raise
                (out / 'boot.log').write_text(boot_err + '\n' + boot_out)
                if boot.returncode:
                    raise RuntimeError(f'run.sh --no-app failed ({boot.returncode}); see {out / "boot.log"}')
                payload = (root / 'run' / vm / 'payload').read_text().strip()
                report['payload'] = payload
                pushed = sh([str(TESTVM / 'guest.sh'), vm, '--push', str(bundle), payload + '/'], timeout=300)
                if pushed.returncode:
                    raise RuntimeError('the harness could not be copied in: ' + pushed.stderr)
                guest(vm, f'cd {shlex.quote(payload)} && tar -xf probes.tar && rm -f probes.tar')
                args = ['/usr/bin/python3', f'{payload}/probes/guest_probes.py', '--payload', payload,
                        '--engine-commit', sha, '--probe-timeout', str(a.probe_timeout)]
                if a.only:
                    args += ['--only', a.only]
                if a.survey:
                    args += ['--survey']
                command = ' '.join(shlex.quote(x) for x in args)
                began = time.monotonic()
                with open(out / 'guest-driver.log', 'w') as log:
                    driver = subprocess.run([str(TESTVM / 'guest.sh'), vm, command], stdout=log, stderr=subprocess.STDOUT,
                                            text=True, timeout=a.probe_timeout * 20 + 600)
                report['driver_seconds'] = round(time.monotonic() - began, 1)
                report['driver_exit'] = driver.returncode
                pulled = sh([str(TESTVM / 'guest.sh'), vm, '--pull', f'{payload}/results', str(out)], timeout=600)
                if pulled.returncode:
                    raise RuntimeError('the results could not be copied out: ' + pulled.stderr)
                report['outcome'] = 'completed'
                return driver.returncode
    except BlockingIOError as refused:
        report['outcome'] = 'admission refused: ' + str(refused)
        print(report['outcome'], file=sys.stderr)
        return 75
    except BaseException as failure:  # noqa: BLE001 - recorded, then the clone still goes
        report['error'] = repr(failure)
        print('probe run failed: ' + repr(failure), file=sys.stderr)
        return 2
    finally:
        if (root / 'run' / vm).exists():
            stopped = sh([str(TESTVM / 'stop.sh'), vm], timeout=300)
            report['cleanup'] = {'exit': stopped.returncode, 'said': (stopped.stdout + stopped.stderr)[-2000:]}
            try:
                report['clone_left'] = vm in running_clones()
            except Exception as error:  # noqa: BLE001
                report['clone_left'] = 'unknown: ' + repr(error)
        report['ended'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        (out / 'run-report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    sys.exit(main())
