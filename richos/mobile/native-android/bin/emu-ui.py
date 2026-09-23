#!/usr/bin/env python3
"""Drive the app on an EMULATOR the way a person does: find a control by its words, tap it.

    emu-ui.py --serial emulator-NNNN wait <text> [--timeout S]      until a node shows <text>
    emu-ui.py --serial emulator-NNNN tap <text> [--timeout S]       tap the node showing <text>
    emu-ui.py --serial emulator-NNNN gone <text> [--timeout S]      until no node shows <text>
    emu-ui.py --serial emulator-NNNN texts                          every text and description on screen
    emu-ui.py --serial emulator-NNNN type-file <file>               type the file's text into the focused field

A node "shows" <text> when its text or its content description equals it, or starts with it
when <text> ends in "…". The screen is read with `uiautomator dump`, as `bin/randroid emu verify`
reads it. Every call names the emulator by serial (never a bare adb: a physical phone may be
attached), and only an emulator-NNNN serial is accepted. `type-file` reads the text from a file so
a single-use pairing code never appears in a process list. Prints one JSON line; exits 1 when the
text is not found in time.
"""
import argparse
import json
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


def adb(serial, *args, check=True):
    return subprocess.run(["adb", "-s", serial, *args], check=check, capture_output=True, text=True).stdout


def nodes(serial):
    # A dump taken while the window changes returns no root; the caller retries.
    adb(serial, "shell", "uiautomator", "dump", "/sdcard/emu-ui.xml", check=False)
    raw = adb(serial, "exec-out", "cat", "/sdcard/emu-ui.xml", check=False)
    adb(serial, "shell", "rm", "-f", "/sdcard/emu-ui.xml", check=False)
    if not raw.startswith("<?xml"):
        return []
    try:
        return list(ET.fromstring(raw).iter("node"))
    except ET.ParseError:
        return []


def shows(node, want):
    for value in (node.get("text") or "", node.get("content-desc") or ""):
        if value == want or (want.endswith("…") and value.startswith(want[:-1])):
            return True
    return False


def center(node):
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds", "[0,0][0,0]")))
    return (x1 + x2) // 2, (y1 + y2) // 2


def find(serial, want, timeout):
    deadline = time.time() + timeout
    while True:
        found = [n for n in nodes(serial) if shows(n, want)]
        if found or time.time() > deadline:
            return found
        time.sleep(0.5)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--serial", required=True)
    p.add_argument("command", choices=["wait", "tap", "gone", "texts", "type-file"])
    p.add_argument("value", nargs="?")
    p.add_argument("--timeout", type=float, default=15)
    a = p.parse_args()
    if not re.fullmatch(r"emulator-\d+", a.serial):
        print(json.dumps({"ok": False, "error": "emulators only: --serial emulator-NNNN"}))
        return 2
    started = time.time()
    if a.command == "texts":
        seen = [v for n in nodes(a.serial) for v in (n.get("text"), n.get("content-desc")) if v]
        print(json.dumps({"ok": True, "texts": seen}))
        return 0
    if a.command == "type-file":
        text = open(a.value, encoding="utf-8").read().strip()
        # `input text` takes one shell word: escape what the device shell would read specially.
        escaped = re.sub(r"([\\\"'`$&|;<>()#*?~ ])", r"\\\1", text).replace("%", "%%")
        subprocess.run(["adb", "-s", a.serial, "shell", "input", "text", escaped], check=True, capture_output=True)
        print(json.dumps({"ok": True, "typed": len(text)}))
        return 0
    if a.command == "gone":
        deadline = time.time() + a.timeout
        while any(shows(n, a.value) for n in nodes(a.serial)):
            if time.time() > deadline:
                print(json.dumps({"ok": False, "still": a.value, "waitedS": round(time.time() - started, 1)}))
                return 1
            time.sleep(0.5)
        print(json.dumps({"ok": True, "gone": a.value, "waitedS": round(time.time() - started, 1)}))
        return 0
    found = find(a.serial, a.value, a.timeout)
    if not found:
        print(json.dumps({"ok": False, "missing": a.value, "waitedS": round(time.time() - started, 1)}))
        return 1
    if a.command == "tap":
        x, y = center(found[0])
        adb(a.serial, "shell", "input", "tap", str(x), str(y))
        print(json.dumps({"ok": True, "tapped": a.value, "at": [x, y], "waitedS": round(time.time() - started, 1)}))
    else:
        print(json.dumps({"ok": True, "shown": a.value, "waitedS": round(time.time() - started, 1)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
