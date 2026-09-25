#!/usr/bin/env python3
"""Drive a PHYSICAL iPhone through its real controls, and read what an app leaves running.

    phone-ios.py check STEPS.json                  validate a step list; touches no device
    phone-ios.py run STEPS.json --out DIR [--allowance S] [--prebuilt --stamp STAMP.json]
                                                   run the steps through XCUITest on the phone
                                                   (`rios device verify script`), then write
                                                   DIR/steps.jsonl (one line per step, phone clock)
                                                   and DIR/attachments/ (the steps' shots and trees);
                                                   --prebuilt reuses the earlier build's exact products
                                                   (about two minutes saved per run) and refuses unless
                                                   the app still hashes to STAMP.json (perf.py stamp)
    phone-ios.py parse-log TEST.log                the PHONE_STEP lines of a finished run
    phone-ios.py pair-steps MAC-TEST-CONFIG.json   the real-control pairing steps for a lab's current
                                                   link, with all six words checked before They match
    phone-ios.py procs [--name NAME]               the phone's processes whose executable ends in
                                                   NAME (default RichOSNative): pid and path only
    phone-ios.py apps                              which RichConnect builds and test runners are installed
    phone-ios.py lock                              the phone's lock state
    phone-ios.py battery                           level, charging and external power
    phone-ios.py syslog --seconds S --out FILE     the phone's log for S seconds, keeping ONLY lines that
                                                   name RichOSNative or dev.richos.connect
    (`syslog` and `battery` take --network for an unplugged phone: libimobiledevice's -n, same pairing)

The iPhone counterpart of phone-android.py. iOS 26 offers no shell on the phone, so every tap,
type, Home, lock and screenshot goes through one XCUITest check that executes a list of steps
(`PhysicalDeviceTests.testScript`). Each step prints one `PHONE_STEP` JSON line with its start and
end on the phone's clock, which this tool collects. A failed step stops the list; nothing is
retried. Validation happens here, before anything is built, so a typo costs a second, not a build.

Steps are JSON objects with "do" and, where needed, "id" (accessibility identifier), "label"
(substring of the accessibility label) or "kind" ("switch" or "button": the first one), "in":
"springboard" for system UI or "tailscale" for the route's own app, "timeout" (s) and "optional":
true (a failure is logged, the list continues). A list that touches Tailscale may not take a shot,
tree or audit: that screen is the person's own account.

    launch{textSize} activate terminate home lock{person: true} sleep{seconds} mark{label} state audit
    waitState{state: background|suspended|foreground|notRunning}
    wait tap exists gone value{equals} type{text, delete, focus} press{seconds, drag:[dx,dy]}
    swipe{direction} count{label, equals} alert{button} shot{name, screen} tree{name}

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
}
NEEDS_TARGET = {"wait", "tap", "exists", "gone", "value", "type", "press", "swipe"}
COMMON = {"do", "id", "label", "kind", "in", "timeout", "optional"}
PLACES = ("springboard", "tailscale")
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
        if "in" in step and step["in"] not in PLACES:
            raise CannotAnswer(f"step {i}: 'in' may only be 'springboard' or 'tailscale'")
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


def pair_steps(config_path):
    """The real-control pairing a person does, from the lab's own mac-test-config.json: open the
    link field, enter the link, check all six words BEFORE pressing They match, then the consent."""
    try:
        config = json.loads(Path(config_path).read_text())
    except (FileNotFoundError, json.JSONDecodeError) as error:
        raise CannotAnswer(f"cannot read the lab configuration {config_path}: {error}")
    link, words = config.get("pairLink"), str(config.get("words", "")).split()
    if not (isinstance(link, str) and link.startswith("https://") and "#pair=" in link) or len(words) != 6:
        raise CannotAnswer("the lab configuration has no current HTTPS pairing link and six words")
    steps = [{"do": "launch"}, {"do": "tap", "id": "pair.link", "timeout": 10},
             {"do": "type", "id": "pairlink.field", "text": link}, {"do": "tap", "id": "pairlink.submit"},
             {"do": "wait", "id": "pair.match", "timeout": 20}]
    steps += [{"do": "count", "label": f"Word {n}: {word}", "equals": 1} for n, word in enumerate(words, 1)]
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


def run(args):
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
    summary = {"passed": p.returncode == 0 and not failed and len(rows) == len(steps),
               "steps": len(steps), "logged": len(rows), "failed": failed[:1],
               "result": result, "testLog": str(log), "out": str(out),
               "attachments": str(attachments) if exported.returncode == 0 else None,
               "attachmentsError": None if exported.returncode == 0 else exported.stderr.strip()[-300:]}
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
    return emit({"passcodeRequired": required.group(1) == "true",
                 "unlockedSinceBoot": "unlockedSinceBoot: true" in p.stdout})


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
    sub.add_parser("parse-log").add_argument("log")
    sub.add_parser("pair-steps").add_argument("config")
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
            print(json.dumps(pair_steps(args.config), indent=1))
            return 0
        if args.command == "parse-log":
            try:
                return emit({"steps": parse_log(Path(args.log).read_text(errors="replace"))})
            except FileNotFoundError:
                raise CannotAnswer(f"no log at {args.log}")
        return {"run": run, "procs": procs, "apps": apps, "lock": lock, "battery": battery,
                "syslog": syslog}[args.command](args)
    except CannotAnswer as error:
        return emit({"error": str(error)}, 2)
    except subprocess.TimeoutExpired as error:
        return emit({"error": f"{error.cmd[0]} did not answer in {error.timeout} s"}, 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
