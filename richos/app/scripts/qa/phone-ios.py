#!/usr/bin/env python3
"""Drive a PHYSICAL iPhone through its real controls, and read what an app leaves running.

    phone-ios.py check STEPS.json                  validate a step list; touches no device
    phone-ios.py run STEPS.json --out DIR [--allowance S] [--prebuilt --stamp STAMP.json]
                 [--approval-announced]
                                                   run the steps through XCUITest on the phone
                                                   (`rios device verify script`), then write
                                                   DIR/steps.jsonl (one line per step, phone clock)
                                                   and DIR/attachments/ (the steps' shots and trees).
                                                   Committed, unchanged app source is never rebuilt:
                                                   the one signed build of that source tree is reused
                                                   from the shared store automatically (see
                                                   physical-device.mjs), so a walk starts in seconds;
                                                   --prebuilt reuses THIS checkout's earlier products
                                                   and refuses unless the app still hashes to
                                                   STAMP.json (perf.py stamp)
    phone-ios.py approval --device UDID            will the next run ask the phone's owner to approve
                                                   UI automation? Asks nothing of the phone's screen.
    phone-ios.py parse-log TEST.log                the PHONE_STEP lines of a finished run
    phone-ios.py summary DIR                       a finished `run` DIR read back: one row per step
                                                   (outcome, seconds, what it waited for, the audit's
                                                   issues) and each named shot or tree mapped to its
                                                   exported file, so nobody reads the xcresult manifest
    phone-ios.py vocabulary [RUNNER.swift]         exit 1 when a step this tool validates has no case in
                                                   the phone runner's dispatcher (or the reverse), before
                                                   any build or install finds it as "unknown step"
    phone-ios.py pair-steps MAC-TEST-CONFIG.json [--v2-hold S]
                                                   the real-control pairing steps for a lab's current
                                                   link, with all six words checked before They match;
                                                   --v2-hold (pairing v2) waits for each word by label
                                                   and holds S seconds before the press, for
                                                   `pair-words.py check` (see that tool)
    phone-ios.py procs [--name NAME]               the phone's processes whose executable ends in
                                                   NAME (default RichOSNative): pid and path only
    phone-ios.py apps                              which RichConnect builds and test runners are installed
    phone-ios.py lock                              the phone's lock state
    phone-ios.py battery                           level, charging and external power
    phone-ios.py syslog --seconds S --out FILE     the phone's log for S seconds, keeping ONLY lines that
                                                   name RichOSNative or dev.richos.connect
    (`syslog` and `battery` take --network for an unplugged phone: libimobiledevice's -n, same pairing)
    phone-ios.py syslog-rate FILE [--process P] [--bucket S] [--from HH:MM:SS] [--to HH:MM:SS]
                                                   entries ONE process (exact name) wrote per S seconds of
                                                   a `syslog` capture: what the app did while hidden

The iPhone counterpart of phone-android.py. iOS 26 offers no shell on the phone, so every tap,
type, Home, lock and screenshot goes through one XCUITest check that executes a list of steps
(`PhysicalDeviceTests.testScript`). Each step prints one `PHONE_STEP` JSON line with its start and
end on the phone's clock, which this tool collects. A failed step stops the list; nothing is
retried. Validation happens here, before anything is built, so a typo costs a second, not a build.

THE APPROVAL PROMPT, AND WHY IT IS NEVER A SURPRISE. When the phone has a passcode, iOS asks
its owner (Touch ID or passcode, at the phone) to allow UI automation when a test session starts
after the phone has been idle; the session waits about 60 s and then fails "Timed out while
enabling automation mode". Apple: the prompt exists only when a passcode is set, comes back
"roughly once per day", and cannot be automated (developer.apple.com/forums/thread/693273).
Measured on this Mac's 108 sessions (2026-09-27 to 10-01): never asked within 12.5 min of the
previous session, always asked after 9.3 h or more, and NOT triggered by reinstalling the runner
(about 100 back-to-back sessions each re-installed it without asking; a 9.7 h idle asked with the
very same products). A phone dedicated to testing is kept without a passcode, so nothing asks;
`run` still forecasts before it builds anything (`approval` prints the same forecast), and
REFUSES a run that is expected to ask unless --approval-announced says the CEO was told first.

First launch of a newly signed development app can require Apple's online verification.
On the physical SE on 2026-09-27, Xcode reported an untrusted certificate but the icon showed
"Unable to Verify App" and Settings had no Developer App profile. One tap on the app icon while
the phone was online resolved it. If that exact refusal occurs, inspect the launch error and
provisioning profile first, then request that one hand step once before retrying. Do not send
the person searching for a trust profile that is absent or repeatedly retry the unchanged refusal.

Steps are JSON objects with "do" and, where needed, "id" (accessibility identifier), "label"
(substring of the accessibility label) or "kind" ("switch" or "button": the first one), "in":
"springboard" for system UI, "tailscale" for the route's own app, "settings" for iOS Settings (this
app's permissions under Settings > Apps > RichConnect, and Wi-Fi: set back what you change) or
"safari" for the one share-sheet source, "timeout" (s) and "optional": true (a failure is logged,
the list continues). `tree` and `shot` keep the "in" app's window; `launch` and `terminate` with
"in" start that app fresh on its first page or close it (never SpringBoard); "kind" with "label" is
that control itself (a Settings permission row's inner toggle, not the row: a tap at the row's center
does not toggle it). Settings builds its rows lazily, so a row below the fold is not found until
scrolled; reach this app's page through the app's own "iPhone permissions" row. A list that touches Tailscale may
not take a shot, tree or audit: that screen is the person's own account. Settings' first page names
the phone's Apple Account, so `ocr-gate.sh` every Settings frame before it enters a record.

    launch{textSize} activate terminate home lock{person: true} sleep{seconds} mark{label} state audit
    waitState{state: background|suspended|foreground|notRunning}
    wait tap exists gone value{equals} type{text, delete, focus} press{seconds, drag:[dx,dy]}
    swipe{direction} count{label, equals} alert{button} shot{name, screen} tree{name}
    appearance{set: light|dark}   the phone's own light/dark setting, read (and set); the app follows
                                  the phone. Record the starting value and set it back before the end.
    orientation{set: portrait|landscapeLeft|landscapeRight|portraitUpsideDown}
                                  turn the phone; the step reports the app window's size, so a
                                  portrait-only app is seen to stay upright. End on portrait.
    open{url}                     an https link, opened as a person's tap opens one: in Safari
                                  (test content only, e.g. an isolated lab's own image).

An "id" names the FIRST element carrying that identifier (SwiftUI repeats a container's identifier
on its children).

`launch` may carry Apple's own text-size override (`textSize`, a UIContentSizeCategory name) and
nothing else: the app under test stays the Release app. `audit` records XCTest's accessibility
audit of the screen as it is.

`lock` presses XCTest's lock button, and NOTHING in a script can open the phone again: measured on
an iPhone SE, iOS 26.3.1, with no passcode set (2026-09-24), XCTest's Home press wakes the lock
screen but does not open it, and XCTest cannot start its runner on a locked phone at all ("Device
test exceeded its time limit"). So a `lock` step must say `"person": true` (a person is at the
phone to press Home), and there is no `unlock` step. `shot` keeps only the app unless "screen": true, so nothing else on a person's phone lands
in a record by accident; run `ocr-gate.sh` on any frame before it enters a record.

Environment for `run`: RICHOS_IOS_DEVICE (the hardware UDID xcodebuild accepts) and
RICHOS_APPLE_TEAM. `procs`, `apps`, `lock` and `battery` take --device (devicectl identifier or
UDID). Prints one JSON document; exits 1 when the phone answered "no" (a step failed) and 2 when
it cannot answer at all, with the sentence in `error`.
"""
import argparse
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]  # the richos repository root
RIOS = ROOT / "richos/mobile/native-ios/bin/rios"
OURS = ("dev.richos.connect", "dev.richos.native.ios", "dev.richos.mobile.integration")

ACTIONS = {
    "launch": {"textSize"}, "audit": set(), "activate": set(), "terminate": set(), "home": set(), "lock": {"person"},
    "sleep": {"seconds"}, "mark": {"label"}, "state": set(),
    "waitState": {"state"}, "wait": set(), "tap": set(), "exists": set(), "gone": set(),
    "value": {"equals"}, "type": {"text", "delete", "focus"}, "press": {"seconds", "drag"},
    "swipe": {"direction"}, "count": {"label", "equals"}, "alert": {"button"},
    "shot": {"name", "screen"}, "tree": {"name"},
    "appearance": {"set"}, "orientation": {"set"}, "open": {"url"},
}
APPEARANCES = ("light", "dark")
ORIENTATIONS = ("portrait", "landscapeLeft", "landscapeRight", "portraitUpsideDown")
NEEDS_TARGET = {"wait", "tap", "exists", "gone", "value", "type", "press", "swipe"}
COMMON = {"do", "id", "label", "kind", "in", "timeout", "optional"}
PLACES = ("springboard", "tailscale", "settings", "safari")
# The Tailscale app shows the person's own account and devices: a list that touches it may press
# and read its switch, and may not keep a picture or a tree of anything.
KEEPS_SCREEN = {"shot", "tree", "audit"}


class CannotAnswer(Exception):
    pass


def emit(obj, code=0):
    print(json.dumps(obj, indent=2))
    return code


def validate(steps):
    """The whole list, or the first reason it cannot run. Nothing partial reaches the phone."""
    if not isinstance(steps, list) or not steps:
        raise CannotAnswer("steps must be a non-empty JSON list")
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            raise CannotAnswer(f"step {i} is not an object")
        action = step.get("do")
        if action not in ACTIONS:
            raise CannotAnswer(f"step {i}: unknown step {action!r}")
        extra = set(step) - COMMON - ACTIONS[action]
        if extra:
            raise CannotAnswer(f"step {i} ({action}): unexpected keys {sorted(extra)}")
        if action in NEEDS_TARGET and not (isinstance(step.get("id"), str) or isinstance(step.get("label"), str)
                                           or step.get("kind") in ("switch", "button")):
            raise CannotAnswer(f"step {i} ({action}) names no id or label")
        if "kind" in step and step["kind"] not in ("switch", "button"):
            raise CannotAnswer(f"step {i}: 'kind' may only be 'switch' or 'button'")
        if action == "count" and not isinstance(step.get("label"), str):
            raise CannotAnswer(f"step {i} (count) needs a label")
        if action == "type" and not isinstance(step.get("text"), str):
            raise CannotAnswer(f"step {i} (type) needs text")
        if action == "swipe" and step.get("direction") not in ("up", "down", "left", "right"):
            raise CannotAnswer(f"step {i} (swipe) needs direction up, down, left or right")
        if action == "waitState" and step.get("state") not in ("background", "suspended", "foreground", "notRunning"):
            raise CannotAnswer(f"step {i} (waitState) needs a state")
        if action == "lock" and step.get("person") is not True:
            raise CannotAnswer(f"step {i} (lock) needs \"person\": true: only a person can open the phone again")
        if action == "sleep" and not (isinstance(step.get("seconds"), (int, float)) and 0 < step["seconds"] <= 1800):
            raise CannotAnswer(f"step {i} (sleep) needs seconds between 0 and 1800")
        if action == "appearance" and "set" in step and step["set"] not in APPEARANCES:
            raise CannotAnswer(f"step {i} (appearance) may only set light or dark")
        if action == "orientation" and "set" in step and step["set"] not in ORIENTATIONS:
            raise CannotAnswer(f"step {i} (orientation) may only set {', '.join(ORIENTATIONS)}")
        if action == "open" and not (isinstance(step.get("url"), str) and step["url"].startswith("https://")):
            raise CannotAnswer(f"step {i} (open) needs an https url: it opens Safari, never another app's own scheme")
        if "in" in step and step["in"] not in PLACES:
            raise CannotAnswer(f"step {i}: 'in' may only be one of {', '.join(PLACES)}")
        if action in ("launch", "terminate") and step.get("in") == "springboard":
            raise CannotAnswer(f"step {i} ({action}): the system UI is never launched or terminated")
        if action == "launch" and "in" in step and "textSize" in step:
            raise CannotAnswer(f"step {i} (launch): textSize is for this app only; another app starts with no arguments")
    if any(s.get("in") == "tailscale" for s in steps) and any(s["do"] in KEEPS_SCREEN for s in steps):
        raise CannotAnswer("a list that touches Tailscale may not keep a shot, tree or audit: its screen is the person's account")
    return steps


def parse_log(text):
    rows = []
    for line in text.splitlines():
        at = line.find("PHONE_STEP ")
        if at < 0:
            continue
        try:
            rows.append(json.loads(line[at + len("PHONE_STEP "):]))
        except json.JSONDecodeError:
            continue  # xcodebuild echoes the print once more inside a quoted line; the clean one counts
    seen, unique = set(), []
    for row in rows:
        if row.get("i") in seen:
            continue
        seen.add(row.get("i"))
        unique.append(row)
    return unique


def summary(directory):
    """A finished `run` directory read back for a person: every step on one row, and the named
    shots and trees mapped to the files xcresulttool exported. Refuses a directory that is not a
    finished run rather than printing an empty table."""
    directory = Path(directory)
    try:
        rows = [json.loads(line) for line in (directory / "steps.jsonl").read_text().splitlines() if line.strip()]
    except FileNotFoundError:
        raise CannotAnswer(f"{directory} has no steps.jsonl: it is not a finished phone-ios.py run")
    except json.JSONDecodeError as error:
        raise CannotAnswer(f"{directory}/steps.jsonl is not one JSON object per line: {error}")
    if not rows:
        raise CannotAnswer(f"{directory}/steps.jsonl is empty: the phone logged no step")
    steps = []
    for row in rows:
        detail = row.get("detail") or {}
        out = {"i": row.get("i"), "do": row.get("do"), "ok": row.get("ok"),
               "seconds": round(float(row.get("end", 0)) - float(row.get("start", 0)), 2), "app": row.get("appState")}
        for key in ("error", ):
            if row.get(key):
                out[key] = row[key]
        for key in ("label", "value", "count", "exists", "waitedMs", "text", "issues", "appearance", "orientation", "frame"):
            if key in detail:
                out[key] = detail[key]
        steps.append(out)
    named = {}
    manifest = directory / "attachments" / "manifest.json"
    if manifest.exists():
        try:
            tests = json.loads(manifest.read_text())
        except json.JSONDecodeError as error:
            raise CannotAnswer(f"{manifest} is not JSON: {error}")
        for test in tests:
            for item in test.get("attachments", []):
                # xcresulttool names an attachment "<name>_<n>_<UUID>.<ext>".
                human = str(item.get("suggestedHumanReadableName", ""))
                found = re.match(r"^(.*)_\d+_[0-9A-F-]{36}\.(\w+)$", human)
                key = f"{found.group(1)}.{found.group(2)}" if found else human
                named[key] = str(directory / "attachments" / item.get("exportedFileName", ""))
    failed = [s for s in steps if not s["ok"]]
    return {"steps": steps, "logged": len(steps), "failed": len(failed), "files": dict(sorted(named.items()))}


RUNNER = ROOT / "richos/mobile/native-ios/UITests/PhysicalDeviceTests.swift"
# Steps the phone runner knows that this tool refuses on purpose: there is no scripted unlock
# (XCTest's Home press does not open an iOS 26 lock screen; see the module docstring).
REFUSED_HERE = {"unlock"}


def vocabulary(runner_path):
    """Does the phone runner (`PhysicalDeviceTests.perform`) have a case for every step this tool
    validates? A step the host accepts and the phone does not know fails on the phone, after a
    build and an install, as "unknown step"; this finds it before either."""
    try:
        source = Path(runner_path).read_text()
    except OSError as error:
        raise CannotAnswer(f"cannot read the phone runner {runner_path}: {error}")
    start = source.find("private func perform(")
    if start < 0:
        raise CannotAnswer(f"{runner_path} has no perform(...) step dispatcher")
    # The dispatcher's own cases sit at eight spaces; nested switches (swipe directions) deeper.
    phone = set()
    for group in re.findall(r'^ {8}case ((?:"[A-Za-z]+"(?:, )?)+):', source[start:], re.M):
        phone.update(re.findall(r'"([A-Za-z]+)"', group))
    if not phone:
        raise CannotAnswer(f"found no step cases in {runner_path}'s perform(...)")
    host = set(ACTIONS)
    missing = sorted(host - phone)
    unknown = sorted(phone - host - REFUSED_HERE)
    return {"same": not missing and not unknown, "host": len(host), "phone": len(phone),
            "missingOnPhone": missing, "unknownToHost": unknown}


def pair_steps(config_path, v2_hold=None):
    """The real-control pairing a person does, from the lab's own mac-test-config.json: open the
    link field, enter the link, check all six words BEFORE pressing They match, then the consent.

    Pairing v2 (`v2_hold` seconds): the Mac's words depend on the key the phone registers, so the
    config's words (v1) are not the ones to count. Each "Word n:" is waited for by label instead,
    which puts the phone's six words in its PHONE_STEP log, and the press waits `v2_hold` seconds
    while the walker runs `pair-words.py check` and stops the run if it does not exit 0."""
    try:
        config = json.loads(Path(config_path).read_text())
    except (FileNotFoundError, json.JSONDecodeError) as error:
        raise CannotAnswer(f"cannot read the lab configuration {config_path}: {error}")
    link, words = config.get("pairLink"), str(config.get("words", "")).split()
    if not (isinstance(link, str) and link.startswith("https://") and "#pair=" in link):
        raise CannotAnswer("the lab configuration has no current HTTPS pairing link")
    if v2_hold is None and len(words) != 6:
        raise CannotAnswer("the lab configuration has no current HTTPS pairing link and six words")
    if v2_hold is not None and not 20 <= v2_hold <= 300:
        raise CannotAnswer("--v2-hold must be 20 to 300 seconds: long enough to check, short enough to stay inside the code's five minutes")
    steps = [{"do": "launch"}, {"do": "tap", "id": "pair.link", "timeout": 10},
             {"do": "type", "id": "pairlink.field", "text": link}, {"do": "tap", "id": "pairlink.submit"},
             {"do": "wait", "id": "pair.match", "timeout": 20}]
    if v2_hold is None:
        steps += [{"do": "count", "label": f"Word {n}: {word}", "equals": 1} for n, word in enumerate(words, 1)]
    else:
        steps += [{"do": "wait", "label": f"Word {n}: ", "timeout": 5} for n in range(1, 7)]
        steps += [{"do": "mark", "label": "compare the words now: pair-words.py check"}, {"do": "sleep", "seconds": v2_hold}]
    steps += [{"do": "tap", "id": "pair.match"}, {"do": "tap", "id": "consent.continue", "timeout": 4, "optional": True},
              {"do": "wait", "id": "composer.field", "timeout": 20}]
    return validate(steps)


def load_steps(path):
    try:
        return validate(json.loads(Path(path).read_text()))
    except FileNotFoundError:
        raise CannotAnswer(f"no step file at {path}")
    except json.JSONDecodeError as error:
        raise CannotAnswer(f"{path} is not JSON: {error}")


def stamped_identity(stamp_path):
    """Identity or refuse: the prebuilt app must still be the stamped bytes (perf.py stamp)."""
    if not stamp_path:
        raise CannotAnswer("--prebuilt needs --stamp: reused products are only trusted against their stamp")
    try:
        stamp = json.loads(Path(stamp_path).read_text())
    except (FileNotFoundError, json.JSONDecodeError) as error:
        raise CannotAnswer(f"cannot read the stamp {stamp_path}: {error}")
    sys.path.insert(0, str(ROOT / "richos/mobile/perf"))
    import perfcore  # the same tree hash perf.py stamp wrote
    artifact = stamp.get("artifact", "")
    if not os.path.isdir(artifact):
        raise CannotAnswer(f"the stamped app {artifact} is gone")
    actual = perfcore.tree_sha256(artifact)
    if actual != stamp.get("sha256") or stamp.get("dirty"):
        raise CannotAnswer(f"freshness mismatch: {artifact} hashes {actual[:12]}…, the stamp says "
                           f"{str(stamp.get('sha256'))[:12]}… (dirty={stamp.get('dirty')})")
    return {"artifact": artifact, "sha256": actual, "commit": stamp.get("commit")}


SESSION_LOGS = "/Volumes/E1TB/caches/richos-native-ios/*/physical/*-test.log"
APPROVAL_TIMEOUT = "Timed out while enabling automation mode"
QUIET_WINDOW_S = 600      # measured: no session within 12.5 min of the previous one ever asked
COLD_GAP_S = 3600         # a session after this much idle is the one that would ask
ASKED_WAIT_S = 3.0        # runner start to first suite: 0.5-1.2 s unasked, 9.9-24.7 s when he approved
_PHONE_TS = r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})"


def session_from_log(path):
    """One automation session as its xcodebuild log left it: which phone, when it ran (this Mac's
    clock: the log's creation and last write) and how long the runner waited for UI automation to
    be enabled (the phone's clock: runner start to first suite). None for a log naming no phone."""
    text = Path(path).read_text(errors="replace")
    device = re.search(r"-destination id=([A-Fa-f0-9-]+)", text)
    if not device:
        return None
    st = os.stat(path)
    runner = (re.search(_PHONE_TS + r"\d*[+-]\d{4} RichOSNativeUITests-Runner\[\d+:\d+\] \[Default\] Running tests", text)
              or re.search(_PHONE_TS + r"\d*[+-]\d{4} RichOSNativeUITests-Runner\[", text))
    suite = re.search(r"Test Suite '[^']+' started at " + _PHONE_TS, text)
    wait = None
    if runner and suite:
        fmt = "%Y-%m-%d %H:%M:%S.%f"
        from datetime import datetime
        wait = round((datetime.strptime(suite.group(1), fmt) - datetime.strptime(runner.group(1), fmt)).total_seconds(), 1)
    passcode = None
    said = re.search(r"PHONE_PASSCODE (\{[^\n]*?\})\s*$", text, re.M)
    if said:
        try:
            value = json.loads(said.group(1)).get("configured")
            passcode = value if isinstance(value, bool) else None
        except json.JSONDecodeError:
            pass
    return {"log": str(path), "device": device.group(1), "started": getattr(st, "st_birthtime", st.st_mtime),
            "ended": st.st_mtime, "enableWaitSeconds": wait, "timedOut": APPROVAL_TIMEOUT in text,
            "passcodeConfigured": passcode}


def sessions(device, pattern=None):
    import glob
    week = time.time() - 7 * 86400
    found = []
    for path in glob.glob(pattern or os.environ.get("RICHOS_IOS_SESSION_LOGS", SESSION_LOGS)):
        try:
            if os.stat(path).st_mtime < week:
                continue
            s = session_from_log(path)
        except OSError:
            continue
        if s and s["device"].lower() == device.lower():
            found.append(s)
    return sorted(found, key=lambda s: s["started"])


def passcode_state(device):
    """True or False only when the phone itself answered whether a passcode is CONFIGURED; None
    otherwise. Lockdown's PasswordProtected and devicectl's passcodeRequired are NOT this: both
    say whether the phone is locked right now (both read false on 2026-10-01 while it had one).
    Measured on iOS 26.3.1 (2026-10-01): MobileGestalt answers "MobileGestaltDeprecated", so this
    is None there and the forecast uses the phone's own PHONE_PASSCODE line from its last session."""
    try:
        p = subprocess.run(["idevicediagnostics", "-u", device, "mobilegestalt", "PasswordConfigured"],
                           capture_output=True, timeout=20)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    import plistlib
    try:
        gestalt = plistlib.loads(p.stdout).get("MobileGestalt", {})
    except Exception:
        return None
    value = gestalt.get("PasswordConfigured")
    return value if gestalt.get("Status") == "Success" and isinstance(value, bool) else None


def forecast(device, now=None, passcode=None, pattern=None):
    """Will the next session ask the phone's owner to approve UI automation? Decided from the phone's
    passcode when it answers, else from this phone's own session history. Never touches its screen."""
    now = time.time() if now is None else now
    history = sessions(device, pattern)
    # No Mac-side tool reads the passcode on iOS 26, so the phone's own answer at its latest
    # session (PhysicalDeviceTests.passcodeReading) stands in, with its age.
    said = next((s for s in reversed(history) if s.get("passcodeConfigured") is not None), None)
    source = "the phone, now"
    if passcode is None and said:
        passcode = said["passcodeConfigured"]
        source = f"the phone itself at a session {round((now - said['ended']) / 60)} min ago"
    out = {"device": device, "passcodeConfigured": passcode, "passcodeReadBy": source if passcode is not None else None,
           "sessionsOnRecord": len(history)}
    last = history[-1] if history else None
    if last:
        out["lastSession"] = {"endedSecondsAgo": round(now - last["ended"]), "enableWaitSeconds": last["enableWaitSeconds"],
                              "timedOut": last["timedOut"], "log": last["log"]}
    if passcode is False:
        return {**out, "approvalExpected": False,
                "why": f"the phone has no passcode ({source}), and iOS asks to allow UI automation only when one is set"}
    if last and last["timedOut"]:
        return {**out, "approvalExpected": True,
                "why": f"the last session on this phone ({last['log']}) failed '{APPROVAL_TIMEOUT}': nobody approved it"}
    if last and now - last["ended"] <= QUIET_WINDOW_S:
        return {**out, "approvalExpected": False,
                "why": f"the last session ended {round(now - last['ended'])} s ago; within {QUIET_WINDOW_S} s none has ever asked"}
    if passcode is None:
        cold = [s for prev, s in zip(history, history[1:]) if s["started"] - prev["ended"] >= COLD_GAP_S]
        if cold and not cold[-1]["timedOut"] and cold[-1]["enableWaitSeconds"] is not None \
                and cold[-1]["enableWaitSeconds"] < ASKED_WAIT_S:
            return {**out, "approvalExpected": False, "coldSession": cold[-1]["log"],
                    "why": f"the passcode could not be read, and the last session after an idle hour "
                           f"started in {cold[-1]['enableWaitSeconds']} s without asking (no passcode since then)"}
    idle = "no session on record for this phone" if not last else f"the last session ended {round((now - last['ended']) / 60)} min ago"
    held = "the phone has a passcode" if passcode else "the passcode could not be read"
    return {**out, "approvalExpected": True,
            "why": f"{held} and {idle}: iOS asks again after idle (never within 12.5 min, always after 9.3 h, measured)"}


def approval_refusal(f):
    return (f"this run is expected to ask the phone's owner to allow UI automation (Touch ID or passcode, "
            f"at the phone, within about 60 s, or the run fails '{APPROVAL_TIMEOUT}'): {f['why']}. "
            "Tell Rich so the CEO hears it BEFORE the run, then pass --approval-announced. "
            "Removing the test phone's passcode ends the prompt for good.")


def approval(args):
    return emit(forecast(args.device, passcode=passcode_state(args.device)))


def run(args):
    started = time.time()
    steps = load_steps(args.steps)
    for name in ("RICHOS_IOS_DEVICE", "RICHOS_APPLE_TEAM"):
        if not os.environ.get(name):
            raise CannotAnswer(f"set {name}")
    out = Path(args.out).resolve()
    if not str(out).startswith("/Volumes/E1TB/"):
        raise CannotAnswer("--out must be on /Volumes/E1TB (the physical check refuses anything else)")
    if not 60 <= args.allowance <= 1800:
        raise CannotAnswer("--allowance must be 60 to 1800 seconds")
    identity = stamped_identity(args.stamp) if args.prebuilt else None
    device = os.environ["RICHOS_IOS_DEVICE"]
    ahead = forecast(device, passcode=passcode_state(device))
    if ahead["approvalExpected"] and not args.approval_announced:
        raise CannotAnswer(approval_refusal(ahead))
    out.mkdir(parents=True, exist_ok=True)
    config = out / "script-config.json"
    config.unlink(missing_ok=True)
    fd = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "w") as f:
        json.dump({"isolatedLab": "true", "steps": json.dumps(steps), "allowanceSeconds": str(args.allowance)}, f)
    env = {**os.environ, "RICHOS_MOBILE_TEST_CONFIG": str(config)}
    if args.prebuilt:
        env["RICHOS_PHYSICAL_PREBUILT"] = "1"
        (out / "identity.json").write_text(json.dumps(identity, indent=1))
    p = subprocess.run([str(RIOS), "device", "verify", "script"], capture_output=True, text=True, env=env)
    config.unlink(missing_ok=True)
    (out / "rios.stdout").write_text(p.stdout)
    (out / "rios.stderr").write_text(p.stderr)
    text = p.stdout + p.stderr
    found = re.search(r"(/Volumes/E1TB/\S+?/physical/script-(\d+)\.xcresult)", text)
    if not found:
        raise CannotAnswer(f"the check produced no result bundle (exit {p.returncode}); see {out}/rios.stderr")
    result, stamp = found.group(1), found.group(2)
    log = Path(result).parent / f"verify-script-{stamp}-test.log"
    rows = parse_log(log.read_text(errors="replace")) if log.exists() else []
    with open(out / "steps.jsonl", "w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    attachments = out / "attachments"
    exported = subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                               "--output-path", str(attachments)], capture_output=True, text=True)
    failed = [r for r in rows if not r.get("ok") and not steps[r["i"]].get("optional")]
    session = session_from_log(log) if log.exists() else None
    build = None
    for line in reversed(p.stdout.splitlines()):
        try:
            build = json.loads(line).get("result", {}).get("build")
            break
        except (json.JSONDecodeError, AttributeError):
            continue
    first = rows[0].get("start") if rows else None
    summary = {"passed": p.returncode == 0 and not failed and len(rows) == len(steps),
               "steps": len(steps), "logged": len(rows), "failed": failed[:1],
               "result": result, "testLog": str(log), "out": str(out),
               "attachments": str(attachments) if exported.returncode == 0 else None,
               "attachmentsError": None if exported.returncode == 0 else exported.stderr.strip()[-300:],
               "build": build, "approvalForecast": ahead,
               # The command's start on this Mac's clock to the first step's start on the phone's
               # clock (both set from network time), and the runner's wait for automation to be allowed.
               "secondsToFirstStep": round(first - started, 1) if isinstance(first, (int, float)) else None,
               "automationEnableWaitSeconds": session and session["enableWaitSeconds"],
               "passcodeConfigured": session and session["passcodeConfigured"]}
    if session and session["timedOut"]:
        summary["error"] = (f"'{APPROVAL_TIMEOUT}': the phone asked its owner to allow UI automation and "
                            "nobody approved it at the phone in about 60 s; no step ran")
    return emit(summary, 0 if summary["passed"] else 1)


def devicectl(args, device):
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "out.json"
        p = subprocess.run(["xcrun", "devicectl", *args, "--device", device, "--json-output", str(target)],
                           capture_output=True, text=True, timeout=120)
        if p.returncode != 0 or not target.exists():
            raise CannotAnswer(f"devicectl {' '.join(args)} failed: {(p.stderr or p.stdout).strip()[-200:]}")
        return json.loads(target.read_text()).get("result", {})


def procs(args):
    rows = devicectl(["device", "info", "processes"], args.device).get("runningProcesses", [])
    mine = [{"pid": r.get("processIdentifier"), "executable": r.get("executable")}
            for r in rows if str(r.get("executable", "")).rstrip("/").endswith("/" + args.name)]
    return emit({"name": args.name, "running": mine, "count": len(mine)})


def apps(args):
    rows = devicectl(["device", "info", "apps"], args.device).get("apps", [])
    ours = [{"bundle": r.get("bundleIdentifier"), "version": r.get("version"), "build": r.get("bundleVersion")}
            for r in rows if str(r.get("bundleIdentifier", "")).startswith(OURS)]
    return emit({"installed": ours})


def lock(args):
    p = subprocess.run(["xcrun", "devicectl", "device", "info", "lockState", "--device", args.device],
                       capture_output=True, text=True, timeout=60)
    required = re.search(r"passcodeRequired:\s*(\w+)", p.stdout)
    if p.returncode != 0 or not required:
        raise CannotAnswer("devicectl did not report a lock state")
    # passcodeRequired is "locked right now", NOT "has a passcode": passcodeConfigured is that
    # (null when the phone would not say; it needs the hardware UDID).
    return emit({"passcodeRequired": required.group(1) == "true",
                 "unlockedSinceBoot": "unlockedSinceBoot: true" in p.stdout,
                 "passcodeConfigured": passcode_state(args.device)})


def battery(args):
    p = subprocess.run(["ideviceinfo", "-u", args.device, *(["-n"] if args.network else []), "-q", "com.apple.mobile.battery"],
                       capture_output=True, text=True, timeout=60)
    values = dict(line.split(": ", 1) for line in p.stdout.splitlines() if ": " in line)
    if p.returncode != 0 or "BatteryCurrentCapacity" not in values:
        raise CannotAnswer("ideviceinfo did not report the battery (it needs the hardware UDID)")
    return emit({"percent": int(values["BatteryCurrentCapacity"]), "charging": values.get("BatteryIsCharging") == "true",
                 "externalPower": values.get("ExternalConnected") == "true", "full": values.get("FullyCharged") == "true"})


SYSLOG_KEEP = ("RichOSNative", "dev.richos.connect")


def syslog(args):
    """The phone's own log for RichConnect only, for a bounded interval. Every other line on a
    person's phone is dropped before it reaches disk; the relay process is owned and stopped here."""
    if not 1 <= args.seconds <= 3600:
        raise CannotAnswer("--seconds must be 1 to 3600")
    out = Path(args.out)
    if not str(out.resolve()).startswith("/Volumes/E1TB/"):
        raise CannotAnswer("--out must be on /Volumes/E1TB")
    relay = subprocess.Popen(["idevicesyslog", "-u", args.device, *(["-n"] if args.network else []), "--no-colors"],
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, errors="replace")
    kept = total = 0
    deadline = time.monotonic() + args.seconds
    try:
        import selectors
        sel = selectors.DefaultSelector()
        sel.register(relay.stdout, selectors.EVENT_READ)
        with open(out, "w") as f:
            while time.monotonic() < deadline:
                if not sel.select(timeout=max(0.0, min(1.0, deadline - time.monotonic()))):
                    if relay.poll() is not None:
                        break
                    continue
                line = relay.stdout.readline()
                if not line:
                    break
                total += 1
                if any(key in line for key in SYSLOG_KEEP):
                    f.write(line)
                    kept += 1
    finally:
        relay.terminate()
        try:
            relay.wait(timeout=5)
        except subprocess.TimeoutExpired:
            relay.kill()
            relay.wait()
    if total == 0:
        raise CannotAnswer("the phone's log relay produced nothing (is the hardware UDID attached?)")
    return emit({"out": str(out), "kept": kept, "read": total, "relayPid": relay.pid, "relayExit": relay.returncode})


SYSLOG_ENTRY = re.compile(r"^\w{3} +\d+ (\d\d):(\d\d):(\d\d)(?:\.\d+)? (\S+)\[(\d+)\]")


def syslog_rate(path, process, bucket, start=None, end=None):
    """How many log entries one process wrote per `bucket` seconds of the phone's clock, from a
    `syslog` capture: the battery reading of a window (an app that does nothing while hidden writes
    nothing). Only the entry's first line counts; continuation lines carry no header. The process
    is matched exactly (`RichOSNative` is not `RichOSNativeUITests-Runner`)."""
    try:
        lines = Path(path).read_text(errors="replace").splitlines()
    except OSError as error:
        raise CannotAnswer(f"cannot read the log capture {path}: {error}")
    if not 1 <= bucket <= 3600:
        raise CannotAnswer("--bucket must be 1 to 3600 seconds")

    def seconds(clock):
        h, m, s = (int(x) for x in clock.split(":"))
        return h * 3600 + m * 60 + s

    lo, hi = (seconds(start) if start else None), (seconds(end) if end else None)
    counts, entries, matched = {}, 0, 0
    for line in lines:
        found = SYSLOG_ENTRY.match(line)
        if not found:
            continue
        entries += 1
        name = found.group(4).split("(")[0]
        if name != process:
            continue
        at = int(found.group(1)) * 3600 + int(found.group(2)) * 60 + int(found.group(3))
        if (lo is not None and at < lo) or (hi is not None and at >= hi):
            continue
        matched += 1
        key = at - at % bucket
        counts[key] = counts.get(key, 0) + 1
    if entries == 0:
        raise CannotAnswer(f"{path} holds no log entries in the idevicesyslog shape: is it a phone-ios.py syslog capture?")
    rows = [{"at": f"{k // 3600:02d}:{k % 3600 // 60:02d}:{k % 60:02d}", "entries": v} for k, v in sorted(counts.items())]
    return {"process": process, "bucketSeconds": bucket, "entries": matched, "ofAllEntries": entries, "buckets": rows}


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check").add_argument("steps")
    r = sub.add_parser("run")
    r.add_argument("steps")
    r.add_argument("--out", required=True)
    r.add_argument("--allowance", type=int, default=240)
    r.add_argument("--prebuilt", action="store_true")
    r.add_argument("--stamp")
    r.add_argument("--approval-announced", action="store_true",
                   help="the CEO was told before this run that the phone will ask him to allow UI automation")
    sub.add_parser("parse-log").add_argument("log")
    sub.add_parser("approval").add_argument("--device", required=True)
    sub.add_parser("summary").add_argument("dir")
    sub.add_parser("vocabulary").add_argument("runner", nargs="?", default=str(RUNNER))
    sr = sub.add_parser("syslog-rate")
    sr.add_argument("file")
    sr.add_argument("--process", default="RichOSNative")
    sr.add_argument("--bucket", type=int, default=10)
    sr.add_argument("--from", dest="start", help="HH:MM:SS on the phone's clock, inclusive")
    sr.add_argument("--to", dest="end", help="HH:MM:SS on the phone's clock, exclusive")
    ps = sub.add_parser("pair-steps")
    ps.add_argument("config")
    ps.add_argument("--v2-hold", type=int, default=None)
    for name in ("procs", "apps", "lock", "battery", "syslog"):
        s = sub.add_parser(name)
        s.add_argument("--device", required=True)
        if name == "procs":
            s.add_argument("--name", default="RichOSNative")
        if name == "syslog":
            s.add_argument("--seconds", type=float, required=True)
            s.add_argument("--out", required=True)
        if name in ("syslog", "battery"):
            # Unplugged (round 2 discharge windows): libimobiledevice's network mode, same pairing.
            s.add_argument("--network", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "check":
            return emit({"valid": True, "steps": len(load_steps(args.steps))})
        if args.command == "pair-steps":
            print(json.dumps(pair_steps(args.config, args.v2_hold), indent=1))
            return 0
        if args.command == "summary":
            return emit(summary(args.dir))
        if args.command == "syslog-rate":
            return emit(syslog_rate(args.file, args.process, args.bucket, args.start, args.end))
        if args.command == "vocabulary":
            result = vocabulary(args.runner)
            return emit(result, 0 if result["same"] else 1)
        if args.command == "parse-log":
            try:
                return emit({"steps": parse_log(Path(args.log).read_text(errors="replace"))})
            except FileNotFoundError:
                raise CannotAnswer(f"no log at {args.log}")
        return {"run": run, "procs": procs, "apps": apps, "lock": lock, "battery": battery,
                "syslog": syslog, "approval": approval}[args.command](args)
    except CannotAnswer as error:
        return emit({"error": str(error)}, 2)
    except subprocess.TimeoutExpired as error:
        return emit({"error": f"{error.cmd[0]} did not answer in {error.timeout} s"}, 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
