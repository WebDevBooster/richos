"""Exercise the real UI runner's ledger cleanup without launching a browser."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


UI = Path(__file__).resolve().parents[1] / 'ui/tests'


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ui-ledger-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scratch = self.root / 'scratch'
        self.scratch.mkdir()
        (self.root / 'lib').mkdir()
        shutil.copyfile(UI / 'run.js', self.root / 'run.js')
        shutil.copyfile(UI / 'lib/ui-sources.js', self.root / 'lib/ui-sources.js')
        (self.root / 'sample.js').write_text('''
const fs = require('fs');
const run = {check() {}};
run.check();
fs.appendFileSync(process.env.RICHOS_UI_TESTS_LEDGER,
  JSON.stringify({suite:'sample.js',label:'fixture',checks:1,failed:0})+'\\n');
''')
        self.env = {**os.environ, 'TMPDIR': str(self.scratch)}
        for name in ('NODE_OPTIONS', 'RICHOS_UI_TESTS_LEDGER'):
            self.env.pop(name, None)

    def runner(self, preload=None):
        args = ['node']
        if preload:
            args += ['--require', str(preload)]
        return args + [str(self.root / 'run.js')]

    def sweep(self, preload=None):
        result = subprocess.run(self.runner(preload), cwd=self.root, env=self.env,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('1 checks', result.stdout)

    def ledger(self, name, owner=None):
        directory = self.scratch / ('richos-ui-evidence-' + name)
        directory.mkdir()
        (directory / 'evidence.jsonl').write_text('retained evidence\n')
        if owner is not None:
            (directory / 'owner.pid').write_text(str(owner))
        return directory

    def test_another_runner_cannot_reap_a_ledger_during_owner_publication(self):
        # Pause the real runner at either observable publication window. A second
        # real runner sweeps while the first is alive but has no readable PID yet.
        for empty in (False, True):
            with self.subTest(empty_owner_file=empty):
                ready = self.root / 'ready'
                release = self.root / 'release'
                for file in (ready, release):
                    file.unlink(missing_ok=True)
                hook = self.root / 'pause-owner.cjs'
                hook.write_text('''
const fs = require('fs');
const write = fs.writeFileSync;
fs.writeFileSync = function(file, ...args) {
  if (String(file).endsWith('/owner.pid')) {
    if (EMPTY) write(file, '');
    write(READY, String(file));
    const deadline = Date.now() + 15000;
    while (!fs.existsSync(RELEASE)) {
      if (Date.now() > deadline) throw new Error('publication barrier expired');
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    }
  }
  return write.call(this, file, ...args);
};
'''.replace('EMPTY', str(empty).lower()).replace('READY', json.dumps(str(ready)))
                                 .replace('RELEASE', json.dumps(str(release))))
                child = subprocess.Popen(self.runner(hook), cwd=self.root, env=self.env,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 10
                    while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertTrue(ready.exists(), 'runner did not reach the publication barrier')
                    directory = Path(ready.read_text()).parent
                    self.sweep()
                    self.assertTrue(directory.exists(), 'live runner lost its unpublished ledger')
                    release.touch()
                    out, err = child.communicate(timeout=15)
                    self.assertEqual(child.returncode, 0, out + err)
                    self.assertFalse(directory.exists(), 'owner did not clean its completed ledger')
                finally:
                    release.touch()
                    if child.poll() is None:
                        child.kill()
                    child.communicate()

    def test_missing_and_invalid_owner_is_not_proof_of_death(self):
        dirs = [self.ledger(str(i), value) for i, value in enumerate(
            (None, '', '0', '-1', 'not-a-pid', '1.5', '999999999999999999999'))]
        self.sweep()
        self.assertTrue(all((d / 'evidence.jsonl').exists() for d in dirs))

    def test_live_owner_is_retained(self):
        directory = self.ledger('live', os.getpid())
        self.sweep()
        self.assertTrue(directory.exists())

    def test_confirmed_dead_owner_is_removed(self):
        child = subprocess.Popen(['node', '-e', 'process.exit(0)'])
        child.wait(timeout=10)
        directory = self.ledger('dead', child.pid)
        self.sweep()
        self.assertFalse(directory.exists())

    def test_permission_denied_is_not_proof_of_death(self):
        directory = self.ledger('permission', os.getpid())
        hook = self.root / 'deny-probe.cjs'
        hook.write_text("process.kill = () => { const e = new Error('denied'); e.code='EPERM'; throw e; };\n")
        self.sweep(hook)
        self.assertTrue(directory.exists())


if __name__ == '__main__':
    unittest.main()
