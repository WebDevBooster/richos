#!/usr/bin/env python3
"""A pause suspends exactly the paused agent's running work and RESUME continues it, correct.

The real-tree cases start a subagent-shaped process tree the way the harness does
(a shell leading its own process group, prefixed with the ownership lines the Bash
rewriter adds), with a CPU-bound worker, a child in its own session and a detached
reparented grandchild. Each computes a known hash chain. The hold must stop all of
them within seconds with no CPU advance; after release each result must be correct.
All state is in a temporary directory; nothing outside this test's own processes
is ever signaled.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import agent_hold

SHELL = shutil.which("zsh") or "/bin/sh"
ROUNDS = 400000

WORKER = r'''
import hashlib, os, sys, time
out, rounds = sys.argv[1], int(sys.argv[2])
def run():
    open(out + ".pid", "w").write("%d %f" % (os.getpid(), time.time()))
    h = b"richos"
    for i in range(rounds):
        h = hashlib.sha256(h).digest()
        if i % 20000 == 0:
            open(out + ".progress", "w").write(str(i))
    open(out + ".tmp", "w").write(h.hex())
    os.replace(out + ".tmp", out)
mode = sys.argv[3] if len(sys.argv) > 3 else "plain"
if mode == "session":
    os.setsid()
if mode == "detach":
    if os.fork():
        sys.exit(0)
    os.setsid()
    if os.fork():
        os._exit(0)
run()
'''

WALK = r'''
import json, os, subprocess, sys, time
slot, out = sys.argv[1], sys.argv[2]
open(slot, "w").write(json.dumps({"pid": os.getpid(), "since": time.time(), "purpose": "fixture walk", "slot": "guest.lock", "state": "running"}))
child = subprocess.Popen([sys.executable, "-c", "import time\nfor i in range(400): time.sleep(0.05)"])
open(out + ".pid", "w").write("%d %d" % (os.getpid(), child.pid))
child.wait()
'''


def expected():
    h = b"richos"
    for _ in range(ROUNDS):
        h = hashlib.sha256(h).digest()
    return h.hex()


def wait_for(predicate, seconds=20.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def state(pid):
    out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return out


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agent-hold-test.")
        self.env_before = {k: os.environ.get(k) for k in ("RICHOS_AGENT_HOLD_DIR", "TESTVM_ROOT", "RICHOS_CPU_GUARD_STATE")}
        os.environ["RICHOS_AGENT_HOLD_DIR"] = os.path.join(self.tmp, "hold")
        os.environ["TESTVM_ROOT"] = os.path.join(self.tmp, "testvm")
        os.environ["RICHOS_CPU_GUARD_STATE"] = os.path.join(self.tmp, "cpu-guard")
        os.makedirs(os.environ["TESTVM_ROOT"])
        self.session = "fixture-session-%d" % os.getpid()
        self.agent = "a%dfixture" % os.getpid()
        self.procs, self.pids = [], set()
        self.worker = os.path.join(self.tmp, "worker.py")
        Path(self.worker).write_text(WORKER)

    def tearDown(self):
        # Only processes this test started and recorded: continue, then kill them.
        for pid in sorted(self.pids):
            for sig in (signal.SIGCONT, signal.SIGKILL):
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
        for p in self.procs:
            try:
                os.killpg(p.pid, signal.SIGCONT)
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                # macOS answers EPERM for a group whose only member is an unreaped zombie.
                pass
            p.wait()
        for k, v in self.env_before.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)

    def payload(self, tuid="toolu_fixture1", agent=None):
        return {"tool_name": "Bash", "session_id": self.session, "agent_id": self.agent if agent is None else agent,
                "tool_use_id": tuid, "cwd": self.tmp, "tool_input": {"command": "true"}}

    def start_call(self, body, tuid="toolu_fixture1", agent=None):
        """One Bash call, shaped as the harness runs it: its own group, under this process."""
        prefix = agent_hold.capture(self.payload(tuid, agent))
        self.assertTrue(prefix, "a subagent's call gets ownership lines")
        p = subprocess.Popen([SHELL, "-c", "set -e -o pipefail\n" + prefix + body], process_group=0,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(p)
        return p

    def out(self, name):
        return os.path.join(self.tmp, name)

    def worker_pid(self, name):
        path = self.out(name) + ".pid"
        self.assertTrue(wait_for(lambda: os.path.exists(path)), "%s started" % name)
        pid = int(Path(path).read_text().split()[0])
        self.pids.add(pid)
        return pid


class Capture(Base):
    def test_lead_call_is_not_rewritten(self):
        p = self.payload()
        del p["agent_id"]
        self.assertEqual(agent_hold.capture(p), "")

    def test_invalid_ids_are_not_recorded(self):
        for bad in ("../escape", "", "a b", "x" * 200):
            self.assertEqual(agent_hold.capture(self.payload(agent=bad)), "", bad)
        self.assertEqual(agent_hold.capture({"tool_name": "Read", "agent_id": self.agent}), "")

    def test_prefix_records_pid_and_exports_tag(self):
        prefix = agent_hold.capture(self.payload())
        self.assertIn('"$$" "$PPID"', prefix)
        self.assertIn("export %s=%s" % (agent_hold.TAG, self.agent), prefix)
        self.assertTrue(os.path.exists(os.path.join(os.environ["RICHOS_AGENT_HOLD_DIR"], "shells",
                                                    self.session, self.agent, "toolu_fixture1.json")))

    def test_prune_removes_finished_calls_only(self):
        d = os.path.join(os.environ["RICHOS_AGENT_HOLD_DIR"], "shells", self.session, self.agent)
        agent_hold.capture(self.payload("toolu_old"))
        Path(d, "toolu_old.pid").write_text("999999 1\n")        # no such process
        agent_hold.capture(self.payload("toolu_live"))
        Path(d, "toolu_live.pid").write_text("%d 1\n" % os.getpid())
        old = time.time() - 120
        for n in ("toolu_old.json", "toolu_live.json"):
            os.utime(os.path.join(d, n), (old, old))
        agent_hold.capture(self.payload("toolu_new"))
        names = sorted(os.listdir(d))
        self.assertNotIn("toolu_old.json", names)
        self.assertIn("toolu_live.json", names)
        self.assertIn("toolu_new.json", names)


class Ownership(Base):
    def test_record_pointing_at_an_unrelated_process_is_refused(self):
        # A record naming a process that did not start inside its window (a reused PID, or a forgery).
        agent_hold.capture(self.payload("toolu_forged"))
        d = os.path.join(os.environ["RICHOS_AGENT_HOLD_DIR"], "shells", self.session, self.agent)
        other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        self.procs.append(other)
        time.sleep(1.2)
        # Right parent, but it started before the hook ran: refused.
        os.utime(os.path.join(d, "toolu_forged.json"), None)
        Path(d, "toolu_forged.json").write_text(json.dumps({"at": time.time() + 5}))
        Path(d, "toolu_forged.pid").write_text("%d %d\n" % (other.pid, os.getpid()))
        self.assertEqual(agent_hold.owned_shells(self.session, self.agent, agent_hold.snapshot()), [])
        # Wrong parent: refused.
        Path(d, "toolu_forged.json").write_text(json.dumps({"at": time.time() - 30}))
        Path(d, "toolu_forged.pid").write_text("%d %d\n" % (other.pid, 1))
        self.assertEqual(agent_hold.owned_shells(self.session, self.agent, agent_hold.snapshot()), [])
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertEqual(r["held"], {})
        self.assertFalse(state(other.pid).startswith("T"))

    def test_same_command_line_elsewhere_is_never_touched(self):
        # An identical worker, not started by the agent: same argv, same script, never suspended.
        twin = subprocess.Popen([sys.executable, self.worker, self.out("twin"), str(ROUNDS * 20)], process_group=0)
        self.procs.append(twin)
        self.start_call('%s %s %s %d' % (sys.executable, self.worker, self.out("w1"), ROUNDS * 20))
        self.worker_pid("w1")
        self.worker_pid("twin")
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertTrue(r["ok"], r)
        self.assertNotIn(str(twin.pid), r["held"])
        self.assertFalse(state(twin.pid).startswith("T"), state(twin.pid))
        agent_hold.release(self.session, self.agent)

    def test_another_agents_work_is_never_touched(self):
        self.start_call('%s %s %s %d' % (sys.executable, self.worker, self.out("mine"), ROUNDS * 20))
        self.start_call('%s %s %s %d' % (sys.executable, self.worker, self.out("theirs"), ROUNDS * 20),
                        tuid="toolu_other", agent="bpeerfixture")
        mine, theirs = self.worker_pid("mine"), self.worker_pid("theirs")
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertIn(str(mine), r["held"])
        self.assertNotIn(str(theirs), r["held"])
        self.assertFalse(state(theirs).startswith("T"))
        agent_hold.release(self.session, self.agent)

    def test_idle_agent_holds_nothing(self):
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertEqual(r["held"], {})
        self.assertIn("nothing was suspended", agent_hold.describe_hold(r))
        self.assertEqual(len(agent_hold.records()), 1, "the record exists so new commands wait")
        self.assertEqual(agent_hold.release(self.session, self.agent)["continued"], [])
        self.assertEqual(agent_hold.records(), [])


class RealTree(Base):
    def test_hold_frees_cpu_at_once_and_release_finishes_correctly(self):
        want = expected()
        body = "\n".join([
            '%s %s %s %d session &' % (sys.executable, self.worker, self.out("session"), ROUNDS),
            '%s %s %s %d detach' % (sys.executable, self.worker, self.out("detached"), ROUNDS),
            '%s %s %s %d' % (sys.executable, self.worker, self.out("plain"), ROUNDS),
            'wait',
        ])
        call = self.start_call(body)
        pids = {n: self.worker_pid(n) for n in ("plain", "session", "detached")}
        self.assertTrue(wait_for(lambda: all(os.path.exists(self.out(n) + ".progress") for n in pids)))
        t0 = time.monotonic()
        r = agent_hold.hold(self.session, self.agent, "fixture-agent", sample=1.0)
        took = time.monotonic() - t0
        self.assertTrue(r["ok"], r)
        for name, pid in pids.items():
            self.assertIn(str(pid), r["held"], "%s (%d) is held; the detached one is found by its tag" % (name, pid))
            self.assertTrue(state(pid).startswith("T"), (name, state(pid)))
        self.assertIn(str(call.pid), r["held"], "the call's own shell is held")
        self.assertNotIn(str(os.getpid()), r["held"], "the session process is never held")
        self.assertLess(r["stopped_seconds"], 3.0)
        self.assertEqual(r["cpu_during_sample"], 0.0, r)
        progress = {n: Path(self.out(n) + ".progress").read_text() for n in pids}
        time.sleep(1.0)
        self.assertEqual(progress, {n: Path(self.out(n) + ".progress").read_text() for n in pids}, "no progress while held")
        for n in pids:
            self.assertFalse(os.path.exists(self.out(n)), "%s has not finished while held" % n)
        sys.stderr.write("\n  measured: %d processes suspended in %.3f s (hold call %.3f s); "
                         "CPU over the next %.1f s: %.2f s\n" % (len(r["held"]), r["stopped_seconds"], took,
                                                                 r["sample_seconds"], r["cpu_during_sample"]))
        rel = agent_hold.release(self.session, self.agent)
        self.assertEqual(sorted(map(int, r["held"])), sorted(rel["continued"]), rel)
        self.assertEqual(call.wait(timeout=120), 0)
        self.assertTrue(wait_for(lambda: os.path.exists(self.out("detached")), 120))
        for n in pids:
            self.assertEqual(Path(self.out(n)).read_text(), want, "%s finished with the correct result" % n)
        self.assertEqual(agent_hold.records(), [], "the hold record is gone after release")

    def test_a_process_forked_during_the_hold_is_caught(self):
        body = 'while :; do %s -c "import time; time.sleep(0.2)"; done' % sys.executable
        call = self.start_call(body)
        time.sleep(0.5)
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertTrue(r["ok"], r)
        tree = agent_hold.subtree([call.pid], agent_hold.snapshot())
        self.assertTrue(all(state(p).startswith("T") for p in tree), [(p, state(p)) for p in tree])
        agent_hold.release(self.session, self.agent)
        self.assertFalse(state(call.pid).startswith("T"))

    def test_new_command_of_a_held_agent_waits_then_runs(self):
        # Rich, 2026-09-27: a held agent kept starting commands until the message reached it.
        # Its NEW command must start no process until release, then run normally; never refused.
        self.start_call('%s %s %s %d' % (sys.executable, self.worker, self.out("w"), ROUNDS * 20))
        self.worker_pid("w")
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertTrue(r["ok"], r)
        marker = self.out("new-command-ran")
        t_start = time.monotonic()
        late = self.start_call('%s -c "open(%r, \'w\').write(\'ran\')"' % (sys.executable, marker), tuid="toolu_late")
        self.assertTrue(wait_for(lambda: state(late.pid).startswith("T"), 5), "the new call suspends itself")
        waited_at = time.monotonic() - t_start
        time.sleep(1.0)
        table = agent_hold.snapshot()
        self.assertEqual(agent_hold.subtree([late.pid], table), {late.pid}, "no process started under it")
        self.assertFalse(os.path.exists(marker), "its command has not run")
        self.assertIsNone(late.poll(), "it waits; it was not refused")
        rel = agent_hold.release(self.session, self.agent)
        self.assertIn(late.pid, rel["waited"], rel)
        self.assertIn("new command(s) that waited", agent_hold.describe_release(rel))
        self.assertEqual(late.wait(timeout=30), 0, "it runs normally after release")
        self.assertEqual(Path(marker).read_text(), "ran")
        sys.stderr.write("\n  measured: a held agent's new call suspended itself %.3f s after launch; "
                         "started 0 processes while held; exit 0 after release\n" % waited_at)

    def test_idle_held_agent_new_command_waits(self):
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertEqual(r["held"], {})
        self.assertIn("new commands wait", agent_hold.describe_hold(r))
        late = self.start_call("true", tuid="toolu_idle")
        self.assertTrue(wait_for(lambda: state(late.pid).startswith("T"), 5))
        rel = agent_hold.release(self.session, self.agent)
        self.assertEqual(rel["waited"], [late.pid])
        self.assertEqual(late.wait(timeout=30), 0)

    def test_test_vm_walk_is_left_running(self):
        walk = os.path.join(self.tmp, "walk.py")
        Path(walk).write_text(WALK)
        slot = os.path.join(os.environ["TESTVM_ROOT"], "guest.lock")
        body = "\n".join([
            '%s %s %s %s &' % (sys.executable, walk, slot, self.out("walk")),
            '%s %s %s %d' % (sys.executable, self.worker, self.out("w"), ROUNDS * 20),
            'wait',
        ])
        call = self.start_call(body)
        worker = self.worker_pid("w")
        self.assertTrue(wait_for(lambda: os.path.exists(self.out("walk") + ".pid")))
        walker, walk_child = map(int, Path(self.out("walk") + ".pid").read_text().split())
        self.pids |= {walker, walk_child}
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertTrue(r["ok"], r)
        self.assertIn(str(worker), r["held"])
        self.assertIn(str(call.pid), r["held"])
        for pid in (walker, walk_child):
            self.assertNotIn(str(pid), r["held"])
            self.assertFalse(state(pid).startswith("T"), state(pid))
        self.assertTrue(any("test VM walk pid %d" % walker in n for n in r["notes"]), r["notes"])
        self.assertIn("left running", agent_hold.describe_hold(r))
        agent_hold.release(self.session, self.agent)

    def test_session_end_and_dead_session_release_everything(self):
        self.start_call('%s %s %s %d' % (sys.executable, self.worker, self.out("w"), ROUNDS * 20))
        pid = self.worker_pid("w")
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertIn(str(pid), r["held"])
        out = agent_hold.release_session(self.session)
        self.assertEqual(len(out), 1)
        self.assertFalse(state(pid).startswith("T"))
        # A hold whose recorded session process is gone is released too; a live one is not.
        agent_hold.hold(self.session, self.agent, "fixture", session_pid=os.getpid())
        self.assertEqual(agent_hold.release_orphans(), [])
        self.assertTrue(state(pid).startswith("T"))
        path = agent_hold._held_path(self.session, self.agent)
        rec = json.loads(Path(path).read_text())
        rec["parents"] = {"999999": 0}
        Path(path).write_text(json.dumps(rec))
        self.assertEqual(len(agent_hold.release_orphans()), 1)
        self.assertFalse(state(pid).startswith("T"))

    def test_release_skips_a_reused_pid(self):
        self.start_call('%s %s %s %d' % (sys.executable, self.worker, self.out("w"), ROUNDS * 20))
        pid = self.worker_pid("w")
        # Older than release's one-second window for commands that started while held.
        time.sleep(agent_hold.BIRTH_SLACK + 0.5)
        agent_hold.hold(self.session, self.agent, "fixture")
        path = agent_hold._held_path(self.session, self.agent)
        rec = json.loads(Path(path).read_text())
        # As if every held PID now named another process. (All of them: a continued
        # shell may itself continue its stopped child, which is not a signal from us.)
        rec["held"] = {k: v - 3600 for k, v in rec["held"].items()}
        Path(path).write_text(json.dumps(rec))
        rel = agent_hold.release(self.session, self.agent)
        self.assertIn(pid, rel["gone"])
        self.assertEqual(rel["continued"], [], rel)
        self.assertTrue(state(pid).startswith("T"), "a process that fails the start-time check is not signaled")


if __name__ == "__main__":
    unittest.main(verbosity=2)
