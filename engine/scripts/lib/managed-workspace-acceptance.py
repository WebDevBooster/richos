#!/usr/bin/env python3
"""Installed root/user acceptance using only newly created disposable fixtures.

Never enables client.json, starts launchd, reboots or accesses real worktrees.
Run from a reviewed root-owned release with the root-owned Command Line Tools
Python using -I -S -B.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import select
import shutil
import subprocess
import sys
import time
import uuid


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owner-uid', required=True, type=int)
    args = parser.parse_args()
    # Import only a sibling in the root-owned installed release. validate_runtime
    # verifies every bundled file, interpreter path and isolation flags before
    # any fixture creation or manager import.
    broker = load('installed_broker', 'managed-workspace-broker.py')
    release = broker.validate_runtime()
    policy_file = broker.protected_path(release.parent.parent / 'policy.json', regular=True)
    policy = broker.validate_policy(json.loads(policy_file.read_text()))
    if str(args.owner_uid) not in policy['owners']:
        raise RuntimeError('acceptance owner must be approved in installed policy')
    owner = (args.owner_uid, policy['owners'][str(args.owner_uid)]['gid'])
    mod = load('installed_manager', 'managed-workspace-manager.py')
    # Dedicated child namespaces cannot select production UUID directories.
    run_id = 'acceptance-' + uuid.uuid4().hex
    private = Path(policy['private_root']) / run_id
    active = Path(policy['active_root']) / run_id
    manager = mod.WorkspaceManager(private, active, require_root=True)
    report = dict(version=1, acceptance_id=run_id, owner_uid=owner[0], checks=[],
                  passed=False, activated=False, fixture_root=str(private))
    identifiers = []
    holder = None
    server = None
    env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME='/var/empty', LC_ALL='C',
               GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')

    def child(argv, **kwargs):
        return subprocess.run(argv, env=env, user=owner[0], group=owner[1], extra_groups=[],
                              capture_output=True, timeout=kwargs.pop('timeout', 30), **kwargs)

    def check(name, condition, detail=''):
        report['checks'].append(dict(name=name, passed=bool(condition), detail=detail))
        if not condition:
            raise RuntimeError('acceptance failed: ' + name + (': ' + detail if detail else ''))

    def git(repo, *argv):
        return manager._user_git(['-C', str(repo), *argv], owner, cwd=active).decode().strip()

    def write(repo, name, value):
        result = child(['/usr/bin/python3', '-I', '-S', '-c',
                        'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])',
                        str(repo / name), value])
        check('owner-write-' + name, result.returncode == 0, result.stderr.decode()[-500:])

    def create(source, commit, request):
        record = manager.create(request_id=request, source_repo=source, commit=commit,
                                owner_uid=owner[0], owner_gid=owner[1], session_id=run_id,
                                agent_name='dev-opus-' + request, size='128m')
        identifiers.append(record['id'])
        return record, active / record['id'] / 'repo'

    try:
        source = active / 'source'; source.mkdir(mode=0o700)
        os.chown(source, *owner)
        git(source, 'init', '-q'); git(source, 'config', 'user.name', 'RichOS fixture')
        git(source, 'config', 'user.email', 'fixture@example.invalid')
        write(source, 'tracked', 'original')
        git(source, 'add', '.'); git(source, 'commit', '-qm', 'fixture')
        commit = git(source, 'rev-parse', 'HEAD')
        record, work = create(source, commit, 'cutoff')
        ident = record['id']; image = private / ident / 'image.sparsebundle'
        denied = child(['/usr/bin/python3', '-I', '-S', '-c',
                        'import os,sys; os.listdir(sys.argv[1])', str(image)])
        check('owner-cannot-read-backing-image', denied.returncode != 0)
        denied = child(['/bin/chmod', '777', str(image)])
        check('owner-cannot-change-backing-permissions', denied.returncode != 0)
        holder = subprocess.Popen(['/usr/bin/python3', '-I', '-S', '-c',
            'import os,sys; f=open(sys.argv[1],"r+b"); print("ready",flush=True); '
            'sys.stdin.readline(); f.seek(0); f.write(b"latest!!"); f.flush(); os.fsync(f.fileno()); f.close()',
            str(work / 'tracked')], env=env, user=owner[0], group=owner[1], extra_groups=[],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check('holder-ready-within-deadline', bool(select.select([holder.stdout], [], [], 10)[0]))
        check('holder-started', holder.stdout.readline().strip() == 'ready')
        manager.bind(ident, session_id=run_id, agent_id='agent-fixture')
        manager.terminal(ident, session_id=run_id, agent_id='agent-fixture')
        busy = manager.reconcile(ident)
        check('busy-holder-blocks-reclamation', busy['state'] == 'terminal' and bool(busy.get('last_error')) and image.exists())
        holder.communicate('\n', timeout=30)
        check('holder-finished', holder.returncode == 0)
        holder = None
        retired = manager.reconcile(ident)
        check('root-to-owner-capture-succeeds', retired['state'] == 'retained', retired.get('last_error', ''))
        check('active-image-reclaimed', not image.exists())
        check('dirty-recovery-retained', (private / ident / 'recovery.dmg').is_file())
        verify_mount = active / 'verify'; verify_mount.mkdir(mode=0o700)
        recovered = private / ident / 'recovery.dmg'
        mounted = plistlib.loads(manager.provider._run(['/usr/bin/hdiutil', 'attach', '-plist',
            '-readonly', '-nobrowse', '-mountpoint', str(verify_mount), str(recovered)]))
        try:
            check('latest-working-bytes-recovered', (verify_mount / 'repo/tracked').read_bytes() == b'latest!!')
            check('separate-index-bytes-recovered', git(verify_mount / 'repo', 'show', ':tracked') == 'original')
        finally:
            manager.provider._run(['/usr/bin/hdiutil', 'detach', manager.provider._device(mounted)])
        check('dirty-expiry-refused', manager.reconcile(ident, now=retired['expires_at']+1)['state'] == 'retained')
        # A second fixture tests the actual authority boundary. Successful user
        # force-unmount invalidates acceptance and does not enable production.
        record2, work2 = create(source, commit, 'authority')
        ident2 = record2['id']
        for command in ('hdiutil', 'diskutil'):
            current = manager.provider.inspect(ident2)
            device = manager.provider._device(current['attachment'])
            argv = ['/usr/bin/hdiutil', 'detach', '-force', device] if command == 'hdiutil' else [
                '/usr/sbin/diskutil', 'unmount', 'force', str(work2.parent)]
            attempt = child(argv)
            check('owner-cannot-force-unmount-' + command, attempt.returncode != 0,
                  attempt.stderr.decode('utf-8', 'replace')[-500:])
            manager.inspect(ident2)  # Still the exact writable mount.
        manager.bind(ident2, session_id=run_id, agent_id='agent-clean')
        manager.terminal(ident2, session_id=run_id, agent_id='agent-clean')
        clean = manager.reconcile(ident2)
        check('clean-recovery-created', clean['state'] == 'retained', clean.get('last_error', ''))
        expired = manager.reconcile(ident2, now=clean['expires_at']+1)
        check('clean-recovery-expires', expired['state'] == 'expired', expired.get('last_error', ''))
        # Run the actual protected broker and its legacy worker against ONLY
        # this run's disposable roots/source. No launchd or public config change.
        fixture_policy = dict(version=1, private_root=str(private), active_root=str(active),
            owners={str(owner[0]): {'gid': owner[1]}}, repositories={'fixture': dict(
                path=str(source), owners=[owner[0]], retention_days=14, size='128m')})
        fixture_policy_path = private / 'broker-policy.json'
        fixture_policy_path.write_text(json.dumps(fixture_policy));fixture_policy_path.chmod(0o600)
        fixture_socket = active / 'broker.sock'
        with (private / 'broker-stderr.log').open('wb') as error_log:
            server = subprocess.Popen(['/Library/Developer/CommandLineTools/usr/bin/python3', '-I', '-S', '-B',
                str(release / 'managed-workspace-broker.py'), '--policy', str(fixture_policy_path),
                '--socket', str(fixture_socket)], env=env, stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=error_log)
            deadline = time.monotonic()+15
            health = None
            while time.monotonic() < deadline and server.poll() is None:
                if fixture_socket.exists():
                    response = child(['/Library/Developer/CommandLineTools/usr/bin/python3', '-I', '-S', '-B',
                        str(release / 'managed-workspace-client.py'), '--socket', str(fixture_socket), 'health'])
                    if response.returncode == 0:
                        health=json.loads(response.stdout)
                        if health.get('legacy_maintenance',{}).get('inventory_complete'):break
                time.sleep(0.05)
            check('installed-root-broker-starts', server.poll() is None and health is not None)
            check('owner-client-authenticates-installed-root-broker', health.get('server_uid') == 0
                  and health.get('peer_uid') == owner[0] and health.get('repositories') == ['fixture'])
            check('installed-legacy-worker-reports-empty-fixture-inventory',
                  health.get('legacy_maintenance',{}).get('enabled') is True
                  and health['legacy_maintenance'].get('inventory_complete') is True
                  and health['legacy_maintenance'].get('total') == 0)
            def request(payload):
                result = child(['/Library/Developer/CommandLineTools/usr/bin/python3', '-I', '-S', '-B',
                    str(release / 'managed-workspace-client.py'), '--socket', str(fixture_socket)],
                    input=json.dumps(payload).encode(), timeout=340)
                if result.returncode:
                    raise RuntimeError('installed owner request failed: '+result.stderr.decode('utf-8','replace')[-1000:])
                return json.loads(result.stdout)

            creation = dict(operation='create', repository='fixture', commit=commit,
                session_id=run_id, agent_name='dev-opus-socket', request_id='socket-lifecycle')
            # Existing same-name source work belongs to someone else. The new
            # managed worker must deliver only through its UUID namespace.
            git(source, 'branch', creation['agent_name'], commit)
            socket_record = request(creation)
            socket_id = socket_record['id']
            check('owner-socket-creation-is-idempotent', request(creation)['id'] == socket_id
                  and socket_record['workspace_class'] == 'managed-image'
                  and socket_record['path'] == str(active / socket_id / 'repo'))
            binding = dict(id=socket_id, session_id=run_id, agent_id='agent-socket')
            bound = request(dict(operation='bind', **binding))
            check('owner-socket-binding-acknowledged', bound['agent_id'] == binding['agent_id'])
            socket_work = active / socket_id / 'repo'
            git(socket_work, 'config', 'user.name', 'RichOS fixture')
            git(socket_work, 'config', 'user.email', 'fixture@example.invalid')
            write(socket_work, 'socket-delivered', 'exact owner delivery')
            git(socket_work, 'add', '.'); git(socket_work, 'commit', '-qm', 'owner delivered work')
            delivered_tip = git(socket_work, 'rev-parse', 'HEAD')
            terminal = request(dict(operation='terminal', **binding))
            check('owner-socket-terminal-acknowledged', terminal['state'] == 'terminal')
            unused = request(dict(creation, request_id='socket-unused', agent_name='dev-opus-unused'))
            cancelled = request(dict(operation='cancel_preparation', id=unused['id'], session_id=run_id))
            check('owner-socket-unused-preparation-cancelled', cancelled['agent_id'] is None
                  and cancelled.get('terminal_ingress') == 'abandoned-preparation')
            # Exercise the ordinary unattended sweep, without a reconcile RPC.
            deadline = time.monotonic()+150
            retired_ids = set()
            while time.monotonic() < deadline and server.poll() is None:
                status = request({'operation':'status'})
                retired_ids = {row['id'] for row in status['records'] if row.get('state') == 'retained'}
                if {socket_id,unused['id']} <= retired_ids:break
                time.sleep(0.2)
            check('installed-sweep-reclaims-terminal-and-unused-workspaces',
                  {socket_id,unused['id']} <= retired_ids
                  and all(not (private / ident / 'image.sparsebundle').exists()
                          and (private / ident / 'recovery.dmg').is_file() for ident in (socket_id,unused['id'])))
            delivery = request(dict(operation='delivery', id=socket_id))
            check('owner-delivery-ref-binds-exact-source-and-commit', delivery == dict(
                manager_id=socket_id, source_repo=str(source),
                ref='refs/richos/handoffs/managed/'+socket_id+'/HEAD', tip=delivered_tip)
                and delivered_tip != commit and git(source, 'rev-parse', delivery['ref']) == delivered_tip)
            check('new-managed-workers-create-no-ordinary-source-branches', all(
                not git(source, 'for-each-ref', '--format=%(refname)', 'refs/heads/'+name)
                for name in ('dev-opus-cutoff', 'dev-opus-authority', 'dev-opus-unused')))
            check('preexisting-same-name-source-branch-is-preserved',
                  git(source, 'rev-parse', 'refs/heads/'+creation['agent_name']) == commit)
            git(source, 'merge', '--ff-only', delivery['tip'])
            check('owner-merges-exact-delivery-after-image-reclamation',
                  git(source, 'rev-parse', 'HEAD') == delivered_tip
                  and (source / 'socket-delivered').read_text() == 'exact owner delivery')
            server.terminate();server.wait(timeout=15)
            check('installed-root-broker-shuts-down-cleanly', server.returncode == 0)
            server=None
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
    finally:
        if server is not None:
            server.terminate()
            try:server.wait(timeout=15)
            except subprocess.TimeoutExpired:
                server.kill();server.wait(timeout=15)
        if holder is not None:
            try:
                holder.communicate('\n', timeout=30)
            except Exception:
                holder.terminate()
                holder.wait(timeout=30)
        safe = True
        try:
            # A creation call can fail after mounting and before returning an
            # ID. Inventory every exclusively created fixture directory, not
            # just successful method returns. Missing image paths are checked
            # too because an attached image can outlive its pathname.
            for base in private.iterdir():
                if base.is_dir() or base.is_symlink():
                    if base.is_symlink() or str(uuid.UUID(base.name)) != base.name:
                        raise RuntimeError('unknown fixture storage identity')
                    ident = base.name
                    for image in (base / 'image.sparsebundle', base / 'recovery.dmg'):
                        attached = manager.provider._attached(image)
                        if attached:
                            manager.provider._run(['/usr/bin/hdiutil', 'detach', manager.provider._device(attached)])
                        if manager.provider._attached(image):
                            raise RuntimeError('fixture image remains attached')
            for attached in manager.provider.attachment_inventory():
                path = Path(attached.get('image-path', '')).resolve()
                if private == path or private in path.parents:
                    raise RuntimeError('attached fixture image is outside complete inventory')
        except Exception as error:
            safe = False
            report.setdefault('cleanup_errors', []).append(str(error))
        if safe:
            # These two roots were exclusively minted by this acceptance run.
            # No production workspace ID or source repository is traversed.
            shutil.rmtree(active)
            shutil.rmtree(private)
            report['fixture_cleanup_complete'] = True
        else:
            report['fixture_cleanup_complete'] = False
            report['passed'] = False
        print(json.dumps(report, sort_keys=True, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
