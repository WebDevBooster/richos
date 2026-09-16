#!/usr/bin/env python3
"""Own a native provider group even if the desktop disappears without running Drop.

The desktop creates this process as its group leader. The provider inherits its
stdio unchanged. Parent death is observed from the OS, never from a timeout on
model activity. No persistent job or automatic restart is created.
"""
import os
import signal
import sys
import time


def main():
    if len(sys.argv) < 2 or os.getpgrp() != os.getpid():
        raise SystemExit("provider supervisor requires an executable and its own process group")
    parent = os.getppid()
    if parent <= 1:
        raise SystemExit("provider supervisor has no desktop owner")
    provider = os.fork()
    if provider == 0:
        os.environ["RICHOS_SESSION_PID"] = str(os.getpid())
        try:
            os.execvp(sys.argv[1], sys.argv[1:])
        except OSError as error:
            print(f"Provider could not start: {error}", file=sys.stderr, flush=True)
            os._exit(127)
    try:
        while os.getppid() == parent:
            ended, _ = os.waitpid(provider, os.WNOHANG)
            if ended:
                break
            time.sleep(0.1)
    finally:
        # This live group leader reserves the group identity. Include ourselves:
        # no detached watcher can later target a recycled PID or process group.
        os.killpg(os.getpid(), signal.SIGKILL)


if __name__ == "__main__":
    main()
