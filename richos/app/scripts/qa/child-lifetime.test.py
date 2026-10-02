#!/usr/bin/env python3
"""No phone needed: a stand-in idevicesyslog must die within 5 s of kill -9 of phone-ios.py."""
import os, signal, subprocess, sys, tempfile, time, unittest
from pathlib import Path

TOOL = Path(__file__).with_name("phone-ios.py")
ROOT = "/Volumes/E1TB/tmp/claude/zach-sonnet-relay1"


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class ChildLifetime(unittest.TestCase):
    def test_child_dies_when_tool_is_sigkilled(self):
        os.makedirs(ROOT, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT) as d:
            fake = Path(d, "idevicesyslog")
            fake.write_text('#!/bin/sh\ntrap "" PIPE\necho $$ > "%s/pid"\nwhile :; do echo RichOSNative line 2>/dev/null; sleep 0.2; done\n' % d)
            fake.chmod(0o755)
            env = dict(os.environ, PATH=d + ":" + os.environ["PATH"])
            tool = subprocess.Popen([sys.executable, str(TOOL), "syslog", "--device", "X", "--seconds", "600",
                                     "--out", d + "/out"], env=env, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
            pidfile = Path(d, "pid")
            end = time.time() + 10
            while not pidfile.exists() and time.time() < end:
                time.sleep(0.1)
            # wait for the fact: the tool has both of its children (the relay and its watchdog)
            while time.time() < end:
                kids = subprocess.run(["pgrep", "-P", str(tool.pid)], capture_output=True, text=True).stdout.split()
                if len(kids) >= 2:
                    break
                time.sleep(0.1)
            child = int(pidfile.read_text())
            self.assertTrue(alive(child))
            tool.send_signal(signal.SIGKILL)
            tool.wait()
            end = time.time() + 5
            while alive(child) and time.time() < end:
                time.sleep(0.1)
            gone = not alive(child)
            if not gone:
                os.kill(child, signal.SIGKILL)  # the pid this test read from its own stand-in
            self.assertTrue(gone, "the child outlived the tool")


if __name__ == "__main__":
    unittest.main()
