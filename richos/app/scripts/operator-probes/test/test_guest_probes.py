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
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, 'clean.json').write_text('{"names": ["PATH", "HOME"]}')
            self.assertEqual(record.scan(folder), {})
            Path(folder, 'leak.jsonl').write_text('{"x": "someone@example.org", "y": "API_KEY=abcdefgh"}')
            self.assertEqual(sorted(record.scan(folder)), ['email address in leak.jsonl', 'secret value in leak.jsonl'])
        bounded = record.bound({'a': 'x' * (record.MAX_STRING + 50), 'b': ['short']})
        self.assertTrue(bounded['a'].endswith('[cut by record.py: %d characters in the run]' % (record.MAX_STRING + 50)))
        self.assertEqual(bounded['b'], ['short'])


def sysf(subtype, **kw):
    return dict({'type': 'system', 'subtype': subtype}, **kw)


class GradeP5(unittest.TestCase):
    """r4 §1.1/§5: a turn started with nothing sent after the agent's task_notification, and
    SubagentStop fired. TeammateIdle/TaskCompleted are recorded, never required."""
    def rows(self, subagent_stop=True, turn=True, notify_at=10.0):
        rows = [(1.0, {'type': 'result'})]
        if subagent_stop:
            rows.append((notify_at - 0.2, sysf('hook_response', hook_event='SubagentStop')))
        rows.append((notify_at, sysf('task_notification', task_id='a1', status='completed')))
        rows.append((notify_at, sysf('task_notification', task_id='b-bash', status='completed')))
        if turn:
            rows.append((notify_at + 0.5, sysf('hook_started', hook_event='UserPromptSubmit')))
            rows.append((notify_at + 3.0, {'type': 'result'}))
        return rows

    def test_the_measured_shape_passes_with_no_teammate_hooks(self):
        verdict, why, facts = gp.grade_p5(self.rows(), 'a1', 1.0)
        self.assertEqual(verdict, 'PASS', why)
        self.assertEqual(facts['seconds_notification_to_turn'], 0.5)
        self.assertEqual(facts['teammate_hooks_fired'], [])

    def test_each_missing_signal_fails(self):
        self.assertEqual(gp.grade_p5(self.rows(subagent_stop=False), 'a1', 1.0)[0], 'FAIL')
        self.assertEqual(gp.grade_p5(self.rows(turn=False), 'a1', 1.0)[0], 'FAIL')
        self.assertEqual(gp.grade_p5(self.rows(), 'someone-else', 1.0)[0], 'FAIL')

    def test_an_agent_that_ended_while_the_harness_was_still_sending_proves_nothing(self):
        self.assertEqual(gp.grade_p5(self.rows(notify_at=0.5), 'a1', 1.0)[0], 'PREMISE-FALSE')


class RegistryStep(unittest.TestCase):
    """P12′ (r4 §2.1, §5): the registry read the way P12 measured it, from agent-liveness.sh's
    JSON on the worktree (`evidence.registry_finished`, `registry_why`)."""
    def live(self, verdict, finished, why):
        return (verdict, {'evidence': {'registry_finished': finished, 'registry_why': why}})

    def result(self, before_a, after_a, after_b, step_exit=0):
        return {'registry_before_step': {'a': gp.registry_of(before_a)}, 'registry_step': {'exit': step_exit},
                'registry_after_step': {'a': gp.registry_of(after_a), 'b': gp.registry_of(after_b)}}

    def test_the_step_passes_only_with_its_control_and_both_agents_right(self):
        open_ = self.live('NOT-ALIVE', False, 'its run has not ended')
        stopped = self.live('NOT-ALIVE', True, 'it was stopped (operator probe P12: stop probe-sonnet-p12a)')
        b_alive = self.live('ALIVE', False, 'its run has not ended')
        self.assertEqual(gp.grade_registry_step(self.result(open_, stopped, b_alive))[0], 'PASS')
        self.assertEqual(gp.grade_registry_step(self.result(stopped, stopped, b_alive))[0], 'PREMISE-FALSE')
        self.assertEqual(gp.grade_registry_step(self.result(open_, open_, b_alive))[0], 'FAIL')
        self.assertEqual(gp.grade_registry_step(self.result(open_, stopped, self.live('NOT-ALIVE', False, 'x')))[0], 'FAIL')
        self.assertEqual(gp.grade_registry_step(self.result(open_, stopped, b_alive, step_exit=1))[0], 'FAIL')

    def test_a_liveness_answer_without_a_registry_reading_is_never_an_open_run(self):
        self.assertEqual(gp.registry_of(('NOT-ALIVE', {})), ['NOT-ALIVE', None, None])
        self.assertEqual(gp.grade_registry_step(self.result(('NOT-ALIVE', {}), ('NOT-ALIVE', {}), ('ALIVE', {})))[0],
                         'PREMISE-FALSE')


class ArtifactActions(unittest.TestCase):
    def test_the_binary_s_list_with_scope_types_is_r4_s_list_types(self):
        self.assertEqual(gp.artifact_action({'action': 'list', 'scope': 'types'}), 'list_types')
        self.assertEqual(gp.artifact_action({'action': 'list_types'}), 'list_types')
        self.assertEqual(gp.artifact_action({'action': 'list'}), 'list')
        self.assertEqual(gp.artifact_action({'action': 'publish'}), 'publish')


class GradeP16(unittest.TestCase):
    def result(self, said='=== Teammate-spawn guard: BLOCKED (name reuse) ===', fresh=True,
               how='exact session id match (session-12345678)', token=True, b_alive='ALIVE'):
        return {'reuse_a': {'said': said}, 'control_fresh_name': {'agent_call': fresh}, 'resolve_teams_dir': how,
                'token_in_b_transcript': token, 'b_alive_at_send': b_alive,
                'team_dir_before_first_spawn': {}, 'team_dir_after_first_spawn': {}}

    def test_all_three_required_lines(self):
        self.assertEqual(gp.grade_p16(self.result())[0], 'PASS')
        self.assertEqual(gp.grade_p16(self.result(said='spawn: ready'))[0], 'FAIL')
        self.assertEqual(gp.grade_p16(self.result(how='the only session team directory under /x'))[0], 'FAIL')
        self.assertEqual(gp.grade_p16(self.result(token=False))[0], 'FAIL')
        self.assertEqual(gp.grade_p16(self.result(fresh=False))[0], 'PREMISE-FALSE')
        self.assertEqual(gp.grade_p16(self.result(b_alive='NOT-ALIVE'))[0], 'PREMISE-FALSE')


class Retired(unittest.TestCase):
    def test_p6_is_retired_with_its_reason_and_p5_p12_p16_p17_are_registered(self):
        self.assertIn('P6', gp.RETIRED)
        self.assertIn('r4', gp.RETIRED['P6'])
        ids = [pid for pid, _ in gp.PROBES]
        for pid in ('P5', 'P12', 'P15', 'P16', 'P17'):
            self.assertIn(pid, ids)


class ArtifactScrub(unittest.TestCase):
    def test_his_artifact_list_never_reaches_the_record(self):
        scrub = gp.scrub_artifact_results(lambda: {'t-1'})
        frame = {'type': 'user', 'message': {'content': [
            {'type': 'tool_result', 'tool_use_id': 't-1', 'content': 'My private artifact title', 'is_error': False},
            {'type': 'tool_result', 'tool_use_id': 't-2', 'content': 'kept'}]}}
        out = json.dumps(scrub(frame))
        self.assertNotIn('private artifact title', out)
        self.assertIn('kept', out)
        self.assertIn('private artifact title', json.dumps(frame), 'the live frame is not changed, only the saved copy')


class Arguments(unittest.TestCase):
    def test_the_lead_arguments_mirror_the_operator_profile(self):
        """operator_profile::child_args, flag for flag. If the profile changes, this list must."""
        ctx = gp.Context.__new__(gp.Context)
        ctx.p = gp.Paths('/fixture/payload')
        ctx.python = '/opt/homebrew/bin/python3'
        a = ctx.lead_args(session_id='s-1')
        for flag in ['--print', '--input-format=stream-json', '--output-format=stream-json', '--include-partial-messages',
                     '--verbose', '--include-hook-events', '--replay-user-messages', '--dangerously-skip-permissions']:
            self.assertIn(flag, a)
        self.assertEqual(a[a.index('--setting-sources') + 1], 'user,project,local')
        self.assertEqual(a[a.index('--permission-prompt-tool') + 1], 'stdio')
        self.assertEqual(a[a.index('--disallowed-tools') + 1], 'AskUserQuestion')
        self.assertNotIn('--no-session-persistence', a)
        self.assertNotIn('--plugin-dir', a)
        self.assertEqual(a[-2], '--mcp-config')
        rust = (HERE.parents[2] / 'crates' / 'richos-core' / 'src' / 'operator_profile.rs').read_text()
        for flag in ['"--include-hook-events"', '"user,project,local"', '"--disallowed-tools"', '"--mcp-config"',
                     '"--dangerously-skip-permissions"', '"--replay-user-messages"', '"CLAUDE_CODE_ARTIFACT"']:
            self.assertIn(flag, rust, 'the profile no longer carries %s: update the harness with it' % flag)


if __name__ == '__main__':
    unittest.main(verbosity=2)
