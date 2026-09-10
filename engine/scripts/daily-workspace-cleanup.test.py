#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
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
        # `source` defaults to a real engine writer because that is what
        # production rows carry: measured 2026-09-10, 617 of 621
        # prepared/registered rows name create-teammate-worktree.sh or
        # detect-nonnative-worktree.sh. The four that do not were written by
        # hand, and one of them removed a workspace nothing had registered —
        # see test_a_hand_written_ledger_row_RESERVES_but_never_BINDS.
        row=dict(event='registered',session_id=SID,teammate='worker',repo=str(self.repo),worktree=str(self.work),
                 branch='worker',agent_id=AID,ts='2026-01-01T00:00:00+00:00',
                 source='create-teammate-worktree.sh'); row.update(fields)
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
        # THE REAL BRANCH, NOT ONLY THE TEST OVERRIDE. A fixture that can only
        # fail the way the fixture allows proves the fixture (type L: verified
        # from the inside). So lsof is made genuinely unreachable by emptying
        # PATH, which is the same FileNotFoundError a machine without lsof
        # raises, and the shipped code path is the one under test.
        empty=self.root/'no-tools';empty.mkdir()
        with patch.dict(os.environ,{'PATH':str(empty)}):
            self.assertIsNone(os.environ.get('RICHOS_DAILY_PROCESSES_UNUSED'))
            with self.assertRaisesRegex(RuntimeError,'lsof did not answer'):
                with patch.dict(os.environ):
                    os.environ.pop('RICHOS_DAILY_PROCESSES',None)
                    daily.processes_using(str(self.work))
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

    def test_a_nested_repository_under_a_disposable_path_is_ARCHIVED_whole_never_dropped(self):
        # FRANK R1, ROUND TWO -- the only loss path found in two rounds of
        # review. `git ls-files --others --ignored --exclude-standard` reports a
        # nested repository as ONE directory entry (`vendor/lib/`), and
        # partition_ignored() dropped any path with a disposable component, so
        # a clone under an ignored vendor/ was classified disposable by its
        # parent's name, archived by nobody, and deleted by the non-force
        # removal -- commits nowhere else, gone. Reproduced under the lane's
        # binary: `nested: (0, '') | exists after: False`.
        (self.repo/'.git/info/exclude').write_text('vendor/\n')
        nested=self.work/'vendor'/'lib';nested.mkdir(parents=True)
        self.git(nested,'init','-q','-b','main');self.git(nested,'config','user.name','Fixture');self.git(nested,'config','user.email','fixture@example.invalid')
        (nested/'only-here').write_text('commits nobody else holds\n');self.git(nested,'add','only-here');self.git(nested,'commit','-q','-m','only here')
        nested_head=self.git(nested,'rev-parse','HEAD').strip()
        (self.work/'vendor'/'plain-ignored').write_text('a disposable file beside it\n')
        # the premise, asserted rather than assumed: git lists the nested
        # repository as a trailing-slash entry and the plain file as itself
        listed=daily.ignored_files(str(self.work))
        self.assertIn('vendor/lib/',listed);self.assertIn('vendor/plain-ignored',listed)
        keep,residue=daily.partition_ignored(listed,daily.disposable_paths(str(self.repo)))
        self.assertEqual((keep,residue),(['vendor/plain-ignored'],['vendor/lib/']))
        # and a `.git` component is never disposable whatever it sits under
        self.assertEqual(daily.partition_ignored(['node_modules/x/.git/HEAD'],{'node_modules'}),([],['node_modules/x/.git/HEAD']))
        decision,reason=self.assess();self.assertEqual(decision,'remove');self.assertIn('1 archived first',reason)
        result=self.run_cleanup();self.assert_reclaimed(result)
        journal=result['members'][0]['daily_cleanup']
        self.assertEqual(journal['ignored_disposable'],1)
        residue=journal['ignored_residue']
        self.assertEqual(residue['nested_repositories'],['vendor/lib'])
        self.assertEqual(residue['nested_repository_count'],1)
        with tarfile.open(residue['archive']) as tar:
            names=tar.getnames()
            self.assertIn('vendor/lib/only-here',names)
            # THE COMMIT ITSELF is in the archive: the loose object of the
            # nested HEAD, under its own .git, byte-identical and verified.
            self.assertIn('vendor/lib/.git/objects/%s/%s'%(nested_head[:2],nested_head[2:]),names)
            self.assertIn('vendor/lib/.git',names)                      # a directory entry
            self.assertTrue(tar.getmember('vendor/lib/.git').isdir())
            self.assertNotIn('vendor/plain-ignored',names)              # the disposable file was dropped
        self.assertGreater(residue['directories'],0)
        # restore it and prove the commit is reachable again
        dest=self.root/'restore';dest.mkdir()
        with tarfile.open(residue['archive']) as tar:
            tar.extractall(dest)
        self.assertEqual(self.git(dest/'vendor'/'lib','rev-parse','HEAD').strip(),nested_head)
        self.assertEqual(self.git(dest/'vendor'/'lib','cat-file','-p','HEAD:only-here'),'commits nobody else holds\n')

    def test_an_ignored_file_written_after_the_archive_HOLDS_the_removal(self):
        # SAGE D3, ROUND TWO. reconcile() archived and verified the residue,
        # then re-checked the tracked side and the lock -- and never the
        # ignored side -- before `git worktree remove`, which does not refuse
        # on ignored changes. A writer the process probe did not see (one that
        # started after the probe, or whose handle closed between writes)
        # writing an ignored file in that window lost those bytes. Same
        # last-look shape as the tracked side, on the ignored side.
        (self.repo/'.git/info/exclude').write_text('extra\nlate\n')
        (self.work/'extra').write_bytes(b'archived\n')
        real_archive=daily.archive_residue
        work=self.work
        def write_during_preparation(*a,**k):
            out=real_archive(*a,**k)
            (work/'late').write_bytes(b'written after the archive\n')
            return out
        with patch.object(daily,'archive_residue',write_during_preparation):
            with self.assertRaisesRegex(RuntimeError,'ignored bytes changed between the archive and the removal'):
                self.run_cleanup()
        self.assert_kept();self.assertTrue((self.work/'late').exists())
        # the same shape when NOTHING was archived and a residue appears late
        (self.work/'extra').unlink();(self.work/'late').unlink()
        def write_late_file(*a,**k):
            raise AssertionError('archive_residue must not be called with no residue')
        real_partition=daily.partition_ignored
        calls=[]
        def partition_then_write(files,disposable):
            calls.append(1)
            out=real_partition(files,disposable)
            if len(calls)==1:
                (work/'late').write_bytes(b'appeared after the first listing\n')
            return out
        with patch.object(daily,'partition_ignored',partition_then_write):
            with self.assertRaisesRegex(RuntimeError,'1 added'):
                self.run_cleanup()
        self.assert_kept()
        # and with the tree quiet, the same workspace reclaims and the late
        # file is in the archive rather than under the rubble
        result=self.run_cleanup();self.assert_reclaimed(result)
        with tarfile.open(result['members'][0]['daily_cleanup']['ignored_residue']['archive']) as tar:
            self.assertEqual(tar.getnames(),['late'])

    def test_the_record_says_WHEN_a_workspace_was_removed(self):
        # SAGE D6, ROUND TWO. `phase = complete` carried no timestamp, so
        # ordering a restart against a removal -- the question the whole round
        # turned on -- had to be inferred from grounds. Read, now, in UTC.
        result=self.run_cleanup();self.assert_reclaimed(result)
        journal=result['members'][0]['daily_cleanup']
        for key in ('worktree_removed_ts','removed_ts'):
            self.assertIn(key,journal)
            self.assertTrue(journal[key].endswith('+00:00'),journal[key])
        self.assertLessEqual(journal['worktree_removed_ts'],journal['removed_ts'])

    def test_a_secret_bearing_file_is_ARCHIVED_and_NAMED_never_silently_dropped(self):
        # FRANK D13, 2026-09-10. The residue archive is where a workspace's
        # IGNORED files go, and `.env` files are ignored by construction: 51
        # archives on the operator's machine, at least 15 holding
        # avelor/.env.local and fitapp/.env.local. Those carry only public
        # Convex URLs today, so nothing has leaked — and the mechanism would
        # archive a real secret with exactly the same care, forever, in a store
        # scan-secrets.sh does not watch.
        #
        # THE FIX IS NOT A FILTER. "Nothing ignored is discarded without a
        # copy" is the invariant this archive exists to keep, and quietly
        # dropping a file would be a deletion wearing a security
        # justification. The file goes in AND the journal names it.
        (self.repo/'.git/info/exclude').write_text('.env.local\nnotes.txt\n')
        (self.work/'.env.local').write_bytes(b'PUBLIC_CONVEX_URL=https://example.invalid\n')
        (self.work/'notes.txt').write_bytes(b'ordinary ignored bytes\n')
        result=self.run_cleanup();self.assert_reclaimed(result)
        residue=result['members'][0]['daily_cleanup']['ignored_residue']
        self.assertEqual(residue['files'],2)
        # ARCHIVED, byte for byte — the invariant is not weakened
        with tarfile.open(residue['archive']) as tar:
            self.assertEqual(sorted(tar.getnames()),['.env.local','notes.txt'])
            self.assertEqual(tar.extractfile('.env.local').read(),
                             b'PUBLIC_CONVEX_URL=https://example.invalid\n')
        # ...and NAMED, so an operator knows where to look
        self.assertEqual(residue['secret_bearing'],['.env.local'])
        self.assertEqual(residue['secret_bearing_count'],1)
        # the negative control: an ordinary ignored file is not named, so the
        # report means something rather than flagging everything
        self.assertNotIn('notes.txt',residue['secret_bearing'])
        for name in ('.env','.env.production','id_rsa','app.pem','secrets'):
            self.assertTrue(daily._looks_secret_bearing('sub/dir/'+name),name)
        for name in ('README.md','environment.md','index.js'):
            self.assertFalse(daily._looks_secret_bearing(name),name)

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
        self.assertEqual(decision,'remove');self.assertIn('nothing is running in it',reason)
        result=self.run_cleanup();self.assert_reclaimed(result)
        self.assertIn('nothing is running in it',result['members'][0]['daily_cleanup']['workspace_free'])
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

    def test_a_hand_written_ledger_row_RESERVES_but_never_BINDS(self):
        # SAGE D2, 2026-09-10. The ownership ledger is an append-only JSONL
        # with no writer authentication — which is right for a RECORD and wrong
        # for an AUTHORIZATION. At 14:23:47 UTC that day a row was appended by
        # hand with source `rich-operator-amnesty`, carrying a session id and a
        # teammate name and NO agent id, to bring a workspace nothing had
        # registered into this lane. It worked, and 45 minutes later that
        # workspace was gone. The identical row with a `codex/` path would have
        # passed the same lane, which is the hole under section 31's
        # "we only remove what we registered".
        later = self._second_workspace()
        self.ledger_row(event='prepared', agent_id=None, teammate='worker',
                        worktree=str(later), branch='later', source='rich-operator-amnesty',
                        ts='2026-01-02T00:00:00+00:00')
        result = tx.terminalize(SID, AID)
        self.assertEqual(len(result['members']), 1, 'a hand-written row must not bind a member')
        self.assertTrue(later.exists(), 'the workspace must survive')
        self.assertIn('refs/heads/later', self.git(self.repo, 'show-ref'))
        # and it still RESERVES: the asymmetry is the whole design. A row
        # anybody can write may protect a workspace and may never destroy one.
        self.assertFalse(load('worktree-ledger').row_may_bind_by_name(
            {'source': 'rich-operator-amnesty'}))
        self.assertTrue(load('worktree-ledger').row_may_bind_by_name(
            {'source': 'create-teammate-worktree.sh'}))
        # the same row from an engine writer DOES bind — the positive control,
        # so the negative above cannot pass because binding is broken outright
        self.ledger_row(event='prepared', agent_id=None, teammate='worker',
                        worktree=str(later), branch='later',
                        source='create-teammate-worktree.sh', ts='2026-01-03T00:00:00+00:00')
        result = tx.bind_late_members(SID, AID)
        self.assertEqual(len(result['members']), 2)
        self.assertEqual(result['members'][1]['bound_late']['join'], 'teammate-name')

    def test_a_codex_workspace_is_EXCLUDED_BY_CEO_RULING_at_every_door(self):
        # D6 / ceo-decisions.md section 31. The ruling says an excluded
        # workspace is never removed AND is reported in those words; the code
        # tested for `codex/` nowhere, and rested on "we only remove what we
        # registered" — which section 31 names as the record hole that must not
        # BE the protection, and which was walked through by hand the same day.
        # So it is refused here even when every other gate would pass.
        self.assertEqual(self.assess()[0], 'remove')          # would be removed
        self.git(self.repo, 'branch', '-m', 'worker', 'codex/owned-outcome')
        self.record['members'][0]['branch'] = 'codex/owned-outcome'
        tx.atomic_write_json(tx.tx_path(SID, AID), self.record)
        decision, reason = self.assess()
        self.assertEqual(decision, 'hold')
        self.assertIn('EXCLUDED BY CEO RULING', reason)
        self.assertIn('section 31', reason)
        with self.assertRaisesRegex(Exception, 'EXCLUDED BY CEO RULING'):
            self.run_cleanup()
        self.assertTrue(self.work.is_dir())
        self.assertIn('refs/heads/codex/owned-outcome', self.git(self.repo, 'show-ref'))
        # `refs/heads/codex/x` is the same branch as `codex/x`, and a path under
        # ~/.codex/worktrees is the same class: one thing, more than one spelling
        self.assertTrue(daily.ceo_owned_workspace({'branch': 'refs/heads/codex/x'})[0])
        self.assertTrue(daily.ceo_owned_workspace(
            {'path': os.path.expanduser('~/.codex/worktrees/06e6/femcboost')})[0])
        self.assertFalse(daily.ceo_owned_workspace({'branch': 'zach-opus-x1'})[0])
        self.assertFalse(daily.ceo_owned_workspace({'branch': 'not-codex/thing'})[0])

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

    def test_a_lock_that_names_nobody_is_STILL_A_LOCK_and_the_engine_never_takes_it_off(self):
        # ROUND 12, 2026-09-10 — THIS TEST IS THE INVERSE OF THE ONE IT
        # REPLACED, and the inversion is the fix.
        #
        # Round 11 accepted an empty lock as "a lock nobody can be behind" and
        # shipped _release_unattributable_lock to take it off and delete the
        # workspace. Three things make that indefensible. The platform holds a
        # lock by the file's PRESENCE, not its contents, so "names nobody" is a
        # fact about a string. The empty locks that motivated it were written
        # by an operator's own `git worktree lock` without --reason over three
        # LIVE agents (evidence pack 2.5/2.6) — a repair of an incident turned
        # into a standing authority. And releasing it destroys the property
        # that makes a restart survivable: git refuses to remove a LOCKED
        # worktree, which is what stops a reclaim racing an agent the platform
        # is starting again (measured: ten of 66 terminal agents restart).
        #
        # The cost is accepted and is visible: the workspace is HELD, and the
        # reason names the remedy a person can apply.
        self.make_native()
        self.git(self.repo,'worktree','lock',str(self.work))   # no --reason: names nobody
        row=_load_registry(self.repo,self.work)
        self.assertIn('locked',row);self.assertEqual(row['locked'],'')
        self.assertFalse(hasattr(daily,'lock_names_nobody'))
        self.assertFalse(hasattr(daily,'_release_unattributable_lock'))
        decision,reason=self.assess()
        self.assertEqual(decision,'observe')
        self.assertIn('the platform is holding its own lock',reason)
        self.assertIn('git worktree unlock',reason)
        self.run_cleanup()
        self.assert_kept();self.assertIn('locked',_load_registry(self.repo,self.work))
        # the hold clears the moment a person or the platform releases it —
        # so it is a hold, not a grave.
        self.git(self.repo,'worktree','unlock',str(self.work))
        self.assertEqual(self.assess()[0],'remove')
        self.assert_reclaimed(self.run_cleanup())

    def test_a_relock_between_the_check_and_the_removal_makes_the_removal_FAIL(self):
        # THE RACE THE NEW GROUND RESTS ON, exercised rather than reasoned.
        # The platform locks a native worktree BEFORE the run starts (measured
        # on two live agents: the lock file's mtime precedes the SubagentStart
        # hook by 43 ms and 49 ms). So if an agent is restarted between the
        # lane's lock check and its `git worktree remove`, the lock is back —
        # and non-force `git worktree remove` REFUSES a locked worktree
        # ("cannot remove a locked working tree", exit 128, git 2.52.0).
        #
        # Simulated by locking the tree after the decision is taken and before
        # the removal runs, through the last-look check that exists for this.
        self.make_native()
        self.assertEqual(self.assess()[0],'remove')
        real_archive=daily.archive_residue
        work,repo,git=self.work,self.repo,self.git
        def relock_during_preparation(*a,**k):
            git(repo,'worktree','lock','--reason','claude agent restarted',str(work))
            return real_archive(*a,**k)
        (self.work/'ignored-residue').write_text('bytes\n')
        (self.repo/'.gitignore').write_text('ignored-residue\n')
        self.git(self.repo,'add','.gitignore');self.git(self.repo,'commit','-m','ignore')
        self.git(self.work,'merge','--ff-only','main')
        self.git(self.repo,'merge','--ff-only','worker')
        self.main=self.git(self.repo,'rev-parse','main').strip()
        with patch.object(daily,'archive_residue',relock_during_preparation):
            with self.assertRaisesRegex(RuntimeError,'holds this workspace again as of this instant'):
                self.run_cleanup()
        self.assert_kept();self.assertIn('locked',_load_registry(self.repo,self.work))
        # and the belt behind the braces: git itself refuses the same removal
        r=subprocess.run(['git','-C',str(self.repo),'worktree','remove','--',str(self.work)],
                         capture_output=True,text=True)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('locked working tree',r.stderr)

    def test_lock_that_names_nobody_still_refuses_without_the_platform_terminal_fact(self):
        # Same empty lock, but the terminal fact is the engine's own
        # derivation rather than a platform event about this agent id. Nothing
        # is removed and nothing is unlocked — two independent refusals, and
        # the test proves the candidacy one still exists after round 12
        # withdrew the authorization it used to carry.
        self.make_native()
        self.ledger_row(session_pid=os.getpid(),pid_start='')
        self.record['terminal']={'ingress':'Adoption','ts':'fixture'}
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        self.git(self.repo,'worktree','lock',str(self.work))
        self.assertEqual(self.assess()[0],'observe')
        self.run_cleanup()
        self.assert_kept();self.assertIn('locked',_load_registry(self.repo,self.work))

    def test_a_lock_naming_a_live_pid_refuses_at_the_liveness_veto(self):
        # The negative control: a lock that names a RUNNING pid is refused by
        # the liveness veto, and after round 12 there is no second route past
        # it — the unattributable-lock door it used to be the control for is
        # gone entirely.
        self.make_native(lock_pid=os.getpid())
        with self.assertRaisesRegex(Exception,'live'):self.run_cleanup()
        self.assert_kept()
        self.assertIn('locked',_load_registry(self.repo,self.work))

    def test_a_restart_after_terminal_is_recorded_and_HOLDS_every_workspace_of_that_agent(self):
        # D1, THE DEFECT BOTH REVIEWERS CONVERGED ON. Round 11 authorized
        # removal in the terminal event because the platform's first
        # SubagentStop "says the agent cannot be given another turn". Measured
        # the same day: ten of the 66 workspace-owning terminal transactions on
        # this machine have a start strictly AFTER their terminal record
        # (restart-after-terminal-measure.py), the earliest two days before
        # round 11 was written. Nothing recorded that fact, so nothing could
        # refuse on it, and no test covered the sequence at all.
        #
        # This is that sequence: seal -> terminal -> the platform starts the
        # agent again -> a reclaim is attempted.
        self.assertEqual(self.assess()[0],'remove')          # would have been removed
        self.assertFalse(tx.restarted_after_terminal(tx.load_tx(SID,AID)))
        tx.note_after_terminal(SID,AID,'start','/some/cwd')  # the platform runs it again
        self.assertTrue(tx.restarted_after_terminal(tx.load_tx(SID,AID)))
        self.assertTrue(tx.running_after_terminal(tx.load_tx(SID,AID)))
        decision,reason=self.assess()
        self.assertEqual(decision,'hold')
        self.assertIn('started agent',reason);self.assertIn('again after its terminal record',reason)
        with self.assertRaisesRegex(Exception,'again after its terminal record'):self.run_cleanup()
        self.assert_kept()
        # the immediate lane refuses it too, and says so in the journal
        with tx.tx_lock(SID,AID):
            outcome,_why=daily.reclaim_now(tx,tx.load_tx(SID,AID),0)
        self.assertEqual(outcome,'deferred')
        journal=tx.load_tx(SID,AID)['members'][0]['immediate_reclaim']
        self.assertIn('still open',journal['reason'])
        self.assert_kept()
        # when that run ends the hold clears — a restart is a hold, never a
        # permanent disqualification, and the record shows both events
        tx.note_after_terminal(SID,AID,'stop','SubagentStop')
        self.assertFalse(tx.running_after_terminal(tx.load_tx(SID,AID)))
        self.assertTrue(tx.restarted_after_terminal(tx.load_tx(SID,AID)))
        counts=tx.load_tx(SID,AID)['after_terminal_counts']
        self.assertEqual((counts['start'],counts['stop']),(1,1))
        self.assertEqual(self.assess()[0],'remove')
        self.assert_reclaimed(self.run_cleanup())

    def _terminal_at(self, when):
        self.record['terminal']['ts']=when.isoformat()
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)

    def _event_log(self, rows, agent_id=AID, session_id=SID):
        """Rows in the platform's own worker event log, the shape
        worker-started-handoff.sh / worker-ended-handoff.sh write."""
        team=self.root/'teams'/('session-'+session_id[:8]);team.mkdir(parents=True,exist_ok=True)
        with open(team/'worker-events.jsonl','a') as stream:
            for when,event in rows:
                stream.write(json.dumps({'timestamp':when.isoformat(),'event':event,'agent_id':agent_id,
                                         'session_id':session_id,'source_hook':'fixture'})+'\n')

    def test_a_lost_stop_note_is_closed_by_the_platforms_own_event_log_and_a_lost_start_note_is_opened_by_it(self):
        # FRANK R2 / R4, ROUND TWO. The post-terminal notes are written under
        # a 5-second flock that a catch-up sweep or the nightly pass holds for
        # a whole reclaim; a note that loses that race is announced on stderr
        # and lost. With ONE source and no expiry, a lost stop note held every
        # workspace of the agent forever while the journal called it a RETRY;
        # a lost start note left the restart invisible to the lane. The
        # platform writes both events in its own log, keyed by the
        # registration id (Sage H3: all eleven restarts on record), and that
        # log is now the second source.
        from datetime import datetime,timezone,timedelta
        t0=datetime.now(timezone.utc)-timedelta(seconds=60)
        self._terminal_at(t0)
        # HERMETIC: a redirected store never reads the operator's real log
        # unless the log is NAMED (the rule session_id_gone applies to the ledger)
        self.assertIsNone(tx.lifecycle_teams_dir())
        with patch.dict(os.environ,{'RICHOS_TEAMS_DIR':str(self.root/'teams')}):
            self.assertEqual(self.assess()[0],'remove')
            # rows for ANOTHER agent, and for this agent in ANOTHER session, never count: the join is exact
            self._event_log([(t0+timedelta(seconds=5),'WorkerStarted')],agent_id='abcdef999999')
            self._event_log([(t0+timedelta(seconds=5),'WorkerStarted')],session_id='other-session')
            self.assertFalse(tx.running_after_terminal(tx.load_tx(SID,AID)))
            # (a) THE LOST START NOTE: only the platform's log saw the restart
            self._event_log([(t0+timedelta(seconds=10),'WorkerStarted')])
            self.assertTrue(tx.running_after_terminal(tx.load_tx(SID,AID)))
            self.assertTrue(tx.restarted_after_terminal(tx.load_tx(SID,AID)))
            decision,reason=self.assess();self.assertEqual(decision,'hold');self.assertIn('again after its terminal record',reason)
            self.assertIn("platform's event log",reason)
            self.assert_kept()
            # (b) THE LOST STOP NOTE: the transaction's last note is a start,
            # the platform's log says the run ended after it
            tx.note_after_terminal(SID,AID,'start','/cwd')
            self.assertTrue(tx.running_after_terminal(tx.load_tx(SID,AID)))
            self._event_log([(datetime.now(timezone.utc)+timedelta(seconds=1),'WorkerRunEnded')])
            self.assertFalse(tx.running_after_terminal(tx.load_tx(SID,AID)))
            self.assertTrue(tx.restarted_after_terminal(tx.load_tx(SID,AID)))
            self.assertEqual([(kind,src) for _when,kind,src in tx.post_terminal_events(tx.load_tx(SID,AID))],
                             [('start','events'),('start','notes'),('stop','events')])
            self.assertEqual(self.assess()[0],'remove')
            self.assert_reclaimed(self.run_cleanup())

    def test_a_post_terminal_run_cannot_outlive_its_session(self):
        # FRANK R2 (2): row 5 preceded row 10a, so `session_gone` never
        # overrode it — a session that died mid-run held the workspace on a
        # note nothing could ever close. A run lives inside its session's
        # process: a session provably gone (every recorded pid gone or reused,
        # no running registration) voids the open run.
        self.assertEqual(self.assess()[0],'remove')
        tx.note_after_terminal(SID,AID,'start','/cwd')
        # the session is running (this process is its recorded identity): held
        self.ledger_row(session_pid=os.getpid(),pid_start='')
        decision,reason=self.assess();self.assertEqual(decision,'hold');self.assertIn('again after its terminal record',reason)
        self.assert_kept()
        # the session is provably gone: the open run is void, the reason says so
        (self.root/'ledger.jsonl').write_text('')
        self.ledger_row(session_pid=DEAD_PID,pid_start='')
        self.assertTrue(daily.session_gone(tx.load_tx(SID,AID),tx)[0])
        run_open,why=daily.post_terminal_run_open(tx,tx.load_tx(SID,AID))
        self.assertFalse(run_open);self.assertIn('cannot outlive its session',why)
        self.assertEqual(self.assess()[0],'remove')
        self.assert_reclaimed(self.run_cleanup())

    def test_a_stale_open_run_names_the_operator_remedy_and_the_remedy_works(self):
        # FRANK R2 (4): a hold older than a bound names the remedy instead of
        # "until the run ends". Every post-terminal run observed on this
        # machine lasted under a minute; this one has been open two hours.
        from datetime import datetime,timezone,timedelta
        old=(datetime.now(timezone.utc)-timedelta(hours=2)).isoformat()
        self.record['after_terminal']=[{'kind':'start','ts':old,'detail':'/cwd'}]
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        decision,reason=self.assess()
        self.assertEqual(decision,'hold')
        self.assertIn('POST_TERMINAL_RUN_STALE_SECONDS',reason);self.assertIn('note-after-terminal',reason)
        self.assertIn('the remedy is a PERSON',reason);self.assertNotIn('held until the run ends',reason)
        self.assert_kept()
        with tx.tx_lock(SID,AID):
            outcome,why=daily.reclaim_now(tx,tx.load_tx(SID,AID),0)
        self.assertEqual(outcome,'deferred');self.assertIn('note-after-terminal',str(why))
        # a person confirms and records the stop both sources missed, through
        # the exact command the reason names
        r=subprocess.run(['python3',str(HERE/'lib'/'worktree-transactions.py'),'note-after-terminal',
                          '--session-id',SID,'--agent-id',AID,'--kind','stop','--detail','operator'],
                         capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(r.stdout)['after_terminal_counts'],{'start':1,'stop':1})
        self.assertEqual(self.assess()[0],'remove')
        self.assert_reclaimed(self.run_cleanup())

    def test_the_immediate_reclaim_journal_APPENDS_instead_of_overwriting(self):
        # FRANK D14. reclaim_now wrote one `immediate_reclaim` object, so the
        # last writer erased every earlier outcome: zach-opus-unl1's own-event
        # outcome vanished under its 18:20 sweep row, and the finding "zero of
        # five reclaims happened in their own event" had to be established from
        # timestamps because the journal built to answer that question could
        # not. The latest outcome keeps its key and shape; the history is beside
        # it.
        self.make_native()
        self.git(self.repo,'worktree','lock',str(self.work))
        with tx.tx_lock(SID,AID):
            daily.reclaim_now(tx,tx.load_tx(SID,AID),0)
        self.git(self.repo,'worktree','unlock',str(self.work))
        (self.work/'extra').write_text('dirty\n')
        with tx.tx_lock(SID,AID):
            daily.reclaim_now(tx,tx.load_tx(SID,AID),0)
        member=tx.load_tx(SID,AID)['members'][0]
        history=member['immediate_reclaim_history']
        self.assertEqual(len(history),2)
        self.assertEqual(member['immediate_reclaim_attempts'],2)
        self.assertIn('holding its own lock',history[0]['reason'])
        self.assertNotIn('holding its own lock',history[1]['reason'])
        self.assertEqual(member['immediate_reclaim'],history[-1])
        # every stamp is UTC, so a journal row is comparable with the terminal
        # record three lines above it in the same file
        for entry in history:
            self.assertTrue(entry['ts'].endswith('+00:00'),entry['ts'])

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
        self.assertIn('workspace_free',journal);self.assertNotIn('session_gone',journal)

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
        self.assertIn('the platform is holding its own lock',member['immediate_reclaim']['reason'])
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
