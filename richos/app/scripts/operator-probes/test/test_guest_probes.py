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
    """P12′ (r4 §2.1, §5): the registry read from agent-liveness.sh's JSON on the worktree, the
    step taken when the host takes it."""
    OPEN = ['NOT-ALIVE', False, 'its run has not ended']
    STOPPED = ['NOT-ALIVE', True, 'it was stopped (operator probe P12: stop probe-sonnet-p12a)']
    OTHER = ['ALIVE', False, 'its run has not ended']

    def step(self, before=None, after=None, other=None, said=True, code=0):
        return {'stream_said_stopped': said, 'before': before or self.OPEN, 'run': {'exit': code},
                'after': after or self.STOPPED, 'other_after': other or self.OTHER}

    def test_the_step_passes_only_with_its_control_and_both_agents_right(self):
        self.assertEqual(gp.grade_registry_step(self.step())[0], 'PASS')
        # Run 2026-09-25 11:26: a minute later the lead's engine had closed the clean agent itself.
        landed = ['NOT-ALIVE', True, 'its work was landed']
        self.assertEqual(gp.grade_registry_step(self.step(before=landed))[0], 'PREMISE-FALSE')
        self.assertEqual(gp.grade_registry_step(self.step(said=False))[0], 'PREMISE-FALSE')
        self.assertEqual(gp.grade_registry_step(self.step(after=self.OPEN))[0], 'FAIL')
        self.assertEqual(gp.grade_registry_step(self.step(other=['NOT-ALIVE', False, 'x']))[0], 'FAIL')
        self.assertEqual(gp.grade_registry_step(self.step(code=1))[0], 'FAIL')

    def test_a_liveness_answer_without_a_registry_reading_is_never_an_open_run(self):
        self.assertEqual(gp.registry_of(('NOT-ALIVE', {})), ['NOT-ALIVE', None, None])
        self.assertEqual(gp.grade_registry_step(self.step(before=['NOT-ALIVE', None, None]))[0], 'PREMISE-FALSE')


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


class Walk(unittest.TestCase):
    def test_the_walk_runs_only_when_named_and_says_not_run_without_its_binary(self):
        self.assertIn('W2', gp.EXPLICIT, 'a default probe run must never start the walk')
        ctx = gp.Context.__new__(gp.Context)
        ctx.walk_binary = ''
        self.assertEqual(gp.w2(ctx, {})[0], 'NOT-RUN')

    def test_a_heartbeat_is_a_shell_loop_writing_one_file(self):
        self.assertIn('/tmp/hb.txt', gp.heartbeat_command('/tmp/hb.txt'))


class GradeP15Reap(unittest.TestCase):
    def run_of(self, **alive):
        return {'alive_after_grace_plus_one': dict(alive)}

    def test_a_run_whose_shells_recorded_nothing_is_never_a_pass(self):
        full = self.run_of(lead=False, **{'fg-self': False, 'fg-grandchild': False, 'bg-self': False, 'bg-grandchild': False})
        self.assertEqual(gp.grade_p15_reap({'reap': full, 'reap-lead-crash': full})[0], 'PASS')
        # The 2026-09-25 run's lead-crash half: only the lead was recorded.
        self.assertEqual(gp.grade_p15_reap({'reap': full, 'reap-lead-crash': self.run_of(lead=False)})[0], 'PREMISE-FALSE')
        survivor = dict(full['alive_after_grace_plus_one'], **{'bg-grandchild': True})
        self.assertEqual(gp.grade_p15_reap({'reap': full, 'reap-lead-crash': {'alive_after_grace_plus_one': survivor}})[0],
                         'FAIL')

    def test_the_harness_found_names_grade_the_same_way(self):
        found = self.run_of(lead=False, **{'fg-shell-40': False, 'fg-task-41': False, 'bg-shell-50': False,
                                           'bg-task-51': False})
        self.assertEqual(gp.grade_p15_reap({'reap': found, 'reap-lead-crash': found})[0], 'PASS')
        only_bg = self.run_of(lead=False, **{'bg-shell-50': False, 'bg-task-51': False})
        self.assertEqual(gp.grade_p15_reap({'reap': found, 'reap-lead-crash': only_bg})[0], 'PREMISE-FALSE')


class GradeP15Premise(unittest.TestCase):
    """The premise is per trigger: the 2026-09-25 run's owner control found no processes while
    its lead-crash control showed four survivors, and "no survivor" was read off the first."""

    def run_of(self, **alive):
        return {'alive_after_grace_plus_one': dict(alive), 'own_group': {'fg': True, 'bg': True}}

    def survived(self):
        return self.run_of(lead=False, **{'fg-task-1': True, 'bg-task-2': True})

    def gone(self):
        return self.run_of(lead=False, **{'fg-task-3': False, 'bg-task-4': False})

    def test_each_trigger_needs_its_own_control_to_show_a_survivor(self):
        r = {'control-no-reap': self.run_of(lead=False), 'control-no-reap-lead-crash': self.survived(),
             'reap': self.gone(), 'reap-lead-crash': self.gone()}
        verdict, why = gp.grade_p15(r, True)
        self.assertEqual(verdict, 'PREMISE-FALSE')
        self.assertIn('owner', why)
        self.assertNotIn("'lead'", why)

    def test_a_control_where_nothing_survived_shows_nothing(self):
        r = {'control-no-reap': self.gone(), 'control-no-reap-lead-crash': self.survived()}
        self.assertEqual(gp.grade_p15(r, True)[0], 'PREMISE-FALSE')

    def test_both_premises_shown_then_the_reap_is_graded(self):
        r = {'control-no-reap': self.survived(), 'control-no-reap-lead-crash': self.survived(),
             'reap': self.gone(), 'reap-lead-crash': self.gone()}
        self.assertEqual(gp.grade_p15(r, True)[0], 'PASS')
        self.assertEqual(gp.grade_p15(r, False)[0], 'NOT-RUN')
        r['reap-lead-crash'] = self.survived()
        self.assertEqual(gp.grade_p15(r, True)[0], 'FAIL')


class P15Processes(unittest.TestCase):
    ROWS = [
        {'pid': 10, 'ppid': 1, 'pgid': 10, 'command': 'python3 provider-supervisor.py claude'},
        {'pid': 11, 'ppid': 10, 'pgid': 10, 'command': 'claude --print'},
        {'pid': 20, 'ppid': 11, 'pgid': 20, 'command': "/bin/zsh -c eval 'python3 /w/long-task.py 600' < /dev/null"},
        {'pid': 21, 'ppid': 20, 'pgid': 20, 'command': '/opt/homebrew/bin/python3 /w/long-task.py 600'},
        {'pid': 30, 'ppid': 11, 'pgid': 30, 'command': "/bin/zsh -c eval 'python3 /w/long-task.py 500' < /dev/null"},
        {'pid': 31, 'ppid': 30, 'pgid': 30, 'command': '/opt/homebrew/bin/python3 /w/long-task.py 500'},
        {'pid': 40, 'ppid': 1, 'pgid': 40, 'command': '/opt/homebrew/bin/python3 /w/long-task.py 600'},
    ]

    def test_the_tasks_are_found_under_the_lead_only(self):
        under = gp.below(self.ROWS, 11)
        self.assertEqual(sorted(r['pid'] for r in under), [20, 21, 30, 31])
        tasks = [r['pid'] for r in gp.long_tasks(under) if r['command'].rstrip().endswith(' 600')]
        self.assertEqual(tasks, [21], 'the shell carries the same words, and pid 40 is not the lead\'s')

    def test_a_tool_group_is_the_shell_and_the_task(self):
        group = gp.tool_group(self.ROWS, 31)
        self.assertEqual(sorted((m['pid'], m['role']) for m in group), [(30, 'shell'), (31, 'task')])
        self.assertEqual(gp.tool_group(self.ROWS, 99), [])


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
