#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent

def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / 'lib' / (name + '.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module

daily = load('daily-workspace-cleanup')
tx = load('worktree-transactions')


def _load_registry(repo, path):
    """The exact `git worktree list` row for one path, as the lane reads it."""
    return load('completion-proof').registry(str(repo)).get(str(path)) or {}

SID = 'daily-test-session'
AID = 'abcdef123456'
DEAD_PID = 999999

class Cleanup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='richos-daily-', dir='/private/tmp' if os.path.isdir('/private/tmp') else None)
        self.root = Path(self.tmp.name).resolve(); self.repo = self.root / 'repo'; self.work = self.root / 'worker'
        # BOTH stores away from their defaults (the lane refuses to archive residue otherwise),
        # and an empty process table so a hold never depends on what this machine runs.
        self.env = patch.dict(os.environ, {'RICHOS_WORKTREE_TX_DIR': str(self.root/'tx'),
            'RICHOS_WORKTREE_CAPTURE_DIR': str(self.root/'captures'),
            'RICHOS_WORKTREE_LEDGER': str(self.root/'ledger.jsonl'), 'CLAUDE_CONFIG_DIR':str(self.root/'profile'),
            'RICHOS_DAILY_PROCESSES': 'none',
            'GIT_CONFIG_GLOBAL':'/dev/null', 'GIT_CONFIG_SYSTEM':'/dev/null'})
        self.env.start(); self.repo.mkdir()
        self.git(self.repo,'init','-b','main'); self.git(self.repo,'config','user.name','Fixture'); self.git(self.repo,'config','user.email','fixture@example.invalid')
        (self.repo/'file').write_text('base\n'); self.git(self.repo,'add','file'); self.git(self.repo,'commit','-m','base')
        self.git(self.repo,'worktree','add','-b','worker',str(self.work))
        (self.work/'file').write_text('delivered\n'); self.git(self.work,'commit','-am','delivery')
        self.git(self.repo,'merge','--ff-only','worker')
        self.main = self.git(self.repo,'rev-parse','main').strip()
        self.record={'record':'transaction','session_id':SID,'agent_id':AID,'teammate':'worker',
            'sealed':True,'terminal':{'ingress':'SubagentStop','ts':'fixture'},'start_cwd':str(self.repo),
            'state':'sealed','members':[{'class':'hand-rolled','repo':str(self.repo),'path':str(self.work),
                'branch':'worker','state':'bound','cleanup_policy':'integrated-daily'}]}
        tx.atomic_write_json(tx.tx_path(SID,AID), self.record)

    def tearDown(self):
        self.env.stop(); self.tmp.cleanup()

    def git(self, repo,*args):
        r=subprocess.run(['git','-C',str(repo),*args],capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr); return r.stdout

    def run_cleanup(self):
        with tx.tx_lock(SID,AID):
            return daily.reconcile(tx,tx.load_tx(SID,AID),0)

    def assess(self):
        return daily.assess(tx,tx.load_tx(SID,AID),0)

    def ledger_row(self, **fields):
        row=dict(event='registered',session_id=SID,teammate='worker',repo=str(self.repo),worktree=str(self.work),
                 branch='worker',agent_id=AID,ts='2026-01-01T00:00:00+00:00'); row.update(fields)
        with open(self.root/'ledger.jsonl','a') as stream: stream.write(json.dumps(row)+'\n')

    def make_native(self, lock_pid=None):
        self.record['members'][0].update({'class':'native','cleanup_owner':'claude-code'})
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        if lock_pid is not None:
            self.git(self.repo,'worktree','lock','--reason','claude agent agent-'+AID+' (pid %d start fixture)'%lock_pid,str(self.work))

    def assert_kept(self):
        self.assertTrue(self.work.is_dir());self.assertEqual(self.git(self.repo,'rev-parse','worker').strip(),self.git(self.work,'rev-parse','HEAD').strip())
        self.assertEqual(self.git(self.repo,'rev-parse','main').strip(),self.main)

    def assert_reclaimed(self, result):
        self.assertEqual(result['members'][0]['daily_cleanup']['phase'],'complete')
        self.assertFalse(self.work.exists());self.assertNotIn('refs/heads/worker',self.git(self.repo,'show-ref'))
        self.assertEqual(self.git(self.repo,'rev-parse','main').strip(),self.main)
        self.assertEqual(self.git(self.repo,'status','--porcelain'),'')

    def test_integrated_without_task_receipt_reclaims_worktree_and_branch(self):
        self.assertEqual(self.assess()[0],'remove')
        self.assert_reclaimed(self.run_cleanup())

    def test_a_process_probe_that_cannot_look_HOLDS_and_never_reports_an_empty_tree(self):
        # FRANK'S D3 / SAGE, 2026-09-10. processes_using() swallowed every
        # lsof and ps exception and returned an empty list, so a TIMEOUT, a
        # missing binary or a permission error arrived at the caller wearing
        # the costume of "nothing is holding this workspace" — absence reading
        # as success (type A), inside the one predicate whose entire job is to
        # refuse. Seven workspaces on the operator's machine were held by a
        # single com.apple.Virtualization.VirtualMachine process that only
        # lsof can see; on the day lsof was slow they would have been deleted.
        #
        # This is the positive probe FIRST (the negative test must be able to
        # fail for the right reason): with a working probe the same workspace
        # reclaims. Then the probe cannot answer, and everything refuses.
        self.assertEqual(self.assess()[0],'remove')
        with patch.dict(os.environ,{'RICHOS_DAILY_PROCESSES':'unavailable'}):
            with self.assertRaisesRegex(RuntimeError,'could not determine whether any process'):
                daily.processes_using(str(self.work))
            decision,reason=self.assess()
            self.assertEqual(decision,'hold')
            self.assertIn('could not determine whether any process',reason)
            self.assertIn('RETRY, not a verdict',reason)
            with self.assertRaisesRegex(Exception,'could not determine whether any process'):
                self.run_cleanup()
        self.assert_kept()
        # and the hold clears by itself the moment the probe answers again
        self.assert_reclaimed(self.run_cleanup())

    def test_dirty_staged_and_untracked_refuse(self):
        for kind in ('dirty','staged','untracked'):
            with self.subTest(kind=kind):
                if kind in ('dirty','staged'):
                    (self.work/'file').write_text('unfinished\n')
                    if kind=='staged':self.git(self.work,'add','file')
                else:
                    (self.work/'extra').write_text('unfinished\n')
                self.assertEqual(self.assess()[0],'hold')
                with self.assertRaises(Exception):self.run_cleanup()
                self.assert_kept();self.git(self.work,'reset','--hard','HEAD')
                if (self.work/'extra').exists():(self.work/'extra').unlink()

    def test_ignored_disposable_is_dropped_and_ignored_residue_is_archived_verified_then_reclaimed(self):
        # Round 10 P1: the predicate that held 20 of 29 members. A __pycache__ is
        # disposable by the committed policy and goes with the tree; an ignored
        # file the policy does not name is archived, the archive re-read and
        # verified, and only then is the tree removed. Nothing ignored vanishes
        # without a copy; nothing disposable is kept on behalf of nobody.
        (self.repo/'.git/info/exclude').write_text('extra\n__pycache__/\n')
        cache=self.work/'__pycache__';cache.mkdir();(cache/'x.pyc').write_bytes(b'\x00\x01')
        (self.work/'extra').write_bytes(b'ignored but not disposable\n')
        decision,reason=self.assess();self.assertEqual(decision,'remove');self.assertIn('1 archived first',reason)
        result=self.run_cleanup();self.assert_reclaimed(result)
        journal=result['members'][0]['daily_cleanup']
        self.assertEqual(journal['ignored_disposable'],1)
        residue=journal['ignored_residue'];self.assertEqual(residue['files'],1)
        with tarfile.open(residue['archive']) as tar:
            self.assertEqual(tar.getnames(),['extra'])
            self.assertEqual(tar.extractfile('extra').read(),b'ignored but not disposable\n')
        self.assertTrue(str(residue['archive']).startswith(str(self.root/'captures')))
        self.assertFalse(list((self.root/'captures').rglob('x.pyc')))

    def test_ignored_only_disposable_records_no_archive(self):
        (self.repo/'.git/info/exclude').write_text('__pycache__/\n')
        cache=self.work/'__pycache__';cache.mkdir();(cache/'x.pyc').write_bytes(b'\x00')
        result=self.run_cleanup();self.assert_reclaimed(result)
        self.assertIsNone(result['members'][0]['daily_cleanup']['ignored_residue'])
        self.assertFalse((self.root/'captures').exists())

    def test_unverifiable_residue_archive_holds_the_tree(self):
        (self.repo/'.git/info/exclude').write_text('extra\n')
        (self.work/'extra').write_text('evidence\n')
        with patch.object(daily,'verify_residue_archive',side_effect=RuntimeError('fixture: archive does not verify')):
            with self.assertRaisesRegex(RuntimeError,'does not verify'):self.run_cleanup()
        self.assert_kept();self.assertEqual((self.work/'extra').read_text(),'evidence\n')

    def test_residue_refuses_when_capture_store_is_at_default_while_transactions_are_redirected(self):
        (self.repo/'.git/info/exclude').write_text('extra\n')
        (self.work/'extra').write_text('evidence\n')
        with patch.dict(os.environ,{'RICHOS_WORKTREE_CAPTURE_DIR':''}):
            with self.assertRaisesRegex(RuntimeError,'inconsistently rooted'):self.run_cleanup()
        self.assert_kept()

    def test_process_standing_in_the_tree_holds_it_and_nothing_is_killed(self):
        with patch.dict(os.environ,{'RICHOS_DAILY_PROCESSES':'4242 /bin/sleep 300 '+str(self.work)}):
            self.assertEqual(self.assess()[0],'hold')
            with self.assertRaisesRegex(RuntimeError,r'RETRY, not a verdict: process\(es\) 4242'):self.run_cleanup()
        self.assert_kept()

    def test_unintegrated_refuses(self):
        (self.work/'file').write_text('later\n');self.git(self.work,'commit','-am','later')
        self.assertEqual(self.assess()[0],'hold')
        with self.assertRaises(Exception):self.run_cleanup()
        self.assert_kept()

    def test_taskstop_ingress_is_a_terminal_fact(self):
        # P2: terminalize-agent-worktrees.sh claims on PostToolUse[TaskStop];
        # the lane refused it as 'not terminal' and held two members that way.
        self.record['terminal']={'ingress':'TaskStop','detail':'requested=worker','ts':'fixture'}
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        self.assert_reclaimed(self.run_cleanup())

    def test_adoption_ingress_owns_its_exact_prepared_path(self):
        # P2/P4: an adopted transaction (kind adopted, ingress Adoption) owns
        # the one path adoption claimed, so the dead session's preparation of
        # that path is its own; a preparation of ANY OTHER path by a session
        # with no terminal record still reserves.
        self.record.update(session_id='adopted',agent_id='adopted-0123456789abcdef',teammate='',kind='adopted',
                           terminal={'ingress':'Adoption','detail':'adopted on T2 evidence','ts':'fixture'})
        tx.atomic_write_json(tx.tx_path('adopted','adopted-0123456789abcdef'),self.record)
        self.ledger_row(event='prepared',session_id='dead-session',agent_id='',session_pid=DEAD_PID)
        with tx.tx_lock('adopted','adopted-0123456789abcdef'):
            result=daily.reconcile(tx,tx.load_tx('adopted','adopted-0123456789abcdef'),0)
        self.assert_reclaimed(result)

    def test_active_reservation_refuses(self):
        other=dict(self.record,agent_id='abcdef999999',terminal=None)
        tx.atomic_write_json(tx.tx_path(SID,other['agent_id']),other)
        with self.assertRaisesRegex(Exception,'reservation'):self.run_cleanup()
        self.assert_kept()

    def test_unsupported_competing_terminal_ingress_remains_reserved(self):
        other=dict(self.record,agent_id='abcdef999999',terminal={'ingress':'TaskCompleted'})
        tx.atomic_write_json(tx.tx_path(SID,other['agent_id']),other)
        with self.assertRaisesRegex(Exception,'reservation'):self.run_cleanup()
        self.assert_kept()

    def test_locked_worktree_refuses(self):
        self.git(self.repo,'worktree','lock',str(self.work))
        with self.assertRaisesRegex(Exception,'unlocked'):self.run_cleanup()
        self.assert_kept()

    def test_previously_sealed_native_record_joins_the_lane_and_is_reclaimed(self):
        # ROUND 11 (2026-09-10). This case asserted `platform-pending` — the
        # workspace kept until a person or the platform removed the checkout.
        # A native record sealed before the daily lane existed still joins the
        # lane on the first pass, and now that its agent is provably over and
        # the platform has released its own lock, that same pass reclaims it.
        self.record['members'][0].update({'class':'native','cleanup_owner':'claude-code'})
        # historical-fixture-partial: cleanup_policy — this is NOT a historical
        # record and must not become one. The case is about a member that IS
        # platform-owned, so cleanup_owner is SET on the line above rather than
        # stripped; only the daily policy is removed, to model a native record
        # sealed before the reconciler had ever reclaimed it.
        self.record['members'][0].pop('cleanup_policy') # Previously sealed native record.
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        result=self.run_cleanup()
        self.assertEqual(result['members'][0]['cleanup_policy'],'integrated-daily')
        self.assert_reclaimed(result)

    def test_native_of_an_engine_derived_terminal_fact_stays_platform_owned(self):
        # The ground is the PLATFORM'S statement about one exact agent id.
        # `Adoption` and `NativeMemberGone` are terminal facts for this lane
        # but they are the engine's own derivations, so they never take a
        # running session's checkout out of its hands. Keeping this refusal is
        # what stops round 11 from becoming "terminal-ish means delete".
        self.make_native()
        # A RUNNING session (this process), so the session ground is the one
        # that must refuse: with no platform statement about the agent, a live
        # session's checkout stays the platform's.
        self.ledger_row(session_pid=os.getpid(),pid_start='')
        self.record['terminal']={'ingress':'Adoption','ts':'fixture'}
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        decision,reason=self.assess()
        self.assertEqual(decision,'observe');self.assertIn('own derivation',reason)
        result=self.run_cleanup();self.assertTrue(self.work.is_dir())
        self.assertEqual(result['members'][0]['state'],'platform-pending')

    def test_native_of_a_provably_gone_session_is_removed_and_its_dead_lock_released(self):
        # P3: the harness of an exited session never removes anything and never
        # releases its lock. Every recorded identity of the session is gone,
        # the registry names no running pid, the lock names the dead pid.
        self.make_native(lock_pid=DEAD_PID)
        self.ledger_row(session_pid=DEAD_PID,pid_start='')
        decision,reason=self.assess();self.assertEqual(decision,'remove');self.assertIn('gone',reason)
        result=self.run_cleanup();self.assert_reclaimed(result)
        self.assertIn('gone',result['members'][0]['daily_cleanup']['session_gone'])

    def test_native_of_a_running_session_is_reclaimed_when_the_platform_releases_its_lock(self):
        # PF6 SAID: an unlocked native tree is the ordinary state of an idle
        # live teammate between turns, so a running session keeps it.
        # ROUND 11 (2026-09-10): a TERMINAL agent has no between-turns. Its
        # terminal index makes guard-resume-isolation.sh refuse every resume
        # with no escape hatch, so the platform cannot give it another turn.
        # While Claude Code holds its own lock the workspace stays the
        # platform's and the live-lock veto refuses; the moment the PLATFORM
        # ITSELF releases that lock, the finished agent's workspace is
        # reclaimed although its session runs on. This engine never removes
        # that lock: the release is the platform's signal, not our decision.
        self.make_native(lock_pid=os.getpid())
        self.ledger_row(session_pid=os.getpid(),pid_start='')
        self.assertEqual(self.assess()[0],'hold')
        with self.assertRaisesRegex(Exception,'live'):self.run_cleanup()
        self.assert_kept()
        self.git(self.repo,'worktree','unlock',str(self.work))
        decision,reason=self.assess()
        self.assertEqual(decision,'remove');self.assertIn('cannot return',reason)
        result=self.run_cleanup();self.assert_reclaimed(result)
        self.assertIn('cannot return',result['members'][0]['daily_cleanup']['agent_over'])
        self.assertNotIn('session_gone',result['members'][0]['daily_cleanup'])

    def test_session_gone_refuses_to_read_the_real_ledger_from_a_sandboxed_store(self):
        # A redirected transaction store with the ownership ledger at its
        # default is a sandbox reading the operator's real record: a fixture
        # session id leaked there by an earlier suite, with a dead pid, would
        # read as a gone session. The verdict is NOT gone, whatever is on disk.
        self.make_native(lock_pid=DEAD_PID)
        self.ledger_row(session_pid=DEAD_PID,pid_start='')
        with patch.dict(os.environ,{'RICHOS_WORKTREE_LEDGER':''}):
            gone,reason=daily.session_gone(tx.load_tx(SID,AID),tx)
            self.assertFalse(gone);self.assertIn('inconsistently rooted',reason)
            # not provably gone -> the platform keeps the checkout; nothing removed
            decision,why=self.assess();self.assertEqual(decision,'observe');self.assertIn('inconsistently rooted',why)
        self.assert_kept()

    def test_a_workspace_this_engine_never_registered_is_never_a_candidate(self):
        # THIS is what protects the CEO's codex folders (ceo-decisions.md 31),
        # and it is structural rather than asserted: the lane acts only on
        # MEMBERS of a transaction, so a workspace nothing registered is not
        # refused -- it is never reached. Measured 2026-09-10: 0 codex paths in
        # any transaction manifest and 0 codex rows in the ownership ledger,
        # for nine standing codex worktrees, eight of them merged and clean.
        stranger = self.root / 'codex-rollback-owned-outcome'
        self.git(self.repo, 'worktree', 'add', '-b', 'codex/rollback', str(stranger))
        self.assertNotIn(os.path.realpath(str(stranger)), set(tx.member_paths()))
        with tx.tx_lock(SID, AID):
            daily.reconcile(tx, tx.load_tx(SID, AID), 0)
        self.assertTrue(stranger.is_dir())
        self.assertIn('refs/heads/codex/rollback', self.git(self.repo, 'show-ref'))

    def test_a_workspace_this_engine_never_registered_is_not_bound_by_the_binder_either(self):
        # The other door into the lane. Late binding takes a path only from a
        # ledger row of THIS session; a folder nobody registered has no row, so
        # it joins nothing and stays exactly where it is.
        stranger = self._second_workspace('codex-late')
        result = tx.bind_late_members(SID, AID)
        self.assertEqual(len(result['members']), 1)
        self.assertTrue(stranger.is_dir())

    def _second_workspace(self, name='later'):
        """A workspace created AFTER the seal, exactly as an orchestrator does
        mid-assignment: a real linked worktree and a `prepared` ledger row that
        carries NO agent id, because the helper that writes it runs before any
        spawn and cannot know one."""
        path = self.root / name
        self.git(self.repo, 'worktree', 'add', '-b', name, str(path))
        (path / 'file').write_text('later delivery\n')
        self.git(path, 'commit', '-am', 'later delivery')
        self.git(self.repo, 'merge', '--ff-only', name)
        self.main = self.git(self.repo, 'rev-parse', 'main').strip()
        return path

    def test_a_workspace_created_after_the_seal_joins_the_transaction_and_is_reclaimed(self):
        # MEASURED 2026-09-10: zach-opus-dor2 had FOUR workspaces; its manifest
        # sealed with the two that existed at spawn, and the two created
        # mid-assignment joined nothing. No terminal ingress could ever name
        # them, so they stood merged and clean an hour after the agent
        # finished, and no sanctioned tool could reclaim them. The seal is no
        # longer the boundary: a ledger row of THIS session naming this
        # teammate binds its exact path into the transaction.
        later = self._second_workspace()
        self.ledger_row(event='prepared', agent_id=None, teammate='worker',
                        worktree=str(later), branch='later', ts='2026-01-02T00:00:00+00:00')
        # NOTHING is bound by hand here: the terminal ingress must do it, or
        # the mutant that removes the binding from terminalize() proves nothing.
        result = tx.terminalize(SID, AID)
        self.assertEqual(len(result['members']), 2)
        self.assertEqual(result['members'][1]['path'], str(later))
        self.assertEqual(result['members'][1]['bound_late']['join'], 'teammate-name')
        self.assertFalse(later.exists())
        self.assertNotIn('refs/heads/later', self.git(self.repo, 'show-ref'))

    def test_a_late_row_naming_THIS_agent_id_joins_by_the_platform_identity(self):
        later = self._second_workspace()
        self.ledger_row(event='registered', agent_id=AID, teammate='somebody-else',
                        worktree=str(later), branch='later', ts='2026-01-02T00:00:00+00:00')
        result = tx.bind_late_members(SID, AID)
        self.assertEqual(result['members'][1]['bound_late']['join'], 'agent-id')

    def test_a_late_row_is_NOT_bound_when_the_teammate_name_is_ambiguous(self):
        # The name join rests on names being unique within a session. That is a
        # claim about a guard, so it is checked rather than trusted: a second
        # transaction carrying the same name makes the row un-joinable.
        later = self._second_workspace()
        self.ledger_row(event='prepared', agent_id=None, teammate='worker',
                        worktree=str(later), branch='later', ts='2026-01-02T00:00:00+00:00')
        twin = dict(self.record, agent_id='abcdef777777')
        tx.atomic_write_json(tx.tx_path(SID, 'abcdef777777'), twin)
        result = tx.bind_late_members(SID, AID)
        self.assertEqual(len(result['members']), 1)
        self.assertTrue(later.is_dir())

    def test_a_late_row_is_NOT_bound_when_the_path_stopped_being_what_it_said(self):
        later = self._second_workspace()
        self.git(later, 'checkout', '-qb', 'somebody-elses-branch')
        self.ledger_row(event='prepared', agent_id=None, teammate='worker',
                        worktree=str(later), branch='later', ts='2026-01-02T00:00:00+00:00')
        result = tx.bind_late_members(SID, AID)
        self.assertEqual(len(result['members']), 1)
        self.assertTrue(later.is_dir())

    def test_a_late_row_is_NOT_bound_when_another_transaction_already_owns_the_path(self):
        later = self._second_workspace()
        other = dict(self.record, agent_id='abcdef888888', teammate='other-worker', session_id='other-session',
                     members=[dict(self.record['members'][0], path=str(later), branch='later')])
        tx.atomic_write_json(tx.tx_path('other-session', 'abcdef888888'), other)
        self.ledger_row(event='prepared', agent_id=None, teammate='worker',
                        worktree=str(later), branch='later', ts='2026-01-02T00:00:00+00:00')
        result = tx.bind_late_members(SID, AID)
        self.assertEqual(len(result['members']), 1)
        self.assertTrue(later.is_dir())

    def test_an_ownerless_row_of_a_GONE_session_no_longer_reserves_forever(self):
        # MEASURED 2026-09-10: two ledger rows written by session 44276098 on
        # 2026-09-02, carrying no agent id, were still holding
        # /Users/alex/ab/richos-wt/zach-opus-prem1 eight days later. Nothing
        # keyed to them could ever retire them: there is no transaction at
        # (session, '') and there never will be. The only thing that can is
        # positive evidence that the session is over.
        self.ledger_row(event='prepared', session_id='dead-session', agent_id=None,
                        teammate='someone-else', session_pid=DEAD_PID, pid_start='')
        self.assertEqual(self.assess()[0], 'remove')
        self.assert_reclaimed(self.run_cleanup())

    def test_an_ownerless_row_of_a_LIVE_session_still_reserves(self):
        self.ledger_row(event='prepared', session_id='live-session', agent_id=None,
                        teammate='someone-else', session_pid=os.getpid(), pid_start='')
        self.assertEqual(self.assess()[0], 'hold')
        with self.assertRaisesRegex(Exception, 'reservation'):
            self.run_cleanup()
        self.assert_kept()

    def test_an_ownerless_row_with_no_recorded_identity_still_reserves(self):
        # Absence is never evidence, here as everywhere else.
        self.ledger_row(event='prepared', session_id='unknown-session', agent_id=None,
                        teammate='someone-else')
        self.assertEqual(self.assess()[0], 'hold')
        with self.assertRaisesRegex(Exception, 'reservation'):
            self.run_cleanup()
        self.assert_kept()

    def test_lock_that_names_nobody_is_released_by_the_reconciler_on_positive_evidence(self):
        # THE CEO'S FIRST OBSERVATION, 2026-09-10: "A finished agent's lock is
        # never released. Five workspaces sat unreclaimable for a working day
        # ... nothing automatic could EVER have cleared them."
        # The mechanism, measured: `git worktree lock` with no --reason writes
        # an EMPTY reason, _release_dead_lock refuses a lock with no pid, and
        # so the workspace is held by nobody forever. The way out is not to
        # weaken the lock rule but to have positive evidence beside it: the
        # platform's own terminal ingress named this exact agent id.
        self.make_native()
        self.git(self.repo,'worktree','lock',str(self.work))   # no --reason: names nobody
        row=_load_registry(self.repo,self.work)
        self.assertIn('locked',row);self.assertEqual(row['locked'],'')
        self.assertTrue(daily.lock_names_nobody(row))
        decision,reason=self.assess()
        self.assertEqual(decision,'remove');self.assertIn('names no process',reason)
        result=self.run_cleanup();self.assert_reclaimed(result)
        self.assertIn('held by nobody',result['members'][0]['daily_cleanup']['lock_released'])

    def test_lock_that_names_nobody_is_NOT_released_in_the_stop_event_itself(self):
        # The ingress never releases a lock the platform is holding, whatever
        # is written on it: in that instant the platform is still putting the
        # worker down. The nightly pass resolves it; the ingress waits.
        self.make_native()
        self.git(self.repo,'worktree','lock',str(self.work))
        tx.terminalize(SID,AID)
        member=tx.load_tx(SID,AID)['members'][0]
        self.assertEqual(member['immediate_reclaim']['outcome'],'deferred')
        self.assertIn('waits for the platform',member['immediate_reclaim']['reason'])
        self.assert_kept();self.assertIn('locked',_load_registry(self.repo,self.work))
        # and the second belt behind the wait: even called directly, the
        # immediate path refuses to release a lock the platform is holding
        with tx.tx_lock(SID,AID):
            with self.assertRaisesRegex(RuntimeError,'ingress waits for the platform'):
                daily.reconcile(tx,tx.load_tx(SID,AID),0,immediate=True)
        self.assert_kept();self.assertIn('locked',_load_registry(self.repo,self.work))

    def test_lock_that_names_nobody_still_refuses_without_the_platform_terminal_fact(self):
        # Same empty lock, but the terminal fact is the engine's own
        # derivation. Nothing is released and nothing is removed: the release
        # rests on the platform having named this agent, never on the lock
        # being uninformative.
        self.make_native()
        self.ledger_row(session_pid=os.getpid(),pid_start='')
        self.record['terminal']={'ingress':'Adoption','ts':'fixture'}
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        self.git(self.repo,'worktree','lock',str(self.work))
        self.assertEqual(self.assess()[0],'observe')
        self.run_cleanup()
        self.assert_kept();self.assertIn('locked',_load_registry(self.repo,self.work))

    def test_process_in_the_tree_holds_a_lock_that_names_nobody(self):
        # The release refuses while anything stands in the tree, and nothing
        # is ever killed to make room for it.
        self.make_native()
        self.git(self.repo,'worktree','lock',str(self.work))
        with patch.dict(os.environ,{'RICHOS_DAILY_PROCESSES':'4242 /bin/sleep 300 '+str(self.work)}):
            with self.assertRaisesRegex(RuntimeError,r'RETRY, not a verdict: process\(es\) 4242'):self.run_cleanup()
        self.assert_kept();self.assertIn('locked',_load_registry(self.repo,self.work))

    def test_a_lock_naming_a_live_pid_is_never_released_by_that_route(self):
        # The negative control for the whole route: a lock that DOES name a
        # running pid is refused by the liveness veto, and never reaches the
        # unattributable path.
        self.make_native(lock_pid=os.getpid())
        with self.assertRaisesRegex(Exception,'live'):self.run_cleanup()
        self.assert_kept()
        with self.assertRaisesRegex(RuntimeError,'names a pid'):
            daily._release_unattributable_lock(str(self.repo),str(self.work),
                                               _load_registry(self.repo,self.work))
        self.assertIn('locked',_load_registry(self.repo,self.work))

    def test_native_with_no_recorded_session_identity_is_not_provably_gone(self):
        # session_gone stays exactly as honest as it was: no recorded process
        # identity is never evidence that a session ended. What changed is
        # that it is no longer the ONLY ground — the removal below rests on
        # the agent ground, and the journal names which ground carried it.
        self.make_native()
        gone,why=daily.session_gone(tx.load_tx(SID,AID),tx)
        self.assertFalse(gone);self.assertIn('no process identity recorded',why)
        self.assertEqual(self.assess()[0],'remove')
        result=self.run_cleanup();self.assert_reclaimed(result)
        journal=result['members'][0]['daily_cleanup']
        self.assertIn('agent_over',journal);self.assertNotIn('session_gone',journal)

    def test_native_lock_held_by_a_running_pid_holds_whatever_the_ledger_says(self):
        # The lock is checked on its own pid, independently of the session
        # verdict: a ledger that says gone and a lock that says running is a
        # contradiction, and a contradiction never resolves in favor of deleting.
        self.make_native(lock_pid=os.getpid())
        self.ledger_row(session_pid=DEAD_PID,pid_start='')
        self.assertEqual(self.assess()[0],'hold')
        with self.assertRaisesRegex(Exception,'live'):self.run_cleanup()
        self.assert_kept()

    def test_actual_native_live_lock_vetoes_old_terminal_fact(self):
        reason='claude agent agent-'+AID+' (pid '+str(os.getpid())+' start fixture)'
        self.git(self.repo,'worktree','lock','--reason',reason,str(self.work))
        with self.assertRaisesRegex(Exception,'native owner is live'):self.run_cleanup()
        self.assert_kept()

    def test_absent_platform_removed_native_without_receipt_deletes_branch_by_recorded_head(self):
        # P5: 20 femcboost branches sat behind 'no retained completion proof'.
        head=self.git(self.work,'rev-parse','HEAD').strip()
        backup=tx.backup_ref(SID,AID,'worker');self.git(self.repo,'update-ref',backup,head)
        self.git(self.repo,'worktree','remove',str(self.work))
        self.record['members'][0].update({'class':'native','cleanup_owner':'claude-code','state':'removed',
                                          'closed':'platform-removed','head':head,'backup_ref':backup})
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        self.assertEqual(self.assess()[0],'branch-only')
        result=self.run_cleanup()
        self.assertEqual(result['members'][0]['daily_cleanup']['phase'],'complete')
        self.assertEqual(result['members'][0]['daily_cleanup']['proof_source'],'recorded-head')
        self.assertEqual(self.git(self.repo,'for-each-ref','--format=%(refname)'),'refs/heads/main\n')

    def test_absent_native_without_receipt_keeps_an_unintegrated_branch(self):
        # The branch's CURRENT tip is what is judged, so a recorded head that
        # main contains does not license deleting a tip that moved past it.
        head=self.git(self.work,'rev-parse','HEAD').strip()
        (self.work/'file').write_text('later\n');self.git(self.work,'commit','-am','later')
        later=self.git(self.work,'rev-parse','HEAD').strip()
        self.git(self.repo,'worktree','remove',str(self.work))
        for recorded in (later,head):
            with self.subTest(recorded_head=recorded[:8]):
                self.record['members'][0].update({'class':'native','cleanup_owner':'claude-code','state':'removed',
                                                  'closed':'platform-removed','head':recorded})
                tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
                self.assertEqual(self.assess()[0],'hold')
                with self.assertRaisesRegex(Exception,'no longer contains'):self.run_cleanup()
                self.assertEqual(self.git(self.repo,'rev-parse','worker').strip(),later)

    def test_absent_native_still_platform_pending_is_observed_then_branch_deleted_in_one_pass(self):
        # On the operator's machine every absent native sat at platform-pending
        # with its path gone: the observation that records `removed` had not run
        # since the platform tore the checkout down. One pass must do both.
        head=self.git(self.work,'rev-parse','HEAD').strip()
        self.git(self.repo,'worktree','remove',str(self.work))
        self.record['members'][0].update({'class':'native','cleanup_owner':'claude-code','state':'platform-pending','head_at_seal':head})
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        self.assertEqual(self.assess()[0],'branch-only')
        result=self.run_cleanup()
        self.assertEqual(result['members'][0]['state'],'removed')
        self.assertEqual(result['members'][0]['daily_cleanup']['phase'],'complete')
        self.assertEqual(self.git(self.repo,'for-each-ref','--format=%(refname)'),'refs/heads/main\n')

    def test_interruption_after_worktree_removal_replays(self):
        def crash(point):
            if point=='after-worktree-remove':raise RuntimeError('fixture crash')
        with patch.object(daily,'_checkpoint',crash):
            with self.assertRaisesRegex(RuntimeError,'fixture crash'):self.run_cleanup()
        self.assertFalse(self.work.exists());self.assertIn('refs/heads/worker',self.git(self.repo,'show-ref'))
        self.assertEqual(self.run_cleanup()['members'][0]['daily_cleanup']['phase'],'complete')

    def test_interruption_after_branch_delete_replays(self):
        def crash(point):
            if point=='after-branch-delete':raise RuntimeError('fixture crash')
        with patch.object(daily,'_checkpoint',crash):
            with self.assertRaisesRegex(RuntimeError,'fixture crash'):self.run_cleanup()
        self.assertFalse(self.work.exists());self.assertNotIn('refs/heads/worker',self.git(self.repo,'show-ref'))
        self.assertEqual(self.run_cleanup()['members'][0]['daily_cleanup']['phase'],'complete')

    def test_recreated_path_after_remove_is_held(self):
        def crash(point):
            if point=='after-worktree-remove':raise RuntimeError('fixture crash')
        with patch.object(daily,'_checkpoint',crash):
            with self.assertRaises(RuntimeError):self.run_cleanup()
        self.work.mkdir();(self.work/'new').write_text('new owner\n')
        with self.assertRaises(Exception):self.run_cleanup()
        self.assertEqual((self.work/'new').read_text(),'new owner\n')
        self.assertIn('refs/heads/worker',self.git(self.repo,'show-ref'))

    def test_terminal_ingress_keeps_dirty_path_and_reconciler_reports_hold(self):
        (self.work/'file').write_text('unfinished\n')
        tx.terminalize(SID,AID)
        self.assertTrue(self.work.exists())
        self.assertFalse(any(self.root.glob('*.richos-terminal-*')))
        spec=importlib.util.spec_from_file_location('daily_reconciler',HERE/'reconcile-terminal-worktrees.py')
        rec=importlib.util.module_from_spec(spec);spec.loader.exec_module(rec)
        rec.reconcile_transaction(tx.load_tx(SID,AID))
        result=tx.load_tx(SID,AID)
        self.assertTrue(result['members'][0]['blocked'])
        self.assertEqual(tx.metrics()['terminal_pending_cleanup'],1)
        self.assertEqual((self.work/'file').read_text(),'unfinished\n')

    def test_native_terminal_ingress_reclaims_in_the_same_event(self):
        # ROUND 11. This case used to terminalize, then remove the checkout by
        # hand, then run the NIGHTLY reconciler to finish the job — which is
        # exactly the 24-hour gap the CEO was looking at. The ingress now does
        # it: one call, workspace gone, branch resolved, nothing pending.
        self.record['members'][0].update({'class':'native','cleanup_owner':'claude-code'})
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        tx.terminalize(SID,AID)
        member=tx.load_tx(SID,AID)['members'][0]
        self.assertEqual(member['immediate_reclaim']['outcome'],'reclaimed')
        self.assertEqual(member['daily_cleanup']['phase'],'complete')
        self.assertFalse(self.work.exists())
        self.assertEqual(self.git(self.repo,'for-each-ref','--format=%(refname)'), 'refs/heads/main\n')
        self.assertEqual(tx.metrics()['terminal_pending_cleanup'],0)
        # and the nightly pass over the same record is a no-op, not a retry
        spec=importlib.util.spec_from_file_location('daily_reconciler',HERE/'reconcile-terminal-worktrees.py')
        rec=importlib.util.module_from_spec(spec);spec.loader.exec_module(rec)
        rec.reconcile_transaction(tx.load_tx(SID,AID))
        self.assertEqual(tx.load_tx(SID,AID)['members'][0]['daily_cleanup']['phase'],'complete')

    def test_hand_rolled_terminal_ingress_reclaims_in_the_same_event(self):
        # The cross-repository worktree — 48 of 53 on this machine — takes the
        # same route from the same event. It carries no platform lock, so the
        # ingress has nothing to wait for.
        tx.terminalize(SID,AID)
        member=tx.load_tx(SID,AID)['members'][0]
        self.assertEqual(member['immediate_reclaim']['outcome'],'reclaimed')
        self.assertFalse(self.work.exists())
        self.assertNotIn('refs/heads/worker',self.git(self.repo,'show-ref'))

    def test_ingress_waits_for_the_platform_to_release_its_own_lock_and_never_removes_it(self):
        # WHO HOLDS THE LOCK, AND MAY THE ENGINE RELEASE IT? Claude Code holds
        # it; its pid is the SESSION's, shared by every agent of that session,
        # so it can never speak about one agent. It is not ours. The ingress
        # therefore WAITS for the platform's own release, bounded, and defers
        # if it does not come — the lock is still on the tree afterwards, and
        # the workspace is untouched.
        self.make_native(lock_pid=os.getpid())
        with patch.dict(os.environ,{}):
            with patch.object(daily,'unlock_wait_seconds',lambda repo=None:0.3):
                tx.terminalize(SID,AID)
        member=tx.load_tx(SID,AID)['members'][0]
        self.assertEqual(member['immediate_reclaim']['outcome'],'deferred')
        self.assertIn('still holds its own lock',member['immediate_reclaim']['reason'])
        self.assert_kept()
        self.assertIn('locked',_load_registry(self.repo,self.work))
        # the platform releases it; the NEXT terminal ingress reclaims at once
        self.git(self.repo,'worktree','unlock',str(self.work))
        tx.terminalize(SID,AID)
        self.assertEqual(tx.load_tx(SID,AID)['members'][0]['immediate_reclaim']['outcome'],'reclaimed')
        self.assertFalse(self.work.exists())

    def test_branch_reserved_elsewhere_is_retained(self):
        second=self.root/'other-checkout'
        self.git(self.repo,'worktree','add','--force',str(second),'worker')
        with self.assertRaisesRegex(Exception,'reserved'):self.run_cleanup()
        self.assertFalse(self.work.exists());self.assertTrue(second.exists())
        self.assertIn('refs/heads/worker',self.git(self.repo,'show-ref'))

    def test_malformed_ledger_and_unbound_preparation_refuse(self):
        ledger=self.root/'ledger.jsonl'
        ledger.write_text('{not-json}\n')
        with self.assertRaises(Exception):self.run_cleanup()
        self.assert_kept()
        ledger.write_text(json.dumps({'event':'prepared','session_id':'new-session','teammate':'new',
            'repo':str(self.repo),'worktree':str(self.work),'branch':'worker'})+'\n')
        with self.assertRaisesRegex(Exception,'preparation'):self.run_cleanup()
        self.assert_kept()

    def test_changed_branch_after_remove_is_held(self):
        def crash(point):
            if point=='after-worktree-remove':raise RuntimeError('fixture crash')
        with patch.object(daily,'_checkpoint',crash):
            with self.assertRaises(RuntimeError):self.run_cleanup()
        base=self.git(self.repo,'rev-parse','main^').strip()
        self.git(self.repo,'update-ref','refs/heads/worker',base)
        with self.assertRaises(Exception):self.run_cleanup()
        self.assertEqual(self.git(self.repo,'rev-parse','worker').strip(),base)

if __name__=='__main__':unittest.main()
