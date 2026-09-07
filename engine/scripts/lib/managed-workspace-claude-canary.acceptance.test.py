#!/usr/bin/env python3
"""Unprivileged harness checks. Never invokes Claude, root services or images."""
import copy
import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import json

spec=importlib.util.spec_from_file_location('canary',Path(__file__).with_name('managed-workspace-claude-canary.acceptance.py'))
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='richos-canary-test-');self.root=Path(self.temp.name).resolve()
    def tearDown(self):self.temp.cleanup()
    def cleanup_fixture(self):
        native=dict(path=str(self.root/'native-gone'),class_='native',cleanup_owner='claude-code',state='removed',closed='platform-removed')
        native['class']=native.pop('class_')
        transaction=dict(state='removed',terminal={'kind':'SubagentStop'},sealed=True,members=[native])
        registry=mock.Mock(returncode=0,stdout=b'worktree '+os.fsencode(self.root)+b'\0HEAD '+b'1'*40+b'\0branch refs/heads/master\0\0')
        heads=mock.Mock(returncode=0,stdout=b'refs/heads/master\n')
        return transaction,native,self.root,registry,heads,['refs/heads/master'],[]
    def test_native_cleanup_without_hook_record_is_explicitly_observed_not_fabricated(self):
        args=self.cleanup_fixture();result=a.verify_native_cleanup(*args)
        self.assertFalse(result['worktree_remove_event_observed']);self.assertEqual(result['worktree_remove_event_count'],0)
        args[-1].append(dict(input=dict(hook_event_name='WorktreeRemove',worktree_path=args[1]['path']),returncode=0))
        self.assertTrue(a.verify_native_cleanup(*args)['worktree_remove_event_observed'])
    def test_native_cleanup_refuses_failed_empty_truncated_or_malformed_registry(self):
        args=self.cleanup_fixture();valid=args[3].stdout
        for raw in (b'',valid[:-1],valid.replace(b'HEAD ',b'HEAD nope '),valid+valid,
                    valid.replace(b'branch refs/heads/master',b'detached'),valid.replace(b'\0HEAD',b'\0unknown value\0HEAD')):
            with self.subTest(raw=raw):
                args[3].stdout=raw
                with self.assertRaises(RuntimeError):a.verify_native_cleanup(*args)
        args[3].stdout=valid;args[3].returncode=1
        with self.assertRaises(RuntimeError):a.verify_native_cleanup(*args)
    def test_native_cleanup_refuses_original_quarantine_and_dangling_paths(self):
        args=self.cleanup_fixture()
        for key in ('path','quarantine','quarantine_path'):
            target=self.root/key
            args[1][key]=str(target)
            target.symlink_to(self.root/'missing-target')
            with self.subTest(key=key),self.assertRaisesRegex(RuntimeError,'path remains'):a.verify_native_cleanup(*args)
            target.unlink()
        self.assertFalse(a.verify_native_cleanup(*args)['worktree_remove_event_observed'])
    def test_native_cleanup_requires_exact_platform_transaction_and_branch_baseline(self):
        for key,value in (('cleanup_owner',None),('cleanup_owner','future-platform'),('closed','absent'),('state','platform-pending')):
            args=self.cleanup_fixture();args[1][key]=value
            with self.subTest(key=key,value=value),self.assertRaises(RuntimeError):a.verify_native_cleanup(*args)
        args=self.cleanup_fixture();args[0]['state']='pending'
        with self.assertRaises(RuntimeError):a.verify_native_cleanup(*args)
        for raw in (b'',b'refs/heads/master\nrefs/heads/native-leftover\n',b'refs/heads/master'):
            args=self.cleanup_fixture();args[4].stdout=raw
            with self.assertRaises(RuntimeError):a.verify_native_cleanup(*args)
        args=self.cleanup_fixture();args[4].returncode=1
        with self.assertRaises(RuntimeError):a.verify_native_cleanup(*args)
    def test_native_cleanup_accepts_actual_git_porcelain_and_branch_inventory(self):
        import subprocess
        def git(*argv):return subprocess.run(['/usr/bin/git','-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-C',str(self.root),*argv],env={**os.environ,'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'},capture_output=True,check=True)
        git('init','-b','master');git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-m','fixture')
        args=list(self.cleanup_fixture());args[3]=git('worktree','list','--porcelain','-z');args[4]=git('for-each-ref','--format=%(refname)','refs/heads/')
        self.assertFalse(a.verify_native_cleanup(*args)['worktree_remove_event_observed'])

    def test_owner_context_restores_audit_session_then_credentials_then_exact_environment(self):
        argv=a.owner_context_argv((501,20),{'HOME':'/Users/example','RICHOS_WORKTREE_TX_DIR':'/fixture/tx'},['/fixed/claude','auth','status'])
        self.assertEqual(argv[:11],['/bin/launchctl','asuser','501','/usr/bin/sudo','-n','-u','#501','-g','#20','--','/usr/bin/env'])
        self.assertEqual(argv[11],'-i')
        self.assertEqual(argv[-3:],['/fixed/claude','auth','status'])
        self.assertIn('RICHOS_WORKTREE_TX_DIR=/fixture/tx',argv[12:-3])
        with self.assertRaises(RuntimeError):a.owner_context_argv((0,20),{},['/fixed/claude'])
    def test_actual_host_identity_is_distinct_from_the_launchctl_supervisor(self):
        path=self.root/'stream.jsonl'
        identity=dict(type='canary_host_identity',uid=501,session_id='session',pid=4321,pid_start='exact',boot_id='boot')
        path.write_text(json.dumps(identity)+'\n')
        supervisor=mock.Mock(pid=1000)
        with mock.patch.object(a,'process_identity',return_value={key:identity[key] for key in ('pid','pid_start','boot_id')}) as query:
            self.assertEqual(a.await_host_identity(path,supervisor,501,'session'),identity)
            query.assert_called_once_with(4321)
        with self.assertRaisesRegex(RuntimeError,'identity mismatch'):
            a.await_host_identity(path,supervisor,501,'different')
    def test_reused_or_unavailable_host_identity_never_receives_a_signal(self):
        identity=dict(pid=4321,pid_start='original',boot_id='boot',uid=501)
        with mock.patch.object(a,'process_identity',return_value=dict(pid=4321,pid_start='new-owner',boot_id='boot')),mock.patch.object(a.os,'kill') as kill:
            self.assertEqual(a.stop_host(identity),'identity-changed-no-signal');kill.assert_not_called()
        with mock.patch.object(a,'process_identity',side_effect=RuntimeError('unavailable')),mock.patch.object(a.os,'kill') as kill:
            self.assertEqual(a.stop_host(identity),'absent-or-identity-unavailable');kill.assert_not_called()
    def test_manifest_refuses_external_symlink(self):
        (self.root/'link').symlink_to('/etc/passwd')
        with self.assertRaisesRegex(RuntimeError,'symlink'):a.file_manifest(self.root)
    def test_complete_manifest_tracks_extra_and_changed_bytes(self):
        (self.root/'one').write_bytes(b'original')
        original=a.file_manifest(self.root)
        self.assertEqual(original,{'one':hashlib.sha256(b'original').hexdigest()})
        (self.root/'two').write_bytes(b'new')
        self.assertNotEqual(a.file_manifest(self.root),original)
        (self.root/'two').unlink();(self.root/'one').write_bytes(b'changed')
        self.assertNotEqual(a.file_manifest(self.root),original)
    def test_bridge_substitution_changes_only_one_exact_constant(self):
        path=self.root/'scripts/lib/managed-workspace-integration.py';path.parent.mkdir(parents=True)
        source="from pathlib import Path\nCLIENT_CONFIG = Path('/Library/Application Support/RichOS/ManagedWorkspaces/client.json')\nVALUE = 123\n"
        path.write_text(source)
        receipt=a.substitute_bridge(self.root,Path('/private/fixture/client.json'))
        self.assertEqual(receipt['before_sha256'],hashlib.sha256(source.encode()).hexdigest())
        self.assertEqual(path.read_text(),source.replace(receipt['before'],receipt['after']))
        with self.assertRaises(RuntimeError):a.substitute_bridge(self.root,Path('/other'))
    def test_fixture_environment_never_scans_all_user_transcripts(self):
        config=dict(active_root='/private/canary',owner_uid=os.getuid(),session_repo='/private/canary/session',engine='/private/canary/engine')
        result=a.isolated_env(config,'/Users/example')
        self.assertEqual(result['HOME'],'/Users/example')
        self.assertEqual(result['RICHOS_PROJECTS_DIR'],'/private/canary/state/project-scope')
        self.assertNotIn('CLAUDE_CONFIG_DIR',result)
        self.assertNotIn('CLAUDE_CODE_OAUTH_TOKEN',result)
    def events(self):
        def event(hook,tool,**fields):
            return dict(hook=hook,returncode=0,input=dict(session_id='session',tool_name=tool,**fields))
        return [event('guard-worktree-isolation.sh','Agent',tool_use_id='call'),
                event('detect-nonnative-worktree.sh','Agent',tool_use_id='call'),
                event('guard-sealed-worktree.sh','Bash',agent_id='agent',tool_input={'command':'/fixed/wrapper work'})]
    def test_event_join_requires_actual_matching_spawn_and_worker_barrier(self):
        events=self.events();self.assertEqual(a.verify_event_join(events,'session','agent','/fixed/wrapper'),'call')
        quoted=copy.deepcopy(events);quoted[2]['input']['tool_input']['command']="'/fixed/wrapper' work"
        self.assertEqual(a.verify_event_join(quoted,'session','agent','/fixed/wrapper'),'call')
        for index,key,value in ((1,'tool_use_id','foreign'),(2,'agent_id','other'),(0,'session_id','foreign')):
            changed=copy.deepcopy(events);changed[index]['input'][key]=value
            with self.assertRaises(RuntimeError):a.verify_event_join(changed,'session','agent','/fixed/wrapper')
        changed=copy.deepcopy(events);changed[2]['returncode']=2
        with self.assertRaises(RuntimeError):a.verify_event_join(changed,'session','agent','/fixed/wrapper')
    def test_blocked_spawn_retry_is_allowed_only_if_the_blocked_call_never_bound(self):
        events=self.events()
        blocked=copy.deepcopy(events[0]);blocked['returncode']=2;blocked['input']['tool_use_id']='blocked-call'
        events.insert(0,blocked)
        self.assertEqual(a.verify_event_join(events,'session','agent','/fixed/wrapper'),'call')
        wrong=copy.deepcopy(events);wrong[2]['input']['tool_use_id']='blocked-call'
        with self.assertRaises(RuntimeError):a.verify_event_join(wrong,'session','agent','/fixed/wrapper')
        duplicate=copy.deepcopy(events);duplicate.append(copy.deepcopy(events[2]))
        with self.assertRaises(RuntimeError):a.verify_event_join(duplicate,'session','agent','/fixed/wrapper')
        error=copy.deepcopy(events);error[0]['returncode']=1
        with self.assertRaises(RuntimeError):a.verify_event_join(error,'session','agent','/fixed/wrapper')
    def test_event_join_refuses_missing_postspawn_record(self):
        events=self.events();events.pop(1)
        with self.assertRaises(RuntimeError):a.verify_event_join(events,'session','agent','/fixed/wrapper')


if __name__=='__main__':unittest.main(verbosity=2)
