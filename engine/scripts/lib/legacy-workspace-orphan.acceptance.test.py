#!/usr/bin/env python3
"""Controller-seam and tiny Git integration tests, never installed cutoff proof."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

runner=load('legacy-workspace-orphan.acceptance')
fixtures=load('legacy-workspace-gate.test')
job=load('legacy-workspace-job')
support=load('legacy-workspace-acceptance')


class Controller(unittest.TestCase):
    setUp=fixtures.GateWorkflow.setUp
    git=fixtures.GateWorkflow.git

    def _case(self, case):
        (self.work/'file').write_bytes(b'staged-only');self.git('-C',str(self.work),'add','file')
        staged=self.git('-C',str(self.work),'rev-parse',':file')
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        expected=dict(head=self.head,staged_oid=staged,index_sha256=runner.hashlib.sha256((admin/'index').read_bytes()).hexdigest())
        (self.work/'file').write_bytes(b'working');(self.work/'untracked').write_bytes(b'untracked\0unique')
        (self.work/'cache').mkdir();(self.work/'cache/unique').write_bytes(b'cache-tagged-unique')
        (self.work/'link').symlink_to('untracked')
        if case=='locked':self.git('worktree','lock','--reason','fixture terminal lock',str(self.work))
        else:shutil.rmtree(self.work)
        report=fixtures.gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},[self.tx],self.records)
        target=runner.validate_report(report,self.sources,case)
        digest=job.shadow.digest(report)
        result=self.manager.stage(report,approved_sha256=digest);ident=result['id'];base=self.vault/ident
        record=dict(report=report,expected=expected,plan_sha256=digest,gate_id=ident)
        record['selection']=runner.selected(record,target,ident)
        scratch=base/'job-scratch';scratch.mkdir(mode=0o700)
        job.arm(self.manager,record['selection'],approved_selection_sha256=job.shadow.digest(record['selection']),scratch_root=scratch)
        self.assertEqual(job.advance(self.manager,ident,scratch_root=scratch)['state'],'waiting-for-boot')
        self.assertFalse(list(scratch.iterdir()))
        return record,base,scratch

    def _driver(self):
        def git(record,repo,*args,input=None,check=True):
            result=subprocess.run(['/usr/bin/git','-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false','-C',str(repo),*args],
                input=input,capture_output=True,env=runner.ENV)
            if check:self.assertEqual(result.returncode,0,result.stderr)
            return result.stdout if check else result
        return SimpleNamespace(job=job,runtime=SimpleNamespace(protected_path=lambda path,**kwargs:path),git=git)

    def test_locked_fixture_real_archive_job_and_gc(self):
        self._complete('locked')

    def test_orphan_fixture_real_admin_archive_job_and_gc(self):
        self._complete('orphan')

    def _complete(self,case):
        record,base,scratch=self._case(case)
        original=self.manager._boot()
        with runner.controller_boot(self.manager,actual_boot=original,synthetic_boot=str(uuid.uuid4())):
            for _ in range(32):
                result=job.advance(self.manager,record['gate_id'],scratch_root=scratch)
                self.assertNotEqual(result['state'],'failed',result)
                if result['phase']=='complete':break
            self.assertEqual(result['phase'],'complete')
            runner.verify_restored(self._driver(),support,record,self.root,self.manager,base,case)
        self.assertEqual(self.manager._boot(),original)
        self.assertEqual(self.manager._load(base)['gated_boot_id'],original)

    def test_recreated_orphan_keeps_new_bytes_old_admin_and_branch(self):
        record,base,scratch=self._case('orphan-recreated')
        self.work.mkdir();(self.work/'new-owner').write_bytes(b'independent')
        with runner.controller_boot(self.manager,actual_boot=self.manager._boot(),synthetic_boot=str(uuid.uuid4())):
            result=job.advance(self.manager,record['gate_id'],scratch_root=scratch)
            self.assertEqual(result['state'],'failed',result)
            self.assertIn('reappeared',result['last_error'])
            self.assertFalse((base/'retirement.json').exists())
            self.manager.restore(record['gate_id'],approved_sha256=record['plan_sha256'])
        self.assertEqual((self.work/'new-owner').read_bytes(),b'independent')
        self.assertTrue(Path(record['selection']['candidates'][0]['git_admin_path']).is_dir())
        self.assertEqual(self.git('rev-parse','worker'),self.head)

    def test_seam_removed_even_after_error_and_does_not_change_other_instance(self):
        previous=self.manager._boot();other=SimpleNamespace(_boot=lambda:previous)
        with self.assertRaisesRegex(RuntimeError,'injected'):
            with runner.controller_boot(self.manager,actual_boot=previous,synthetic_boot=str(uuid.uuid4())):
                self.assertEqual(other._boot(),previous)
                raise RuntimeError('injected')
        self.assertEqual(self.manager._boot(),previous)
        with self.assertRaises(RuntimeError):
            with runner.controller_boot(self.manager,actual_boot='unknown',synthetic_boot=str(uuid.uuid4())):pass

    def test_scope_cannot_silently_add_an_unapproved_checkout(self):
        report=json.loads(json.dumps(self.report))
        report['repositories'][0]['gate_paths'].append(dict(path='/unapproved'))
        with self.assertRaisesRegex(RuntimeError,'unexpected fixture scope'):
            runner.validate_report(report,self.sources,'locked')

    def test_later_case_failure_retains_completed_receipt_and_stops(self):
        calls=[]
        def run(support,uid,case):
            calls.append(case)
            if case=='orphan':raise RuntimeError('failed fixture retained /fixture/two/receipt.json')
            return dict(case=case,passed=True,receipt='/fixture/one/receipt.json')
        with patch.object(runner,'run_case',side_effect=run):result=runner.execute_cases(None,501)
        self.assertFalse(result['passed']);self.assertFalse(result['tests_cutoff'])
        self.assertEqual(result['cases'][0]['receipt'],'/fixture/one/receipt.json')
        self.assertEqual(result['failed_case'],'orphan')
        self.assertEqual(calls,['locked','orphan'])

    def test_setup_only_changes_exact_fixture_and_preserves_original_template(self):
        original=support.SETUP
        for case in runner.CASES:
            modified=runner.fixture_setup(original,case)
            compile(modified,'fixture-setup','exec')
            self.assertEqual(modified.count('sys.stdin.readline()'),1)
        self.assertEqual(support.SETUP,original)
        with self.assertRaises(RuntimeError):runner.fixture_setup(original,'live-repo')
        with self.assertRaises(RuntimeError):runner.fixture_setup('changed installed template','orphan')


if __name__=='__main__':unittest.main()
