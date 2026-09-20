from contextlib import nullcontext
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest


class Wiring(unittest.TestCase):
    def test_nightly_supplies_state_and_current_suite_receipt(self):
        scripts = Path(__file__).resolve().parents[1]
        spec = importlib.util.spec_from_file_location('lint_nightly_fixture', scripts / 'nightly-local.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='lint-wiring-') as tmp:
            calls = []
            runner = SimpleNamespace(state=Path(tmp), source=scripts.parents[2],
                announce=lambda *a: None, phase=lambda *a: nullcontext(),
                command=lambda *a, **kw: calls.append((a, kw)),
                ui_suite=lambda *a: None)
            module.Runner.gates(runner)
            checks = [args for args, _ in calls if '--nightly' in args]
            self.assertEqual(len(checks), 1)
            self.assertEqual(checks[0][checks[0].index('--state-dir') + 1], Path(tmp))
            self.assertEqual(checks[0][checks[0].index('--suite-results') + 1], Path(tmp) / module.SUITE_RESULTS)
