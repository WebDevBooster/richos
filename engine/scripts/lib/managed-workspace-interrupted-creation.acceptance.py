#!/usr/bin/env python3
"""External installed acceptance for unpublished provider storage.

Copy this reviewed script into fresh root-protected staging, pin its bytes in the
launcher and invoke fixed CLTools Python -I -S -B. It imports an explicitly pinned
existing release. It never installs code, changes policy, activates launchd,
reboots or selects an existing workspace. Failed fixtures remain for diagnosis.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import select
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import time
import uuid

PYTHON = '/Library/Developer/CommandLineTools/usr/bin/python3'
INSTALL = Path('/Library/Application Support/RichOS/workspace-broker')
PREFIX = 'interrupted-acceptance-'
ENV = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME='/var/empty', LC_ALL='C',
           GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
CASES = ('crashed-attached', 'malformed-detached', 'unreserved')
INITIAL = b'initial unpublished working bytes\n'
FINAL = INITIAL + b'last write through the already-open descriptor\n'
MALFORMED = b'not an image plist: preserve these exact unpublished bytes\n'
ATTRIBUTE = 'org.richos.acceptance.interrupted'
ATTRIBUTE_BYTES = b'raw outer image attribute\x00\xff'


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


def roots(policy, fixture):
    require(isinstance(fixture, str) and re.fullmatch(PREFIX + '[0-9a-f]{32}', fixture), 'invalid fixture ID')
    return Path(policy['private_root']) / fixture, Path(policy['active_root']) / fixture


def save(path, record):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    with temporary.open('x') as stream:
        os.chmod(temporary, 0o600)
        json.dump(record, stream, sort_keys=True)
        stream.flush(); os.fsync(stream.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def pin(path):
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
            'fixture root authority changed')
    return [info.st_dev, info.st_ino, info.st_uid, stat.S_IMODE(info.st_mode)]


def creation(receipt, case):
    return dict(request_id=case, source_repo=Path(receipt['active_root']) / 'source',
                commit=receipt['commit'], owner_uid=receipt['owner_uid'], owner_gid=receipt['owner_gid'],
                session_id=receipt['acceptance_id'], agent_name='dev-opus-' + case, size='128m')


def fault_child(args, release, policy, owner):
    private, active = roots(policy, args.fixture_id)
    receipt = json.loads(protected(private / 'acceptance.json', True).read_text())
    require(receipt['owner_uid'] == owner[0] and receipt['owner_gid'] == owner[1]
            and receipt['release'] == str(release) and receipt['manifest_sha256'] == args.manifest_sha256
            and receipt['private_root'] == str(private) and receipt['active_root'] == str(active)
            and receipt['root_pins'] == [pin(private), pin(active)], 'fault fixture binding mismatch')
    manager = load(release, 'managed-workspace-manager').WorkspaceManager(private, active, require_root=True)
    if args.fault == 'unreserved':
        manager.provider.create = lambda *a, **k: os._exit(90)
    else:
        original = manager.provider._git
        def fail_clone(argv, *pos, **kw):
            if argv and argv[0] == 'clone':
                if args.fault == 'malformed-detached':
                    raise RuntimeError('injected failure before first clone')
                print('attached-before-clone', flush=True)
                require(sys.stdin.readline() == 'exit\n', 'creator checkpoint was not released')
                os._exit(88)
            return original(argv, *pos, **kw)
        manager.provider._git = fail_clone
    try:
        manager.create(**creation(receipt, args.fault))
    except RuntimeError as error:
        if args.fault == 'malformed-detached' and str(error) == 'injected failure before first clone':
            return 89
        raise
    raise RuntimeError('fault boundary was not reached')


def stop(process, graceful=True):
    if process is None or process.poll() is not None:
        return
    if graceful:
        process.terminate()
    else:
        process.kill()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill(); process.wait(timeout=15)


def extract_raw(archive, destination):
    """Only verified raw directories/files, never tar ownership or link targets."""
    destination.mkdir(mode=0o700)
    with tarfile.open(archive, 'r:gz') as source:
        for entry in source:
            parts = Path(entry.name).parts
            require(parts and parts[0] == 'image.sparsebundle' and all(p not in ('..', '.') for p in parts),
                    'unsafe raw archive member')
            target = destination.joinpath(*parts)
            if entry.isdir():
                target.mkdir(mode=0o700)
            else:
                require(entry.isfile(), 'unsupported raw archive member')
                with source.extractfile(entry) as incoming, target.open('xb') as output:
                    shutil.copyfileobj(incoming, output)
                target.chmod(0o600)
    return destination / 'image.sparsebundle'


def execute(args, release, policy, owner):
    module = load(release, 'managed-workspace-manager')
    recovery = load(release, 'managed-workspace-failed-creation')
    fixture = PREFIX + uuid.uuid4().hex
    private, active = roots(policy, fixture)
    require(not os.path.lexists(private) and not os.path.lexists(active), 'fixture already exists')
    manager = module.WorkspaceManager(private, active, require_root=True)
    report = dict(version=1, acceptance_id=fixture, release=str(release), manifest_sha256=args.manifest_sha256,
                  private_root=str(private), active_root=str(active), owner_uid=owner[0], owner_gid=owner[1],
                  root_pins=[pin(private), pin(active)], checks=[], passed=False, fixture_cleanup_complete=False,
                  activated=False, ordinary_sweep_interval_seconds=60, fault_injection='isolated creator process only',
                  expected=dict(working_sha256=hashlib.sha256(FINAL).hexdigest(),
                                malformed_sha256=hashlib.sha256(MALFORMED).hexdigest(),
                                outer_xattr_base64=base64.b64encode(ATTRIBUTE_BYTES).decode()))
    receipt_path = private / 'acceptance.json'
    save(receipt_path, report)  # Before any owner-controlled source or image exists.
    holder = creator = server = None
    identifiers = {}
    def check(name, condition, detail=''):
        report['checks'].append(dict(name=name, passed=bool(condition), detail=detail))
        save(receipt_path, report)
        require(condition, name + (': ' + detail if detail else ''))
    def child(argv, **kwargs):
        return subprocess.run(argv, env=ENV, user=owner[0], group=owner[1], extra_groups=[],
                              capture_output=True, timeout=kwargs.pop('timeout', 30), **kwargs)
    def fault(case):
        return subprocess.Popen([PYTHON, '-I', '-S', '-B', str(Path(__file__).resolve()),
            '--release', str(release), '--manifest-sha256', args.manifest_sha256,
            '--owner-uid', str(owner[0]), '--fixture-id', fixture, '--fault', case], env=ENV,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    def request_for(case):
        key = manager._request_key(owner[0], case)
        value = json.loads((private / (key + '.request.json')).read_text())
        require(value['request_id'] == case and value['session_id'] == fixture, 'wrong durable request')
        require(str(uuid.UUID(value['id'])) == value['id'], 'invalid request workspace ID')
        identifiers[case] = value['id']; report['identifiers'] = dict(identifiers)
        save(receipt_path, report)
        return value
    try:
        source = active / 'source'; source.mkdir(mode=0o700); os.chown(source, *owner)
        def git(*argv):
            return manager._user_git(['-C', str(source), *argv], owner, cwd=active).decode().strip()
        git('init', '-q'); git('config', 'user.name', 'RichOS fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        result = child([PYTHON, '-I', '-S', '-c',
            'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"source fixture\\n")', str(source / 'tracked')])
        require(result.returncode == 0, result.stderr.decode(errors='replace'))
        git('add', '.'); git('commit', '-qm', 'fixture')
        report['commit'] = git('rev-parse', 'HEAD'); save(receipt_path, report)
        creator = fault(CASES[0])
        check('creator-reached-real-attached-clone-boundary',
              bool(select.select([creator.stdout], [], [], 90)[0]) and
              creator.stdout.readline().strip() == 'attached-before-clone')
        request0 = request_for(CASES[0]); ident = request0['id']
        # The creator intentionally still owns the provider lock here. Read its
        # durable journal and real inventory without attempting that same lock.
        journal = json.loads((private / ident / 'journal.json').read_text())
        check('uninitialized-image-is-actually-attached', bool(manager.provider._attached(
              private / ident / 'image.sparsebundle')) and journal['state'] == 'attached_writable'
              and not journal.get('initialized'))
        holder_code = ('import os,signal,sys; signal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGTERM,signal.SIGINT}); '
            'f=open(sys.argv[1],"w+b"); f.write(' + repr(INITIAL) + '); f.flush(); os.fsync(f.fileno()); '
            'print("ready",flush=True); sys.stdin.readline(); f.write(' + repr(FINAL[len(INITIAL):]) + '); '
            'f.flush(); os.fsync(f.fileno()); f.close()')
        holder = subprocess.Popen([PYTHON, '-I', '-S', '-c', holder_code,
            str(active / ident / 'incomplete-working')], env=ENV, user=owner[0], group=owner[1], extra_groups=[],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check('actual-owner-holds-writable-descriptor', bool(select.select([holder.stdout], [], [], 15)[0])
              and holder.stdout.readline().strip() == 'ready')
        _, err = creator.communicate('exit\n', timeout=15)
        check('creator-really-exits-without-provider-cleanup', creator.returncode == 88, err[-500:]); creator = None
        for case, code in ((CASES[1], 89), (CASES[2], 90)):
            creator = fault(case); _, err = creator.communicate(timeout=120)
            check('fault-boundary-' + case, creator.returncode == code, err[-500:]); creator = None
            request_for(case)
        malformed = private / identifiers[CASES[1]] / 'image.sparsebundle'
        detached = manager.provider.inspect(identifiers[CASES[1]])
        check('ordinary-provider-exception-cleanly-detached', detached['state'] == 'detached'
              and detached.get('operation') is None and not detached.get('attachment') and not detached.get('initialized'))
        (malformed / 'Info.plist').write_bytes(MALFORMED)
        subprocess.run(['/usr/bin/xattr', '-wx', ATTRIBUTE, ATTRIBUTE_BYTES.hex(), str(malformed)],
                       env=ENV, check=True, capture_output=True, timeout=10)
        check('unreserved-request-has-no-provider-directory', not (private / identifiers[CASES[2]]).exists())
        fixture_policy = dict(version=1, private_root=str(private), active_root=str(active),
            owners={str(owner[0]): {'gid': owner[1]}}, repositories={'fixture': dict(
                path=str(source), owners=[owner[0]], retention_days=14, size='128m')})
        policy_path = private / 'broker-policy.json'; save(policy_path, fixture_policy)
        socket = active / 'b.sock'
        require(len(os.fsencode(socket)) < 104, 'fixture socket path too long')
        error_log = (private / 'broker-stderr.log').open('wb')
        try:
            server = subprocess.Popen([PYTHON, '-I', '-S', '-B', str(release / 'managed-workspace-broker.py'),
                '--policy', str(policy_path), '--socket', str(socket)], env=ENV, stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=error_log)
        finally:
            error_log.close()
        def rpc(payload, allow_error=False):
            result = child([PYTHON, '-I', '-S', '-B', str(release / 'managed-workspace-client.py'),
                            '--socket', str(socket)], input=json.dumps(payload).encode(), timeout=40)
            if allow_error:
                return result
            require(result.returncode == 0, result.stderr.decode(errors='replace')[-1000:])
            return json.loads(result.stdout)
        def wait_for(predicate, timeout=90):
            deadline = time.monotonic() + timeout
            latest = None
            while time.monotonic() < deadline:
                require(server.poll() is None, 'installed broker exited')
                if socket.exists():
                    result = rpc({'operation':'health'}, allow_error=True)
                    if result.returncode == 0:
                        latest = json.loads(result.stdout)
                        if predicate(latest):
                            return latest
                time.sleep(0.25)
            raise RuntimeError('broker deadline exceeded: ' + json.dumps(latest, sort_keys=True))
        health = wait_for(lambda h: h.get('latest_sweep', {}).get('last_completed_at'))
        check('actual-owner-authenticates-root-broker', health['server_uid'] == 0
              and health['peer_uid'] == owner[0] and health['repositories'] == ['fixture'])
        check('same-boot-sweep-does-not-invent-cancellation', all(
            not (private / (manager._request_key(owner[0], case) + '.cancel.json')).exists()
            and not (private / identifiers[case] / 'failed-creation.json').exists() for case in CASES))
        refused = rpc(dict(operation='cancel_preparation', id=ident, session_id='wrong-session'), allow_error=True)
        check('wrong-session-cancellation-refused', refused.returncode != 0 and
              not (private / (request0['request_key'] + '.cancel.json')).exists())
        previous = health['latest_sweep']['last_completed_at']
        for case in CASES:
            result = rpc(dict(operation='cancel_preparation', id=identifiers[case], session_id=fixture))
            require(result['id'] == identifiers[case], 'cancellation response identity mismatch')
        health = wait_for(lambda h: (h.get('latest_sweep', {}).get('last_completed_at') or 0) > previous, 100)
        status = rpc({'operation':'status'})
        rows = {row['id']: row for row in status['records']}
        check('unforced-cutoff-retains-busy-owner-storage', rows[ident]['state'] == 'creation-blocked'
              and bool(rows[ident].get('reason')) and (private / ident / 'image.sparsebundle').exists()
              and not (private / ident / 'failed-creation.tar.gz').exists())
        _, err = holder.communicate('\n', timeout=15)
        check('holder-final-write-is-fsynced-and-closed', holder.returncode == 0, err[-500:]); holder = None
        def finished(health):
            rows = {row['id']: row for row in rpc({'operation':'status'})['records']}
            return all(rows.get(identifiers[case], {}).get('state') == (
                'creation-empty' if case == CASES[2] else 'creation-retained') for case in CASES)
        wait_for(finished, 130)
        check('normal-unattended-sweeps-finish-all-cancelled-requests', True)
        for case in CASES:
            replay = rpc(dict(operation='create', repository='fixture', commit=report['commit'],
                session_id=fixture, agent_name='dev-opus-' + case, request_id=case))
            check('permanent-request-retry-' + case, replay['id'] == identifiers[case] and replay['state'] == (
                'creation-empty' if case == CASES[2] else 'creation-retained'))
        server.terminate(); server.wait(timeout=15)
        check('installed-broker-shuts-down-cleanly', server.returncode == 0); server = None
        for case in CASES[:2]:
            base = private / identifiers[case]
            record = json.loads((base / 'failed-creation.json').read_text())
            archive = base / 'failed-creation.tar.gz'
            recovery._verify_archive(archive, record['manifest'])
            check('verified-lossless-raw-archive-' + case, record['phase'] == 'retained'
                  and recovery._hash(archive) == record['archive_sha256'] and not (base / 'image.sparsebundle').exists())
        base = private / identifiers[CASES[1]]
        record = json.loads((base / 'failed-creation.json').read_text())
        with tarfile.open(base / 'failed-creation.tar.gz', 'r:gz') as archive:
            check('malformed-image-bytes-preserved', archive.extractfile('image.sparsebundle/Info.plist').read() == MALFORMED)
            outer = archive.getmember('image.sparsebundle')
            check('outer-image-xattr-preserved', json.loads(outer.pax_headers['RICHOS.xattrs'])[ATTRIBUTE]
                  == base64.b64encode(ATTRIBUTE_BYTES).decode())
        empty = private / identifiers[CASES[2]]
        record = json.loads((empty / 'failed-creation.json').read_text())
        check('empty-reservation-has-no-archive-or-byte-reclamation-claim', record['phase'] == 'empty'
              and not (empty / 'failed-creation.tar.gz').exists() and not (empty / 'image.sparsebundle').exists()
              and not record.get('manifest'))
        restored = extract_raw(private / ident / 'failed-creation.tar.gz', private / 'verified-raw-copy')
        verify = active / 'verify'; verify.mkdir(mode=0o700)
        mounted = plistlib.loads(manager.provider._run(['/usr/bin/hdiutil', 'attach', '-plist', '-readonly',
            '-nobrowse', '-mountpoint', str(verify), str(restored)]))
        try:
            check('actual-readonly-restoration-preserves-final-owner-write', (verify / 'incomplete-working').read_bytes() == FINAL)
        finally:
            manager.provider._run(['/usr/bin/hdiutil', 'detach', manager.provider._device(mounted)])
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
    finally:
        stop(creator); stop(server)
        if holder is not None:
            try:
                holder.communicate('\n', timeout=15)
            except Exception:
                stop(holder)
        # Never erase a failed experiment. Preserve exact evidence after attempting
        # unforced fixture-only detach. Missing/malformed inventory also retains.
        try:
            require(report['root_pins'] == [pin(private), pin(active)], 'cleanup root identity changed')
            inventory = manager.provider.attachment_inventory()
            detached_paths = []
            for attachment in inventory:
                image = Path(attachment['image-path']).resolve()
                if private in image.parents:
                    manager.provider._run(['/usr/bin/hdiutil', 'detach', manager.provider._device(attachment)])
                    detached_paths.append(str(image))
            inventory = manager.provider.attachment_inventory()
            require(not any(private in Path(item['image-path']).resolve().parents for item in inventory),
                    'fixture image still attached')
            report['cleanup'] = dict(strict_inventory_complete=True, remaining_fixture_attachments=0,
                                     unforced_detached_paths=detached_paths, roots_match=True)
            save(receipt_path, report)
            if report['passed']:
                require(report['root_pins'] == [pin(private), pin(active)], 'cleanup root changed')
                shutil.rmtree(active); shutil.rmtree(private)
                report['fixture_cleanup_complete'] = not active.exists() and not private.exists()
            else:
                report['retained_fixture_receipt'] = str(receipt_path)
        except Exception as error:
            report.setdefault('cleanup_errors', []).append(str(error))
            report['passed'] = False
        print(json.dumps(report, sort_keys=True, indent=2))
    return 0 if report['passed'] and report['fixture_cleanup_complete'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--owner-uid', required=True, type=int)
    parser.add_argument('--fixture-id')
    parser.add_argument('--fault', choices=CASES)
    args = parser.parse_args()
    require(bool(args.fixture_id) == bool(args.fault), 'internal fault needs exact fixture ID')
    # osascript can inherit blocked control signals. Do not propagate that mask
    # into disposable creators or owners; unrelated signal masks remain intact.
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT})
    release, policy, owner = runtime(args)
    return fault_child(args, release, policy, owner) if args.fault else execute(args, release, policy, owner)


if __name__ == '__main__':
    raise SystemExit(main())
