import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import driver
import rust


class Inputs(unittest.TestCase):
    def test_removed_lint_and_removed_inheritance_change_rule_identity(self):
        with tempfile.TemporaryDirectory(prefix='lint-manifest-') as tmp:
            root = Path(tmp)
            path = 'richos/app/Cargo.toml'
            manifest = root / path
            manifest.parent.mkdir(parents=True)
            original = '[package]\nname="fixture"\n[lints]\nworkspace=true\n[workspace.lints.rust]\nunused_must_use="warn"\n'
            manifest.write_text(original)
            with patch('rust.tracked', return_value=[path]):
                before = rust.lint_rules(root)
                manifest.write_text(original.replace('workspace=true', 'workspace=false'))
                self.assertNotEqual(before, rust.lint_rules(root))
                manifest.write_text(original.replace('unused_must_use="warn"', ''))
                self.assertNotEqual(before, rust.lint_rules(root))

    def test_real_content_changes_invalidate(self):
        with tempfile.TemporaryDirectory(prefix='lint-inputs-') as tmp:
            root = Path(tmp).resolve()
            paths = ['richos/app/src-tauri/Cargo.toml', 'richos/app/src-tauri/src/main.rs',
                     'richos/app/crates/new-dependency/Cargo.toml', 'richos/app/crates/new-dependency/src/lib.rs',
                     'rust-toolchain.toml', 'richos/app/clippy.toml', 'richos/app/src-tauri/Cargo.lock']
            for p in paths:
                (root / p).parent.mkdir(parents=True, exist_ok=True)
                (root / p).write_text('initial')
            manifest = root / paths[0]
            dependency = root / paths[2]
            def metadata(command, *_args, **_kwargs):
                if command[0] == 'git': return ''
                current = Path(command[-1])
                return json.dumps({'packages': [{'manifest_path': str(current), 'dependencies':
                    [{'path': str(dependency.parent)}] if current == manifest else []}]})
            with patch('rust.checked', side_effect=metadata), patch('rust.tracked', return_value=paths):
                def digest(version='v1'):
                    return rust.tauri_inputs(root, {'clippy': version}, time.monotonic() + 10)
                original = digest()
                self.assertEqual(original, digest())
                for path in paths[1:]:
                    with self.subTest(path=path):
                        (root / path).write_text('changed')
                        self.assertNotEqual(original, digest())
                        (root / path).write_text('initial')
                self.assertNotEqual(original, digest('v2'))

    def test_skipped_suite_is_not_current_fast_proof(self):
        with tempfile.TemporaryDirectory(prefix='lint-receipt-') as tmp:
            path = Path(tmp) / 'receipt.json'
            for status, expected in [('passed', True), ('skipped', False), ('failed', False)]:
                path.write_text(json.dumps({'run_id': 'current', 'suites': [{'name': 'lint.test.sh', 'state': status}]}))
                self.assertEqual(driver.fast_was_run(path, 'current'), expected)
                self.assertFalse(driver.fast_was_run(path, 'different'))
