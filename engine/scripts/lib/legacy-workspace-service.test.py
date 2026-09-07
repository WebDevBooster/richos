#!/usr/bin/env python3
"""Background-only execution, owner filtering and nonblocking status checks."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import Mock, patch

spec=importlib.util.spec_from_file_location('legacy_service',Path(__file__).with_name('legacy-workspace-service.py'))
service=importlib.util.module_from_spec(spec);spec.loader.exec_module(service)

class Service(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory(prefix='legacy-service-');self.addCleanup(tmp.cleanup)
        self.root=Path(tmp.name).resolve();self.vault=self.root/'legacy-gates';self.vault.mkdir(mode=0o700)
        self.owner=os.getuid();self.other=self.owner+1
        self.policy={'private_root':str(self.root),'owners':{str(self.owner):{'gid':os.getgid()},str(self.other):{'gid':os.getgid()}},
                     'repositories':{'repo':{'path':'/approved/repo','owners':[self.owner,self.other]}}}
        self.job=Mock();self.gate=Mock();self.job.status.return_value={'phase':'waiting-for-boot'}
        self.instance=service.LegacyMaintenanceService(self.policy,require_root=False,job_module=self.job,gate_module=self.gate)

    def add(self,owner=None,armed=True):
        ident=str(uuid.uuid4());base=self.vault/ident;base.mkdir(mode=0o700)
        context={'owner_uid':self.owner if owner is None else owner,'owner_gid':os.getgid()}
        (base/'state.json').write_text(json.dumps({'inspection_context':context}))
        (base/'plan.json').write_text(json.dumps({'repositories':[{'alias':'repo','canonical_repository':{'path':'/approved/repo'}}]}))
        if armed:(base/'job.json').write_text('{}')
        return ident

    def test_only_explicitly_armed_gate_is_advanced(self):
        selected=self.add();self.add(armed=False)
        self.assertFalse(self.instance.sweep())
        self.assertEqual(self.job.advance.call_args.args[1],selected);self.job.advance.assert_called_once()
        self.assertEqual(self.instance.status(self.owner)['total'],1)

    def test_owner_status_never_exposes_other_owner_job(self):
        mine=self.add();other=self.add(self.other);self.instance.sweep()
        status=self.instance.status(self.owner)
        self.assertEqual([row['gate_id'] for row in status['records']],[mine])
        self.assertNotIn(other,json.dumps(status))

    def test_policy_drift_prevents_advance_and_reports_incomplete_inventory(self):
        self.add();self.policy['repositories']['repo']['path']='/different/repo'
        self.instance.sweep();self.job.advance.assert_not_called()
        self.assertFalse(self.instance.status(self.owner)['inventory_complete'])
        self.assertIn('policy',self.instance.status(self.owner)['error'])

    def test_one_broken_gate_does_not_strand_an_unrelated_valid_job(self):
        valid=self.add();broken=self.add()
        (self.vault/broken/'plan.json').write_text('{broken')
        self.instance.sweep()
        self.job.advance.assert_called_once();self.assertEqual(self.job.advance.call_args.args[1],valid)
        status=self.instance.status(self.owner)
        self.assertFalse(status['inventory_complete'])
        self.assertEqual({row['gate_id'] for row in status['records']},{valid,broken})

    def test_protected_policy_is_reloaded_before_each_automatic_advance(self):
        self.add();policy_file=self.root/'policy.json';policy_file.write_text(json.dumps(self.policy))
        self.instance.policy_path=policy_file
        with patch.object(self.instance.runtime,'protected_path',side_effect=lambda p,**kw:Path(p)), \
                patch.object(self.instance.runtime,'validate_policy',side_effect=lambda p:p):
            self.instance.sweep();self.job.advance.assert_called_once();self.job.advance.reset_mock()
            changed=json.loads(policy_file.read_text());changed['owners'].pop(str(self.owner));policy_file.write_text(json.dumps(changed))
            self.instance.sweep();self.job.advance.assert_not_called()

    def test_unarmed_absence_is_valid_empty_inventory(self):
        self.vault.rmdir();self.instance.sweep()
        self.job.advance.assert_not_called();self.assertTrue(self.instance.status(self.owner)['inventory_complete'])

    def test_completed_jobs_are_not_reexecuted(self):
        self.add();self.job.status.return_value={'phase':'complete'}
        self.assertFalse(self.instance.sweep());self.job.advance.assert_not_called()

    def test_only_durable_phase_progress_requests_immediate_followup(self):
        self.add();self.job.status.side_effect=[{'phase':'capture','last_attempt_at':1},{'phase':'handoff','last_attempt_at':2}]
        self.assertTrue(self.instance.sweep())
        self.job.status.side_effect=[{'phase':'waiting-for-boot','last_attempt_at':2},{'phase':'waiting-for-boot','last_attempt_at':3}]
        self.assertFalse(self.instance.sweep())

    def test_status_does_not_block_behind_long_capture(self):
        ident=self.add();entered=threading.Event();release=threading.Event()
        def advance(*args,**kwargs):entered.set();release.wait(5)
        self.job.advance.side_effect=advance
        worker=threading.Thread(target=self.instance.sweep);worker.start()
        try:
            self.assertTrue(entered.wait(2))
            status=self.instance.status(self.owner)
            self.assertTrue(status['in_progress'])
            self.assertEqual(status['records'][0]['gate_id'],ident)
            self.assertEqual(status['records'][0]['phase'],'waiting-for-boot')
            self.assertTrue(status['records'][0]['advancing'])
        finally:release.set();worker.join(5)
        self.assertFalse(worker.is_alive())

spec=importlib.util.spec_from_file_location('service_job_fixture',Path(__file__).with_name('legacy-workspace-job.test.py'))
job_fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(job_fixture)


class CompleteService(unittest.TestCase):
    setUp=job_fixture.Jobs.setUp
    git=job_fixture.Jobs.git
    stage=job_fixture.Jobs.stage
    ready=job_fixture.Jobs.ready
    next_boot=job_fixture.Jobs.next_boot

    def test_service_drives_real_armed_job_through_reclamation_and_restore(self):
        self.ready();owner=os.getuid()
        adapter=SimpleNamespace(status=job_fixture.job.status,
            advance=lambda gate,ident,**kwargs:job_fixture.job.advance(gate,ident,trusted_git=self.binary,**kwargs))
        worker=service.LegacyMaintenanceService({'private_root':str(self.root),'owners':{str(owner):{'gid':os.getgid()}},
            'repositories':{}},require_root=False,job_module=adapter,gate_module=job_fixture.fixtures.gate)
        worker.root=self.vault
        # Only discovery/host owner context is substituted. The job, archive,
        # Git recovery refs, retirement journals and restoration all run.
        with patch.object(worker,'_discover',return_value=([(self.manager,self.ident,owner)],[])):
            self.assertFalse(worker.sweep())
            self.assertEqual(worker.status(owner)['records'][0]['state'],'waiting-for-boot')
            self.next_boot()
            for _ in range(12):
                worker.sweep();row=worker.status(owner)['records'][0]
                self.assertNotEqual(row['state'],'failed',row)
                if row['phase']=='complete':break
            else:self.fail('background service did not complete the armed job')
            self.assertFalse(worker.sweep())
        self.assertFalse(self.work.exists());self.assertEqual(self.git('branch','--list','worker'),'')
        self.assertEqual(self.git('rev-parse','main'),self.head)


if __name__=='__main__':unittest.main()
