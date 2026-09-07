#!/usr/bin/env python3
"""Pinned root/owner storage-gate acceptance in fresh fixture-only storage.

Only controller-created tiny repositories are gated. An instance-local synthetic
boot permits recovery-path testing; this is NOT evidence of an actual boot cutoff.
No production gate, service or activation is changed.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import uuid

PYTHON='/Library/Developer/CommandLineTools/usr/bin/python3'
INSTALL=Path('/Library/Application Support/RichOS/workspace-broker')
ENV=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',HOME='/var/empty',LC_ALL='C',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')


def require(condition,message):
    if not condition:raise RuntimeError(message)


def protected(path, regular=None):
    """Bootstrap protection before importing even the pinned broker module."""
    path = Path(path).resolve(strict=True)
    for item in (path, *path.parents):
        info = item.lstat()
        require(info.st_uid == 0 and not info.st_mode & 0o022, 'unprotected bootstrap path: ' + str(item))
        require(item == path or stat.S_ISDIR(info.st_mode), 'non-directory ancestor')
        result = subprocess.run(['/bin/ls', '-lde', str(item)], env=ENV, capture_output=True,
                                text=True, timeout=5)
        lines = result.stdout.splitlines()
        require(result.returncode == 0 and lines, 'ACL metadata unavailable')
        require(all(re.fullmatch(r'\s*\d+: .+ deny [A-Za-z_,]+', line) for line in lines[1:]),
                'unsafe bootstrap ACL')
    require(regular is None or (stat.S_ISREG(path.stat().st_mode) if regular else path.is_dir()),
            'wrong protected path type')
    return path


def load(release, name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), release / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def runtime(args):
    require(sys.platform == 'darwin' and os.geteuid() == 0 and sys.flags.isolated and sys.flags.no_site,
            'root macOS CLTools Python -I -S required')
    require(Path(sys.executable).resolve() == Path(PYTHON).resolve(), 'wrong actual interpreter')
    protected(sys.executable, True)
    for entry in sys.path:
        require(entry and Path(entry).is_absolute(), 'relative interpreter path')
        path = Path(entry)
        while not path.exists():
            path = path.parent
        protected(path)
    protected(__file__, True)
    release = protected(args.release, False)
    require(release.parent == INSTALL / 'releases' and re.fullmatch('[0-9a-f]{64}', release.name),
            'explicit installed release required')
    manifest_bytes = protected(release / 'manifest.json', True).read_bytes()
    require(re.fullmatch('[0-9a-f]{64}', args.manifest_sha256) and
            hashlib.sha256(manifest_bytes).hexdigest() == args.manifest_sha256, 'manifest pin mismatch')
    manifest = json.loads(manifest_bytes)
    broker_file = protected(release / 'managed-workspace-broker.py', True)
    require(hashlib.sha256(broker_file.read_bytes()).hexdigest() == manifest['managed-workspace-broker.py'],
            'bootstrap broker hash mismatch')
    broker = load(release, 'managed-workspace-broker')
    require(broker.validate_runtime() == release, 'runtime release mismatch')
    policy = broker.validate_policy(json.loads(broker.protected_path(INSTALL / 'policy.json', regular=True).read_text()))
    require(str(args.owner_uid) in policy['owners'], 'owner must be approved in installed policy')
    return release, policy, (args.owner_uid, policy['owners'][str(args.owner_uid)]['gid'])



CHECKS=(
    'actual-owner-hardlink-and-benign-flags-originals',
    'external-alias-refused-before-mutation',
    'external-alias-original-metadata-preserved',
    'partial-protection-crash-is-recoverable',
    'all-aliases-have-durable-owner-preimages',
    'replay-protects-every-alias-as-root',
    'actual-owner-cannot-open-held-bytes',
    'actual-same-boot-frozen-view-refused',
    'capture-preserves-hardlink-topology-and-flags',
    'actual-owner-metadata-and-links-restored',
    'original-real-boot-evidence-unchanged',
    'controller-only-gate-restored-without-service-activation',
)
SETUP_LINKS = "import os,pathlib,sys; p=pathlib.Path(sys.argv[1]); a=p/'linked-a'; a.write_bytes(b'linked private bytes'); os.chmod(a,0o751); os.chflags(a,0x8040); os.link(a,p/'linked-b')"


def run(args):
    release,policy,owner=runtime(args)
    support=load(release,'legacy-workspace-acceptance');driver=support.Acceptance()
    fixture=driver.prepare(owner[0]);private=Path(fixture['private']);active=Path(fixture['active'])
    result=dict(passed=False,tests_cutoff=False,activated=False,controller_only=True,checks=[],
                fixture_cleanup_complete=False,private_root=str(private),active_root=str(active),
                source_release=str(release),manifest_sha256=args.manifest_sha256,owner_uid=owner[0],
                seam='instance-local LegacyGate._boot only after real same-boot refusal; no kernel boot or installed source mutation')
    pins={str(private):support.pin(private),str(active):support.pin(active)}
    def check(name,condition):
        require(name in CHECKS,'unrecognized acceptance check')
        result['checks'].append(dict(name=name,passed=bool(condition)));require(condition,name)
    manager=None;ident=None
    try:
        with driver.existing(fixture['id']):
            repo=active/'sources/repo';work=active/'sources/worker'
            child=driver.child(fixture,[PYTHON,'-I','-S','-B','-c',SETUP_LINKS,str(work)])
            require(child.returncode==0,'owner link setup failed: '+child.stderr.decode(errors='replace')[:1024])
            first,second=work/'linked-a',work/'linked-b';before=first.lstat()
            check(CHECKS[0],before.st_uid==owner[0] and before.st_gid==owner[1] and before.st_ino==second.lstat().st_ino
                  and before.st_nlink==2 and before.st_flags==0x8040 and stat.S_IMODE(before.st_mode)==0o751)
            vault=private/'controller-only-gates';vault.mkdir(mode=0o700)
            manager=driver.gate.LegacyGate(vault,inspection_context=fixture['inspection_context'])
            actual_boot=manager._boot()
            report=driver.gate.owner_report({'repositories':{'fixture':{'path':str(repo)}}},fixture['inspection_context'])
            driver.validate_report(report,active/'sources');approved=driver.gate.planner.history._digest(report)
            # A third alias outside every approved gate root must not cause
            # even a temporary ownership change to that external name.
            outside=active/'external-alias';os.link(first,outside)
            refused=False
            try:manager.stage(report,approved_sha256=approved)
            except driver.gate.GateError as error:refused='not closed' in str(error)
            check(CHECKS[1],refused and not list(vault.iterdir()) and repo.is_dir() and work.is_dir())
            now=outside.lstat()
            check(CHECKS[2],(now.st_uid,now.st_gid,stat.S_IMODE(now.st_mode),now.st_flags)==
                  (owner[0],owner[1],0o751,0x8040) and outside.read_bytes()==b'linked private bytes')
            outside.unlink()
            original=manager._apply;injected=[]
            def crash(path,row,**kwargs):
                original(path,row,**kwargs)
                if path.name=='linked-a' and not kwargs.get('restore') and not injected:
                    injected.append(True);raise RuntimeError('storage acceptance crash after first alias')
            manager._apply=crash
            try:
                manager.stage(report,approved_sha256=approved)
                raise RuntimeError('injected first-alias crash did not fire')
            except RuntimeError as error:
                require(str(error)=='storage acceptance crash after first alias','unexpected staging failure: '+str(error))
            finally:manager._apply=original
            bases=list(vault.iterdir());require(len(bases)==1,'unexpected gate count')
            base=bases[0];ident=base.name;result.update(gate_id=ident,gate_sha256=approved)
            check(CHECKS[3],bool(injected) and manager._load(base)['phase']=='staging')
            rows=[row for row in manager._entries(base).values() if row['inode']==before.st_ino]
            check(CHECKS[4],len(rows)==2 and all((row['uid'],row['gid'],row['mode'],row['flags'],row['nlink'])==
                  (owner[0],owner[1],0o751,0x8040,2) for row in rows))
            manager.resume(ident);held=[base/row['relative'] for row in rows]
            check(CHECKS[5],all(path.lstat().st_uid==0 and path.lstat().st_gid==os.getegid()
                  and stat.S_IMODE(path.lstat().st_mode)==0o600 and path.lstat().st_flags==0x8040 for path in held))
            denied=driver.child(fixture,[PYTHON,'-I','-S','-B','-c',"import pathlib,sys;pathlib.Path(sys.argv[1]).read_bytes()",str(held[0])])
            check(CHECKS[6],denied.returncode!=0 and b'PermissionError' in denied.stderr)
            refused=False
            try:
                with manager.frozen_view(ident,approved_sha256=approved):pass
            except driver.gate.GateError:refused=True
            check(CHECKS[7],refused and manager._boot()==actual_boot)
            synthetic=str(uuid.uuid4());require(synthetic!=actual_boot,'synthetic UUID collision')
            manager._boot=lambda:synthetic
            try:
                scratch=base/'storage-capture';scratch.mkdir(mode=0o700)
                captured=driver.job.capture.prepare(manager,ident,approved_gate_sha256=approved,repo_alias='fixture',
                    candidate_path=str(work),scratch_root=scratch,trusted_git=driver.job.shadow.TRUSTED_GIT)
                directory=Path(captured['artifact_path']);manifest=json.loads((directory/'manifest.json').read_text())
                driver.job.capture._verify_archive(directory/'recovery.tar.gz',manifest)
                a,b=manifest['worktree/linked-a'],manifest['worktree/linked-b']
                check(CHECKS[8],a['hardlink_group']==b['hardlink_group'] and b['hardlink_to']=='worktree/linked-a'
                      and a['flags']==b['flags']==0x8040 and a['uid']==b['uid']==owner[0])
                manager.restore(ident,approved_sha256=approved)
            finally:del manager.__dict__['_boot']
            restored=first.lstat()
            owner_read=driver.child(fixture,[PYTHON,'-I','-S','-B','-c',"import pathlib,sys;assert pathlib.Path(sys.argv[1]).read_bytes()==b'linked private bytes'",str(first)])
            check(CHECKS[9],owner_read.returncode==0 and restored.st_ino==second.lstat().st_ino==before.st_ino
                  and restored.st_nlink==2 and all((p.lstat().st_uid,p.lstat().st_gid,stat.S_IMODE(p.lstat().st_mode),p.lstat().st_flags)==
                  (owner[0],owner[1],0o751,0x8040) for p in (first,second)))
            check(CHECKS[10],manager._boot()==actual_boot and manager._load(base)['gated_boot_id']==actual_boot)
            check(CHECKS[11],manager._load(base)['phase']=='restored' and not (private/'legacy-gates').exists())
            result['passed']=len(result['checks'])==len(CHECKS) and all(row['passed'] for row in result['checks'])
    except Exception as error:result['error']=str(error)
    finally:
        try:support.save(private/'storage-acceptance.json',result)
        except Exception as error:result.update(passed=False,receipt_error=str(error))
        if result['passed']:
            try:
                require(manager is not None and ident is not None and manager._load(manager._base(ident))['phase']=='restored','gate is not restored')
                require(all(support.pin(Path(name))==pin for name,pin in pins.items()),'fixture cleanup root replaced')
                for path in (active,private):shutil.rmtree(path)
                result['fixture_cleanup_complete']=True
            except Exception as error:result.update(passed=False,cleanup_error=str(error))
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release',required=True);parser.add_argument('--manifest-sha256',required=True)
    parser.add_argument('--owner-uid',required=True,type=int);args=parser.parse_args()
    result=run(args);print(json.dumps(result,sort_keys=True));return 0 if result['passed'] else 2


if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception as error:print(json.dumps(dict(passed=False,error=str(error),tests_cutoff=False)));raise SystemExit(2)
