#!/usr/bin/env python3
"""Small execution-boundary regressions using the shipped runners and receipts."""
import datetime
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

import engine_pass

LIB = Path(__file__).resolve().parent


class Boundaries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="runner-boundaries-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.engine = self.root / "repo/engine"
        (self.engine / "scripts/lib").mkdir(parents=True)
        (self.engine / "scripts/hooks").mkdir()
        (self.engine / "VERSION").write_text("1.0.0-test\n")
        for name in ("ci-shard.sh", "ci-units.sh", "run-all-tests.sh"):
            shutil.copy2(LIB.parent / name, self.engine / "scripts" / name)
        for name in ("ci-receipts.py", "leak-canary.sh", "record-canary.sh", "tree-witness.sh",
                     "proc_tree.py", "worker_tokens.py", "engine_pass.py", "stopwatch.sh"):
            shutil.copy2(LIB / name, self.engine / "scripts/lib" / name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("RICHOS_")}
        self.env.update(TMPDIR=str(self.root / "tmp"), PYTHONDONTWRITEBYTECODE="1",
                        CLAUDE_CONFIG_DIR=str(self.root / "config"),
                        RICHOS_MACHINE_WORKERS=str(self.root / "machine"),
                        RICHOS_ENGINE_PASS_DIR=str(self.root / "slot"),
                        RICHOS_VERIFICATION_CONTAMINATION=str(self.root / "contamination"))
        for name in ("tmp", "config/state", "bin"):
            (self.root / name).mkdir(parents=True)

    def snapshot(self):
        for args in (("init", "-q", "-b", "main"), ("add", "-A"),
                     ("commit", "-q", "--allow-empty", "-m", "fixture")):
            subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=fixture",
                            "-c", "user.email=fixture@example.invalid", *args],
                           cwd=self.engine.parent, check=True, capture_output=True)

    def invoke(self, *args):
        return subprocess.run(args, cwd=self.engine, env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)

    def known_unit(self, exit_code=1):
        uid = "scripts/lib/known.test.sh"
        (self.engine / uid).write_text("touch " + shlex.quote(str(self.root / "executed")) +
                                       "\nexit %d\n" % exit_code)
        expires = (datetime.date.today() + datetime.timedelta(days=1)).isoformat()
        (self.engine / "scripts/lib/ci-known-red.tsv").write_text(
            f"{uid}\t2026-09-26\t{expires}\tfixture\tfixture\tDeclared assertion failure\n")
        return uid

    def inject(self, code):
        wrapper = f'''#!{sys.executable}
import os, pathlib, sys
if len(sys.argv) > 2 and sys.argv[1].endswith('/lib/worker_tokens.py') and sys.argv[2] == 'machine':
    sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
    import worker_tokens
{code}
    sys.exit(worker_tokens.main(sys.argv[2:]))
os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])
'''
        path = self.root / "bin/python3"
        path.write_text(wrapper)
        path.chmod(0o755)
        self.env["PATH"] = str(path.parent) + os.pathsep + self.env["PATH"]

    def shard(self, uid):
        self.snapshot()
        receipt = self.root / "receipt.jsonl"
        result = self.invoke("bash", "scripts/ci-shard.sh", "--only-units", uid,
                             "--receipt", str(receipt))
        self.assertTrue(receipt.exists(), result.stdout)
        row = json.loads(receipt.read_text())
        return result, row

    def verify(self, row):
        plan = self.root / "plan"
        plan.write_text(row["unit"] + "\n")
        return subprocess.run([sys.executable, str(LIB / "ci-receipts.py"), "verify", "--plan", str(plan)],
                              input=json.dumps(row), text=True, capture_output=True, timeout=5)

    def test_refused_known_red_never_earns_coverage(self):
        uid = self.known_unit()
        self.inject("    def reject(*a, **kw): raise TimeoutError('fixture: no permit')\n"
                    "    worker_tokens.Budget.acquire = reject")
        result, row = self.shard(uid)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / "executed").exists())
        self.assertEqual(row["verdict"], "NOT-ADMITTED")
        self.assertEqual(row["execution_status"], "not-admitted")
        self.assertNotEqual(self.verify(row).returncode, 0)
        row["verdict"] = "KNOWN-RED"
        self.assertNotEqual(self.verify(row).returncode, 0, "verifier must check execution too")

    def test_infrastructure_exit_is_not_a_known_assertion_failure(self):
        result, row = self.shard(self.known_unit(125))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.root / "executed").exists())
        self.assertEqual(row["verdict"], "INFRASTRUCTURE-ERROR")
        self.assertNotEqual(self.verify(row).returncode, 0)

    def test_missing_timing_cannot_be_accepted(self):
        uid = self.known_unit()
        self.inject("    def broken(*a, **kw): return 1\n    worker_tokens.machine_command = broken")
        result, row = self.shard(uid)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / "executed").exists())
        self.assertEqual(row["verdict"], "INFRASTRUCTURE-ERROR")
        self.assertNotEqual(self.verify(row).returncode, 0)

    def test_executed_declared_failure_retains_known_red_policy(self):
        result, row = self.shard(self.known_unit())
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.root / "executed").exists())
        self.assertEqual(row["verdict"], "KNOWN-RED")
        self.assertEqual(self.verify(row).returncode, 0)

    def test_serial_source_contamination_stops_and_notifies_parent(self):
        source = self.engine / "subject"
        source.write_text("original\n")
        (self.engine / "scripts/lib/aa.test.sh").write_text("echo changed > " + shlex.quote(str(source)))
        (self.engine / "scripts/lib/zz.test.sh").write_text("touch " + shlex.quote(str(self.root / "later")))
        self.snapshot()
        result = self.invoke("bash", "scripts/run-all-tests.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("QUARANTINED", result.stdout)
        self.assertFalse((self.root / "later").exists(), result.stdout)
        self.assertTrue(list((self.root / "contamination").glob("*.json")))

    def test_serial_assertion_failure_preserves_independent_work(self):
        (self.engine / "scripts/lib/aa.test.sh").write_text("exit 1\n")
        (self.engine / "scripts/lib/zz.test.sh").write_text("touch " + shlex.quote(str(self.root / "later")))
        self.snapshot()
        result = self.invoke("bash", "scripts/run-all-tests.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.root / "later").exists(), result.stdout)
        self.assertFalse((self.root / "contamination").exists())

    def test_slot_parent_close_does_not_unlock_inherited_descriptor(self):
        path = self.root / "inherited.lock"
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        slot = engine_pass.Slot(fd, 0)
        child = subprocess.Popen([sys.executable, "-c", "print('ready',flush=True); input()"],
                                 pass_fds=(fd,), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), "ready")
            slot.release()
            self.assertTrue(engine_pass._locked(str(path)))
        finally:
            slot.release()
            child.communicate("\n", timeout=5)
        self.assertFalse(engine_pass._locked(str(path)))


if __name__ == "__main__":
    unittest.main()
