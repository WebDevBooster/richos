#!/usr/bin/env python3
"""Unprivileged harness checks. Never invokes Claude, root services or images."""
import copy
import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('canary',Path(__file__).with_name('managed-workspace-claude-canary.acceptance.py'))
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='richos-canary-test-');self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
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
