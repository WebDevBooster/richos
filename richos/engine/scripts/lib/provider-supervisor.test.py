#!/usr/bin/env python3
"""Real OS process tests with a fictional provider, never the user's sessions."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SUPERVISOR=Path(__file__).resolve().parents[1]/"provider-supervisor.py"
def alive(pid):
    result=subprocess.run(["/bin/ps","-o","stat=","-p",str(pid)],text=True,capture_output=True)
    return result.returncode==0 and bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")

class Supervisor(unittest.TestCase):
    def test_parent_crash_stops_owned_provider_and_child_but_preserves_unrelated_process(self):
        with tempfile.TemporaryDirectory(prefix="supervisor fixture ") as root:
            root=Path(root); receipt=root/"pids.json"
            fake=root/"provider.py"
            fake.write_text("import subprocess,os,json,time,sys\nchild=subprocess.Popen(['/bin/sleep','120'])\nopen(sys.argv[1],'w').write(json.dumps([os.getpid(),child.pid,os.environ['RICHOS_SESSION_PID']]))\ntime.sleep(120)\n")
            launcher=root/"desktop.py"
            launcher.write_text("import subprocess,sys,time\nsubprocess.Popen(sys.argv[1:],start_new_session=True)\ntime.sleep(120)\n")
            unrelated=subprocess.Popen(["/bin/sleep","120"])
            desktop=subprocess.Popen([sys.executable,str(launcher),sys.executable,str(SUPERVISOR),sys.executable,str(fake),str(receipt)])
            try:
                for _ in range(100):
                    if receipt.exists():break
                    time.sleep(.05)
                provider,child,identity=json.loads(receipt.read_text())
                self.assertEqual(str(provider),identity)
                self.assertTrue(alive(provider));self.assertTrue(alive(child))
                desktop.kill();desktop.wait()
                for _ in range(100):
                    if not alive(provider) and not alive(child):break
                    time.sleep(.05)
                self.assertFalse(alive(provider));self.assertFalse(alive(child))
                self.assertIsNone(unrelated.poll())
            finally:
                if desktop.poll() is None:desktop.kill();desktop.wait()
                unrelated.kill();unrelated.wait()

if __name__=="__main__":unittest.main()
