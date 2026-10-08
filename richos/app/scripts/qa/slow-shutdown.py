#!/usr/bin/env python3
"""slow-shutdown.py -- run ONE program that takes a known extra time to shut down when asked.

    SLOW_SHUTDOWN_TARGET=/path/to/program SLOW_SHUTDOWN_MS=350 slow-shutdown.py [ARG ...]
    slow-shutdown.py --ms 350 -- /path/to/program [ARG ...]

WHY (2026-10-08). Nightly 44 failed extension-native-browser.test.sh after every check passed:
the harness sent Chrome SIGTERM, slept 400 ms and removed its scratch folder, and Chrome, still
shutting down on a busy Mac, wrote into the folder while it was being removed (ENOTEMPTY).
Measured: Chrome exits 181-198 ms after SIGTERM on a quiet Mac and 395-2164 ms under 60
one-core workers. under-load.py makes that slow shutdown likely; this makes it certain. Pass this
script where a harness takes the program's path (CHROME_PATH for the extension browser suites)
and the program's own shutdown starts SLOW_SHUTDOWN_MS later than the signal, which is what a
descheduled program looks like to whoever signaled it. Cleanup that waits for the program to
exit passes under any value; cleanup that sleeps a fixed time and hopes fails.

WHAT IT DOES. Starts the program as its only child with the arguments it was given and the same
stdio. On SIGTERM, SIGINT or SIGHUP it waits SLOW_SHUTDOWN_MS (or --ms) and then sends the
same signal to that child. It exits when the child exits, with the child's status (128 + N for
a child ended by signal N), so the caller sees one program that shut down slowly.

WHAT IT NEVER DOES. It signals only the child it started, by the pid it holds, and never after
that child has exited. It looks nothing up by name. A signal that lands before this script has
installed its handlers (its first few milliseconds) ends it at once, as for any process. It adds no load and takes no lock. A SIGKILL
to this script cannot be forwarded, so the child then runs on: the extension harnesses send
SIGKILL only after a 15 s grace, and only to the program they spawned, which is this script.
"""
import os
import signal
import subprocess
import sys
import threading


def parse(argv):
    if argv[:1] == ["--ms"]:
        if len(argv) < 4 or argv[2] != "--":
            return None, None
        return float(argv[1]), argv[3:]
    target = os.environ.get("SLOW_SHUTDOWN_TARGET")
    delay = os.environ.get("SLOW_SHUTDOWN_MS")
    if not target or delay is None:
        return None, None
    return float(delay), [target] + argv


def main(argv):
    try:
        delay_ms, cmd = parse(argv)
    except ValueError:
        delay_ms, cmd = None, None
    if cmd is None or delay_ms < 0:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        print("usage: SLOW_SHUTDOWN_TARGET=PROGRAM SLOW_SHUTDOWN_MS=N slow-shutdown.py [ARG ...]"
              " | slow-shutdown.py --ms N -- PROGRAM [ARG ...]", file=sys.stderr)
        return 2

    lock = threading.Lock()
    state = {"child": None, "pending": []}

    def forward(signum):
        with lock:
            child = state["child"]
            if child is None:
                state["pending"].append(signum)
            elif child.poll() is None:
                child.send_signal(signum)

    def on_signal(signum, frame):
        timer = threading.Timer(delay_ms / 1000.0, forward, args=(signum,))
        timer.daemon = True
        timer.start()

    # Handlers first: a signal that arrives while the child is starting is delayed, not fatal.
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, on_signal)
    child = subprocess.Popen(cmd)
    with lock:
        state["child"] = child
        for signum in state["pending"]:
            child.send_signal(signum)
    while True:
        try:
            code = child.wait()
            break
        except InterruptedError:
            continue
    return 128 - code if code < 0 else code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
