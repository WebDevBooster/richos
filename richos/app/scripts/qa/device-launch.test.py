#!/usr/bin/env python3
"""No phone needed: `rios device launch BUNDLE` opens an app by the one procedure, against a faked devicectl.

Connected check first (not connected: 0 launches, 0 reboots); open once; a trust refusal restarts the phone
once, waits, opens once more; refused twice exits non-zero; never a third launch."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).with_name("phone-ios.py")

# fake `xcrun`: argv[1] is "devicectl". It counts launches and reboots in $FAKE_DIR; $FAKE_LAUNCHES holds
# the comma-separated answer of each launch (ok or no).
FAKE = r'''#!/bin/bash
d="$FAKE_DIR"; shift
json=""; prev=""
for a in "$@"; do [ "$prev" = "--json-output" ] && json="$a"; prev="$a"; done
case "$1 $2" in
  "device info")
    [ -n "$json" ] && echo "{\"result\":{\"connectionProperties\":{\"tunnelState\":\"$FAKE_TUNNEL\",\"transportType\":\"localNetwork\"}}}" > "$json"
    exit 0 ;;
  "device reboot") echo x >> "$d/reboots"; exit 0 ;;
  "device process")
    echo x >> "$d/launches"
    n=$(wc -l < "$d/launches" | tr -d ' ')
    answer=$(echo "$FAKE_LAUNCHES" | cut -d, -f"$n")
    if [ "$answer" = ok ]; then echo "app console line"; exit 0; fi
    echo "ERROR: The application could not be launched because the Developer App Certificate is not trusted." >&2
    exit 1 ;;
esac
exit 0
'''


class DeviceLaunch(unittest.TestCase):
    def run_launch(self, tunnel, launches):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "xcrun"
            fake.write_text(FAKE)
            fake.chmod(0o755)
            (Path(tmp) / "launches").touch()
            (Path(tmp) / "reboots").touch()
            env = {**os.environ, "RICHOS_XCRUN": str(fake), "RICHOS_DEVICE_VERB": "rios", "FAKE_DIR": tmp,
                   "FAKE_TUNNEL": tunnel, "FAKE_LAUNCHES": launches, "RICHOS_PHONE_REBOOT_SETTLE": "0",
                   "RICHOS_PHONE_REBOOT_STEP": "0", "PYTHONDONTWRITEBYTECODE": "1"}
            p = subprocess.run([sys.executable, str(TOOL), "launch", "--device", "PHONE", "dev.example.app"],
                               capture_output=True, text=True, env=env, timeout=60)
            count = lambda name: len((Path(tmp) / name).read_text().split())
            return p, count("launches"), count("reboots")

    def test_not_connected_does_nothing(self):
        p, launches, reboots = self.run_launch("disconnected", "ok")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual((launches, reboots), (0, 0))
        self.assertIn("not connected", p.stderr)

    def test_opens_once(self):
        p, launches, reboots = self.run_launch("connected", "ok")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((launches, reboots), (1, 0))
        self.assertIn("app console line", p.stdout)

    def test_refused_then_ok_reboots_once(self):
        p, launches, reboots = self.run_launch("connected", "no,ok")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((launches, reboots), (2, 1))

    def test_refused_twice_fails_after_two_launches(self):
        p, launches, reboots = self.run_launch("connected", "no,no,ok")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual((launches, reboots), (2, 1))
        self.assertIn("not trusted", p.stderr)


if __name__ == "__main__":
    unittest.main()
