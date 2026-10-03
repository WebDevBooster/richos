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
                that names the missing verification restarts the PHONE once (the function below,
                CEO 2026-10-02: no passcode, so it comes back usable without a hand) and opens the app
                again; only when that still fails does it raise `Unreachable` with ONE plain sentence,
                before anything is built, installed or run. A locked phone, a missing tool or any other
                answer is not a verdict on the network: it is said and the run goes on.
    postflight  the same launch after the run, however the run ended. When the phone now refuses,
                the run left its network off (a step list that switches Wi-Fi off in Settings and did not
                get to switch it back): `RICHOS_PHONE_NET_RESTORE` (default `phone-ios.py wifi-restore`)
                reads the Wi-Fi switch in Settings and turns it on, and the launch is tried once more.
                What is still wrong is said in a sentence; it is never hidden behind the run's own exit.

The phone is named by RICHOS_IOS_DEVICE (what xcodebuild and devicectl both accept). Nothing here
installs, uninstalls or erases anything, and it never touches the phone's screen beyond opening and
closing the app and, when the trust check fails, one restart of the phone.
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
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

# Settings shows no Verify App button for this team-provisioned app (2026-09-27, and the CEO 2026-10-02);
# sending a person to look for one wastes his time. `rios device trust` names the actual cause.
FIX = ("The test iPhone cannot reach Apple to verify RichConnect's developer certificate, so iOS will not open "
       "the app, and restarting the phone once (`rios device reboot`) did not clear it; `rios device trust` names "
       "why (the phone's DNS, VPN or profiles). Settings has no Verify App button for this app, so do not look "
       "for one: the phone's Wi-Fi has to reach Apple (Tailscale and any VPN off).")

# When the trust check fails, the automation restarts the phone itself (CEO 2026-10-02: the test iPhone has
# no passcode, so it comes back usable on its own). On 2026-10-02 the phone's Wi-Fi DNS server stopped
# answering it (a capture on the phone: its queries to the router went out and nothing came back, while
# the router answered the Mac) and a restart of the phone cleared it. After the phone is back, RichConnect
# is opened every SETTLE_STEP seconds until iOS verifies it or SETTLE_SECONDS pass (Wi-Fi rejoining and
# Apple's check take a moment after boot).
SETTLE_SECONDS = float(os.environ.get("RICHOS_PHONE_REBOOT_SETTLE", "120"))
SETTLE_STEP = float(os.environ.get("RICHOS_PHONE_REBOOT_STEP", "10"))


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


def check_ready(device):
    """Is the phone connected to this Mac and on Wi-Fi? (ok, one sentence). Reads only: no launch.
    devicectl's tunnelState says connected; its transportType says how: 'localNetwork' is Wi-Fi. A cable
    ('wired') proves the connection but devicectl does not report the phone's Wi-Fi, so RICHOS_PHONE_WIFI_CHECK
    (a command, exit 0 = on Wi-Fi) decides there; without it a cable connection is accepted, and said so."""
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "details.json"
        try:
            _xcrun("devicectl", "device", "info", "details", "--device", device, "--json-output", str(target),
                   timeout=60)
            props = (json.loads(target.read_text()).get("result") or {}).get("connectionProperties") or {}
        except (OSError, subprocess.TimeoutExpired, ValueError):
            return False, "the iPhone is not connected (devicectl did not answer)"
    if props.get("tunnelState") != "connected":
        return False, "the iPhone is not connected / not on Wi-Fi (devicectl: tunnel " + str(props.get("tunnelState")) + ")"
    if props.get("transportType") == "localNetwork":
        return True, "connected over Wi-Fi"
    named = os.environ.get("RICHOS_PHONE_WIFI_CHECK")
    if named:
        if subprocess.run(shlex.split(named), capture_output=True).returncode == 0:
            return True, "connected by cable; Wi-Fi confirmed by RICHOS_PHONE_WIFI_CHECK"
        return False, "the iPhone is connected by cable but not on Wi-Fi"
    return True, "connected by cable; devicectl does not report Wi-Fi, so it is not confirmed"


def restart_and_wait(device, say):
    """Restart the phone (devicectl, a full reboot, waiting until it is connected again), then wait, with
    NO launches, until it is connected and on Wi-Fi or SETTLE_SECONDS pass. (ok, detail, seconds)."""
    started = time.monotonic()
    try:
        p = _xcrun("devicectl", "device", "reboot", "--device", device, "--wait-for-device", timeout=600)
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, f"devicectl reboot did not answer ({type(error).__name__})", 0
    if p.returncode != 0:
        return False, "devicectl reboot failed: " + ((p.stderr or "") + (p.stdout or "")).strip()[-300:], 0
    deadline = time.monotonic() + SETTLE_SECONDS
    while True:
        ok, detail = check_ready(device)
        if ok or time.monotonic() + SETTLE_STEP > deadline:
            break
        time.sleep(SETTLE_STEP)
    seconds = time.monotonic() - started
    say(f"the phone restarted; after {seconds:.0f} s: {detail}")
    return ok, detail, seconds


def launch_app(device, bundle, app_args, say, out=None):
    """`rios device launch`: the one procedure for opening an installed app (CEO 2026-10-02/03).
    0. phone not connected / not on Wi-Fi: nothing happens (no launch, no reboot).
    1. open the app once. 2. refused for want of verification: restart the phone once. 3. wait until it is
    back, connected and on Wi-Fi. 4. open the app once more. 5. refused again: say exactly why.
    Never more than two launches and one restart: every failed launch pops a notification on the phone.
    Returns (exit code, {'launches', 'reboots', 'state', 'detail'}); the app's console goes to `out`."""
    out = out or sys.stdout
    result = {"launches": 0, "reboots": 0, "state": "unknown", "detail": ""}
    ok, detail = check_ready(device)
    if not ok:
        result.update(state="not-ready", detail=detail)
        return 2, result
    say(detail)

    def once():
        result["launches"] += 1
        with tempfile.TemporaryDirectory() as tmp:
            try:
                p = subprocess.Popen([os.environ.get("RICHOS_XCRUN") or "xcrun", "devicectl", "device", "process",
                                      "launch", "--device", device, "--terminate-existing", "--console",
                                      "--json-output", str(Path(tmp) / "launch.json"), bundle, *app_args],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            except OSError as error:
                return {"state": "unknown", "detail": f"devicectl did not start ({error})"}
            lines = []
            for line in p.stdout:
                lines.append(line)
                out.write(line)
                out.flush()
            code = p.wait()
            text = "".join(lines).strip()
            if code == 0:
                return {"state": "ok", "detail": ""}
            doc = Path(tmp) / "launch.json"
            blob = text + " " + (doc.read_text() if doc.exists() else "")
            return {"state": "untrusted" if UNTRUSTED.search(blob) else "failed", "detail": text[-600:]}

    first = once()
    result.update(state=first["state"], detail=first["detail"])
    if first["state"] == "ok":
        return 0, result
    if first["state"] != "untrusted":
        return 1, result
    say("iOS refused to open the app (" + first["detail"].replace("\n", " ")[-200:] + "); restarting the phone once")
    result["reboots"] += 1
    ok, detail, _ = restart_and_wait(device, say)
    if not ok:
        result.update(state="not-ready", detail="after the restart: " + detail)
        return 2, result
    second = once()
    result.update(state=second["state"], detail=second["detail"])
    return (0 if second["state"] == "ok" else 1), result


def reboot(device, say):
    """Restart the phone (devicectl, a full reboot, waiting until it is connected again), then open
    RichConnect until iOS verifies it or SETTLE_SECONDS pass. Returns the last launch_check result with
    'rebooted' and the seconds it took. Nothing is installed, removed or erased; the app's data stays."""
    started = time.monotonic()
    try:
        p = _xcrun("devicectl", "device", "reboot", "--device", device, "--wait-for-device", timeout=600)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"state": "unknown", "detail": f"devicectl reboot did not answer ({type(error).__name__})", "rebooted": False}
    if p.returncode != 0:
        return {"state": "unknown", "rebooted": False,
                "detail": "devicectl reboot failed: " + ((p.stderr or "") + (p.stdout or "")).strip()[-300:]}
    back = time.monotonic() - started
    say(f"the phone restarted and is connected again after {back:.0f} s; opening RichConnect until iOS verifies it")
    deadline = time.monotonic() + SETTLE_SECONDS
    tries = 0
    while True:
        result = launch_check(device)
        tries += 1
        if result["state"] == "ok" or time.monotonic() + SETTLE_STEP > deadline:
            break
        time.sleep(SETTLE_STEP)
    return {**result, "rebooted": True, "backAfterSeconds": round(back), "launchTries": tries,
            "totalSeconds": round(time.monotonic() - started)}


def preflight(say, device=None):
    """Raises Unreachable (the sentence) when the phone will not open the app for want of verification,
    after one restart of the phone (reboot) has not cleared it."""
    device = device or os.environ.get("RICHOS_IOS_DEVICE")
    if not device:
        say("phone network check skipped: RICHOS_IOS_DEVICE names no phone")
        return
    result = launch_check(device)
    if result["state"] == "untrusted":
        say("the phone cannot verify RichConnect with Apple; restarting it once (rios device reboot): "
            + result["detail"].replace("\n", " ")[-200:])
        result = reboot(device, say)
        if result["state"] != "ok":
            raise Unreachable(FIX + f" (after the restart: {result['state']}: {result['detail']})")
        say(f"after the restart the phone opens RichConnect ({result['totalSeconds']} s): the run goes on")
        return
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
