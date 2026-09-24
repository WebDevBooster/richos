"""ios — RichConnect measurement on an iOS simulator or iPhone.

Physical capture was first exercised on iPhone SE (2nd generation), iOS 26.3.1,
with Xcode 26.3 on 2026-09-24. App Launch alone does not collect the app's
signposts: add the os_signpost instrument explicitly. Retain each raw trace.

Cold launch and warm return (PRD §7) end where the PRD puts them: the saved
viewport PRESENTED and the composer accepting input. The app marks when its
transcript applied its saved position and its editable field exists, then
`input-ready` once the main run loop committed that turn and went idle. The tool
joins those marks, on the trace's one clock and by process ID, to the Core
Animation commit that carried them, to the first frame whose server render
began after that commit (Frame Lifetimes) and to the display swap that showed
it. A useful draw alone is not the endpoint: on the first physical trace it came
one commit before the transcript's final scroll position.

Simulator frame records are not a display pipeline (a swap can precede its own
render), so a simulator trace proves the capture, marks and join, never a phone
number. Simulator timing without --xctrace uses the host launch command and the
device log on the Mac's clock. Simulator background observations use the
simulated process's CPU and network use, not physical iPhone energy.
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
# The app's PRD §7 end marks (native-ios/App/Platform/PerformanceMarks.swift, ReadinessMarks).
VIEWPORT = "viewport-ready"
COMPOSER = "composer-ready"
READY = "input-ready"
CORE_ANIMATION = "com.apple.coreanimation"
PROCESS_CREATION = "Initializing - Process Creation"
# Every table a launch or return sample reads; each export must carry its own schema.
TABLES = ("life-cycle-period", "os-signpost", "coreanimation-lifetime-interval", "display-surface-swap")
# Xcode 26.3's trace loader crashes on about one load in seven (SIGSEGV or a Swift trap in
# InstrumentsPlugIn FileStatus, during ProcessLoader.load) before any table is read. An export is
# a pure read of an immutable trace, so a signal death is re-read; every attempt is recorded.
EXPORT_ATTEMPTS = 5
EXPORT_PAUSE_S = 2.0
# Frame Lifetimes' end and the display's swap timestamp for the same swap agree to tens of ns.
SWAP_TOLERANCE_NS = 100_000
# Simulator.swift `developmentMarkers`: every Debug bundle carries all of them, Release none.
DEVELOPMENT_MARKERS = ["rios-commands", "rios-fixture", "rios-interactive-fixture", "rios-appearance",
                       "compose-draft", "Henderson proposal"]


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


def trace_useful_draw(lifecycle_xml, signposts_xml):
    """Join two real xctrace tables by target PID, never assume trace zero is launch."""
    def rows(xml):
        root = ET.fromstring(xml)
        refs = {e.get("id"): e for e in root.iter() if e.get("id") is not None}
        def resolve(e):
            return refs.get(e.get("ref"), e) if e is not None else None
        for row in root.iter("row"):
            values = {e.tag: resolve(e) for e in row}
            process = values.get("process")
            pid = resolve(process.find("pid")) if process is not None else None
            yield values, int(pid.text) if pid is not None else None
    starts = []
    for values, pid in rows(lifecycle_xml):
        if values.get("app-period") is not None and values["app-period"].text == "Initializing - Process Creation":
            starts.append((pid, int(values["start-time"].text)))
    if len(starts) != 1 or starts[0][0] is None:
        raise Unmeasurable("expected exactly one process creation in the target lifecycle table")
    pid, start = starts[0]
    ends = []
    for values, row_pid in rows(signposts_xml):
        if (row_pid == pid and values.get("subsystem") is not None and values["subsystem"].text == SUBSYSTEM
                and values.get("signpost-name") is not None and values["signpost-name"].text == USEFUL
                and values.get("event-type") is not None and values["event-type"].text == "Event"):
            ends.append(int(values["event-time"].text))
    if len(ends) != 1 or ends[0] <= start:
        raise Unmeasurable("expected one useful-content event after creation in the same process")
    return {"pid": pid, "creationNs": start, "usefulDrawNs": ends[0], "durationMs": (ends[0] - start) / 1e6}


# ---------------------------------------------------------------------------------------------
# PRD §7 end marks: the frame that presented the ready content, and the main thread idle after it
# ---------------------------------------------------------------------------------------------

def _table(xml_text, schema):
    """One exported table as rows of {column mnemonic: element}, id/ref resolved across the export.
    Refuses an export without its schema: Frame Lifetimes and display swaps repeat engineering
    types, so reading their columns by position would be a guess. (An export of several tables
    carries the schema on the first table only, which is why each table is exported alone.)"""
    root = ET.fromstring(xml_text)
    refs = {e.get("id"): e for e in root.iter() if e.get("id") is not None}

    def resolve(e):
        return refs.get(e.get("ref"), e) if e is not None and e.get("ref") is not None else e
    nodes = root.findall("node")
    if len(nodes) != 1:
        raise Unmeasurable(f"expected one exported {schema} table, found {len(nodes)} (was it recorded?)")
    found = nodes[0].find("schema")
    if found is None or found.get("name") != schema:
        raise Unmeasurable(f"the {schema} export carries no {schema} schema")
    cols = [c.findtext("mnemonic") for c in found.findall("col")]
    rows = []
    for row in nodes[0].findall("row"):
        cells = list(row)
        if len(cells) != len(cols):
            raise Unmeasurable(f"a {schema} row has {len(cells)} cells for {len(cols)} columns")
        rows.append({c: resolve(e) for c, e in zip(cols, cells)})
    return rows, resolve


def _text(e):
    return None if e is None or e.tag == "sentinel" else e.text


def _int(e):
    t = _text(e)
    return int(t) if t not in (None, "") else None


def _pid(resolve, e):
    e = resolve(e)
    if e is not None and e.tag == "thread":
        e = resolve(e.find("process"))
    if e is None or e.tag == "sentinel":
        return None
    p = resolve(e.find("pid"))
    return int(p.text) if p is not None and p.text else None


def signposts(xml_text):
    """os-signpost → [{ns, pid, main, subsystem, name, type, message}]; `main` is the main thread."""
    rows, resolve = _table(xml_text, "os-signpost")

    def message(e):
        return None if e is None or e.tag == "sentinel" else (e.get("fmt") or e.text)
    return [{"ns": _int(r.get("time")), "pid": _pid(resolve, r.get("process")),
             "main": r.get("thread") is not None and (r["thread"].get("fmt") or "").startswith("Main Thread"),
             "subsystem": _text(r.get("subsystem")), "name": _text(r.get("name")), "type": _text(r.get("event-type")),
             "message": message(r.get("message"))}
            for r in rows]


def lifecycle(xml_text):
    """life-cycle-period → [{start, duration, pid, period}] (trace clock, ns)."""
    rows, resolve = _table(xml_text, "life-cycle-period")
    return [{"start": _int(r.get("start")), "duration": _int(r.get("duration")), "pid": _pid(resolve, r.get("process")),
             "period": _text(r.get("period"))} for r in rows]


def frame_lifetimes(xml_text):
    """coreanimation-lifetime-interval → [{start, duration, swapId, renderStart}], complete rows only."""
    rows, _ = _table(xml_text, "coreanimation-lifetime-interval")
    out = []
    for r in rows:
        f = {"start": _int(r.get("start")), "duration": _int(r.get("duration")), "swapId": _int(r.get("swap-id")),
             "renderStart": _int(r.get("render-start"))}
        if None not in f.values():
            out.append(f)
    return out


def display_swaps(xml_text):
    """display-surface-swap → [{ns, swapId}]: the moment the display showed each surface."""
    rows, _ = _table(xml_text, "display-surface-swap")
    return [{"ns": _int(r.get("timestamp")), "swapId": _int(r.get("swap-id"))} for r in rows]


def presented_ready(marks, frames, swaps, pid, after_ns, content):
    """PRD §7's end on one trace clock. `input-ready` must occur exactly once in process `pid` after
    `after_ns`, preceded by every `content` mark. The carrying commit is the first main-thread Core
    Animation commit to END at or after the latest content mark (Core Animation sends a transaction
    when its commit ends), and it must end no later than `input-ready`, which the app emits after
    that commit. The presented frame is the first frame whose server render STARTED at or after
    that commit's end: a render that began earlier cannot contain it. Its presentation is the
    display's swap time, which must agree with that frame lifetime's end. The end is the later of
    presentation and `input-ready`. Any missing or ambiguous step rejects the sample."""
    mine = [m for m in marks if m["pid"] == pid and m["ns"] is not None and m["ns"] >= after_ns]

    def ours(name):
        return sorted(m["ns"] for m in mine if m["subsystem"] == SUBSYSTEM and m["name"] == name and m["type"] == "Event")
    ready = ours(READY)
    if len(ready) != 1:
        raise Unmeasurable(f"expected exactly one '{READY}' in process {pid} after the start, found {len(ready)}")
    r = ready[0]
    content_ns = {}
    for name in content:
        before = [t for t in ours(name) if t <= r]
        if not before:
            raise Unmeasurable(f"no '{name}' before '{READY}' in process {pid}")
        content_ns[name] = before[-1]
    commit = carrying_commit(marks, pid, max(content_ns.values(), default=after_ns), until_ns=r)
    frame = presented_frame(frames, swaps, commit)
    return {"pid": pid, "contentNs": content_ns, "commitEndNs": commit, **frame, "inputReadyNs": r,
            "endNs": max(frame["presentedNs"], r)}


def carrying_commit(marks, pid, content_ns, until_ns=None):
    """The end of the first main-thread Core Animation commit in `pid` ending at or after
    `content_ns` (and, if given, no later than `until_ns`)."""
    ends = sorted(m["ns"] for m in marks if m["pid"] == pid and m["main"] and m["subsystem"] == CORE_ANIMATION
                  and m["name"] == "Commit" and m["type"] == "End" and m["ns"] is not None and m["ns"] >= content_ns)
    if not ends or (until_ns is not None and ends[0] > until_ns):
        raise Unmeasurable(f"no main-thread Core Animation commit ended between the ready content and '{READY}'")
    return ends[0]


def presented_frame(frames, swaps, commit_end_ns):
    """The first frame whose server render started at or after `commit_end_ns`, and the display
    swap that showed it (which must agree with that frame lifetime's end)."""
    later = sorted((f for f in frames if f["renderStart"] >= commit_end_ns), key=lambda f: f["renderStart"])
    if not later:
        raise Unmeasurable("no frame began rendering after the carrying commit before the trace ended "
                           "(no Frame Lifetimes data, or the trace is too short)")
    if len(later) > 1 and later[1]["renderStart"] == later[0]["renderStart"]:
        raise Unmeasurable("two frames began rendering at the same instant; the presented frame is ambiguous")
    frame = later[0]
    swap = [s for s in swaps if s["swapId"] == frame["swapId"]]
    if len(swap) != 1:
        raise Unmeasurable(f"frame swap {frame['swapId']} has {len(swap)} display swaps, not one")
    lifetime_end = frame["start"] + frame["duration"]
    if abs(swap[0]["ns"] - lifetime_end) > SWAP_TOLERANCE_NS:
        raise Unmeasurable(f"swap {frame['swapId']}: the display shows it at {swap[0]['ns']} ns but its frame "
                           f"lifetime ends at {lifetime_end} ns")
    if swap[0]["ns"] < frame["renderStart"]:
        # Seen on the Simulator (Xcode 26.3): its host-rendered frame records are not a display pipeline.
        raise Unmeasurable(f"swap {frame['swapId']} was shown before its render began; this is not physical "
                           f"display presentation data")
    return {"renderStartNs": frame["renderStart"], "swapId": frame["swapId"], "presentedNs": swap[0]["ns"],
            "lifetimeEndNs": lifetime_end}


def _first_mark(marks, pid, name, after_ns):
    found = sorted(m["ns"] for m in marks if m["pid"] == pid and m["subsystem"] == SUBSYSTEM and m["name"] == name
                   and m["type"] == "Event" and m["ns"] is not None and m["ns"] >= after_ns)
    return found[0] if found else None


def launch_sample(tables):
    """Cold launch: the target's process creation to the presented, input-ready saved viewport."""
    creations = [p for p in lifecycle(tables["life-cycle-period"]) if p["period"] == PROCESS_CREATION]
    if len(creations) != 1 or creations[0]["pid"] is None or creations[0]["start"] is None:
        raise Unmeasurable(f"expected exactly one '{PROCESS_CREATION}' in the lifecycle table, found {len(creations)}")
    pid, start = creations[0]["pid"], creations[0]["start"]
    marks = signposts(tables["os-signpost"])
    end = presented_ready(marks, frame_lifetimes(tables["coreanimation-lifetime-interval"]),
                          display_swaps(tables["display-surface-swap"]), pid, start, (VIEWPORT, COMPOSER))
    draw = _first_mark(marks, pid, USEFUL, start)
    return {**end, "class": "cold", "startBoundary": PROCESS_CREATION, "startNs": start,
            "durationMs": (end["endNs"] - start) / 1e6,
            "phasesMs": {"usefulDraw": None if draw is None else (draw - start) / 1e6,
                         "commitEnd": (end["commitEndNs"] - start) / 1e6,
                         "presented": (end["presentedNs"] - start) / 1e6,
                         "inputReady": (end["inputReadyNs"] - start) / 1e6}}


RESUME = ("com.apple.UIKit", "AppResume")


def return_sample(tables, pid):
    """Warm return in retained process `pid`: UIKit's own `AppResume` interval begin (AppLifecycle,
    IsForeground 1, emitted in the app's process when the foreground transition reaches it) to the
    presented frame of the first draw after activation and the idle main thread after it. A new
    process is a cold start, never a warm sample."""
    life = lifecycle(tables["life-cycle-period"])
    if any(p["period"] == PROCESS_CREATION for p in life):
        raise Unmeasurable("the trace contains a process creation: the app was relaunched, which is a cold start")
    marks = signposts(tables["os-signpost"])
    pids = {m["pid"] for m in marks if m["subsystem"] == SUBSYSTEM and m["pid"] is not None}
    if pids - {pid}:
        raise Unmeasurable(f"app marks came from process {sorted(pids - {pid})}, not the retained process {pid}")
    resumes = sorted(m["ns"] for m in marks if m["pid"] == pid and (m["subsystem"], m["name"]) == RESUME
                     and m["type"] == "Begin" and "IsForeground= 1" in (m["message"] or ""))
    if len(resumes) != 1:
        raise Unmeasurable(f"expected exactly one UIKit AppResume (IsForeground 1) in process {pid}, found {len(resumes)}")
    start = resumes[0]
    end = presented_ready(marks, frame_lifetimes(tables["coreanimation-lifetime-interval"]),
                          display_swaps(tables["display-surface-swap"]), pid, start, (FOREGROUND,))
    return {**end, "class": "warm", "startBoundary": "UIKit AppResume begin", "startNs": start,
            "durationMs": (end["endNs"] - start) / 1e6,
            "phasesMs": {"foregroundDraw": (end["contentNs"][FOREGROUND] - start) / 1e6,
                         "commitEnd": (end["commitEndNs"] - start) / 1e6,
                         "presented": (end["presentedNs"] - start) / 1e6,
                         "inputReady": (end["inputReadyNs"] - start) / 1e6}}


def export_tables(trace, prefix, runner=subprocess.run, pause=time.sleep, tables=TABLES):
    """Export each table alone from a saved trace, keeping every attempt's output and exit. A
    signal death (the loader crash above) is re-read up to EXPORT_ATTEMPTS times; any other failure
    stops at once. The trace is retained either way: `perf.py ios --reparse` exports it later."""
    out, attempts = {}, []
    try:
        for table in tables:
            for attempt in range(1, EXPORT_ATTEMPTS + 1):
                result = runner(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                                 f'/trace-toc/run[@number="1"]/data/table[@schema="{table}"]'],
                                capture_output=True, text=True, timeout=120)
                path = f"{prefix}.{table}.xml"
                with open(path, "w") as f:
                    f.write(result.stdout or "")
                if result.stderr:
                    with open(f"{path}.{attempt}.stderr", "w") as f:
                        f.write(result.stderr)
                attempts.append({"table": table, "attempt": attempt, "exit": result.returncode,
                                 "bytes": len(result.stdout or "")})
                if result.returncode == 0 and (result.stdout or "").strip():
                    out[table] = result.stdout
                    break
                if result.returncode >= 0:
                    raise Unmeasurable(f"xctrace export of {table} failed (exit {result.returncode}); see {path}")
                if attempt == EXPORT_ATTEMPTS:
                    raise Unmeasurable(f"xctrace export of {table} was killed by signal {-result.returncode} "
                                       f"{EXPORT_ATTEMPTS} times; the trace is retained for --reparse")
                pause(EXPORT_PAUSE_S)
    finally:
        with open(prefix + ".exports.json", "w") as f:
            json.dump(attempts, f, indent=2)
    return out, attempts


def build_configuration(artifact):
    """'release', 'debug' or None, from the stamped bundle's bytes by the same development-marker
    test as `rios sim check-release`: a Debug bundle carries every marker, a Release bundle none."""
    if not artifact or not os.path.isdir(artifact):
        return None
    present = set()
    for root, _, files in os.walk(artifact):
        for name in files:
            path = os.path.join(root, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as f:
                data = f.read()
            present.update(m for m in DEVELOPMENT_MARKERS if m.encode() in data)
    if len(present) == len(DEVELOPMENT_MARKERS):
        return "debug"
    return "release" if not present else None


APP_EXECUTABLE = "RichOSNative"
AWAY_APP = "com.apple.Preferences"  # brought to the front to background the app (no Home press over USB)
RECORD = ["xcrun", "xctrace", "record", "--template", "App Launch", "--instrument", "os_signpost",
          "--instrument", "Frame Lifetimes"]


class Devicectl:
    """A physical iPhone through Xcode's devicectl. `process launch` without --terminate-existing
    activates an app that is already running (devicectl's documented default, --activate)."""
    kind = "physical"

    def __init__(self, udid, runner=subprocess.run):
        self.target, self.runner = udid, runner

    def pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "processes.json")
            run(["xcrun", "devicectl", "device", "info", "processes", "--device", self.target, "--json-output", out],
                self.runner, timeout=60)
            with open(out) as f:
                data = json.load(f)
        procs = (data.get("result") or {}).get("runningProcesses")
        if not isinstance(procs, list):
            raise Unmeasurable("devicectl's process list has no result.runningProcesses")
        found = [p.get("processIdentifier") for p in procs
                 if f"/{APP_EXECUTABLE}.app/{APP_EXECUTABLE}" in str(p.get("executable") or "")]
        if len(found) > 1:
            raise Unmeasurable(f"{len(found)} {APP_EXECUTABLE} processes are running")
        return int(found[0]) if found else None

    def launch(self, bundle, *args):
        run(["xcrun", "devicectl", "device", "process", "launch", "--device", self.target, bundle, *args],
            self.runner, timeout=60)


class Simctl:
    """A leased, booted simulator (`--xctrace`): the same capture path, for dry runs of the tool.
    Simulator frame records are refused as presentation data (see presented_frame)."""
    kind = "simulator"

    def __init__(self, udid, runner=subprocess.run):
        self.target, self.runner = udid, runner

    def pid(self):
        return parse_launchctl_pid(run(["xcrun", "simctl", "spawn", self.target, "launchctl", "list"], self.runner))

    def launch(self, bundle, *args):
        run(["xcrun", "simctl", "launch", self.target, bundle, *args], self.runner)


def evidence_root_ok(path):
    return bool(path) and os.path.realpath(path).startswith("/Volumes/E1TB/") and os.path.ismount("/Volumes/E1TB")


def _capture(command, prefix, runner, timeout):
    result = runner(command, capture_output=True, text=True, timeout=timeout)
    with open(prefix + ".log", "w") as f:
        f.write(result.stdout or "")
    with open(prefix + ".log.stderr", "w") as f:
        f.write(result.stderr or "")
    if result.returncode:
        raise Unmeasurable(f"capture failed ({result.returncode}); see {prefix}.log")


def _return_capture(driver, trace, prefix, seconds, away, app_args, runner, popen, sleep):
    """Attach a recording to the app's process while it is in front (a simulator dry run once
    failed to find a just-backgrounded process by pid), and once the recording reports that
    tracing started, put Settings in front, wait `away` seconds and bring the app back. The same
    process must be running afterwards."""
    pid = driver.pid()
    if pid is None:
        driver.launch(BUNDLE, *app_args)
        sleep(3.0)
        pid = driver.pid()
        if pid is None:
            raise Unmeasurable("the app is not running after launching it")
    with open(prefix + ".trial.json", "w") as f:
        json.dump({"pid": pid}, f)
    note = f"dev.richos.perf.{os.getpid()}.{os.path.basename(prefix)}"
    waiter = popen(["notifyutil", "-1", note], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(prefix + ".log", "w") as out, open(prefix + ".log.stderr", "w") as err:
        recorder = popen(RECORD + ["--device", driver.target, "--time-limit", f"{seconds}s", "--output", trace,
                                   "--notify-tracing-started", note, "--attach", str(pid)],
                         stdout=out, stderr=err, text=True)
        try:
            for _ in range(120):  # at most 60 s for the recording to start; fail at once if it ends
                try:
                    waiter.wait(timeout=0.5)
                    break
                except subprocess.TimeoutExpired:
                    if recorder.poll() is not None:
                        with open(prefix + ".log.stderr") as f:
                            detail = f.read().strip()[-300:]
                        raise Unmeasurable(f"the recording ended ({recorder.returncode}) before tracing started: {detail}")
            else:
                raise Unmeasurable("the recording never reported that tracing started")
            driver.launch(AWAY_APP)
            sleep(away)
            driver.launch(BUNDLE)
            code = recorder.wait(timeout=seconds + 120)
        finally:
            for owned in (waiter, recorder):  # only the processes this function started
                if owned.poll() is None:
                    owned.terminate()
                    owned.wait(timeout=30)
    if code:
        raise Unmeasurable(f"capture failed ({code}); see {prefix}.log")
    after = driver.pid()
    if after != pid:
        raise Unmeasurable(f"the app's process changed from {pid} to {after}: a relaunch is a cold start")
    return pid


def trace_series(cls, driver, trials, evidence, runner=subprocess.run, popen=subprocess.Popen, sleep=time.sleep,
                 seconds=10, away=2.0, app_args=()):
    """`cold` or `warm` trials with Instruments, each trace retained under a unique directory.
    The first rejected trial (capture, export or join) stops the series; nothing is retried
    except the re-read of a trace whose exporter died (export_tables)."""
    if not 1 <= trials <= 1000:
        raise Refused("trace trials must be between 1 and 1000")
    if cls == "warm" and seconds < away + 5:
        raise Refused(f"--trace-seconds {seconds} cannot hold {away} s away plus the return; use at least {away + 5:g}")
    if not evidence_root_ok(evidence):
        raise Refused("traces require --evidence-dir on mounted /Volumes/E1TB")
    os.makedirs(evidence, exist_ok=True)
    evidence = tempfile.mkdtemp(prefix=f"ios-{cls}-", dir=evidence)
    samples, rejected = [], []
    for i in range(trials):
        prefix = os.path.join(evidence, f"{'launch' if cls == 'cold' else 'return'}-{i + 1:04}")
        trace = prefix + ".trace"
        try:
            if cls == "cold":
                _capture(RECORD + ["--device", driver.target, "--time-limit", f"{seconds}s", "--output", trace,
                                   "--launch", "--", BUNDLE, *app_args], prefix, runner, seconds + 120)
                tables, attempts = export_tables(trace, prefix, runner, sleep)
                sample = launch_sample(tables)
            else:
                pid = _return_capture(driver, trace, prefix, seconds, away, app_args, runner, popen, sleep)
                tables, attempts = export_tables(trace, prefix, runner, sleep)
                sample = return_sample(tables, pid)
            sample.update(trial=i + 1, trace=trace, exportAttempts=len(attempts))
            with open(prefix + ".json", "w") as f:
                json.dump(sample, f, indent=2)
            samples.append(sample)
        except (Unmeasurable, ET.ParseError, ValueError, KeyError, subprocess.TimeoutExpired) as e:
            rejection = {"trial": i + 1, "why": str(e), "evidence": prefix}
            rejected.append(rejection)
            with open(prefix + ".rejected.json", "w") as f:
                json.dump(rejection, f, indent=2)
            break
    return samples, rejected, evidence


def device_cold(udid, trials, evidence, runner=subprocess.run):
    """Physical cold launches (kept for callers of the first tool): see trace_series."""
    return trace_series("cold", Devicectl(udid, runner), trials, evidence, runner)


def reparse(evidence, cls, runner=subprocess.run, sleep=time.sleep):
    """Re-export and re-join every retained trace of one series, e.g. after the exporter died on
    all its attempts. Each trace is read again; nothing is captured."""
    stem = "launch" if cls == "cold" else "return"
    traces = sorted(n for n in os.listdir(evidence) if n.startswith(stem + "-") and n.endswith(".trace"))
    if not traces:
        raise Refused(f"no {stem}-NNNN.trace in {evidence}")
    samples, rejected = [], []
    for name in traces:
        prefix = os.path.join(evidence, name[:-len(".trace")])
        try:
            tables, attempts = export_tables(prefix + ".trace", prefix, runner, sleep)
            if cls == "cold":
                sample = launch_sample(tables)
            else:
                with open(prefix + ".trial.json") as f:
                    sample = return_sample(tables, int(json.load(f)["pid"]))
            sample.update(trial=int(name[len(stem) + 1:len(stem) + 5]), trace=prefix + ".trace",
                          exportAttempts=len(attempts), reparsed=True)
            samples.append(sample)
        except (Unmeasurable, ET.ParseError, ValueError, KeyError, OSError, subprocess.TimeoutExpired) as e:
            rejected.append({"trial": name, "why": str(e), "evidence": prefix})
    return samples, rejected


KEYS = {"cold": "coldLaunch", "warm": "warmResume"}
END_BOUNDARY = ("the later of: the display swap that presented the first frame rendered after the main-thread "
                "Core Animation commit carrying the ready content, and the app's input-ready mark (main run loop "
                "idle after that commit)")
METHODS = {
    "cold": "Instruments App Launch + os_signpost + Frame Lifetimes (xctrace record --launch). Start: the target "
            "process's 'Initializing - Process Creation'. Ready content: the app's viewport-ready (the transcript "
            "applied its saved position) and composer-ready (the editable field exists). End: " + END_BOUNDARY + ". "
            "One trace clock, joined by process ID. Profiler overhead is included; pixels are not inspected.",
    "warm": "Instruments App Launch + os_signpost + Frame Lifetimes (xctrace record --attach to the retained "
            "process). Settings is brought to the front, then the app is re-activated without termination "
            "(devicectl/simctl launch). Start: UIKit's AppResume begin (IsForeground 1) in that process. Ready "
            "content: the first draw after activation (foreground-useful). End: " + END_BOUNDARY + ". A changed "
            "process is rejected as a cold start. Profiler overhead is included; pixels are not inspected.",
}


def trace_metric(cls, samples, rejected, evidence):
    ms = [round(s["durationMs"], 3) for s in samples]
    summary = perfcore.stats(ms)
    p95 = summary.get("p95")
    phases = {}
    for name in sorted({k for s in samples for k, v in s["phasesMs"].items() if v is not None}):
        values = [round(s["phasesMs"][name], 3) for s in samples if s["phasesMs"].get(name) is not None]
        phases[name] = perfcore.stats(values)
    return {"method": METHODS[cls], "startBoundary": samples[0]["startBoundary"], "endBoundary": END_BOUNDARY,
            "samplesMs": ms, "stats": summary, "budget": perfcore.compare(KEYS[cls], summary), "phaseStatsMs": phases,
            "outliers": [{"trial": s["trial"], "ms": round(s["durationMs"], 3), "trace": s["trace"]}
                         for s in samples if p95 is not None and s["durationMs"] > p95],
            "exportAttempts": sum(s["exportAttempts"] for s in samples), "rejected": rejected, "evidence": evidence}


def _trace_classes(record, driver, args, runner, popen, sleep):
    """Each requested class in turn; the first rejected trial stops everything after it."""
    failures = 0
    for cls, trials in (("cold", args.cold), ("warm", getattr(args, "warm", 0) or 0)):
        if trials <= 0:
            continue
        samples, rejected, evidence = trace_series(cls, driver, trials, args.evidence_dir, runner, popen, sleep,
                                                   seconds=getattr(args, "trace_seconds", 10),
                                                   away=getattr(args, "away", 2.0),
                                                   app_args=tuple(getattr(args, "app_arg", None) or ()))
        with open(os.path.join(evidence, "series.json"), "w") as f:
            json.dump({"class": cls, "device": record["device"], "build": record["build"]}, f, indent=2)
        record.setdefault("evidence", {})[cls] = evidence
        if samples:
            record["metrics"][KEYS[cls]] = trace_metric(cls, samples, rejected, evidence)
        else:
            record["notMeasured"].append({"what": KEYS[cls], "why": rejected[0]["why"] if rejected else "no trial"})
        record["phases"][cls] = (f"stopped at trial {rejected[0]['trial']}: {rejected[0]['why']}" if rejected
                                 else f"{len(samples)} trials")
        if rejected:
            failures += 1
            break
    return failures


def _reparsed(args, record, runner):
    with open(os.path.join(args.reparse, "series.json")) as f:
        series = json.load(f)
    record["device"], record["build"] = series["device"], series["build"]
    record["ranOnHardware"] = series["device"].get("kind") == "physical"
    record["evidence"] = {series["class"]: args.reparse}
    samples, rejected = reparse(args.reparse, series["class"], runner)
    if samples:
        record["metrics"][KEYS[series["class"]]] = trace_metric(series["class"], samples, rejected, args.reparse)
    else:
        record["notMeasured"].append({"what": KEYS[series["class"]], "why": rejected[0]["why"] if rejected else "no trace"})
    record["phases"][series["class"]] = f"reparsed {len(samples)} of {len(samples) + len(rejected)} retained traces"
    return int(bool(rejected) or not samples)


def run_ios(args, runner=subprocess.run, popen=subprocess.Popen, sleep=time.sleep):
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
    if getattr(args, "reparse", None):
        failures += _reparsed(args, record, runner)
    elif args.simulator:
        record["device"] = simulator(run(["xcrun", "simctl", "list", "devices", "-j"], runner), args.simulator)
        container = run(["xcrun", "simctl", "get_app_container", args.simulator, BUNDLE, "app"], runner).strip()
        installed = perfcore.tree_sha256(container)
        if stamp and installed != stamp.get("sha256"):
            raise Refused(f"freshness mismatch: the installed app is {installed[:12]}…, the stamped build {str(stamp.get('sha256'))[:12]}…")
        record["build"] = {"bundle": BUNDLE, "commit": stamp and stamp.get("commit"), "dirty": stamp and stamp.get("dirty"),
                           "installedSha256": installed, "builtSha256": stamp and stamp.get("sha256"),
                           "configuration": build_configuration(container)}
        if getattr(args, "xctrace", False):
            failures += _trace_classes(record, Simctl(args.simulator, runner), args, runner, popen, sleep)
        else:
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
                           "builtSha256": stamp and stamp.get("sha256"),
                           "configuration": build_configuration(stamp and stamp.get("artifact")),
                           "note": "an iPhone's installed bundle cannot be read back; identity is the stamp of what was installed"}
        record["ranOnHardware"] = True
        failures += _trace_classes(record, Devicectl(args.device, runner), args, runner, popen, sleep)
    record["notMeasured"].extend(ios_gaps(record["metrics"]))
    record["acceptance"] = ios_acceptance(record)
    record["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return record, failures


def ios_acceptance(record):
    """PRD §8 needs both launch classes: the smaller class's trial count is the protocol count."""
    metrics = record["metrics"]
    counts = [len((metrics.get(k) or {}).get("samplesMs") or []) for k in ("coldLaunch", "warmResume")]
    out = perfcore.acceptance(record["device"]["kind"], record["build"].get("configuration") == "release", min(counts))
    if record["build"].get("configuration") is None:
        out["why"] = [w if not w.startswith("not a release") else
                      "the build configuration is unknown (no stamped bundle to inspect)" for w in out["why"]]
    for key, cls in (("coldLaunch", "cold launch"), ("warmResume", "warm return")):
        if key not in metrics:
            out["why"].append(f"no {cls} distribution")
    out["verdict"] = "NOT VERIFIED" if out["why"] else out["verdict"]
    return out


def ios_gaps(metrics=None):
    metrics = metrics or {}
    gaps = []
    if "coldLaunch" not in metrics:
        gaps.append({"what": "coldLaunch", "why": "run the trace series (physical --device, or --xctrace on a simulator "
                                                  "as a dry run) with --cold N"})
    if "warmResume" not in metrics:
        gaps.append({"what": "warmResume", "why": "run the trace series with --warm N"})
    return gaps + [
        {"what": "tapToFeedback, sendToQueued, receiveToVisible, activeFrames",
         "why": "need an XCUITest harness in native-ios/UITests driving the real controls with XCTOSSignpostMetric "
                "around app-emitted signposts; not written"},
        {"what": "idleFrames", "why": "iOS has no gfxinfo; on an iPhone, Instruments' Animation Hitches template "
                                      "(xctrace) over an untouched window; not parsed here"},
        {"what": "background on an iPhone and energy",
         "why": "Instruments' Activity Monitor / Power Profiler templates (xctrace record --attach) and Settings > "
                "Battery over the PRD §8 windows; not parsed here"},
    ]

