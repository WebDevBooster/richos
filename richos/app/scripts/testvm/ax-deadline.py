#!/usr/bin/env python3
"""Guest-side deadline for AX calls. Kill the owned process group, including helpers."""
import os
import json
from pathlib import Path
import tempfile
import signal
import subprocess
import sys
import time


def phase_records():
    try:
        return [json.loads(line) for line in Path(os.environ['TESTVM_AX_PHASE_FILE']).read_text().splitlines()]
    except (KeyError, OSError, ValueError):
        return []


def host_phase():
    records = phase_records()
    phase = records[-1]['phase'] if records else 'preflight'
    if phase == 'transport':
        try:
            if '"ax_phase": "guest"' in Path(os.environ['TESTVM_AX_LOG_FILE']).read_text():
                return 'guest'
        except (KeyError, OSError):
            pass
    return phase


def timing(start, host, err):
    elapsed = time.monotonic() - start
    if not host:
        return {'ax_guest_seconds': round(elapsed, 4)}
    phases = phase_records() + [{'phase': 'done', 'at': time.monotonic()}]
    record = {'ax_timing': True, 'total_seconds': round(elapsed, 4)}
    for before, after in zip(phases, phases[1:]):
        record[before['phase'] + '_seconds'] = round(after['at'] - before['at'], 4)
    for line in err.decode(errors='replace').splitlines():
        try:
            guest = json.loads(line).get('ax_guest_seconds')
            if guest is not None:
                record['guest_seconds'] = guest
        except (ValueError, AttributeError):
            pass
    if 'transport_seconds' in record and 'guest_seconds' in record:
        # Residual includes remote startup and shell overhead, not pure SSH time.
        record['transport_overhead_seconds'] = round(max(0, record['transport_seconds'] - record['guest_seconds']), 4)
    return record


def timeout_record(host, err=b''):
    phase = host_phase() if host else 'guest'
    if phase == 'transport' and b'"ax_phase": "guest"' in err:
        phase = 'guest'
    return {'error': phase + '_deadline', 'phase': phase, 'status': 'effect_unknown',
            'detail': 'AX deadline reached; owned command group terminated; inspect before retrying'}


def run(command, source, seconds, host=False):
    began = time.monotonic()
    deadline = began + seconds
    if host:
        os.environ['TESTVM_AX_DEADLINE']=str(deadline)
    else:
        print(json.dumps({'ax_phase': 'guest'}), file=sys.stderr, flush=True)
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
    def stop(signum, _frame):
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        raise SystemExit(128 + signum)
    previous = {s: signal.signal(s, stop) for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    try:
        try:
            out, err = child.communicate(source, timeout=max(.01, seconds - 1))
            sys.stdout.buffer.write(out)
            sys.stdout.buffer.flush()
            sys.stderr.buffer.write(err)
            sys.stderr.buffer.flush()
            print(json.dumps(timing(began, host, err)), file=sys.stderr, flush=True)
            return child.returncode if child.returncode >= 0 else 128 - child.returncode
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            out, err = child.communicate()
            # Classification precedes partial output and process listings, also with head.
            print(json.dumps(timeout_record(host, err)), flush=True)
            sys.stdout.buffer.write(out)
            sys.stdout.buffer.flush()
            sys.stderr.buffer.write(err)
            sys.stderr.buffer.flush()
            print(json.dumps(timing(began, host, err)), file=sys.stderr, flush=True)
            # Process state is independent of a possibly blocked accessibility server.
            try:
                if host:
                    return 124
                state = subprocess.run(['ps', '-axo', 'pid,stat,comm'], capture_output=True,
                                       text=True, timeout=max(.01, deadline-time.monotonic()))
                for line in state.stdout.splitlines():
                    if any(x in line for x in ('SecurityAgent', 'richos-tauri', 'Safari')):
                        print(line, file=sys.stderr)
            except subprocess.TimeoutExpired:
                pass
            return 124
    finally:
        for s, handler in previous.items():
            signal.signal(s, handler)
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()


if __name__ == '__main__':
    host = sys.argv[1:2] == ['--host']
    if host: del sys.argv[1]
    seconds = float(sys.argv[1])
    if not 1 <= seconds <= 300:
        raise SystemExit('AX timeout must be between 1 and 300 seconds')
    command = sys.argv[2:] or ['osascript', '-l', 'JavaScript', '-']
    source = sys.stdin.buffer.read()
    if host:
        # Ephemeral diagnostics only. Never use the agent registry or a durable budget.
        with tempfile.TemporaryDirectory(prefix='testvm-ax-', dir=os.environ.get('TMPDIR')) as scratch:
            os.environ['TESTVM_AX_PHASE_FILE'] = str(Path(scratch) / 'phases.jsonl')
            os.environ['TESTVM_AX_LOG_FILE'] = str(Path(scratch) / 'guest.stderr')
            Path(os.environ['TESTVM_AX_PHASE_FILE']).write_text(json.dumps({'phase': 'preflight', 'at': time.monotonic()}) + '\n')
            raise SystemExit(run(command, source, seconds, host=True))
    raise SystemExit(run(command, source, seconds))
