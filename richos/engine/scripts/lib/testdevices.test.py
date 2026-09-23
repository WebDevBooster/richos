#!/usr/bin/env python3
"""testdevices.test.py — the test-device collector, TESTED BY DEFEAT.

Run by testdevices.test.sh, which allocates the sandbox. Every simulator here
is a row in a FAKE simctl's state file and every emulator is a real process
whose arguments name an AVD; the machine's own simulators are never listed
(T11 proves the module refuses to, from a sandboxed HOME). Each removal case is
paired with the case that must NOT remove, because a collector is judged as
much on what it leaves as on what it takes.
"""
import importlib.util
import json
import os
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SANDBOX = os.environ["TESTDEVICES_SANDBOX"]

spec = importlib.util.spec_from_file_location("testdevices", os.path.join(HERE, "testdevices.py"))
T = importlib.util.module_from_spec(spec)
spec.loader.exec_module(T)

FAKE_SIMCTL = r'''#!/usr/bin/env python3
import json, os, sys
state = os.environ["FAKE_SIMCTL_STATE"]
d = json.load(open(state))
with open(state + ".log", "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
a = sys.argv[1:]
if a[:2] == ["list", "devices"]:
    print(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-6": d["devices"]}}))
    sys.exit(0)
udid = a[1] if len(a) > 1 else ""
dev = [x for x in d["devices"] if x["udid"] == udid]
if not dev:
    sys.stderr.write("Invalid device: %s\n" % udid); sys.exit(148)
if a[0] == "shutdown":
    dev[0]["state"] = "Shutdown"
elif a[0] == "delete":
    if udid in d.get("undeletable", []):
        sys.stderr.write("Unable to delete: busy\n"); sys.exit(1)
    d["devices"] = [x for x in d["devices"] if x["udid"] != udid]
json.dump(d, open(state, "w"))
'''


class Base(unittest.TestCase):
    n = 0

    def setUp(self):
        Base.n += 1
        self.root = os.path.join(SANDBOX, "case-%02d" % Base.n)
        self.home = os.path.join(self.root, "home")
        self.claude = os.path.join(self.root, "claude")
        self.devdir = os.path.join(self.root, "devices")
        self.android = os.path.join(self.root, "android")
        for d in (self.home, self.claude, self.devdir, self.android):
            os.makedirs(d)
        self.simctl = os.path.join(self.root, "simctl")
        with open(self.simctl, "w") as f:
            f.write(FAKE_SIMCTL)
        os.chmod(self.simctl, 0o755)
        self.state = os.path.join(self.root, "simctl.json")
        self.write_state([])
        self.saved = dict(os.environ)
        os.environ.update({
            "HOME": self.home, "CLAUDE_CONFIG_DIR": self.claude,
            "RICHOS_WORKSPACES_DIR": os.path.join(self.claude, "state", "workspaces"),
            "RICHOS_SIMCTL": self.simctl, "FAKE_SIMCTL_STATE": self.state,
            "RICHOS_SIM_DEVICES_DIR": self.devdir, "RICHOS_ANDROID_CACHES_ROOT": self.android,
        })
        os.environ.pop("RICHOS_TEST_DEVICES_DIR", None)
        os.environ.pop("TEST_DEVICE_FAILURES_STATE", None)
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            try:
                p.kill()
                p.wait()
            except OSError:
                pass
        os.environ.clear()
        os.environ.update(self.saved)

    # --- fixtures -----------------------------------------------------------
    def write_state(self, devices, undeletable=()):
        with open(self.state, "w") as f:
            json.dump({"devices": devices, "undeletable": list(undeletable)}, f)

    def devices(self):
        return json.load(open(self.state))["devices"]

    def calls(self):
        try:
            return open(self.state + ".log").read().splitlines()
        except OSError:
            return []

    def device(self, name, state="Booted", udid=None):
        udid = udid or "%08X-0000-4000-8000-%012X" % (Base.n, len(self.devices()) + 1)
        os.makedirs(os.path.join(self.devdir, udid))
        self.write_state(self.devices() + [{"udid": udid, "name": name, "state": state}],
                         json.load(open(self.state)).get("undeletable", []))
        return udid

    def proc(self, *args):
        p = subprocess.Popen(list(args) or ["sleep", "600"])
        self.procs.append(p)
        time.sleep(0.1)
        return p

    def dead_pid(self):
        p = self.proc()
        p.kill()
        p.wait()
        return p.pid

    def record_checkout(self, path):
        d = os.path.join(os.environ["RICHOS_WORKSPACES_DIR"], "done")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "agent-%d.json" % Base.n), "w") as f:
            json.dump({"key": "k", "workspaces": [{"path": path, "repo": "/nonexistent-repo"}]}, f)

    def rows(self):
        return T.read_failures()

    def ids(self, res, key):
        return sorted(d["id"] for d in res[key])


class Collector(Base):

    def test_T01_a_simulator_whose_creator_pid_is_gone_is_shut_down_and_deleted(self):
        u = self.device("rios-ui-%d-iPhone-SE" % self.dead_pid())
        res = T.collect(apply=True)
        self.assertEqual(self.ids(res, "collected"), [u])
        self.assertEqual(self.devices(), [])
        self.assertIn("shutdown %s" % u, self.calls())
        self.assertIn("delete %s" % u, self.calls())
        self.assertEqual(self.rows(), {})

    def test_T02_its_live_creator_keeps_it(self):
        p = self.proc()
        time.sleep(1.2)                                   # the device is made AFTER its creator started
        u = self.device("rios-ui-%d-iPhone-SE" % p.pid)
        res = T.collect(apply=True)
        self.assertEqual(self.ids(res, "left"), [u])
        self.assertEqual(len(self.devices()), 1)
        self.assertFalse([c for c in self.calls() if not c.startswith("list")])

    def test_T03_a_reused_pid_is_not_its_creator(self):
        u = self.device("rios-ui-99999-iPhone-SE")
        time.sleep(2.2)
        p = self.proc()                                   # started after the device existed
        self.write_state([{"udid": u, "name": "rios-ui-%d-iPhone-SE" % p.pid, "state": "Booted"}])
        res = T.collect(apply=True)
        self.assertEqual(self.ids(res, "collected"), [u])
        self.assertIn("reused", res["collected"][0]["why"])

    def test_T04_a_registered_cache_is_kept_while_its_owner_runs_and_collected_after(self):
        cache = os.path.join(self.root, "caches", "60e53bf487-app")
        os.makedirs(cache)
        owner = self.proc()
        T.register("ios-cache", cache, owner.pid, "native-ios-app.test.sh")
        u = self.device("RichOS native-ios 60e53bf487-app")
        self.assertEqual(self.ids(T.collect(apply=True), "left"), [u])
        owner.kill()
        owner.wait()
        res = T.collect(apply=True)
        self.assertEqual(self.ids(res, "collected"), [u])
        self.assertIn("native-ios-app.test.sh", res["collected"][0]["why"])
        self.assertEqual(T.records(), [])                 # nothing left to say: pruned

    def test_T05_a_registered_simulator_goes_with_its_owner_and_an_unregistered_one_is_alerted(self):
        reg = self.device("RichOS native-ios platform-tests simulator")
        T.register("ios-simulator", reg, self.proc().pid, "simulator-tests.sh")
        for p in self.procs:
            p.kill()
            p.wait()
        stray = self.device("RichOS native-ios platform-tests simulator")
        res = T.collect(apply=True)
        self.assertEqual(self.ids(res, "collected"), [reg])
        self.assertEqual(self.ids(res, "undecided"), [stray])
        self.assertEqual([d["udid"] for d in self.devices()], [stray])     # never deleted on a guess
        row = self.rows()["ios:" + stray]
        self.assertEqual(row["verdict"], "owner cannot be proven")
        self.assertIn("xcrun simctl delete %s" % stray, row["command"])

    def test_T06_a_per_checkout_device_follows_its_recorded_checkout(self):
        co = os.path.join(self.root, "richos-wt", "isaac-opus-n1")
        os.makedirs(co)
        self.record_checkout(co)
        key = T.checkout_keys(co)["rios"]
        u = self.device("RichOS native-ios %s" % key)
        self.assertEqual(self.ids(T.collect(apply=True), "left"), [u])
        os.rmdir(co)
        res = T.collect(apply=True)
        self.assertEqual(self.ids(res, "collected"), [u])
        self.assertIn("no longer exists", res["collected"][0]["why"])

    def test_T06b_an_unknown_checkout_is_undecided_and_alerted_only_while_it_runs(self):
        off = self.device("RichOS mobile loop 0052f60ff2", state="Shutdown")
        on = self.device("RichOS mobile loop 38180311e9", state="Booted")
        res = T.collect(apply=True)
        self.assertEqual(self.ids(res, "undecided"), sorted([off, on]))
        self.assertEqual(len(self.devices()), 2)
        self.assertEqual(sorted(self.rows()), ["ios:" + on])

    def test_T07_a_land_deleting_the_checkout_takes_its_devices(self):
        co = os.path.join(self.root, "richos-wt", "andy-opus-a2")
        os.makedirs(co)
        self.record_checkout(co)
        u = self.device("RichOS mobile loop %s" % T.checkout_keys(co)["loop"], state="Shutdown")
        self.assertEqual(self.ids(T.collect(apply=True), "left"), [u])
        res = T.collect(apply=True, departing=[co])
        self.assertEqual(self.ids(res, "collected"), [u])
        self.assertTrue(os.path.isdir(co))               # the land deletes it, not this

    def test_T08_a_device_that_will_not_go_is_alerted_until_it_is_gone(self):
        u = self.device("rios-ui-%d-iPhone-SE" % self.dead_pid())
        st = json.load(open(self.state))
        self.write_state(st["devices"], undeletable=[u])
        res = T.collect(apply=True)
        self.assertEqual(self.ids(res, "survivors"), [u])
        self.assertEqual(self.rows()["ios:" + u]["verdict"], "would not close")
        T.collect(apply=True)
        self.assertEqual(self.rows()["ios:" + u]["attempts"], 2)
        self.write_state([])                              # Rich deleted it by hand
        T.collect(apply=True)
        self.assertEqual(self.rows(), {})
        self.assertFalse(os.path.exists(T.failures_path()))

    def test_T09_a_device_outside_our_families_is_never_touched(self):
        self.device("iPhone 16 Pro", state="Booted")
        self.device("RichOS native-ios notahexkey")
        res = T.collect(apply=True)
        self.assertEqual(sum(len(res[k]) for k in ("collected", "left", "undecided", "survivors")), 0)
        self.assertFalse([c for c in self.calls() if not c.startswith("list")])

    def test_T10_an_orphaned_emulator_is_ended_by_its_recorded_pid_and_its_avd_removed(self):
        cache = os.path.join(self.android, "1a2b3c4d5e")
        os.makedirs(os.path.join(cache, "avd", "randroid-1a2b3c4d5e.avd"))
        emu = self.proc(sys.executable, "-c", "import time; time.sleep(600)",
                        "-avd", "randroid-1a2b3c4d5e", "-no-window")
        with open(os.path.join(cache, "emulator.json"), "w") as f:
            json.dump({"serial": "emulator-5580", "pid": emu.pid, "avd": "randroid-1a2b3c4d5e"}, f)
        owner = self.proc()
        T.register("android-cache", cache, owner.pid, "native-android-app.test.sh")
        self.assertEqual(self.ids(T.collect(apply=True), "left"), [emu.pid])
        owner.kill()
        owner.wait()
        res = T.collect(apply=True)
        self.assertEqual(self.ids(res, "collected"), [emu.pid])
        emu.wait(timeout=10)
        self.assertIsNotNone(emu.returncode)
        self.assertFalse(os.path.exists(os.path.join(cache, "avd")))
        self.assertFalse(os.path.exists(os.path.join(cache, "emulator.json")))

    def test_T10b_a_recorded_pid_that_is_no_longer_the_emulator_is_never_signaled(self):
        cache = os.path.join(self.android, "9f8e7d6c5b")
        os.makedirs(os.path.join(cache, "avd"))
        bystander = self.proc()                          # some other process now holds the number
        with open(os.path.join(cache, "emulator.json"), "w") as f:
            json.dump({"serial": "emulator-5582", "pid": bystander.pid, "avd": "randroid-9f8e7d6c5b"}, f)
        owner = self.proc()
        T.register("android-cache", cache, owner.pid, "native-android-app.test.sh")
        owner.kill()
        owner.wait()
        res = T.collect(apply=True)
        self.assertEqual(res["collected"] + res["survivors"], [])
        self.assertIsNone(bystander.poll())
        self.assertTrue(os.path.isdir(os.path.join(cache, "avd")))

    def test_T11_a_sandboxed_home_never_reads_the_machines_simulators(self):
        os.environ.pop("RICHOS_SIMCTL")
        os.environ.pop("RICHOS_ANDROID_CACHES_ROOT")
        self.assertFalse(T.machine_devices_allowed())
        self.assertEqual(T.ios_devices(), [])
        self.assertEqual(T.android_caches_root(), "")

    def test_T12_a_dry_run_removes_nothing(self):
        u = self.device("rios-ui-%d-iPhone-SE" % self.dead_pid())
        res = T.collect(apply=False)
        self.assertEqual(self.ids(res, "collected"), [u])
        self.assertEqual(len(self.devices()), 1)
        self.assertFalse(os.path.exists(T.failures_path()))

    def test_T13_the_registration_cli_records_the_calling_shell(self):
        owner = self.proc()
        cache = os.path.join(self.root, "c", "abcdef0123-app")
        os.makedirs(cache)
        r = subprocess.run([sys.executable, os.path.join(HERE, "testdevices.py"), "register", "--kind",
                            "ios-cache", "--id", cache, "--owner-pid", str(owner.pid), "--script", "x.sh"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = T.records()[0]
        self.assertEqual(rec["owner"]["pid"], owner.pid)
        self.assertEqual(rec["owner"]["start"], T.process_start(owner.pid))
        r = subprocess.run([sys.executable, os.path.join(HERE, "testdevices.py"), "register", "--kind",
                            "ios-cache", "--id", cache, "--owner-pid", str(self.dead_pid())],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)                 # a dead owner proves nothing


class _Result(unittest.TextTestResult):
    def addSuccess(self, test):
        super().addSuccess(test)
        self.stream.write("  PASS  %s\n" % test._testMethodName)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.stream.write("  FAIL  %s\n" % test._testMethodName)

    def addError(self, test, err):
        super().addError(test, err)
        self.stream.write("  FAIL  %s (error)\n" % test._testMethodName)


if __name__ == "__main__":
    runner = unittest.TextTestRunner(stream=sys.stdout, verbosity=0, resultclass=_Result)
    names = [a for a in sys.argv[1:] if a]
    loader = unittest.defaultTestLoader
    suite = (loader.loadTestsFromNames(names, sys.modules[__name__]) if names
             else loader.loadTestsFromModule(sys.modules[__name__]))
    result = runner.run(suite)
    print("=== testdevices tests: %d run, %d failed ===" % (
        result.testsRun, len(result.failures) + len(result.errors)))
    sys.exit(0 if result.wasSuccessful() else 1)
