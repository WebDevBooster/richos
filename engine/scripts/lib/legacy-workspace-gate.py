#!/usr/bin/env python3
"""Root-only, explicitly authorized legacy gate. No capture or deletion API."""
import contextlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('legacy_planner', HERE / 'legacy-workspace-maintenance.py')
planner = importlib.util.module_from_spec(spec);spec.loader.exec_module(planner)
filesystem = planner.filesystem
spec = importlib.util.spec_from_file_location('legacy_inspection', HERE / 'legacy-workspace-inspection.py')
inspection = importlib.util.module_from_spec(spec);spec.loader.exec_module(inspection)
INTERPRETER = '/Library/Developer/CommandLineTools/usr/bin/python3'


class GateError(RuntimeError):
    pass


def owner_report(policy, context, *, require_root=True):
    """Run repository and history inspection only after dropping root authority."""
    context = inspection.normalized_context(context)
    helper = HERE / 'legacy-workspace-inspection.py'
    if require_root:
        spec = importlib.util.spec_from_file_location('legacy_runtime', HERE / 'managed-workspace-broker.py')
        runtime = importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
        runtime.validate_runtime()
        if Path(sys.executable).resolve() != Path(INTERPRETER).resolve():
            raise GateError('fixed Command Line Tools interpreter required')
        runtime.protected_path(helper, regular=True)
    elif os.geteuid() != 0 and (os.geteuid(), os.getegid()) != (context['owner_uid'], context['owner_gid']):
        raise GateError('disposable inspection must use its actual owner')
    payload = {'policy': policy, 'inspection_context': context}
    if 'operator_attestation' in context:
        descriptor = context['operator_attestation']
        path = Path(descriptor['path'])
        if str(uuid.UUID(path.stem)) != path.stem or path.suffix != '.json':
            raise GateError('minted operator attestation UUID path required')
        if require_root:
            installed_policy = runtime.validate_policy(json.loads(runtime.protected_path(
                runtime.validate_runtime().parent.parent / 'policy.json', regular=True).read_text()))
            if path.parent != Path(installed_policy['private_root']) / 'legacy-authorizations':
                raise GateError('operator attestation is outside protected authorization namespace')
            runtime.protected_path(path, regular=True)
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600):
            raise GateError('operator attestation ownership or mode is invalid')
        with path.open('rb') as stream: raw = stream.read(1024*1024+1)
        if len(raw) > 1024*1024:
            raise GateError('operator attestation exceeds byte limit')
        document = json.loads(raw)
        if planner.history._digest(document) != descriptor['sha256']:
            raise GateError('protected operator attestation hash mismatch')
        if (not isinstance(document, dict) or document.get('owner_uid') != context['owner_uid']
                or document.get('owner_gid') != context['owner_gid']):
            raise GateError('protected operator attestation belongs to another owner')
        payload['operator_attestation'] = document
    credentials = dict(user=context['owner_uid'], group=context['owner_gid'], extra_groups=[]) if os.geteuid() == 0 else {}
    result = subprocess.run([INTERPRETER if require_root else sys.executable, '-I', '-S', '-B', str(helper)],
        input=json.dumps(payload).encode(),
        capture_output=True, cwd='/', timeout=120, **credentials,
        env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'HOME':context['owner_home'], 'LC_ALL':'C', 'LANG':'C', 'TZ':'UTC0'})
    if result.returncode:
        raise GateError('unprivileged inspection failed: ' + result.stderr.decode(errors='replace')[:1024])
    report = json.loads(result.stdout)
    if not isinstance(report, dict) or report.get('inspection_context') != context:
        raise GateError('inspection returned a different owner context')
    return report


class LegacyGate:
    def __init__(self, vault, *, require_root=True, inspection_context=None):
        self.require_root = require_root
        self.uid, self.gid = os.geteuid(), os.getegid()
        if require_root and (self.uid != 0 or sys.platform != 'darwin'):
            raise GateError('macOS root authority required')
        if require_root and inspection_context is None:
            raise GateError('explicit approved owner inspection context required')
        self.inspection_context = inspection.normalized_context(inspection_context) if inspection_context is not None else None
        self.vault = Path(vault).resolve(strict=True)
        for path in (self.vault, *self.vault.parents) if require_root else (self.vault,):
            info = path.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o022 or (require_root and info.st_uid != 0):
                raise GateError('vault namespace is not protected')
            self._no_acl(path)
        if self.vault.stat().st_uid != self.uid or stat.S_IMODE(self.vault.stat().st_mode) != 0o700:
            raise GateError('dedicated manager-owned mode-0700 vault required')

    @staticmethod
    def _boot():
        result = subprocess.run(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid'],
                                capture_output=True, check=True, timeout=5,
                                env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C'})
        value = result.stdout.decode('ascii').strip()
        return str(uuid.UUID(value))

    @staticmethod
    def _no_acl(path):
        if sys.platform != 'darwin':
            return  # Only the non-root disposable test mode is portable.
        result = subprocess.run(['/bin/ls', '-lde', str(path)], capture_output=True,
                                timeout=5, env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
        if result.returncode or len(result.stdout.splitlines()) != 1:
            raise GateError('extended ACL or unreadable ACL metadata: ' + str(path))

    @staticmethod
    def _sync(path):
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def _base(self, ident):
        if not isinstance(ident, str) or str(uuid.UUID(ident)) != ident:
            raise GateError('server-minted gate UUID required')
        return self.vault / ident

    @contextlib.contextmanager
    def _lock(self, ident):
        base = self._base(ident)
        fd = os.open(base / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield base
        finally:
            os.close(fd)

    def _save(self, base, record):
        tmp = base / 'state.next'
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(record, stream, sort_keys=True);stream.write('\n');stream.flush();os.fsync(stream.fileno())
        os.replace(tmp, base / 'state.json');self._sync(base)

    def _load(self, base):
        record = json.loads((base / 'state.json').read_text())
        if record.get('version') != 1 or record.get('id') != base.name:
            raise GateError('invalid gate journal')
        if self.inspection_context is not None and record.get('inspection_context') != self.inspection_context:
            raise GateError('gate belongs to another owner inspection context')
        return record

    @staticmethod
    def _require_completed_mutation(base):
        for name in ('mutation.json','retirement.json'):
            path = base / name
            if os.path.lexists(path):
                if path.is_symlink():
                    raise GateError('invalid mutation receipt')
                journal = json.loads(path.read_text())
                if journal.get('version') != 1 or journal.get('gate_id') != base.name or journal.get('phase') != 'complete':
                    raise GateError('incomplete frozen mutation requires replay before access can reopen')

    def _append(self, base, value):
        fd = os.open(base / 'metadata.jsonl', os.O_CREAT | os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'a') as stream:
            stream.write(json.dumps(value, sort_keys=True) + '\n');stream.flush();os.fsync(stream.fileno())
        self._sync(base)

    @staticmethod
    def _entries(base):
        file = base / 'metadata.jsonl'
        if not file.exists():
            return {}
        data = file.read_bytes()
        if data and not data.endswith(b'\n'):
            raise GateError('incomplete metadata journal; admin recovery required')
        result = {}
        for line in data.splitlines():
            item = json.loads(line)
            name = item['relative']
            if name in result or Path(name).is_absolute() or '..' in Path(name).parts:
                raise GateError('invalid metadata journal path')
            result[name] = item
        return result

    def _metadata(self, path, *, allow_hardlinks=False):
        info = path.lstat()
        kind = 'directory' if stat.S_ISDIR(info.st_mode) else 'file' if stat.S_ISREG(info.st_mode) else 'symlink' if stat.S_ISLNK(info.st_mode) else None
        if kind is None or getattr(info, 'st_flags', 0) or info.st_mode & 0o6000:
            raise GateError('unsupported file type, flags or set-ID mode: ' + str(path))
        if kind != 'directory' and info.st_nlink != 1 and not allow_hardlinks:
            raise GateError('multiply linked object: ' + str(path))
        if info.st_dev != self.vault.stat().st_dev:
            raise GateError('cross-device object: ' + str(path))
        self._no_acl(path)
        value = dict(device=filesystem.filesystem_token(path, info=info), inode=info.st_ino, uid=info.st_uid, gid=info.st_gid,
                     mode=stat.S_IMODE(info.st_mode), kind=kind)
        if kind == 'symlink':
            value['target'] = os.readlink(path)
        return value

    def _same(self, info, expected):
        # A live descriptor must still belong to the current vault filesystem.
        # Its persistent identity uses that filesystem's UUID, never a saved
        # mount number that the kernel can renumber during reboot.
        vault = self.vault.lstat()
        return (info.st_dev == vault.st_dev and
                (filesystem.filesystem_token(self.vault, info=vault), info.st_ino) ==
                (expected['device'], expected['inode']))

    def _apply(self, path, original, *, restore=False):
        current = self._metadata(path, allow_hardlinks=restore)
        if (current['device'], current['inode'], current['kind']) != (original['device'], original['inode'], original['kind']):
            raise GateError('metadata target identity changed: ' + str(path))
        uid, gid = (original['uid'], original['gid']) if restore else (self.uid, self.gid)
        mode = original['mode'] if restore else 0o700 if original['kind'] == 'directory' else 0o600
        fields = ('uid', 'gid', 'mode')
        if current['uid'] != self.uid:
            if any(current[key] != original[key] for key in fields):
                raise GateError('unprotected metadata changed; admin recovery required')
            if restore:
                return  # Already restored. Never overwrite subsequent user metadata.
        if original['kind'] == 'symlink':
            if current['target'] != original['target']:
                raise GateError('symlink contents changed')
            os.chown(path, uid, gid, follow_symlinks=False)
            return
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            if not self._same(os.fstat(fd), original):
                raise GateError('opened object identity changed')
            if restore:
                # Return ownership last so an interrupted restore can recognize
                # already returned objects without rewriting their metadata.
                os.fchmod(fd, mode);os.fchown(fd, uid, gid)
            else:
                os.fchown(fd, uid, gid);os.fchmod(fd, mode)
            os.fsync(fd)
        finally:
            os.close(fd)

    def _protect_tree(self, base, path, entries):
        relative = str(path.relative_to(base))
        if relative not in entries:
            original = dict(self._metadata(path), relative=relative)
            self._append(base, original)  # Original metadata is durable before mutation.
            entries[relative] = original
        original = entries[relative]
        self._apply(path, original)
        if original['kind'] == 'directory':
            # Revoke directory access before enumeration: old directory FDs
            # cannot create another child after this point without privilege.
            for child in sorted(path.iterdir()):
                self._protect_tree(base, child, entries)

    def _preflight_tree(self, path):
        original = self._metadata(path)
        if original['kind'] == 'directory':
            for child in sorted(path.iterdir()):
                self._preflight_tree(child)

    def _parent(self, row):
        path = Path(row['path'])
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        if not self._same(os.fstat(fd), row['metadata']):
            os.close(fd);raise GateError('source parent identity changed')
        return fd

    def _validate_report(self, report, approved_sha256):
        if planner.history._digest(report) != approved_sha256:
            raise GateError('explicit matching offline gate authorization required')
        if report.get('mode') != 'planning-only' or report.get('errors') or not report.get('repositories'):
            raise GateError('complete reviewed maintenance plan required')
        if any(not row.get('inventory_complete') or row.get('blockers') for row in report['repositories']):
            raise GateError('live, unknown or incomplete maintenance plan cannot be gated')
        policy = {'repositories': {row['alias']: {'path': row['canonical_repository']['path']} for row in report['repositories']}}
        if self.inspection_context is not None:
            if report.get('inspection_context') != self.inspection_context:
                raise GateError('approved report has a different inspection owner or history')
            current = owner_report(policy, self.inspection_context, require_root=self.require_root)
        else:
            # Compatibility for disposable, non-production state-machine tests.
            txs, rows, errors = planner.history.load_history()
            current = planner.plan(policy, txs, rows, input_errors=errors)
        if planner.history._digest(current) != approved_sha256:
            raise GateError('maintenance evidence changed; new review required')

    def stage(self, report, *, approved_sha256):
        self._validate_report(report, approved_sha256)
        roots, parents = [], {}
        for repo in report['repositories']:
            for gate in repo['gate_roots']:
                source = Path(gate['path']);original = self._metadata(source)
                pin = gate.get('identity', gate)
                if (original['device'], original['inode']) != (pin['device'], pin['inode']):
                    raise GateError('source root changed')
                parent = str(source.parent)
                if parent not in parents:
                    original_parent = self._metadata(source.parent)
                    approved_parent = next(p for p in repo['temporary_parent_gates'] if p['path'] == parent)['identity']
                    if any(original_parent[key] != approved_parent[key] for key in ('device','inode','uid','gid','mode')):
                        raise GateError('temporary parent gate identity changed')
                    parents[parent] = dict(path=parent, metadata=original_parent, restored=False)
                roots.append(dict(source=str(source), held='content/' + str(len(roots)), metadata=original, moved=False))
        for root in roots:
            self._preflight_tree(Path(root['source']))
        boot = self._boot()  # Do not create a reservation if kernel identity is unreadable.
        ident = str(uuid.uuid4());base = self._base(ident);base.mkdir(mode=0o700);(base / 'content').mkdir(mode=0o700)
        self._sync(self.vault)
        with (base / 'plan.json').open('x') as stream:
            os.chmod(base / 'plan.json', 0o600)
            json.dump(report, stream, sort_keys=True);stream.write('\n');stream.flush();os.fsync(stream.fileno())
        record = dict(version=1, id=ident, phase='staging', approved_sha256=approved_sha256,
                      roots=roots, parents=list(parents.values()), started_boot_id=boot,
                      inspection_context=self.inspection_context)
        self._save(base, record)
        return self.resume(ident)

    def resume(self, ident):
        with self._lock(ident) as base:
            self._require_completed_mutation(base)
            record = self._load(base)
            if record['phase'] != 'staging':
                return self._status(base, record)
            for parent in record['parents']:
                if parent['restored']:
                    continue
                self._apply(Path(parent['path']), parent['metadata'])
            entries = self._entries(base)
            for root in record['roots']:
                source, held = Path(root['source']), base / root['held']
                parent = next(p for p in record['parents'] if p['path'] == str(source.parent))
                fd = self._parent(parent)
                try:
                    if held.exists():
                        if not self._same(held.lstat(), root['metadata']):
                            raise GateError('held root identity changed')
                    else:
                        info = os.stat(source.name, dir_fd=fd, follow_symlinks=False)
                        if not self._same(info, root['metadata']):
                            raise GateError('source root was replaced')
                        os.rename(source.name, held, src_dir_fd=fd)
                        os.fsync(fd);self._sync(held.parent)
                    root['moved'] = True;self._save(base, record)
                    self._protect_tree(base, held, entries)
                finally:
                    os.close(fd)
            self._verify_held(base, record, entries)
            # A crash before this receipt deliberately requires another boot.
            record['gated_boot_id'] = self._boot()
            for parent in record['parents']:
                if not parent['restored']:
                    self._apply(Path(parent['path']), parent['metadata'], restore=True)
                    parent['restored'] = True;self._save(base, record)
            record['phase'] = 'gated';self._save(base, record)
            return self._status(base, record)

    def _verify_held(self, base, record, entries):
        found = set()
        def scan_error(error):
            raise error
        for root in record['roots']:
            path = base / root['held']
            if root.get('retired'):
                if os.path.lexists(path):
                    raise GateError('retired gate root unexpectedly exists')
                continue
            paths = [path]
            for directory, dirs, files in os.walk(path, followlinks=False, onerror=scan_error):
                paths.extend(Path(directory) / name for name in dirs + files)
            for path in paths:
                relative = str(path.relative_to(base));found.add(relative)
                original = entries.get(relative)
                if original is None:
                    raise GateError('unrecorded held object')
                current = self._metadata(path)
                if (current['device'], current['inode'], current['kind']) != (original['device'], original['inode'], original['kind']):
                    raise GateError('held object identity changed')
                if current['uid'] != self.uid or current['gid'] != self.gid:
                    raise GateError('held ownership is not protected')
                if current['kind'] != 'symlink' and current['mode'] != (0o700 if current['kind'] == 'directory' else 0o600):
                    raise GateError('held mode is not protected')
                if current['kind'] == 'symlink' and current['target'] != original['target']:
                    raise GateError('held symlink changed')
        if found != set(entries):
            raise GateError('held object inventory changed')

    def _status(self, base, record):
        self._require_completed_mutation(base)
        cutoff = False
        if record['phase'] == 'gated':
            previous = record.get('gated_boot_id')
            if not isinstance(previous, str) or str(uuid.UUID(previous)) != previous:
                raise GateError('unknown gate boot identity')
            self._verify_held(base, record, self._entries(base))
            cutoff = self._boot() != previous
        return dict(id=record['id'], phase=record['phase'], boot_cutoff_verified=cutoff,
                    execution_authorized=False, deletion_implemented=False,
                    approved_sha256=record['approved_sha256'])

    def inspect(self, ident):
        with self._lock(ident) as base:
            return self._status(base, self._load(base))

    @contextlib.contextmanager
    def frozen_view(self, ident, *, approved_sha256):
        """Root executor read boundary. Lock excludes restore for this context."""
        with self._lock(ident) as base:
            record = self._load(base)
            report = json.loads((base / 'plan.json').read_text())
            if (approved_sha256 != record['approved_sha256']
                    or planner.history._digest(report) != approved_sha256):
                raise GateError('approved maintenance plan identity changed')
            if not self._status(base, record)['boot_cutoff_verified']:
                raise GateError('verified later-boot frozen gate required')
            yield dict(id=ident, approved_sha256=approved_sha256, plan=report,
                       roots=[dict(root, held_path=str(base / root['held'])) for root in record['roots']],
                       metadata=self._entries(base), observed_boot_id=self._boot(),
                       deletion_authorized=False)

    def restore(self, ident, *, approved_sha256):
        with self._lock(ident) as base:
            self._require_completed_mutation(base)
            record = self._load(base)
            if approved_sha256 != record['approved_sha256']:
                raise GateError('explicit restore authorization required')
            if record['phase'] == 'restored':
                return self._status(base, record)
            if record['phase'] != 'restoring':
                if record['phase'] == 'staging':
                    previous = record.get('started_boot_id')
                    if (not isinstance(previous, str) or str(uuid.UUID(previous)) != previous
                            or self._boot() == previous):
                        raise GateError('verified later boot required before partial admin restore')
                elif not self._status(base, record)['boot_cutoff_verified']:
                    raise GateError('verified later boot required before restoring access')
                for root in record['roots']:
                    if root.get('retired'):
                        continue
                    if os.path.lexists(root['source']):
                        if ((base / root['held']).exists() or record['phase'] != 'staging'
                                or not self._same(Path(root['source']).lstat(), root['metadata'])):
                            raise GateError('restore destination exists; it will not be overwritten')
                record['restore_parents'] = [dict(path=p['path'], metadata=(p['metadata'] if not p['restored']
                                                else self._metadata(Path(p['path']))), restored=False)
                                             for p in record['parents']]
                for old, new in zip(record['parents'], record['restore_parents']):
                    if (old['metadata']['device'], old['metadata']['inode']) != (new['metadata']['device'], new['metadata']['inode']):
                        raise GateError('restore parent identity changed')
                record['phase'] = 'restoring';self._save(base, record)
            for parent in record['restore_parents']:
                if not parent['restored']:
                    self._apply(Path(parent['path']), parent['metadata'])
            entries = self._entries(base)
            for root in record['roots']:
                if root.get('retired'):
                    continue
                source, held = Path(root['source']), base / root['held']
                parent = next(p for p in record['restore_parents'] if p['path'] == str(source.parent))
                fd = self._parent(parent)
                try:
                    if held.exists():
                        try:
                            os.stat(source.name, dir_fd=fd, follow_symlinks=False)
                        except FileNotFoundError:
                            pass
                        else:
                            raise GateError('restore destination appeared; refusing overwrite')
                        prefix = root['held']
                        names = [name for name in entries if name == prefix or name.startswith(prefix + '/')]
                        for name in sorted(names, key=lambda value: len(Path(value).parts), reverse=True):
                            self._apply(base / name, entries[name], restore=True)
                        os.rename(held, source.name, dst_dir_fd=fd)
                        os.fsync(fd);self._sync(held.parent)
                    elif not self._same(os.stat(source.name, dir_fd=fd, follow_symlinks=False), root['metadata']):
                        raise GateError('restored root identity unavailable')
                    root['restored'] = True;self._save(base, record)
                finally:
                    os.close(fd)
            for parent in record['restore_parents']:
                if not parent['restored']:
                    self._apply(Path(parent['path']), parent['metadata'], restore=True)
                    parent['restored'] = True;self._save(base, record)
            record['phase'] = 'restored';self._save(base, record)
            return self._status(base, record)
