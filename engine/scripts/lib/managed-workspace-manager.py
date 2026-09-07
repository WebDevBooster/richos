#!/usr/bin/env python3
"""Privileged lifecycle for manager-owned workspace images.

The socket broker authenticates callers separately. This module accepts only
manager-issued IDs and retains failed operations for retry. It never deletes
an arbitrary caller-provided path or force-detaches a filesystem.
"""
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import subprocess
import time
import uuid


def _module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


volumes = _module('managed_volume', 'managed-workspace-volume.py')


class ManagerError(RuntimeError):
    pass


class WorkspaceManager:
    def __init__(self, root, active_root, *, require_root=True, provider=None):
        self.provider = provider or volumes.VolumeStore(root, active_root, require_root=require_root)
        self.root = self.provider.root

    def _base(self, ident):
        try:
            if str(uuid.UUID(ident)) != ident:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise ManagerError('canonical manager ID required')
        return self.root / ident

    @contextlib.contextmanager
    def _lock(self, ident):
        base = self._base(ident)
        self.provider._check_directory(base)
        fd = os.open(base / 'lifecycle.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    def _save(self, ident, record):
        base = self._base(ident)
        tmp = base / ('lifecycle.' + uuid.uuid4().hex)
        with tmp.open('x', encoding='utf-8') as stream:
            os.chmod(tmp, 0o600)
            json.dump(record, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, base / 'lifecycle.json')
        self.provider._sync_dir(base)

    def _load(self, ident):
        with (self._base(ident) / 'lifecycle.json').open(encoding='utf-8') as stream:
            record = json.load(stream)
        if record.get('version') != 1 or record.get('id') != ident:
            raise ManagerError('invalid lifecycle journal')
        return record

    @staticmethod
    def _identity(path, kind):
        st = path.lstat()
        if not kind(st.st_mode) or st.st_uid != os.geteuid():
            raise ManagerError('manager asset has unexpected type or owner')
        return [st.st_dev, st.st_ino]

    @staticmethod
    def _digest(path):
        h = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(block)
        return h.hexdigest()

    @staticmethod
    def _request_key(owner_uid, request_id):
        if type(owner_uid) is not int or owner_uid < 0:
            raise ManagerError('numeric owner UID required')
        if not isinstance(request_id, str) or not request_id or len(request_id) > 128:
            raise ManagerError('stable request_id must contain 1 to 128 characters')
        return hashlib.sha256((str(owner_uid) + '\0' + request_id).encode('utf-8')).hexdigest()

    @contextlib.contextmanager
    def _request_lock(self, key):
        if not re.fullmatch(r'[0-9a-f]{64}', key):
            raise ManagerError('invalid request key')
        fd = os.open(self.root / (key + '.request.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    def _recover_create(self, request, *, start=False):
        ident = request['id']
        base = self._base(ident)
        if not base.exists():
            if not start:
                return dict(request, state='creation-incomplete', last_error='provider reservation not started')
            payload = request['payload']
            self.provider.create(ident, payload['source_repo'], payload['commit'],
                                 owner_uid=payload['owner_uid'], owner_gid=payload['owner_gid'],
                                 size=payload['size'])
        with self._lock(ident):
            if (base / 'lifecycle.json').exists():
                lifecycle = self._load(ident)
                if lifecycle.get('request_key') != request['request_key']:
                    raise ManagerError('lifecycle belongs to another creation request')
                if lifecycle['state'] != 'creating':
                    lifecycle = self._terminalize_after_boot(ident, lifecycle)
                    if lifecycle['state'] == 'active':
                        self._active_ready(ident)
                    return lifecycle
            try:
                provider = self.provider.inspect(ident)
            except Exception as error:
                return dict(request, state='creation-incomplete', last_error=str(error))
            if not provider.get('initialized'):
                return dict(request, state='creation-incomplete', last_error='provider initialization incomplete')
            payload = request['payload']
            if any(provider.get(key) != payload[key] for key in ('owner_uid', 'owner_gid', 'commit')):
                raise ManagerError('provider identity differs from creation request')
            recovered = self._terminalize_after_boot(ident, request, provider=provider)
            if recovered['state'] == 'terminal':
                return recovered
            if provider['state'] == 'detached' and provider.get('operation') is None:
                self.provider.attach(ident)
            elif provider['state'] != 'attached_writable' or provider.get('operation') is not None:
                return dict(request, state='creation-incomplete', last_error='provider has no active writable mount')
            repo = self.provider.active_root / ident / 'repo'
            owner = (payload['owner_uid'], payload['owner_gid'])
            branch = payload['agent_name']
            self._user_git(['check-ref-format', '--branch', branch], owner, cwd=repo)
            head = self._user_git(['rev-parse', '--verify', 'HEAD'], owner, cwd=repo).decode().strip()
            if head != payload['commit']:
                raise ManagerError('unpublished workspace HEAD changed during initialization')
            current = self._user_git(['rev-parse', '--abbrev-ref', 'HEAD'], owner, cwd=repo).decode().strip()
            if current != branch:
                if current != 'HEAD':
                    raise ManagerError('unpublished workspace has another active branch')
                existing = self._user_git(['for-each-ref', '--format=%(objectname)', 'refs/heads/' + branch],
                                          owner, cwd=repo).decode().strip()
                if existing and existing != head:
                    raise ManagerError('worker branch already holds different work')
                self._user_git(['checkout', branch] if existing else ['checkout', '-b', branch], owner, cwd=repo)
            if self._user_git(['symbolic-ref', '--short', 'HEAD'], owner, cwd=repo).decode().strip() != branch:
                raise ManagerError('worker branch initialization not verified')
            record = dict(request, branch_initialized=True, branch=branch, state='creating')
            self._save(ident, record)
            record['state'] = 'active'
            self._save(ident, record)
            return record

    def _terminalize_after_boot(self, ident, record, *, provider=None):
        """Caller holds lifecycle lock. Reboot closes bound and unbound owners."""
        if record['state'] not in ('active', 'creating'):
            return record
        provider = self.provider.inspect(ident) if provider is None else provider
        previous = provider.get('boot_id')
        try:
            valid = isinstance(previous, str) and str(uuid.UUID(previous)) == previous
        except ValueError:
            valid = False
        if not valid:
            raise ManagerError('workspace boot identity is unknown; ownership retained')
        current = self.provider._boot_id()
        if previous == current:
            return record
        record = dict(record, state='terminal', terminal_at=time.time(),
                      terminal_ingress='machine-reboot', previous_boot_id=previous, terminal_boot_id=current)
        self._save(ident, record)
        return record

    def create(self, *, request_id, source_repo, commit, owner_uid, owner_gid, session_id,
               agent_name, retention_days=14, size='32g'):
        key = self._request_key(owner_uid, request_id)
        if type(retention_days) is not int or not 1 <= retention_days <= 365:
            raise ManagerError('retention must be an integer from 1 to 365 days')
        if not isinstance(session_id, str) or not session_id or len(session_id) > 128:
            raise ManagerError('session identity required')
        if not isinstance(agent_name, str) or not agent_name or len(agent_name) > 128:
            raise ManagerError('agent name required')
        if type(owner_uid) is not int or owner_uid <= 0 or type(owner_gid) is not int or owner_gid < 0:
            raise ManagerError('unprivileged numeric owner required')
        if not isinstance(commit, str) or not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', commit):
            raise ManagerError('full source commit required')
        if not isinstance(size, str) or not re.fullmatch(r'[1-9][0-9]*[mg]', size):
            raise ManagerError('valid sparse capacity required')
        if not Path(source_repo).is_absolute():
            raise ManagerError('absolute source repository required')
        if agent_name.startswith('-') or agent_name == 'HEAD':
            raise ManagerError('invalid worker branch name')
        self._user_git(['check-ref-format', 'refs/heads/' + agent_name], (owner_uid, owner_gid), cwd=self.provider.active_root)
        payload = dict(source_repo=str(Path(source_repo).resolve()), commit=commit,
                       owner_uid=owner_uid, owner_gid=owner_gid, session_id=session_id,
                       agent_name=agent_name, retention_days=retention_days, size=size)
        pending = self.root / (key + '.request.json')
        with self._request_lock(key):
            if pending.exists():
                request = json.loads(pending.read_text(encoding='utf-8'))
                if (request.get('request_key') != key or request.get('request_id') != request_id
                        or request.get('payload') != payload):
                    raise ManagerError('request_id was already used for a different creation payload')
            else:
                ident = str(uuid.uuid4())
                request = dict(version=1, id=ident, request_id=request_id, request_key=key,
                               payload=payload, state='creating', owner_uid=owner_uid, owner_gid=owner_gid,
                               source_repo=payload['source_repo'], source_commit=commit, session_id=session_id,
                               agent_name=agent_name, retention_days=retention_days,
                               created_at=time.time(), agent_id=None)
                request['source_identity'] = self._source_fingerprint(request)
                # The permanent tiny mapping is published before provider side
                # effects. It survives success, reclamation and expiry so retries
                # never allocate a second workspace for the same owner/request.
                temporary = self.root / (key + '.' + uuid.uuid4().hex + '.request.tmp')
                with temporary.open('x', encoding='utf-8') as stream:
                    os.chmod(temporary, 0o600)
                    json.dump(request, stream, sort_keys=True)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, pending)
                self.provider._sync_dir(self.root)
            return self._recover_create(request, start=True)

    def bind(self, ident, *, session_id, agent_id):
        if not isinstance(agent_id, str) or not agent_id or len(agent_id) > 128:
            raise ManagerError('agent ID required')
        with self._lock(ident):
            record = self._load(ident)
            if record['state'] != 'active' or record['session_id'] != session_id:
                raise ManagerError('workspace session or lifecycle mismatch')
            if record['agent_id'] not in (None, agent_id):
                raise ManagerError('workspace cannot be rebound')
            self._active_ready(ident)
            record['agent_id'] = agent_id
            self._save(ident, record)
            return record

    def terminal(self, ident, *, session_id, agent_id):
        with self._lock(ident):
            record = self._load(ident)
            if not agent_id or record['agent_id'] != agent_id or record['session_id'] != session_id:
                raise ManagerError('terminal owner does not match bound workspace')
            if record['state'] == 'active':
                record.update(state='terminal', terminal_at=time.time())
                self._save(ident, record)
            return record

    def cancel_preparation(self, ident, *, session_id):
        """Close an unused preparation. Binding and cancellation share one lock."""
        with self._lock(ident):
            record = self._load(ident)
            if not session_id or record.get('session_id') != session_id or record.get('agent_id') is not None:
                raise ManagerError('preparation is bound or session identity differs')
            if record['state'] == 'active':
                record.update(state='terminal', terminal_at=time.time(),
                              terminal_ingress='abandoned-preparation')
                self._save(ident, record)
            elif record.get('terminal_ingress') != 'abandoned-preparation':
                raise ManagerError('workspace is not an unused active preparation')
            return record

    def inspect(self, ident):
        with self._lock(ident):
            record = self._load(ident)
            if record['state'] == 'active':
                self._active_ready(ident)
            return record

    def owner_uid(self, ident):
        """Authenticate an existing ID even when its volume is unavailable."""
        with self._lock(ident):
            return self._load(ident)['owner_uid']

    def status(self, owner_uid):
        """Read durable inventory without waiting for a slow capture lock."""
        rows, seen = [], set()
        def append(ident, source):
            self._base(ident)
            if ident in seen:
                return
            seen.add(ident)
            if source.get('owner_uid') != owner_uid:
                return
            try:
                record = self._load(ident)
            except FileNotFoundError:
                record = dict(source, state='creation-incomplete', last_error='lifecycle not published')
            except Exception:
                record = dict(source, state='record-error', last_error='lifecycle unreadable')
            if record.get('owner_uid') != owner_uid:
                raise ManagerError('owned lifecycle identity mismatch')
            row = dict(id=ident, owner_uid=owner_uid, state=record['state'])
            for key in ('session_id', 'agent_id', 'created_at'):
                if key in record:
                    row[key] = record[key]
            if record.get('last_error'):
                row['last_error'] = record['last_error']
            if record.get('publication_error'):
                row['publication_error'] = record['publication_error']
            rows.append(row)
        for pending in sorted(self.root.glob('*.request.json')):
            try:
                request = json.loads(pending.read_text(encoding='utf-8'))
                key = self._request_key(request['owner_uid'], request['request_id'])
                if pending.name != key + '.request.json' or request.get('request_key') != key:
                    raise ValueError('request key mismatch')
                append(request['id'], request)
            except Exception as error:
                raise ManagerError('request inventory is incomplete') from error
        for base in sorted(self.root.iterdir()):
            try:
                self._base(base.name)
            except ManagerError:
                continue
            if base.is_symlink() or not base.is_dir():
                raise ManagerError('workspace inventory has an unexpected asset')
            if base.name in seen:
                continue
            try:
                record = self._load(base.name)
            except Exception as error:
                raise ManagerError('workspace inventory is incomplete') from error
            append(base.name, record)
        return rows

    def _active_ready(self, ident):
        """Caller holds lifecycle lock. Never publish a guessed active path."""
        try:
            provider = self.provider.inspect(ident)
            if (provider.get('initialized') is not True or provider.get('state') != 'attached_writable'
                    or provider.get('operation') is not None or provider.get('boot_id') != self.provider._boot_id()):
                raise ManagerError('active workspace provider is not ready in this boot')
            attached = provider.get('attachment')
            if not isinstance(attached, dict) or attached.get('writeable') is not True:
                raise ManagerError('active workspace has no verified writable attachment')
            if self.provider._device(attached) != provider.get('device'):
                raise ManagerError('active workspace attachment device changed')
            points = [row.get('mount-point') for row in attached.get('system-entities', []) if row.get('mount-point')]
            mount = self.provider.active_root / ident
            if points != [str(mount)]:
                raise ManagerError('active workspace mountpoint changed')
            if not stat.S_ISDIR((mount / 'repo').lstat().st_mode) or not stat.S_ISDIR((mount / 'repo/.git').lstat().st_mode):
                raise ManagerError('active workspace repository identity changed')
        except ManagerError:
            raise
        except Exception as error:
            raise ManagerError('active workspace readiness unavailable: ' + str(error)) from error

    def _not_attached(self, image):
        if self.provider._attached(image):
            raise ManagerError('backing image is attached; cannot reclaim it')

    def _source_fingerprint(self, record):
        source = Path(record['source_repo'])
        common = self._user_git(['rev-parse', '--path-format=absolute', '--git-common-dir'],
                                (record['owner_uid'], record['owner_gid']), cwd=source).decode().strip()
        common = Path(common).resolve(strict=True)
        result = dict(common_git_dir=str(common))
        for key, path in (('checkout', source), ('git_store', common)):
            info = path.lstat()
            if not stat.S_ISDIR(info.st_mode):
                raise ManagerError('source repository identity is not a directory')
            result[key] = [info.st_dev, info.st_ino]
        return result

    def _verify_source(self, record):
        if not record.get('source_identity') or self._source_fingerprint(record) != record['source_identity']:
            raise ManagerError('canonical source repository identity changed')

    @staticmethod
    def _user_git(args, owner, *, cwd, stdout=subprocess.PIPE, input=None):
        if owner[0] <= 0:
            raise ManagerError('Git must run without root privilege')
        env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME='/var/empty', LC_ALL='C',
                   GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                   GIT_TERMINAL_PROMPT='0', GIT_NO_REPLACE_OBJECTS='1')
        credentials = dict(user=owner[0], group=owner[1], extra_groups=[]) if os.geteuid() == 0 else {}
        command = ['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
                   '-c', 'protocol.allow=never', '-c', 'protocol.file.allow=always', *args]
        result = subprocess.run(command, cwd=cwd, env=env, input=input, stdout=stdout,
                                stderr=subprocess.PIPE, timeout=300, **credentials)
        if result.returncode:
            raise ManagerError('unprivileged Git failed: ' + result.stderr.decode('utf-8', 'replace')[-2000:])
        return result.stdout

    def _handoff(self, ident, record):
        """Preserve every bundled ref in the canonical repo before image expiry.

        Git runs as the workspace owner, including when its cwd is the protected
        readonly mount. No repository configuration executes with root authority.
        """
        self._verify_source(record)
        if record.get('handoff_verified'):
            self._verify_handoff(record)
            self._publish_terminal_branch(record)
            return
        base = self._base(ident)
        owner = (record['owner_uid'], record['owner_gid'])
        mounted = self.provider.attach(ident, readonly=True, owner_readable=True)
        frozen = Path(mounted['mountpoint']) / 'repo'
        gitdir = frozen / '.git'
        if gitdir.is_symlink() or not gitdir.is_dir():
            raise ManagerError('frozen workspace lost its independent Git directory')
        if (gitdir / 'objects/info/alternates').exists():
            raise ManagerError('frozen workspace has mutable alternate object dependencies')
        record['has_uncommitted_data'] = self._has_uncommitted_data(frozen, owner)
        self._save(ident, record)
        # Export is owner-readable under a protected ancestor. The user cannot
        # replace it or grant themselves write access to the manager-owned file.
        exports = self.provider.active_root / 'handoffs'
        exports.mkdir(mode=0o711, exist_ok=True)
        self.provider._check_directory(exports, private=False)
        export = exports / (ident + '-' + uuid.uuid4().hex + '.bundle')
        try:
            with export.open('xb') as stream:
                os.chmod(export, 0o600)
                self._user_git(['bundle', 'create', '-', '--all', '--reflog', 'HEAD'],
                               owner, cwd=frozen, stdout=stream)
                stream.flush()
                os.fsync(stream.fileno())
            # staff (the usual macOS primary group) is shared by other users.
            # Grant only this UID read access, retaining manager ownership and
            # exclusive write authority over the exported repository history.
            username = pwd.getpwuid(owner[0]).pw_name
            if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.-]*', username):
                raise ManagerError('unsupported owner ACL identity')
            self.provider._run(['/bin/chmod', '+a', 'user:' + username + ' allow read', str(export)])
            rows = self._user_git(['bundle', 'list-heads', str(export)], owner,
                                  cwd=record['source_repo']).decode('utf-8').splitlines()
            refs = []
            for row in rows:
                oid, separator, source = row.partition(' ')
                if not separator or not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', oid):
                    raise ManagerError('invalid bundle reference record')
                if source == 'HEAD':
                    suffix = 'HEAD'
                elif source.startswith('refs/'):
                    self._user_git(['check-ref-format', source], owner, cwd=record['source_repo'])
                    suffix = source
                else:
                    raise ManagerError('unexpected bundle reference namespace')
                refs.append(dict(oid=oid, source=source,
                                 destination='refs/richos/handoffs/managed/' + ident + '/' + suffix))
            if not any(ref['source'] == 'HEAD' for ref in refs):
                raise ManagerError('bundle has no terminal HEAD')
            record['handoff_refs'] = refs
            self._save(ident, record)
            refspecs = ''.join(ref['source'] + ':' + ref['destination'] + '\n' for ref in refs).encode()
            self._user_git(['fetch', '--no-write-fetch-head', '--no-auto-maintenance',
                            '--stdin', str(export)], owner, cwd=record['source_repo'], input=refspecs)
            # Reflog-only commits are real recovery work too. --all does not
            # name them. Unbundle the full pack then pin each captured reflog
            # tip so later canonical GC cannot discard that history.
            self._user_git(['bundle', 'unbundle', str(export)], owner, cwd=record['source_repo'])
            reflog = self._user_git(['rev-list', '--reflog', '--all', '--no-walk'], owner, cwd=frozen).decode().splitlines()
            for oid in sorted(set(reflog)):
                if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', oid):
                    raise ManagerError('invalid reflog object identity')
                dest = 'refs/richos/handoffs/managed/' + ident + '/reflog/' + oid
                self._user_git(['update-ref', '--no-deref', dest, oid], owner, cwd=record['source_repo'])
                refs.append(dict(source='reflog/' + oid, destination=dest, oid=oid))
            record['handoff_refs'] = refs
            self._verify_handoff(record)
            record.update(handoff_verified=True, handoff_at=time.time())
            self._save(ident, record)
            self._publish_terminal_branch(record)
            self._save(ident, record)
        finally:
            # The image remains until detach succeeds. A busy readonly mount
            # prevents reclamation and is retried, never force-detached.
            if export.exists():
                export.unlink()
            self.provider.detach(ident)

    def _has_uncommitted_data(self, frozen, owner):
        """Prove clean from frozen bytes, independent of Git's stat shortcuts."""
        status = self._user_git(['status', '--porcelain=v1', '-z', '--untracked-files=all',
                                 '--ignored=matching'], owner, cwd=frozen)
        if status or (frozen / '.git/index.lock').exists():
            return True
        flags = self._user_git(['ls-files', '-v', '-z'], owner, cwd=frozen)
        if any(row and (row[:1].islower() or row[:1] == b'S') for row in flags.split(b'\0')):
            return True
        expected = {}
        rows = self._user_git(['ls-tree', '-r', '-z', 'HEAD'], owner, cwd=frozen)
        for row in rows.split(b'\0'):
            if not row:
                continue
            header, name = row.split(b'\t', 1)
            mode, kind, oid = header.split(b' ')
            if kind != b'blob':
                return True  # Nested repositories need their own recovery policy.
            rel = os.fsdecode(name)
            if rel.startswith('/') or any(part in ('..', '.git') for part in Path(rel).parts):
                raise ManagerError('unsafe Git tree path')
            expected[rel] = (mode, oid)
            path = frozen / rel
            for parent in path.parents:
                if parent == frozen:
                    break
                if not stat.S_ISDIR(parent.lstat().st_mode):
                    return True
            try:
                info = path.lstat()
            except FileNotFoundError:
                return True
            if mode == b'120000':
                if not stat.S_ISLNK(info.st_mode):
                    return True
                content = os.fsencode(os.readlink(path))
            elif mode in (b'100644', b'100755'):
                if not stat.S_ISREG(info.st_mode) or bool(info.st_mode & 0o111) != (mode == b'100755'):
                    return True
                content = path.read_bytes()
            else:
                return True
            digest = hashlib.sha1() if len(oid) == 40 else hashlib.sha256()
            digest.update(b'blob ' + str(len(content)).encode() + b'\0')
            digest.update(content)
            if digest.hexdigest().encode() != oid:
                return True
        index = self._user_git(['ls-files', '--stage', '-z'], owner, cwd=frozen)
        observed = {}
        for row in index.split(b'\0'):
            if row:
                header, name = row.split(b'\t', 1)
                mode, oid, stage = header.split(b' ')
                if stage != b'0':
                    return True
                observed[os.fsdecode(name)] = (mode, oid)
        return observed != expected

    def _verify_handoff(self, record):
        self._verify_source(record)
        refs = record.get('handoff_refs')
        if not refs or not any(ref['source'] == 'HEAD' for ref in refs):
            raise ManagerError('verified terminal commit handoff is required')
        owner = (record['owner_uid'], record['owner_gid'])
        for ref in refs:
            actual = self._user_git(['rev-parse', '--verify', ref['destination']], owner,
                                    cwd=record['source_repo']).decode().strip()
            if actual != ref['oid']:
                raise ManagerError('handoff reference does not preserve exported tip')
            self._user_git(['cat-file', '-e', ref['oid']], owner, cwd=record['source_repo'])

    def _publish_terminal_branch(self, record):
        if record.get('branch_published'):
            return
        owner = (record['owner_uid'], record['owner_gid'])
        ref = 'refs/heads/' + record['agent_name']
        self._user_git(['check-ref-format', ref], owner, cwd=record['source_repo'])
        head = next(row['oid'] for row in record['handoff_refs'] if row['source'] == 'HEAD')
        # Publication can race another owner of the name. CAS-create only:
        # never overwrite their ref. The unique handoff namespace still owns
        # the terminal commit if publication is blocked or later moved.
        try:
            self._user_git(['update-ref', '--no-deref', ref, head, '0' * len(head)],
                           owner, cwd=record['source_repo'])
        except ManagerError:
            actual = self._user_git(['rev-parse', '--verify', ref], owner,
                                    cwd=record['source_repo']).decode().strip()
            if actual != head:
                record['publication_error'] = 'terminal branch name already has a different tip'
                return
        record.update(branch_published=True, published_ref=ref, published_tip=head)
        record.pop('publication_error', None)

    def _archive(self, ident, record):
        base = self._base(ident)
        image = base / 'image.sparsebundle'
        archive = base / 'recovery.dmg'
        # Clean detach supplies the cutoff. The private backing image cannot
        # be remounted by the workspace owner during conversion or deletion.
        if record['state'] == 'terminal':
            self.provider.detach(ident)
            record.update(state='detached', detached_at=time.time())
            self._save(ident, record)
        if record['state'] == 'detached':
            # A previous capture can have left a busy readonly mount. Retry
            # its clean detach before attempting another attachment.
            self.provider.detach(ident)
            self._handoff(ident, record)
            source = self.provider.inspect(ident)
            if source['state'] != 'detached' or source.get('attachment'):
                raise ManagerError('clean detachment is not established')
            # A failed conversion has no authority as a recovery copy. Remove
            # only its recorded private output before making another attempt.
            old = record.get('archive_candidate')
            if old:
                if not re.fullmatch(r'recovery-[0-9a-f]{32}\.dmg', old):
                    raise ManagerError('invalid partial archive identity')
                partial = base / old
                if partial.exists() or partial.is_symlink():
                    self._not_attached(partial)
                    self._identity(partial, stat.S_ISREG)
                    partial.unlink()
                    self.provider._sync_dir(base)
            candidate = base / ('recovery-' + uuid.uuid4().hex + '.dmg')
            record.update(archive_candidate=candidate.name)
            self._save(ident, record)
            self.provider._run(['/usr/bin/hdiutil', 'convert', str(image),
                                '-format', 'UDZO', '-o', str(candidate)])
            self.provider._run(['/usr/bin/hdiutil', 'verify', str(candidate)])
            self._not_attached(candidate)
            identity = self._identity(candidate, stat.S_ISREG)
            digest = self._digest(candidate)
            with candidate.open('rb') as stream:
                os.fsync(stream.fileno())
            record.update(state='archive-ready', archive_identity=identity,
                          archive_sha256=digest, image_identity=source['image_identity'])
            self._save(ident, record)
        if record['state'] == 'archive-ready':
            candidate = base / record['archive_candidate']
            if candidate.parent != base or not candidate.name.startswith('recovery-'):
                raise ManagerError('invalid archive promotion identity')
            if archive.exists() or archive.is_symlink():
                # Promotion may have succeeded immediately before a crash.
                if candidate.exists() or self._identity(archive, stat.S_ISREG) != record['archive_identity']:
                    raise ManagerError('unexpected recovery image already exists')
            else:
                if self._identity(candidate, stat.S_ISREG) != record['archive_identity']:
                    raise ManagerError('archive candidate identity changed')
                if self._digest(candidate) != record['archive_sha256']:
                    raise ManagerError('archive candidate bytes changed')
                os.rename(candidate, archive)
                self.provider._sync_dir(base)
            record.update(state='archived', archived_at=time.time(),
                          expires_at=time.time() + record['retention_days'] * 86400)
            self._save(ident, record)
        if record['state'] == 'archived':
            if self._identity(archive, stat.S_ISREG) != record['archive_identity']:
                raise ManagerError('recovery image identity changed')
            if self._digest(archive) != record['archive_sha256']:
                raise ManagerError('recovery image bytes changed')
            self._not_attached(archive)
            self._not_attached(image)
            if image.exists() or image.is_symlink():
                if self._identity(image, stat.S_ISDIR) != record['image_identity']:
                    raise ManagerError('active image identity changed')
                # Persist intent before deleting bands so interruption retries
                # the same private image, never another path or a live mount.
                record['state'] = 'reclaiming'
                self._save(ident, record)
        if record['state'] == 'reclaiming':
            if self._identity(archive, stat.S_ISREG) != record['archive_identity']:
                raise ManagerError('recovery identity changed during reclamation')
            if self._digest(archive) != record['archive_sha256']:
                raise ManagerError('recovery bytes changed during reclamation')
            self._not_attached(image)
            self._not_attached(archive)
            if image.exists() or image.is_symlink():
                if self._identity(image, stat.S_ISDIR) != record['image_identity']:
                    raise ManagerError('reclamation image identity changed')
                shutil.rmtree(image)  # Only the detached private manager image.
                self.provider._sync_dir(base)
            record.update(state='retained', reclaimed_at=time.time())
            self._save(ident, record)
        return record

    def _expire(self, ident, record, now):
        if record['state'] not in ('retained', 'expiring') or now < record['expires_at']:
            return record
        if record.get('has_uncommitted_data') is not False:
            raise ManagerError('recovery retained: unique uncommitted data has no expiry authorization')
        self._verify_handoff(record)
        archive = self._base(ident) / 'recovery.dmg'
        self._not_attached(archive)
        if archive.exists() or archive.is_symlink():
            if self._identity(archive, stat.S_ISREG) != record['archive_identity']:
                raise ManagerError('refuse expiry of replaced recovery image')
            if self._digest(archive) != record['archive_sha256']:
                raise ManagerError('refuse expiry of corrupted recovery image')
            record['state'] = 'expiring'
            self._save(ident, record)
            archive.unlink()
            self.provider._sync_dir(archive.parent)
        elif record['state'] != 'expiring':
            raise ManagerError('recovery image disappeared before expiry')
        record.update(state='expired', expired_at=now)
        self._save(ident, record)
        return record

    def reconcile(self, ident, *, now=None):
        with self._lock(ident):
            record = self._load(ident)
            try:
                if record['state'] in ('terminal', 'detached', 'archive-ready', 'archived', 'reclaiming'):
                    record = self._archive(ident, record)
                record = self._expire(ident, record, time.time() if now is None else now)
                record.pop('last_error', None)
            except Exception as error:
                # Read the last durable transition, not the potentially stale
                # in-memory value from before a successfully persisted step.
                record = self._load(ident)
                record['last_error'] = str(error)
            self._save(ident, record)
            return record

    def sweep(self):
        results = []
        seen = set()
        for pending in sorted(self.root.glob('*.request.json')):
            try:
                request = json.loads(pending.read_text(encoding='utf-8'))
                ident = request['id']
                self._base(ident)
                if 'request_id' not in request:
                    # Earlier prototype records have no caller idempotency key.
                    if pending.name != ident + '.request.json':
                        raise ManagerError('legacy pending request identity mismatch')
                    if not (self._base(ident) / 'lifecycle.json').exists():
                        results.append(dict(id=ident, state='creation-incomplete',
                                            session_id=request.get('session_id')))
                        seen.add(ident)
                    continue
                key = self._request_key(request['owner_uid'], request['request_id'])
                if pending.name != key + '.request.json' or request.get('request_key') != key:
                    raise ManagerError('pending request identity mismatch')
                with self._request_lock(key):
                    recovered = self._recover_create(request)
                if recovered['state'] == 'creation-incomplete':
                    results.append(recovered)
                    seen.add(ident)
            except Exception as error:
                results.append(dict(state='request-error', last_error=str(error)))
        for base in sorted(self.root.iterdir()):
            if not base.is_dir() or base.is_symlink() or base.name in seen:
                continue
            try:
                self._base(base.name)
            except ManagerError:
                continue
            if not (base / 'lifecycle.json').exists():
                results.append(dict(id=base.name, state='creation-incomplete'))
                continue
            try:
                with self._lock(base.name):
                    record = self._load(base.name)
                    self._terminalize_after_boot(base.name, record)
            except Exception as error:
                with self._lock(base.name):
                    record = self._load(base.name)
                    record['last_error'] = str(error)
                    self._save(base.name, record)
                results.append(record)
                continue
            results.append(self.reconcile(base.name))
        return results
