#!/usr/bin/env python3
"""mobile-device.test.py — a physical phone is touched only through `randroid device` / `rios device`,
only the release build goes on it, and nothing uninstalls the app or clears its data (CEO 2026-10-02,
2026-10-01). The real `randroid` runs against a scripted adb and a scripted aapt2 that keep a fake
phone's state in a JSON file; the commit check (`physical.py scan`) runs over planted files in a
scratch git repository. No phone, emulator, build or window.
"""
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
RANDROID = REPO / "richos/mobile/native-android/bin/randroid"
PHYSICAL = REPO / "richos/mobile/physical.py"
sys.path.insert(0, str(REPO / "richos/mobile"))
import physical  # noqa: E402

failures = []
names = []


def case(name):
    def wrap(fn):
        names.append(name)
        try:
            fn()
            print(f"  ok    {name}")
        except Exception as e:  # noqa: BLE001 — every failure is reported by name
            failures.append(name)
            print(f"  FAIL  {name}: {type(e).__name__}: {e}")
        return fn
    return wrap


# A scripted adb: the fake phone is a JSON file (emulator or not, the installed APK's bytes and
# whether it is debuggable, whether the phone refuses an install). Every call is logged.
FAKE_ADB = r'''#!/usr/bin/env python3
import hashlib, json, os, sys
state_path = os.environ["FAKE_PHONE"]
state = json.load(open(state_path))
args = sys.argv[1:]
with open(state_path + ".log", "a") as log:
    log.write(" ".join(args) + "\n")
if args[:1] == ["devices"]:
    print("List of devices attached\n" + state["serial"] + "\tdevice"); sys.exit(0)
if args[:2] != ["-s", state["serial"]]:
    print("error: device '%s' not found" % (args[1] if len(args) > 1 else ""), file=sys.stderr); sys.exit(1)
verb, rest = args[2], args[3:]
def save():
    json.dump(state, open(state_path, "w"))
if verb == "shell":
    cmd = " ".join(rest)
    if cmd.startswith("getprop ro.kernel.qemu"):
        flags = "DEBUGGABLE HAS_CODE" if state.get("debuggable") else "HAS_CODE ALLOW_CLEAR_USER_DATA"
        print("1" if state.get("emulator") else "")
        print("")
        print("--richos--")
        if state.get("sha"):
            print("    versionName=%s" % state.get("version", "1.0.0"))
            print("    versionCode=7 minSdk=26 targetSdk=36")
            print("    pkgFlags=[ %s ]" % flags)
        sys.exit(0)
    if cmd.startswith("pm path "):
        if state.get("sha"):
            print("package:/data/app/~~x/dev.richos.connect-1/base.apk")
        sys.exit(0)
    if cmd.startswith("sha256sum /data/app"):
        print("%s  /data/app/~~x/dev.richos.connect-1/base.apk" % state.get("sha")); sys.exit(0)
    if cmd.startswith("screenrecord"):
        state["recorded"] = cmd; save(); sys.exit(0)
    if cmd.startswith("rm -f"):
        sys.exit(0)
    sys.exit(0)
if verb == "install":
    if state.get("refuse"):
        print("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]", file=sys.stderr); sys.exit(1)
    data = open(rest[-1], "rb").read()
    state["sha"] = hashlib.sha256(data).hexdigest()
    state["debuggable"] = b"DEBUGGABLE" in data
    save(); print("Performing Streamed Install\nSuccess"); sys.exit(0)
if verb == "pull":
    open(rest[1], "wb").write(b"\x00\x00\x00\x18ftypmp42 fake video"); sys.exit(0)
print("unexpected adb call: " + " ".join(args), file=sys.stderr)
sys.exit(1)
'''

# aapt2's own reading of the manifest, scripted: an APK whose bytes say DEBUGGABLE is debuggable.
FAKE_AAPT2 = r'''#!/usr/bin/env python3
import sys
data = open(sys.argv[-1], "rb").read()
name = "dev.richos.other" if b"OTHER" in data else "dev.richos.connect"
print("package: name='%s' versionCode='7' versionName='1.0.0'" % name)
print("application-label:'RichConnect'")
if b"DEBUGGABLE" in data:
    print("application-debuggable")
'''


class Phone:
    def __init__(self, tmp, **state):
        self.tmp = Path(tmp)
        self.bin = self.tmp / "bin"
        self.bin.mkdir(exist_ok=True)
        for name, body in (("adb", FAKE_ADB), ("aapt2", FAKE_AAPT2)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.file = self.tmp / "phone.json"
        self.file.write_text(json.dumps({"serial": "PHONE1", **state}))
        self.release = self.apk("release.apk", b"release bytes")
        self.debug = self.apk("app-debug.apk", b"debug bytes DEBUGGABLE")

    def apk(self, name, data):
        path = self.tmp / name
        path.write_bytes(data)
        return str(path)

    @property
    def state(self):
        return json.loads(self.file.read_text())

    @property
    def calls(self):
        log = Path(str(self.file) + ".log")
        return log.read_text().splitlines() if log.exists() else []

    def randroid(self, *args, env=None):
        e = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "FAKE_PHONE": str(self.file),
             "RANDROID_CACHE": str(self.tmp / "cache"), "ANDROID_HOME": str(self.tmp / "sdk"),
             "RANDROID_AAPT2": str(self.bin / "aapt2"), "PYTHONDONTWRITEBYTECODE": "1",
             "RICHOS_PHONE_LOCK_DIR": str(self.tmp / "locks"), "RICHOS_DEVICE_HOLDER": "test-runner"}
        e.pop("RICHOS_DEVICE_VERB", None)
        e.update(env or {})
        p = subprocess.run(["bash", str(RANDROID), *args], capture_output=True, text=True, env=e, timeout=120)
        return p.returncode, p.stdout + p.stderr


def touched(calls):
    """The calls that change the phone: an install, an uninstall, a data clear."""
    return [c for c in calls if " install" in f" {c.split(' ', 2)[-1]}" or "uninstall" in c or "pm clear" in c]  # device-cli-exempt: reads the scripted adb's log for the calls that must not happen


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# -- install: release only, over the app, never an uninstall ------------------------------------

@case("D1 a debuggable APK is refused on a physical phone, with the sentence; nothing is installed")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp, sha="a" * 64)
        code, out = ph.randroid("device", "--serial", "PHONE1", "install", ph.debug)
        assert code == 3, (code, out)
        assert "DEBUGGABLE build" in out and "only the build users get (release)" in out, out
        assert touched(ph.calls) == [] and ph.state["sha"] == "a" * 64, ph.calls


@case("D2 the release APK goes over the installed app with install -r (data kept), is read back, and is stamped for device perf")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp, sha="a" * 64)
        code, out = ph.randroid("device", "--serial", "PHONE1", "install", ph.release)
        assert code == 0, (code, out)
        installs = touched(ph.calls)
        assert installs == [f"-s PHONE1 install -r {ph.release}"], installs
        assert ph.state["sha"] == sha(ph.release) and not ph.state["debuggable"], ph.state
        assert '"configuration": "release"' in out, out
        stamp = json.loads(Path(ph.release + ".stamp.json").read_text())
        assert stamp["sha256"] == sha(ph.release), stamp
        code, out = ph.randroid("device", "--serial", "PHONE1", "install", ph.release)
        assert code == 0 and '"install": "skipped"' in out and len(touched(ph.calls)) == 1, (code, out)


@case("D3 a phone that refuses the install (another signer) is reported, and NOTHING is uninstalled")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp, sha="b" * 64, debuggable=True, refuse=True)
        code, out = ph.randroid("device", "--serial", "PHONE1", "install", ph.release)
        assert code == 3 and "NOTHING was uninstalled" in out and "CEO's decision" in out, (code, out)
        assert not any("uninstall" in c or "pm clear" in c for c in ph.calls), ph.calls
        assert ph.state["sha"] == "b" * 64


@case("D4 an APK that is not RichConnect is refused before the phone is touched")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp)
        other = ph.apk("other.apk", b"OTHER release")
        code, out = ph.randroid("device", "--serial", "PHONE1", "install", other)
        assert code == 3 and "not RichConnect" in out and ph.calls == [], (code, out, ph.calls)


@case("D5 an emulator is refused by randroid device (emulators go through randroid emu); no serial is refused")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp, emulator=True)
        code, out = ph.randroid("device", "--serial", "PHONE1", "install", ph.release)
        assert code == 3 and "randroid emu" in out and touched(ph.calls) == [], (code, out)
        code, out = ph.randroid("device", "build")
        assert code == 1 and "name the phone" in out, (code, out)


@case("D14 the grammar richos/mobile/perf/watch.py calls: --serial after the command; --expect-commit refuses another commit before the phone is touched")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp, sha="a" * 64)
        code, out = ph.randroid("device", "install", "--serial", "PHONE1", "--expect-commit", "0000000", ph.release)
        assert code == 3 and "freshness mismatch" in out and "nothing was installed" in out, (code, out)
        assert touched(ph.calls) == [], ph.calls
        code, out = ph.randroid("device", "install", "--serial", "PHONE1", ph.release)
        assert code == 0 and ph.state["sha"] == sha(ph.release), (code, out)
        sys.path.insert(0, str(REPO / "richos/mobile/perf"))
        import perf  # noqa: E402
        args = perf.parse_args(["android", "--adb", "adb", "--serial", "S", "--kind", "physical", "--evidence-dir", "/x/e",
                                "--cold", "3", "--warm", "2", "--expect-commit", "abcdef1", "--out", "/x/r.json"])
        assert (args.evidence_dir, args.cold, args.warm, args.expect_commit) == ("/x/e", 3, 2, "abcdef1"), args


@case("D15 an unsigned release APK is refused by name before the phone is touched (a phone installs only a signed APK)")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp, sha="a" * 64)
        unsigned = ph.apk("app-release-unsigned.apk", b"release bytes")
        code, out = ph.randroid("device", "--serial", "PHONE1", "install", unsigned)
        assert code == 3 and "unsigned" in out and "with-android-signing.py" in out and ph.calls == [], (code, out, ph.calls)


# -- every other command tests the release build only --------------------------------------------

@case("D6 build shows the installed build, debuggable or not: the way to see the phone's state is never refused")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp, sha="c" * 64, debuggable=True, version="1.0.0-dev")
        code, out = ph.randroid("device", "--serial", "PHONE1", "build")
        result = json.loads(out)["result"]
        assert code == 0 and result["debuggable"] is True and result["versionName"] == "1.0.0-dev", out
        assert result["configuration"] == "debug"


@case("D7 a walk step on a phone holding a debuggable build is refused before the step, naming the build and the way back")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp, sha="c" * 64, debuggable=True, version="1.0.0-dev")
        for step in (["tap", "Send message"], ["texts"], ["state", "--package", "dev.richos.connect"]):
            code, out = ph.randroid("device", "--serial", "PHONE1", *step)
            assert code == 3, (step, code, out)
            assert "DEBUGGABLE RichConnect" in out and "1.0.0-dev" in out and "device --serial PHONE1 install" in out, out
        assert not any(" input " in f" {c} " or "uiautomator" in c for c in ph.calls), ph.calls


@case("D8 a screen recording on the release build: screenrecord, pulled, removed from the phone; a debuggable build is refused first")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp, sha="d" * 64)
        out_file = str(Path(tmp) / "rec" / "cold.mp4")
        code, out = ph.randroid("device", "--serial", "PHONE1", "record", out_file, "--seconds", "5")
        assert code == 0 and Path(out_file).is_file(), (code, out)
        assert ph.state["recorded"].startswith("screenrecord --time-limit 5 "), ph.state
        assert any(c.endswith("rm -f /sdcard/richos-device-record.mp4") for c in ph.calls), ph.calls
        (Path(tmp) / "two").mkdir()
        ph2 = Phone(Path(tmp) / "two", sha="d" * 64, debuggable=True)
        code, out = ph2.randroid("device", "--serial", "PHONE1", "record", out_file)
        assert code == 3 and "recorded" not in ph2.state, (code, out)


@case("D9 perf and seed on a physical phone go through the verb; started any other way perf.py refuses")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp, sha="e" * 64)
        env = {**os.environ, "PATH": f"{ph.bin}:{os.environ['PATH']}", "FAKE_PHONE": str(ph.file)}
        env.pop("RICHOS_DEVICE_VERB", None)
        p = subprocess.run([sys.executable, str(REPO / "richos/mobile/perf/perf.py"), "android", "--adb", "adb",
                            "--serial", "PHONE1", "--kind", "physical", "--conversation", "as-installed"],
                           capture_output=True, text=True, env=env)
        assert p.returncode == 3 and "randroid device perf" in p.stderr and ph.calls == [], (p.returncode, p.stderr, ph.calls)
        # seed builds the release build's twin itself; without the upload key it cannot carry the
        # release signature, so it refuses (exit 3) with the sentence before the phone is touched
        from unittest.mock import patch
        with patch.dict(os.environ):
            for key in [k for k in os.environ if k.startswith("ORG_GRADLE_PROJECT_richos.upload.")]:
                del os.environ[key]
            code, out = ph.randroid("device", "--serial", "PHONE1", "seed")
        assert code == 3 and "debuggable twin must carry the upload key" in out and ph.calls == [], (code, out, ph.calls)


# -- one user per phone (CEO 2026-10-02) ---------------------------------------------------------
# Every holder below is a process this test started; its PID is the one recorded at spawn (the
# hold process) or the one its own command wrote (the held command), and only those are signaled.

def hold_cmd(phone, *cmd, wait=0, holder="agent-one", platform="android"):
    return [sys.executable, str(PHYSICAL), "hold", "--platform", platform, "--phone", phone, "--wait", str(wait),
            "--holder", holder, "--", *cmd]


class Holder:
    """A first user of a phone: `hold` running a command that writes its own PID, then sleeps."""

    def __init__(self, tmp, phone="P1", seconds=30, holder="agent-one", platform="android"):
        self.env = {**os.environ, "RICHOS_PHONE_LOCK_DIR": str(Path(tmp) / "locks"), "PYTHONDONTWRITEBYTECODE": "1"}
        self.flag = Path(tmp) / f"held-{holder}-{phone}"
        body = f"import os, pathlib, time; pathlib.Path({str(self.flag)!r}).write_text(str(os.getpid())); time.sleep({seconds})"
        self.proc = subprocess.Popen(hold_cmd(phone, sys.executable, "-c", body, holder=holder, platform=platform),
                                     env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        # The fact waited for: the held command wrote its PID, or the holder ended without doing so.
        while not (self.flag.exists() and self.flag.read_text()):
            if self.proc.poll() is not None:
                raise AssertionError(f"the first holder ended before its command ran: {self.proc.stderr.read()}")
            time.sleep(0.05)
        self.child = int(self.flag.read_text())

    def stop(self):
        for pid in (self.proc.pid, self.child):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.proc.wait()  # SIGKILL always ends it; this only reaps it


def second(tmp, phone="P1", wait=0, cmd=("true",), holder="agent-two", platform="android"):
    env = {**os.environ, "RICHOS_PHONE_LOCK_DIR": str(Path(tmp) / "locks"), "PYTHONDONTWRITEBYTECODE": "1"}
    return subprocess.run(hold_cmd(phone, *cmd, wait=wait, holder=holder, platform=platform), env=env,
                          capture_output=True, text=True, timeout=900)  # load-bound: a hang guard only; no verdict rests on it


def lock_status(tmp, phone="P1", platform="android"):
    env = {**os.environ, "RICHOS_PHONE_LOCK_DIR": str(Path(tmp) / "locks")}
    p = subprocess.run([sys.executable, str(PHYSICAL), "status", "--platform", platform, "--phone", phone],
                       env=env, capture_output=True, text=True)
    return json.loads(p.stdout)["result"]


@case("D16 two users of one phone: the second is refused at once, naming the holder; status says held and by whom")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        first = Holder(tmp)
        try:
            p = second(tmp)
            assert p.returncode == 3, (p.returncode, p.stderr)
            assert "in use by agent-one" in p.stderr and f"process {first.proc.pid}" in p.stderr, p.stderr
            st = lock_status(tmp)
            assert st["state"] == "held" and st["holder"] == "agent-one" and st["pid"] == first.proc.pid, st
        finally:
            first.stop()


@case("D17 a second user given --wait waits for the first, says so, and goes on when the phone is free")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        first = Holder(tmp, seconds=2)
        try:
            p = second(tmp, wait=600)  # load-bound: the first ends after its 2 s sleep; 600 s only bounds a hang
            assert p.returncode == 0, (p.returncode, p.stderr)
            assert "waiting up to 600 s" in p.stderr and "held by agent-one" in p.stderr and "is free after" in p.stderr, p.stderr
            st = lock_status(tmp)
            assert st["state"] == "free" and st["previous"]["holder"] == "agent-two" and st["previous"]["endedAt"], st
        finally:
            first.stop()


@case("D18 a holder whose process is gone: its lock is free, status says so, and the next user takes it and records whose it was")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        first = Holder(tmp)
        first.stop()  # killed outright: no handler, no release of its own
        st = lock_status(tmp)
        assert st["state"] == "free" and "process is gone" in st["previous"]["note"], st
        p = second(tmp)
        assert p.returncode == 0 and "ended without releasing" in p.stderr and "agent-one" in p.stderr, (p.returncode, p.stderr)
        record = json.loads((Path(tmp) / "locks" / Path(lock_status(tmp)["record"]).name).read_text())
        assert record["reclaimedFrom"]["holder"] == "agent-one" and record["holder"] == "agent-two", record


@case("D19 one session, many commands: a device command inside `hold` of the same phone runs without waiting")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        inner = hold_cmd("P1", "true", holder="inner")
        p = second(tmp, cmd=inner, holder="walker")
        assert p.returncode == 0, (p.returncode, p.stderr)


@case("D20 two phones are two locks; the iPhone's spellings (hardware UDID, CoreDevice UUID) are one")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        first = Holder(tmp, phone="P1")
        try:
            assert second(tmp, phone="P2").returncode == 0
        finally:
            first.stop()
        iphone = Holder(tmp, phone="00008030-AAAA", platform="ios")
        try:
            p = second(tmp, phone="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", platform="ios")
            assert p.returncode == 3 and "iPhone is in use by agent-one" in p.stderr, p.stderr
        finally:
            iphone.stop()


@case("D21 randroid device refuses a walk step while another user holds the phone (nothing reaches it), and status names the holder")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        ph = Phone(tmp, sha="f" * 64)
        first = Holder(tmp, phone="PHONE1")
        try:
            code, out = ph.randroid("device", "--serial", "PHONE1", "tap", "Send message")
            assert code == 3 and "in use by agent-one" in out, (code, out)
            assert ph.calls == [], ph.calls
            code, out = ph.randroid("device", "--serial", "PHONE1", "status")
            result = json.loads(out)["result"]
            assert code == 0 and result["state"] == "held" and result["holder"] == "agent-one", out
        finally:
            first.stop()
        code, out = ph.randroid("device", "--serial", "PHONE1", "build")
        assert code == 0 and '"configuration": "release"' in out, (code, out)


# -- the commit check ---------------------------------------------------------------------------
# Each planted line is what a change might add; the scan must name it. The literals carry the
# exemption marker as a comment on THIS file's line, never inside the planted text.
PLANTED = {
    "richos/app/scripts/qa/new-tool.sh": 'adb -s "$SERIAL" install -r out/app-debug.apk\n',  # device-cli-exempt: planted, the scan must refuse it
    "richos/app/scripts/qa/wipe.py": 'subprocess.run(["adb", "-s", serial, "uninstall", "dev.richos.connect"])\n',  # device-cli-exempt: planted, the scan must refuse it
    "richos/app/scripts/qa/clear.sh": 'adb -s "$S" shell pm clear dev.richos.connect\n',  # device-cli-exempt: planted, the scan must refuse it
    "richos/mobile/native-android/bin/helper.sh": './gradlew :app:installDebug\n',  # device-cli-exempt: planted, the scan must refuse it
    "richos/app/scripts/qa/ios.sh": 'xcodebuild test -scheme X -destination "platform=iOS,id=$UDID"\n',  # device-cli-exempt: planted, the scan must refuse it
    "richos/app/scripts/qa/ios2.sh": 'xcrun devicectl device install app --device "$UDID" "$APP"\n',  # device-cli-exempt: planted, the scan must refuse it
    "richos/app/scripts/qa/ios3.mjs": "const app = 'build/Debug-iphoneos/RichOSNative.app';\n",  # device-cli-exempt: planted, the scan must refuse it
    "richos/mobile/native-android/bin/randroid": 'adb -s "$S" uninstall dev.richos.connect\n',  # device-cli-exempt: planted: the command line itself may never remove the app
    "docs/howto.md": "Prose about adb install is fine.\n\n```sh\nadb -s SERIAL install app.apk\n```\n",  # device-cli-exempt: planted, the fenced command must be refused
}
CLEAN = {
    "richos/mobile/native-android/bin/apk-install.sh": 'echo never an uninstall; "$adb" -s "$serial" install -r "$apk"\n',  # device-cli-exempt: a fixture the check must pass
    "richos/app/scripts/qa/t.test.py": 'assert "uninstall" not in calls and "pm clear" not in calls\n',  # device-cli-exempt: a fixture the check must pass
    "richos/app/scripts/qa/sim.sh": 'xcrun simctl install "$UDID" "$APP"\nmake install\n',
    "richos/mobile/perf/android.py": 'dev.run("install", "-r", apk)\n',  # device-cli-exempt: a fixture the check must pass
    "richos/app/scripts/qa/x.sh": 'adb -s "$S" install x.apk  # device-cli-exempt: a reviewer-visible reason here\n',
    "docs/prose.md": "Run `adb install -r` only through randroid device.\n",  # device-cli-exempt: a fixture the check must pass
    "richos/engine/reference/advanced-tier/old.sh": 'adb -s "$S" uninstall example\n',  # device-cli-exempt: a fixture the check must pass
}


def scratch_repo(tmp, files):
    root = Path(tmp)
    for path, text in files.items():
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_text(text)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
    return root


@case("D10 the commit check names every planted phone install, uninstall, data clear, Gradle device task, device xcodebuild and Debug iPhone build")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        root = scratch_repo(tmp, PLANTED)
        found = {path for path, *_ in physical.scan(root)}
        assert found == set(PLANTED), sorted(set(PLANTED) - found)
        p = subprocess.run([sys.executable, str(PHYSICAL), "scan", "--root", str(root)], capture_output=True, text=True)
        assert p.returncode == 1 and "REFUSED" in p.stderr and "randroid device" in p.stderr, p.stderr


@case("D11 the check passes the command lines' own installs, simulators, tests of absence, prose, declared exemptions and reference examples")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        root = scratch_repo(tmp, CLEAN)
        assert physical.scan(root) == [], physical.scan(root)


@case("D12 this repository's tree passes its own check")
def _():
    p = subprocess.run([sys.executable, str(PHYSICAL), "scan", "--root", str(REPO)], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr[-1500:]


@case("D13 the commit check is wired into the commit and the land (autocheck.py)")
def _():
    text = (REPO / "richos/app/scripts/autocheck/autocheck.py").read_text()
    assert 'PHYSICAL_CHECK = "richos/mobile/physical.py"' in text
    commit = text[text.index("def commit_check("):text.index("def policy_inputs(")]
    assert commit.count("physical_check(repo, what)") == 2, "both commit paths (inside and outside richos/app) run it"
    land = text[text.index("def land_check("):text.index("def left_out(")]
    # proof-run.py reads only `cd <dir> && <command>` lines, so the land writes the scan in that form
    assert 'f"cd {scanner.parent} && python3 {scanner.name} scan"' in land, "every land runs it, as a line proof-run can read"
    assert "python3 {PHYSICAL_CHECK} scan" not in land, "not the bare form proof-run refuses"


if __name__ == "__main__":
    if failures:
        print(f"mobile-device: {len(failures)} of {len(names)} FAILED: {', '.join(failures)}")
        sys.exit(1)
    print(f"mobile-device: {len(names)} cases passed")
