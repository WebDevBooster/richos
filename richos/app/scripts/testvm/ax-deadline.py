#!/usr/bin/env python3
"""Guest-side deadline for AX calls. Kill the owned process group, including helpers."""
import os
import signal
import subprocess
import sys
import time


def run(command, source, seconds, host=False):
    deadline = time.monotonic() + seconds
    if host:
        os.environ['TESTVM_AX_DEADLINE']=str(deadline)
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
            sys.stderr.buffer.write(err)
            return child.returncode if child.returncode >= 0 else 128 - child.returncode
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            out, err = child.communicate()
            sys.stdout.buffer.write(out)
            sys.stderr.buffer.write(err)
            # Process state is independent of a possibly blocked accessibility server.
            try:
                if host:
                    print('AX transport/preflight deadline exceeded',file=sys.stderr)
                    return 124
                state = subprocess.run(['ps', '-axo', 'pid,stat,comm'], capture_output=True,
                                       text=True, timeout=max(.01, deadline-time.monotonic()))
                for line in state.stdout.splitlines():
                    if any(x in line for x in ('SecurityAgent', 'richos-tauri', 'Safari')):
                        print(line, file=sys.stderr)
            except subprocess.TimeoutExpired:
                pass
            print('AX timeout: owned command group terminated; check modal/process state above', file=sys.stderr)
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
    raise SystemExit(run(command, sys.stdin.buffer.read(), seconds, host=host))
