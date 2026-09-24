"""ios — RichConnect measurement on an iOS simulator or iPhone.

WRITTEN, NOT YET RUN (2026-09-24). No simulator was booted and no iPhone was attached when this
was written (the brief reserved the night's one simulator run for another stream; the test iPhone
arrives 2026-09-25). Every parser below is exercised by richos/app/scripts/mobile-perf.test.py
against output SHAPED like the tools' documented output, not against captured output; the record
says `"ranOnHardware": false` until a first run replaces that with evidence.

THE LAUNCH MARKERS IMPLEMENTED IN THE APP (Sage review 2026-09-24 T5). The iPhone app draws `Color.clear`
until the saved state has loaded (native-ios/App/App/RichOSNativeApp.swift, the `else` branch of
`if let store`), so a first-frame launch metric would pass a blank screen. The end mark is a
signpost the app emits once the saved transcript is on screen and the composer accepts input:

    import os
    private let perfLog = OSLog(subsystem: "dev.richos.connect", category: .pointsOfInterest)
    os_signpost(.event, log: perfLog, name: "useful-content")      // once per launch
    os_signpost(.event, log: perfLog, name: "foreground-useful")   // each return to .active

Where: `useful-content` in RootView's conversation (or pairing, when unpaired) screen, on the
first appearance of the composer AFTER `store` is set (RichOSNativeApp.swift, the `RootView(...)`
branch), never at `store = loaded` in the `.task`; `foreground-useful` in the `.active` case of
`.onChange(of: scenePhase)` once the retained screen has drawn. Both are release-safe, add no
polling and no network. The app now emits these from UsefulFrameMarker after loading. Physical capture and frame-presentation correlation remain unverified.

What it measures today, given a simulator UDID (never `booted`) or an iPhone's UDID:
  identity      the installed bundle's files hashed (simulator), compared with the stamp
  cold launch   simctl terminate + launch; the `useful-content` signpost's time in the device log
                minus the host's time just before the launch request (simulator: one clock, the
                Mac's); an iPhone uses `xctrace record --template 'App Launch' --launch` and the
                signpost's time from launch in the trace's os-signpost table
  background    simulator only: the app is a Mac process, so over the window its idle wakeups,
                context switches and CPU time come from `top -l 1 -pid` (cumulative, differenced)
                and its bytes from `nettop -P -L 1 -p`; an iPhone needs Instruments' Activity
                Monitor or Power Profiler (not parsed here; NOT MEASURED)
"""
import datetime
import json
import os
import re
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

import perfcore
from perfcore import Refused, Unmeasurable

BUNDLE = "dev.richos.connect"
SUBSYSTEM = "dev.richos.connect"
USEFUL = "useful-content"
FOREGROUND = "foreground-useful"


def run(cmd, runner=subprocess.run, timeout=120):
    p = runner(cmd, capture_output=True, text=True, timeout=timeout)
    if p.returncode:
        raise Unmeasurable(f"{' '.join(cmd[:4])} exited {p.returncode}: {(p.stderr or p.stdout).strip()[:200]}")
    return p.stdout


def simulator(listing, udid):
    """`xcrun simctl list devices -j` → the named simulator, which must be booted."""
    if udid.lower() == "booted":
        raise Refused("a simulator is named by its UDID, never 'booted' (another test's simulator may be booted)")
    data = json.loads(listing)
    for runtime, devices in data.get("devices", {}).items():
        for d in devices:
            if d.get("udid") == udid:
                if d.get("state") != "Booted":
                    raise Refused(f"simulator {udid} is {d.get('state')}, not Booted")
                return {"kind": "simulator", "udid": udid, "model": d.get("name"),
                        "os": runtime.rsplit(".", 1)[-1].replace("iOS-", "iOS ").replace("-", ".")}
    raise Refused(f"no simulator {udid}")


def physical(listing, udid):
    """`xcrun devicectl list devices --json-output` → the named iPhone."""
    data = json.loads(listing)
    for d in (data.get("result") or {}).get("devices", []):
        hw = d.get("hardwareProperties") or {}
        if udid in (d.get("identifier"), hw.get("udid")):
            props = d.get("deviceProperties") or {}
            return {"kind": "physical", "udid": udid, "model": hw.get("marketingName") or hw.get("productType"),
                    "os": f"iOS {props.get('osVersionNumber')}"}
    raise Refused(f"no iPhone {udid} in devicectl's list")


def parse_log_marks(ndjson, name):
    """`log show --style ndjson --signpost` lines → timestamps (UTC epoch seconds) of mark `name`."""
    marks = []
    for line in ndjson.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("subsystem") != SUBSYSTEM:
            continue
        if entry.get("signpostName") != name and entry.get("eventMessage") != name:
            continue
        stamp = entry.get("timestamp", "")
        try:
            when = datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f%z")
        except ValueError:
            continue
        marks.append(when.timestamp())
    return marks


def parse_top(text):
    """`top -l 1 -pid P -stats pid,idlew,csw,time` → {"idleWakeups", "switches", "cpuSeconds"}."""
    lines = [l for l in text.splitlines() if l.strip()]
    for i, line in enumerate(lines):
        if line.split()[:4] == ["PID", "IDLEW", "CSW", "TIME"] and i + 1 < len(lines):
            cols = lines[i + 1].split()
            parts = [float(x) for x in cols[3].split(":")]
            seconds = 0.0
            for part in parts:
                seconds = seconds * 60 + part
            return {"idleWakeups": int(re.sub(r"\D", "", cols[1])), "switches": int(re.sub(r"\D", "", cols[2])),
                    "cpuSeconds": seconds}
    raise Unmeasurable("top printed no PID IDLEW CSW TIME row")


def parse_nettop(text, pid):
    """`nettop -P -L 1 -p PID -J bytes_in,bytes_out -x` CSV → total bytes for the process."""
    total = 0
    found = False
    for line in text.splitlines():
        cols = line.split(",")
        if len(cols) >= 3 and cols[0].endswith(f".{pid}"):
            total += int(cols[1] or 0) + int(cols[2] or 0)
            found = True
    return total if found else 0


def parse_launchctl_pid(text):
    """`simctl spawn <udid> launchctl list` → the app's pid (label UIKitApplication:dev.richos.connect[...])."""
    for line in text.splitlines():
        cols = line.split("\t") if "\t" in line else line.split()
        if len(cols) >= 3 and f"UIKitApplication:{BUNDLE}[" in cols[2] and cols[0].isdigit():
            return int(cols[0])
    return None


def parse_xctrace_signposts(xml_text, name):
    """An exported os-signpost table → event times (ns from trace start) of signpost `name`. The
    export dedupes repeated values by id/ref; both forms are resolved."""
    root = ET.fromstring(xml_text)
    refs = {}
    for el in root.iter():
        if el.get("id") is not None:
            refs[el.get("id")] = el
    times = []
    for row in root.iter("row"):
        def val(tag):
            el = row.find(tag)
            if el is None:
                return None
            if el.get("ref") is not None:
                el = refs.get(el.get("ref"), el)
            return el.text
        if val("name") == name or val("signpost-name") == name:
            t = val("event-time") or val("start-time")
            if t is not None:
                times.append(int(t))
    return times


class Sim:
    def __init__(self, udid, runner=subprocess.run, sleep=time.sleep, clock=time.time):
        self.udid, self.runner, self.sleep, self.clock = udid, runner, sleep, clock

    def simctl(self, *args, timeout=120):
        return run(["xcrun", "simctl", *args], self.runner, timeout)

    def since(self, t):
        return datetime.datetime.fromtimestamp(t - 1).strftime("%Y-%m-%d %H:%M:%S")

    def marks(self, name, since):
        out = self.simctl("spawn", self.udid, "log", "show", "--style", "ndjson", "--signpost", "--start", self.since(since),
                          "--predicate", f'subsystem == "{SUBSYSTEM}"')
        return [m for m in parse_log_marks(out, name) if m >= since]

    def cold(self, trials):
        samples, rejected = [], []
        for i in range(trials):
            self.runner(["xcrun", "simctl", "terminate", self.udid, BUNDLE], capture_output=True, text=True)
            self.sleep(1.0)
            t0 = self.clock()
            self.simctl("launch", self.udid, BUNDLE)
            mark = None
            for _ in range(40):
                found = self.marks(USEFUL, t0)
                if found:
                    mark = found[0]
                    break
                self.sleep(0.25)
            if mark is None:
                rejected.append({"trial": i + 1, "why": f"no '{USEFUL}' signpost within 10 s (the app does not emit it yet?)"})
                continue
            samples.append(round((mark - t0) * 1000))
            self.sleep(2.0)
        return samples, rejected

    def pid(self):
        return parse_launchctl_pid(self.simctl("spawn", self.udid, "launchctl", "list"))

    def background(self, seconds, settle_s):
        pid = self.pid()
        if pid is None:
            raise Unmeasurable("the app is not running on the simulator")
        self.simctl("launch", self.udid, "com.apple.Preferences")  # the app goes to the background
        self.sleep(settle_s)

        def sample():
            top = parse_top(run(["top", "-l", "1", "-pid", str(pid), "-stats", "pid,idlew,csw,time"], self.runner))
            net = parse_nettop(run(["nettop", "-P", "-L", "1", "-p", str(pid), "-J", "bytes_in,bytes_out", "-x"], self.runner), pid)
            return top, net
        (a, na), _ = sample(), self.sleep(seconds)
        b, nb = sample()
        return {"seconds": seconds, "settleSeconds": settle_s, "pid": pid,
                "idleWakeups": b["idleWakeups"] - a["idleWakeups"], "contextSwitches": b["switches"] - a["switches"],
                "cpuMs": round((b["cpuSeconds"] - a["cpuSeconds"]) * 1000), "networkBytes": nb - na}


def device_cold(udid, trials, runner=subprocess.run):
    """Cold launches on an iPhone through Instruments' App Launch template (one trace per trial)."""
    samples, rejected = [], []
    for i in range(trials):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
            trace = os.path.join(tmp, "launch.trace")
            try:
                run(["xcrun", "xctrace", "record", "--template", "App Launch", "--device", udid, "--time-limit", "15s",
                     "--output", trace, "--launch", "--", BUNDLE], runner, timeout=120)
                xml_text = run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                                '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]'], runner)
                times = parse_xctrace_signposts(xml_text, USEFUL)
            except (Unmeasurable, ET.ParseError) as e:
                rejected.append({"trial": i + 1, "why": str(e)})
                continue
        if not times:
            rejected.append({"trial": i + 1, "why": f"no '{USEFUL}' signpost in the trace (the app does not emit it yet?)"})
            continue
        samples.append(round(times[0] / 1e6))
    return samples, rejected


def run_ios(args, runner=subprocess.run):
    """perf.py ios. Returns (record, failures)."""
    stamp = None
    if args.stamp:
        with open(args.stamp) as f:
            stamp = json.load(f)
    if args.expect_commit and (not stamp or not str(stamp.get("commit", "")).startswith(args.expect_commit) or stamp.get("dirty")):
        raise Refused(f"freshness mismatch: the stamp is {stamp and stamp.get('commit')} (dirty {stamp and stamp.get('dirty')}), not {args.expect_commit}")
    record = {"schema": perfcore.SCHEMA, "platform": "ios", "startedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
              "ranOnHardware": False, "metrics": {}, "phases": {}, "notMeasured": [],
              "route": {"name": "as installed", "detail": "whatever state the installed app holds"}}
    failures = 0
    if args.simulator:
        record["device"] = simulator(run(["xcrun", "simctl", "list", "devices", "-j"], runner), args.simulator)
        container = run(["xcrun", "simctl", "get_app_container", args.simulator, BUNDLE, "app"], runner).strip()
        installed = perfcore.tree_sha256(container)
        if stamp and installed != stamp.get("sha256"):
            raise Refused(f"freshness mismatch: the installed app is {installed[:12]}…, the stamped build {str(stamp.get('sha256'))[:12]}…")
        record["build"] = {"bundle": BUNDLE, "commit": stamp and stamp.get("commit"), "dirty": stamp and stamp.get("dirty"),
                           "installedSha256": installed, "builtSha256": stamp and stamp.get("sha256")}
        sim = Sim(args.simulator, runner)
        samples, rejected = sim.cold(args.cold)
        if samples:
            record["metrics"]["coldLaunch"] = {"method": "simctl terminate; host clock before simctl launch to the app's "
                                               "'useful-content' signpost in the simulator log (one clock: the Mac's). "
                                               "Includes simctl's own launch overhead",
                                               "samplesMs": samples, "stats": perfcore.stats(samples),
                                               "budget": perfcore.compare("coldLaunch", perfcore.stats(samples)), "rejected": rejected}
        else:
            failures += 1
            record["notMeasured"].append({"what": "coldLaunch", "why": "; ".join(r["why"] for r in rejected[:1]) or "no trial"})
        try:
            record["metrics"]["backgroundQuiet"] = {"method": "the simulated app is a Mac process: top idle wakeups, "
                                                    "context switches and CPU time, nettop bytes, differenced over the window",
                                                    **sim.background(args.background_seconds, args.background_settle)}
        except Unmeasurable as e:
            failures += 1
            record["notMeasured"].append({"what": "backgroundQuiet", "why": str(e)})
    else:
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "devices.json")
            run(["xcrun", "devicectl", "list", "devices", "--json-output", out], runner)
            with open(out) as f:
                record["device"] = physical(f.read(), args.device)
        record["build"] = {"bundle": BUNDLE, "commit": stamp and stamp.get("commit"), "dirty": stamp and stamp.get("dirty"),
                           "note": "an iPhone's installed bundle cannot be read back; identity is the stamp of what was installed"}
        samples, rejected = device_cold(args.device, args.cold, runner)
        if samples:
            record["metrics"]["coldLaunch"] = {
                "method": "xctrace record --template 'App Launch' --launch (the trace starts at the launch request) to "
                          "the app's 'useful-content' signpost in the exported os-signpost table. UNVERIFIED until the "
                          "first iPhone run: the export's shape is from Apple's documentation, not a captured trace",
                "parserVerified": False, "samplesMs": samples, "stats": perfcore.stats(samples),
                "budget": perfcore.compare("coldLaunch", perfcore.stats(samples)), "rejected": rejected}
        else:
            failures += 1
            record["notMeasured"].append({"what": "coldLaunch on an iPhone", "why": "; ".join(r["why"] for r in rejected[:1]) or "no trial"})
    record["notMeasured"].extend(ios_gaps())
    record["acceptance"] = perfcore.acceptance(record["device"]["kind"], False, len((record["metrics"].get("coldLaunch") or {}).get("samplesMs") or []))
    record["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return record, failures


def ios_gaps():
    return [
        {"what": "useful-content and foreground-useful signposts",
         "why": "the iPhone app emits neither yet; see this module's header for the exact code and where it goes "
                "(RichOSNativeApp.swift RootView branch and the .active case)"},
        {"what": "warmResume", "why": "needs the foreground-useful signpost; then the cold method with Preferences "
                                      "launched in between instead of terminate"},
        {"what": "tapToFeedback, sendToQueued, receiveToVisible, activeFrames",
         "why": "need an XCUITest harness in native-ios/UITests driving the real controls with XCTOSSignpostMetric "
                "around app-emitted signposts; not written"},
        {"what": "idleFrames", "why": "iOS has no gfxinfo; on an iPhone, Instruments' Animation Hitches template "
                                      "(xctrace) over an untouched window; not parsed here"},
        {"what": "background on an iPhone and energy",
         "why": "Instruments' Activity Monitor / Power Profiler templates (xctrace record --attach) and Settings > "
                "Battery over the PRD §8 windows; not parsed here"},
    ]

