#!/usr/bin/env python3
"""proof-run.py — RUN a proof-for.sh selection: concurrently, admitted by CPU, one summary.

    proof-run.py [proof-for arguments]          e.g.  origin/main..main   |  --working  |  <sha>
    proof-run.py --commands <file>              a saved `proof-for.sh --quiet` output
    options:
      --dry-run            print the plan (items, lanes, expected seconds) and run nothing
      --as-printed         run the printed commands exactly as printed, one after another (the
                           hand-written loop's shape, to measure what the runner saves)
      --capacity N         the run's budget of concurrent WORKERS, nested ones included
                           (default: 80% of logical cores — the admission line, in cores)
      --engine-shards N    at most N engine shards (default: logical cores / 2)
      --admission-wait S   how long one check may wait for admission (default 1800 s)
      --budget S           a check running past S seconds is named while the run goes (600)
      --deadline S         a check still running at max(S, 3 x its expected seconds), capped
                           at an hour, is stopped with its whole tree and fails (1800)
      --sample-every S     how often the host is sampled for the run's summary (10)
      --log-dir DIR        where the per-check logs go (default: one directory per checkout
                           under ~/.richos-nightly/proof-runs/, the last 3 runs kept)
    There is no low-priority switch: CEO ruling §78's mode is for the native app build, and a
    runner of tests never skips the CPU line.

Exit: 0 every check passed; 1 a check failed, timed out, was not admitted, or proof-for.sh
found a changed code path no suite covers (nothing is run then); 2 usage or an unreadable
selection.

WHY THIS EXISTS (2026-09-23). `proof-for.sh` prints the smallest set of commands that can
prove a change, and deliberately runs nothing. The land of 184 commits on 2026-09-22/23
took 2 h 45 min of wall clock, and part of that was the lead running the printed
commands ONE AT A TIME in a hand-written loop. The CEO's end state for landing is "a
one-line change costs seconds of waiting. Nobody watches a test suite." A committed
runner is the answer to the loop; hand-rolling it again is the defect.

WHAT IT DOES WITH EACH FAMILY OF COMMAND, and why nothing is dropped:
  * engine `ci-shard.sh --only-units <u>` lines (one per unit) become ONE units file,
    packed into shards by the engine's own weight-based planner (`ci-shard.sh --units-file
    F --shard i/N`, the path the CI affected-gate uses), each shard leaving a receipt; a
    final `ci-shard.sh --verify-receipts` proves the union of units run equals the set
    selected. A unit that silently did not run fails the land, as it does in CI.
  * `run-tests.sh --only a --only b ...` becomes one `run-tests.sh --only <suite>` per
    suite, so every suite is scheduled, timed and logged on its own. Each keeps
    run-tests.sh's own semantics (declared host gaps, NOT RUN without a screen).
  * `cargo test` lines share one Cargo target, whose lock would serialize them anyway;
    they run in one lane, and a filter already matched by a shorter filter for the same
    target is dropped only because cargo's filter is a substring match (`phone::` runs
    every test `phone::attachments::` names).
  * everything else runs as printed.

WHAT MUST NOT RUN AT THE SAME TIME, and how that is decided (derived, never typed):
  * lane `cargo`   every cargo command (one target directory, one lock);
  * lane `gradle`  every app suite that drives bin/randroid (one Gradle project);
  * lane `guest`   every host-screen suite when RICHOS_GUI_HOST names the test VM (one
                   guest, which run-suite.sh locks);
  * simulators need no lane: every iOS suite creates, boots and deletes its own.

ENGINE SHARDS SHARE THIS CHECKOUT. In CI each shard had a machine of its own; here they run side
by side in one tree. Every unit still has ci-shard.sh's leak canary, so a write outside a sandbox
is still caught; what changes is attribution: a leak by a unit in one shard can also be charged
to whatever unit another shard is running at that moment. The run is red either way; read both.

REFERENCE (T3 Code adoption ledger, richos-hq docs/research/t3code-tooling-what-to-adopt-2026-09-19.md):
§2.3 "shard across runners, not workers" — COPIED as receipted engine shards and one simulator
per iOS shard, because on one Mac with CI paused the separate "runners" are processes and
simulators. §2.4 "every CI job capped at 10 minutes" — COPIED as a budget enforced while the run
goes: named live at --budget, stopped with its whole tree at the deadline. Their CI workflow
files themselves are NOT APPLICABLE (CI paused).

ADMISSION, TWO CONDITIONS, BOTH CHECKED BEFORE EVERY START:
  * A FREE WORKER TOKEN (scripts/lib/worker_tokens.py, engine). The run has --capacity tokens;
    each check holds one while it runs, and the budget's directory is exported to it as
    RICHOS_WORKER_TOKENS, so a nested pool (the mutation harness's eight workers) takes a token
    for every worker beyond its first. The count is of workers on the machine from this run,
    not of commands this runner typed.
  * CEO RULING §77's LINE, the same rule and the same code as testvm/reserve.py: one sample of
    user CPU and memory; below 80% it starts, otherwise the check waits (samples at least 30 s
    apart, at most --admission-wait) and the wait is reported beside its time.
Checks start longest-expected first, so the long poles are not the ones left waiting. While the
run goes, a sampler records user CPU and the tokens held; the summary prints both, which is the
evidence of whether the machine stayed under the line.

A BUDGET SHARED WITH OTHER, SEPARATE RUNS (another agent's, the nightly's) is not this runner's:
the token directory is per run. Pointing RICHOS_WORKER_TOKENS at one machine-wide directory is
the natural extension and nothing here stands in its way.
"""
import argparse
import datetime
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "testvm"))
import reserve  # noqa: E402  (the admission rule, not a copy of it)

SETTLE_SECONDS = 3        # a check just started has not shown its load yet
KEEP_RUNS = 3
# T3 Code caps every CI job at 10 minutes (adoption ledger §2.4, COPY). With no CI here it is
# re-expressed as a REPORTED budget, never a kill: killing a check at a deadline would be
# running less of it, which the land-cost plan rules out. A check past it is named in the
# summary as the next long pole to cut.
BUDGET_SECONDS = 600
DEFAULT_WEIGHTS = (("native-ios", 900), ("native-android", 600), ("cargo", 300), ("engine", 300))


def git_root():
    out = subprocess.run(["git", "-C", APP, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return out.stdout.strip() or os.path.dirname(os.path.dirname(APP))


ROOT = git_root()
# How a check is stopped: the engine's one tree-kill, not a second copy of it.
sys.path.insert(0, os.path.join(ROOT, "richos", "engine", "scripts", "lib"))
import proc_tree  # noqa: E402
import worker_tokens  # noqa: E402


class Item:
    def __init__(self, label, cwd, argv, lane=None, weight=60.0, after=()):
        self.label, self.cwd, self.argv, self.lane = label, cwd, argv, lane
        self.weight, self.after = weight, set(after)
        self.state = "waiting"          # waiting | running | passed | failed | not-admitted
        self.rc = None
        self.admission_wait = 0.0
        self.started = self.ended = None
        self.first_wait = None
        self.proc = None
        self.log = None
        self.notes = []
        self.env = {}
        self.token = None
        self.over_budget = False

    @property
    def seconds(self):
        return (self.ended - self.started) if (self.started and self.ended) else 0.0


# ---------------------------------------------------------------------------------------
# the selection
# ---------------------------------------------------------------------------------------
def selection(args):
    if args.commands:
        with open(args.commands) as fh:
            return [l.rstrip("\n") for l in fh if l.strip()]
    cmd = [os.path.join(HERE, "proof-for.sh"), "--quiet", *args.proof_for_args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 1:
        sys.stderr.write(r.stderr)
        sys.stderr.write("proof-run: proof-for.sh found changed code no suite covers. Nothing was run:\n"
                         "           a green run of an incomplete selection would be a green over a gap.\n")
        sys.exit(1)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.stderr.write("proof-run: proof-for.sh exited %d; nothing was run.\n" % r.returncode)
        sys.exit(2)
    return [l for l in r.stdout.splitlines() if l.strip()]


def is_host_screen(path):
    try:
        text = open(path).read()
    except OSError:
        return False
    return bool(re.search(r"^[ \t]*(\.|source)[ \t]+\S*lib/gui-launch\.sh", text, re.M)
                or re.search(r"^# run-tests: host-screen", text, re.M))


def uses_gradle(path):
    try:
        return "bin/randroid" in open(path).read()
    except OSError:
        return False


def history_weights(state):
    w = {}
    try:
        with open(os.path.join(state, "weights.tsv")) as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2:
                    try:
                        w[parts[0]] = float(parts[1])
                    except ValueError:
                        pass
    except OSError:
        pass
    return w


def default_weight(label, hist):
    if label in hist:
        return hist[label]
    for prefix, secs in DEFAULT_WEIGHTS:
        if label.startswith(prefix):
            return float(secs)
    return 60.0


def cargo_key(argv):
    """(target, filter) for `cargo test ... [filter]`, or None when the shape is not the
    one proof-for.sh prints (then nothing is merged)."""
    if argv[:2] != ["cargo", "test"]:
        return None
    rest = argv[2:]
    flt = ""
    if rest and not rest[-1].startswith("-") and (len(rest) == 1 or rest[-2] not in ("-p", "--manifest-path", "--test", "--bin")):
        flt = rest[-1]
        rest = rest[:-1]
    return (" ".join(rest), flt)


def runtime_for(item):
    """make-engine-asset.test.sh needs RICHOS_RUNTIME_DIR. Unset, the runner supplies the one the
    nightly uses (<state>/runtime, nightly-local.py `runtime()`), only after verify-runtime.py
    accepts it against the tracked recipe, exactly as the nightly does, and says so."""
    if os.environ.get("RICHOS_RUNTIME_DIR"):
        return
    path = os.path.join(os.path.expanduser("~"), ".richos-nightly", "runtime")
    if not os.path.isdir(path):
        item.notes.append("RICHOS_RUNTIME_DIR is unset and %s does not exist; the suite will refuse" % path)
        return
    r = subprocess.run([sys.executable, os.path.join(HERE, "verify-runtime.py"), path,
                        os.path.join(HERE, "runtime-sources.json")], capture_output=True, text=True)
    if r.returncode == 0:
        item.env["RICHOS_RUNTIME_DIR"] = path
        item.notes.append("RICHOS_RUNTIME_DIR=%s (the nightly's runtime, verified against runtime-sources.json)" % path)
    else:
        item.notes.append("RICHOS_RUNTIME_DIR is unset and %s did not verify; the suite will refuse" % path)


def plan(lines, args, logdir, hist):
    items, units, cargo = [], [], []
    for n, line in enumerate(lines, 1):
        s = line.strip()
        m = re.match(r"^cd (\S+) && (.+)$", s)
        if not m:
            raise SystemExit("proof-run: cannot read line %d of the selection: %r" % (n, line))
        cwd, argv = os.path.join(ROOT, m.group(1)), shlex.split(m.group(2))
        if argv[:2] == ["bash", "scripts/ci-shard.sh"] and "--only-units" in argv:
            units.extend(argv[argv.index("--only-units") + 1].split(","))
        elif argv and argv[0] == "scripts/run-tests.sh" and "--only" in argv:
            flags = [a for i, a in enumerate(argv[1:], 1) if a != "--only" and argv[i - 1] != "--only"]
            for i, a in enumerate(argv):
                if a == "--only":
                    suite = argv[i + 1]
                    path = os.path.join(cwd, "scripts", suite)
                    lane = "gradle" if uses_gradle(path) else None
                    if os.environ.get("RICHOS_GUI_HOST") and is_host_screen(path):
                        lane = "guest"
                    label = suite[:-len(".test.sh")] if suite.endswith(".test.sh") else suite
                    items.append(Item(label, cwd, ["scripts/run-tests.sh", *flags, "--only", suite], lane,
                                      default_weight(label, hist)))
        elif argv[:2] == ["cargo", "test"]:
            cargo.append((cwd, argv))
        else:
            first = argv[0]
            if first in ("bash", "node", "python3"):
                first = next((a for a in argv[1:] if not a.startswith("-")), first)
            base = os.path.basename(first)
            label = re.sub(r"\.test\.sh$|\.sh$", "", base)
            if argv[:2] == ["node", "--test"]:
                label = "web-app"
            elif "testvm/test/run-tests.sh" in m.group(2):
                label = "testvm"
            items.append(Item(label, cwd, argv, None, default_weight(label, hist)))
            if label == "make-engine-asset":
                runtime_for(items[-1])
    # cargo: drop a filter a shorter filter on the same target already matches
    keyed = [(cwd, argv, cargo_key(argv)) for cwd, argv in cargo]
    for cwd, argv, key in keyed:
        if key is not None and key[1] and any(
                k is not None and k != key and c == cwd and k[0] == key[0] and k[1] and k[1] in key[1]
                for c, _a, k in keyed):
            continue
        label = "cargo " + (key[1] if key and key[1] else " ".join(argv[2:]))
        items.append(Item(label, cwd, argv, "cargo", default_weight("cargo", hist)))
    # engine: one units file, packed by the engine's planner, then the coverage proof
    if units:
        engine = os.path.join(ROOT, "richos/engine")
        ufile = os.path.join(logdir, "engine-units.txt")
        with open(ufile, "w") as fh:
            fh.write("\n".join(sorted(set(units))) + "\n")
        info = subprocess.run(["bash", "scripts/ci-units.sh", "units", "--units-file", ufile], cwd=engine,
                              capture_output=True, text=True)
        if info.returncode != 0:
            raise SystemExit("proof-run: ci-units.sh could not read the engine units:\n" + info.stderr)
        weight = {}
        for row in info.stdout.splitlines():
            f = row.split("\t")
            if len(f) >= 4:
                weight[f[0]] = float(f[3] or 0)
        # As many shards as allowed: the packer is longest-first, so a unit heavier than all the
        # rest together gets a shard of its own and the others spread over the remainder. A shard
        # count derived from the weights would trust lib/ci-unit-weights.tsv further than it can
        # be trusted: it is dated data, and a stale heavy row would idle the other shards.
        k = max(1, min(args.engine_shards, len(weight)))
        packed = subprocess.run(["bash", "scripts/ci-units.sh", "shards", str(k), "--units-file", ufile],
                                cwd=engine, capture_output=True, text=True)
        per = {}
        for row in packed.stdout.splitlines():
            i, u = row.split("\t", 1)
            per.setdefault(i, []).append(u)
        receipts = os.path.join(logdir, "engine-receipts")
        os.makedirs(receipts, exist_ok=True)
        shard_labels = []
        for i in sorted(per, key=int):
            label = "engine %s/%d" % (i, k)
            shard_labels.append(label)
            items.append(Item(label, engine,
                              ["bash", "scripts/ci-shard.sh", "--units-file", ufile, "--shard", "%s/%d" % (i, k),
                               "--receipt", os.path.join(receipts, "shard-%s.jsonl" % i)],
                              None, sum(weight.get(u, 60.0) for u in per[i])))
            items[-1].notes.append("%d unit(s): %s" % (len(per[i]), ", ".join(per[i])))
        items.append(Item("engine receipts", engine,
                          ["bash", "scripts/ci-shard.sh", "--verify-receipts", receipts, "--units-file", ufile],
                          None, 1.0, after=shard_labels))
    return items


# ---------------------------------------------------------------------------------------
# running
# ---------------------------------------------------------------------------------------
def stamp():
    return datetime.datetime.now().strftime("%H:%M:%S")


def slug(label):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", label).strip("-")[:60]


def launch(item, n, logdir, tokens_dir):
    item.log = os.path.join(logdir, "%02d-%s.log" % (n, slug(item.label)))
    fh = open(item.log, "wb")
    fh.write(("$ cd %s && %s\n" % (os.path.relpath(item.cwd, ROOT), " ".join(shlex.quote(a) for a in item.argv))).encode())
    fh.flush()
    # Its own session, so nothing it does can signal this runner; how it is stopped is
    # proc_tree.kill_tree (its whole tree), never a group or a name.
    env = {**os.environ, **item.env, "RICHOS_WORKER_TOKENS": tokens_dir}
    item.proc = subprocess.Popen(item.argv, cwd=item.cwd, stdout=fh, stderr=subprocess.STDOUT,
                                 stdin=subprocess.DEVNULL, start_new_session=True, env=env)
    fh.close()
    item.state, item.started = "running", time.time()


def admitted(args, sampler):
    """One sample, CEO ruling §77's line and memory rule; (ok, sample). Never skips the CPU line."""
    s = sampler()
    return not reserve._refusal(s, args.max_cpu, 16, cpu_rule=True), s


class Monitor(threading.Thread):
    """The machine while the run is going: user CPU and the worker tokens held, every few
    seconds. It is the evidence that the run stayed under the admission line, not a guess."""

    def __init__(self, every, budget, sampler):
        super().__init__(daemon=True)
        self.every, self.budget, self.sampler = every, budget, sampler
        self.samples = []
        self.halt = threading.Event()

    def run(self):
        while not self.halt.is_set():
            try:
                s = self.sampler()
                self.samples.append((time.time(), s["cpu_user_percent"], s["cpu_system_percent"], self.budget.held()))
            except (BlockingIOError, OSError, ValueError):
                pass
            self.halt.wait(self.every)

    def report(self, line):
        if not self.samples:
            return ["host during the run: no sample was taken"]
        users = [u for _t, u, _s, _h in self.samples]
        held = [h for _t, _u, _s, h in self.samples]
        over = sum(1 for u in users if u >= line)
        return ["host during the run: %d samples, user CPU mean %.0f%%, max %.0f%%, at or over the %g%% "
                "admission line in %d of them; worker tokens held: max %d of %d" % (
                    len(users), sum(users) / len(users), max(users), line, over, max(held), len(self.budget.files))]


def deadline_for(item, args):
    """The kill point: the --deadline floor, or three times what this check is expected to take,
    whichever is later, never past an hour (ci-shard.sh's own rule for a unit)."""
    return min(3600.0, max(args.deadline, 3 * item.weight))


def run(items, args, logdir, sampler=None):
    sampler = sampler or (lambda: reserve.host_sample())
    tokens_dir = os.path.join(logdir, "worker-tokens")
    worker_tokens.init(tokens_dir, args.capacity)
    budget = worker_tokens.Budget(tokens_dir)
    order = sorted(items, key=lambda it: -it.weight)
    running, n, next_sample, last_launch = [], 0, 0.0, 0.0
    t0 = time.time()
    monitor = Monitor(args.sample_every, budget, sampler)
    monitor.start()

    def stop_all(signum, _frame):
        # The whole tree of every running check, not its group alone: a check's descendants
        # start groups and sessions of their own (stop-at-line.py, worker_tokens.py, xcodebuild),
        # and a group kill would leave those running (proc_tree.py's header).
        left = []
        for it in running:
            left += proc_tree.kill_tree(it.proc.pid, 5.0)
            it.proc.wait()
        print("proof-run: interrupted; every check this run started was stopped%s. Logs: %s" % (
            "" if not left else " EXCEPT pids %s, which survived SIGKILL" % left, logdir), flush=True)
        sys.exit(130)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, stop_all)

    while True:
        now = time.time()
        for it in list(running):
            rc = it.proc.poll()
            age = now - it.started
            if rc is None and age >= deadline_for(it, args):
                # ENFORCED, while the run is going: the check and everything it started are
                # stopped, and the run is red by name. Never a skip.
                left = proc_tree.kill_tree(it.proc.pid, 3.0)
                it.proc.wait()
                rc = 124
                it.state = "timed-out"
                it.notes.append("stopped at its %.0f s deadline%s" % (
                    deadline_for(it, args), "" if not left else "; pids %s survived SIGKILL" % left))
            elif rc is None and age >= args.budget and not it.over_budget:
                it.over_budget = True
                print("[%s] OVER BUDGET %-34s running %.0f s, past the %.0f s budget; stopped at %.0f s if still "
                      "running" % (stamp(), it.label, age, args.budget, deadline_for(it, args)), flush=True)
            if rc is not None:
                it.rc, it.ended = rc, time.time()
                if it.state != "timed-out":
                    it.state = "passed" if rc == 0 else "failed"
                running.remove(it)
                it.token.release()
                print("[%s] %-6s %-40s %6.0f s%s" % (stamp(), {"passed": "PASS", "failed": "FAIL"}.get(it.state, "KILLED"),
                                                     it.label, it.seconds, "" if rc == 0 else "  (exit %d)" % rc), flush=True)
        waiting = [it for it in order if it.state == "waiting"]
        if not waiting and not running:
            break
        busy_lanes = {it.lane for it in running if it.lane}
        done = {it.label for it in items if it.state not in ("waiting", "running")}
        ready = [it for it in waiting if (not it.lane or it.lane not in busy_lanes) and it.after <= done]
        # A check whose prerequisites failed still runs: the receipts check is what NAMES a
        # shard that did not finish, so it is never skipped.
        if ready and now >= next_sample and now - last_launch >= (SETTLE_SECONDS if running else 0):
            it = ready[0]
            if it.first_wait is None:
                it.first_wait = now
            token = budget.try_acquire()
            ok, s = (False, None)
            if token is not None:
                ok, s = admitted(args, sampler)
                if not ok:
                    token.release()
            if ok:
                it.admission_wait, it.token = now - it.first_wait, token
                n += 1
                launch(it, n, logdir, tokens_dir)
                running.append(it)
                last_launch = time.time()
                print("[%s] start  %-40s %s" % (stamp(), it.label,
                                                "(waited %.0f s for admission)" % it.admission_wait if it.admission_wait >= 1 else ""),
                      flush=True)
            elif s is not None:
                # Refused by the CPU line or the memory rule (not merely waiting for a token).
                waited = now - it.first_wait
                if waited >= args.admission_wait:
                    it.state, it.admission_wait = "not-admitted", waited
                    it.notes.append("not admitted after %.0f s: %s" % (waited, reserve.describe(s)))
                    print("[%s] REFUSED %-39s not admitted after %.0f s (%s)" % (stamp(), it.label, waited,
                                                                                 reserve.describe(s)), flush=True)
                else:
                    next_sample = now + reserve.MIN_RETRY_SECONDS
                    if not running:
                        print("[%s] wait   %-40s admission: %s" % (stamp(), it.label, reserve.describe(s)), flush=True)
        time.sleep(0.2)
    monitor.halt.set()
    monitor.join(timeout=5)
    args.monitor_lines = monitor.report(args.max_cpu)
    return time.time() - t0


def notes_from_logs(items):
    for it in items:
        if not it.log:
            continue
        try:
            text = open(it.log, errors="replace").read()
        except OSError:
            continue
        for line in text.splitlines():
            if re.search(r"NOT RUN|SKIPPED:|KNOWN-RED", line):
                it.notes.append(line.strip()[:160])


def summarize(items, wall, logdir, budget_seconds=600, monitor_lines=()):
    serial = sum(it.seconds for it in items)
    print("")
    print("proof-run: %d check(s), wall %.0f s (%.1f min); the same checks one after another: %.0f s" %
          (len(items), wall, wall / 60, serial))
    for line in monitor_lines:
        print("  " + line)
    print("  %-40s %-12s %8s %10s  %s" % ("check", "result", "seconds", "admission", "log"))
    rows = []
    for it in sorted(items, key=lambda i: -(i.seconds)):
        print("  %-40s %-12s %8.0f %9.0fs  %s" % (it.label, it.state.upper(), it.seconds, it.admission_wait,
                                                 os.path.basename(it.log or "-")))
        if it.seconds > budget_seconds:
            print("      OVER BUDGET: %.0f s is past the %.0f s budget one check may take" % (it.seconds, budget_seconds))
        for note in it.notes[:6]:
            print("      %s" % note)
        rows.append({"check": it.label, "result": it.state, "seconds": round(it.seconds, 1),
                     "admission_wait": round(it.admission_wait, 1), "exit": it.rc, "log": it.log,
                     "command": "cd %s && %s" % (os.path.relpath(it.cwd, ROOT), " ".join(shlex.quote(a) for a in it.argv))})
    with open(os.path.join(logdir, "summary.json"), "w") as fh:
        json.dump({"wall_seconds": round(wall, 1), "serial_seconds": round(serial, 1), "host": list(monitor_lines),
                   "checks": rows}, fh, indent=1)
    bad = [it for it in items if it.state != "passed"]
    print("")
    if bad:
        print("=== proof-run: %d of %d check(s) did NOT pass: %s ===" % (len(bad), len(items),
                                                                        ", ".join("%s (%s)" % (b.label, b.state) for b in bad)))
        print("    logs: %s" % logdir)
        return 1
    print("=== proof-run: all %d check(s) passed in %.0f s ===" % (len(items), wall))
    print("    logs: %s" % logdir)
    return 0


def default_logdir():
    base = os.environ.get("RICHOS_PROOF_RUN_DIR", os.path.join(os.path.expanduser("~"), ".richos-nightly", "proof-runs"))
    wid = subprocess.run(["/usr/bin/shasum", "-a", "256"], input=ROOT, capture_output=True, text=True).stdout[:12]
    return os.path.join(base, wid)


def rotate(parent):
    """Bounded by construction (§54): the last KEEP_RUNS runs of this checkout, nothing more."""
    try:
        runs = sorted(d for d in os.listdir(parent) if re.fullmatch(r"\d{8}T\d{6}Z(-\d+)?", d))
    except OSError:
        return
    for d in runs[:-KEEP_RUNS]:
        shutil.rmtree(os.path.join(parent, d), ignore_errors=True)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                usage="proof-run.py [options] [proof-for arguments]")
    p.add_argument("--commands")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--as-printed", action="store_true")
    p.add_argument("--capacity", type=int, default=max(2, int((os.cpu_count() or 4) * 0.8)))
    p.add_argument("--engine-shards", type=int, default=max(1, (os.cpu_count() or 4) // 2))
    p.add_argument("--admission-wait", type=float, default=1800)
    p.add_argument("--max-cpu", type=float, default=80)
    p.add_argument("--budget", type=float, default=BUDGET_SECONDS)
    p.add_argument("--deadline", type=float, default=3 * BUDGET_SECONDS)
    p.add_argument("--sample-every", type=float, default=10)
    p.add_argument("--log-dir")
    args, rest = p.parse_known_args(argv)
    args.proof_for_args = rest
    if args.capacity < 1 or args.engine_shards < 1:
        p.error("--capacity and --engine-shards must be at least 1")
    parent = args.log_dir or default_logdir()
    run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    logdir = os.path.join(parent, run_id if not args.log_dir else "")
    os.makedirs(logdir, exist_ok=True)
    hist_dir = default_logdir()
    lines = selection(args)
    items = as_printed(lines) if args.as_printed else plan(lines, args, logdir, history_weights(hist_dir))
    if not items:
        print("proof-run: the selection is empty — nothing to run. (For a documentation-only change that is"
              " the right answer; proof-for.sh says so without --quiet.)")
        return 0
    print("proof-run: %d check(s) from %d selected command(s); a budget of %d workers for the whole run, "
          "nested workers included; %.0f s budget per check, stopped at its deadline" % (
              len(items), len(lines), args.capacity, args.budget))
    for it in sorted(items, key=lambda i: -i.weight):
        print("  %-40s lane %-7s ~%5.0f s  cd %s && %s" % (it.label, it.lane or "-", it.weight,
                                                         os.path.relpath(it.cwd, ROOT), " ".join(it.argv)))
    if args.dry_run:
        return 0
    print("  logs: %s" % logdir, flush=True)
    wall = run(items, args, logdir)
    notes_from_logs(items)
    rc = summarize(items, wall, logdir, args.budget, getattr(args, "monitor_lines", ()))
    if not args.as_printed:
        record_weights(hist_dir, items)
    if not args.log_dir:
        rotate(parent)
    return rc


def as_printed(lines):
    """The selection exactly as proof-for.sh printed it, one command after another: the shape a
    hand-written loop runs, kept so the runner's own saving can be measured on any selection."""
    items = []
    for n, line in enumerate(lines, 1):
        m = re.match(r"^cd (\S+) && (.+)$", line.strip())
        if not m:
            raise SystemExit("proof-run: cannot read line %d of the selection: %r" % (n, line))
        argv = shlex.split(m.group(2))
        it = Item("%02d %s" % (n, slug(" ".join(argv))[:36]), os.path.join(ROOT, m.group(1)), argv,
                  "as-printed", float(len(lines) - n + 1))
        if "make-engine-asset.test.sh" in m.group(2):
            runtime_for(it)
        items.append(it)
    return items


def record_weights(state, items):
    """What each check measured, so the next run starts the long poles first."""
    os.makedirs(state, exist_ok=True)
    w = history_weights(state)
    for it in items:
        if it.state == "passed" and not it.label.startswith("engine "):
            w[it.label] = round(it.seconds, 1)
    with open(os.path.join(state, "weights.tsv"), "w") as fh:
        for k in sorted(w):
            fh.write("%s\t%s\n" % (k, w[k]))


if __name__ == "__main__":
    sys.exit(main())
