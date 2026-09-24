#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch, Mock
import cpu_guard as G
import testdevices as D
import worker_tokens as W

spec = importlib.util.spec_from_file_location('native_work', Path(__file__).with_name('native-work.py'))
N = importlib.util.module_from_spec(spec)
spec.loader.exec_module(N)


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cpu-guard-test-', dir=os.environ['TMPDIR'])
        self.addCleanup(self.tmp.cleanup)
        state = patch.object(G, 'STATE', Path(self.tmp.name))
        env = patch.dict(os.environ, {"RICHOS_TEST_DEVICES_DIR": str(Path(self.tmp.name)/"devices")})
        env.start()
        self.addCleanup(env.stop)
        state.start()
        self.addCleanup(state.stop)

    def row(self, parent=0, cpu=0, birth='birth', name='test'):
        return dict(parent=parent, cpu=cpu, birth=birth, name=name)

    def root(self, pid=10, role='session'):
        G.write_json(G.STATE/'roots'/f'{pid}.json', dict(pid=pid,birth='birth',role=role,label='test session'))

    def test_cpu_time_parser(self):
        self.assertEqual(G.seconds('01:02.50'), 62.5)
        self.assertEqual(G.seconds('1-02:03:04'), 93784)

    def test_sustained_load_and_unowned_process(self):
        self.root()
        watch = G.Watch()
        for now in (0, 2, 4, 6, 8, 10):
            chosen, _, _ = watch.sample({10:self.row(), 20:self.row(10,now*5), 30:self.row(0,now*9)}, now)
            self.assertEqual(chosen, [])
        chosen, _, protected = watch.sample({10:self.row(),20:self.row(10,60),30:self.row(0,108)},12)
        self.assertEqual(chosen,[20])
        self.assertIn(10,protected)

    def test_reparented_child_keeps_identity_but_reused_pid_does_not(self):
        self.root()
        watch = G.Watch()
        watch.sample({10:self.row(),20:self.row(10)},0)
        watch.sample({20:self.row(1,4)},2)
        self.assertIn('20',watch.owned)
        watch.sample({20:self.row(1,0,'new process')},4)
        self.assertNotIn('20',watch.owned)

    def test_short_burst_resets_window(self):
        self.root()
        watch = G.Watch()
        for now,cpu in ((0,0),(2,10),(4,20),(6,20),(8,30),(10,40),(12,50),(14,60)):
            chosen,_,_=watch.sample({10:self.row(),20:self.row(10,cpu)},now)
            self.assertEqual(chosen,[])

    def test_aggregate_small_workers(self):
        self.root()
        watch=G.Watch()
        with patch.object(os,'cpu_count',return_value=4):
            for now in range(0,14,2):
                chosen,_,_=watch.sample({10:self.row(),20:self.row(10,now*2),21:self.row(10,now*2)},now)
            self.assertEqual(len(chosen),1)

    def test_signal_checks_identity_again(self):
        watch=G.Watch()
        watch.owned={'20':dict(owner='test')}
        rows={20:self.row(cpu=50)}
        with patch.object(G,'processes',return_value={20:self.row(birth='reused')}), patch.object(os,'kill') as kill:
            watch.stop(20,rows,set(),{20:5})
            kill.assert_not_called()

    def test_direct_launch_guard_and_read_only_commands(self):
        for command in ('./gradlew test','bash ./gradlew test','swift test','/usr/bin/xcodebuild build',
                        'xcrun simctl boot UUID','emulator -avd foo','FOO=bar ./gradlew build',
                        "bash -c 'swift build'",'cd app && ./gradlew test','nice -n 10 swift test'):
            self.assertIsNotNone(G.forbidden(command), command)
        for command in ('git status','rg "swift test" .','echo "xcodebuild build"','xcrun simctl list devices',
                        'xcrun simctl shutdown UUID','adb -s emulator-5580 emu kill',
                        'randroid test core','python3 native-work.py -- swift test','./gradlew --stop'):
            self.assertIsNone(G.forbidden(command), command)

    def test_heredoc_data_is_not_a_command_but_shell_body_is(self):
        self.assertIsNone(G.forbidden("cat <<'EOF'\nIt's a description of swift test.\nEOF\ngit status"))
        self.assertEqual(G.forbidden("bash <<'EOF'\nswift test\nEOF"), "swift test")
        self.assertEqual(G.forbidden("cat <<'EOF'\ntext\nEOF\nswift test"), "swift test")

    def test_busy_host_reclaims_small_owned_workload(self):
        self.root()
        watch=G.Watch()
        for now in range(0,14,2):
            chosen,_,_=watch.sample({10:self.row(),20:self.row(10,now)},now,host_busy=95)
        self.assertEqual(chosen,[20])

    def test_caps_cannot_be_overridden(self):
        gradle=N.capped(['./gradlew','test'])
        self.assertIn('--max-workers=1',gradle)
        self.assertIn('--no-daemon',gradle)
        for args in (['./gradlew','--max-workers=8'],['swift','test','--jobs','8'],['xcodebuild','-jobs','8']):
            with self.assertRaises(ValueError): N.capped(args)
        self.assertEqual(N.capped(['swift','test'])[-2:],['--jobs','1'])

    def test_health_requires_successful_independent_device_collector(self):
        G.write_json(G.STATE/'heartbeat.json', dict(at=time.time(), ok=True))
        self.assertFalse(G.healthy())
        G.write_json(G.STATE/'devices-heartbeat.json', dict(at=time.time(), ok=False))
        self.assertFalse(G.healthy())
        G.write_json(G.STATE/'devices-heartbeat.json', dict(at=time.time(), ok=True))
        self.assertTrue(G.healthy())

    def test_device_worker_runs_without_process_sampling_and_reports_stderr(self):
        G.block_ios('incident')
        with patch.object(G, 'processes', side_effect=TimeoutError('ps unavailable')), patch.object(G.subprocess, 'run') as run:
            run.return_value = Mock(returncode=1, stderr='shutdown RPC timed out', stdout='')
            G.device_cycle('/engine')
            self.assertIn('--pressure', run.call_args.args[0])
            self.assertFalse(G.read_json(G.STATE/'devices-heartbeat.json')['ok'])
            self.assertIn('shutdown RPC timed out', G.read_json(G.STATE/'alert.json')['error'])
            run.return_value = Mock(returncode=0)
            G.device_cycle('/engine')
            self.assertTrue(G.read_json(G.STATE/'devices-heartbeat.json')['ok'])

    def test_old_checkout_proof_launcher_is_refused_before_execution(self):
        old = G.STATE/'old-checkout'
        policy = old/'richos/engine/scripts/lib/testdevices.py'
        policy.parent.mkdir(parents=True)
        policy.write_text('# old collector')
        command = 'cd ' + str(old/'richos/app') + ' && python3 scripts/proof-run.py --working'
        self.assertIn('outdated', G.forbidden(command))
        policy.write_text('def acquire_ios(): pass')
        self.assertIsNone(G.forbidden(command))

    def test_incident_stop_is_persistent_and_headless_is_available(self):
        G.block_ios('incident')
        with self.assertRaisesRegex(RuntimeError, 'incident'): G.require_ios()
        for command in ('bash /old/Release/simulator-tests.sh /out', '/old/bin/rios sim prepare',
                        'bash /old/scripts/native-ios-ui.test.sh'):
            self.assertIsNotNone(G.forbidden(command))
        self.assertIsNone(G.forbidden('bash /old/scripts/native-ios-ui.test.sh --headless'))
        self.assertIsNone(G.forbidden('rios headless state'))
        self.assertIsNone(G.forbidden('rios sim stop'))

    def test_xcode_diagnostics_are_disabled_and_cannot_be_overridden(self):
        command=N.capped(['xcodebuild','test'])
        self.assertEqual(command[command.index('-collect-test-diagnostics')+1], 'never')
        with self.assertRaises(ValueError):
            N.capped(['xcodebuild','test','-collect-test-diagnostics','on-failure'])
        self.assertIsNotNone(G.forbidden('xcrun simctl diagnose -l'))

    def test_unavailable_cpu_sample_retries_using_full_interval(self):
        reserve=Mock()
        reserve.host_sample.side_effect=[BlockingIOError('counters did not advance'), {'cpu_idle_percent':80}]
        reserve._refusal.return_value=False
        with patch.object(N.time,'sleep') as sleep:
            N.wait_for_headroom(reserve, timeout=10)
        self.assertEqual(reserve.host_sample.call_count,2)
        reserve.host_sample.assert_called_with()
        sleep.assert_called_once_with(3)

    def test_successful_intervention_notice_is_not_repeated_every_turn(self):
        G.write_json(G.STATE/'alert.json',{'at':123,'message':'test intervention'})
        with patch.object(G,'healthy',return_value=True):
            payload={'session_id':'test','hook_event_name':'Stop'}
            self.assertIn('test intervention',G.notice_payload(payload)['systemMessage'])
            self.assertIsNone(G.notice_payload(payload))
            G.write_json(G.STATE/'alert.json',{'at':124,'message':'second intervention'})
            self.assertIn('second intervention',G.notice_payload(payload)['systemMessage'])

    def test_broken_hook_input_refuses_instead_of_returning_nonblocking_error(self):
        child=subprocess.run([sys.executable,str(Path(G.__file__)),'hook'],input='{broken',
                             text=True,capture_output=True)
        self.assertEqual(child.returncode,2)

    def test_missing_watchdog_fails_closed(self):
        with patch.object(sys,'platform','darwin'):
            with self.assertRaisesRegex(RuntimeError,'not healthy'):
                N.run([sys.executable,'-c','raise Exception("must not run")'])

    def test_device_lifetime_and_idle_are_independent(self):
        rec={'lease':dict(created=100,last_use=900,max_seconds=900,idle_seconds=300)}
        self.assertFalse(D.lease_expired(rec,999))
        self.assertTrue(D.lease_expired(rec,1000))
        rec['lease']['last_use']=100
        self.assertTrue(D.lease_expired(rec,400))
        self.assertFalse(D.lease_expired({},100000))

    def test_kernel_lock_serializes_and_releases_on_holder_death(self):
        directory=G.STATE/'budget'
        W.init(directory,1)
        token=W.Budget(directory,shared=False).acquire()
        code='import worker_tokens as w,sys; t=w.Budget(sys.argv[1],shared=False).acquire(timeout=5); print("admitted",flush=True); t.release()'
        child=subprocess.Popen([sys.executable,'-c',code,str(directory)],stdout=subprocess.PIPE,text=True,
                               env={**os.environ,'PYTHONPATH':str(Path(__file__).parent)})
        try:
            time.sleep(.3)
            self.assertIsNone(child.poll())
            token.release()
            self.assertEqual(child.communicate(timeout=6)[0].strip(),'admitted')
            self.assertEqual(child.returncode,0)
        finally:
            token.release()
            if child.poll() is None: child.kill();child.wait()

    def test_real_owned_cpu_process_is_stopped_unrelated_survives(self):
        # One busy core for <2 seconds. Exercise real sampling/signals, with a
        # deliberately lower test threshold instead of saturating this Mac.
        busy=subprocess.Popen([sys.executable,'-c','while True: pass'],start_new_session=True)
        bystander=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])
        try:
            G.register(busy.pid,'test burner','workload')
            watch=G.Watch()
            with patch.object(G,'WINDOW',.3), patch.object(G,'JOB_CORES',.1):
                deadline=time.monotonic()+5
                caught=False
                while time.monotonic()<deadline:
                    rows=G.processes()
                    candidates,rates,protected=watch.sample(rows,time.monotonic())
                    if candidates:
                        self.assertEqual(candidates, [busy.pid])
                        watch.stop(candidates[0],rows,protected,rates)
                        self.assertIn(busy.pid, watch.pending)
                        caught=True
                        break
                    time.sleep(.15)
                self.assertTrue(caught)
            busy.wait(timeout=3)
            self.assertEqual(busy.returncode,-signal.SIGTERM)
            self.assertIsNone(bystander.poll())
        finally:
            for child in (busy,bystander):
                if child.poll() is None: child.kill()
                child.wait()


if __name__=='__main__': unittest.main()
