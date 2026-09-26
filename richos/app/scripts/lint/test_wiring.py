import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest


class Wiring(unittest.TestCase):
    def test_nightly_runs_all_with_current_suite_receipt(self):
        scripts = Path(__file__).resolve().parents[1]
        spec = importlib.util.spec_from_file_location('lint_nightly_fixture', scripts / 'nightly-local.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        # One after another and side by side: the lint reads the SAME receipt either way.
        for at_once in (1, 'all'):
            with self.subTest(gates_at_once=at_once), \
                    tempfile.TemporaryDirectory(prefix='lint-wiring-') as tmp, \
                    contextlib.redirect_stdout(io.StringIO()):
                calls = []
                runner = module.Runner(Path(tmp), Path(tmp), {}, io.StringIO(), gates_at_once=at_once)
                runner.source = scripts.parents[2]
                runner.command = lambda *a, **kw: calls.append((a, kw))
                runner.ui_suite = lambda *a: None
                runner.gates()
                checks = [args for args, _ in calls if '--all' in args]
                self.assertEqual(len(checks), 1)
                self.assertNotIn('--state-dir', checks[0])
                self.assertEqual(checks[0][checks[0].index('--suite-results') + 1],
                                 Path(tmp) / module.SUITE_RESULTS)

    def test_land_suite_counts_the_ceiling_the_nightly_gate_refuses_on(self):
        # The land runs lint.test.sh; the nightly refuses on `lint.sh --all`. If the suite ran
        # less than the gate, a merge could pass here and then stop the build (c2bfe118).
        suite = Path(__file__).resolve().parents[1] / 'lint.test.sh'
        calls = [line.split() for line in suite.read_text().splitlines()
                 if '/lint.sh"' in line and not line.lstrip().startswith('#')]
        self.assertEqual(len(calls), 1)
        self.assertIn('--all', calls[0])
        self.assertNotIn('--fast', calls[0])
