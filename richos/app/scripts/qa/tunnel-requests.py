#!/usr/bin/env python3
"""How many requests reached the isolated lab through its tunnel, and when.

    tunnel-requests.py sample --port P --out FILE --seconds S [--interval I]
    tunnel-requests.py between FILE --from T1 --to T2

The lab Mac's RichOS Connect helper (cloudflared, started by the lab with `--metrics
127.0.0.1:PORT`) counts every request that crosses the tunnel. That count is how a phone
check tells a SECOND request with the same client id (a send cut and sent again) from a late
answer to the first: the lab's own intake records the message once either way, by design.

`sample` reads http://127.0.0.1:PORT/metrics every I seconds (default 0.25) for S seconds and
appends one line per reading to FILE, this Mac's epoch seconds first:

    1790867244.232 request_errors=0 response_by_code[200]=7 total_requests=7

A reading that fails, or that answers without the request counter, is written as `<epoch>
unreadable <why>`, never as a number (hunt part 2 v3, R39: a missing counter is not zero). (Not the
file `hidden-send-try.py --metrics-file` writes: the same name=value shape since the fix of its
unlabeled counters, which used to read `total_requests 7=7`; `between` refuses such an old file.)
It refuses (exit 2) before writing anything when the port does not answer with the helper's
request counter: a wrong port must not look like a quiet tunnel. SIGTERM or SIGINT ends it
cleanly (exit 0); stop it by the PID you captured when you started it.

`between` prints one JSON document: how far the request counter rose between the last
reading at or before T1 and the last reading at or before T2, each rise with the readings
that bracket it (the request arrived inside that interval), and the rise in errors and in
each response code. It exits 2 when the readings do not cover the window (none at or before
T1, none at or after T2) or when an unreadable reading falls inside it: a gap is not a zero.
A reading without total_requests is unreadable, whoever wrote the file.
T1 and T2 are epoch seconds on this Mac's clock (a phone step's time is the phone's clock;
say so when you compare them).
"""
import argparse
import json
import signal
import sys
import time
import urllib.request

PREFIX = "cloudflared_tunnel_"
KEEP = ("cloudflared_tunnel_total_requests", "cloudflared_tunnel_request_errors", "cloudflared_tunnel_response_by_code")


def counters(body):
    """The kept counters of one /metrics body as {name: value}, names as the line writes them."""
    found = {}
    for line in body.splitlines():
        if not line.startswith(KEEP):
            continue
        # The name ends at its labels or, for an unlabeled counter, at the space before the value.
        name = line.split()[0].split("{")[0][len(PREFIX):]
        if "{" in line:
            name += "[" + line.split('"')[1] + "]"
        found[name] = float(line.split()[-1])
    return found


def line_of(found):
    return " ".join("%s=%s" % (k, int(v) if v == int(v) else v) for k, v in sorted(found.items()))


def read(port):
    return urllib.request.urlopen("http://127.0.0.1:%d/metrics" % port, timeout=2).read().decode()


def sample(a):
    try:
        first = counters(read(a.port))
    except OSError as e:
        print("port %d did not answer /metrics (%s): is this the lab's tunnel helper?" % (a.port, e), file=sys.stderr)
        return 2
    if "total_requests" not in first:
        print("port %d answers /metrics without cloudflared_tunnel_total_requests: not a tunnel helper" % a.port, file=sys.stderr)
        return 2
    stop = []
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.append(True))
    end = time.time() + a.seconds
    with open(a.out, "a", encoding="utf-8") as out:
        out.write("%.3f %s\n" % (time.time(), line_of(first)))
        out.flush()
        while time.time() < end and not stop:
            time.sleep(a.interval)
            try:
                found = counters(read(a.port))
                if "total_requests" not in found:
                    raise ValueError("no cloudflared_tunnel_total_requests in the reading")
                out.write("%.3f %s\n" % (time.time(), line_of(found)))
            except (OSError, ValueError) as e:
                out.write("%.3f unreadable %s\n" % (time.time(), str(e).replace("\n", " ")))
            out.flush()
    return 0


def parse(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for raw in f:
            parts = raw.split()
            if not parts:
                continue
            at = float(parts[0])
            if len(parts) > 1 and parts[1] == "unreadable":
                rows.append((at, None))
                continue
            found = {k: float(v) for k, v in (p.split("=", 1) for p in parts[1:])}
            # A reading without the request counter cannot say how many requests there were:
            # it is a gap, never a zero (hunt part 2 v3, R39).
            rows.append((at, found if "total_requests" in found else None))
    return rows


def between(a):
    try:
        rows = parse(a.file)
    except (OSError, ValueError) as e:
        print("cannot read %s as tunnel counter readings: %s" % (a.file, e), file=sys.stderr)
        return 2
    if a.to <= a.frm:
        print("--to must be after --from", file=sys.stderr)
        return 2
    before = [r for r in rows if r[0] <= a.frm and r[1] is not None]
    after = [r for r in rows if r[0] >= a.to]
    if not before or not after:
        print("the readings do not cover %.3f-%.3f (first %.3f, last %.3f): no count" % (
            a.frm, a.to, rows[0][0] if rows else 0, rows[-1][0] if rows else 0), file=sys.stderr)
        return 2
    window = [r for r in rows if before[-1][0] <= r[0] <= a.to]
    gaps = [r[0] for r in window if r[1] is None]
    if gaps:
        print("%d unreadable reading(s) inside the window (first at %.3f): a gap is not a zero" % (len(gaps), gaps[0]), file=sys.stderr)
        return 2
    end = window[-1][1]
    start = before[-1][1]
    rises, prev = [], window[0]
    for row in window[1:]:
        d = row[1].get("total_requests", 0) - prev[1].get("total_requests", 0)
        if d:
            rises.append({"requests": int(d), "after": round(prev[0], 3), "by": round(row[0], 3)})
        prev = row
    delta = {k: int(end.get(k, 0) - start.get(k, 0)) for k in sorted(set(end) | set(start)) if end.get(k, 0) != start.get(k, 0)}
    print(json.dumps({"from": a.frm, "to": a.to, "requests": int(end.get("total_requests", 0) - start.get("total_requests", 0)),
                      "rises": rises, "counters": delta, "readings": len(window),
                      "lastReadingAtOrBeforeTo": round(window[-1][0], 3)}, indent=1))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sample")
    s.add_argument("--port", type=int, required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--seconds", type=float, required=True)
    s.add_argument("--interval", type=float, default=0.25)
    b = sub.add_parser("between")
    b.add_argument("file")
    b.add_argument("--from", dest="frm", type=float, required=True)
    b.add_argument("--to", type=float, required=True)
    a = p.parse_args()
    return sample(a) if a.cmd == "sample" else between(a)


if __name__ == "__main__":
    sys.exit(main())
