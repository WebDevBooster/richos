#!/usr/bin/env python3
"""Test actual startup in a disposable guest with or without persisted pairing.

First use scripts/testvm/run.sh to boot the guest. For the paired case, pair its
phone page through the UI. The same guest home and browser credential survive
this test's relaunch. No prompt is sent and no host window is opened.

  python3 src-tauri/tests/paired_startup.py VM --case unpaired --output OUT
  python3 src-tauri/tests/paired_startup.py VM --case paired --output OUT

The caller holds the VM reservation and owns testvm/stop.sh cleanup. This test
stops only the recorded app PID and records its replacement for that cleanup.
It checks startup and the real TLS listener's authentication challenge. Browser
reconnection with the existing credential is a separate UI proof.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

TOOLS = Path(__file__).resolve().parents[2] / "scripts" / "testvm"


def run(args):
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    state = Path(os.environ.get("TESTVM_ROOT", str(Path.home() / ".richos-testvm"))) / "run" / args.vm

    def guest(command):
        result = subprocess.run([str(TOOLS / "guest.sh"), args.vm, command],
                                text=True, capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError(result.stderr or result.stdout)
        return result.stdout.strip()

    payload = (state / "payload").read_text().strip()
    if not payload.startswith("/Users/") or "/testvm/" not in payload:
        raise ValueError("expected a disposable guest payload")
    home = payload + "/home"
    pairing = home + "/Library/Application Support/com.richos.app/phone/device.json"
    q = shlex.quote

    def pairing_hash():
        return guest("if test -f " + q(pairing) + "; then shasum -a 256 " + q(pairing) +
                     " | cut -d ' ' -f 1; fi")

    before = pairing_hash()
    if bool(before) != (args.case == "paired"):
        raise ValueError("fixture pairing does not match the requested case")
    old = (state / "app.pid").read_text().strip()
    if not old.isdigit():
        raise ValueError("expected a recorded app PID")
    exe = guest("ps -p " + old + " -o comm= || true")
    if exe and (not exe.startswith(payload + "/") or not exe.endswith("/richos-tauri")):
        raise ValueError("recorded PID no longer belongs to this guest payload")
    app = args.app or payload + "/RichOS.app"
    if not app.startswith(payload + "/") or not app.endswith(".app"):
        raise ValueError("app must belong to this disposable payload")
    guest("kill -TERM " + old + " 2>/dev/null || true")
    for _ in range(30):
        if not guest("kill -0 " + old + " 2>/dev/null && echo alive || true"):
            break
        time.sleep(.2)
    else:
        guest("kill -KILL " + old + " 2>/dev/null || true")
    prior = {line.split()[0] for line in guest("ps -axo pid=").splitlines()}
    log = payload + "/startup-regression-" + str(time.time_ns()) + ".log"
    env = {"HOME": home, "CLAUDE_CONFIG_DIR": home + "/.claude",
           "RICHOS_ACTIVATION": "regular", "DISABLE_AUTOUPDATER": "1",
           "RICHOS_ENGINE_DIR": payload + "/engine",
           "RICHOS_CLAUDE_BIN": "/Users/admin/.local/bin/claude"}
    command = ["open", "-n", "-a", app, "--stdout", log, "--stderr", log]
    for key, value in env.items():
        command += ["--env", key + "=" + value]
    guest(shlex.join(command))
    result = {"case": args.case, "app": app, "old_pid": int(old), "test_send_attempts": 0,
              "pairing_sha256_before": before, "passed": False}
    try:
        deadline = time.monotonic() + args.timeout
        text = ""
        while time.monotonic() < deadline:
            for line in guest("ps -axo pid=,ppid=,comm=").splitlines():
                parts = line.split(None, 2)
                if (len(parts) == 3 and parts[0] not in prior and parts[1] == "1"
                        and parts[2].startswith(payload + "/") and parts[2].endswith("/richos-tauri")):
                    result["pid"] = int(parts[0])
                    (state / "app.pid").write_text(parts[0] + "\n")
            text = guest("cat " + q(log) + " 2>/dev/null || true")
            (out / "boot.log").write_text(text + "\n")
            if "panicked at" in text or "state() called before manage()" in text:
                panic = next(line for line in text.splitlines() if "state() called before manage()" in line or "panicked at" in line)
                raise AssertionError("startup panic: " + panic)
            if "[richos] boot complete" in text:
                break
            time.sleep(.5)
        else:
            raise AssertionError("startup did not reach boot complete within the deadline")
        if "pid" not in result or not guest("kill -0 " + str(result["pid"]) + " && echo alive"):
            raise AssertionError("no live app after startup")
        result["pairing_sha256_after"] = pairing_hash()
        if result["pairing_sha256_after"] != before:
            raise AssertionError("startup changed or removed the persisted pairing")
        listening = [line for line in text.splitlines() if "the phone channel is listening on" in line]
        if args.case == "paired":
            if not listening:
                raise AssertionError("paired startup never started the real bridge/listener")
            result["listener"] = listening[-1]
            origin = listening[-1].split("pairing at ", 1)[1].strip()
            # No -k: the tailnet certificate must verify on this guest.
            response = guest("curl --silent --show-error --max-time 15 -D - " +
                             q(origin.rstrip("/") + "/api/threads"))
            (out / "phone-response.txt").write_text(response + "\n")
            if "404" not in response.splitlines()[0] or "x-richos-challenge:" not in response.lower():
                raise AssertionError("phone route did not respond with its authentication challenge")
        elif listening:
            raise AssertionError("unpaired startup unexpectedly opened the phone listener")
        result["boot_complete"] = next(line for line in text.splitlines() if "[richos] boot complete" in line)
        result["passed"] = True
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vm")
    parser.add_argument("--case", choices=("paired", "unpaired"), required=True)
    parser.add_argument("--app", help="bundle path inside the disposable guest payload")
    parser.add_argument("--output", type=Path, required=True, help="new evidence directory")
    parser.add_argument("--timeout", type=float, default=60)
    run(parser.parse_args())
