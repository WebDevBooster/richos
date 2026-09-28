#!/usr/bin/env python3
"""engine_pass.test.py — one full engine pass on this Mac at a time, proven by running two.

Every case uses a slot directory of its own (RICHOS_ENGINE_PASS_DIR) and a throwaway git
repository with a linked worktree, so nothing here touches the machine's real slot, and "the
land run" and "a teammate" are the two real kinds of checkout. The mutation harness
(engine_pass.mutation.sh) removes one property at a time and requires the named case to fail.

    python3 engine_pass.test.py [CASE-ID]      e.g. EP05 — run one case only
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "engine_pass.py")
sys.path.insert(0, HERE)
import engine_pass as EP  # noqa: E402

ONLY = sys.argv[1] if len(sys.argv) > 1 else None
PASSED = FAILED = 0
OWNED = []          # every process this suite starts, stopped by PID at the end


def check(case, ok, what, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print("  PASS  %s %s" % (case, what), flush=True)
    else:
        FAILED += 1
        print("  FAIL  %s %s" % (case, what), flush=True)
        if detail:
            print("        " + str(detail)[:1500].replace("\n", "\n        "), flush=True)


def wanted(case):
    return ONLY is None or ONLY == case


def git(*args, cwd):
    # No hooks: the operator's global hooks guard real repositories, not this throwaway one.
    empty = os.path.join(os.path.dirname(cwd), "no-hooks")
    os.makedirs(empty, exist_ok=True)
    r = subprocess.run(["git", "-c", "core.hooksPath=" + empty, "-c", "user.email=t@t", "-c", "user.name=t",
                        *args], cwd=cwd, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit("fixture git %s failed: %s" % (" ".join(args), r.stderr))


RECORD = ("import sys,time\n"
          "open(sys.argv[1],'a').write('start %.3f\\n' % time.time())\n"
          "time.sleep(float(sys.argv[2]))\n"
          "open(sys.argv[1],'a').write('end %.3f\\n' % time.time())\n")


def hold(checkout, log, seconds, count=25, wait=30, label="fixture", units="a,b"):
    """Start `engine_pass.py hold` around a command that records when it ran."""
    p = subprocess.Popen([sys.executable, TOOL, "hold", "--count", str(count), "--units", units,
                          "--label", label, "--checkout", checkout, "--wait", str(wait), "--",
                          sys.executable, "-c", RECORD, log, str(seconds)],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    OWNED.append(p)
    return p


def interval(log):
    try:
        rows = open(log).read().split()
    except OSError:
        return None
    vals = dict(zip(rows[0::2], map(float, rows[1::2])))
    return (vals.get("start"), vals.get("end"))


def wait_until(pred, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.1)
    return pred()


def main():
    tmp = tempfile.mkdtemp(prefix="engine-pass-test-")
    os.environ["RICHOS_ENGINE_PASS_DIR"] = os.path.join(tmp, "slot")
    land = os.path.join(tmp, "land")
    os.makedirs(land)
    git("init", "-q", "-b", "main", cwd=land)
    git("commit", "-q", "--allow-empty", "-m", "seed", cwd=land)
    mate = os.path.join(tmp, "mate")
    git("worktree", "add", "-q", "-b", "cc/mate", mate, cwd=land)
    mate2 = os.path.join(tmp, "mate2")
    git("worktree", "add", "-q", "-b", "cc/mate2", mate2, cwd=land)
    try:
        run_cases(tmp, land, mate, mate2)
    finally:
        for p in OWNED:
            if p.poll() is None:
                p.kill()
                p.wait()
        subprocess.run(["rm", "-rf", tmp])
    print("=== engine_pass: %d passed, %d FAILED ===" % (PASSED, FAILED), flush=True)
    return 0 if FAILED == 0 else 1


def run_cases(tmp, land, mate, mate2):
    print("=== engine_pass: one full engine pass at a time ===", flush=True)

    if wanted("EP01"):
        check("EP01", not EP.needs_slot(EP.FULL_PASS_UNITS - 1) and EP.needs_slot(EP.FULL_PASS_UNITS)
              and EP.FULL_PASS_UNITS == 20,
              "a full pass is 20 units or more; 19 runs free (the measured gap between 12 and 29)")

    if wanted("EP02"):
        check("EP02", EP.is_main_checkout(land) and not EP.is_main_checkout(mate),
              "the main checkout is the land run; a linked worktree is a teammate")

    if wanted("EP03") or wanted("EP04"):
        log1, log2 = os.path.join(tmp, "ep03-1"), os.path.join(tmp, "ep03-2")
        first = hold(mate, log1, 4)
        wait_until(lambda: interval(log1) and interval(log1)[0], 10)
        rec = EP.holder()
        if wanted("EP03"):
            check("EP03", bool(rec) and rec.get("count") == 25 and rec.get("branch") == "cc/mate"
                  and rec.get("main") is False and rec.get("pid") == first.pid,
                  "the holder is recorded: its pid, branch, unit count and that it is not the land run", rec)
        second = hold(mate2, log2, 0.1, wait=1, units="scripts/x.test.sh,scripts/y.test.sh")
        try:
            out, _ = second.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            second.kill()
            out, _ = second.communicate()
            out = "(still waiting after 20 s: the bound was not enforced)\n" + out
        if wanted("EP04"):
            check("EP04", second.returncode == EP.REFUSED and "NOTHING WAS RUN" in out
                  and "scripts/y.test.sh" in out and not os.path.exists(log2)
                  and "--only-units" in out,
                  "a teammate still waiting at its bound is REFUSED (75), never runs, and names its units "
                  "and the --only-units way to verify", out)
        first.wait(timeout=20)

    if wanted("EP05"):
        # THE DEMONSTRATION: two full passes started together; the second never overlaps the first.
        a, b = os.path.join(tmp, "ep05-a"), os.path.join(tmp, "ep05-b")
        pa = hold(mate, a, 2, label="pass A")
        pb = hold(mate2, b, 2, label="pass B")
        oa, _ = pa.communicate(timeout=60)
        ob, _ = pb.communicate(timeout=60)
        ia, ib = interval(a), interval(b)
        ok = (pa.returncode == 0 and pb.returncode == 0 and ia and ib and None not in ia + ib
              and (ia[1] <= ib[0] or ib[1] <= ia[0]))
        check("EP05", ok, "two full passes started together both run, one after the other: never overlapping",
              "A=%s B=%s\nA says: %s\nB says: %s" % (ia, ib, oa, ob))
        waited = ob if (ia and ib and ia[0] < ib[0]) else oa
        check("EP05b", "waiting" in waited and "held by" in waited,
              "the second one says it is waiting and who holds the slot", waited)

    if wanted("EP06"):
        # A crashed holder cannot keep the slot: SIGKILL a process that holds it, then take it at once.
        holder_script = ("import sys,time; sys.path.insert(0,%r); import engine_pass as E\n"
                         "s=E.acquire(30,'crasher',%r,wait=5)\nprint('held',flush=True)\ntime.sleep(60)\n"
                         % (HERE, mate))
        p = subprocess.Popen([sys.executable, "-c", holder_script], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True)
        OWNED.append(p)
        line = p.stdout.readline().strip()
        locked_before = EP.holder() is not None
        p.send_signal(signal.SIGKILL)       # our own child, by the PID we captured at spawn
        p.wait(timeout=10)
        t0 = time.monotonic()
        try:
            s = EP.acquire(30, "after-crash", mate2, wait=5, out=open(os.devnull, "w"))
            got = time.monotonic() - t0
            s.release()
        except EP.Refused:
            got = None
        check("EP06", line == "held" and locked_before and got is not None and got < 1.0,
              "a SIGKILLed holder releases the slot: the next run takes it at once", (line, locked_before, got))

    if wanted("EP07"):
        # The land run goes first: a teammate waiting behind it does not jump the queue.
        h, m, t = (os.path.join(tmp, "ep07-" + n) for n in ("h", "m", "t"))
        ph = hold(mate, h, 3, label="teammate holder")
        wait_until(lambda: interval(h) and interval(h)[0], 10)
        pm = hold(land, m, 1, label="land run")
        time.sleep(0.5)
        pt = hold(mate2, t, 1, label="teammate waiter")
        for p in (ph, pm, pt):
            p.communicate(timeout=60)
        ih, im, it = interval(h), interval(m), interval(t)
        ok = (all(x and None not in x for x in (ih, im, it)) and ih[1] <= im[0] and im[1] <= it[0])
        check("EP07", ok, "the land run takes the slot before a teammate that was also waiting, and nothing overlaps",
              "holder=%s land=%s teammate=%s" % (ih, im, it))

    if wanted("EP07b"):
        # Deterministic form of the same property: the slot is FREE, a land run is waiting for it
        # (it polls slowly on purpose), and a teammate arriving now still does not take it.
        m, t = (os.path.join(tmp, "ep07b-" + n) for n in ("m", "t"))
        ph = subprocess.Popen([sys.executable, "-c",
                               "import sys,time; sys.path.insert(0,%r); import engine_pass as E\n"
                               "s=E.acquire(30,'teammate holder',%r,wait=5)\nprint('held',flush=True)\n"
                               "time.sleep(60)\n" % (HERE, mate)],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        OWNED.append(ph)
        ph.stdout.readline()
        slow = dict(os.environ, RICHOS_ENGINE_PASS_POLL="30")
        pm = subprocess.Popen([sys.executable, TOOL, "hold", "--count", "25", "--label", "land run", "--checkout",
                               land, "--wait", "60", "--", sys.executable, "-c", RECORD, m, "0.1"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=slow)
        OWNED.append(pm)
        waiting = wait_until(lambda: EP.status()["land_run_waiting"], 10)
        ph.kill()                            # our own child, by the PID we captured at spawn
        ph.wait(timeout=10)
        wait_until(lambda: EP.holder() is None, 10)
        pt = hold(mate2, t, 0.1, wait=1, label="teammate arriving")
        try:
            out, _ = pt.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            pt.kill()
            out, _ = pt.communicate()
        pm.kill()
        pm.wait(timeout=10)
        check("EP07b", waiting and pt.returncode == EP.REFUSED and not os.path.exists(t)
              and "land run is waiting" in out,
              "with the slot free but a land run waiting, an arriving teammate does not take it", (waiting, pt.returncode, out))

    if wanted("EP08") or wanted("EP09"):
        # Descendants of the holder run under it; a process outside it needs the slot.
        log = os.path.join(tmp, "ep08")
        inner = ("import subprocess,sys; r=subprocess.run([sys.executable,%r,'needed','25']).returncode; "
                 "open(%r,'w').write(str(r))" % (TOOL, log))
        p = subprocess.Popen([sys.executable, TOOL, "hold", "--count", "25", "--label", "outer", "--checkout",
                              mate, "--wait", "10", "--", sys.executable, "-c", inner + "; import time; time.sleep(2)"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        OWNED.append(p)
        wait_until(lambda: os.path.exists(log) and open(log).read(), 15)
        inside = open(log).read() if os.path.exists(log) else "missing"
        outside = subprocess.run([sys.executable, TOOL, "needed", "25"]).returncode
        small = subprocess.run([sys.executable, TOOL, "needed", "3"]).returncode
        p.wait(timeout=20)
        if wanted("EP08"):
            check("EP08", inside == "0" and outside == EP.NEEDED and small == 0,
                  "a child of the holder runs under the slot (0); an unrelated run of 25 units needs it (10); "
                  "3 units never do (0)", (inside, outside, small))
        if wanted("EP09"):
            # A reused PID is not an ancestor: the record names OUR pid but with a different start time.
            keep = subprocess.Popen([sys.executable, "-c",
                                     "import sys,time; sys.path.insert(0,%r); import engine_pass as E\n"
                                     "s=E.acquire(30,'x',%r,wait=5)\nprint('held',flush=True)\ntime.sleep(30)\n"
                                     % (HERE, mate)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            OWNED.append(keep)
            keep.stdout.readline()
            path = os.path.join(os.environ["RICHOS_ENGINE_PASS_DIR"], "holder.json")
            rec = json.load(open(path))
            rec.update(pid=os.getpid(), birth="Thu Jan  1 00:00:00 1970")
            json.dump(rec, open(path, "w"))
            forged = EP.held_by_ancestor()
            rec["birth"] = EP.birth(os.getpid())
            json.dump(rec, open(path, "w"))
            genuine = EP.held_by_ancestor()
            keep.kill()
            keep.wait()
            check("EP09", forged is False and genuine is True,
                  "an ancestor is matched by PID AND start time, so a reused PID never inherits the slot",
                  (forged, genuine))

    if wanted("EP10"):
        # The slot stays held while the pass runs, even when the wrapper that took it is killed.
        log = os.path.join(tmp, "ep10")
        p = hold(mate, log, 3, label="orphaned pass")
        wait_until(lambda: interval(log) and interval(log)[0], 10)
        p.send_signal(signal.SIGKILL)       # our own child, by the PID we captured at spawn
        p.wait(timeout=10)
        still = EP.holder() is not None
        freed = wait_until(lambda: EP.holder() is None, 15)
        check("EP10", still and freed and interval(log)[1] is not None,
              "killing the wrapper does not free the slot while its pass still runs; the pass's end does",
              (still, freed, interval(log)))


if __name__ == "__main__":
    sys.exit(main())
