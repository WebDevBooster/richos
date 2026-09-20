import unittest
from process_rules import scan


class ProcessRules(unittest.TestCase):
    def test_selected_kill(self):
        for source in ('kill $(pgrep -f app)', 'pkill -f app',
                       'pid=$(pgrep -f app)\nkill "$pid"',
                       'for pid in $(pgrep -f app); do\nkill "$pid"\ndone'):
            with self.subTest(source=source):
                self.assertIn('process-pattern-kill', [r for r, _ in scan(source)])

    def test_owned_and_inspection(self):
        for source in ('pid=$!\nkill "$pid"', 'pgrep -f app', 'pkill -0 app',
                       'pid=$(pgrep -f app)\npid=$!\nkill "$pid"',
                       'echo "kill $(pgrep -f app)"', '# pkill -f app'):
            with self.subTest(source=source):
                self.assertEqual(scan(source), [])

    def test_self_command_line(self):
        self.assertEqual(scan("sh -c 'while pgrep -f worker; do sleep 1; done'")[0][0], 'process-self-wait')
        self.assertEqual(scan("while pgrep -f '[w]orker'; do sleep 1; done"), [])
        self.assertEqual(scan('while kill -0 "$owned_pid"; do sleep 1; done'), [])
