#!/usr/bin/env python3
"""Real OS process tests with a fictional provider, never the user's sessions."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SUPERVISOR=Path(__file__).resolve().parents[1]/"provider-supervisor.py"
def alive(pid):
    result=subprocess.run(["/bin/ps","-o","stat=","-p",str(pid)],text=True,capture_output=True)
    return result.returncode==0 and bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")

class Supervisor(unittest.TestCase):
    def test_parent_crash_stops_owned_provider_and_child_but_preserves_unrelated_process(self):
        with tempfile.TemporaryDirectory(prefix="supervisor fixture ") as root:
            root=Path(root); receipt=root/"pids.json"
            fake=root/"provider.py"
            fake.write_text("import subprocess,os,json,time,sys\nchild=subprocess.Popen(['/bin/sleep','120'])\nopen(sys.argv[1],'w').write(json.dumps([os.getpid(),child.pid,os.environ['RICHOS_SESSION_PID']]))\ntime.sleep(120)\n")
            launcher=root/"desktop.py"
            launcher.write_text("import subprocess,sys,time\nsubprocess.Popen(sys.argv[1:],start_new_session=True)\ntime.sleep(120)\n")
            unrelated=subprocess.Popen(["/bin/sleep","120"])
            desktop=subprocess.Popen([sys.executable,str(launcher),sys.executable,str(SUPERVISOR),sys.executable,str(fake),str(receipt)])
            try:
                for _ in range(100):
                    if receipt.exists():break
                    time.sleep(.05)
                provider,child,identity=json.loads(receipt.read_text())
                self.assertEqual(str(provider),identity)
                self.assertTrue(alive(provider));self.assertTrue(alive(child))
                desktop.kill();desktop.wait()
                for _ in range(100):
                    if not alive(provider) and not alive(child):break
                    time.sleep(.05)
                self.assertFalse(alive(provider));self.assertFalse(alive(child))
                self.assertIsNone(unrelated.poll())
            finally:
                if desktop.poll() is None:desktop.kill();desktop.wait()
                unrelated.kill();unrelated.wait()

PROVIDER_WITH_TOOL_SHELL = r'''
import json, os, subprocess, sys, time
receipt, beat = sys.argv[1], sys.argv[2]
# A tool shell the way Claude Code starts one: its own session and process group,
# no controlling terminal. It starts a background heartbeat and a grandchild.
shell = subprocess.Popen(["/bin/sh", "-c",
    "(while :; do date +%s > '" + beat + "'; sleep 0.2; done) & sleep 300 & wait"], start_new_session=True)
# A same-group child, the way sourcekit-lsp or caffeinate sit in the lead's group.
same = subprocess.Popen(["/bin/sleep", "300"])
time.sleep(0.6)
open(receipt, "w").write(json.dumps({"provider": os.getpid(), "shell": shell.pid, "same": same.pid}))
if len(sys.argv) > 3 and sys.argv[3] == "exit-soon":
    time.sleep(1.5)
    os._exit(0)
time.sleep(300)
'''


def beating(path, window=0.7):
    try:
        return time.time() - os.path.getmtime(path) < window
    except OSError:
        return False


def group_members(pgid):
    r = subprocess.run(["/bin/ps", "-A", "-o", "pid=,pgid=,stat="], text=True, capture_output=True)
    return [int(p) for p, g, s in (l.split()[:3] for l in r.stdout.splitlines() if len(l.split()) >= 3)
            if int(g) == pgid and not s.startswith("Z")]


class ReapDescendants(unittest.TestCase):
    """Spec r3 (q) item 2 (F5), Frank G8 and G9; the P15 shape, in-process."""

    def run_case(self, trigger, reap=True, provider_arg=None):
        with tempfile.TemporaryDirectory(prefix="supervisor reap ") as root:
            root = Path(root)
            receipt, beat, state = root/"pids.json", root/"beat", root/"state.json"
            fake = root/"provider.py"; fake.write_text(PROVIDER_WITH_TOOL_SHELL)
            launcher = root/"desktop.py"
            launcher.write_text("import subprocess,sys,time\np=subprocess.Popen(sys.argv[2:],start_new_session=True)\n"
                                "open(sys.argv[1],'w').write(str(p.pid))\ntime.sleep(120)\n")
            unrelated = subprocess.Popen(["/bin/sleep", "120"])
            args = [sys.executable, str(SUPERVISOR)] + (["--reap-descendants"] if reap else []) + \
                   [sys.executable, str(fake), str(receipt), str(beat)] + ([provider_arg] if provider_arg else [])
            env = dict(os.environ, OPERATOR_REAP_GRACE="1", RICHOS_OPERATOR_REAP_STATE=str(state),
                       RICHOS_OPERATOR_REAP_LOG=str(root/"reap.log"))
            desktop = subprocess.Popen([sys.executable, str(launcher), str(root/"sup.pid")] + args, env=env)
            shell_group = None
            try:
                for _ in range(100):
                    if receipt.exists() and (root/"sup.pid").exists():
                        break
                    time.sleep(0.05)
                pids = json.loads(receipt.read_text()); sup = int((root/"sup.pid").read_text())
                shell_group = pids["shell"]
                time.sleep(1.4)                      # at least one in-process snapshot
                self.assertTrue(beating(beat), "fixture: the heartbeat never started")
                snapshot = json.loads(state.read_text()) if state.exists() else {}
                if trigger == "owner":
                    desktop.kill(); desktop.wait()
                elif trigger == "sigterm":
                    os.kill(sup, signal.SIGTERM)
                elif trigger == "provider-killed":
                    os.kill(pids["provider"], signal.SIGKILL)     # G9: the provider crashes
                elif trigger == "provider-exits":
                    pass                                          # it exits by itself (exit-soon)
                t0 = time.time()
                while time.time() - t0 < 4 and beating(beat):
                    time.sleep(0.1)
                stopped_after = time.time() - t0
                return {"pids": pids, "beating": beating(beat), "stopped_after": stopped_after,
                        "left": group_members(shell_group), "snapshot": snapshot,
                        "unrelated_alive": unrelated.poll() is None,
                        "log": (root/"reap.log").read_text() if (root/"reap.log").exists() else ""}
            finally:
                if desktop.poll() is None:
                    desktop.kill(); desktop.wait()
                unrelated.kill(); unrelated.wait()
                if shell_group:
                    try:
                        os.killpg(shell_group, signal.SIGKILL)   # the fixture's own group, captured at spawn
                    except (ProcessLookupError, PermissionError):
                        pass

    def assert_reaped(self, result):
        self.assertFalse(result["beating"], "the tool shell's heartbeat outlived the lead")
        self.assertLessEqual(result["stopped_after"], 1 + 1 + 0.5, "not within OPERATOR_REAP_GRACE plus one second")
        self.assertEqual(result["left"], [], "members of the tool shell's group survived")
        self.assertTrue(result["unrelated_alive"], "an unrelated process was touched")
        self.assertIn("killed group %d" % result["pids"]["shell"], result["log"])

    def test_R1_owner_death_reaps_the_tool_shell_group(self):
        self.assert_reaped(self.run_case("owner"))

    def test_R2_sigterm_from_the_host_reaps_the_tool_shell_group(self):
        self.assert_reaped(self.run_case("sigterm"))

    def test_R3_G9_a_crashed_provider_is_reaped_from_the_last_snapshot(self):
        self.assert_reaped(self.run_case("provider-killed"))

    def test_R4_G9_a_provider_that_exits_by_itself_is_reaped_too(self):
        self.assert_reaped(self.run_case("provider-exits", provider_arg="exit-soon"))

    def test_R5_control_without_the_flag_the_tool_shell_survives_its_lead(self):
        result = self.run_case("owner", reap=False)
        self.assertTrue(result["beating"] or result["left"],
                        "control: without --reap-descendants the tool shell should outlive the lead (F5)")

    def test_R6_G8_idle_state_counts_only_descendants_outside_the_lead_group(self):
        result = self.run_case("owner")
        outside = result["snapshot"].get("outside_provider_group") or []
        self.assertIn(result["pids"]["shell"], outside, "the tool shell (own group) must count")
        self.assertNotIn(result["pids"]["same"], outside, "a same-group child (language server) must not count")

    def test_R7_a_recycled_group_id_is_never_adopted_or_signaled(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("provider_supervisor", str(SUPERVISOR))
        mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
        rec = mod.Record(provider=100, own_group=100)
        rec.procs = {200: (5000, 200), 201: (5001, 200)}; rec.groups = {200: 5000}
        recycled = {100: (1, 100, 4000), 200: (1, 200, 9999), 300: (1, 200, 9999)}   # pid 200 reused, new members
        self.assertEqual(rec.live_groups(recycled), set(), "a recycled group leader with no live recorded member")
        rec.snapshot(recycled)
        self.assertNotIn(300, rec.procs, "a process in a recycled group was adopted")
        still = {100: (1, 100, 4000), 201: (1, 200, 5001)}                             # a real member lives on
        self.assertEqual(rec.live_groups(still), {200})

    def test_R8_N1_the_product_invocation_is_unchanged(self):
        source = SUPERVISOR.read_text().splitlines()
        self.assertTrue(any(l.startswith("def main():") for l in source[:20]))
        main_body = "\n".join(source[source.index("def main():"):source.index("def main():") + 26])
        self.assertNotIn("reap", main_body, "the product main() must not know about reaping")


if __name__=="__main__":unittest.main()
