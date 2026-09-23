#!/usr/bin/env python3
"""proof-run.test.py — the land runner runs everything it was given, at the same time where
that is safe, one at a time where it is not, and never reports green over a check that did
not pass. Fixture commands only (sleep, exit codes, files); nothing here builds or boots.
"""
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("proof_run", os.path.join(HERE, "proof-run.py"))
pr = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pr)
pr.SETTLE_SECONDS = 0

PASSED = FAILED = 0


def check(ok, what, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print("  ok    %s" % what)
    else:
        FAILED += 1
        print("  FAIL  %s" % what)
        if detail:
            print("        %s" % str(detail)[:600])


class Args:
    def __init__(self, **kw):
        self.jobs, self.engine_shards, self.admission_wait = 4, 4, 1800
        self.max_cpu, self.low_priority = 80, False
        self.__dict__.update(kw)


def idle():
    return {"cpu_user_percent": 5.0, "cpu_system_percent": 2.0, "cpu_idle_percent": 93.0, "swapout_mb_per_s": 0.0,
            "memory_pressure": "normal", "memory_free_percent": 80, "swap_used_mb": 0.0}


def busy():
    s = idle()
    s["cpu_user_percent"] = 95.0
    return s


def items_from(lines, tmp, **kw):
    return pr.plan(lines, Args(**kw), tmp, {})


tmp = tempfile.mkdtemp(prefix="proof-run-test.")
try:
    print("=== proof-run ===")

    # P1 — the plan: every family becomes checks, nothing is dropped except a cargo filter a
    # shorter filter on the same target already runs.
    lines = [
        "  cd richos/app/src-tauri && cargo test --bin richos-tauri phone::",
        "  cd richos/app/src-tauri && cargo test --bin richos-tauri phone::rows::",
        "  cd richos/app && cargo test -p richos-core --lib sessions::",
        "  cd richos/web/web-app && node --test test/api.test.js test/scroll.test.js",
        "  cd richos/app && scripts/run-tests.sh --no-host-screen --only lint.test.sh --only native-android-app.test.sh --only native-android-core.test.sh",
        "  cd richos/engine && bash scripts/ci-shard.sh --only-units scripts/stop.test.sh",
        "  cd richos/engine && bash scripts/ci-shard.sh --only-units scripts/spawn.test.sh",
    ]
    its = items_from(lines, tmp)
    labels = sorted(i.label for i in its)
    cargo = [i for i in its if i.lane == "cargo"]
    check(sorted(i.label for i in cargo) == ["cargo phone::", "cargo sessions::"],
          "P1a cargo: phone::rows:: is dropped only because phone:: on the same target runs it; sessions:: stays",
          [i.label for i in cargo])
    suites = [i for i in its if i.argv[:1] == ["scripts/run-tests.sh"]]
    check(sorted(i.label for i in suites) == ["lint", "native-android-app", "native-android-core"]
          and all(i.argv[1] == "--no-host-screen" and i.argv[-2] == "--only" for i in suites),
          "P1b run-tests.sh --only a --only b becomes one check per suite, flags kept", [i.argv for i in suites])
    gradle = sorted(i.label for i in its if i.lane == "gradle")
    check(gradle == ["native-android-app", "native-android-core"],
          "P1c the suites that drive bin/randroid share the gradle lane (derived from the suite, not a list)", gradle)
    eng = [i for i in its if i.label.startswith("engine ")]
    shards = [i for i in eng if i.label != "engine receipts"]
    recv = [i for i in eng if i.label == "engine receipts"]
    with open(os.path.join(tmp, "engine-units.txt")) as fh:
        units = fh.read().split()
    check(units == ["scripts/spawn.test.sh", "scripts/stop.test.sh"] and shards
          and all("--units-file" in i.argv and "--shard" in i.argv and "--receipt" in i.argv for i in shards),
          "P1d engine units become one units file, packed into receipted shards by the engine's planner",
          [i.argv for i in shards])
    check(len(recv) == 1 and recv[0].after == {i.label for i in shards} and "--verify-receipts" in recv[0].argv,
          "P1e and a receipts check runs after every shard, proving the union of units run is the set selected")
    check("web-app" in labels, "P1f every other command runs as printed", labels)

    # P2 — concurrency: four 2-second checks finish together, not one after another.
    lines = ["cd richos/app && bash -c 'sleep 2'"] * 4
    its = items_from(lines, tmp)
    t0 = time.time()
    wall = pr.run(its, Args(jobs=4), tmp, sampler=idle)
    check(all(i.state == "passed" for i in its) and wall < 5.5,
          "P2 four 2 s checks with --jobs 4 take %.1f s of wall clock (one after another: 8 s)" % wall,
          [(i.label, i.state) for i in its])

    # P3 — a lane is one at a time.
    probe = os.path.join(tmp, "lane")
    os.makedirs(probe, exist_ok=True)
    script = ("d=%s; if ls $d/busy.* >/dev/null 2>&1; then touch $d/overlap; fi; "
              "touch $d/busy.$$; sleep 1; rm -f $d/busy.$$" % probe)
    its = [pr.Item("g%d" % n, os.path.join(pr.ROOT, "richos/app"), ["bash", "-c", script], "gradle", 1.0)
           for n in range(3)]
    wall = pr.run(its, Args(jobs=4), tmp, sampler=idle)
    check(not os.path.exists(os.path.join(probe, "overlap")) and wall >= 2.8,
          "P3 three checks in one lane never overlap (%.1f s for three 1 s checks)" % wall)

    # P4 — a failure is named and the exit is non-zero.
    its = items_from(["cd richos/app && bash -c 'exit 0'", "cd richos/app && bash -c 'echo broken; exit 3'"], tmp)
    its[1].label = "the-broken-one"
    pr.run(its, Args(), tmp, sampler=idle)
    rc = pr.summarize(its, 1.0, tmp)
    with open(os.path.join(tmp, "summary.json")) as fh:
        summary = json.load(fh)
    check(rc == 1 and its[1].state == "failed" and its[1].rc == 3
          and any(c["check"] == "the-broken-one" and c["result"] == "failed" for c in summary["checks"]),
          "P4 a check that exits 3 fails the run by name, in the summary and its JSON")
    check(open(its[1].log).read().splitlines()[-1] == "broken",
          "P4b and its output is in its own log", its[1].log)

    # P5 — admission: a busy machine is waited out, never ignored, and the wait has an end.
    its = items_from(["cd richos/app && bash -c 'exit 0'"], tmp)
    pr.run(its, Args(admission_wait=0), tmp, sampler=busy)
    check(its[0].state == "not-admitted" and its[0].started is None,
          "P5a at 95% user CPU a check is not started, and after its wait it is NOT-ADMITTED (a failure)",
          (its[0].state, its[0].notes))
    its = items_from(["cd richos/app && bash -c 'exit 0'"], tmp)
    pr.run(its, Args(admission_wait=0, low_priority=True), tmp, sampler=busy)
    check(its[0].state == "passed" and open(its[0].log).read().startswith("$ cd richos/app"),
          "P5b --low-priority (CEO ruling §78) does not apply the CPU line, and the check runs")

    # P6 — the receipts check runs even when a shard failed: it is what names the missing units.
    a = pr.Item("engine 1/2", os.path.join(pr.ROOT, "richos/app"), ["bash", "-c", "exit 1"], None, 5)
    b = pr.Item("engine receipts", os.path.join(pr.ROOT, "richos/app"), ["bash", "-c", "exit 0"], None, 1,
                after=["engine 1/2"])
    pr.run([a, b], Args(), tmp, sampler=idle)
    check(a.state == "failed" and b.state == "passed" and b.started >= a.ended,
          "P6 the receipts check waits for the shards and runs even after one failed")

    # P7 — an UNCOVERED selection runs nothing and exits 1.
    r = subprocess.run([sys.executable, os.path.join(HERE, "proof-run.py"), "--log-dir", os.path.join(tmp, "p7"),
                        "--paths", "richos/mobile/zz-uncovered.sh"], capture_output=True, text=True)
    check(r.returncode == 1 and "Nothing was run" in r.stderr and not os.path.exists(os.path.join(tmp, "p7", "summary.json")),
          "P7 proof-for.sh's UNCOVERED stops the run before anything starts (exit 1)", (r.returncode, r.stderr[-300:]))

    # P8 — an interrupt stops what the runner started, by its process group, and nothing else.
    cmds = os.path.join(tmp, "p8.txt")
    pidfile = os.path.join(tmp, "p8.pid")
    with open(cmds, "w") as fh:
        fh.write("cd richos/app && bash -c 'sleep 60 & echo $! > %s; wait'\n" % pidfile)
    runner = subprocess.Popen([sys.executable, os.path.join(HERE, "proof-run.py"), "--commands", cmds,
                               "--log-dir", os.path.join(tmp, "p8"), "--low-priority"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    deadline = time.time() + 20
    while not os.path.exists(pidfile) and time.time() < deadline:
        time.sleep(0.1)
    sleeper = int(open(pidfile).read().strip()) if os.path.exists(pidfile) else None
    runner.send_signal(signal.SIGTERM)
    out, _ = runner.communicate(timeout=30)
    alive = False
    if sleeper:
        try:
            os.kill(sleeper, 0)
            alive = True
            os.kill(sleeper, signal.SIGKILL)
        except ProcessLookupError:
            pass
    check(sleeper is not None and not alive and runner.returncode == 130 and "interrupted" in out,
          "P8 SIGTERM to the runner stops the check it started (pid %s gone) and exits 130" % sleeper, out[-300:])

    # P10 — --as-printed: the selection unsplit, in printed order, one at a time (the baseline).
    order = os.path.join(tmp, "order")
    lines = ["cd richos/app && bash -c 'echo %d >> %s; sleep 0.3'" % (n, order) for n in range(1, 4)]
    its = pr.as_printed(lines)
    pr.run(its, Args(jobs=4), tmp, sampler=idle)
    check(len(its) == 3 and {i.lane for i in its} == {"as-printed"}
          and open(order).read().split() == ["1", "2", "3"],
          "P10 --as-printed runs each printed line unsplit, one after another, in printed order")

    # P9 — the log directory is bounded: the last three runs of a checkout, nothing more.
    parent = os.path.join(tmp, "rot")
    for n in range(5):
        os.makedirs(os.path.join(parent, "20260923T00000%dZ" % n))
    os.makedirs(os.path.join(parent, "not-a-run"))
    pr.rotate(parent)
    left = sorted(os.listdir(parent))
    check(left == ["20260923T000002Z", "20260923T000003Z", "20260923T000004Z", "not-a-run"],
          "P9 rotation keeps the last 3 runs and touches nothing it did not name", left)
finally:
    subprocess.run(["rm", "-rf", tmp])

if FAILED:
    print("=== proof-run tests: %d FAILED, %d passed ===" % (FAILED, PASSED))
    sys.exit(1)
print("=== proof-run tests: all %d passed ===" % PASSED)
