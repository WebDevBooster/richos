"""The merge-scope regressions use real selectors and fixture tool/result protocols."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("MERGE_SCOPE_TEST_ROOT", HERE.parents[2]))
TOOLS = ROOT / "richos/app/scripts"
sys.path.insert(0, str(HERE / 'lib'))
import ios_ui_scope
import ios_ui_shards


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Scope(unittest.TestCase):
    def selection(self, paths):
        result = subprocess.run(['bash', str(TOOLS / 'proof-for.sh'), '--quiet', '--paths', ','.join(paths)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_previous_cargo_fix_selects_no_iphone_suite(self):
        paths = subprocess.check_output(['git', '-C', str(ROOT), 'diff', '--name-only',
                                         'ad1b6996..0c65837b'], text=True).splitlines()
        plan = self.selection(paths)
        for name in ('native-ios-app', 'native-ios-ui', 'native-ios-share'):
            self.assertNotIn(name + '.test.sh', plan)

    def test_real_shared_app_dependency_still_selects_iphone(self):
        plan = self.selection(['richos/mobile/native-ios/Core/Sources/RichOSCore/Protocol/URLSessionTransport.swift'])
        for name in ('native-ios-app', 'native-ios-ui', 'native-ios-share'):
            self.assertIn(name + '.test.sh', plan)

    def test_composer_change_selects_cases_and_not_unrelated_pairing(self):
        plan = self.selection(['richos/mobile/native-ios/App/Features/Composer/ComposerView.swift'])
        self.assertIn('--only ScreenshotTests/testComposerDark', plan)
        self.assertIn('--only InteractionTests/testComposeAndSendAddsTheMessageAndFollowsIt', plan)
        self.assertNotIn('--only PairWaitInteractionTests', plan)

    def test_new_app_source_is_conservative_and_test_source_selects_its_cases(self):
        self.assertIsNone(ios_ui_scope.select(ROOT, ['richos/mobile/native-ios/App/NewFeature/New.swift']))
        selected = ios_ui_scope.select(ROOT, ['richos/mobile/native-ios/UITests/QuestionTests.swift'])
        self.assertEqual(selected, ['QuestionTests/testOtherAnswerInLightTheme',
                                    'QuestionTests/testTapAndOfflineEditLeaveTheComposerAvailable'])

    def test_product_plist_and_package_changes_still_select_all_phone_suites(self):
        for path in ['Release/App-Info.plist', 'Core/Package.swift']:
            plan = self.selection(['richos/mobile/native-ios/' + path])
            for suite in ('native-ios-app', 'native-ios-share', 'native-ios-ui'):
                self.assertIn(suite + '.test.sh', plan)

    def test_unit_source_selects_its_suite_with_attribution_control(self):
        selected = ios_ui_scope.select(ROOT, ['richos/mobile/native-ios/UnitTests/TooShortLineTests.swift'])
        self.assertEqual(selected, ['RichOSNativeTests/BuildStampTests/testTheBundleCarriesItsBuildStamp',
                                   'RichOSNativeTests/TooShortLineTests'])

    def test_suites_queue_on_one_lane_with_existing_finite_deadlines(self):
        pr = load('merge_scope_runner', 'richos/app/scripts/proof-run.py')
        from types import SimpleNamespace
        args = SimpleNamespace(deadline=1800, engine_shards=4, fail_fast=False)
        # plan() keeps an explicit RICHOS_IOS_POOL_WAIT from its caller; the nightly sets one for its
        # children, so this test must not read the ambient value (nightly attempt 2: KeyError).
        with tempfile.TemporaryDirectory() as log, mock.patch.dict(os.environ):
            os.environ.pop('RICHOS_IOS_POOL_WAIT', None)
            items = pr.plan(['cd richos/app && scripts/run-tests.sh --no-host-screen --only native-ios-app.test.sh --only native-ios-share.test.sh',
                             'cd richos/app && bash scripts/native-ios-ui.test.sh --only QuestionTests/testOtherAnswerInLightTheme'], args, log, {})
        self.assertEqual(len(items), 3)
        self.assertEqual({item.lane for item in items}, {'ios-simulator'})
        for item in items:
            self.assertEqual(float(item.env['RICHOS_IOS_POOL_WAIT']), pr.deadline_for(item, args))

    def test_direct_ui_refusal_is_not_run_and_actual_failure_stays_failed(self):
        pr = load('merge_scope_verdict', 'richos/app/scripts/proof-run.py')
        with tempfile.TemporaryDirectory() as work:
            item = pr.Item('native-ios-ui', str(ROOT), ['bash', 'scripts/native-ios-ui.test.sh'])
            item.rc, item.state = 2, 'failed'
            item.log = str(Path(work) / 'log')
            Path(item.log).write_text('  NOT RUN  native-ios-ui: prepared simulator is leased by another run; no UI test ran\n')
            pr.not_run(item)
            self.assertEqual(item.state, 'not-run')
            item.state = 'failed'
            Path(item.log).write_text('  FAIL  assertion\n  NOT RUN  native-ios-ui: unavailable\n')
            pr.not_run(item)
            self.assertEqual(item.state, 'failed')

    def test_real_ui_acquisition_adapter_distinguishes_refusal_and_error(self):
        text = (TOOLS / 'native-ios-ui.test.sh').read_text()
        start = text.index('  SIM_UDID[i]="$(python3')
        end = text.index('  CREATED+=', start)
        block = text[start:end]
        with tempfile.TemporaryDirectory() as work:
            base = 'WORK=' + work + '\ni=0; SIM_TYPE=(fixture); RUNTIME=fixture; RICHOS_TESTDEVICES=fixture\n'
            for message, code in [('prepared simulator is leased by another run', 2), ('cannot read simulator inventory', 1)]:
                fixture = base + 'python3() { echo "' + message + '" >&2; return 1; }\nnot_run() { echo "  NOT RUN  native-ios-ui: $*"; exit 2; }\n' + block
                result = subprocess.run(['bash', '-c', fixture], text=True, capture_output=True)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)

    def test_share_and_app_adapters_distinguish_unavailable_device_from_failure(self):
        app = (TOOLS / 'native-ios-app.test.sh').read_text()
        app = app[app.index('if "$RIOS" sim prepare'):app.index('UDID="$(json', app.index('if "$RIOS" sim prepare'))]
        share = (ROOT / 'richos/mobile/native-ios/Release/simulator-tests.sh').read_text()
        start = share.index('UDID="$(python3')
        share = share[start:share.index('cleanup()', start)]
        with tempfile.TemporaryDirectory() as work:
            for message, expected in [('prepared simulator is leased by another run', 2), ('compile error', 1)]:
                prepare = Path(work) / 'rios'
                prepare.write_text('#!/bin/sh\necho "' + message + '" >&2\nexit 1\n')
                prepare.chmod(0o755)
                fixture = ('SCRATCH=' + work + '; OUT=' + work + '; RIOS=' + str(prepare) + '\n'
                           'PASS=0; FAILED=0; HERE=fixture; RUNTIME=fixture\n'
                           'bad() { FAILED=$((FAILED + 1)); }; notrun() { echo "NOT RUN $*"; exit 2; }\n'
                           'python3() { echo "' + message + '" >&2; return 1; }\n')
                for block in (app, share):
                    result = subprocess.run(['bash', '-c', fixture + block], text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_unreviewed_case_and_new_feature_file_use_full_coverage(self):
        original = ios_ui_scope.inventory(ROOT)
        changed = {**original, 'NewTests.swift': ['NewTests/testNewBehavior']}
        with mock.patch.object(ios_ui_scope, 'inventory', return_value=changed):
            self.assertIsNone(ios_ui_scope.select(ROOT, ['richos/mobile/native-ios/App/Features/Composer/ComposerView.swift']))
        self.assertIsNone(ios_ui_scope.select(ROOT, ['richos/mobile/native-ios/App/Features/Composer/NewView.swift']))

    def test_existing_shard_attribution_and_completeness_controls(self):
        self.assertEqual(ios_ui_shards.selftest(), 0)

    def test_run_tests_refusal_is_not_run_and_failure_wins(self):
        pr = load('merge_scope_wrapped_verdict', 'richos/app/scripts/proof-run.py')
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'results.json'
            item = pr.Item('native-ios-share', str(ROOT), ['scripts/run-tests.sh', '--results-out', str(path)])
            item.rc, item.state = 2, 'failed'
            path.write_text(json.dumps({'suites': [{'name': 'native-ios-share.test.sh', 'state': 'gap'}]}))
            pr.not_run(item)
            self.assertEqual(item.state, 'not-run')
            item.rc, item.state = 1, 'failed'
            pr.not_run(item)
            self.assertEqual(item.state, 'failed')

    def test_failed_only_retry_keeps_missing_cases_and_verifies_combined_coverage(self):
        with tempfile.TemporaryDirectory() as base:
            old, new = Path(base) / 'old', Path(base) / 'new'
            old.mkdir(); new.mkdir()
            for work in (old, new):
                (work / 'build-stamp.txt').write_text('source-stamp')
                (work / 'expected.txt').write_text('')
                (work / 'result-0.xcresult').mkdir()
            (new / 'tests-0.json').write_text(json.dumps({'values': [{'enabledTests': [
                {'identifier': 'RichOSNativeUITests/C/' + name} for name in ('pass', 'fail', 'missing')]}]}))
            (new / 'test-0.rc').write_text('0')
            old_rows = [('RichOSNativeUITests/C/pass', 'Passed', 1, ''),
                        ('RichOSNativeUITests/C/fail', 'Failed', 1, '')]
            new_rows = [('RichOSNativeUITests/C/fail', 'Passed', 1, ''),
                        ('RichOSNativeUITests/C/missing', 'Passed', 1, '')]
            def results(bundle, runner=None):
                rows = old_rows if str(bundle).startswith(str(old)) else new_rows
                ios_ui_shards.result_tests.kinds = {'RichOSNativeUITests': 'UI test bundle'}
                return {'passed': sum(r[1] == 'Passed' for r in rows), 'failed': sum(r[1] == 'Failed' for r in rows),
                        'skipped': 0, 'total': len(rows)}, rows.copy()
            def stamps(bundle, out, runner=None):
                return {'C/' + name: 'source-stamp' for name in ('pass', 'fail', 'missing')}
            with mock.patch.object(ios_ui_shards, 'result_tests', side_effect=results), mock.patch.object(ios_ui_shards, 'stamps', side_effect=stamps):
                ios_ui_shards.cmd_retry(new, str(old), 0)
                args = (new / 'retry-0.args').read_text()
                self.assertNotIn('/pass', args)
                self.assertIn('/fail', args)
                self.assertIn('/missing', args)
                self.assertEqual(ios_ui_shards.cmd_verify(str(new), 1, str(new / 'times.tsv'), ['SE']), 0)
                # Damage to reused evidence refuses green rather than trusting the manifest.
                old_rows[0] = ('RichOSNativeUITests/C/pass', 'Failed', 1, '')
                self.assertEqual(ios_ui_shards.cmd_verify(str(new), 1, str(new / 'times.tsv'), ['SE']), 1)
                (new / 'test-0.lost').write_text('{}')
                self.assertEqual(ios_ui_shards.cmd_verify(str(new), 1, str(new / 'times.tsv'), ['SE']), 2)
                (new / 'test-0.lost').unlink()
                # Different inputs or lost leases cannot contribute passing cases.
                (old / 'build-stamp.txt').write_text('different-source')
                ios_ui_shards.cmd_retry(new, str(old), 0)
                self.assertIn('/pass', (new / 'retry-0.args').read_text())
                (old / 'build-stamp.txt').write_text('source-stamp')
                (old / 'test-0.lost').write_text('{}')
                ios_ui_shards.cmd_retry(new, str(old), 0)
                self.assertIn('/pass', (new / 'retry-0.args').read_text())

    def test_all_skipped_cases_are_not_run_and_missing_unit_source_is_conservative(self):
        self.assertIsNone(ios_ui_scope.select(ROOT, ['richos/mobile/native-ios/UnitTests/DeletedTests.swift']))
        with tempfile.TemporaryDirectory() as base:
            work = Path(base)
            (work / 'expected.txt').write_text('B/C/a\n')
            (work / 'test-0.rc').write_text('0')
            rows = [('B/C/a', 'Skipped', 0, 'needs physical device')]
            with mock.patch.object(ios_ui_shards, 'result_tests', return_value=(
                    {'passed': 0, 'failed': 0, 'skipped': 1, 'total': 1}, rows)):
                self.assertEqual(ios_ui_shards.cmd_verify(base, 1, str(work / 'times.tsv'), ['SE']), 2)

    def test_retry_identity_binds_untracked_source_and_execution_settings(self):
        with tempfile.TemporaryDirectory() as base:
            root = Path(base)
            scripts = root / 'richos/app/scripts'
            (scripts / 'lib').mkdir(parents=True)
            (scripts / 'native-ios-ui.test.sh').write_text('# run-tests: inputs source\n')
            (scripts / 'lib/ios_ui_shards.py').write_text('fixture')
            (root / 'source').mkdir()
            (root / 'source/untracked.swift').write_text('one')
            with mock.patch.object(subprocess, 'check_output', return_value='Xcode fixture'):
                identity = ios_ui_shards.retry_identity(root, 'ios', ['SE'], ['case'])
                with mock.patch.dict(os.environ, {'RICHOS_PROOF_RUN': 'new-attempt', 'RICHOS_TEST_DEVICE_RUN_ID': 'new-run',
                                                   'RICHOS_TEST_RESULTS_ROOT': 'new-results', 'RICHOS_AUTOCHECK_RETRY_REASON': 'diagnosed'}):
                    self.assertEqual(identity, ios_ui_shards.retry_identity(root, 'ios', ['SE'], ['case']))
                (root / 'source/untracked.swift').write_text('two')
                self.assertNotEqual(identity, ios_ui_shards.retry_identity(root, 'ios', ['SE'], ['case']))
                self.assertNotEqual(identity, ios_ui_shards.retry_identity(root, 'ios', ['Pro'], ['case']))

    def test_scr_weight_is_measured_and_under_the_merge_gates_cap(self):
        # Section SCR now only checks discovery and declared thresholds: 4.8 s measured alone at
        # 4e73fd89. Its old 676.8 s (a contended full suite, when it still ran the reaper's
        # suite) planned it past the merge gate's 600 s cap, and proof-run.py --cap never starts
        # a check planned past the cap, so a stale row here would leave it unrun at every merge.
        rows = (ROOT / 'richos/engine/scripts/lib/ci-unit-weights.tsv').read_text().splitlines()
        weights = [float(row.split('\t')[1]) for row in rows if row.startswith('scripts/hooks/contract-integrity.test.sh:SCR\t')]
        self.assertEqual(len(weights), 1, weights)
        self.assertTrue(0 < weights[0] < 600, weights)


if __name__ == '__main__':
    unittest.main()
