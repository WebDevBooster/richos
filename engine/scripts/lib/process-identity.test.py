"""Real-process and cross-process regressions for terminal/daemon ownership."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ENGINE = Path(os.environ.get('RICHOS_IDENTITY_TEST_ROOT', Path(__file__).resolve().parents[2]))
LEDGER = ENGINE / 'scripts/lib/worktree-ledger.py'
ADOPTION = ENGINE / 'scripts/lib/worktree-adoption.py'

# THE CI SHAPE, PINNED (Sage D2, round three, 2026-09-10). This suite pinned
# RICHOS_ADOPTION_PROCESSES and not the session-process table, so its verdict
# was a fact about the machine: green wherever a `claude` process happened to
# be running (the operator's laptop), 21 failures on a CI runner where none
# is, and the same 21 on the operator's machine at 04:00 after his session
# closed. A test that decides differently on different machines decides
# nothing. So the table is an EMPTY one and the harness's live-session
# registry is an EMPTY directory, unconditionally — the shape in which every
# invariant below must hold, because it is the shape in which the retired T4
# tier used to authorize what they forbid.
import atexit
import shutil
_NO_SESSIONS = tempfile.mkdtemp(prefix='identity-no-sessions-')
atexit.register(shutil.rmtree, _NO_SESSIONS, True)
os.environ['RICHOS_SESSION_PROCESSES'] = 'none'
os.environ['RICHOS_SESSIONS_DIR'] = _NO_SESSIONS


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


wl = load('identity_ledger', LEDGER)
ad = load('identity_adoption', ADOPTION)


class ProcessIdentity(unittest.TestCase):
    def run_command(self, argv, env=None):
        result = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def token(self, tz, locale):
        return self.run_command([sys.executable, str(LEDGER), 'pid-start', str(os.getpid())],
                                {**os.environ, 'TZ': tz, 'LC_ALL': locale, 'LANG': locale})

    def test_terminal_and_daemon_observe_same_live_process(self):
        tokens = [self.token(tz, loc) for tz, loc in (
            ('Europe/London', 'en_GB.UTF-8'), ('UTC', 'C'),
            ('America/New_York', 'C'), ('Asia/Kathmandu', 'C'))]
        self.assertEqual(len(set(tokens)), 1, tokens)
        self.assertEqual(wl.process_status(os.getpid(), tokens[0]), 'alive')

    def test_legacy_strings_cannot_prove_pid_reuse(self):
        for legacy in ('Sun 6 Sep 21:49:58 2026', 'Sun Sep 6 20:49:58 2026', 'unreadable'):
            with self.subTest(legacy=legacy):
                self.assertEqual(wl.process_status(os.getpid(), legacy), 'unknown')

    def test_canonical_reuse_and_death_still_distinguishable(self):
        start = self.token('UTC', 'C')
        old = 'ps-lstart-utc-v1:Mon Jan 1 00:00:00 1990'
        newer = 'ps-lstart-utc-v1:Tue Jan 2 00:00:00 1990'
        with patch.object(wl, 'pid_start', return_value=newer):
            self.assertEqual(wl.process_status(os.getpid(), old), 'reused')
        with patch.object(wl, '_pid_running', return_value=False):
            self.assertEqual(wl.process_status(123, start), 'gone')
        with patch.object(wl, 'pid_start', return_value=''):
            self.assertEqual(wl.process_status(os.getpid(), start), 'unknown')

    def test_malformed_identity_cannot_prove_reuse(self):
        prefix = 'ps-lstart-utc-v1:'
        bad = (prefix, prefix + 'Mon Jan 1 00:00:00 199',
               prefix + 'Mon Jan 1 00:00:00 1990-different',
               prefix + 'Tue Jan 1 00:00:00 1990',
               prefix + 'Mon Feb 31 00:00:00 1990',
               prefix + 'Mon Jan 1 25:00:00 1990',
               42, ['invalid'], {'invalid': True})
        for token in bad:
            with self.subTest(token=token):
                self.assertEqual(wl.process_status(os.getpid(), token), 'unknown')
        with patch.object(wl, 'pid_start', return_value=prefix + 'broken'):
            self.assertEqual(wl.process_status(os.getpid(),
                             prefix + 'Mon Jan 1 00:00:00 1990'), 'unknown')
        with patch.object(wl.subprocess, 'run', return_value=
                          subprocess.CompletedProcess([], 0, stdout='broken ps output')):
            self.assertEqual(wl.pid_start(os.getpid()), '')
        # Malformed JSON field types must reach the conservative verdict, not
        # crash the owner's deduplication before process_status can judge them.
        with tempfile.TemporaryDirectory() as temp:
            for token in bad:
                rows = [{'worktree': temp, 'session_id': 'old', 'session_pid': 99999999},
                        {'worktree': temp, 'session_id': 'current',
                         'session_pid': os.getpid(), 'pid_start': token}]
                with self.subTest(owner_token=token):
                    tier, reason = ad.owner_evidence(rows, temp)
                    self.assertIsNone(tier, reason)
                    self.assertIn('UNKNOWN', reason)

    def test_unknown_owner_vetoes_an_older_dead_owner(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {
            'RICHOS_WORKTREE_TX_DIR': str(Path(temp) / 'tx'),
            'RICHOS_WORKTREE_LEDGER': str(Path(temp) / 'ledger')}):
            records = [
                {'worktree': temp, 'session_id': 'old', 'session_pid': 99999999, 'pid_start': ''},
                {'worktree': temp, 'session_id': 'current', 'session_pid': os.getpid(),
                 'pid_start': 'Sun 6 Sep 21:49:58 2026'}]
            tier, reason = ad.owner_evidence(records, temp)
            self.assertIsNone(tier, reason)
            self.assertIn('UNKNOWN', reason)

    def test_resumed_session_cannot_be_collapsed_onto_its_old_dead_pid(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {
            'RICHOS_WORKTREE_TX_DIR': str(Path(temp) / 'tx'),
            'RICHOS_WORKTREE_LEDGER': str(Path(temp) / 'ledger')}):
            old = {'worktree': temp, 'session_id': 'resumed',
                   'session_pid': 99999999, 'pid_start': ''}
            current = {'worktree': temp, 'session_id': 'resumed',
                       'session_pid': os.getpid(), 'pid_start': self.token('UTC', 'C')}
            for records in ([old, current], [current, old]):
                tier, reason = ad.owner_evidence(records, temp)
                self.assertIsNone(tier, reason)
                self.assertIn('STILL RUNNING', reason)

    def test_pidless_path_considers_every_resumed_session_incarnation(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {
            'RICHOS_WORKTREE_TX_DIR': str(Path(temp) / 'tx'),
            'RICHOS_WORKTREE_LEDGER': str(Path(temp) / 'ledger')}):
            old = {'worktree': temp + '/old', 'session_id': 'resumed',
                   'session_pid': 99999999, 'pid_start': ''}
            current = {'worktree': temp + '/current', 'session_id': 'resumed',
                       'session_pid': os.getpid(), 'pid_start': self.token('UTC', 'C')}
            target = {'worktree': temp + '/target', 'session_id': 'resumed'}
            for current_start in (current['pid_start'], 'legacy-local-time'):
                current['pid_start'] = current_start
                for records in ([old, current, target], [current, old, target]):
                    with self.subTest(start=current_start, records=records):
                        tier, reason = ad.owner_evidence(records, target['worktree'])
                        self.assertIsNone(tier, reason)
                        self.assertIn('UNKNOWN' if current_start == 'legacy-local-time'
                                      else 'STILL RUNNING', reason)

    def test_direct_old_pid_cannot_hide_a_resumed_session_elsewhere(self):
        with tempfile.TemporaryDirectory() as temp:
            old = {'worktree': temp + '/target', 'session_id': 'resumed',
                   'session_pid': 99999999}
            current = {'worktree': temp + '/another', 'session_id': 'resumed',
                       'session_pid': os.getpid()}
            for token in (self.token('UTC', 'C'), 'legacy-local-time'):
                current['pid_start'] = token
                for records in ([old, current], [current, old]):
                    tier, reason = ad.owner_evidence(records, old['worktree'])
                    self.assertIsNone(tier, reason)
                    self.assertIn('UNKNOWN' if token == 'legacy-local-time'
                                  else 'STILL RUNNING', reason)

    def test_missing_named_owner_cannot_borrow_an_old_owner_termination(self):
        with tempfile.TemporaryDirectory() as temp:
            old = {'worktree': temp, 'session_id': 'old', 'session_pid': 99999999,
                   'agent_id': 'a1111111111111111'}
            current = {'event': 'prepared', 'worktree': temp, 'session_id': 'current',
                       'agent_id': 'a2222222222222222'}
            for terminal_agent in ('', old['agent_id'], current['agent_id']):
                for records in ([old, current], [current, old]):
                    with self.subTest(terminal_agent=terminal_agent, first=records[0]['session_id']), \
                            patch.object(ad.tx, 'is_terminal_agent',
                                         side_effect=lambda aid: aid == terminal_agent):
                        tier, reason = ad.owner_evidence(records, temp)
                        if terminal_agent == current['agent_id']:
                            self.assertEqual(tier, 'T1', reason)
                        else:
                            self.assertIsNone(tier, reason)
                            self.assertIn('UNKNOWN', reason)
            current.pop('agent_id')
            with patch.object(ad.tx, 'is_terminal_agent', return_value=True):
                tier, reason = ad.owner_evidence([old, current], temp)
                self.assertIsNone(tier, reason)
                self.assertIn('UNKNOWN', reason)

    def test_missing_session_id_does_not_hide_live_or_unknown_ownership(self):
        with tempfile.TemporaryDirectory() as temp:
            old = {'worktree': temp, 'session_id': 'old', 'session_pid': 99999999,
                   'agent_id': 'a1111111111111111'}
            current = {'event': 'registered', 'worktree': temp,
                       'agent_id': 'a2222222222222222'}
            for pid in (None, os.getpid()):
                current['session_pid'] = pid
                current['pid_start'] = self.token('UTC', 'C') if pid else ''
                for terminal_agent in (old['agent_id'], current['agent_id']):
                    for records in ([old, current], [current, old]):
                        with self.subTest(pid=pid, terminal_agent=terminal_agent,
                                          first=records[0].get('session_id')), \
                                patch.object(ad.tx, 'is_terminal_agent',
                                             side_effect=lambda aid: aid == terminal_agent):
                            tier, reason = ad.owner_evidence(records, temp)
                            if pid is None and terminal_agent == current['agent_id']:
                                self.assertEqual(tier, 'T1', reason)
                            else:
                                self.assertIsNone(tier, reason)
                                self.assertIn('STILL RUNNING' if pid else 'UNKNOWN', reason)

    def test_ambiguous_record_cannot_fall_through_to_process_name_scan(self):
        reg = {'session_pid': os.getpid(), 'pid_start': 'legacy-local-time',
               'session_id': 'current', 'last_write': 1, 'teammate': 'worker'}
        with patch.object(wl, 'session_gone_by_exhaustion', return_value=('gone', 'incomplete table')) as scan:
            verdict, reason = wl._judge_registration(reg, '', [reg], None, False, '')
            self.assertEqual(verdict, wl.INDETERMINATE, reason)
            scan.assert_not_called()

    def test_prepared_worktree_survives_repeated_reconciler_processes(self):
        # This runs the real scheduled entry point, with every mutable store
        # isolated. A false T2 decision can only quarantine this throwaway tree.
        with tempfile.TemporaryDirectory(prefix='identity-lifecycle-') as temp:
            root = Path(temp).resolve()
            repo, worktree = root / 'repo', root / 'worker'
            repo.mkdir()
            self.run_command(['git', '-C', str(repo), 'init', '-q', '-b', 'main'])
            (repo / 'seed.txt').write_text('seed\n')
            self.run_command(['git', '-C', str(repo), 'add', 'seed.txt'])
            self.run_command(['git', '-C', str(repo), 'commit', '-qm', 'fixture'])
            self.run_command(['git', '-C', str(repo), 'worktree', 'add', '-qb', 'worker', str(worktree)])
            ledger = root / 'ledger.jsonl'
            env = {**os.environ, 'RICHOS_WORKTREE_LEDGER': str(ledger),
                   'RICHOS_WORKTREE_TX_DIR': str(root / 'tx'),
                   'RICHOS_WORKTREE_CAPTURE_DIR': str(root / 'captures'),
                   'RICHOS_ADOPTION_PROCESSES': 'none', 'TZ': 'UTC', 'LC_ALL': 'C'}
            record = {'event': 'prepared', 'session_id': 'current', 'session_pid': os.getpid(),
                      'pid_start': self.token('Europe/London', 'en_GB.UTF-8'),
                      'repo': str(repo), 'worktree': str(worktree), 'branch': 'worker',
                      'class': 'hand-rolled', 'teammate': 'worker'}
            for identity in (record['pid_start'], 'Sun 6 Sep 21:49:58 2026'):
                record['pid_start'] = identity
                ledger.write_text(json.dumps(record) + '\n')
                for attempt in range(2):
                    self.run_command([sys.executable, str(ENGINE / 'scripts/reconcile-terminal-worktrees.py'),
                                      '--quiet', '--max-seconds', '20'], env)
                    self.assertTrue((worktree / 'seed.txt').exists(), f'{identity}, pass {attempt}: live tree moved')
                    self.assertFalse(list(root.glob('worker.richos-terminal-*')))
                    status = json.loads((root / 'tx/last-run.json').read_text())
                    self.assertTrue(status['adoption']['ran'])
                    self.assertEqual(status['adoption']['candidates'], 1)
                    self.assertEqual(status['adoption']['adopted'], 0)
            # Prove the retained checkout remains usable for work and landing.
            (worktree / 'output.txt').write_text('worker result\n')
            self.run_command(['git', '-C', str(worktree), 'add', 'output.txt'])
            self.run_command(['git', '-C', str(worktree), 'commit', '-qm', 'result'])
            self.run_command(['git', '-C', str(repo), 'merge', '--no-ff', '--no-edit', 'worker'])
            self.assertEqual((repo / 'output.txt').read_text(), 'worker result\n')
            self.assertEqual(self.run_command(['git', '-C', str(repo), 'status', '--porcelain']), '')


if __name__ == '__main__':
    unittest.main()
