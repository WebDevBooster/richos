#!/usr/bin/env python3
"""phone-speed-watch.test.py — the phone speed check that runs by itself after a mobile land
(richos/mobile/perf/watch.py) and the guard in front of the phones (phone_guard.py).

Fake phones, a fake land: a throwaway Git repository stands for richos, a stand-in adb and xcrun
list one Android phone and one wired iPhone, stand-in `randroid`/`rios` command lines answer the
`device install` and `device perf` verbs, a stand-in perf.py answers `compare`, and escalations go
to a scratch file. No phone, emulator, simulator, build or window; nothing touches this repository.

  W1-W3   the trigger: a land touching richos/mobile/ starts a runner, one that does not starts
          nothing, and a clone that is not the operator's checkout never does
  W4      a missed run (requested, never finished, no runner alive) is escalated once and retried
  W5-W8   the run: a good result is recorded; a slower one raises an escalation naming the range
          since the last good run; a verb that does not exist yet and a verb that tries to
          uninstall are reported (COULD NOT MEASURE, REFUSED) and nothing reaches the phone
  W9-W10  a busy phone: the run waits and never interrupts the user; still busy at the bound, it
          reports and leaves the user running
  W11     a phone whose app cannot have changed is not measured again
  W12     the land through git itself: autocheck's post-merge hook starts the run
  G1-G3   the guard: uninstall, pm clear and install without -r are refused and stop the run;
          install -r and reads pass; xcrun devicectl uninstall is refused
  B1      the busy test: another process naming the phone is busy, this run's own tree is not,
          the adb server is not
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
PERF = HERE.parents[1] / "mobile/perf"
WATCH = PERF / "watch.py"
GUARD = PERF / "phone_guard.py"
AUTOCHECK = HERE / "autocheck"
SERIAL = "FAKESERIAL0042"
UDID = "00008030-FAKEUDID0042"
IDENT = "AAAAAAAA-BBBB-CCCC-DDDD-FAKEIDENT042"

sys.path.insert(0, str(PERF))
import watch  # noqa: E402

FAKE_ADB = f"""#!/usr/bin/env python3
import os, sys
open(os.environ["FAKE_LOG"], "a").write("real-adb " + " ".join(sys.argv[1:]) + "\\n")
if sys.argv[1:] == ["devices"]:
    print("List of devices attached")
    if os.environ.get("FAKE_NO_ANDROID") != "1":
        print("{SERIAL}\\tdevice")
"""
FAKE_XCRUN = f"""#!/usr/bin/env python3
import json, os, sys
open(os.environ["FAKE_LOG"], "a").write("real-xcrun " + " ".join(sys.argv[1:]) + "\\n")
if sys.argv[1:4] == ["devicectl", "list", "devices"]:
    out = sys.argv[sys.argv.index("--json-output") + 1]
    json.dump({{"result": {{"devices": [{{"identifier": "{IDENT}", "connectionProperties": {{"transportType": "wired"}},
        "hardwareProperties": {{"udid": "{UDID}", "reality": "physical", "deviceType": "iPhone"}}}}]}}}}, open(out, "w"))
"""
# randroid / rios stand-in: `<platform> device install|perf --serial|--device ID ...`.
FAKE_CLI = """#!/usr/bin/env python3
import json, os, subprocess, sys
platform, args = sys.argv[1], sys.argv[2:]
open(os.environ["FAKE_LOG"], "a").write(f"cli-{platform} " + " ".join(args) + "\\n")
mode = os.environ.get("FAKE_MODE_" + platform.upper(), "good")
if mode == "noverb":
    print("{\\"ok\\": false, \\"error\\": \\"unknown mode 'device'; see randroid --help\\"}", file=sys.stderr)
    sys.exit(1)
if mode == "uninstall" and args[:2] == ["device", "install"]:
    # A tool that ignores a failed uninstall and goes on to install: both must be stopped.
    subprocess.run(["adb", "uninstall", "dev.richos.connect"])
    subprocess.run(["adb", "install", "twin.apk"])
    sys.exit(1)
if args[:2] == ["device", "perf"]:
    out = args[args.index("--out") + 1]
    json.dump({"fake": mode}, open(out, "w"))
"""
FAKE_PERF = """#!/usr/bin/env python3
import json, sys
assert sys.argv[1:3] == ["compare", "--json"], sys.argv
verdict = json.load(open(sys.argv[3]))["fake"]
status = {"good": "WITHIN NOISE", "slower": "SLOWER"}.get(verdict, "NOT COMPARED")
p95 = {"good": 900, "slower": 1400}.get(verdict)
print(json.dumps({"verdict": {"good": "NOT SLOWER", "slower": "SLOWER THAN THE ESTABLISHED BENCHMARK"}.get(verdict, "NOT COMPARED"),
                  "metrics": {m: {"status": status, "p95Ms": p95, "limitMs": 1000, "why": "fixture"} for m in ("coldLaunch", "warmResume")}}))
sys.exit({"good": 0, "slower": 4}.get(verdict, 5))
"""
FAKE_ESCALATE = """#!/usr/bin/env python3
import json, os, sys
fields = json.load(open(sys.argv[sys.argv.index("--fields") + 1]))
open(os.environ["FAKE_ESCALATIONS"], "a").write(json.dumps(fields) + "\\n")
"""
FAKE_RUNNER = """#!/usr/bin/env python3
import os, sys
open(os.environ["FAKE_RUNNER_LOG"], "a").write(" ".join(sys.argv[1:]) + "\\n")
"""


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="phone-watch-")
        self.base = Path(self.tmp.name).resolve()
        self.repo = self.base / "repo"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        for name, text in (("adb", FAKE_ADB), ("xcrun", FAKE_XCRUN), ("cli.py", FAKE_CLI), ("perf.py", FAKE_PERF),
                           ("escalate.py", FAKE_ESCALATE), ("runner.py", FAKE_RUNNER)):
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)
        (self.base / "gitconfig").write_text("[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n"
                                              "[init]\n\tdefaultBranch = main\n")
        self.log = self.base / "tools.log"
        self.escalations = self.base / "escalations.jsonl"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GIT_", "RICHOS_PHONE_WATCH", "RICHOS_AUTOCHECK", "FAKE_"))}
        self.env.update(
            GIT_CONFIG_GLOBAL=str(self.base / "gitconfig"), GIT_CONFIG_NOSYSTEM="1",
            FAKE_LOG=str(self.log), FAKE_ESCALATIONS=str(self.escalations),
            FAKE_RUNNER_LOG=str(self.base / "runner.log"),
            RICHOS_PHONE_WATCH_HOME=str(self.base / "home"), RICHOS_PHONE_WATCH_REPO=str(self.repo),
            RICHOS_PHONE_WATCH_ESCALATE=f"{sys.executable} {self.bin / 'escalate.py'}",
            RICHOS_PHONE_WATCH_ADB=str(self.bin / "adb"), RICHOS_PHONE_WATCH_XCRUN=str(self.bin / "xcrun"),
            RICHOS_PHONE_WATCH_ANDROID_CLI=f"{sys.executable} {self.bin / 'cli.py'} android",
            RICHOS_PHONE_WATCH_IOS_CLI=f"{sys.executable} {self.bin / 'cli.py'} ios",
            RICHOS_PHONE_WATCH_PERF=str(self.bin / "perf.py"),
            RICHOS_PHONE_WATCH_QUIET_S="0", RICHOS_PHONE_WATCH_POLL_S="0", RICHOS_PHONE_WATCH_TRIALS="3",
            # Only processes naming the made-up phones count: the real phones on this Mac may be in use.
            RICHOS_PHONE_WATCH_MARKERS="ident", RICHOS_PHONE_WATCH_MAX_WAIT_S="60",
            RICHOS_APPLE_TEAM="FAKETEAM42")
        self.repo.mkdir()
        self.git("init", "-q")
        self.write("richos/app/src/thing.txt", "fine\n")
        self.write("richos/mobile/native-android/App.kt", "fast\n")
        self.write("richos/mobile/native-ios/App.swift", "fast\n")
        self.commit("base")

    def tearDown(self):
        self.tmp.cleanup()

    def run_(self, argv, env=None, cwd=None, timeout=120):
        return subprocess.run(argv, cwd=cwd or self.repo, env=env or self.env, capture_output=True, text=True,
                              timeout=timeout)

    def git(self, *args):
        p = self.run_(["git", *args])
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def write(self, rel, text):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def watch(self, *args, env=None):
        return self.run_([sys.executable, str(WATCH), *args], env=env)

    def ledger(self):
        path = self.base / "home/ledger.jsonl"
        return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []

    def escalated(self):
        return [json.loads(l) for l in self.escalations.read_text().splitlines()] if self.escalations.exists() else []

    def tools(self):
        return self.log.read_text() if self.log.exists() else ""

    def request(self, main=None):
        """A request in the ledger, as the trigger writes it."""
        main = main or self.git("rev-parse", "HEAD")
        (self.base / "home").mkdir(exist_ok=True)
        with open(self.base / "home/ledger.jsonl", "a") as f:
            f.write(json.dumps({"at": watch.now(), "event": "requested", "id": f"r{time.time_ns()}", "main": main}) + "\n")

    def run_round(self, env=None):
        p = self.watch("run", "--repo", str(self.repo), env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        return [r for r in self.ledger() if r["event"] == "outcome"]


class Trigger(Base):
    def setUp(self):
        super().setUp()
        self.env["RICHOS_PHONE_WATCH_RUNNER"] = f"{sys.executable} {self.bin / 'runner.py'}"

    def runner_calls(self):
        path = self.base / "runner.log"
        for _ in range(50):  # the runner is detached; give it a moment to write its line
            if path.exists():
                return path.read_text().splitlines()
            time.sleep(0.1)
        return []

    def test_W1_a_land_touching_mobile_starts_a_run(self):
        old = self.git("rev-parse", "HEAD")
        self.write("richos/mobile/native-android/App.kt", "slower?\n")
        new = self.commit("android change")
        p = self.watch("trigger", "--repo", str(self.repo), "--from", old, "--to", new)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("phone run requested", p.stderr)
        requests = [r for r in self.ledger() if r["event"] == "requested"]
        self.assertEqual([r["main"] for r in requests], [new])
        self.assertEqual(self.runner_calls(), [f"run --repo {self.repo}"])

    def test_W2_a_land_not_touching_mobile_starts_nothing(self):
        old = self.git("rev-parse", "HEAD")
        self.write("richos/app/src/thing.txt", "other\n")
        new = self.commit("app change")
        p = self.watch("trigger", "--repo", str(self.repo), "--from", old, "--to", new)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("changes nothing under richos/mobile/", p.stderr)
        # The trigger writes `spawned` before it returns whenever it starts a runner: none was written.
        self.assertEqual(self.ledger(), [])
        self.assertFalse((self.base / "runner.log").exists())

    def test_W3_a_clone_that_is_not_the_operator_checkout_never_reaches_a_phone(self):
        old = self.git("rev-parse", "HEAD")
        self.write("richos/mobile/native-ios/App.swift", "slower?\n")
        new = self.commit("ios change")
        env = dict(self.env, RICHOS_PHONE_WATCH_REPO=str(self.base / "elsewhere"))
        p = self.watch("trigger", "--repo", str(self.repo), "--from", old, "--to", new, env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("not the operator's main checkout", p.stderr)
        self.assertEqual(self.ledger(), [])

    def test_W4_a_missed_run_is_escalated_once_and_retried(self):
        head = self.git("rev-parse", "HEAD")
        (self.base / "home").mkdir()
        stale = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600))
        (self.base / "home/ledger.jsonl").write_text(json.dumps(
            {"at": stale, "event": "requested", "id": "lost1", "main": head}) + "\n")
        self.write("richos/app/src/thing.txt", "other\n")
        new = self.commit("app change, not mobile")
        p = self.watch("trigger", "--repo", str(self.repo), "--from", head, "--to", new)
        self.assertEqual(p.returncode, 0, p.stderr)
        titles = [e["title"] for e in self.escalated()]
        self.assertEqual(len(titles), 1, titles)
        self.assertIn("MISSED", titles[0])
        self.assertEqual(self.runner_calls(), [f"run --repo {self.repo}"], "the missed request is retried")
        self.watch("trigger", "--repo", str(self.repo), "--from", head, "--to", new)
        self.assertEqual(len(self.escalated()), 1, "reported once, not at every land")


class Run(Base):
    def test_W5_a_good_run_is_recorded_and_raises_nothing(self):
        head = self.git("rev-parse", "HEAD")
        self.request()
        outcomes = self.run_round()
        self.assertEqual(sorted((o["platform"], o["verdict"]) for o in outcomes), [("android", "good"), ("ios", "good")])
        self.assertEqual(self.escalated(), [])
        good = json.loads((self.base / "home/good.json").read_text())
        self.assertEqual(good["android"]["commit"], head)
        self.assertEqual(good["ios"]["commit"], head)
        calls = self.tools()
        self.assertIn(f"cli-android device install --serial {SERIAL} --expect-commit {head}", calls)
        self.assertIn(f"cli-ios device perf --device {IDENT} --expect-commit {head} --cold 3 --warm 3", calls)
        self.assertNotIn("real-adb install", calls, "the phone is reached only through the platform verbs")
        finished = [r for r in self.ledger() if r["event"] == "finished"]
        self.assertEqual(len(finished), 1)
        self.assertEqual(watch.uncovered.__name__, "uncovered")
        p = self.watch("run", "--repo", str(self.repo))
        self.assertIn("nothing pending", p.stderr)

    def test_W6_a_slower_run_escalates_with_the_range_since_the_last_good_run(self):
        good_sha = self.git("rev-parse", "HEAD")
        self.request()
        self.run_round()
        self.write("richos/mobile/native-android/App.kt", "slow\n")
        slow_sha = self.commit("android: the change that slowed it")
        self.request()
        outcomes = self.run_round(env=dict(self.env, FAKE_MODE_ANDROID="slower"))
        android = [o for o in outcomes if o["platform"] == "android"][-1]
        self.assertEqual(android["verdict"], "slower")
        [esc] = self.escalated()
        self.assertIn("Android start SLOWER than the benchmark", esc["title"])
        self.assertIn(f"{good_sha[:12]}..{slow_sha[:12]}", esc["question"])
        self.assertIn("the change that slowed it", esc["question"])
        self.assertIn("coldLaunch p95 1400 ms (SLOWER, limit 1000 ms)", esc["question"])
        self.assertEqual(json.loads((self.base / "home/good.json").read_text())["android"]["commit"], good_sha,
                         "a slower run never becomes the good run")

    def test_W7_a_verb_that_does_not_exist_yet_is_a_run_that_could_not_measure(self):
        self.request()
        outcomes = self.run_round(env=dict(self.env, FAKE_MODE_ANDROID="noverb"))
        android = [o for o in outcomes if o["platform"] == "android"][0]
        self.assertEqual(android["verdict"], "unmeasured")
        self.assertIn("does not exist in main yet", android["why"])
        titles = [e["title"] for e in self.escalated()]
        self.assertTrue(any("Android run COULD NOT MEASURE" in t for t in titles), titles)

    def test_W8_a_verb_that_would_uninstall_is_refused_and_the_phone_is_untouched(self):
        self.request()
        outcomes = self.run_round(env=dict(self.env, FAKE_MODE_ANDROID="uninstall"))
        android = [o for o in outcomes if o["platform"] == "android"][0]
        self.assertEqual(android["verdict"], "refused")
        self.assertIn("adb uninstall", android["why"])
        calls = self.tools()
        self.assertNotIn("real-adb uninstall", calls)
        self.assertNotIn("real-adb install", calls, "the install after the refused uninstall was stopped too")
        titles = [e["title"] for e in self.escalated()]
        self.assertTrue(any("Android run REFUSED" in t for t in titles), titles)

    def test_W9_a_busy_phone_waits_and_is_not_interrupted(self):
        user = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(3)", SERIAL])
        try:
            self.request()
            env = dict(self.env, RICHOS_PHONE_WATCH_PLATFORMS="android", RICHOS_PHONE_WATCH_POLL_S="1",
                       RICHOS_PHONE_WATCH_QUIET_S="1", RICHOS_PHONE_WATCH_MAX_WAIT_S="60")
            started = time.monotonic()
            outcomes = self.run_round(env=env)
            self.assertEqual(outcomes[0]["verdict"], "good")
            self.assertEqual(user.wait(timeout=30), 0, "the phone's user ran to its own end")
            self.assertGreaterEqual(time.monotonic() - started, 2.5, "the run waited for the user to finish")
            free = [r for r in self.ledger() if r["event"] == "phone-free"]
            self.assertGreaterEqual(free[0]["waited"], 2)
        finally:
            user.kill()

    def test_W10_still_busy_at_the_bound_is_reported_and_the_user_left_running(self):
        user = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", SERIAL])
        try:
            self.request()
            env = dict(self.env, RICHOS_PHONE_WATCH_PLATFORMS="android", RICHOS_PHONE_WATCH_POLL_S="1",
                       RICHOS_PHONE_WATCH_MAX_WAIT_S="2")
            outcomes = self.run_round(env=env)
            self.assertEqual(outcomes[0]["verdict"], "unmeasured")
            self.assertIn("stayed busy", outcomes[0]["why"])
            self.assertIsNone(user.poll(), "the user's process is still running: nothing interrupted it")
            self.assertNotIn("cli-android", self.tools(), "nothing was installed or measured")
        finally:
            user.kill()
            user.wait()

    def test_W11_a_phone_whose_app_cannot_have_changed_is_not_measured_again(self):
        self.request()
        self.run_round()
        self.write("richos/mobile/native-ios/App.swift", "faster\n")
        ios_sha = self.commit("ios only")
        self.log.unlink()
        self.request()
        outcomes = self.run_round()[-2:]
        verdicts = {o["platform"]: o["verdict"] for o in outcomes}
        self.assertEqual(verdicts, {"android": "unchanged", "ios": "good"})
        self.assertNotIn("cli-android", self.tools())
        good = json.loads((self.base / "home/good.json").read_text())
        self.assertEqual(good["android"]["commit"], ios_sha, "the good run moves forward, so the next range is short")


class Land(Base):
    """W12: git itself starts the run, through autocheck's post-merge hook on main."""

    def test_W12_a_merge_into_main_touching_mobile_starts_the_run_through_the_hook(self):
        for name in ("autocheck.py", "shim.sh", "install.sh"):
            dest = self.repo / "richos/app/scripts/autocheck" / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(AUTOCHECK / name, dest)
        (self.repo / "richos/mobile/perf").mkdir(parents=True, exist_ok=True)
        for path in (WATCH, GUARD):
            shutil.copy(path, self.repo / "richos/mobile/perf" / path.name)
        (self.repo / "richos/engine").symlink_to(HERE.parents[1] / "engine")
        (self.repo / ".git/info/exclude").write_text("richos/engine\n")
        self.commit("the check and the watch")
        p = self.run_(["bash", str(AUTOCHECK / "install.sh"), str(self.repo)])
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        env = dict(self.env, RICHOS_PHONE_WATCH_RUNNER=f"{sys.executable} {self.bin / 'runner.py'}",
                   RICHOS_ESCALATION_LEDGER=str(self.base / "engine-ledger.jsonl"))
        self.run_(["git", "checkout", "-q", "-b", "feature"], env=env)
        self.write("richos/mobile/native-android/App.kt", "changed\n")
        self.run_(["git", "add", "-A"], env=env)
        p = self.run_(["git", "commit", "-q", "-m", "android change", "--no-verify"], env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.run_(["git", "checkout", "-q", "main"], env=env)
        p = self.run_(["git", "merge", "-q", "--ff-only", "feature"], env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("phone run requested", p.stderr)
        new = self.git("rev-parse", "HEAD")
        self.assertEqual([r["main"] for r in self.ledger() if r["event"] == "requested"], [new])
        for _ in range(50):
            if (self.base / "runner.log").exists():
                break
            time.sleep(0.1)
        self.assertEqual((self.base / "runner.log").read_text().splitlines(), [f"run --repo {self.repo}"])


class Guard(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="phone-guard-")
        base = Path(self.tmp.name)
        self.log = base / "real.log"
        for tool in ("adb", "xcrun"):
            real = base / f"real-{tool}"
            real.write_text(f"#!/bin/sh\necho \"{tool} $*\" >> {self.log}\n")
            real.chmod(0o755)
        self.env = dict(os.environ, RICHOS_PHONE_GUARD_TRIP=str(base / "trip"),
                        RICHOS_PHONE_GUARD_REAL_ADB=str(base / "real-adb"),
                        RICHOS_PHONE_GUARD_REAL_XCRUN=str(base / "real-xcrun"))
        self.trip = base / "trip"

    def tearDown(self):
        self.tmp.cleanup()

    def guard(self, *args):
        return subprocess.run([sys.executable, str(GUARD), *args], env=self.env, capture_output=True, text=True)

    def real(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_G1_uninstall_is_refused_and_stops_the_run(self):
        self.assertEqual(self.guard("adb", "-s", SERIAL, "shell", "pm", "path", "dev.richos.connect").returncode, 0)
        self.assertEqual(self.guard("adb", "-s", SERIAL, "install", "-r", "app.apk").returncode, 0)
        p = self.guard("adb", "-s", SERIAL, "uninstall", "dev.richos.connect")
        self.assertEqual(p.returncode, 97)
        self.assertIn("PHONE GUARD REFUSED: adb uninstall", p.stderr)
        p = self.guard("adb", "-s", SERIAL, "install", "-r", "app.apk")
        self.assertEqual(p.returncode, 97, "after a refusal nothing else of the run reaches the phone")
        self.assertEqual(self.real(), [f"adb -s {SERIAL} shell pm path dev.richos.connect",
                                       f"adb -s {SERIAL} install -r app.apk"])

    def test_G2_data_clears_and_installs_without_r_are_refused(self):
        for args in (("shell", "pm clear dev.richos.connect"), ("shell", "pm", "uninstall", "dev.richos.connect"),
                     ("exec-out", "cmd", "package", "clear", "dev.richos.connect"), ("install", "app.apk"),
                     ("install-multiple", "a.apk", "b.apk")):
            self.trip.unlink(missing_ok=True)
            p = self.guard("adb", "-s", SERIAL, *args)
            self.assertEqual(p.returncode, 97, args)
        self.assertEqual(self.real(), [])

    def test_G3_the_iphone_app_is_never_uninstalled(self):
        self.assertEqual(self.guard("xcrun", "devicectl", "device", "install", "app", "--device", IDENT, "A.app").returncode, 0)
        p = self.guard("xcrun", "devicectl", "device", "uninstall", "app", "--device", IDENT, "dev.richos.connect")
        self.assertEqual(p.returncode, 97)
        self.assertEqual(self.real(), [f"xcrun devicectl device install app --device {IDENT} A.app"])


class Busy(unittest.TestCase):
    def test_B1_who_counts_as_using_the_phone(self):
        procs = [(1, 0, "/sbin/launchd"), (10, 1, "claude"), (20, 10, "python3 watch.py run --repo /r"),
                 (21, 20, f"randroid device perf --serial {SERIAL}"), (22, 21, f"adb -s {SERIAL} shell am start"),
                 (30, 10, f"python3 phone-android.py tap --serial {SERIAL} Send"),
                 (40, 1, "adb -L tcp:5037 fork-server server --reply-fd 4"),
                 (50, 10, "adb -s emulator-5554 shell getprop"), (60, 10, "adb shell input keyevent 3"),
                 (70, 1, "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDeviceService")]
        found = [pid for pid, _ in watch.users("android", [SERIAL], procs=procs, me=20)]
        self.assertEqual(found, [30, 60], "another agent's phone tool and a serial-less adb client; not this run, "
                                          "not the adb server, not an emulator")
        self.assertEqual(watch.users("ios", [IDENT], procs=procs, me=20), [])

    def test_B2_the_wait_resets_on_every_busy_sample_and_never_interrupts(self):
        samples = iter([[(30, "x")], [], [(30, "x")], [], [], []])
        clock = iter(range(0, 100, 10))
        os.environ["RICHOS_PHONE_WATCH_QUIET_S"] = "15"
        try:
            free, waited = watch.wait_until_free("android", [SERIAL], sample=lambda: next(samples),
                                                 clock=lambda: next(clock), sleep=lambda s: None, log=lambda s: None)
        finally:
            del os.environ["RICHOS_PHONE_WATCH_QUIET_S"]
        self.assertTrue(free)
        self.assertEqual(waited, 60, "free only once QUIET_S has passed with no busy sample, counted from the last one")


if __name__ == "__main__":
    unittest.main(verbosity=2)
