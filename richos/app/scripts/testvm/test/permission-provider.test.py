#!/usr/bin/env python3
"""The native-walk provider must wait for the exact decision, not invent one."""
import json
from pathlib import Path
import select
import subprocess
import sys
import unittest

PROVIDER = Path(__file__).resolve().parents[1] / 'permission-provider.py'


class PermissionProviderTests(unittest.TestCase):
    def setUp(self):
        self.child = subprocess.Popen([sys.executable, '-u', str(PROVIDER)],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, bufsize=0)

    def tearDown(self):
        if self.child.poll() is None:
            self.child.terminate()
        self.child.communicate(timeout=5)

    def send(self, frame):
        self.child.stdin.write((json.dumps(frame) + '\n').encode())
        self.child.stdin.flush()

    def read(self):
        self.assertTrue(select.select([self.child.stdout], [], [], 3)[0], 'no provider frame')
        return json.loads(self.child.stdout.readline())

    def prompt(self, text):
        self.send({'type': 'user', 'message': {'content': text}})

    def test_initialize_and_hidden_context_do_not_ask(self):
        self.send({'type': 'control_request', 'request_id': 'req_init',
                   'request': {'subtype': 'initialize'}})
        self.assertEqual(self.read()['response']['request_id'], 'req_init')
        self.prompt('Synthetic startup context')
        self.assertEqual(self.read()['type'], 'result')

    def test_exact_decision_releases_each_request_once(self):
        for decision in ('allow', 'deny'):
            self.prompt('S7_NATIVE_PERMISSION_' + decision.upper())
            request = self.read()
            self.assertEqual(request['request']['subtype'], 'can_use_tool')
            self.assertFalse(select.select([self.child.stdout], [], [], .05)[0],
                             'provider finished while permission was unanswered')
            self.send({'type': 'control_response', 'response': {
                'request_id': 'unrelated', 'response': {'behavior': decision}}})
            self.assertFalse(select.select([self.child.stdout], [], [], .05)[0],
                             'unrelated decision released the request')
            self.send({'type': 'control_response', 'response': {
                'request_id': request['request_id'], 'response': {'behavior': decision}}})
            receipt = self.read()['message']['content'][0]['text']
            self.assertIn('received ' + decision, receipt)
            self.assertIn(request['request_id'], receipt)
            self.assertEqual(self.read()['type'], 'result')

    def test_interrupt_does_not_approve(self):
        self.prompt('S7_NATIVE_PERMISSION_ALLOW')
        self.read()
        self.send({'type': 'control_request', 'request_id': 'stop',
                   'request': {'subtype': 'interrupt'}})
        self.assertEqual(self.read()['response']['request_id'], 'stop')
        self.assertEqual(self.read()['type'], 'result')


if __name__ == '__main__':
    unittest.main()
