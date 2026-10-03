#!/usr/bin/env python3
"""A Gradle daemon kept warm for ONE workspace (2026-10-02): the workspace's second build reuses
it, nothing else the build left behind survives, and landing the workspace leaves no Gradle
process. Fixture processes only: a stand-in gradlew and a stand-in daemon (it announces itself
the way Gradle does, with daemon-<pid>.out.log in the registry it was given). No Gradle, no
build, no device, no live state (gradle_daemons.test.sh runs under verification-fixture.sh).

Every process here was started by this test; teardown ends only PIDs the stand-ins recorded.
"""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import cpu_guard  # noqa: E402
import operator_fences  # noqa: E402

spec = importlib.util.spec_from_file_location('native_work', HERE / 'native-work.py')
N = importlib.util.module_from_spec(spec)
spec.loader.exec_module(N)

DAEMON = textwrap.dedent('''\
    import json, os, signal, subprocess, sys, time
    from pathlib import Path
    os.setsid()                                   # Gradle's daemon detaches the same way
    folder = Path(sys.argv[1]) / '9.9'
    folder.mkdir(parents=True, exist_ok=True)
    (folder / ('daemon-%d.out.log' % os.getpid())).write_text('stand-in daemon\\n')
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])   # its aapt2
    def stop(*_):
        child.kill()
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    (folder / 'stand-in-registry.json').write_text(json.dumps({'pid': os.getpid(), 'child': child.pid}))
    time.sleep(120)
''')

GRADLEW = textwrap.dedent('''\
    #!{python}
    import json, os, subprocess, sys, time
    from pathlib import Path
    args = sys.argv[1:]
    registry = next((a.split('=', 1)[1] for a in args if a.startswith('-Dorg.gradle.daemon.registry.base=')),
                    os.path.join(os.environ['GRADLE_USER_HOME'], 'daemon'))
    log = Path(os.environ['STAND_IN_LOG'])
    # Something a build leaves behind that is NOT a daemon: it must still be ended.
    stray = subprocess.Popen([sys.executable, '-c', 'import os, time; os.setsid(); time.sleep(120)'])
    with log.with_name('strays').open('a') as out:
        out.write('%d\\n' % stray.pid)
    state = Path(registry) / '9.9' / 'stand-in-registry.json'
    pid = json.loads(state.read_text())['pid'] if state.exists() else None
    if pid:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pid = None
    if pid:
        verb = 'reused'
    else:
        state.unlink(missing_ok=True)
        subprocess.Popen([sys.executable, '-c', {daemon!r}, registry])
        deadline = time.time() + 20
        while not state.exists() and time.time() < deadline:
            time.sleep(0.05)
        pid, verb = json.loads(state.read_text())['pid'], 'started'
    with log.open('a') as out:
        out.write('%s %d %s\\n' % (verb, pid, ' '.join(a for a in args if a.startswith('--max-workers'))))
    time.sleep(0.5)          # long enough for the supervisor to observe the tree
''')


def alive(pid):
    row = operator_fences.proc(pid, precise=True)
    return bool(row and not row['zombie'])


class WarmDaemon(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='gradle-daemons-', dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.tmp.cleanup)
        root = Path(os.path.realpath(self.tmp.name))
        self.ws = root / 'workspace'
        self.ws.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.ws)], check=True)
        gradlew = self.ws / 'gradlew'
        gradlew.write_text(GRADLEW.format(python=sys.executable, daemon=DAEMON))
        gradlew.chmod(0o755)
        self.log = root / 'builds.log'
        self.home = root / 'gradle-home'
        env = patch.dict(os.environ, {'GRADLE_USER_HOME': str(self.home), 'STAND_IN_LOG': str(self.log),
                                      'RICHOS_GRADLE_DAEMONS': str(root / 'daemon-records')})
        env.start()
        self.addCleanup(env.stop)
        self.addCleanup(self.end_stand_ins)
        self.registered = []

    def end_stand_ins(self):
        """Teardown: only the PIDs the stand-ins recorded for this test."""
        pids = []
        for state in self.home.rglob('stand-in-registry.json'):
            record = json.loads(state.read_text())
            pids += [record['pid'], record['child']]
        strays = self.log.with_name('strays')
        if strays.exists():
            pids += [int(line) for line in strays.read_text().split()]
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def build(self):
        def register(pid, label, role='session', verification=None, grant=None):
            self.registered.append((pid, label, role, grant))
        with patch.object(cpu_guard, 'require_managed_ancestor'), \
                patch.object(cpu_guard, 'healthy', return_value=True), \
                patch.object(cpu_guard, 'register', side_effect=register), \
                patch.dict(sys.modules, {'reserve': object()}), \
                patch.object(N, 'wait_for_headroom', return_value=5.0), \
                patch.object(N, 'sharers', return_value=1), \
                patch.object(N.os, 'cpu_count', return_value=10):
            return N.run([str(self.ws / 'gradlew'), '-p', str(self.ws), 'assembleRelease'])

    def builds(self):
        return [line.split() for line in self.log.read_text().splitlines()]

    def test_a_second_build_reuses_the_daemon_and_landing_leaves_no_gradle_process(self):
        self.assertEqual(self.build(), 0)
        self.assertEqual(self.build(), 0)
        log = self.builds()
        started = int(log[0][1])
        # The workspace's second build found the first one's daemon (red on main: 'started' twice).
        self.assertEqual([row[:2] for row in log], [['started', str(started)], ['reused', str(started)]])
        self.assertTrue(alive(started))
        # 5 cores granted at 5 percent busy on 10 cpus; the daemon gets 5 - 4 processors and workers (at least 1).
        self.assertEqual(log[1][2], '--max-workers=1')
        # Nothing else the builds left behind survived them.
        strays = [int(p) for p in self.log.with_name('strays').read_text().split()]
        self.assertEqual(len(strays), 2)
        self.assertFalse(any(alive(p) for p in strays), strays)

        import gradle_daemons
        workspace = os.path.realpath(self.ws)
        record = gradle_daemons.load(workspace)
        self.assertEqual(list(record['daemons']), [str(started)])
        self.assertEqual(record['daemons'][str(started)]['processors'], 1)
        grant = {'cores': 5, 'group': workspace}
        self.assertIn((started, 'gradle daemon: ' + workspace, cpu_guard.NATIVE_ROLE, grant), self.registered)
        builds = [r for r in self.registered if r[1] == 'native build: gradlew']
        self.assertEqual([(r[2], r[3]) for r in builds], [(cpu_guard.NATIVE_ROLE, grant)] * 2)

        # Landing the workspace: the deleter's stop step ends the daemon and its child.
        child = json.loads(next(self.home.rglob('stand-in-registry.json')).read_text())['child']
        spec = importlib.util.spec_from_file_location('workspaces', HERE.parents[1] / 'mega-lander/workspaces.py')
        ws = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ws)
        with patch.object(ws, 'PROCESS_STOP_GRACE', 5):
            result = ws.stop_processes([str(self.ws)])
        self.assertIn(started, result['stopped'])
        self.assertEqual(result['survivors'], [])
        deadline = time.monotonic() + 10
        while (alive(started) or alive(child)) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(alive(started))
        self.assertFalse(alive(child))
        self.assertIsNone(gradle_daemons.load(workspace))
        self.assertFalse(Path(gradle_daemons.registry(workspace, str(self.home))).exists())

    def test_turned_off_every_build_is_cold_and_nothing_survives(self):
        with patch.dict(os.environ, {'RICHOS_GRADLE_DAEMON': '0'}):
            self.assertEqual(self.build(), 0)
            self.assertEqual(self.build(), 0)
        log = self.builds()
        self.assertEqual([row[0] for row in log], ['started', 'started'])
        self.assertFalse(alive(int(log[0][1])))
        self.assertFalse(alive(int(log[1][1])))


class Decisions(unittest.TestCase):
    def test_reuse_while_the_grant_covers_the_daemon_and_restart_when_it_shrinks_or_grows_by_two(self):
        import gradle_daemons
        workspace, home = '/w', '/g'
        reg = gradle_daemons.registry(workspace, home)
        record = {'workspace': workspace, 'registry': reg, 'daemons': {'7': {'generation': 'g', 'processors': 3}}}
        stops = []
        with patch.object(gradle_daemons, 'load', return_value=record), \
                patch.object(gradle_daemons, 'live', return_value={7: record['daemons']['7']}), \
                patch.object(gradle_daemons, 'stop', side_effect=lambda w: stops.append(w) or
                             {'stopped': [7], 'survivors': []}):
            for wanted, processors, reused in ((3, 3, True), (4, 3, True), (5, 5, False), (2, 2, False), (1, 1, False)):
                plan = gradle_daemons.prepare(workspace, home, wanted)
                self.assertEqual((plan['processors'], plan['reused']), (processors, reused), wanted)
        self.assertEqual(len(stops), 3)

    def test_a_log_older_than_the_process_is_not_its_announcement(self):
        import gradle_daemons
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
            folder = Path(tmp) / '9.9'
            folder.mkdir()
            log = folder / 'daemon-4242.out.log'
            log.write_text('an earlier process with this PID\n')
            os.utime(log, (1000, 1000))
            self.assertFalse(gradle_daemons.is_announced_daemon(4242, 'darwin:2000:000001', tmp))
            self.assertTrue(gradle_daemons.is_announced_daemon(4242, 'darwin:999:000001', tmp))
            self.assertFalse(gradle_daemons.is_announced_daemon(4243, 'darwin:999:000001', tmp))

    def test_daemon_overrides_are_refused_and_the_cold_form_is_unchanged(self):
        for args in (['./gradlew', '--daemon'], ['./gradlew', '--no-daemon'], ['./gradlew', '--foreground'],
                     ['./gradlew', '-Dorg.gradle.daemon.idletimeout=1'], ['./gradlew', '-Dorg.gradle.daemon.registry.base=/x']):
            with self.assertRaises(ValueError):
                N.capped(args)
        cold = N.capped(['./gradlew', 'assemble'])
        self.assertIn('--no-daemon', cold)
        self.assertIn('--max-workers=1', cold)
        warm = N.capped(['./gradlew', 'assemble'], 6, daemon={'registry': '/r', 'processors': 4})
        self.assertIn('--daemon', warm)
        self.assertIn('--max-workers=4', warm)
        self.assertIn('-Dorg.gradle.jvmargs=-Xmx1536m -XX:ActiveProcessorCount=4 -Dfile.encoding=UTF-8', warm)
        self.assertIn('-Dorg.gradle.daemon.registry.base=/r', warm)
        self.assertIn('-Dorg.gradle.daemon.idletimeout=120000', warm)
        self.assertEqual([N.gradle_processors(c) for c in (1, 2, 3, 4, 6)], [1, 1, 1, 1, 2])
        with patch.dict(os.environ, {'RICHOS_GRADLE_MAX_PROCESSORS': '1'}):
            self.assertEqual([N.gradle_processors(c) for c in (1, 4, 6, 10)], [1, 1, 1, 1])
        with patch.dict(os.environ, {'RICHOS_GRADLE_MAX_PROCESSORS': '9'}):
            self.assertEqual(N.gradle_processors(6), 2)          # a brake, never an accelerator


if __name__ == '__main__':
    unittest.main(verbosity=1)
