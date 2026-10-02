#!/usr/bin/env python3
"""physical.py — what may touch a physical phone, and how (CEO, 2026-10-02).

His rule: only the build users get (release) ever goes on his wired phones, and every test on them
tests that build. His standing rule (2026-10-01): never wipe or reinstall the app; install over the
existing build only, keeping its data. On 2026-10-02 the wired Android phone ran a debuggable build
from 00:40Z to about 08:30Z; its screen sat blank 2.1-2.6 s per cold start against 0.25-0.34 s on the
release build, and he judged the app by it.

So a physical phone is touched ONLY through the two command lines, `randroid device ...` and
`rios device ...`, and this file holds their rules (both call it; nothing else should):

    physical.py android-build   --adb ADB --serial S        the installed build; never refused
    physical.py android-gate    --adb ADB --serial S        exit 0 (the installed build as JSON) or 3
    physical.py android-install --adb ADB --serial S --apk APK --aapt2 AAPT2
    physical.py android-record  --adb ADB --serial S --out FILE.mp4 [--seconds N]
    physical.py ios-app APP                                 exit 0 for a Release bundle, 3 otherwise
    physical.py hold --platform android|ios --phone ID [--wait S] [--holder NAME] -- <command>
                                                            run <command> holding that phone's lock
    physical.py status --platform android|ios --phone ID    free or held, and by whom (JSON)
    physical.py scan [--root DIR]                           the commit check (autocheck.py runs it)

One user per phone (CEO 2026-10-02): see "one user per phone" below. The lock records live in
/Volumes/E1TB/state/richos/phone-locks/<android-<sha256(serial)[:16]> | ios-iphone>.json.

The gate refuses: an emulator (it goes through `randroid emu`), and a phone whose installed
RichConnect is debuggable (`dumpsys package` pkgFlags DEBUGGABLE), naming the build it found. The
install refuses an APK whose manifest is debuggable (aapt2's own reading), installs with
`adb install -r` (the app's data kept), and never uninstalls: when the phone refuses (a build signed
by another key is installed), it says so and leaves the phone as it was, because replacing that
build means an uninstall, which wipes the app's data, and that is the CEO's decision. An emulator or
a simulator is never refused here; it has its own commands.

Exit codes: 0 done, 2 cannot answer (bad arguments, a tool missing), 3 refused, with the sentence.
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

PACKAGE = "dev.richos.connect"
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
# Set by the command line that owns physical phones (randroid / rios) for the tools it runs.
VERB_ENV = "RICHOS_DEVICE_VERB"
RULE = ("only the build users get (release) ever goes on a physical phone, and every test on one tests "
        "that build (CEO, 2026-10-02)")


class Refused(Exception):
    pass


class CannotAnswer(Exception):
    pass


def require_verb(cli):
    """The tools behind the two command lines refuse to touch a physical phone on their own."""
    if os.environ.get(VERB_ENV) != cli:
        raise Refused(f"a physical phone is touched only through `{cli} device ...`, which checks that the "
                      f"build on it is the release build: {RULE}")


# -- Android ----------------------------------------------------------------------------------

def adb(adb_path, serial, *args, binary=False, timeout=120):
    if not serial:
        raise CannotAnswer("no serial: a phone is addressed only by an explicit serial, never a bare adb")
    try:
        return subprocess.run([adb_path, "-s", serial, *args], capture_output=True, text=not binary, timeout=timeout)
    except FileNotFoundError:
        raise CannotAnswer(f"no adb at {adb_path}")
    except subprocess.TimeoutExpired:
        raise CannotAnswer(f"adb {' '.join(args)[:80]} did not answer in {timeout} s")


PROBE = (f"getprop ro.kernel.qemu; getprop ro.boot.qemu; echo '--richos--'; "
         f"dumpsys package {PACKAGE} | grep -E 'versionName=|versionCode=|pkgFlags=|lastUpdateTime='; true")


def probe(adb_path, serial):
    """One adb round trip: is it an emulator, and what RichConnect build is installed."""
    p = adb(adb_path, serial, "shell", PROBE, timeout=30)
    if p.returncode != 0 or "--richos--" not in p.stdout:
        raise CannotAnswer(f"{serial} did not answer (is it attached and authorized in `adb devices`?): "
                           f"{(p.stderr or p.stdout).strip()[:200]}")
    head, _, tail = p.stdout.replace("\r", "").partition("--richos--")
    emulator = "1" in head.split()
    flags = re.search(r"pkgFlags=\[([^\]]*)\]", tail)
    version = re.search(r"versionName=(\S+)", tail)
    code = re.search(r"versionCode=(\d+)", tail)
    updated = re.search(r"lastUpdateTime=(.+)", tail)
    installed = bool(flags or version)
    debuggable = bool(flags and "DEBUGGABLE" in flags.group(1).split())
    return {"serial": serial, "emulator": emulator, "package": PACKAGE, "installed": installed,
            "versionName": version.group(1) if version else None, "versionCode": int(code.group(1)) if code else None,
            "lastUpdateTime": updated.group(1).strip() if updated else None,
            "debuggable": debuggable if installed else None,
            "configuration": ("debug" if debuggable else "release") if installed else None}


def physical(info):
    if info["emulator"]:
        raise Refused(f"{info['serial']} is an emulator: emulators go through `randroid emu ...`, never `randroid device`")


def gate(adb_path, serial):
    """The check every command on a physical phone passes first. Returns the installed build."""
    info = probe(adb_path, serial)
    physical(info)
    if info["debuggable"]:
        raise Refused(f"{serial} has a DEBUGGABLE RichConnect installed (versionName {info['versionName']}, "
                      f"pkgFlags DEBUGGABLE), so nothing on it would test the build users get: {RULE}. "
                      "Put the release build over it, data kept: `randroid build release`, then "
                      f"`randroid device --serial {serial} install`. If the phone refuses that install (the "
                      "debuggable build is signed by another key), replacing it means an uninstall, which wipes "
                      "the app's data: that is the CEO's decision, never a tool's")
    return info


def apk_badging(aapt2, apk):
    """(package name, debuggable) from aapt2's own reading of the APK's manifest."""
    if not os.path.isfile(apk):
        raise CannotAnswer(f"no APK at {apk}")
    try:
        p = subprocess.run([aapt2, "dump", "badging", apk], capture_output=True, text=True, timeout=120)
    except FileNotFoundError:
        raise CannotAnswer(f"no aapt2 at {aapt2}: whether {apk} is debuggable cannot be read, so it is not installed")
    if p.returncode != 0:
        raise CannotAnswer(f"aapt2 could not read {apk}: {(p.stderr or p.stdout).strip()[:200]}")
    name = re.search(r"^package: name='([^']*)'", p.stdout, re.M)
    lines = [line.strip() for line in p.stdout.splitlines()]
    return (name.group(1) if name else None), "application-debuggable" in lines


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def installed_sha(adb_path, serial):
    p = adb(adb_path, serial, "shell", f"pm path {PACKAGE}", timeout=30)
    paths = [l.split(":", 1)[1].strip() for l in p.stdout.split() if l.startswith("package:")]
    if len(paths) != 1:
        return None
    q = adb(adb_path, serial, "shell", f"sha256sum {paths[0]}", timeout=60)
    return (q.stdout.split() or [None])[0] if q.returncode == 0 else None


def install(adb_path, serial, apk, aapt2):
    """Release only, over the installed app, data kept, never an uninstall."""
    name, debuggable = apk_badging(aapt2, apk)
    if name != PACKAGE:
        raise Refused(f"{apk} is {name!r}, not RichConnect ({PACKAGE}); only RichConnect's release build goes on the phone")
    if debuggable:
        raise Refused(f"{apk} is a DEBUGGABLE build (its manifest says so); {RULE}. Build the release APK "
                      "(`randroid build release`) and install that")
    info = probe(adb_path, serial)
    physical(info)
    want = sha256_file(apk)
    if info["installed"] and not info["debuggable"] and installed_sha(adb_path, serial) == want:
        return {"install": "skipped", "why": "these exact bytes are already installed", "sha256": want, "build": info}
    p = adb(adb_path, serial, "install", "-r", apk, timeout=600)
    if p.returncode != 0 or "Success" not in (p.stdout + p.stderr):
        raise Refused(f"the phone refused the install ({(p.stderr or p.stdout).strip()[-300:]}); NOTHING was "
                      "uninstalled and the app's data is untouched. If a build signed by another key is installed, "
                      "replacing it means an uninstall, which wipes the app's data: that is the CEO's decision")
    after = probe(adb_path, serial)
    got = installed_sha(adb_path, serial)
    if after["debuggable"] or got != want:
        raise Refused(f"after the install the phone holds {after['configuration']} bytes {str(got)[:12]}…, not the "
                      f"release APK {want[:12]}…")
    return {"install": "installed", "sha256": want, "build": after}


def record(adb_path, serial, out, seconds):
    """A screen recording of what the phone shows, through the gate first. Android's own
    `screenrecord` (at most 180 s), pulled to `out`, removed from the phone."""
    if not (1 <= seconds <= 180):
        raise CannotAnswer("--seconds must be 1 to 180 (Android's screenrecord limit)")
    if not out.endswith(".mp4"):
        raise CannotAnswer("--out must name an .mp4 file")
    info = gate(adb_path, serial)
    remote = "/sdcard/richos-device-record.mp4"
    try:
        p = adb(adb_path, serial, "shell", f"screenrecord --time-limit {int(seconds)} {remote}", timeout=seconds + 30)
        if p.returncode != 0:
            raise CannotAnswer(f"screenrecord failed: {(p.stderr or p.stdout).strip()[:200]}")
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        q = adb(adb_path, serial, "pull", remote, out, timeout=120)
        if q.returncode != 0 or not os.path.isfile(out):
            raise CannotAnswer(f"could not copy the recording off the phone: {(q.stderr or q.stdout).strip()[:200]}")
    finally:
        adb(adb_path, serial, "shell", f"rm -f {remote}", timeout=30)
    return {"recording": out, "seconds": seconds, "bytes": os.path.getsize(out), "build": info}


# -- one user per phone -------------------------------------------------------------------------
# CEO, 2026-10-02: two agents used the iPhone at once and broke each other's runs twice. Every
# command of the two verbs runs inside `hold`: an exclusive lock per physical phone for the whole
# use (a perf series, a recording, a UI-test session: the command's full length, never per adb
# call; `randroid device hold -- <script>` keeps it across a walker's many commands). The lock is
# the kernel's (flock), so it is released however the holder ends, a crash or a kill included; the
# record beside it says who holds it (teammate, process, start, command). A second caller is refused
# at once with the holder's name, or waits up to --wait seconds, saying so. A holder whose process
# is gone left its lock released; the next caller says so and takes it. Queried by `status`.
# The iPhone lock is one for every spelling of the phone (hardware UDID, CoreDevice UUID): the Mac
# has one wired iPhone, and two spellings must never be two locks.

LOCK_DIR = "/Volumes/E1TB/state/richos/phone-locks"
HOLD_ENV = "RICHOS_DEVICE_HOLD"


def lock_dir():
    d = os.environ.get("RICHOS_PHONE_LOCK_DIR") or LOCK_DIR
    if d == LOCK_DIR and not os.path.ismount("/Volumes/E1TB"):
        raise CannotAnswer("the phone locks live on /Volumes/E1TB, which is not mounted; nothing touches a phone without its lock")
    return d


def lock_paths(platform, phone):
    if platform not in ("android", "ios"):
        raise CannotAnswer("--platform is android or ios")
    if platform == "android" and not phone:
        raise CannotAnswer("an Android phone's lock is named by its serial")
    name = "ios-iphone" if platform == "ios" else "android-" + hashlib.sha256(phone.encode()).hexdigest()[:16]
    base = os.path.join(lock_dir(), name)
    return name, base + ".lock", base + ".json"


def phone_label(platform, phone):
    return "iPhone" if platform == "ios" else f"Android phone {phone}"


def holder_name():
    if os.environ.get("RICHOS_DEVICE_HOLDER"):
        return os.environ["RICHOS_DEVICE_HOLDER"]
    branch = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True).stdout.strip()
    return f"{branch or 'unknown'} in {os.getcwd()}"


def read_record(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_record(path, record):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(record, f, indent=1)
    os.replace(tmp, path)


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except (PermissionError, ValueError, TypeError):
        return True


def ancestors():
    pids, pid = set(), os.getppid()
    for _ in range(64):
        if pid <= 1 or pid in pids:
            break
        pids.add(pid)
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        pid = int(out) if out.isdigit() else 0
    return pids


def inside_hold(name):
    """True when a `hold` of this phone is an ancestor of this process: one session, many commands."""
    held, _, pid = os.environ.get(HOLD_ENV, "").rpartition(":")
    return held == name and pid.isdigit() and int(pid) in ancestors()


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def status(platform, phone):
    """free or held, and by whom. Reads the record; tests the kernel lock only when the record says
    held and its process lives (a reused process id), and then only for an instant."""
    name, lock, record_path = lock_paths(platform, phone)
    rec = read_record(record_path) or {}
    out = {"phone": phone_label(platform, phone), "lock": lock, "record": record_path}
    if not rec or rec.get("endedAt") or not alive(rec.get("pid")):
        if rec and not rec.get("endedAt"):
            out["previous"] = {**rec, "note": "its process is gone; the kernel released its lock"}
        elif rec:
            out["previous"] = rec
        return {"state": "free", **out}
    fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return {"state": "free", **out, "previous": {**rec, "note": "its process id lives on, but it holds no lock"}}
    except BlockingIOError:
        return {"state": "held", **out, **{k: rec.get(k) for k in ("holder", "pid", "startedAt", "command")}}
    finally:
        os.close(fd)


def hold(platform, phone, cmd, wait_s=0, holder=None, say=lambda s: print(s, file=sys.stderr, flush=True),
         net_check=False):
    """Run `cmd` holding the phone's lock for its whole length; returns its exit code.

    `net_check` (iOS, from `rios device verify|run|perf|hold`): the phone must be able to reach Apple
    before the command starts and is checked again after it, however it ended (phone_net.py: CEO,
    2026-10-02, "Unable to Verify App" again). Refused up front with one sentence; a run that left the
    phone's network off gets it put back, and exits 4 if it cannot be."""
    if not cmd:
        raise CannotAnswer("hold runs a command: hold ... -- <command>")
    name, lock, record_path = lock_paths(platform, phone)
    if inside_hold(name):
        return subprocess.call(cmd)
    os.makedirs(os.path.dirname(lock), mode=0o700, exist_ok=True)
    fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
    started, said = time.monotonic(), False
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            who = read_record(record_path) or {}
            waited = time.monotonic() - started
            line = (f"{who.get('holder', 'an unknown holder')} (process {who.get('pid')}, since {who.get('startedAt')}: "
                    f"{who.get('command')})")
            if waited >= wait_s:
                os.close(fd)
                raise Refused(f"the {phone_label(platform, phone)} is in use by {line}; two users of one phone break each "
                              f"other's runs (CEO 2026-10-02). " + (f"Waited {waited:.0f} s. " if wait_s else "") +
                              "Run it again when it is free (`device status` says), or pass --wait SECONDS")
            if not said:
                say(f"waiting up to {wait_s:.0f} s for the {phone_label(platform, phone)}, held by {line}")
                said = True
            time.sleep(min(1.0, max(0.05, wait_s - waited)))
    waited = round(time.monotonic() - started, 1)
    previous = read_record(record_path)
    record = {"holder": holder or holder_name(), "pid": os.getpid(), "startedAt": now_iso(), "command": " ".join(cmd)[:300],
              "platform": platform, "waitedSeconds": waited}
    if previous and not previous.get("endedAt"):
        record["reclaimedFrom"] = {k: previous.get(k) for k in ("holder", "pid", "startedAt", "command")}
        say(f"the previous holder of the {phone_label(platform, phone)}, {previous.get('holder')} (process "
            f"{previous.get('pid')}), ended without releasing it; the kernel released its lock and it is taken now")
    if said:
        say(f"the {phone_label(platform, phone)} is free after {waited} s; taken")
    write_record(record_path, record)
    net_check = net_check and platform == "ios"
    if net_check:
        import phone_net
        try:
            phone_net.preflight(say)
        except phone_net.Unreachable as error:
            record.update(endedAt=now_iso(), exit=3, refused=str(error)[:300])
            write_record(record_path, record)
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
            raise Refused(str(error))
    child = subprocess.Popen(cmd, env={**os.environ, HOLD_ENV: f"{name}:{os.getpid()}"})
    forward = lambda signum, _frame: child.send_signal(signum)
    previous_handlers = {s: signal.signal(s, forward) for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
    code = None
    left = None
    try:
        code = child.wait()
    finally:
        for s, h in previous_handlers.items():
            signal.signal(s, h)
        if net_check:
            left = phone_net.postflight(say)
        record.update(endedAt=now_iso(), exit=code)
        write_record(record_path, record)
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    if left:
        say(left)
        return code if code else 4
    return code


# -- iOS --------------------------------------------------------------------------------------

def ios_configuration(app):
    """'release', 'debug' or None, by the development markers `rios sim check-release` proves: every
    Debug bundle carries all of them, a Release bundle none (perf/ios.py build_configuration)."""
    sys.path.insert(0, str(HERE / "perf"))
    import ios  # noqa: E402 — perf/ios.py, the one definition of the markers
    return ios.build_configuration(app)


def ios_app(app):
    if not os.path.isdir(app):
        raise CannotAnswer(f"no app bundle at {app}")
    found = ios_configuration(app)
    if found != "release":
        raise Refused(f"{app} is {'a Debug' if found == 'debug' else 'not a Release'} bundle (its development "
                      f"markers say so); {RULE}")
    return {"app": app, "configuration": found}


# -- the commit check ---------------------------------------------------------------------------
# A file outside the two command lines must not install on, uninstall from or wipe a phone. The
# command lines may install (release only, checked at run time above) and may never uninstall or
# clear the app's data either. A line can be excused only by `device-cli-exempt: <reason>` on it,
# where a reviewer sees it (a test that plants a forbidden command to prove a refusal).

CLI_FILES = {
    "richos/mobile/native-android/bin/randroid": "the Android command line",
    "richos/mobile/native-android/bin/apk-install.sh": "randroid emu's installer, for its recorded emulator only",
    "richos/mobile/physical.py": "randroid device install: refuses a debuggable APK, installs with install -r",
    "richos/mobile/perf/android.py": "randroid device seed/perf: the debuggable twin installed with install -r and "
                                     "replaced by the release build in the same call",
    "richos/mobile/perf/perf.py": "randroid device perf/seed and rios device perf; refuses a phone without them",
    "richos/mobile/native-ios/bin/rios": "the iPhone command line",
    "richos/mobile/native-ios/Tools/physical-device.mjs": "rios device: Release products only, never removed",
}
NOT_SCANNED = {
    "richos/mobile/physical.py": "this check's own patterns; its own install is the gated one above",
    "richos/engine/reference/": "reference examples from another product, marked not wired and not runnable as-is",
    "docs/verification/": "evidence of past runs: a record, not a path anything runs",
    "richos/engine/docs/verification/": "evidence of past runs: a record, not a path anything runs",
}
TEXT = {".py", ".sh", ".mjs", ".js", ".cjs", ".ts", ".swift", ".kt", ".kts", ".gradle", ".md", ".yml", ".yaml",
        ".toml", ".bash", ".zsh", ""}
EXEMPT = re.compile(r"device-cli-exempt:\s*\S.{8,}")
# A line that asserts the thing does NOT happen (a test of a refusal) is not a path that does it.
ABSENCE = re.compile(r"^\s*assert\b.*\bnot\b|assert\.doesNotMatch|assert\.ok\(\s*!")
CHEAP = re.compile(r"install|Debug-iphoneos|connected|ios-deploy|platform=iOS,|pm\s+clear")
ADB = r"(?<![\w-])adb[\"']?(?:\s+-s\s+\S+)?\s+(?:shell\s+)?(?:pm\s+)?"
# An argument list ("install", apk) counts only on a line that is about the phone's adb.
ADB_CONTEXT = re.compile(r"(?<![\w-])adb(?![\w-])|apk|PACKAGE|dev\.richos|\b(?:dev|phone|device)\.(?:run|sh)\(")
QUOTED = re.compile(r"[\"'](uninstall|install|install-multiple)[\"']")
REMOVES = "removes the app or its data"
INSTALLS = "installs on a phone outside randroid device / rios device"
# (name, pattern, applies inside the command lines too)
RULES = [
    (REMOVES, re.compile(
        ADB + r"(uninstall|clear)\b"
        r"|\bpm\s+(uninstall|clear)\b"
        r"|devicectl\s+device\s+uninstall\b"
        r"|ideviceinstaller[^\n]*?(\s-U\b|--uninstall)"), True),
    (INSTALLS, re.compile(
        ADB + r"install(-multiple)?\b"
        r"|\bpm\s+install\b"
        r"|devicectl\s+device\s+install\b|[\"']devicectl[\"'],\s*[\"']device[\"'],\s*[\"']install[\"']"
        r"|ideviceinstaller[^\n]*?(\s-i\b|--install)"
        r"|\bios-deploy\b"
        r"|platform=iOS,\s*(?:id|name)="), False),
    ("a Gradle task that installs on EVERY attached device, a phone included", re.compile(
        r"(?<![\w-]):?\b(?:install|uninstall)(?:Debug|Release|SeedTwin|All)\w*\b|\bconnected\w*(?:AndroidTest|Check)\b"), True),
    ("a Debug build for a physical iPhone", re.compile(r"Debug-iphoneos"), True),
]


def rule_for(line, inside):
    for name, pattern, everywhere in RULES:
        if (everywhere or not inside) and pattern.search(line):
            return name
    quoted = QUOTED.search(line)
    if quoted and ADB_CONTEXT.search(line):
        if quoted.group(1) == "uninstall":
            return REMOVES
        if not inside:
            return INSTALLS
    return None


def tracked(root):
    p = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True)
    if p.returncode != 0:
        raise CannotAnswer(f"git ls-files failed in {root}")
    return [x for x in p.stdout.decode().split("\0") if x]


def scan_text(path, text):
    """[(line number, rule, line)] for one file's text. In Markdown only the fenced code is read
    (the commands a reader copies), never the prose that describes what a tool does."""
    found = []
    inside = path in CLI_FILES
    markdown = path.endswith(".md")
    fenced = False
    for number, line in enumerate(text.splitlines(), 1):
        if markdown:
            if line.lstrip().startswith("```"):
                fenced = not fenced
                continue
            if not fenced or line.lstrip().startswith("#"):
                continue
        if not CHEAP.search(line) or EXEMPT.search(line) or ABSENCE.search(line):
            continue
        name = rule_for(line, inside)
        if name:
            found.append((number, name, line.strip()[:160]))
    return found


def scan(root, paths=None):
    rows = []
    for path in paths if paths is not None else tracked(root):
        if any(path.startswith(prefix) for prefix in NOT_SCANNED) or os.path.splitext(path)[1] not in TEXT:
            continue
        try:
            data = (Path(root) / path).read_bytes()
        except OSError:
            continue
        if b"\0" in data[:8192]:
            continue
        text = data.decode("utf-8", "replace")
        if CHEAP.search(text):
            rows += [(path, *hit) for hit in scan_text(path, text)]
    return rows


# -- the command line ---------------------------------------------------------------------------

def main(argv):
    if argv[:1] == ["hold"]:
        if "--" not in argv:
            print(json.dumps({"ok": False, "error": "hold --platform P --phone ID [--wait S] -- <command>"}), file=sys.stderr)
            return 2
        cut = argv.index("--")
        q = argparse.ArgumentParser(prog="physical.py hold")
        q.add_argument("--platform", required=True)
        q.add_argument("--phone", default="")
        q.add_argument("--wait", type=float, default=float(os.environ.get("RICHOS_DEVICE_WAIT") or 0))
        q.add_argument("--holder")
        q.add_argument("--net-check", action="store_true")
        h = q.parse_args(argv[1:cut])
        try:
            return hold(h.platform, h.phone, argv[cut + 1:], h.wait, h.holder, net_check=h.net_check)
        except Refused as e:
            print(json.dumps({"ok": False, "refused": str(e)}), file=sys.stderr)
            return 3
        except CannotAnswer as e:
            print(json.dumps({"ok": False, "error": str(e)}), file=sys.stderr)
            return 2
    p = argparse.ArgumentParser(prog="physical.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["android-build", "android-gate", "android-install", "android-record", "ios-app", "scan",
                                       "status"])
    p.add_argument("--platform")
    p.add_argument("--phone", default="")
    p.add_argument("value", nargs="?")
    p.add_argument("--adb", default="adb")
    p.add_argument("--serial")
    p.add_argument("--apk")
    p.add_argument("--aapt2")
    p.add_argument("--out")
    p.add_argument("--seconds", type=int, default=10)
    p.add_argument("--root", default=str(REPO))
    a = p.parse_args(argv)
    try:
        if a.command == "scan":
            rows = scan(a.root)
            for path, number, rule, line in rows:
                print(f"{path}:{number}: {rule}: {line}", file=sys.stderr)
            if rows:
                print(f"REFUSED: {len(rows)} line(s) touch a phone outside `randroid device` / `rios device`, or "
                      f"remove the app or its data. {RULE}; and the app is never uninstalled or wiped (CEO, "
                      "2026-10-01). Go through the command line; a test that plants such a line to prove a refusal "
                      "says `device-cli-exempt: <reason>` on it.", file=sys.stderr)
                return 1
            print("physical.py scan: no phone install, uninstall or wipe outside the command lines")
            return 0
        if a.command == "status":
            result = status(a.platform, a.phone)
        elif a.command == "ios-app":
            if not a.value:
                raise CannotAnswer("ios-app takes the app bundle's path")
            result = ios_app(a.value)
        else:
            if a.command == "android-build":
                result = probe(a.adb, a.serial)
                physical(result)
            elif a.command == "android-gate":
                result = gate(a.adb, a.serial)
            elif a.command == "android-install":
                if not (a.apk and a.aapt2):
                    raise CannotAnswer("android-install needs --apk and --aapt2")
                result = install(a.adb, a.serial, a.apk, a.aapt2)
            else:
                if not a.out:
                    raise CannotAnswer("android-record needs --out FILE.mp4")
                result = record(a.adb, a.serial, a.out, a.seconds)
        print(json.dumps({"ok": True, "result": result}, indent=2))
        return 0
    except Refused as e:
        print(json.dumps({"ok": False, "refused": str(e)}), file=sys.stderr)
        return 3
    except CannotAnswer as e:
        print(json.dumps({"ok": False, "error": str(e)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
