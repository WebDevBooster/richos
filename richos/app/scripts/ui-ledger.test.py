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
WORKER_TOKENS = Path(__file__).resolve().parents[2] / 'engine/scripts/lib/worker_tokens.py'


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
        shutil.copyfile(UI / 'lib/blocking-stdio.js', self.root / 'lib/blocking-stdio.js')
        (self.root / 'sample.js').write_text('''
const fs = require('fs');
const run = {check() {}};
run.check();
fs.appendFileSync(process.env.RICHOS_UI_TESTS_LEDGER,
  JSON.stringify({suite:'sample.js',label:'fixture',checks:1,failed:0})+'\\n');
''')
        self.env = {**os.environ, 'TMPDIR': str(self.scratch)}
        for name in ('NODE_OPTIONS', 'RICHOS_UI_TESTS_LEDGER', 'RICHOS_UI_NAV_EVIDENCE_DIR'):
            self.env.pop(name, None)
        # This suite can itself run under a proof run that holds a machine worker token. The
        # runner reads these to put its shards on the budget, so a fixture that did not ask
        # for a budget must not inherit the real one.
        for name in [n for n in self.env if n.startswith('RICHOS_WORKER_') or n == 'RICHOS_MACHINE_WORKERS']:
            self.env.pop(name)

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
    write(READY + '.pending', String(file));
    fs.renameSync(READY + '.pending', READY);
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

    def navigation_dir_seen_by_a_suite(self, *args, env=None):
        """Run the real runner sharded and report the evidence directory its suite inherited."""
        seen = self.root / 'nav-dir.txt'
        seen.unlink(missing_ok=True)
        (self.root / 'sample.js').write_text('''
const fs = require('fs');
const run = {check() {}};
run.check();
fs.writeFileSync(SEEN, process.env.RICHOS_UI_NAV_EVIDENCE_DIR || '<unset>');
fs.appendFileSync(process.env.RICHOS_UI_TESTS_LEDGER,
  JSON.stringify({suite:'sample.js',label:'fixture',checks:1,failed:0})+'\\n');
'''.replace('SEEN', json.dumps(str(seen))))
        result = subprocess.run(['node', str(self.root / 'run.js'), '--shards=1', *args], cwd=self.root,
                                env={**self.env, **(env or {})}, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return seen.read_text()

    def assertSameDirectory(self, reported, expected):
        # The runner names a directory, not a spelling of one. On macOS /var is a symlink to
        # /private/var: Node reports `__dirname` resolved and `path.resolve(--receipts)` as given,
        # so a string comparison passes only where TMPDIR happens to contain no symlink.
        self.assertEqual(os.path.realpath(reported), os.path.realpath(expected),
                         f'reported {reported!r}, expected {str(expected)!r}')

    def test_navigation_evidence_lands_beside_the_receipts_and_starts_empty(self):
        # A failed page load's bundle (ui/tests/lib/navigation-evidence.js) belongs in the
        # directory a build keeps, and a bundle left from an earlier run is not this run's.
        receipts = self.root / 'receipts'
        (receipts / 'navigation').mkdir(parents=True)
        stale = receipts / 'navigation' / 'contrast-1-1.json'
        stale.write_text('{}')
        self.assertSameDirectory(self.navigation_dir_seen_by_a_suite(f'--receipts={receipts}'),
                                 receipts / 'navigation')
        self.assertFalse(stale.exists(), 'a previous run\'s navigation bundle survived into this run')

    def test_navigation_evidence_outlives_a_run_that_owns_its_receipts(self):
        # Without --receipts the runner deletes its own receipt directory at exit, so evidence
        # written there would vanish with it; the harness's gitignored default is used instead.
        self.assertSameDirectory(self.navigation_dir_seen_by_a_suite(),
                                 self.root / '.shots' / 'navigation-failures')

    def test_an_explicit_navigation_evidence_directory_wins(self):
        chosen = self.root / 'chosen'
        self.assertEqual(self.navigation_dir_seen_by_a_suite(
            f'--receipts={self.root / "receipts"}', env={'RICHOS_UI_NAV_EVIDENCE_DIR': str(chosen)}),
            str(chosen))

    def test_a_sharded_run_prints_every_byte_before_it_exits(self):
        # Runs 20260928T230511Z-20aa349a and 20260928T233221Z-56bcde43: the nightly's log of
        # the UI gate stops in the middle of shard 2's output, mid-line, both times. Shards 3
        # and 4 and the coverage verdict never arrived, so the log could not say which check
        # failed. The `--shards` parent prints every shard's held output in one burst and then
        # exits the process. On macOS, Node writes to a pipe asynchronously, so whatever did
        # not fit in the pipe was still queued when the process exited, and was dropped.
        lines = 4000
        (self.root / 'sample.js').write_text('''
const fs = require('fs');
const run = {check() {}};
run.check();
for (let i = 0; i < LINES; i++) console.log('sample line ' + i + ' ' + 'x'.repeat(200));
console.log('SAMPLE-END');
fs.appendFileSync(process.env.RICHOS_UI_TESTS_LEDGER,
  JSON.stringify({suite:'sample.js',label:'fixture',checks:1,failed:0})+'\\n');
'''.replace('LINES', str(lines)))
        result = subprocess.run(['node', str(self.root / 'run.js'), '--shards=1',
                                 f'--receipts={self.root / "receipts"}'], cwd=self.root,
                                env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr)
        seen = sum(1 for line in result.stdout.splitlines() if line.startswith('sample line '))
        self.assertEqual(seen, lines, f'{lines - seen} of the suite\'s lines never reached the pipe')
        self.assertIn('SAMPLE-END', result.stdout)
        self.assertIn('✓ ui-suite:', result.stdout, 'the coverage verdict never reached the pipe')

    def test_a_failed_check_names_itself_in_its_receipt_and_the_verdict(self):
        # Run 20260928T233221Z-56bcde43's receipt said home.js ran 38 checks and 1 failed, and
        # nothing anywhere said which one or why. The receipt is the record a build keeps, so
        # the failed check's name and its message belong in it.
        # The REAL harness, from where it lives: it checks its own screenshot declarations
        # against the real tree when it loads, so a copy of it cannot load anywhere else.
        (self.root / 'sample.js').write_text('''
const { createRun } = require(HARNESS);
const run = createRun('the fixture suite');
(async () => {
  await run.check('the check that holds', async () => 'fine');
  await run.check('the check that breaks', async () => {
    throw new Error('rejected at 2731 ms of 1500\\nsecond line of the reason');
  });
  process.exit(run.report() ? 1 : 0);
})();
'''.replace('HARNESS', json.dumps(str(UI / 'lib/harness.js'))))
        receipts = self.root / 'receipts'
        result = subprocess.run(['node', str(self.root / 'run.js'), '--shards=1', f'--receipts={receipts}'],
                                cwd=self.root, env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        receipt = json.loads((receipts / 'sample.receipt.json').read_text())
        failures = [f for r in receipt['records'] for f in r.get('failures', [])]
        self.assertEqual(failures, [{'check': 'the check that breaks',
                                     'message': 'rejected at 2731 ms of 1500\nsecond line of the reason'}])
        verdict = result.stdout[result.stdout.index('reconciled across every shard'):]
        self.assertIn('the check that breaks: rejected at 2731 ms of 1500', verdict)

    def test_shards_hold_machine_worker_tokens_and_never_exceed_the_budget(self):
        # The UI gate held ONE machine worker token (nightly-local.py owned_run) and ran four
        # WebKit shards under it, so the budget that keeps every other gate's parallel work at
        # 80% of the cores admitted a full mutation pool on top of four shards it never counted.
        # Under a budget, each shard is a nested worker: the first runs on the caller's own
        # token (its free slot), and every other one waits for a token of the budget.
        budget = self.root / 'budget'
        subprocess.run(['python3', str(WORKER_TOKENS), 'init', str(budget), '2'], check=True, timeout=30)
        spans = self.root / 'spans.jsonl'
        (self.root / 'sample.js').unlink()
        for name in ('a', 'b', 'c'):
            (self.root / f'{name}.js').write_text('''
const fs = require('fs');
const run = {check() {}};
run.check();
const start = Date.now();
Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1500);
fs.appendFileSync(SPANS, JSON.stringify({start, end: Date.now()}) + '\\n');
fs.appendFileSync(process.env.RICHOS_UI_TESTS_LEDGER,
  JSON.stringify({suite:NAME,label:'fixture',checks:1,failed:0})+'\\n');
'''.replace('SPANS', json.dumps(str(spans))).replace('NAME', json.dumps(f'{name}.js')))
        env = {**self.env, 'RICHOS_MACHINE_WORKERS': str(budget), 'RICHOS_WORKER_TOKENS': str(budget),
               'RICHOS_WORKER_TOKENS_TOOL': str(WORKER_TOKENS)}
        # The gate's own command holds one of the two tokens, exactly as owned_run's does.
        result = subprocess.run(['python3', str(WORKER_TOKENS), 'run', str(budget), '--',
                                 'node', str(self.root / 'run.js'), '--shards=3',
                                 f'--receipts={self.root / "receipts"}'],
                                cwd=self.root, env=env, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rows = [json.loads(line) for line in spans.read_text().splitlines()]
        self.assertEqual(len(rows), 3)
        edges = sorted([(r['start'], 1) for r in rows] + [(r['end'], -1) for r in rows],
                       key=lambda e: (e[0], e[1]))
        running = most = 0
        for _, step in edges:
            running += step
            most = max(most, running)
        self.assertEqual(most, 2, f'{most} shards ran at once on a budget of two worker tokens')

    def test_permission_denied_is_not_proof_of_death(self):
        directory = self.ledger('permission', os.getpid())
        hook = self.root / 'deny-probe.cjs'
        hook.write_text("process.kill = () => { const e = new Error('denied'); e.code='EPERM'; throw e; };\n")
        self.sweep(hook)
        self.assertTrue(directory.exists())


if __name__ == '__main__':
    unittest.main()
