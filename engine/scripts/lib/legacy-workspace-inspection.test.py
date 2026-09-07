#!/usr/bin/env python3
"""Tiny owner-inspection fixtures. No gate, image, package or service creation."""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE=Path(__file__).resolve().parent

def module(name):
    spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result)
    return result

gate=module('legacy-workspace-gate');admin=module('legacy-workspace-admin')


class OwnerInspection(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='owner-inspection-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve();self.root.chmod(0o755)
        self.account=pwd.getpwuid(os.getuid()) if os.getuid()!=0 else pwd.getpwnam('nobody')
        self.sources=self.root/'sources';self.sources.mkdir();self.repo=self.sources/'repo';self.repo.mkdir()
        self.transactions=self.root/'transactions';self.transactions.mkdir();self.ledger=self.root/'ledger.jsonl'
        for command in (['init','-q','-b','main'],['config','user.name','fixture'],['config','user.email','fixture@example.invalid']):self.git(*command)
        (self.repo/'file').write_text('one small fixture');self.git('add','file');self.git('commit','-qm','fixture')
        self.ledger.write_text(json.dumps(dict(event='registered',worktree=str(self.repo),repo=str(self.repo),session_id='gone',session_pid=999999999))+'\n')
        self.context=dict(version=1,owner_uid=self.account.pw_uid,owner_gid=self.account.pw_gid,
                          owner_home=os.path.normpath(self.account.pw_dir),transactions=str(self.transactions),ledger=str(self.ledger))
        self.policy={'repositories':{'fixture':{'path':str(self.repo)}}}
        if os.getuid()==0:
            for directory,dirs,files in os.walk(self.root):
                os.chown(directory,self.account.pw_uid,self.account.pw_gid)
                for name in files:os.chown(Path(directory)/name,self.account.pw_uid,self.account.pw_gid)
        self.report=gate.owner_report(self.policy,self.context,require_root=False)
        self.assertEqual(self.report['repositories'][0]['blockers'],[])

    def git(self,*args):
        return subprocess.check_output(['/usr/bin/git','-c','core.hooksPath=/dev/null','-C',str(self.repo),*args],
            stderr=subprocess.PIPE,env={'PATH':'/usr/bin:/bin','HOME':'/var/empty','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'})

    def test_actual_owner_child_ignores_ambient_root_history_and_git_injection(self):
        with patch.dict(os.environ,{'HOME':'/var/root','GIT_DIR':'/unrelated','RICHOS_WORKTREE_LEDGER':'/unrelated',
                                    'RICHOS_WORKTREE_TX_DIR':'/unrelated','RICHOS_CLAUDE_PROCESSES':'injected'}):
            actual=gate.owner_report(self.policy,self.context,require_root=False)
        self.assertEqual(actual,self.report)
        self.assertEqual(actual['inspection_context']['owner_uid'],self.account.pw_uid)
        self.assertIn('canonical_repository',actual['repositories'][0])

    def test_packaged_file_set_is_sufficient_for_actual_owner_inspection(self):
        broker=module('managed-workspace-broker')
        release=self.root/'packaged';release.mkdir(mode=0o755)
        for name in broker.CODE_FILES:shutil.copyfile(HERE/name,release/name)
        credentials=dict(user=self.account.pw_uid,group=self.account.pw_gid,extra_groups=[]) if os.getuid()==0 else {}
        result=subprocess.run([sys.executable,'-I','-S','-B',str(release/'legacy-workspace-inspection.py')],
            input=json.dumps({'policy':self.policy,'inspection_context':self.context}).encode(),capture_output=True,
            cwd='/',env={'PATH':'/usr/bin:/bin'},**credentials)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertEqual(json.loads(result.stdout),self.report)

    def test_production_requires_explicit_context_before_vault_access(self):
        with patch.object(gate.os,'geteuid',return_value=0),patch.object(gate.sys,'platform','darwin'), \
                self.assertRaisesRegex(gate.GateError,'explicit approved owner'):
            gate.LegacyGate(self.root/'nonexistent')

    def test_helper_refuses_root_and_wrong_owner_before_history_reads(self):
        with patch.object(gate.inspection.os,'geteuid',return_value=0),patch.object(gate.inspection,'_history_path') as read:
            with self.assertRaisesRegex(ValueError,'unprivileged owner'):
                gate.inspection.inspect_owner(self.policy,self.context)
        read.assert_not_called()
        with patch.object(gate.inspection.os,'geteuid',return_value=self.account.pw_uid+1),patch.object(gate.inspection,'_history_path') as read:
            with self.assertRaisesRegex(ValueError,'unprivileged owner'):
                gate.inspection.inspect_owner(self.policy,self.context)
        read.assert_not_called()

    def test_explicit_history_path_is_bound_even_when_bytes_match(self):
        alternate=self.root/'alternate.jsonl';alternate.write_bytes(self.ledger.read_bytes());alternate.chmod(0o644)
        actual=gate.owner_report(self.policy,dict(self.context,ledger=str(alternate)),require_root=False)
        self.assertEqual(actual['history_sha256'],self.report['history_sha256'])
        self.assertNotEqual(gate.planner.history._digest(actual),gate.planner.history._digest(self.report))

    def test_history_path_whitespace_cannot_be_trimmed_into_another_store(self):
        with self.assertRaisesRegex(ValueError,'normalized absolute'):
            gate.owner_report(self.policy,dict(self.context,ledger=str(self.ledger)+' '),require_root=False)

    def test_symlink_history_is_not_silently_substituted(self):
        linked=self.root/'linked.jsonl';linked.symlink_to(self.ledger)
        with self.assertRaisesRegex(gate.GateError,'symlink'):
            gate.owner_report(self.policy,dict(self.context,ledger=str(linked)),require_root=False)

    def test_production_dispatch_drops_uid_gid_groups_and_uses_stdin(self):
        runtime=SimpleNamespace(validate_runtime=lambda:HERE,protected_path=lambda path,**kw:path)
        spec=SimpleNamespace(loader=SimpleNamespace(exec_module=lambda value:None))
        response=subprocess.CompletedProcess([],0,json.dumps(self.report).encode(),b'')
        with patch.object(gate.os,'geteuid',return_value=0),patch.object(gate.sys,'executable',gate.INTERPRETER), \
                patch.object(gate.importlib.util,'spec_from_file_location',return_value=spec), \
                patch.object(gate.importlib.util,'module_from_spec',return_value=runtime), \
                patch.object(gate.subprocess,'run',return_value=response) as run:
            self.assertEqual(gate.owner_report(self.policy,self.context),self.report)
        args,kwargs=run.call_args
        self.assertEqual(args[0][:4],[gate.INTERPRETER,'-I','-S','-B'])
        self.assertEqual((kwargs['user'],kwargs['group'],kwargs['extra_groups']),(self.account.pw_uid,self.account.pw_gid,[]))
        self.assertEqual(kwargs['cwd'],'/')
        self.assertEqual(json.loads(kwargs['input']),{'policy':self.policy,'inspection_context':self.context})
        self.assertNotIn('RICHOS_CLAUDE_PROCESSES',kwargs['env']);self.assertNotIn('PYTHONPATH',kwargs['env'])

    def test_failed_child_output_cannot_be_accepted_as_a_report(self):
        with patch.object(gate.subprocess,'run',return_value=subprocess.CompletedProcess([],73,json.dumps(self.report).encode(),b'failure')):
            with self.assertRaises(gate.GateError):gate.owner_report(self.policy,self.context,require_root=False)

    def test_production_revalidation_never_reads_history_in_root_process(self):
        instance=object.__new__(gate.LegacyGate);instance.inspection_context=self.context;instance.require_root=True
        with patch.object(gate.planner.history,'load_history',side_effect=AssertionError('root history read')), \
                patch.object(gate.planner,'plan',side_effect=AssertionError('root Git inventory')), \
                patch.object(gate,'owner_report',return_value=self.report) as inspect:
            instance._validate_report(self.report,gate.planner.history._digest(self.report))
        inspect.assert_called_once_with(self.policy,self.context,require_root=True)

    def test_admin_wrong_hash_and_policy_mismatch_precede_vault_creation(self):
        release=self.root/'releases'/'test';release.mkdir(parents=True)
        private=self.root/'private'
        policy={'owners':{str(self.account.pw_uid):{'gid':self.account.pw_gid}},'private_root':str(private),
                'repositories':{'fixture':{'path':str(self.repo),'owners':[self.account.pw_uid]}}}
        (self.root/'policy.json').write_text(json.dumps(policy))
        report=self.root/'report.json';report.write_text(json.dumps(self.report))
        runtime=SimpleNamespace(validate_runtime=lambda:release,protected_path=lambda path,**kw:Path(path),validate_policy=lambda value:value)
        args=SimpleNamespace(operation='stage',owner_uid=self.account.pw_uid,transactions=str(self.transactions),ledger=str(self.ledger),
                             report=str(report),approved_sha256='wrong',repository=[],gate_id=None)
        with patch.object(admin,'load',side_effect=lambda name,filename:runtime if filename=='managed-workspace-broker.py' else gate), \
                patch.object(admin.sys,'executable',gate.INTERPRETER),patch.object(gate,'owner_report') as inspect:
            with self.assertRaisesRegex(ValueError,'hash'):admin.run(args)
            args.approved_sha256=gate.planner.history._digest(self.report);policy['repositories']={}
            (self.root/'policy.json').write_text(json.dumps(policy))
            with self.assertRaisesRegex(ValueError,'alias'):admin.run(args)
        inspect.assert_not_called();self.assertFalse(private.exists())


if __name__=='__main__':unittest.main(verbosity=2)
