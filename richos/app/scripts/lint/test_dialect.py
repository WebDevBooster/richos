from pathlib import Path
import tempfile
import unittest
from common import Refusal
from dialect import scan

ROOT = Path(__file__).resolve().parents[4]


class DialectAdapter(unittest.TestCase):
    def test_hook_red_green_and_quote(self):
        path = 'richos/app/lint-probe.md'
        self.assertTrue(scan(ROOT, path, 'The colour is blue.'))
        self.assertEqual(scan(ROOT, path, 'The color is blue.'), [])
        self.assertEqual(scan(ROOT, path, '> The colour is blue.'), [])
        self.assertEqual(scan(ROOT, 'richos/app/fixtures/probe.md', 'The colour is blue.'), [])

    def test_undeclared_locale_is_not_clean(self):
        with tempfile.TemporaryDirectory(prefix='lint-dialect-') as tmp:
            entity = Path(tmp)
            (entity / 'orchestration.config').write_text('DIALECT_TARGET=""\n')
            with self.assertRaises(Refusal):
                scan(ROOT, 'richos/app/lint-probe.md', 'The color is blue.', entity=entity)
