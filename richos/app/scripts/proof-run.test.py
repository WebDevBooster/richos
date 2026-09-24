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
        self.capacity, self.engine_shards, self.admission_wait = 4, 4, 1800
        self.max_cpu, self.budget, self.deadline, self.sample_every = 80, 600, 1800, 0.5
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
os.environ["RICHOS_MACHINE_WORKERS"] = os.path.join(tmp, "machine")
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
    wall = pr.run(its, Args(capacity=4), tmp, sampler=idle)
    check(all(i.state == "passed" for i in its) and wall < 5.5,
          "P2 four 2 s checks with a capacity of 4 take %.1f s of wall clock (one after another: 8 s)" % wall,
          [(i.label, i.state) for i in its])

    # P3 — a lane is one at a time.
    probe = os.path.join(tmp, "lane")
    os.makedirs(probe, exist_ok=True)
    script = ("d=%s; if ls $d/busy.* >/dev/null 2>&1; then touch $d/overlap; fi; "
              "touch $d/busy.$$; sleep 1; rm -f $d/busy.$$" % probe)
    its = [pr.Item("g%d" % n, os.path.join(pr.ROOT, "richos/app"), ["bash", "-c", script], "gradle", 1.0)
           for n in range(3)]
    wall = pr.run(its, Args(capacity=4), tmp, sampler=idle)
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
    r = subprocess.run([sys.executable, os.path.join(HERE, "proof-run.py"), "--low-priority", "--dry-run",
                        "--log-dir", os.path.join(tmp, "p5b"), "--paths", "richos/app/scripts/proof-run.py"],
                       capture_output=True, text=True)
    check(r.returncode != 0 and "--low-priority" in r.stderr,
          "P5b there is no switch that skips the CPU line: --low-priority is refused, not honored",
          (r.returncode, r.stderr[-200:]))

    # P11 — the deadline is enforced WHILE the run goes: named at the budget, stopped with its
    # whole tree at the deadline (a TERM-ignoring child and an own-session grandchild included),
    # and the run is red by name.
    d11 = os.path.join(tmp, "p11")
    os.makedirs(d11)
    script = ("python3 -c 'import subprocess, sys; p = subprocess.Popen([\"sleep\", \"60\"], start_new_session=True); "
              "open(sys.argv[1], \"w\").write(str(p.pid)); p.wait()' %s/own & "
              "bash -c 'trap \"\" TERM; echo $$ > %s/deaf; while :; do sleep 1; done' & "
              "sleep 60" % (d11, d11))
    it = pr.Item("runs-forever", os.path.join(pr.ROOT, "richos/app"), ["bash", "-c", script], None, 0.1)
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        wall = pr.run([it], Args(budget=1, deadline=3), os.path.join(tmp, "p11log"), sampler=idle)
    pids = [int(open(os.path.join(d11, f)).read()) for f in ("own", "deaf") if os.path.exists(os.path.join(d11, f))]
    alive = []
    for p in pids + [it.proc.pid]:
        try:
            os.kill(p, 0)
            alive.append(p)
            os.kill(p, signal.SIGKILL)
        except ProcessLookupError:
            pass
    check("OVER BUDGET" in buf.getvalue() and it.state == "timed-out" and wall < 20,
          "P11 a check past its budget is named while running, and at its deadline it is TIMED-OUT (%.0f s)" % wall,
          (it.state, buf.getvalue()[-300:]))
    check(len(pids) == 2 and not alive,
          "P11b nothing of the timed-out check survives: its shell, a TERM-ignoring child, an own-session grandchild",
          (pids, alive))

    # P12 — the worker budget counts NESTED workers. Three checks, each with three workers that
    # follow the mutation pool's contract: a worker runs on the check's own free slot when no
    # other worker of that check holds it, otherwise on a token of the run's budget. With a
    # capacity of three, no more than three workers ever work at once, and none is stuck: the
    # first version of this case had no free slot and deadlocked once the checks held every
    # token (found by the branch's own proof run, 2026-09-23).
    d12 = os.path.join(tmp, "p12")
    os.makedirs(d12)
    wt = os.path.join(pr.ROOT, "richos/engine/scripts/lib/worker_tokens.py")
    work = ("touch %s/w.$$; ls %s/w.* | wc -l >> %s/conc; sleep 0.6; rm -f %s/w.$$" % (d12, d12, d12, d12))
    nested = ("for i in 1 2 3; do python3 %s run \"$RICHOS_WORKER_TOKENS\" --free %s/free.$$ -- bash -c '%s' & done; wait"
              % (wt, d12, work.replace("'", "")))
    its = [pr.Item("nested-%d" % n, os.path.join(pr.ROOT, "richos/app"), ["bash", "-c", nested], None, 1.0)
           for n in range(3)]
    pr.run(its, Args(capacity=3), os.path.join(tmp, "p12log"), sampler=idle)
    conc = [int(x) for x in open(os.path.join(d12, "conc")).read().split()] if os.path.exists(os.path.join(d12, "conc")) else []
    check(all(i.state == "passed" for i in its) and len(conc) == 9 and 2 <= max(conc) <= 3,
          "P12 capacity 3, three checks with three workers each: all nine ran, at most %s at once" % (max(conc) if conc else "?"),
          (conc, [(i.label, i.state) for i in its]))

    # P13 — checks not yet started are never starved by nested workers. A runs twelve nested
    # workers, as many at a time as the budget lets it, for several seconds; four light checks
    # queued behind it must all run to the end while A's workers are still going, on the token
    # nested workers may never take (worker_tokens.py's reserve). In the third full run
    # native-ios-share waited 2519 s to start behind four mutation pools.
    d13 = os.path.join(tmp, "p13")
    os.makedirs(d13)
    nested13 = ("for i in $(seq 1 12); do python3 %s run \"$RICHOS_WORKER_TOKENS\" --free %s/free.$$ -- sleep 1 & done; wait"
                % (wt, d13))
    a = pr.Item("A", os.path.join(pr.ROOT, "richos/app"), ["bash", "-c", nested13], None, 30)
    light = [pr.Item("light-%d" % k, os.path.join(pr.ROOT, "richos/app"), ["bash", "-c", "sleep 0.3"], None, 1)
             for k in range(4)]
    pr.run([a] + light, Args(capacity=4), os.path.join(tmp, "p13log"), sampler=idle)
    check(all(i.state == "passed" for i in [a] + light) and max(i.ended for i in light) < a.ended,
          "P13 four light checks all ran while a nested pool kept the rest of the budget busy "
          "(last one ended %.1f s before the pool's check)" % (a.ended - max(i.ended for i in light)),
          [(i.label, i.state) for i in [a] + light])

    # P14 — a check whose command cannot even start fails by name, and the run goes on. The third
    # full run crashed on `cargo` not being found and left two other checks running under init.
    gone = pr.Item("no-such-tool", os.path.join(pr.ROOT, "richos/app"), ["no-such-tool-7c1f", "--x"], None, 5)
    fine = pr.Item("fine", os.path.join(pr.ROOT, "richos/app"), ["bash", "-c", "sleep 0.5"], None, 1)
    pr.run([gone, fine], Args(), os.path.join(tmp, "p14log"), sampler=idle)
    check(gone.state == "failed" and fine.state == "passed" and any("could not start" in n for n in gone.notes),
          "P14 a command that cannot start is a FAILED check, named, and the run carries on",
          (gone.state, gone.notes, fine.state))

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
    own = os.path.join(tmp, "p8.own")
    deaf = os.path.join(tmp, "p8.deaf")
    # Three ways a process escaped a group kill: a plain child, a grandchild in a session of its
    # own (reserve.py's shape), and a child that ignores SIGTERM.
    with open(cmds, "w") as fh:
        fh.write("cd richos/app && bash -c 'python3 -c \"import subprocess, sys; p = subprocess.Popen([\\\"sleep\\\", \\\"60\\\"], "
                 "start_new_session=True); open(sys.argv[1], \\\"w\\\").write(str(p.pid)); p.wait()\" %s & "
                 "bash -c \"trap \\\"\\\" TERM; echo \\$\\$ > %s; while :; do sleep 1; done\" & "
                 "sleep 60 & echo $! > %s; wait'\n" % (own, deaf, pidfile))
    # This case tests cancellation of started children. Use a deterministic
    # admission sample so a busy real Mac cannot turn it into a queueing test.
    bootstrap = ("import runpy,sys; sys.path.insert(0," + repr(os.path.join(HERE, 'testvm')) + "); "
                 "import reserve; reserve.host_sample=lambda: " + repr(idle()) + "; "
                 "sys.argv=[" + repr(os.path.join(HERE, 'proof-run.py')) + "]+sys.argv[1:]; "
                 "runpy.run_path(sys.argv[0],run_name='__main__')")
    runner = subprocess.Popen([sys.executable, '-c', bootstrap, "--commands", cmds,
                               "--log-dir", os.path.join(tmp, "p8")],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    deadline = time.time() + 20
    while not all(os.path.exists(f) and open(f).read().strip() for f in (pidfile, own, deaf)) and time.time() < deadline:
        time.sleep(0.1)
    pids = [int(open(f).read().strip()) for f in (pidfile, own, deaf) if os.path.exists(f) and open(f).read().strip()]
    runner.send_signal(signal.SIGTERM)
    out, _ = runner.communicate(timeout=60)
    alive = []
    for p in pids:
        try:
            os.kill(p, 0)
            alive.append(p)
            os.kill(p, signal.SIGKILL)
        except ProcessLookupError:
            pass
    check(len(pids) == 3 and not alive and runner.returncode == 130 and "interrupted" in out,
          "P8 SIGTERM to the runner stops the whole tree of the check it started (child, own-session "
          "grandchild, TERM-ignoring child: %s all gone) and exits 130" % pids, (alive, out[-300:]))

    # P10 — --as-printed: the selection unsplit, in printed order, one at a time (the baseline).
    order = os.path.join(tmp, "order")
    lines = ["cd richos/app && bash -c 'echo %d >> %s; sleep 0.3'" % (n, order) for n in range(1, 4)]
    its = pr.as_printed(lines)
    pr.run(its, Args(capacity=4), tmp, sampler=idle)
    check(len(its) == 3 and {i.lane for i in its} == {"as-printed"}
          and open(order).read().split() == ["1", "2", "3"],
          "P10 --as-printed runs each printed line unsplit, one after another, in printed order")

    # P9 — the log directory is bounded: the last three runs of a checkout, nothing more.
    parent = os.path.join(tmp, "rot")
    for n in range(5):
        d = os.path.join(parent, "20260923T00000%dZ" % n)
        os.makedirs(d)
        json.dump({"checks": [{"result": "passed"}]}, open(os.path.join(d, "summary.json"), "w"))
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
