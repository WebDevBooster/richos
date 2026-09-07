#!/usr/bin/env python3
"""Pinned root/owner operator-authority acceptance in fresh fixture-only storage.

Byte-identical installed runtime is mirrored under a fresh protected namespace
solely to select a fixture policy. No gate, boot override, service or activation.
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



def mirror_runtime(release, destination, policy):
    """Only fresh root-controlled code directories; no source substitutions."""
    require(destination.parent==INSTALL and re.fullmatch('operator-runtime-[0-9a-f]{32}',destination.name),
            'fixed fresh mirror namespace required')
    protected(destination.parent,False)
    destination.mkdir(mode=0o755);destination.chmod(0o755)
    releases=destination/'releases';releases.mkdir(mode=0o755);releases.chmod(0o755)
    target=releases/release.name;target.mkdir(mode=0o755);target.chmod(0o755)
    manifest=json.loads((release/'manifest.json').read_bytes())
    for name in [*manifest,'manifest.json']:
        raw=(release/name).read_bytes()
        if name!='manifest.json':require(hashlib.sha256(raw).hexdigest()==manifest[name],'source runtime changed')
        path=target/name
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o644)
        os.fchmod(fd,0o644)
        with os.fdopen(fd,'wb') as stream:stream.write(raw);stream.flush();os.fsync(stream.fileno())
    fd=os.open(destination/'policy.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as stream:json.dump(policy,stream,sort_keys=True);stream.flush();os.fsync(stream.fileno())
    require(load(target,'managed-workspace-broker').validate_runtime()==target,'mirrored runtime validation failed')
    return target


def run(args):
    release,policy,owner=runtime(args)
    support=load(release,'legacy-workspace-acceptance');driver=support.Acceptance()
    fixture=driver.prepare(owner[0]);private=Path(fixture['private']);active=Path(fixture['active'])
    mirror=INSTALL/('operator-runtime-'+uuid.uuid4().hex)
    result=dict(passed=False,tests_cutoff=False,activated=False,staged=False,checks=[],fixture_cleanup_complete=False,
                private_root=str(private),active_root=str(active),runtime_mirror=str(mirror),
                source_release=str(release),manifest_sha256=args.manifest_sha256,owner_uid=owner[0])
    pins={str(private):support.pin(private),str(active):support.pin(active)}
    def check(name,condition):
        result['checks'].append(dict(name=name,passed=bool(condition)));require(condition,name)
    try:
        with driver.existing(fixture['id']):
            # Remove only the fixture's invented terminal proof, retaining its
            # exact bytes privately. Actual user history is never selected.
            history=active/'history';saved=private/'original-fixture-history';saved.mkdir(mode=0o700)
            tx=history/'transactions'/fixture['id']/'fixture-worker.json'
            require(tx.is_file(),'exact synthetic fixture transaction missing')
            tx.rename(saved/'transaction.json')
            ledger=history/'ledger.jsonl';(saved/'ledger.jsonl').write_bytes(ledger.read_bytes());ledger.write_bytes(b'')
            copied=mirror_runtime(release,mirror,fixture['fixture_policy']);pins[str(mirror)]=support.pin(mirror)
            check('installed-runtime-mirror-is-byte-identical',all((copied/name).read_bytes()==(release/name).read_bytes()
                  for name in [*json.loads((release/'manifest.json').read_bytes()),'manifest.json']))
            common=['--owner-uid',str(owner[0]),'--transactions',fixture['inspection_context']['transactions'],
                    '--ledger',fixture['inspection_context']['ledger']]
            def cli(operation,extra=(),*,success=True):
                value=subprocess.run([PYTHON,'-I','-S','-B',str(copied/'legacy-workspace-admin.py'),operation,*common,*extra],
                                     cwd='/',env=ENV,capture_output=True,timeout=120)
                if success:
                    require(value.returncode==0,'root operator CLI failed: '+value.stderr.decode(errors='replace')[:2048])
                    return json.loads(value.stdout)
                require(value.returncode!=0,'invalid operator CLI request passed')
                return value.stderr.decode(errors='replace')
            base=cli('plan',['--repository','fixture']);row=base['repositories'][0]
            check('unknown-owner-is-real-unattested-baseline',len(row['removal_candidates'])==0 and
                  set(row['blockers'])=={'unknown-owner:'+str(active/'sources'/name) for name in ('repo','worker')})
            operator=load(copied,'legacy-workspace-operator')
            decisions=[operator.decision_record(row,target,'retain' if target['kind']=='canonical-checkout' else 'remove') for target in row['gate_paths']]
            basefile=private/'base-report.json';support.save(basefile,base)
            decisionfile=private/'decisions.json';support.save(decisionfile,decisions)
            attested=cli('attest-maintenance',['--report',str(basefile),'--approved-sha256',operator.digest(base),
                         '--decisions',str(decisionfile),'--authorization','Explicit isolated fixture maintenance authorization'])
            descriptor=attested['operator_attestation'];path=Path(descriptor['path']);original=path.read_bytes()
            check('root-stores-exact-protected-operator-authority',path.parent==private/'legacy-authorizations' and
                  path.stat().st_uid==0 and stat.S_IMODE(path.stat().st_mode)==0o600 and operator.digest(json.loads(original))==descriptor['sha256'])
            extra=['--repository','fixture','--operator-attestation',str(path),'--operator-attestation-sha256',descriptor['sha256']]
            current=cli('plan',extra);candidate=current['repositories'][0]['removal_candidates'][0]
            check('actual-owner-helper-applies-explicit-provenance',current==attested['report'] and candidate['path']==str(active/'sources/worker')
                  and candidate.get('provenance')=='explicit-operator-maintenance' and 'agent_id' not in candidate and 'session_id' not in candidate
                  and current['history_sha256']==base['history_sha256'])
            denied=driver.child(fixture,[PYTHON,'-I','-S','-B','-c',"import pathlib,sys;pathlib.Path(sys.argv[1]).write_text('forged')",str(path)])
            check('actual-owner-cannot-change-root-attestation',denied.returncode!=0 and b'PermissionError' in denied.stderr and path.read_bytes()==original)
            changed=json.loads(original);changed['authorization']='changed';support.save(path,changed)
            try:check('tampered-attestation-is-refused-before-owner-inspection','hash mismatch' in cli('plan',extra,success=False))
            finally:path.write_bytes(original)
            path.chmod(0o644)
            try:check('nonprivate-attestation-mode-is-refused','mode' in cli('plan',extra,success=False))
            finally:path.chmod(0o600)
            # A new sibling is real report drift, without touching the source HEAD.
            (active/'sources/new-independent').mkdir()
            check('stale-parent-scope-is-refused','baseline' in cli('plan',extra,success=False))
            (active/'sources/new-independent').rmdir()
            check('no-terminal-history-was-fabricated',not tx.exists() and ledger.read_bytes()==b'' and (saved/'transaction.json').exists())
            check('no-gate-or-service-was-created',not (private/'legacy-gates').exists() and not (active/'broker.sock').exists())
            check('canonical-and-worker-bytes-remain',driver.git(fixture,active/'sources/repo','rev-parse','HEAD').decode().strip()==fixture['expected']['head']
                  and (active/'sources/worker/file').read_bytes()==b'working')
            result['attestation']=descriptor;result['approved_report_sha256']=operator.digest(current)
            result['passed']=True
    except Exception as error:result['error']=str(error)
    finally:
        try:support.save(private/'operator-acceptance.json',result)
        except Exception as error:result.update(passed=False,receipt_error=str(error))
        # There are no background workers, images, mounted gates or services.
        # Delete only these newly minted test namespaces after all synchronous
        # fixture children exited. A failure retains evidence for inspection.
        if result['passed']:
            try:
                require(all(support.pin(Path(name))==pin for name,pin in pins.items()),'fixture cleanup root replaced')
                for path in (active,private,mirror):shutil.rmtree(path)
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
