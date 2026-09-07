#!/usr/bin/env python3
"""Installed orphan/locked retirement integration, explicitly NOT cutoff acceptance.

An external pinned controller invokes unchanged installed modules. Only its own
LegacyGate instance receives a synthetic later-boot observation, after actual
same-boot refusal and owner access exclusion are checked. Fixture journals are
kept under controller-only-gates, never a service-discovered legacy-gates root.
No service, activation, reboot, existing-gate input or fixture cleanup API exists.
"""
import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile
import uuid

PYTHON = '/Library/Developer/CommandLineTools/usr/bin/python3'
INSTALL = Path('/Library/Application Support/RichOS/workspace-broker')
ENV = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME='/var/empty', LC_ALL='C',
           GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
CASES = ('locked', 'orphan', 'orphan-recreated')

def require(condition, message):
    if not condition:
        raise RuntimeError(message)


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



def fixture_setup(original, case):
    require(case in CASES, 'unknown fixed fixture case')
    marker = 'sys.stdin.readline()'
    require(original.count(marker) == 1, 'installed fixture setup changed')
    action = "git(repo,'worktree','lock','--reason','fixture terminal lock',str(work))"
    if case != 'locked':
        action = "import shutil;shutil.rmtree(work)"
    # The installed fixture already fsyncs and reports the original index hash.
    # Modify only freshly created fixture storage before the owner child exits.
    return original.replace(marker, action+'\n'+marker)


def validate_report(report, sources, case):
    require(case in CASES, 'unknown case')
    require(not report.get('errors') and len(report.get('repositories', [])) == 1,
            'fixture inventory incomplete')
    row = report['repositories'][0]
    require(row['alias'] == 'fixture' and row['inventory_complete'] and not row['blockers'],
            'fixture storage or terminal ownership blocked')
    require({r['path'] for r in row['gate_paths']} == {str(sources/'repo'), str(sources/'worker')},
            'unexpected fixture scope')
    require(len(row['removal_candidates']) == 1 and row['removal_candidates'][0]['path'] == str(sources/'worker'),
            'exact single terminal fixture candidate required')
    target = next(r for r in row['gate_paths'] if r['path'] == str(sources/'worker'))
    expected = 'registered-linked-worktree' if case == 'locked' else 'orphan-registration'
    require(target['kind'] == expected, 'wrong fixture candidate kind')
    require({r['path'] for r in row['temporary_parent_gates']} == {str(sources)},
            'unexpected parent downtime scope')
    if case == 'locked':
        require(target.get('registry_flags', {}).get('locked') == 'fixture terminal lock',
                'fixture registration is not locked')
    else:
        require(target['identity'].get('state') == 'absent', 'missing fixture is not explicitly absent')
    return target


@contextlib.contextmanager
def controller_boot(gate, *, actual_boot, synthetic_boot):
    """Only this in-process object observes the seam. No system/module patch."""
    require(gate._boot() == actual_boot and actual_boot != synthetic_boot,
            'controller cannot substitute an unknown or matching boot')
    had_override = '_boot' in gate.__dict__
    previous = gate.__dict__.get('_boot')
    gate._boot = lambda: synthetic_boot
    try:
        yield
    finally:
        if had_override:gate._boot = previous
        else:del gate.__dict__['_boot']


def selected(record, target, ident):
    candidate = dict(repo_alias='fixture', path=target['path'], identity=target['identity'],
                     git_admin_path=target['git_directory']['path'], head=record['expected']['head'], kind=target['kind'])
    return dict(version=1, gate_id=ident, gate_sha256=record['plan_sha256'], approval_kind='exact-legacy-job',
                restore=True, candidates=[candidate], branches=[dict(repo_alias='fixture', ref='refs/heads/worker',
                tip=record['expected']['head'], integration_ref='refs/heads/main', integration_tip=record['expected']['head'])])


def verify_archive(driver, record, base, case):
    job = driver.job._read(base)
    require(len(job['captures']) == 1, 'unexpected capture count')
    artifact = Path(job['captures'][0]['path'])
    require(artifact.is_relative_to(base/'job-scratch'), 'capture escaped fixture scratch')
    driver.runtime.protected_path(artifact, regular=False)
    receipt = json.loads((artifact/'receipt.json').read_text())
    manifest = json.loads((artifact/'manifest.json').read_text())
    require(driver.job.shadow.digest(manifest) == receipt['manifest_sha256'], 'archive manifest changed')
    driver.job.capture._verify_archive(artifact/'recovery.tar.gz', manifest)
    kind = 'full-worktree' if case == 'locked' else 'orphan-admin-only'
    require(receipt.get('capture_kind', 'full-worktree') == kind, 'archive source kind changed')
    if case != 'locked':
        require(receipt.get('working_tree_bytes_present') is False, 'orphan receipt claims absent working bytes')
        require(all(name == 'git-admin' or name.startswith('git-admin/') for name in manifest),
                'orphan archive invented a working tree')
    with tarfile.open(artifact/'recovery.tar.gz', 'r:gz') as archive:
        require(hashlib.sha256(archive.extractfile('git-admin/index').read()).hexdigest() == record['expected']['index_sha256'],
                'original staged index bytes changed')
        if case == 'locked':
            require(archive.extractfile('git-admin/locked').read().strip() == b'fixture terminal lock', 'lock bytes missing')
            for name, contents in {'worktree/file':b'working', 'worktree/untracked':b'untracked\0unique',
                                   'worktree/cache/unique':b'cache-tagged-unique'}.items():
                require(archive.extractfile(name).read() == contents, 'original working bytes changed: '+name)
            require(archive.getmember('worktree/link').linkname == 'untracked', 'original symlink changed')
    return receipt


def verify_restored(driver, support, record, active, gate, base, case):
    repo = active/'sources/repo';work = active/'sources/worker'
    row = record['report']['repositories'][0]
    support.restored_pin(repo, next(r['identity'] for r in row['gate_paths'] if r['path'] == str(repo)))
    support.restored_pin(repo.parent, next(r['identity'] for r in row['temporary_parent_gates'] if r['path'] == str(repo.parent)))
    require((repo/'file').read_bytes() == b'committed', 'canonical working bytes changed')
    require(gate._load(base)['phase'] == 'restored', 'fixture gate not restored')
    require(not os.path.lexists(work), 'retired working namespace remains')
    require(not os.path.lexists(record['selection']['candidates'][0]['git_admin_path']), 'selected registration remains')
    require(driver.git(record,repo,'branch','--list','worker') == b'', 'terminal worker branch remains')
    require(driver.git(record,repo,'rev-parse','main').decode().strip() == record['expected']['head'], 'canonical tip changed')
    receipt = verify_archive(driver,record,base,case)
    control = driver.git(record,repo,'hash-object','-w','--stdin',input=b'orphan-unpinned-gc-control').decode().strip()
    driver.git(record,repo,'reflog','expire','--expire=now','--all');driver.git(record,repo,'gc','--prune=now')
    require(driver.git(record,repo,'cat-file','-e',control,check=False).returncode != 0, 'GC negative control survived')
    for dependency in receipt['dependencies']['required_objects']:
        driver.git(record,repo,'cat-file','-e',dependency['oid'])
    require(driver.git(record,repo,'cat-file','blob',record['expected']['staged_oid']) == b'staged-only',
            'staged-only bytes were lost after registration removal and immediate GC')
    return receipt


def run_case(support, uid, case):
    driver = support.Acceptance()
    original = support.SETUP
    driver.validate_report = lambda report,sources:validate_report(report,sources,case)
    try:
        support.SETUP = fixture_setup(original,case)
        record = driver.prepare(uid)
    finally:
        support.SETUP = original
    private = Path(record['private']);active = Path(record['active'])
    record.update(tests_cutoff=False, controller_only=True, production_service_eligible=False,
                  synthetic_boot_uuid=str(uuid.uuid4()), phase='controller-prepared', case=case,
                  seam='instance-local LegacyGate._boot only during direct controller advancement; no system boot or installed code mutation',
                  cleanup_complete=False, fixture_retained=True)
    support.save(private/'receipt.json',record)
    try:
        with driver.existing(record['id']) as (_,_,current):
            require(current == record, 'fixture receipt changed')
            target = validate_report(record['report'],active/'sources',case)
            vault = private/'controller-only-gates';vault.mkdir(mode=0o700)
            gate = driver.gate.LegacyGate(vault,inspection_context=record['inspection_context'])
            actual_boot = gate._boot()
            require(actual_boot == record['prepared_boot'], 'real boot changed during fixture setup')
            result = gate.stage(record['report'],approved_sha256=record['plan_sha256'])
            ident = result['id'];base = gate._base(ident);scratch = base/'job-scratch';scratch.mkdir(mode=0o700)
            record.update(gate_id=ident,gate_vault=str(vault),selection=selected(record,target,ident),phase='controller-gated')
            record['selection_sha256'] = driver.job.shadow.digest(record['selection'])
            support.save(private/'receipt.json',record)
            driver.job.arm(gate,record['selection'],approved_selection_sha256=record['selection_sha256'],scratch_root=scratch)
            require(driver.job.advance(gate,ident,scratch_root=scratch)['state'] == 'waiting-for-boot', 'real same-boot job advanced')
            require(not list(scratch.iterdir()), 'same-boot job created captures')
            refused = False
            try:
                with gate.frozen_view(ident,approved_sha256=record['plan_sha256']):pass
            except driver.gate.GateError:refused = True
            require(refused, 'production frozen view did not enforce real boot')
            state = gate._load(base)
            held_repo = next(base/root['held'] for root in state['roots'] if root['source'] == str(active/'sources/repo'))
            denied = driver.child(record,[PYTHON,'-I','-S','-B','-c',
                "import os,sys;os.open(sys.argv[1],os.O_WRONLY)",str(held_repo/'file')])
            require(denied.returncode != 0 and b'PermissionError' in denied.stderr, 'actual owner could open protected held bytes')
            record['checks'] += ['real-same-boot-refused','actual-owner-held-access-refused']
            if case == 'orphan-recreated':
                recreated = active/'sources/worker';recreated.mkdir(mode=0o700)
                os.chown(recreated,*driver.owner(uid));(recreated/'new-owner').write_bytes(b'new independent bytes')
                os.chown(recreated/'new-owner',*driver.owner(uid))
            with controller_boot(gate,actual_boot=actual_boot,synthetic_boot=record['synthetic_boot_uuid']):
                if case == 'orphan-recreated':
                    outcome = driver.job.advance(gate,ident,scratch_root=scratch)
                    require(outcome.get('state') == 'failed' and 'reappeared' in str(outcome.get('last_error')),
                            'recreated orphan namespace was not refused: '+str(outcome))
                    require(not (base/'retirement.json').exists(), 'refused capture wrote retirement intent')
                    gate.restore(ident,approved_sha256=record['plan_sha256'])
                    require((recreated/'new-owner').read_bytes() == b'new independent bytes', 'recreated path bytes changed')
                    require(Path(target['git_directory']['path']).is_dir(), 'refused orphan registration was deleted')
                    require(driver.git(record,active/'sources/repo','rev-parse','worker').decode().strip() == record['expected']['head'],
                            'refused orphan branch changed')
                    record['checks'] += ['recreated-path-held','recreated-bytes-and-old-admin-retained']
                else:
                    for _ in range(32):
                        outcome = driver.job.advance(gate,ident,scratch_root=scratch)
                        require(outcome.get('state') != 'failed', 'fixture job failed: '+str(outcome))
                        if outcome.get('phase') == 'complete':break
                    require(outcome.get('phase') == 'complete', 'bounded controller job did not complete')
                    verify_restored(driver,support,record,active,gate,base,case)
                    require(not driver.job.advance(gate,ident,scratch_root=scratch)['progressed'], 'completed replay changed state')
                    record['checks'] += ['journaled-job-complete','original-index-and-classified-archive',
                                         'registration-and-worker-branch-removed','staged-objects-survive-immediate-gc','idempotent-completion']
            require(gate._boot() == actual_boot, 'controller boot seam leaked')
            require(gate._load(base)['gated_boot_id'] == actual_boot, 'original gate boot evidence was rewritten')
            record.update(phase='controller-complete',passed=True)
            support.save(private/'receipt.json',record)
            return dict(case=case,passed=True,tests_cutoff=False,receipt=str(private/'receipt.json'),
                        checks=record['checks'],fixture_retained=True,cleanup_complete=False)
    except Exception as error:
        record.update(phase='controller-failed',passed=False,last_error=str(error))
        support.save(private/'receipt.json',record)
        raise RuntimeError(str(error)+'; retained fixture '+str(private/'receipt.json')) from error


def execute_cases(support, uid):
    results = []
    summary = dict(passed=False,tests_cutoff=False,activated=False,
        acceptance='installed orphan/locked capture-retirement integration with controller-only boot seam',
        cases=results,fixture_cleanup_complete=False)
    for case in CASES:
        try:results.append(run_case(support,uid,case))
        except Exception as error:
            summary.update(failed_case=case,error=str(error))
            return summary
    summary['passed'] = all(row['passed'] for row in results)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release',required=True)
    parser.add_argument('--manifest-sha256',required=True)
    parser.add_argument('--owner-uid',type=int,required=True)
    args = parser.parse_args()
    release,_,_ = runtime(args)
    support = load(release,'legacy-workspace-acceptance')
    result = execute_cases(support,args.owner_uid)
    print(json.dumps(result,sort_keys=True))
    return 0 if result['passed'] else 2


if __name__ == '__main__':
    try:raise SystemExit(main())
    except Exception as error:
        print(json.dumps(dict(passed=False,tests_cutoff=False,error=str(error))),flush=True)
        raise SystemExit(2)
