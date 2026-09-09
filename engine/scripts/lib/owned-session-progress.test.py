#!/usr/bin/env python3
"""Resumable host inspection orchestration, with no synthetic CEO turns."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('existing_owned_tests', Path(__file__).with_name('owned-session.test.py'))
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)
o = baseline.o


def response(value):
    return subprocess.CompletedProcess([], 0, json.dumps(value), '')


def progress(moved=True, key='native-inspector-session'):
    return response({'kind': 'progress', 'checkpoint': key, 'reason': 'Source reads retained before slice deadline.', 'progressed': moved})


class InspectionProgress(unittest.TestCase):
    setUp = baseline.Owned.setUp
    tearDown = baseline.Owned.tearDown
    write_message = baseline.Owned.write_message

    def test_slices_automatically_finish_without_worker_wake_or_failure_budget(self):
        path = o.capture(self.root, self.payload)
        results = [progress(), progress(False), progress(), response({'kind': 'complete', 'evidence': 'All current requirements verified.'})]
        snapshots = []
        def run(*args, **kwargs):
            snapshots.append(json.loads(path.read_text()))
            self.assertTrue(Path(kwargs['env']['RICHOS_AUDIT_CHECKPOINT']).is_absolute())
            self.assertEqual(len(kwargs['pass_fds']), 2)
            return results.pop(0)
        with patch.object(o.subprocess, 'run', side_effect=run):
            self.assertEqual(o.audit(path, self.config), (0, ''))
        self.assertEqual(len(snapshots), 4)
        self.assertTrue(all(s['audit_attempts'] == 1 for s in snapshots))
        self.assertTrue(all('audit_wake' not in s for s in snapshots))
        self.assertEqual(snapshots[-1]['inspection_progress']['stalled_slices'], 0)
        saved = json.loads(path.read_text())
        self.assertEqual(saved['failures'], 0)
        self.assertEqual(saved['verdict']['kind'], 'complete')
        self.assertNotIn('inspection_progress', saved)

    def test_stalled_inspection_exits_without_rewake_or_identical_retry(self):
        path = o.capture(self.root, self.payload)
        with patch.object(o.subprocess, 'run', return_value=progress(False)) as run:
            code, diagnostic = o.audit(path, self.config)
            self.assertEqual(code, 0)
            self.assertIn('does not block normal session exit', diagnostic)
            self.assertEqual(run.call_count, 3)
            self.assertEqual(o.audit(path, self.config), (0, ''))
            self.assertEqual(run.call_count, 3)
        saved = json.loads(path.read_text())
        self.assertIn('no durable progress', saved['integration_failure']['diagnostic'])
        self.assertNotIn('audit_wake', saved)
        self.assertEqual(saved['failures'], 1)
        self.assertEqual(saved['audit_attempts'], 1)

    def test_checkpoint_is_stable_across_source_changes_and_native_sessions(self):
        path = o.capture(self.root, self.payload)
        calls = []
        def run(*args, **kwargs):
            calls.append(kwargs)
            if len(calls) == 1:
                saved = json.loads(path.read_text())
                saved['messages'].append({'role': 'user', 'text': 'Pause delivery. Keep all source evidence.'})
                saved['revision'] += 1
                o.atomic(path, saved)
                return progress()
            self.assertIn('Pause delivery.', kwargs['input'])
            return response({'kind': 'complete', 'evidence': 'Source-bound pause reconciled.'})
        with patch.object(o.subprocess, 'run', side_effect=run):
            self.assertEqual(o.audit(path, self.config), (0, ''))
        self.assertEqual(calls[0]['env']['RICHOS_AUDIT_CHECKPOINT'], calls[1]['env']['RICHOS_AUDIT_CHECKPOINT'])
        other_session = o.location(self.root, 'replacement-session')
        self.assertEqual(o.inspection_checkpoint(path, self.root), o.inspection_checkpoint(other_session, self.root))
        self.assertNotEqual(o.inspection_checkpoint(path, self.root), o.inspection_checkpoint(path, self.root/'other-workspace'))

    def test_host_progress_schema_rejects_model_verdict_and_extra_authority(self):
        good = json.loads(progress().stdout)
        for value in [dict(good, progressed=1), dict(good, checkpoint=''), dict(good, reason=' '), dict(good, evidence='complete'), dict(good, checkpoint='a'*257)]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                o.validate_inspection_progress(value)
        with self.assertRaises(ValueError):
            o.validate_verdict(good)
        path = o.capture(self.root, self.payload)
        with patch.object(o.subprocess, 'run', return_value=response(dict(good, permissions='all'))):
            self.assertEqual(o.audit(path, self.config)[0], 0)
        self.assertNotIn('audit_wake', json.loads(path.read_text()))

    def test_progress_is_not_completion_and_restarts_at_durable_checkpoint(self):
        path = o.capture(self.root, self.payload)
        with patch.object(o.subprocess, 'run', return_value=progress()):
            self.assertEqual(o.audit_once(path, self.config), (-1, ''))
        state = json.loads(path.read_text())
        self.assertEqual(state['audit_inference']['phase'], 'progress')
        self.assertNotIn('checked', state)
        self.assertNotEqual(state.get('verdict', {}).get('kind'), 'complete')
        expected = str(o.inspection_checkpoint(path, self.root).resolve())
        with patch.object(o.subprocess, 'run', return_value=response({'kind':'complete','evidence':'Resumed checkpoint verified.'})) as run:
            self.assertEqual(o.audit(path, self.config), (0, ''))
        self.assertEqual(run.call_args.kwargs['env']['RICHOS_AUDIT_CHECKPOINT'], expected)

    def test_owner_loss_after_slice_retires_before_another_inference(self):
        path = o.capture(self.root, self.payload)
        with patch.object(o.subprocess, 'run', return_value=progress()):
            self.assertEqual(o.audit_once(path, self.config), (-1, ''))
        with patch.object(o, 'checked_audit_process', side_effect=o.OwnershipSuperseded('native owner exited')), patch.object(o.subprocess, 'run') as run:
            with self.assertRaises(o.OwnershipSuperseded):
                o.audit(path, self.config, binding={'root':str(self.root), 'session':'native-leader'})
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
