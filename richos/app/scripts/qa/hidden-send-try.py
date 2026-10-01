#!/usr/bin/env python3
"""One try of "a send kept in flight across Home" on a PHYSICAL Android phone, optionally with a fault.

    hidden-send-try.py --serial S --log STEPS.log --n N --send X,Y [--fault wifi] [--fault-after S]
                       [--restore-after S] [--metrics-port P --metrics-file F [--observe S]]

The measurement behind the Android outbox's "a send that faults while hidden goes again inside the
bound". The walker has already typed the message and started `lab-pause.py --log STEPS.log
--stop-at 'PAUSE MAC {n}' --cont-at 'RELEASE MAC {n}'`. This does the part that must be quick, on
one clock, through `step-mark.py` lines:

    PAUSE MAC n   (lab-pause freezes the isolated lab)    -> tap Send at X,Y (the request is in flight)
    HOME n        (KEYCODE_HOME, never the power key)
    [--fault wifi] WIFI OFF n  S seconds after HOME       -> every connection the app has on Wi-Fi dies
    RELEASE MAC n (lab-pause continues the lab after its --cont-delay)
    [--fault wifi] WIFI ON n   --restore-after seconds later (default 0.3)

Why a fault has to be made: a frozen lab only makes the request hang, and it then succeeds late
without ever failing; the app's read timeout (30 s) is longer than the 5 s bound after Home, so
no freeze ends in a fault inside the bound. Dropping Wi-Fi under the request is a real transport
fault (the connection is aborted), and with no cellular internet on the phone the retry has to
wait for Wi-Fi to come back, which is the case the bound exists for. The Wi-Fi switch is put back
on however this ends (a finally), and `--fault` omitted changes no setting at all.

`--metrics-port` samples, every 0.25 s from just before the first mark, the request counters of the
lab's tunnel helper (its own `--metrics` port, read from its command line) into `--metrics-file`:
the number of requests that reached the lab and when, which is how a second request with the same
client id is told from a late answer to the first.

Exit 0 when every step ran; 2 with a sentence when it cannot (no serial, bad coordinates). It prints
the marks it wrote. The serial is an argument, never written anywhere.
"""
import argparse
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

MARK = str(Path(__file__).resolve().parent / "step-mark.py")
KEEP = ("cloudflared_tunnel_total_requests", "cloudflared_tunnel_request_errors", "cloudflared_tunnel_response_by_code")


def adb(serial, *args):
    done = subprocess.run(["adb", "-s", serial, "shell", *args], capture_output=True, text=True, timeout=30)
    if done.returncode != 0:
        raise SystemExit("adb %s failed: %s" % (" ".join(args), done.stderr.strip() or done.stdout.strip()))


def mark(log, *words):
    subprocess.run([sys.executable, MARK, log, *words], check=True)


def counter(line):
    name = line.split("{")[0].replace("cloudflared_tunnel_", "")
    if "{" in line:
        name += "[" + line.split('"')[1] + "]"
    return name + "=" + line.split()[-1]


def sample(port, path, seconds, stop):
    end = time.time() + seconds
    with open(path, "a", encoding="utf-8") as out:
        while time.time() < end and not stop.is_set():
            try:
                body = urllib.request.urlopen("http://127.0.0.1:%d/metrics" % port, timeout=2).read().decode()
                out.write("%.3f %s\n" % (time.time(), " ".join(counter(l) for l in body.splitlines() if l.startswith(KEEP))))
            except OSError as e:
                out.write("%.3f unreadable %s\n" % (time.time(), e))
            out.flush()
            time.sleep(0.25)


TCP_STATES = {"01": "ESTABLISHED", "02": "SYN_SENT", "04": "FIN_WAIT1", "05": "FIN_WAIT2", "06": "TIME_WAIT", "07": "CLOSE", "08": "CLOSE_WAIT", "09": "LAST_ACK", "0A": "LISTEN", "0B": "CLOSING"}


def sockets(serial, uid, path, seconds, stop):
    """The phone's own TCP sockets of one app uid, every 0.5 s: which are still ESTABLISHED after the fault."""
    end = time.time() + seconds
    with open(path, "a", encoding="utf-8") as out:
        while time.time() < end and not stop.is_set():
            done = subprocess.run(["adb", "-s", serial, "shell", "cat", "/proc/net/tcp6", "/proc/net/tcp"], capture_output=True, text=True, timeout=10)
            seen = []
            for line in done.stdout.splitlines():
                f = line.split()
                if len(f) > 8 and f[7] == str(uid) and f[0].endswith(":"):
                    seen.append("%s:%s" % (TCP_STATES.get(f[3], f[3]), f[2].split(":")[1]))
            out.write("%.3f %s\n" % (time.time(), " ".join(sorted(seen)) or "none"))
            out.flush()
            time.sleep(0.3)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--serial", required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--n", type=int, required=True)
    p.add_argument("--send", required=True, help="X,Y of the Send button in screen pixels")
    p.add_argument("--fault", choices=["wifi"], help="drop Wi-Fi under the in-flight request")
    p.add_argument("--fault-after", type=float, default=0.3, help="seconds after HOME before the fault")
    p.add_argument("--restore-after", type=float, default=0.3, help="seconds after RELEASE before Wi-Fi returns")
    p.add_argument("--metrics-port", type=int, help="the lab tunnel helper's --metrics port")
    p.add_argument("--metrics-file", help="where the samples go (with --metrics-port)")
    p.add_argument("--sockets-uid", type=int, help="sample this app uid's TCP sockets on the phone (state and remote port)")
    p.add_argument("--sockets-file", help="where those samples go (with --sockets-uid)")
    p.add_argument("--observe", type=float, default=12.0, help="seconds of samples, from the start")
    a = p.parse_args()
    try:
        x, y = (int(v) for v in a.send.split(","))
    except ValueError:
        print("--send wants X,Y integers", file=sys.stderr)
        return 2
    if a.metrics_port and not a.metrics_file:
        print("--metrics-port wants --metrics-file", file=sys.stderr)
        return 2
    stop = threading.Event()
    began = time.time()
    if a.metrics_port:
        threading.Thread(target=sample, args=(a.metrics_port, a.metrics_file, a.observe, stop), daemon=True).start()
        time.sleep(0.6)
    if a.sockets_uid and not a.sockets_file:
        print("--sockets-uid wants --sockets-file", file=sys.stderr)
        return 2
    if a.sockets_uid:
        threading.Thread(target=sockets, args=(a.serial, a.sockets_uid, a.sockets_file, a.observe, stop), daemon=True).start()
    n = str(a.n)
    off = False
    try:
        mark(a.log, "PAUSE", "MAC", n)
        adb(a.serial, "input", "tap", str(x), str(y))
        adb(a.serial, "input", "keyevent", "KEYCODE_HOME")
        mark(a.log, "HOME", n)
        if a.fault == "wifi":
            time.sleep(a.fault_after)
            off = True
            adb(a.serial, "svc", "wifi", "disable")
            mark(a.log, "WIFI", "OFF", n)
        mark(a.log, "RELEASE", "MAC", n)
        if a.fault == "wifi":
            time.sleep(a.restore_after)
            adb(a.serial, "svc", "wifi", "enable")
            off = False
            mark(a.log, "WIFI", "ON", n)
        if a.metrics_port or a.sockets_uid:
            time.sleep(max(0.0, a.observe - (time.time() - began)))
    finally:
        stop.set()
        if off:
            subprocess.run(["adb", "-s", a.serial, "shell", "svc", "wifi", "enable"], capture_output=True, timeout=30)
    return 0


if __name__ == "__main__":
    sys.exit(main())
