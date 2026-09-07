#!/usr/bin/env python3
"""Disposable gate state-machine tests; not privileged boundary acceptance."""
import importlib.util
import contextlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('legacy-workspace-gate.py'))
gate = importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)


@contextlib.contextmanager
def renumbered_device():
    """Model the kernel changing mount numbers, leaving filesystem bytes intact."""
    class Observed:
        def __init__(self, value):self.value=value;self.st_dev=value.st_dev+29
        def __getattr__(self, name):return getattr(self.value,name)
        def __getitem__(self, key):return self.st_dev if key==stat.ST_DEV else self.value[key]
    def observed(value):return value if isinstance(value,Observed) else Observed(value)
    class Entry:
        def __init__(self, value):self.value=value
        def __getattr__(self, name):return getattr(self.value,name)
        def stat(self, **kwargs):return observed(self.value.stat(**kwargs))
    class Scan:
        def __init__(self, value):self.value=value
        def __iter__(self):return self
        def __next__(self):return Entry(next(self.value))
        def __enter__(self):self.value.__enter__();return self
        def __exit__(self, *args):return self.value.__exit__(*args)
        def close(self):self.value.close()
    originals={name:getattr(os,name) for name in ('stat','lstat','fstat')}
    paths={name:getattr(Path,name) for name in ('stat','lstat')}
    scandir=os.scandir
    with contextlib.ExitStack() as stack:
        for name,original in originals.items():
            stack.enter_context(patch.object(os,name,side_effect=lambda *a,_call=original,**kw:observed(_call(*a,**kw))))
        for name,original in paths.items():
            stack.enter_context(patch.object(Path,name,lambda *a,_call=original,**kw:observed(_call(*a,**kw))))
        stack.enter_context(patch.object(os,'scandir',side_effect=lambda *a,**kw:Scan(scandir(*a,**kw))))
        yield


class GateWorkflow(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='legacy-gate-test-');self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve();self.sources = self.root / 'sources';self.sources.mkdir()
        self.repo = self.sources / 'repo';self.repo.mkdir();self.vault = self.root / 'vault';self.vault.mkdir(mode=0o700)
        self.git('init', '-q', '-b', 'main');self.git('config', 'user.name', 'fixture');self.git('config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'file').write_text('committed');self.git('add', '.');self.git('commit', '-qm', 'initial')
        self.work = self.sources / 'worker';self.git('worktree', 'add', '-qb', 'worker', str(self.work))
        self.head = self.git('rev-parse', 'HEAD')
        self.tx = dict(record='transaction', sealed=True, session_id='s', agent_id='a', sealed_ts='2026-09-01T10:00:00Z',
                       terminal={'ts':'2026-09-01T11:00:00Z'}, members=[dict(path=str(self.work), repo=str(self.repo), branch='worker', head=self.head)])
        self.records = [dict(event='registered', worktree=str(self.repo), repo=str(self.repo), session_id='gone', session_pid=999999999)]
        history = patch.object(gate.planner.history, 'load_history', return_value=([self.tx], self.records, []))
        history.start();self.addCleanup(history.stop)
        self.manager = gate.LegacyGate(self.vault, require_root=False)
        self.boot = str(uuid.uuid4());self.current_boot = self.boot
        boot = patch.object(self.manager, '_boot', side_effect=lambda:self.current_boot);boot.start();self.addCleanup(boot.stop)
        self.report = gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}}, [self.tx], self.records)
        self.digest = gate.planner.history._digest(self.report)
        self.assertEqual(self.report['repositories'][0]['blockers'], [])

    def git(self, *args):
        return subprocess.check_output(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-C', str(self.repo), *args],
            stderr=subprocess.PIPE, env={'PATH':'/usr/bin:/bin','HOME':'/var/empty','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'}).decode().strip()

    def stage(self):
        return self.manager.stage(self.report, approved_sha256=self.digest)

    def test_roundtrip_requires_later_boot_and_preserves_dirty_staged_and_symlink_bytes(self):
        (self.work / 'file').write_text('staged');subprocess.run(['/usr/bin/git','-C',str(self.work),'add','file'],check=True)
        (self.work / 'file').write_text('working');(self.work / 'untracked').write_bytes(b'private\0bytes')
        (self.work / 'link').symlink_to('../outside');os.chmod(self.work / 'file', 0o751)
        original = (self.work / 'file').stat();holder = open(self.work / 'file', 'ab');self.addCleanup(holder.close)
        result = self.stage();ident = result['id']
        self.assertFalse(self.repo.exists());self.assertFalse(self.work.exists());self.assertFalse(result['boot_cutoff_verified'])
        holder.write(b'-late');holder.flush();holder.close()
        with self.assertRaises(gate.GateError):
            self.manager.restore(ident, approved_sha256=self.digest)
        self.current_boot = str(uuid.uuid4())
        self.assertTrue(self.manager.inspect(ident)['boot_cutoff_verified'])
        self.assertEqual(self.manager.restore(ident, approved_sha256=self.digest)['phase'], 'restored')
        self.assertEqual((self.work/'file').read_bytes(), b'working-late')
        self.assertEqual((self.work/'untracked').read_bytes(), b'private\0bytes')
        self.assertEqual(os.readlink(self.work/'link'), '../outside')
        self.assertEqual(stat.S_IMODE((self.work/'file').stat().st_mode), stat.S_IMODE(original.st_mode))
        self.assertEqual(subprocess.check_output(['/usr/bin/git','-C',str(self.work),'show',':file']), b'staged')
        self.assertEqual(self.git('rev-parse','HEAD'), self.head)

    def test_wrong_authorization_and_live_plan_have_no_side_effects(self):
        with self.assertRaises(gate.GateError):
            self.manager.stage(self.report, approved_sha256='wrong')
        active = gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}}, [self.tx], self.records, active_paths=[str(self.work)])
        with self.assertRaises(gate.GateError):
            self.manager.stage(active, approved_sha256=gate.planner.history._digest(active))
        self.assertEqual(list(self.vault.iterdir()), []);self.assertTrue(self.repo.exists())

    @unittest.skipUnless(gate.sys.platform=='darwin','cross-boot UUID contract is macOS only')
    def test_kernel_device_renumber_preserves_real_uuid_gate_and_restore(self):
        (self.work/'file').write_bytes(b'unique pre-reboot bytes')
        ident=self.stage()['id'];base=self.manager._base(ident)
        before=(base/'metadata.jsonl').read_bytes()
        self.current_boot=str(uuid.uuid4())
        with renumbered_device():
            self.assertTrue(self.manager.inspect(ident)['boot_cutoff_verified'])
            with self.manager.frozen_view(ident,approved_sha256=self.digest):pass
            self.assertEqual(self.manager.restore(ident,approved_sha256=self.digest)['phase'],'restored')
        self.assertEqual((base/'metadata.jsonl').read_bytes(),before,'original approval evidence is never rewritten')
        self.assertEqual((self.work/'file').read_bytes(),b'unique pre-reboot bytes')

    def test_different_filesystem_uuid_and_old_integer_pins_cannot_restore(self):
        ident=self.stage()['id'];base=self.manager._base(ident);self.current_boot=str(uuid.uuid4())
        state=(base/'state.json').read_bytes()
        with patch.object(gate.filesystem,'filesystem_token',return_value='darwin-volume-uuid-v1:'+str(uuid.uuid4())):
            with self.assertRaisesRegex(gate.GateError,'identity changed'):
                self.manager.restore(ident,approved_sha256=self.digest)
        self.assertEqual((base/'state.json').read_bytes(),state)
        entries=[json.loads(line) for line in (base/'metadata.jsonl').read_text().splitlines()]
        for entry in entries:entry['device']=self.vault.stat().st_dev
        (base/'metadata.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in entries))
        with self.assertRaisesRegex(gate.GateError,'identity changed'):
            self.manager.restore(ident,approved_sha256=self.digest)
        self.assertEqual((base/'state.json').read_bytes(),state)

    def test_live_descriptor_on_other_device_or_replaced_inode_is_still_refused(self):
        from types import SimpleNamespace
        info=self.repo.lstat();expected=self.manager._metadata(self.repo)
        self.assertTrue(self.manager._same(info,expected))
        self.assertFalse(self.manager._same(SimpleNamespace(st_dev=info.st_dev+1,st_ino=info.st_ino),expected))
        self.assertFalse(self.manager._same(SimpleNamespace(st_dev=info.st_dev,st_ino=info.st_ino+1),expected))

    def test_production_authority_and_unreadable_boot_fail_before_reservation(self):
        with patch.object(gate.os,'geteuid',return_value=501),self.assertRaises(gate.GateError):
            gate.LegacyGate(self.vault)
        with patch.object(self.manager,'_boot',side_effect=gate.GateError('unreadable kernel identity')),self.assertRaises(gate.GateError):
            self.stage()
        self.assertEqual(list(self.vault.iterdir()),[]);self.assertTrue(self.repo.exists())

    def test_changed_repository_pin_is_refused_before_mutation(self):
        moved = self.sources / 'preserved';self.repo.rename(moved);self.repo.mkdir()
        with self.assertRaises(gate.GateError):self.stage()
        self.assertEqual(list(self.vault.iterdir()), []);self.assertTrue((moved/'file').exists())

    def test_existing_hardlink_is_refused_before_initial_mutation(self):
        os.link(self.work/'file', self.root/'outside-hardlink')
        with self.assertRaises(gate.GateError):self.stage()
        self.assertEqual(list(self.vault.iterdir()),[]);self.assertTrue(self.repo.exists());self.assertTrue(self.work.exists())

    def test_late_hardlink_retains_partial_gate_and_allows_only_later_boot_admin_restore(self):
        original=self.manager._protect_tree;injected=[]
        def changed(*args):
            if not injected:
                injected.append(True);os.link(self.work/'file',self.root/'outside-hardlink')
            return original(*args)
        with patch.object(self.manager,'_protect_tree',side_effect=changed),self.assertRaises(gate.GateError):self.stage()
        bases = [p for p in self.vault.iterdir() if p.is_dir()];self.assertEqual(len(bases),1)
        self.assertEqual(self.manager._load(bases[0])['phase'], 'staging')
        self.assertEqual((self.root/'outside-hardlink').read_text(),'committed')
        with self.assertRaises(gate.GateError):self.manager.restore(bases[0].name,approved_sha256=self.digest)
        self.current_boot = str(uuid.uuid4())
        with self.assertRaises(gate.GateError):
            with self.manager.frozen_view(bases[0].name,approved_sha256=self.digest):pass
        self.assertEqual(self.manager.restore(bases[0].name,approved_sha256=self.digest)['phase'],'restored')
        self.assertEqual((self.work/'file').read_text(),'committed');self.assertEqual((self.work/'file').stat().st_nlink,2)
        self.assertEqual(self.git('rev-parse','HEAD'),self.head)

    def test_partial_restore_preserves_unmoved_root_and_newly_linked_journaled_file(self):
        original=self.manager._apply;injected=[]
        def changed(path, metadata, **kwargs):
            if not kwargs.get('restore') and path.name=='file' and self.vault in path.parents and not injected:
                injected.append(True);os.link(path,self.root/'outside-hardlink')
            return original(path,metadata,**kwargs)
        with patch.object(self.manager,'_apply',side_effect=changed),self.assertRaises(gate.GateError):self.stage()
        ident=next(self.vault.iterdir()).name
        self.assertTrue(self.work.exists());self.assertFalse(self.repo.exists())
        self.current_boot=str(uuid.uuid4());self.manager.restore(ident,approved_sha256=self.digest)
        self.assertEqual((self.repo/'file').stat().st_ino,(self.root/'outside-hardlink').stat().st_ino)
        self.assertEqual(self.git('rev-parse','HEAD'),self.head)

    def test_crash_after_rename_recovers_exact_root_without_duplicate(self):
        original = self.manager._protect_tree;calls=[]
        def failure(*args):
            if not calls:calls.append(True);raise RuntimeError('injected after rename')
            return original(*args)
        with patch.object(self.manager,'_protect_tree',side_effect=failure), self.assertRaises(RuntimeError):self.stage()
        ident = next(self.vault.iterdir()).name
        self.assertEqual(self.manager.resume(ident)['phase'],'gated')
        self.assertEqual(len(list(self.vault.iterdir())),1)
        self.current_boot = str(uuid.uuid4());self.manager.restore(ident,approved_sha256=self.digest)
        self.assertEqual(self.git('rev-parse','HEAD'),self.head)

    def test_recreated_destination_is_never_overwritten(self):
        ident=self.stage()['id'];self.current_boot=str(uuid.uuid4());self.repo.mkdir();(self.repo/'new').write_text('new work')
        with self.assertRaises(gate.GateError):self.manager.restore(ident,approved_sha256=self.digest)
        self.assertEqual((self.repo/'new').read_text(),'new work')
        self.assertEqual(self.manager.inspect(ident)['phase'],'gated')

    def test_unknown_recorded_boot_cannot_authorize_restore(self):
        ident=self.stage()['id'];base=self.manager._base(ident);record=self.manager._load(base)
        record['gated_boot_id']='unknown';self.manager._save(base,record);self.current_boot=str(uuid.uuid4())
        with self.assertRaises((gate.GateError,ValueError)):self.manager.restore(ident,approved_sha256=self.digest)

    def test_frozen_view_requires_cutoff_and_pins_the_approved_plan(self):
        ident=self.stage()['id']
        with self.assertRaises(gate.GateError):
            with self.manager.frozen_view(ident,approved_sha256=self.digest):pass

        self.current_boot=str(uuid.uuid4())
        with self.manager.frozen_view(ident,approved_sha256=self.digest) as view:
            self.assertFalse(view['deletion_authorized'])
            self.assertEqual(view['plan'],self.report)
            self.assertEqual({row['source'] for row in view['roots']},{str(self.repo),str(self.work)})
            self.assertEqual((Path(view['roots'][0]['held_path'])/'file').read_text(),'committed')
        (self.manager._base(ident)/'plan.json').write_text('{}')
        with self.assertRaises(gate.GateError):
            with self.manager.frozen_view(ident,approved_sha256=self.digest):pass

    def test_native_nested_checkout_moves_once_and_restores_registered_paths(self):
        native=self.repo/'.claude/worktrees/native';native.parent.mkdir(parents=True)
        self.git('worktree','add','-qb','native',str(native))
        self.tx['members'].append(dict(path=str(native),repo=str(self.repo),branch='native',head=self.head))
        self.report=gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},[self.tx],self.records)
        self.digest=gate.planner.history._digest(self.report)
        result=self.stage();self.current_boot=str(uuid.uuid4())
        with self.manager.frozen_view(result['id'],approved_sha256=self.digest) as view:
            self.assertEqual(len(view['roots']),2)
            target=next(g for g in view['plan']['repositories'][0]['gate_paths'] if g['path']==str(native))
            self.assertEqual(target['relative_path'],'.claude/worktrees/native')
            self.assertEqual((Path(view['roots'][0]['held_path'])/target['relative_path']/'file').read_text(),'committed')
        self.manager.restore(result['id'],approved_sha256=self.digest)
        self.assertEqual(subprocess.check_output(['/usr/bin/git','-C',str(native),'rev-parse','HEAD']).decode().strip(),self.head)

    def test_new_sibling_after_parent_scope_review_refuses_before_mutation(self):
        (self.sources/'new-active-sibling').mkdir()
        with self.assertRaises(gate.GateError):self.stage()
        self.assertEqual(list(self.vault.iterdir()),[]);self.assertTrue(self.repo.exists())

    def test_set_id_parent_mode_is_refused_before_mutation(self):
        os.chmod(self.sources,0o2755)
        self.report=gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},[self.tx],self.records)
        self.digest=gate.planner.history._digest(self.report)
        with self.assertRaises(gate.GateError):self.stage()
        self.assertEqual(list(self.vault.iterdir()),[]);self.assertTrue(self.repo.exists())

    @unittest.skipUnless(gate.sys.platform=='darwin','actual macOS ACL control')
    def test_parent_acl_refuses_before_any_namespace_mutation(self):
        import pwd
        subprocess.run(['/bin/chmod','+a','user:'+pwd.getpwuid(os.getuid()).pw_name+' allow write',str(self.sources)],check=True)
        try:
            with self.assertRaises(gate.GateError):self.stage()
            self.assertTrue(self.repo.exists());self.assertTrue(self.work.exists());self.assertEqual(list(self.vault.iterdir()),[])
        finally:
            subprocess.run(['/bin/chmod','-N',str(self.sources)],check=True)

    @unittest.skipUnless(gate.sys.platform=='darwin','actual macOS ACL control')
    def test_production_constructor_checks_vault_ancestor_acl(self):
        import pwd
        subprocess.run(['/bin/chmod','+a','user:'+pwd.getpwuid(os.getuid()).pw_name+' allow write',str(self.root)],check=True)
        account=pwd.getpwuid(os.getuid())
        context=dict(version=1,owner_uid=os.getuid(),owner_gid=account.pw_gid,
                     owner_home=os.path.normpath(account.pw_dir),
                     transactions=str(self.root/'transactions'),ledger=str(self.root/'ledger.jsonl'))
        original=Path.lstat
        def ownership_only(path):
            info=original(path)
            class Ownership:
                st_mode=info.st_mode & ~0o022
                st_uid=0
                def __getattr__(self, name):return getattr(info,name)
            return Ownership()
        try:
            # Root ownership is simulated only to reach the production ancestry
            # check. ACL bytes and its rejection are actual macOS behavior.
            with patch.object(gate.os,'geteuid',return_value=0),patch.object(Path,'lstat',ownership_only),self.assertRaisesRegex(gate.GateError,'ACL'):
                gate.LegacyGate(self.vault,inspection_context=context)
        finally:
            subprocess.run(['/bin/chmod','-N',str(self.root)],check=True)

    def test_metadata_journal_truncation_holds_partial_gate(self):
        original=self.manager._protect_tree
        with patch.object(self.manager,'_protect_tree',side_effect=RuntimeError('stop')),self.assertRaises(RuntimeError):self.stage()
        base=next(self.vault.iterdir());(base/'metadata.jsonl').write_bytes(b'{"partial":')
        with self.assertRaises(gate.GateError):self.manager.resume(base.name)
        self.assertEqual(self.manager._load(base)['phase'],'staging')


if __name__=='__main__':unittest.main(verbosity=2)
