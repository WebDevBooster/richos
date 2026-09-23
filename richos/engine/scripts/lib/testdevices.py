#!/usr/bin/env python3
"""testdevices.py — a simulator or emulator a test made is garbage when the test is over.

CEO, ceo-decisions §54, verbatim: "There now needs to be a ROCK-SOLID,
UNBREAKABLE, UNDEFEATABLE mechanisms that always guarantees that garbage like
this will be always cleaned up afterwards. Or if the clean-up fails or
impossible for some reason, then Rich must get a MASSIVE ALERT about it". And
addendum 4: "Test app windows must always close/quit when testing is finished.
Same hygiene as with any other garbage."

WHY THIS EXISTS. On 2026-09-22 the CEO stopped ten agents from his own screen.
Three iOS simulators their test runs had booted stayed booted after he exited:
two `rios-ui-<pid>-...` from richos/app/scripts/native-ios-ui.test.sh and one
`RichOS native-ios <key>-app` from native-ios-app.test.sh. Each script deletes
its simulator in an EXIT trap, and a killed run never reaches its trap.
appinstances.py, the engine's one definition of a test instance, looks only for
the desktop app's process, so nothing collected them; Rich deleted them by
hand the next session.

THE RULE: OWNERSHIP, NEVER A NAME. A name says which family of tool made a
device; it never says whether anyone is still using it. A device is collected
only when its owner is PROVEN gone, by one of:

  registered owner   the creating script registered the device (or the cache
                     that names it) with its own pid and that pid's start time,
                     and that process no longer exists or is another process
  creator pid        `rios-ui-<pid>-...` names its creator; the pid no longer
                     exists, or it started AFTER the device was created (the
                     number was reused)
  checkout           the per-checkout families (`RichOS native-ios <key>`,
                     `RichOS mobile loop <key>`, `randroid-<key>`) are keyed by
                     a hash of the checkout's path; the device is collected when
                     that key belongs to a checkout the engine RECORDED and that
                     checkout no longer exists (or is being deleted by the land
                     running this), and left alone while it exists

Anything in those families that none of the three can decide is UNDECIDED: it
is never deleted, and while it RUNS it is written to the failure record, which
the disk watchdog raises as the MASSIVE ALERT with the exact command Rich runs
(a shut-down one is reported by the collector and not alerted; see
record_failures). A device
that would not close when collected is recorded the same way. A row resolves
the moment its device no longer exists, however it went. Devices outside the
families (an engineer's own "iPhone 16") are never looked at.

Every simulator command addresses one UDID (never `booted`); an emulator gets a
signal only through the pid its own launcher recorded, and only after its
arguments are read back and still name that AVD.
"""

import argparse
import calendar
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

FAMILY_RIOS_UI = re.compile(r"^rios-ui-(\d+)-")
FAMILY_NATIVE = re.compile(r"^RichOS native-ios ([0-9a-f]{10})(-[a-z]+)?$")
FAMILY_LOOP = re.compile(r"^RichOS mobile loop ([0-9a-f]{10})$")
FAMILY_PLATFORM = re.compile(r"^RichOS native-ios platform-tests ")

COLLECT = "COLLECT"
LEAVE = "LEAVE"
UNDECIDED = "UNDECIDED"


def _env():
    return dict(os.environ, LC_ALL="C", LANG="C", TZ="UTC0")


def _state_base():
    base = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() \
        or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "state")


def registry_dir():
    return (os.environ.get("RICHOS_TEST_DEVICES_DIR") or "").strip() \
        or os.path.join(_state_base(), "test-devices")


def failures_path():
    """Declared in orchestration.config as TEST_DEVICE_FAILURES_STATE and
    resolved here the same way, so the writer and the watchdog cannot drift."""
    return (os.environ.get("TEST_DEVICE_FAILURES_STATE") or "").strip() \
        or os.path.join(_state_base(), "test-device-failures.json")


def workspaces_dir():
    return (os.environ.get("RICHOS_WORKSPACES_DIR") or "").strip() \
        or os.path.join(_state_base(), "workspaces")


def machine_devices_allowed():
    """THE MACHINE'S DEVICES ARE TOUCHED ONLY WITH THE ACCOUNT'S OWN STATE.
    Simulators and emulators belong to the machine, while the records that
    prove who owns one live in a state directory, and every engine suite runs
    with HOME or CLAUDE_CONFIG_DIR redirected into a sandbox. Deciding a REAL
    device against a SANDBOX's records would be deciding it against the wrong
    evidence, so with either redirected the machine's devices are not read at
    all. A suite that means to exercise this module names its own fakes with
    RICHOS_SIMCTL and RICHOS_ANDROID_CACHES_ROOT."""
    try:
        import pwd
        real = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)
    except (ImportError, KeyError):
        return False
    if os.path.realpath(os.path.expanduser("~")) != real:
        return False
    for var, default in (("CLAUDE_CONFIG_DIR", os.path.join(real, ".claude")),
                         ("RICHOS_WORKSPACES_DIR", os.path.join(real, ".claude", "state", "workspaces"))):
        v = (os.environ.get(var) or "").strip()
        if v and os.path.realpath(v) != os.path.realpath(default):
            return False
    return True


def android_caches_root():
    v = (os.environ.get("RICHOS_ANDROID_CACHES_ROOT") or "").strip()
    if v:
        return v
    return "/Volumes/E1TB/caches/richos-native-android" if machine_devices_allowed() else ""


def sim_devices_dir():
    return (os.environ.get("RICHOS_SIM_DEVICES_DIR") or "").strip() or os.path.join(
        os.path.expanduser("~"), "Library", "Developer", "CoreSimulator", "Devices")


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# processes, read from the operating system
# ---------------------------------------------------------------------------

def process_start(pid):
    """The process's start time as `ps -o lstart=` prints it, "" when no such
    process exists, None when it cannot be told."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return None
    if pid <= 0:
        return None
    try:
        r = subprocess.run(["ps", "-o", "stat=,lstart=", "-p", str(pid)], capture_output=True,
                           text=True, timeout=10, env=_env())
    except (OSError, subprocess.TimeoutExpired):
        return None
    stat, _, text = r.stdout.strip().partition(" ")
    text = " ".join(text.split())
    if r.returncode == 0 and stat.startswith("Z"):
        return ""                        # a zombie has ended; only its parent's wait is missing
    if r.returncode == 0 and text:
        return text
    if r.returncode in (0, 1) and not text:
        return ""
    return None


def _epoch(lstart):
    """lstart is read with TZ=UTC0 (see _env), so it is UTC."""
    try:
        return calendar.timegm(time.strptime(lstart, "%a %b %d %H:%M:%S %Y"))
    except (TypeError, ValueError):
        return None


def process_args(pid):
    try:
        r = subprocess.run(["ps", "-ww", "-o", "args=", "-p", str(int(pid))], capture_output=True,
                           text=True, timeout=10, env=_env())
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    return r.stdout.strip() if r.returncode == 0 else ""


def owner_state(owner):
    """('alive'|'gone'|'unknown', why) for a registered {pid, start}."""
    pid = (owner or {}).get("pid")
    st = process_start(pid)
    if st is None:
        return "unknown", "the owner's process (%s) could not be read" % pid
    if st == "":
        return "gone", "its owner, pid %s, no longer exists" % pid
    if owner.get("start") and st != owner["start"]:
        return "gone", "pid %s is now another process (started %s, owner started %s)" % (
            pid, st, owner["start"])
    return "alive", "its owner, pid %s, still runs" % pid


def _by_owner(owner, what):
    st, why = owner_state(owner)
    verdict = {"alive": LEAVE, "gone": COLLECT}.get(st, UNDECIDED)
    return verdict, "%s by %s: %s" % (what, (owner or {}).get("script") or "its test", why)


# ---------------------------------------------------------------------------
# the registry: what a creating script says it made
# ---------------------------------------------------------------------------

KINDS = ("ios-simulator", "ios-cache", "android-cache")


def _record_path(kind, ident):
    h = hashlib.sha1(("%s\0%s" % (kind, ident)).encode("utf-8")).hexdigest()[:16]
    return os.path.join(registry_dir(), "%s-%s.json" % (kind, h))


def _norm(kind, ident):
    return os.path.realpath(ident) if kind.endswith("-cache") else ident.strip()


def register(kind, ident, owner_pid, script=""):
    if kind not in KINDS:
        raise ValueError("kind must be one of %s" % ", ".join(KINDS))
    ident = _norm(kind, ident)
    if not ident:
        raise ValueError("nothing to register")
    start = process_start(owner_pid)
    if not start:
        raise ValueError("the owner pid %s is not a running process" % owner_pid)
    rec = {"kind": kind, "id": ident, "registered_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "owner": {"pid": int(owner_pid), "start": start, "script": script}}
    _write_json(_record_path(kind, ident), rec)
    return rec


def records():
    out = []
    try:
        names = sorted(os.listdir(registry_dir()))
    except OSError:
        return out
    for n in names:
        if n.endswith(".json"):
            r = _read_json(os.path.join(registry_dir(), n))
            if isinstance(r, dict) and r.get("kind") in KINDS and r.get("id"):
                r["_path"] = os.path.join(registry_dir(), n)
                out.append(r)
    return out


# ---------------------------------------------------------------------------
# checkouts the engine has recorded, and the keys their tools derive
# ---------------------------------------------------------------------------

def _sha256_10(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:10]


def _sha1_10(s):
    return hashlib.sha1(s.encode("utf-8")).hexdigest()[:10]


def checkout_keys(path):
    """The keys each per-checkout tool derives from a checkout at `path`:
       suite     native-ios-*.test.sh: shasum -a 256 of the checkout root
       rios      native-ios/bin/rios: of <root>/richos/mobile/native-ios
       loop      mobile/cli/simulator.mjs: of <root>/richos/mobile
       randroid  native-android/bin/randroid: SHA-1 of <root>/richos/mobile/native-android"""
    p = path.rstrip("/")
    return {
        "suite": _sha256_10(p),
        "rios": _sha256_10(p + "/richos/mobile/native-ios"),
        "loop": _sha256_10(p + "/richos/mobile"),
        "randroid": _sha1_10(p + "/richos/mobile/native-android"),
    }


def _git_worktrees(repo):
    try:
        r = subprocess.run(["git", "-C", repo, "worktree", "list", "--porcelain"], capture_output=True,
                           text=True, timeout=20, env=_env())
    except (OSError, subprocess.TimeoutExpired):
        return []
    if r.returncode != 0:
        return []
    return [line[len("worktree "):] for line in r.stdout.splitlines() if line.startswith("worktree ")]


def recorded_checkouts():
    """Every checkout path the engine has a record of: the repositories and their
    current worktrees, and every workspace any agent record ever named."""
    paths = set()
    wd = workspaces_dir()
    repos = _read_json(os.path.join(wd, "repos.json"))
    if isinstance(repos, dict):
        repos = list(repos.keys()) + [v for v in repos.values() if isinstance(v, str)]
    for repo in repos if isinstance(repos, list) else []:
        if isinstance(repo, str) and repo.startswith("/"):
            paths.add(repo)
            for w in _git_worktrees(repo) if os.path.isdir(repo) else []:
                paths.add(w)
    for sub in ("agents", "done"):
        try:
            names = os.listdir(os.path.join(wd, sub))
        except OSError:
            continue
        for n in names:
            rec = _read_json(os.path.join(wd, sub, n))
            for w in (rec or {}).get("workspaces") or []:
                if isinstance(w, dict):
                    for k in ("path", "repo"):
                        v = w.get(k)
                        if isinstance(v, str) and v.startswith("/"):
                            paths.add(v)
    return paths


class Checkouts(object):
    """(family, key) -> (path, exists) for every recorded checkout. Built on the
    first question, so a pass that finds no device in a per-checkout family
    reads no record and runs no git."""

    def __init__(self, departing=()):
        self.departing = set(os.path.realpath(p) for p in departing or () if p)
        self._by_key = None

    @property
    def by_key(self):
        if self._by_key is None:
            self._by_key = self._build()
        return self._by_key

    def _build(self):
        by_key = {}
        for p in recorded_checkouts() | self.departing:
            rp = os.path.realpath(p)
            exists = os.path.isdir(rp) and rp not in self.departing
            for fam, key in checkout_keys(rp).items():
                prev = by_key.get((fam, key))
                # An existing checkout always wins: one live owner is enough.
                if prev is None or (exists and not prev[1]):
                    by_key[(fam, key)] = (rp, exists)
        return by_key

    def decide(self, fam, key):
        hit = self.by_key.get((fam, key))
        if hit is None:
            return UNDECIDED, "no checkout the engine has recorded derives the key %s" % key
        path, exists = hit
        if exists:
            return LEAVE, "its checkout %s exists" % path
        return COLLECT, "its checkout %s no longer exists" % path


# ---------------------------------------------------------------------------
# iOS simulators
# ---------------------------------------------------------------------------

def simctl(*args):
    base = (os.environ.get("RICHOS_SIMCTL") or "").strip()
    cmd = [base] if base else ["xcrun", "simctl"]
    try:
        r = subprocess.run(cmd + list(args), capture_output=True, text=True, timeout=120, env=_env())
    except FileNotFoundError:
        return 127, "", "simctl is not installed"
    except (OSError, subprocess.TimeoutExpired) as e:
        return 124, "", str(e)
    return r.returncode, r.stdout, r.stderr


def ios_devices():
    """[{udid, name, state}], [] where there is no simulator tooling, None when
    the tooling exists and could not be read."""
    if not (os.environ.get("RICHOS_SIMCTL") or "").strip() and (
            sys.platform != "darwin" or not machine_devices_allowed()):
        return []
    rc, out, _err = simctl("list", "devices", "--json")
    if rc == 127:
        return []
    if rc != 0:
        return None
    try:
        groups = (json.loads(out) or {}).get("devices") or {}
    except ValueError:
        return None
    devs = []
    for lst in groups.values():
        for d in lst or []:
            if isinstance(d, dict) and d.get("udid"):
                devs.append({"udid": d["udid"], "name": d.get("name") or "", "state": d.get("state") or ""})
    return devs


def device_created(udid):
    try:
        st = os.stat(os.path.join(sim_devices_dir(), udid))
    except OSError:
        return None
    return getattr(st, "st_birthtime", None) or st.st_mtime


def _cache_record_for(regs, basename, kind):
    for r in regs:
        if r["kind"] == kind and os.path.basename(r["id"].rstrip("/")) == basename:
            return r
    return None


def classify_ios(dev, regs, checkouts):
    """(verdict, why) for one simulator, or (None, '') when it is not ours."""
    name, udid = dev["name"], dev["udid"]
    for r in regs:
        if r["kind"] == "ios-simulator" and r["id"] == udid:
            return _by_owner(r.get("owner"), "registered")
    m = FAMILY_NATIVE.match(name)
    if m:
        r = _cache_record_for(regs, m.group(1) + (m.group(2) or ""), "ios-cache")
        if r:
            return _by_owner(r.get("owner"), "its cache %s was registered" % r["id"])
        return checkouts.decide("suite" if m.group(2) else "rios", m.group(1))
    m = FAMILY_RIOS_UI.match(name)
    if m:
        pid = int(m.group(1))
        st = process_start(pid)
        if st is None:
            return UNDECIDED, "its creator, pid %d, could not be read" % pid
        if st == "":
            return COLLECT, "its creator, pid %d, no longer exists" % pid
        born, started = device_created(udid), _epoch(st)
        if born is None or started is None:
            return UNDECIDED, "pid %d runs, and whether it is the creator cannot be told" % pid
        if started > born + 1:
            return COLLECT, "pid %d started %s, after the device was made: the number was reused" % (pid, st)
        return LEAVE, "its creator, pid %d, still runs" % pid
    m = FAMILY_LOOP.match(name)
    if m:
        return checkouts.decide("loop", m.group(1))
    if FAMILY_PLATFORM.match(name):
        return UNDECIDED, "nothing records which run made it"
    return None, ""


def _ios_remove(dev):
    """(gone, how). Shut down if running, delete, then read the list back."""
    udid = dev["udid"]
    if dev.get("state") and dev["state"] != "Shutdown":
        simctl("shutdown", udid)
    rc, _o, err = simctl("delete", udid)
    after = ios_devices()
    if after is not None and not any(d["udid"] == udid for d in after):
        return True, "shut down and deleted"
    return False, "simctl delete exited %d: %s" % (rc, (err or "").strip()[:200] or "it is still listed")


# ---------------------------------------------------------------------------
# Android emulators — only ones a launcher RECORDED, by the pid it recorded
# ---------------------------------------------------------------------------

def _names_avd(pid, avd):
    a = process_args(pid)
    return bool(a) and ("-avd %s " % avd) in a + " "


def android_emulators(regs):
    """[{pid, avd, cache, key}] for every emulator.json whose recorded process
    still runs AND still has `-avd <avd>` in its arguments."""
    caches = set(r["id"] for r in regs if r["kind"] == "android-cache")
    root = android_caches_root()
    try:
        for n in os.listdir(root) if root else []:
            caches.add(os.path.join(root, n))
    except OSError:
        pass
    out = []
    for c in sorted(caches):
        rec = _read_json(os.path.join(c, "emulator.json"))
        if not isinstance(rec, dict) or not rec.get("pid") or not rec.get("avd"):
            continue
        if not _names_avd(rec["pid"], rec["avd"]):
            continue
        out.append({"pid": int(rec["pid"]), "avd": rec["avd"], "cache": c, "key": os.path.basename(c),
                    "name": rec["avd"], "state": "Running"})
    return out


def classify_android(emu, regs, checkouts):
    r = _cache_record_for(regs, emu["key"], "android-cache")
    if r:
        return _by_owner(r.get("owner"), "its cache was registered")
    return checkouts.decide("randroid", emu["key"])


def _android_remove(emu):
    pid, avd = emu["pid"], emu["avd"]
    for sig, wait in ((signal.SIGTERM, 15.0), (signal.SIGKILL, 5.0)):
        if not _names_avd(pid, avd):
            break
        try:
            os.kill(pid, sig)
        except OSError:
            pass
        deadline = time.time() + wait
        while time.time() < deadline and process_start(pid):
            time.sleep(0.2)
    if process_start(pid):
        return False, "pid %d survived SIGTERM and SIGKILL" % pid
    try:
        shutil.rmtree(os.path.join(emu["cache"], "avd"), ignore_errors=True)
        rec = os.path.join(emu["cache"], "emulator.json")
        if os.path.exists(rec):
            os.unlink(rec)
    except OSError as e:
        return False, "the emulator ended but its AVD could not be removed: %s" % e
    return True, "ended and its AVD removed"


# ---------------------------------------------------------------------------
# the one entry point, and the durable failure record
# ---------------------------------------------------------------------------

def _command(kind, d):
    if kind == "ios":
        return "xcrun simctl shutdown %s; xcrun simctl delete %s" % (d["udid"], d["udid"])
    return "kill %d   (after checking that ps -o args= -p %d still names -avd %s)" % (d["pid"], d["pid"], d["avd"])


def collect(apply=False, departing=(), deadline=None):
    """Classify every device in our families; remove the proven-orphaned ones.

    {"collected", "survivors", "left", "undecided", "deferred", "notes"}.
    `deadline` (epoch seconds) bounds the removals: what is not reached stays
    for the next pass and is reported as deferred, never dropped."""
    res = {"collected": [], "survivors": [], "left": [], "undecided": [], "deferred": [], "notes": []}
    regs = records()
    checkouts = Checkouts(departing)
    seen = {"ios": None, "ios_names": set(), "android": set()}
    devs = ios_devices()
    if devs is None:
        res["notes"].append("the simulator list could not be read; iOS devices were not checked")
    else:
        seen["ios"] = set(d["udid"] for d in devs)
        seen["ios_names"] = set(d["name"] for d in devs)
    work = [("ios", d, classify_ios(d, regs, checkouts)) for d in devs or []]
    for e in android_emulators(regs):
        seen["android"].add(e["pid"])
        work.append(("android", e, classify_android(e, regs, checkouts)))
    for kind, d, (verdict, why) in work:
        if verdict is None:
            continue
        row = {"kind": kind, "id": d.get("udid") or d.get("pid"), "name": d["name"], "state": d.get("state"),
               "why": why, "command": _command(kind, d)}
        if verdict == LEAVE:
            res["left"].append(row)
        elif verdict == UNDECIDED:
            res["undecided"].append(row)
        elif not apply:
            row["how"] = "would be removed (dry run)"
            res["collected"].append(row)
        elif deadline is not None and time.time() >= deadline:
            row["how"] = "not reached inside this pass's budget; the next pass collects it"
            res["deferred"].append(row)
        else:
            gone, how = (_ios_remove if kind == "ios" else _android_remove)(d)
            row["how"] = how
            (res["collected"] if gone else res["survivors"]).append(row)
            if gone and kind == "ios":
                seen["ios"].discard(d["udid"])
                seen["ios_names"].discard(d["name"])
    if apply:
        _prune_registry(regs, seen)
        res["standing"] = record_failures(res["survivors"], res["undecided"], seen)
    return res


def _prune_registry(regs, seen):
    """A record whose device is gone and whose owner is gone has nothing left to
    say. One whose owner still runs stays: its test may not have booted yet."""
    for r in regs:
        if owner_state(r.get("owner"))[0] != "gone":
            continue
        if r["kind"] == "ios-simulator":
            if seen["ios"] is None or r["id"] in seen["ios"]:
                continue
        elif r["kind"] == "ios-cache":
            if seen["ios"] is None or \
                    ("RichOS native-ios " + os.path.basename(r["id"].rstrip("/"))) in seen["ios_names"]:
                continue
        elif r["kind"] == "android-cache":
            rec = _read_json(os.path.join(r["id"], "emulator.json"))
            if isinstance(rec, dict) and rec.get("pid") in seen["android"]:
                continue
        try:
            os.unlink(r["_path"])
        except OSError:
            pass


def read_failures(path=None):
    rows = _read_json(path or failures_path())
    return rows if isinstance(rows, dict) else {}


def record_failures(survivors, undecided, seen, path=None):
    """Carry every device that could not be collected, or whose owner cannot be
    proven; drop every row whose device no longer exists, or that this pass
    decided after all. A listing that could not be read resolves nothing."""
    path = path or failures_path()
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    rows = read_failures(path)
    live = {}
    for verdict, lst in (("would not close", survivors), ("owner cannot be proven", undecided)):
        for d in lst or []:
            # AN UNPROVEN OWNER IS ALERTED ONLY WHILE THE DEVICE RUNS. A running
            # simulator or emulator is what kept the Mac at 100% on 2026-09-22;
            # a shut-down one whose checkout nothing recorded costs disk, which
            # the disk alert already watches, and nine of them sat on this
            # machine when this was written (`RichOS mobile loop <key>` from
            # checkouts no record names). Alerting on those would put a
            # permanent nine-row block in front of the one row that matters.
            # They stay in the collector's output and log as UNDECIDED.
            if verdict == "owner cannot be proven" and d.get("state") == "Shutdown":
                continue
            live["%s:%s" % (d["kind"], d["id"])] = (verdict, d)
    for key in list(rows):
        if key in live:
            continue
        kind, _, ident = key.partition(":")
        if kind == "ios" and seen["ios"] is None:
            continue                    # nothing was read, so nothing is resolved
        del rows[key]
    for key, (verdict, d) in live.items():
        prev = rows.get(key) or {}
        rows[key] = {"kind": d["kind"], "id": d["id"], "name": d["name"], "verdict": verdict,
                     "why": d.get("how") or d.get("why") or "?", "command": d["command"],
                     "first": prev.get("first") or stamp, "last": stamp,
                     "attempts": int(prev.get("attempts") or 0) + 1}
    if rows:
        _write_json(path, rows)
    elif os.path.exists(path):
        try:
            os.unlink(path)
        except OSError:
            _write_json(path, {})
    return rows


def _main(argv):
    ap = argparse.ArgumentParser(description="Test simulators and emulators: register, find, collect.")
    sub = ap.add_subparsers(dest="cmd")
    r = sub.add_parser("register", help="record that the calling test owns a device, or the cache naming it")
    r.add_argument("--kind", required=True, choices=KINDS)
    r.add_argument("--id", required=True, help="a simulator UDID, or a cache directory")
    r.add_argument("--owner-pid", type=int, default=os.getppid())
    r.add_argument("--script", default="")
    c = sub.add_parser("collect", help="report (default) or remove (--apply) orphaned test devices")
    c.add_argument("--apply", action="store_true")
    c.add_argument("--json", action="store_true")
    c.add_argument("--departing", action="append", default=[],
                   help="a checkout being deleted right now: treat it as gone")
    c.add_argument("--budget", type=float, default=0.0, help="seconds for removals (0 = unbounded)")
    a = ap.parse_args(argv)
    if a.cmd == "register":
        try:
            register(a.kind, a.id, a.owner_pid, a.script)
        except ValueError as e:
            sys.stderr.write("testdevices: %s\n" % e)
            return 2
        return 0
    if a.cmd != "collect":
        ap.print_help()
        return 2
    res = collect(apply=a.apply, departing=a.departing,
                  deadline=(time.time() + a.budget) if a.budget > 0 else None)
    if a.json:
        print(json.dumps(res, indent=2, sort_keys=True, default=str))
    else:
        for n in res["notes"]:
            print("NOTE         %s" % n)
        for key in ("collected", "survivors", "undecided", "deferred", "left"):
            for d in res[key]:
                print("%-12s %s %s (%s): %s" % (key.upper(), d["kind"], d["id"], d["name"],
                                                d.get("how") or d["why"]))
        print("verdict: collected=%d survivors=%d undecided=%d deferred=%d left=%d"
              % tuple(len(res[k]) for k in ("collected", "survivors", "undecided", "deferred", "left")))
    if res["survivors"] or res["notes"]:
        return 1
    if res["undecided"]:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
