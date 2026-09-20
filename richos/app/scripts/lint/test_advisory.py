import unittest
from advisory_rules import scan


class AdvisoryRules(unittest.TestCase):
    def test_refusal_candidates(self):
        self.assertEqual(scan('assert!(result.is_err());', 'suite', 'rust')[0][0], 'test-positive-control')
        self.assertEqual(scan('assert!(result.is_err());\nassert!(valid.is_ok());', 'suite', 'rust'), [])
        self.assertEqual(scan('assert!(result.is_err());', 'production', 'rust'), [])
        self.assertEqual(scan('// assert the refusal', 'suite', 'javascript'), [])

    def test_retry_candidates(self):
        self.assertEqual(scan('sleep 2\nassert_ready', 'suite', 'shell')[0][0], 'test-retry')
        self.assertEqual(scan('sleep 2', 'production', 'shell'), [])
        self.assertEqual(scan('# sleep 2', 'suite', 'shell'), [])
        # Product retry inside a test remains only a candidate, never blocking.
        self.assertEqual(scan('product.retry()', 'suite', 'javascript')[0][0], 'test-retry')

    def test_absence_candidates(self):
        self.assertEqual(scan('label = "No files found";', 'production', 'javascript')[0][0], 'ui-absence')
        self.assertEqual(scan('label = "Looking for files";', 'production', 'javascript'), [])
        self.assertEqual(scan('// old label = "No files found";', 'production', 'javascript'), [])
        self.assertEqual(scan('button("No thanks");', 'production', 'javascript'), [])
        self.assertEqual(scan('assert(label === "No files found");', 'suite', 'javascript'), [])
