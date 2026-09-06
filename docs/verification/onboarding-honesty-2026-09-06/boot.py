#!/usr/bin/env python3
"""Boot the RichOS binary, capture its boot log, and end the process this run started.

Usage: boot.py --bin PATH --out LOG [--env KEY=VALUE ...] [--seconds N]

Why a runner rather than `binary & sleep; kill`: `gui-boot.test.sh`'s own header records
that this suite once left 157 orphaned `richos-tauri` processes on the CEO's Dock by killing
a subshell instead of the app. This kills the process it started, on every path including
the failing ones, and reports whether it actually died.

It reads to the `boot complete` terminator rather than sleeping for a fixed time, because a
check whose input depends on a duration goes red for no reason on a slow morning. `--seconds`
is only the ceiling.
"""
import argparse, os, signal, subprocess, sys, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--env", action="append", default=[], metavar="KEY=VALUE")
ap.add_argument("--seconds", type=float, default=25.0)
a = ap.parse_args()

env = dict(os.environ)
for kv in a.env:
    k, _, v = kv.partition("=")
    env[k] = v

p = subprocess.Popen([a.bin], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                     text=True, bufsize=1, start_new_session=True)

lines, done = [], threading.Event()

def reader():
    for line in p.stdout:
        lines.append(line.rstrip("\n"))
        if "boot complete" in line:
            done.set()
    done.set()

threading.Thread(target=reader, daemon=True).start()
reached = done.wait(a.seconds)

try:
    os.killpg(os.getpgid(p.pid), signal.SIGTERM)
except ProcessLookupError:
    pass
for _ in range(50):
    if p.poll() is not None:
        break
    time.sleep(0.1)
if p.poll() is None:
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    except ProcessLookupError:
        pass
    p.wait(timeout=5)

with open(a.out, "w") as f:
    f.write("\n".join(lines) + "\n")

print("[boot] terminator reached = %s" % reached, file=sys.stderr)
print("[boot] process exited = %s" % (p.poll() is not None), file=sys.stderr)
print("[boot] lines = %d -> %s" % (len(lines), a.out), file=sys.stderr)
sys.exit(0 if reached else 3)
