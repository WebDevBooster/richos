#!/usr/bin/env python3
"""No phone needed: `rios device launch BUNDLE` opens an app by the one procedure, against a faked devicectl.

Connected check first (not connected: 0 launches, 0 reboots); the phone's Wi-Fi must carry traffic before
the first open (a dead path is restarted once with nothing opened, so iOS never shows "Unable to Verify App"
for want of a network); open once; a trust refusal restarts the phone once, waits, opens once more; refused
twice exits non-zero; never a third launch and never a second restart. `rios device reboot` opens the app
once after the restart, never in a loop. `phone_net.py ensure` (run by `rios device install`) restarts a
dead path once."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).with_name("phone-ios.py")
PHONE_NET = Path(__file__).resolve().parents[4] / "richos/mobile/phone_net.py"
sys.path.insert(0, str(PHONE_NET.parent))
import phone_net  # noqa: E402

# fake `xcrun`: argv[1] is "devicectl". It counts launches and reboots in $FAKE_DIR; $FAKE_LAUNCHES holds
# the comma-separated answer of each launch (ok or no). Its details name the phone $FAKE_HOSTNAME.
FAKE = r'''#!/bin/bash
d="$FAKE_DIR"; shift
json=""; prev=""
for a in "$@"; do [ "$prev" = "--json-output" ] && json="$a"; prev="$a"; done
case "$1 $2" in
  "device info")
    [ -n "$json" ] && echo "{\"result\":{\"connectionProperties\":{\"tunnelState\":\"$FAKE_TUNNEL\",\"transportType\":\"localNetwork\",\"localHostnames\":[\"$FAKE_HOSTNAME\"]}}}" > "$json"
    exit 0 ;;
  "device reboot") echo x >> "$d/reboots"; exit 0 ;;
  "device process")
    echo "$@" >> "$d/calls"
    echo x >> "$d/launches"
    n=$(wc -l < "$d/launches" | tr -d ' ')
    answer=$(echo "$FAKE_LAUNCHES" | cut -d, -f"$n")
    if [ "$answer" = ok ]; then echo "app console line"; exit 0; fi
    echo "ERROR: The application could not be launched because the Developer App Certificate is not trusted." >&2
    exit 1 ;;
esac
exit 0
'''

# The phone's address lookup answers with a loopback address (its sync port refuses at once) beside its cable
# link's address, and `ping` answers per $FAKE_PATH: ok (always), dead (never), dead-then-ok (only once the
# phone has been restarted).
FAKE_DSCACHEUTIL = '#!/bin/bash\nprintf "ip_address: 127.0.0.1\\nip_address: 169.254.1.2\\n"\n'
FAKE_PING = r'''#!/bin/bash
case "$FAKE_PATH" in
  ok) ok=1 ;;
  dead-then-ok) [ -s "$FAKE_DIR/reboots" ] && ok=1 ;;
esac
if [ -n "$ok" ]; then echo "3 packets transmitted, 3 packets received, 0.0% packet loss"; exit 0; fi
echo "3 packets transmitted, 0 packets received, 100.0% packet loss"; exit 2
'''


# The cable measurement (`phone-ios.py net`'s JSON) per $FAKE_CABLE: ok (internet over the cable, not Wi-Fi), none.
FAKE_PROBE = r'''#!/bin/bash
if [ "$FAKE_CABLE" = ok ]; then
  echo '{"internet":{"reached":true,"primary":{"interface":"en2","address":"192.168.2.2","wifi":false,"leasedByThisMac":true}}}'
else
  echo '{"internet":{"reached":false,"tcpTimedOut":2,"primary":{"interface":"en2","address":"192.168.2.2","wifi":false}}}'
fi
'''


class DeviceLaunch(unittest.TestCase):
    def run_tool(self, argv, tunnel="connected", launches="ok", path="ok", cable="none"):
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "bin"
            bin_dir.mkdir()
            for name, body in (("xcrun", FAKE), ("dscacheutil", FAKE_DSCACHEUTIL), ("ping", FAKE_PING), ("probe", FAKE_PROBE)):
                (bin_dir / name).write_text(body)
                (bin_dir / name).chmod(0o755)
            (Path(tmp) / "launches").touch()
            (Path(tmp) / "reboots").touch()
            env = {**os.environ, "RICHOS_XCRUN": str(bin_dir / "xcrun"), "RICHOS_DEVICE_VERB": "rios",
                   "FAKE_DIR": tmp, "FAKE_TUNNEL": tunnel, "FAKE_LAUNCHES": launches, "FAKE_PATH": path, "FAKE_CABLE": cable,
                   "RICHOS_PHONE_NET_PROBE": str(bin_dir / "probe"),
                   "FAKE_HOSTNAME": "TESTPHONE" + phone_net.COREDEVICE_SUFFIX,
                   "PATH": f"{bin_dir}:{os.environ['PATH']}", "RICHOS_PHONE_REBOOT_SETTLE": "0",
                   "RICHOS_PHONE_REBOOT_STEP": "0", "PYTHONDONTWRITEBYTECODE": "1"}
            p = subprocess.run([sys.executable, *argv], capture_output=True, text=True, env=env, timeout=60)
            count = lambda name: len((Path(tmp) / name).read_text().split())
            calls = Path(tmp) / "calls"
            self.calls = calls.read_text() if calls.exists() else ""
            return p, count("launches"), count("reboots")

    def run_launch(self, tunnel, launches, path="ok", cable="none"):
        return self.run_tool([str(TOOL), "launch", "--device", "PHONE", "dev.example.app"], tunnel, launches, path, cable)

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
        self.assertIn("--console", self.calls)

    def test_refused_then_ok_reboots_once(self):
        p, launches, reboots = self.run_launch("connected", "no,ok")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((launches, reboots), (2, 1))

    def test_refused_twice_fails_after_two_launches(self):
        p, launches, reboots = self.run_launch("connected", "no,no,ok")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual((launches, reboots), (2, 1))
        self.assertIn("not trusted", p.stderr)

    def test_detach_opens_once_without_the_console(self):
        p, launches, reboots = self.run_tool([str(TOOL), "launch", "--device", "PHONE", "--detach", "dev.example.app"])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((launches, reboots), (1, 0))
        self.assertIn('"state": "ok"', p.stderr)
        self.assertNotIn("--console", self.calls)

    def test_dead_wifi_is_restarted_before_the_first_open(self):
        p, launches, reboots = self.run_launch("connected", "ok", path="dead-then-ok")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((launches, reboots), (1, 1))
        self.assertIn("carries no traffic", p.stderr)

    def test_dead_wifi_with_the_internet_over_the_cable_opens_the_app(self):
        p, launches, reboots = self.run_launch("connected", "ok", path="dead", cable="ok")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((launches, reboots), (1, 0))
        self.assertIn("the cable to this Mac", p.stderr)

    def test_dead_wifi_after_the_restart_opens_nothing(self):
        p, launches, reboots = self.run_launch("connected", "ok", path="dead")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual((launches, reboots), (0, 1))
        self.assertIn("carries no traffic", p.stderr)

    def test_refused_after_the_path_restart_is_not_restarted_again(self):
        p, launches, reboots = self.run_launch("connected", "no,ok", path="dead-then-ok")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual((launches, reboots), (1, 1))

    def test_reboot_opens_the_app_once_never_in_a_loop(self):
        p, launches, reboots = self.run_tool([str(TOOL), "reboot", "--device", "PHONE"], launches="no,no,no,ok")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual((launches, reboots), (1, 1))

    def test_reboot_into_a_dead_wifi_opens_nothing(self):
        p, launches, reboots = self.run_tool([str(TOOL), "reboot", "--device", "PHONE"], path="dead")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual((launches, reboots), (0, 1))

    def test_install_check_restarts_a_dead_wifi_once(self):
        p, launches, reboots = self.run_tool([str(PHONE_NET), "ensure", "--device", "PHONE"], path="dead-then-ok")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((launches, reboots), (0, 1))
        self.assertIn('"wifiCarriesTraffic": true', p.stdout)

    def test_install_check_leaves_a_working_wifi_alone(self):
        p, launches, reboots = self.run_tool([str(PHONE_NET), "ensure", "--device", "PHONE"], path="ok")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((launches, reboots), (0, 0))


if __name__ == "__main__":
    unittest.main()
