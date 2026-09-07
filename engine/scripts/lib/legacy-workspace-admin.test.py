#!/usr/bin/env python3
"""Administrator authorization/dispatch checks without privilege or live gates."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

def load(file):
    spec=importlib.util.spec_from_file_location(file,Path(__file__).with_name(file+'.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod

admin=load('legacy-workspace-admin');gate=load('legacy-workspace-gate')

class Commands(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory(prefix='legacy-admin-test-');self.addCleanup(tmp.cleanup)
        self.root=Path(tmp.name).resolve();self.private=self.root/'private';self.private.mkdir(mode=0o700)
        self.release=self.root/'releases/reviewed';self.release.mkdir(parents=True)
        owner=pwd.getpwuid(os.getuid())
        self.uid=owner.pw_uid if owner.pw_uid else pwd.getpwnam('nobody').pw_uid
        policy={'owners':{str(self.uid):{'gid':pwd.getpwuid(self.uid).pw_gid}},'private_root':str(self.private)}
        (self.root/'policy.json').write_text(json.dumps(policy))
        runtime=SimpleNamespace(validate_runtime=lambda:self.release,protected_path=lambda p,**kw:Path(p),validate_policy=lambda v:v)
        self.store=Mock();self.store.frozen_view.side_effect=lambda *a,**kw:contextlib.nullcontext({})
        self.mutation=Mock();self.shadow=Mock()
        self.retirement=Mock();self.capture=Mock()
        modules={'managed-workspace-broker.py':runtime,'legacy-workspace-gate.py':gate,
                 'legacy-workspace-mutation.py':self.mutation,'terminal-branch-shadow.py':self.shadow,
                 'legacy-workspace-retirement.py':self.retirement,'legacy-workspace-capture.py':self.capture}
        for p in (patch.object(admin,'load',side_effect=lambda name,file:modules[file]),
                  patch.object(admin.sys,'executable',gate.INTERPRETER),patch.object(gate,'LegacyGate',return_value=self.store)):
            p.start();self.addCleanup(p.stop)
        self.args=SimpleNamespace(operation='publish-branches',owner_uid=self.uid,transactions=str(self.root/'tx'),
            ledger=str(self.root/'ledger'),gate_id='gate',approved_sha256='gate-hash',approved_selection_sha256='selection-hash',
            report=str(self.root/'selection.json'),repository=['fixture'])
        self.selection={'gate_id':'gate','gate_sha256':'gate-hash'}
        Path(self.args.report).write_text(json.dumps(self.selection))

    def test_wrong_gate_selection_never_reaches_publisher(self):
        self.selection['gate_id']='different';Path(self.args.report).write_text(json.dumps(self.selection))
        with self.assertRaisesRegex(ValueError,'different gate'):admin.run(self.args)
        self.mutation.publish.assert_not_called()

    def test_pending_gate_failure_prevents_scratch_and_publication(self):
        self.store.frozen_view.side_effect=RuntimeError('pending mutation')
        with self.assertRaisesRegex(RuntimeError,'pending'):admin.run(self.args)
        self.assertFalse((self.private/'legacy-scratch').exists());self.mutation.publish.assert_not_called()

    def test_oversized_selection_is_refused_before_publisher(self):
        Path(self.args.report).write_bytes(b' '*(128*1024+1))
        with self.assertRaisesRegex(ValueError,'bounded'):admin.run(self.args)
        self.mutation.publish.assert_not_called()

    def test_exact_gate_and_selection_approvals_are_forwarded(self):
        admin.run(self.args)
        self.store.frozen_view.assert_called_once_with('gate',approved_sha256='gate-hash')
        self.mutation.publish.assert_called_once_with(self.store,self.selection,approved_selection_sha256='selection-hash',
                                                    scratch_root=self.private/'legacy-scratch')

    def test_replay_requires_selection_hash_and_does_not_request_frozen_view(self):
        self.args.operation='replay-branches';self.args.approved_selection_sha256=None
        with self.assertRaisesRegex(ValueError,'approval'):admin.run(self.args)
        self.mutation.replay.assert_not_called()
        self.args.approved_selection_sha256='selection-hash';admin.run(self.args)
        self.mutation.replay.assert_called_once_with(self.store,'gate',approved_selection_sha256='selection-hash')
        self.store.frozen_view.assert_not_called()

    def test_recovery_and_retirement_use_distinct_fixed_dispatch(self):
        self.args.operation='publish-recovery';admin.run(self.args)
        self.mutation.publish_recovery.assert_called_once_with(self.store,self.selection,approved_selection_sha256='selection-hash',
                                                             scratch_root=self.private/'legacy-scratch')
        self.mutation.publish.assert_not_called()
        self.args.operation='retire';admin.run(self.args)
        self.retirement.retire.assert_called_once_with(self.store,self.selection,approved_selection_sha256='selection-hash',
                                                      scratch_root=self.private/'legacy-scratch')

    def test_capture_requires_exact_candidate_identity(self):
        self.args.operation='capture';self.args.candidate_path=None
        with self.assertRaisesRegex(ValueError,'candidate'):admin.run(self.args)
        self.capture.prepare.assert_not_called()
        self.args.candidate_path='/selected/worker';admin.run(self.args)
        self.capture.prepare.assert_called_once_with(self.store,'gate',approved_gate_sha256='gate-hash',
            repo_alias='fixture',candidate_path='/selected/worker',scratch_root=self.private/'legacy-scratch')

    def test_retirement_replay_bypasses_pending_frozen_view_without_bypassing_approval(self):
        self.args.operation='replay-retirement';self.args.approved_selection_sha256=None
        with self.assertRaisesRegex(ValueError,'approval'):admin.run(self.args)
        self.retirement.replay.assert_not_called()
        self.args.approved_selection_sha256='retirement-hash';admin.run(self.args)
        self.retirement.replay.assert_called_once_with(self.store,'gate',approved_selection_sha256='retirement-hash',
                                                      scratch_root=self.private/'legacy-scratch')
        self.store.frozen_view.assert_not_called()

if __name__=='__main__':unittest.main()
