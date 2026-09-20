import unittest
from suite_rules import scan


class SuiteInputs(unittest.TestCase):
    def test_declaration_is_required_only_for_discovered_suites(self):
        self.assertEqual(scan('richos/app/scripts/example.test.sh', '#!/bin/bash\n'), [('suite-inputs', 1)])
        self.assertEqual(scan('richos/app/scripts/example.test.sh', '# run-tests: inputs '), [('suite-inputs', 1)])
        self.assertEqual(scan('richos/app/scripts/example.test.sh', '# run-tests: inputs richos/app/example'), [])
        self.assertEqual(scan('richos/app/scripts/qa/wait-for.sh', '#!/bin/bash\n'), [])
        self.assertEqual(scan('richos/app/scripts/testvm/test/helper.test.sh', '#!/bin/bash\n'), [])
