#!/usr/bin/env python3
"""phone_net.py — the test iPhone must be able to reach Apple, or nothing runs on it (CEO, 2026-10-02).

Why this exists. iOS verifies the developer certificate of an app signed for development ONLINE, each
time its cached verification has lapsed. A phone that cannot reach Apple at that moment refuses to open
the app: "Unable to Verify App. An internet connection is required to verify trust of the developer",
and every XCUITest session on it fails "The application could not be launched because the Developer
App Certificate is not trusted" (the test iPhone, 2026-09-24 and 2026-10-02 from 12:27Z: the refusal
came and went between passing runs, so the phone's route to Apple was flapping, not the app). The run
that follows such a refusal tests nothing, and it said so only after a build, an install and minutes.

So `rios device` (verify, run, perf, hold) calls this module around the phone's one use:

    preflight   one cheap launch of RichConnect through devicectl, then it is closed again. A refusal
                that names the missing verification raises `Unreachable` with ONE plain sentence
                naming the fix, before anything is built, installed or run. A locked phone, a missing
                tool or any other answer is not a verdict on the network: it is said and the run goes on.
    postflight  the same launch after the run, however the run ended. When the phone now refuses,
                the run left its network off (a step list that switches Wi-Fi off in Settings and did not
                get to switch it back): `RICHOS_PHONE_NET_RESTORE` (default `phone-ios.py wifi-restore`)
                reads the Wi-Fi switch in Settings and turns it on, and the launch is tried once more.
                What is still wrong is said in a sentence; it is never hidden behind the run's own exit.

The phone is named by RICHOS_IOS_DEVICE (what xcodebuild and devicectl both accept). Nothing here
installs, uninstalls or erases anything, and it never touches the phone's screen beyond opening and
closing the app.
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PACKAGE = "dev.richos.connect"
HERE = Path(__file__).resolve().parent
PHONE_IOS = HERE.parent / "app/scripts/qa/phone-ios.py"
# What devicectl (and the test log) say when iOS will not open a developer-signed app for want of its
# online verification.
UNTRUSTED = re.compile(
    r"not trusted|Unable to Verify|verify trust|has not been (?:explicitly )?trusted|"
    r"Developer App Certificate|internet connection is required", re.I)
LOCKED = re.compile(r"\blocked\b|unlock", re.I)

FIX = ("The test iPhone cannot reach Apple to verify RichConnect's developer certificate, so iOS will not open "
       "the app: put the phone on Wi-Fi with Tailscale and any VPN switched off, open RichConnect on the phone "
       "once (tap Verify App if iOS asks), then run again.")


class Unreachable(Exception):
    """The phone cannot open the app for want of Apple's online verification; the text is the sentence."""


def _xcrun(*args, timeout=60):
    return subprocess.run([os.environ.get("RICHOS_XCRUN") or "xcrun", *args],
                          capture_output=True, text=True, timeout=timeout)


def launch_check(device, timeout=60):
    """One launch of the app and its close: {'state': ok|untrusted|locked|unknown, 'detail': text}."""
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "launch.json"
        try:
            p = _xcrun("devicectl", "device", "process", "launch", "--device", device, "--terminate-existing",
                       "--json-output", str(target), PACKAGE, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as error:
            return {"state": "unknown", "detail": f"devicectl did not answer ({type(error).__name__})"}
        text = ((p.stderr or "") + (p.stdout or "")).strip()
        try:
            doc = json.loads(target.read_text()) if target.exists() else {}
        except ValueError:
            doc = {}
        if p.returncode == 0:
            pid = ((doc.get("result") or {}).get("process") or {}).get("processIdentifier")
            if pid:
                try:
                    _xcrun("devicectl", "device", "process", "terminate", "--device", device, "--pid", str(pid),
                           timeout=30)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            return {"state": "ok", "detail": ""}
        blob = text + " " + json.dumps(doc.get("error") or {})
        if UNTRUSTED.search(blob):
            return {"state": "untrusted", "detail": text[-300:]}
        if LOCKED.search(blob):
            return {"state": "locked", "detail": text[-300:]}
        return {"state": "unknown", "detail": text[-300:]}


def preflight(say, device=None):
    """Raises Unreachable (the sentence) when the phone will not open the app for want of verification."""
    device = device or os.environ.get("RICHOS_IOS_DEVICE")
    if not device:
        say("phone network check skipped: RICHOS_IOS_DEVICE names no phone")
        return
    result = launch_check(device)
    if result["state"] == "untrusted":
        raise Unreachable(FIX + f" (devicectl said: {result['detail']})")
    if result["state"] != "ok":
        say(f"phone network check could not decide ({result['state']}: {result['detail']}); the run goes on")


def _restore_command():
    named = os.environ.get("RICHOS_PHONE_NET_RESTORE")
    if named:
        return shlex.split(named)
    return None


def restore(say):
    """Ask the phone to put its Wi-Fi back on. True when the command ran and exited 0."""
    named = _restore_command()
    scratch = None
    try:
        if named:
            command = named
        else:
            root = Path("/Volumes/E1TB/tmp/claude")
            root.mkdir(parents=True, exist_ok=True)
            scratch = tempfile.mkdtemp(prefix="phone-net-", dir=str(root))
            command = [sys.executable, str(PHONE_IOS), "wifi-restore", "--out", scratch]
        p = subprocess.run(command, capture_output=True, text=True, timeout=600)
        if p.returncode != 0:
            say(f"putting the phone's Wi-Fi back failed (exit {p.returncode}): {(p.stdout + p.stderr).strip()[-300:]}")
        return p.returncode == 0
    except (OSError, subprocess.TimeoutExpired) as error:
        say(f"putting the phone's Wi-Fi back failed: {error}")
        return False
    finally:
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)


def postflight(say, device=None):
    """After the run, however it ended. Never raises. Returns None when the phone is fine (or cannot be
    judged) and the sentence when the phone is still unable to open the app."""
    device = device or os.environ.get("RICHOS_IOS_DEVICE")
    if not device:
        return None
    try:
        result = launch_check(device)
        if result["state"] != "untrusted":
            return None
        say("the phone now refuses to open the app for want of Apple's verification: the run left its "
            "network off; putting the Wi-Fi back")
        restore(say)
        again = launch_check(device)
        if again["state"] == "untrusted":
            return "After the run " + FIX
        say("the phone's network is back: the app opens again")
        return None
    except Exception as error:  # noqa: BLE001: the after-check never changes the run's own outcome by crashing
        say(f"phone network check after the run failed: {error}")
        return None
