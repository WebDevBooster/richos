import unittest
from timeout_rules import scan


class TimeoutRules(unittest.TestCase):
    def test_timeout_success(self):
        for source in ('if [ "$elapsed" -ge "$TIMEOUT" ]; then exit 0; fi',
                       'if (( SECONDS >= deadline )); then\n  exit 0\nfi',
                       'if [ "$remaining" -le 0 ]; then exit 0; fi'):
            with self.subTest(source=source):
                self.assertEqual(scan(source)[0][0], 'timeout-success')

    def test_refusal_and_success_condition(self):
        for source in ('if [ "$elapsed" -ge "$TIMEOUT" ]; then exit 1; fi',
                       'if [ "$ready" = yes ]; then exit 0; fi',
                       '# if [ "$remaining" -le 0 ]; then exit 0; fi'):
            self.assertEqual(scan(source), [])

    def test_indirect_is_advisory(self):
        self.assertEqual(scan('if [ "$elapsed" -ge "$TIMEOUT" ]; then fail_timeout; fi')[0][0], 'timeout-indirect')
