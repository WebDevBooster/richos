#!/usr/bin/env python3
"""The probe harness's own logic, tested on the host without a guest, a model or a network.

The guest driver carries a port of three pieces of Rust (operator_frames::alarms_in,
operator_profile::parse_banner, operator_profile::init_check) because it runs under the
guest's Python 3.9 with no app binary to call. A port can drift; these cases are the Rust
tests' own cases, including the banner line measured on the wire in run 1, so a drift in
either direction fails here or there.
"""
import importlib.util
import json
from pathlib import Path
import sys
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('guest_probes', HERE.parent / 'guest_probes.py')
gp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp)

MEASURED_BANNER = ('RichOS engine 1.2.0: ENFORCEMENT ACTIVE for /Users/admin/testvm/probes-412d7918db8e/home/ab/femcboost '
                   '(77/77 guards, engine at /Users/admin/testvm/probes-412d7918db8e/home/ab/richos/richos/engine, root via '
                   'project-dir). Engine HEAD not-a-git-checkout (this is the path that RUNS; an installation record naming '
                   'another path is not evidence until something is shown to read it).')


def hook_response(event, stdout, stderr=''):
    return {'type': 'system', 'subtype': 'hook_response', 'hook_id': 'h', 'hook_name': event, 'hook_event': event,
            'output': stdout + stderr, 'stdout': stdout, 'stderr': stderr, 'exit_code': 0, 'outcome': 'success'}


class Frames(unittest.TestCase):
    def test_a_system_message_is_an_alarm_and_plain_text_or_stderr_is_not(self):
        self.assertEqual([a['text'] for a in gp.alarms_in(hook_response('Stop', '{"systemMessage":"esc-1"}\n'))], ['esc-1'])
        self.assertEqual(gp.alarms_in(hook_response('Stop', 'plain text for the model\n')), [])
        self.assertEqual(gp.alarms_in(hook_response('Stop', '', '{"systemMessage":"on stderr"}')), [])
        self.assertEqual(gp.alarms_in(hook_response('Stop', '{"systemMessage":""}')), [])
        pretty = '{\n  "systemMessage": "pretty"\n}\n'
        self.assertEqual([a['text'] for a in gp.alarms_in(hook_response('Stop', pretty))], ['pretty'])

    def test_informational_frames_are_alarms_and_the_framing_is_dropped_only_for_the_key(self):
        alarms = gp.alarms_in({'type': 'system', 'subtype': 'informational', 'content': 'Stop says: esc-1', 'level': 'notice'})
        self.assertEqual(alarms[0]['text'], 'Stop says: esc-1')
        self.assertEqual(gp.dedupe_key('Stop says: esc-1'), 'esc-1')
        self.assertEqual(gp.dedupe_key('Rich says: keep this'), 'Rich says: keep this')


class Banner(unittest.TestCase):
    def test_the_measured_person_facing_line_is_the_banner(self):
        b = gp.parse_banner(MEASURED_BANNER)
        self.assertEqual((b['version'], b['guard_count'], b['guard_expected']), ('1.2.0', 77, 77))
        self.assertTrue(b['engine_root'].endswith('/home/ab/richos/richos/engine'))
        self.assertTrue(b['governing'].endswith('/home/ab/femcboost'))

    def test_the_model_summary_is_read_too_and_stand_downs_are_not(self):
        long = ('RichOS engine 1.2.0 ACTIVE. Engine: /e. Governing: /f (resolved via x). 26/26 guards present (...)')
        self.assertEqual(gp.parse_banner(long)['engine_root'], '/e')
        self.assertIsNone(gp.parse_banner('RichOS engine 1.2.0: STOOD DOWN — this repository has not adopted it.'))
        self.assertIsNone(gp.parse_banner('Stop says: hello'))


class InitCheck(unittest.TestCase):
    ENGINE = '/fixture/engine'

    def init(self, plugins, tools):
        return {'plugins': [{'name': n} for n in plugins], 'tools': tools}

    def banner(self, root=ENGINE, count=77, expected=77):
        return {'version': '1.2.0', 'engine_root': root, 'governing': '/f', 'guard_count': count, 'guard_expected': expected}

    def test_every_condition_refuses_and_the_good_case_opens(self):
        report = ['mcp__richos_operator__report']
        self.assertEqual(gp.init_check(self.init(['richos-engine'], report), self.banner(), self.ENGINE)[0], 'open')
        for init, banner in [
            (self.init([], report), self.banner()),
            (self.init(['richos-engine', 'richos-engine'], report), self.banner()),
            (self.init(['richos-engine', 'richos-app-engine'], report), self.banner()),
            (self.init(['richos-engine'], []), self.banner()),
            (self.init(['richos-engine'], report), None),
            (self.init(['richos-engine'], report), self.banner(root='/Users/x/.claude/plugins/cache/richos-local/e')),
            (self.init(['richos-engine'], report), self.banner(count=76)),
        ]:
            self.assertEqual(gp.init_check(init, banner, self.ENGINE)[0], 'refuse', (init, banner))


class Redaction(unittest.TestCase):
    def test_account_fields_and_addresses_never_reach_a_result_file(self):
        frame = {'type': 'control_response', 'response': {'account': {'email': 'a@b.example'}, 'note': 'mail c@d.example'}}
        out = json.dumps(gp.redact(frame))
        self.assertNotIn('a@b.example', out)
        self.assertNotIn('c@d.example', out)
        self.assertIn('<removed>', out)


class KernelEnvironment(unittest.TestCase):
    def read(self, argv, env):
        import subprocess
        import time
        child = subprocess.Popen(argv, env=env)
        try:
            names = None
            for _ in range(40):
                names = gp.environ_names(child.pid)
                if names:
                    break
                time.sleep(0.05)
            return names
        finally:
            child.kill()
            child.wait()

    def test_names_are_read_off_a_non_apple_child_and_no_values_leave(self):
        node = '/opt/homebrew/bin/node'
        if not Path(node).exists():
            self.skipTest('no Homebrew node on this machine')
        names = self.read([node, '-e', 'setTimeout(function(){}, 30000)'],
                          {'PROBE_NAME_ONE': 'secret-value', 'PATH': '/usr/bin:/bin'})
        self.assertEqual(names, ['PATH', 'PROBE_NAME_ONE'])
        self.assertNotIn('secret-value', json.dumps(names))

    def test_an_apple_binary_s_environment_is_withheld_and_reads_as_none_never_as_empty(self):
        """Measured 2026-09-25: the kernel returns /bin/sleep's arguments and no environment."""
        self.assertIsNone(self.read(['/bin/sleep', '30'], {'PROBE_NAME_ONE': 'x', 'PATH': '/usr/bin:/bin'}))


class Record(unittest.TestCase):
    def test_the_record_step_refuses_the_public_repository_and_bounds_long_strings(self):
        rspec = importlib.util.spec_from_file_location('record', HERE.parent / 'record.py')
        record = importlib.util.module_from_spec(rspec)
        rspec.loader.exec_module(record)
        self.assertTrue(record.public(HERE), 'this harness lives in the public richos repository')
        bounded = record.bound({'a': 'x' * (record.MAX_STRING + 50), 'b': ['short']})
        self.assertTrue(bounded['a'].endswith('[cut by record.py: %d characters in the run]' % (record.MAX_STRING + 50)))
        self.assertEqual(bounded['b'], ['short'])


class Arguments(unittest.TestCase):
    def test_the_lead_arguments_mirror_the_operator_profile(self):
        """operator_profile::child_args, flag for flag. If the profile changes, this list must."""
        ctx = gp.Context.__new__(gp.Context)
        ctx.p = gp.Paths('/fixture/payload')
        ctx.python = '/opt/homebrew/bin/python3'
        a = ctx.lead_args(session_id='s-1')
        for flag in ['--print', '--input-format=stream-json', '--output-format=stream-json', '--include-partial-messages',
                     '--verbose', '--include-hook-events', '--dangerously-skip-permissions']:
            self.assertIn(flag, a)
        self.assertEqual(a[a.index('--setting-sources') + 1], 'user,project,local')
        self.assertEqual(a[a.index('--permission-prompt-tool') + 1], 'stdio')
        self.assertEqual(a[a.index('--disallowed-tools') + 1], 'AskUserQuestion')
        self.assertNotIn('--no-session-persistence', a)
        self.assertNotIn('--plugin-dir', a)
        self.assertEqual(a[-2], '--mcp-config')
        rust = (HERE.parents[2] / 'crates' / 'richos-core' / 'src' / 'operator_profile.rs').read_text()
        for flag in ['"--include-hook-events"', '"user,project,local"', '"--disallowed-tools"', '"--mcp-config"',
                     '"--dangerously-skip-permissions"']:
            self.assertIn(flag, rust, 'the profile no longer carries %s: update the harness with it' % flag)


if __name__ == '__main__':
    unittest.main(verbosity=2)
