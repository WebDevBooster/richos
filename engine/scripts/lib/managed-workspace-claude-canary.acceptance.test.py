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
        self.temp=tempfile.TemporaryDirectory(prefix='richos-canary-test-');self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
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
    def test_event_join_refuses_missing_postspawn_record(self):
        events=self.events();events.pop(1)
        with self.assertRaises(RuntimeError):a.verify_event_join(events,'session','agent','/fixed/wrapper')


if __name__=='__main__':unittest.main(verbosity=2)
