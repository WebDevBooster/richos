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


REGISTRY = r'''
import os, sys
name = sys.argv[sys.argv.index("--name") + 1]
done = os.path.join(os.path.dirname(os.path.abspath(__file__)), "finished-" + name)
print(("finished\tstopped from the screen" if os.path.exists(done) else "active\t") )
'''

# A daemon as adb starts one: fork, the parent exits, the child leads its own session.
DAEMON = r'''
import os, sys, time
out = sys.argv[1]
if os.fork():
    sys.exit(0)
os.setsid()
open(out + ".pid", "w").write(str(os.getpid()))
while True:
    time.sleep(0.05)
'''

# run.sh's login keeper: `nohup claude-login.sh keep ... &` then `echo $! > claude-keep.pid`,
# after which run.sh exits and the keeper is reparented.
KEEPER = r'''
import os, sys, subprocess, time
pidfile = sys.argv[1]
p = subprocess.Popen([sys.executable, "-c", "import time\nwhile True: time.sleep(0.05)"])
open(pidfile, "w").write(str(p.pid))
'''

# Holds a Cargo-style target lock for as long as it runs.
LOCKER = r'''
import fcntl, os, sys, time
lock = open(sys.argv[1], "w")
fcntl.flock(lock, fcntl.LOCK_EX)
open(sys.argv[2], "w").write(str(os.getpid()))
while True:
    time.sleep(0.05)
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
        self.env_before = {k: os.environ.get(k) for k in (
            "RICHOS_AGENT_HOLD_DIR", "TESTVM_ROOT", "RICHOS_CPU_GUARD_STATE", "RICHOS_AGENT_HOLD_WATCH_SECONDS",
            "RICHOS_AGENT_HOLD_REGISTRY", agent_hold.TAG, agent_hold.SESSION_TAG)}
        os.environ["RICHOS_AGENT_HOLD_DIR"] = os.path.join(self.tmp, "hold")
        os.environ["TESTVM_ROOT"] = os.path.join(self.tmp, "testvm")
        os.environ["RICHOS_CPU_GUARD_STATE"] = os.path.join(self.tmp, "cpu-guard")
        os.environ["RICHOS_AGENT_HOLD_WATCH_SECONDS"] = "0.2"
        # The registry the watchdog asks is a stand-in: "finished" once finished-<name> exists.
        registry = os.path.join(self.tmp, "registry.py")
        Path(registry).write_text(REGISTRY)
        os.environ["RICHOS_AGENT_HOLD_REGISTRY"] = registry
        os.makedirs(os.environ["TESTVM_ROOT"])
        self.session = "fixture-session-%d" % os.getpid()
        self.agent = "a%dfixture" % os.getpid()
        self.procs, self.pids = [], set()
        self.worker = os.path.join(self.tmp, "worker.py")
        Path(self.worker).write_text(WORKER)

    def tearDown(self):
        # Only processes this test started and recorded: continue, then kill them.
        table = agent_hold.snapshot()
        for r in agent_hold.records():
            wd = r.get("watchdog") or {}
            if wd.get("pid") in table and table[wd["pid"]]["birth"] == wd.get("birth"):
                self.pids.add(wd["pid"])
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
        """One background-shaped Bash call, as the harness runs it: its own group, under this process."""
        prefix = agent_hold.capture(self.payload(tuid, agent))
        self.assertTrue(prefix, "a subagent's call gets ownership lines")
        p = subprocess.Popen([SHELL, "-c", "set -e -o pipefail\n" + prefix + body], process_group=0,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(p)
        return p

    def start_rewritten(self, command, tuid="toolu_fg1", background=False):
        """One call rewritten exactly as shell-evidence.py does (a foreground call is wrapped),
        its output captured as the harness captures it."""
        payload = self.payload(tuid)
        payload["tool_input"] = {"command": command, "run_in_background": background}
        got = agent_hold.rewrite(payload)
        self.assertTrue(got, "a subagent's call is rewritten")
        # Its own session, as Claude Code starts every Bash shell (ps shows `Ss`).
        p = subprocess.Popen([SHELL, "-c", "set -e -o pipefail\n" + got["command"]], start_new_session=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True)
        self.procs.append(p)
        return p, got

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

    def test_new_command_of_a_held_agent_is_refused_at_once_with_the_wait(self):
        # Sage's catch B (2026-09-28): a new call that suspended itself kept its tool round
        # open, so the queued WAIT could not reach the agent. It must return at once, run
        # nothing, and carry the WAIT itself.
        for background in (False, True):
            self.start_call('%s %s %s %d' % (sys.executable, self.worker, self.out("w%d" % background), ROUNDS * 20),
                            tuid="toolu_bgw%d" % background)
            self.worker_pid("w%d" % background)
            r = agent_hold.hold(self.session, self.agent, "fixture")
            self.assertTrue(r["ok"], r)
            marker = self.out("new-command-ran")
            t_start = time.monotonic()
            late, _got = self.start_rewritten('%s -c "open(%r, \'w\').write(\'ran\')"' % (sys.executable, marker),
                                              tuid="toolu_late%d" % background, background=background)
            stdout, _err = late.communicate(timeout=10)
            took = time.monotonic() - t_start
            self.assertEqual(late.returncode, agent_hold.REFUSED_EXIT)
            self.assertEqual(stdout.strip(), agent_hold.REFUSED_TEXT)
            self.assertIn(agent_hold.WAIT_COMMAND, stdout)
            self.assertFalse(os.path.exists(marker), "its command did not run")
            self.assertLess(took, 3.0)
            agent_hold.release(self.session, self.agent)
            sys.stderr.write("\n  measured: a held agent's new %s call returned the WAIT in %.3f s and ran nothing\n"
                             % ("background" if background else "foreground", took))

    def test_idle_held_agent_new_command_is_refused(self):
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertEqual(r["held"], {})
        self.assertIn("next command returns the WAIT at once", agent_hold.describe_hold(r))
        late, _got = self.start_rewritten("true", tuid="toolu_idle")
        self.assertEqual(late.wait(timeout=10), agent_hold.REFUSED_EXIT)
        agent_hold.release(self.session, self.agent)
        again, _got = self.start_rewritten("true", tuid="toolu_idle2")
        self.assertEqual(again.wait(timeout=10), 0, "after release it runs normally")

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
        # The backstop for a watchdog that itself died: end ours (we started it), then the
        # next SessionStart's release_orphans() must still find the dead session.
        wd = rec["watchdog"]["pid"]
        os.kill(wd, signal.SIGKILL)
        self.assertTrue(wait_for(lambda: not state(wd) or state(wd).startswith("Z")))
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


class Catches(Base):
    """Sage's catches on the first design (sage-opus-pauseplan1), each as a failing case first."""

    def script(self, name, text):
        path = os.path.join(self.tmp, name)
        Path(path).write_text(text)
        return path

    def pid_from(self, path):
        self.assertTrue(wait_for(lambda: os.path.exists(path) and Path(path).read_text().strip()), path)
        pid = int(Path(path).read_text().split()[0])
        self.pids.add(pid)
        return pid

    def test_catch2_a_supervisor_registered_as_a_cpu_guard_session_root_is_held_with_its_check(self):
        # proc_tree.py registers its supervisor as a cpu_guard "session" root; left running
        # while its check was frozen, its own bounds expired and it killed the check.
        sup = self.script("sup.py", "import os, subprocess, sys, time\n"
                          "open(sys.argv[1], 'w').write(str(os.getpid()))\n"
                          "subprocess.run([sys.executable, sys.argv[2], sys.argv[3], sys.argv[4]])\n")
        self.start_call("%s %s %s %s %s %d" % (sys.executable, sup, self.out("sup.pid"), self.worker,
                                               self.out("w"), ROUNDS * 20))
        sup_pid = self.pid_from(self.out("sup.pid"))
        self.worker_pid("w")
        roots = os.path.join(os.environ["RICHOS_CPU_GUARD_STATE"], "roots")
        os.makedirs(roots)
        lstart = agent_hold.snapshot()[sup_pid]["lstart"]
        Path(roots, "%d.json" % sup_pid).write_text(json.dumps(
            {"pid": sup_pid, "birth": " ".join(lstart.split()), "label": "managed python3", "role": "session"}))
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertIn(str(sup_pid), r["held"], r)
        self.assertTrue(state(sup_pid).startswith("T"))
        agent_hold.release(self.session, self.agent)

    def test_catch4_the_test_vm_login_keeper_is_left_running(self):
        guest = os.path.join(os.environ["TESTVM_ROOT"], "run", "walk-fixture")
        os.makedirs(guest)
        keeper_pidfile = os.path.join(guest, "claude-keep.pid")
        keeper = self.script("keeper.py", KEEPER)
        self.start_call("%s %s %s\n%s %s %s %d" % (sys.executable, keeper, keeper_pidfile,
                                                   sys.executable, self.worker, self.out("w"), ROUNDS * 20))
        kpid = self.pid_from(keeper_pidfile)
        worker = self.worker_pid("w")
        self.assertTrue(wait_for(lambda: agent_hold.snapshot().get(kpid, {}).get("ppid") == 1), "reparented")
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertIn(str(worker), r["held"])
        self.assertNotIn(str(kpid), r["held"], "the keeper carries the tag but is the walk's, not frozen")
        self.assertFalse(state(kpid).startswith("T"))
        self.assertIn("login keeper pid %d" % kpid, agent_hold.describe_hold(r))
        agent_hold.release(self.session, self.agent)

    def test_catch7_a_left_running_walk_says_its_scenario_has_no_bound(self):
        Path(os.environ["TESTVM_ROOT"], "guest.lock").write_text("")
        walk = self.script("walk.py", WALK)
        self.start_call("%s %s %s %s &\n%s %s %s %d\nwait" % (
            sys.executable, walk, os.path.join(os.environ["TESTVM_ROOT"], "guest.lock"), self.out("walk"),
            sys.executable, self.worker, self.out("w"), ROUNDS * 20))
        self.worker_pid("w")
        self.assertTrue(wait_for(lambda: os.path.exists(self.out("walk") + ".pid")))
        self.pids |= set(map(int, Path(self.out("walk") + ".pid").read_text().split()))
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertIn("scenario step has no time bound", agent_hold.describe_hold(r))
        agent_hold.release(self.session, self.agent)

    def test_catch5_a_shared_daemon_it_started_is_left_running_and_named(self):
        daemon = self.script("daemon.py", DAEMON)
        self.start_call("%s %s %s\n%s %s %s %d" % (sys.executable, daemon, self.out("d"),
                                                   sys.executable, self.worker, self.out("w"), ROUNDS * 20))
        dpid = self.pid_from(self.out("d") + ".pid")
        worker = self.worker_pid("w")
        self.assertTrue(wait_for(lambda: agent_hold.snapshot().get(dpid, {}).get("ppid") == 1))
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertIn(str(worker), r["held"])
        self.assertNotIn(str(dpid), r["held"])
        self.assertFalse(state(dpid).startswith("T"))
        self.assertIn("shared daemon(s) it started left running for other agents' work: pid %d" % dpid,
                      agent_hold.describe_hold(r))
        agent_hold.release(self.session, self.agent)

    def test_catch5_the_locks_held_work_keeps_are_named(self):
        lock = os.path.join(self.tmp, "cargo-target", "debug", ".cargo-lock")
        os.makedirs(os.path.dirname(lock))
        locker = self.script("locker.py", LOCKER)
        self.start_call("%s %s %s %s" % (sys.executable, locker, lock, self.out("locker.pid")))
        self.pid_from(self.out("locker.pid"))
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertIn(os.path.realpath(lock), [os.path.realpath(p) for p in r["locks"]], r["locks"])
        self.assertIn("they keep these locks until RESUME", agent_hold.describe_hold(r))
        agent_hold.release(self.session, self.agent)

    def watchdog_of(self, r):
        wd = r.get("watchdog") or {}
        self.assertIsInstance(wd.get("pid"), int, r)
        self.pids.add(wd["pid"])
        return wd["pid"]

    def gone(self, pid):
        return not state(pid) or state(pid).startswith("Z")

    def test_catch6_a_lead_that_dies_without_session_end_never_leaves_work_frozen(self):
        lead = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        self.procs.append(lead)
        self.start_call("%s %s %s %d" % (sys.executable, self.worker, self.out("w"), ROUNDS * 20))
        worker = self.worker_pid("w")
        r = agent_hold.hold(self.session, self.agent, "fixture", session_pid=lead.pid)
        wd = self.watchdog_of(r)
        # The shells' recorded parent is this test process, so it counts as a session process too.
        rec = json.loads(Path(agent_hold._held_path(self.session, self.agent)).read_text())
        rec["parents"] = {str(lead.pid): rec["parents"][str(lead.pid)]}
        Path(agent_hold._held_path(self.session, self.agent)).write_text(json.dumps(rec))
        time.sleep(1.0)
        self.assertTrue(state(worker).startswith("T"), "held while its lead lives")
        t0 = time.monotonic()
        lead.kill()
        lead.wait()
        self.assertTrue(wait_for(lambda: not state(worker).startswith("T"), 10), "the watchdog continued it")
        took = time.monotonic() - t0
        self.assertEqual(agent_hold.records(), [])
        self.assertTrue(wait_for(lambda: self.gone(wd), 10), "the watchdog exits once it has released")
        sys.stderr.write("\n  measured: lead killed; its held work continued %.2f s later, with no hook\n" % took)

    def test_catch1_an_agent_stopped_from_the_screen_is_released_by_the_watchdog(self):
        self.start_call("%s %s %s %d" % (sys.executable, self.worker, self.out("w"), ROUNDS * 20))
        worker = self.worker_pid("w")
        r = agent_hold.hold(self.session, self.agent, "fixture-agent")
        self.watchdog_of(r)
        self.assertTrue(state(worker).startswith("T"))
        Path(self.tmp, "finished-fixture-agent").write_text("")      # the registry now says finished
        self.assertTrue(wait_for(lambda: not state(worker).startswith("T"), 15), "continued so its stop lands")
        self.assertEqual(agent_hold.records(), [])

    def test_the_watchdog_ends_with_a_normal_release(self):
        r = agent_hold.hold(self.session, self.agent, "fixture")
        wd = self.watchdog_of(r)
        self.assertFalse(self.gone(wd), "a hold has a live watchdog, even for an idle agent")
        self.assertEqual(agent_hold.hold(self.session, self.agent, "fixture")["watchdog"]["pid"], wd,
                         "a repeated hold keeps the same watchdog")
        agent_hold.release(self.session, self.agent)
        self.assertTrue(wait_for(lambda: self.gone(wd), 10))


class Wait(Base):
    """Rich's brief addition 1: a paused agent stays inside its run, in a wait that ends at RESUME."""

    def test_wait_needs_an_agents_identity(self):
        import io
        os.environ.pop(agent_hold.TAG, None)
        buf = io.StringIO()
        self.assertEqual(agent_hold.wait_resume(1, 0.05, buf), 2)
        self.assertIn("no agent identity", buf.getvalue())

    def test_wait_reports_still_paused_at_its_bound_then_resumed(self):
        import io
        os.environ[agent_hold.TAG], os.environ[agent_hold.SESSION_TAG] = self.agent, self.session
        agent_hold.hold(self.session, self.agent, "fixture")
        buf = io.StringIO()
        self.assertEqual(agent_hold.wait_resume(0.5, 0.05, buf), 0)
        self.assertIn("STILL WAITING", buf.getvalue())
        agent_hold.release(self.session, self.agent)
        buf = io.StringIO()
        agent_hold.wait_resume(0.5, 0.05, buf)
        self.assertIn("RESUMED at", buf.getvalue())

    def test_the_agents_wait_command_runs_while_held_and_returns_resumed_only_after_release(self):
        # Sage's catch A (2026-09-28): the wait command itself was self-suspended. It must run
        # (never refused, never frozen by a hold) and return RESUMED only once released.
        agent_hold.hold(self.session, self.agent, "fixture")
        call, got = self.start_rewritten("python3 %s wait" % (HERE / "agent_hold.py"), tuid="toolu_wait")
        self.assertEqual(got["input"], {"timeout": agent_hold.TOOL_MAX_TIMEOUT_MS},
                         "its call gets the tool's longest timeout, so it returns before being backgrounded")
        time.sleep(1.0)
        again = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertNotIn(str(call.pid), again["held"], "a hold never freezes the wait command")
        time.sleep(1.0)
        self.assertFalse(state(call.pid).startswith("T"), state(call.pid))
        self.assertIsNone(call.poll(), "it is still waiting")
        agent_hold.release(self.session, self.agent)
        stdout, _err = call.communicate(timeout=30)
        self.assertEqual(call.returncode, 0)
        self.assertIn("RESUMED at", stdout)

    def test_the_wait_bound_follows_the_tool_ceiling(self):
        keep = {k: os.environ.get(k) for k in ("BASH_MAX_TIMEOUT_MS", "RICHOS_AGENT_HOLD_WAIT_SECONDS")}
        try:
            for k in keep:
                os.environ.pop(k, None)
            self.assertEqual(agent_hold._wait_bound_seconds(), (600000, 585))
            os.environ["BASH_MAX_TIMEOUT_MS"] = "300000"
            self.assertEqual(agent_hold._wait_bound_seconds(), (300000, 285))
            os.environ["RICHOS_AGENT_HOLD_WAIT_SECONDS"] = "60"
            self.assertEqual(agent_hold._wait_bound_seconds(), (300000, 60))
        finally:
            for k, v in keep.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    def test_the_wait_command_text_is_the_generated_waits(self):
        import pause_protocol
        self.assertEqual(agent_hold.WAIT_COMMAND, pause_protocol.WAIT_COMMAND)
        self.assertIn(pause_protocol.WAIT_COMMAND, pause_protocol.render("manual"))
        for text in (agent_hold.WAIT_COMMAND, "python3 /x/y/agent_hold.py wait", "agent_hold.py wait 2>&1",
                     "python3 agent_hold.py wait --max-seconds 30"):
            self.assertTrue(agent_hold.is_wait_call(text), text)
        for text in ("agent_hold.py wait; rm -rf x", "echo agent_hold.py wait", "agent_hold.py hold --session s"):
            self.assertFalse(agent_hold.is_wait_call(text), text)


class Foreground(Base):
    """2026-09-28: the WAIT must reach an agent whose foreground command is running. A hold
    freezes that command's job and ends its tool call, so the queued message is handed over."""

    def test_an_unheld_wrapped_call_returns_what_it_always_returned(self):
        cases = [('echo out; echo err >&2; exit 3', 3, "out\nerr\n"),
                 ('false | cat; echo unreachable', 1, ""),
                 ('echo a\ncat <<EOF\nheredoc\nEOF\n# a trailing comment', 0, "a\nheredoc\n"),
                 ('printf "%s" "$RICHOS_AGENT_OWNER"', 0, self.agent),
                 ('exit 0', 0, "")]
        for i, (command, code, stdout) in enumerate(cases):
            call, _got = self.start_rewritten(command, tuid="toolu_plain%d" % i)
            out, _err = call.communicate(timeout=30)
            self.assertEqual((call.returncode, out), (code, stdout), command)
        d = os.path.join(os.environ["RICHOS_AGENT_HOLD_DIR"], "shells", self.session, self.agent)
        self.assertFalse([n for n in os.listdir(d) if n.endswith((".out", ".status", ".job"))],
                         "a finished call leaves no output behind")

    def test_hold_returns_the_foreground_call_at_once_and_wait_collects_the_same_result(self):
        want = expected()
        command = "\n".join([
            '%s %s %s %d' % (sys.executable, self.worker, self.out("fg"), ROUNDS),
            'echo "worker result: $(cat %s)"' % self.out("fg"),
            'exit 4',
        ])
        call, _got = self.start_rewritten(command, tuid="toolu_long")
        worker = self.worker_pid("fg")
        self.assertTrue(wait_for(lambda: os.path.exists(self.out("fg") + ".progress")))
        t0 = time.monotonic()
        r = agent_hold.hold(self.session, self.agent, "fixture", sample=1.0)
        stdout, _err = call.communicate(timeout=10)
        returned = time.monotonic() - t0
        self.assertTrue(r["ok"], r)
        self.assertEqual(list(r["detached"]), ["toolu_long"])
        self.assertEqual((call.returncode, stdout.strip()), (0, agent_hold.DETACHED_TEXT),
                         "the call returns the WAIT, so the harness hands over the queued message")
        self.assertIn(agent_hold.WAIT_COMMAND, stdout)
        self.assertLess(returned, 3.0)
        self.assertNotIn(str(call.pid), r["held"], "the foreground shell is told to return, not frozen")
        self.assertIn(str(worker), r["held"])
        self.assertTrue(state(worker).startswith("T"), state(worker))
        self.assertEqual(r["cpu_during_sample"], 0.0, r)
        progress = Path(self.out("fg") + ".progress").read_text()
        time.sleep(1.0)
        self.assertEqual(Path(self.out("fg") + ".progress").read_text(), progress, "no progress while held")
        self.assertIn("its tool call returned, so the WAIT reaches it now", agent_hold.describe_hold(r))
        # The agent now runs its wait: it waits, then collects the command's own result.
        waiter, _got = self.start_rewritten("python3 %s wait" % (HERE / "agent_hold.py"), tuid="toolu_wait")
        time.sleep(1.0)
        self.assertIsNone(waiter.poll(), "the wait waits while held")
        rel = agent_hold.release(self.session, self.agent)
        self.assertIn(worker, rel["continued"])
        out, _err = waiter.communicate(timeout=120)
        self.assertEqual(waiter.returncode, 0)
        self.assertIn("RESUMED at", out)
        self.assertIn("has finished with exit status 4", out)
        self.assertIn("worker result: %s" % want, out, "the same process finished from the same point")
        d = os.path.join(os.environ["RICHOS_AGENT_HOLD_DIR"], "shells", self.session, self.agent)
        self.assertFalse([n for n in os.listdir(d) if n.startswith("toolu_long.")], "collected output is removed")
        sys.stderr.write("\n  measured: hold ended the foreground call in %.3f s (%d process(es) frozen); "
                         "after release the wait printed its exit status and output\n" % (returned, len(r["held"])))

    def test_a_result_still_running_at_the_bound_is_collected_by_the_next_wait(self):
        command = '%s -c "import time; time.sleep(3); print(\'late result\')"' % sys.executable
        call, _got = self.start_rewritten(command, tuid="toolu_slow")
        self.assertTrue(wait_for(lambda: len(agent_hold.subtree([call.pid], agent_hold.snapshot())) > 2, 5))
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertEqual(list(r["detached"]), ["toolu_slow"])
        call.communicate(timeout=10)
        agent_hold.release(self.session, self.agent)
        import io
        os.environ[agent_hold.TAG], os.environ[agent_hold.SESSION_TAG] = self.agent, self.session
        buf = io.StringIO()
        agent_hold.wait_resume(0.5, 0.1, buf)
        self.assertIn("STILL RUNNING", buf.getvalue())
        buf = io.StringIO()
        agent_hold.wait_resume(20, 0.1, buf)
        self.assertIn("has finished with exit status 0", buf.getvalue())
        self.assertIn("late result", buf.getvalue())

    def test_a_foreground_shell_that_never_starts_its_job_is_frozen_whole_and_said_so(self):
        payload = self.payload("toolu_stuck")
        payload["tool_input"] = {"command": "true", "run_in_background": False}
        stem, _held = agent_hold._record(payload, "fg", "true")
        # Records itself like a wrapped call, then never writes its job.
        body = agent_hold._head(stem, payload) + '%s -c "import time; time.sleep(30)"' % sys.executable
        p = subprocess.Popen([SHELL, "-c", body], process_group=0)
        self.procs.append(p)
        self.assertTrue(wait_for(lambda: os.path.exists(stem + ".pid")))
        t0 = time.monotonic()
        r = agent_hold.hold(self.session, self.agent, "fixture")
        self.assertGreaterEqual(time.monotonic() - t0, agent_hold.DETACH_GRACE - 0.1)
        self.assertEqual(r["undetached"], [p.pid])
        self.assertTrue(state(p.pid).startswith("T"))
        self.assertIn("could not be told to return", agent_hold.describe_hold(r))
        agent_hold.release(self.session, self.agent)

    def test_prune_keeps_a_frozen_commands_output_until_collected(self):
        d = os.path.join(os.environ["RICHOS_AGENT_HOLD_DIR"], "shells", self.session, self.agent)
        agent_hold.capture(self.payload("toolu_kept"))
        Path(d, "toolu_kept.pid").write_text("999999 1\n")
        Path(d, "toolu_kept.out").write_text("output")
        Path(d, "toolu_kept.detached").write_text(json.dumps({"job": 999999, "at": time.time()}))
        old = time.time() - 3600
        os.utime(os.path.join(d, "toolu_kept.json"), (old, old))
        agent_hold.capture(self.payload("toolu_next"))
        self.assertIn("toolu_kept.out", os.listdir(d), "kept for the agent's wait")
        old = time.time() - agent_hold.DETACHED_KEEP - 60
        os.utime(os.path.join(d, "toolu_kept.json"), (old, old))
        agent_hold.capture(self.payload("toolu_last"))
        self.assertFalse([n for n in os.listdir(d) if n.startswith("toolu_kept.")], "gone after DETACHED_KEEP")


if __name__ == "__main__":
    unittest.main(verbosity=2)
