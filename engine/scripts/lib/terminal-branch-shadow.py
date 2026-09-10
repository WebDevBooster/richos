#!/usr/bin/env python3
"""Prepare reviewed branch ref deltas in a trusted shadow, never publish them.

The gate supplies and locks the verified later-boot frozen view. Git reads a
fresh controlled config and copied ref metadata, with frozen objects read-only.
No Git command uses the held common directory as its Git directory.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

MAX_METADATA_BYTES = 16 * 1024 * 1024
MAX_METADATA_FILES = 10000
MAX_SELECTION_BYTES = 128 * 1024
MAX_SELECTED_BRANCHES = 128
# THE TRUSTED GIT, PER PLATFORM — and this is a CONSOLIDATION, not a new policy.
#
# This constant named Apple's Command Line Tools binary and nothing else, so on
# any host that is not macOS the default below resolves to a path under
# `/Library`, which does not exist, and `_authority` raised FileNotFoundError
# out of `Path(...).resolve(strict=True)` before it could reach any of its own
# refusals. `legacy-workspace-orphan.acceptance` failed exactly that way on
# Linux on 2026-09-09 (3 errors, "No such file or directory: '/Library'"),
# while passing on macOS.
#
# THE POLICY THIS ENCODES ALREADY EXISTED, COPIED BY HAND INTO FIVE TEST FILES.
# legacy-workspace-expiry, legacy-workspace-retirement, terminal-branch-shadow,
# terminal-recovery-shadow and legacy-workspace-operator-integration each write
# `shadow.TRUSTED_GIT if sys.platform == 'darwin' else '/usr/bin/git'` at their
# call sites. So the platform answer was already decided; it just was not
# written in the one place the DEFAULT is taken from, and the one acceptance
# suite that did not copy the incantation is the one that went red.
#
# WHY `/usr/bin/git` IS THE RIGHT NON-DARWIN VALUE, and why that is not a
# loosening: `_authority` already REFUSES `/usr/bin/git` `if sys.platform ==
# 'darwin'`, because there it is the developer-selection shim rather than a
# binary. Off darwin it is the real binary, root-owned, on the same
# root-protected path the `require_root` arm walks. The refusal was always
# darwin-gated; only the default was not.
if sys.platform == 'darwin':
    TRUSTED_GIT = '/Library/Developer/CommandLineTools/usr/bin/git'
else:
    TRUSTED_GIT = '/usr/bin/git'
OID = re.compile(r'[0-9a-f]{40}|[0-9a-f]{64}')


class ShadowError(RuntimeError):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def _private_directory(path, gate):
    path = Path(path).resolve(strict=True)
    for entry in (path, *path.parents) if gate.require_root else (path,):
        info = entry.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ShadowError('private shadow directory is not protected')
        if gate.require_root:
            gate._no_acl(entry)
    if path.stat().st_mode & 0o077:
        raise ShadowError('private mode-0700 scratch directory required')
    return path


def _authority(gate, scratch_root, executable):
    if gate.require_root and os.geteuid() != 0:
        raise ShadowError('root gate required')
    # A trusted binary that is not there is a REFUSAL, and it is spelled the same
    # way as every other refusal in this function. `resolve(strict=True)` raises
    # FileNotFoundError, which is not a ShadowError, so a caller catching
    # ShadowError saw an unhandled exception with a traceback pointing at
    # pathlib instead of a message naming the missing binary. That is how the
    # macOS-only default above surfaced on Linux: as posixpath internals, three
    # frames from anything a reader could act on.
    try:
        executable = Path(executable).resolve(strict=True)
    except OSError as error:
        raise ShadowError('fixed Git executable required: %s (%s)' % (executable, error)) from error
    if sys.platform == 'darwin' and str(executable) == '/usr/bin/git':
        raise ShadowError('developer-selection Git shim is not a trusted executable')
    if not executable.is_file():
        raise ShadowError('fixed Git executable required')
    if gate.require_root:
        for path in (executable, *executable.parents):
            info = path.lstat()
            if info.st_uid != 0 or info.st_mode & 0o022:
                raise ShadowError('Git runtime is not root protected')
            gate._no_acl(path)
    return _private_directory(scratch_root, gate), str(executable)


def _git(binary, shadow, objects, *args, input=None):
    env = {'PATH': '/usr/bin:/bin', 'HOME': '/var/empty', 'LC_ALL': 'C',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_SYSTEM': '/dev/null', 'GIT_CONFIG_GLOBAL': '/dev/null',
           'GIT_TERMINAL_PROMPT': '0', 'GIT_NO_REPLACE_OBJECTS': '1',
           'GIT_OBJECT_DIRECTORY': str(objects), 'GIT_EXEC_PATH': str(Path(binary).parent)}
    result = subprocess.run([binary, '--no-replace-objects', '--git-dir', str(shadow),
                             '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
                             '-c', 'protocol.allow=never', *args],
                            cwd=shadow, env=env, input=input, capture_output=True, timeout=30)
    if result.returncode:
        raise ShadowError('trusted Git failed: ' + result.stderr.decode('utf-8', 'replace')[-1000:])
    return result.stdout


def _bytes(path, budget):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ShadowError('ref metadata is not an independent regular file')
    if info.st_size > budget:
        raise ShadowError('ref metadata exceeds bounded shadow budget')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read(budget + 1)
        after = os.fstat(fd)
        stamp = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if len(data) > budget or stamp(info) != stamp(before) or stamp(before) != stamp(after) or stamp(after) != stamp(path.lstat()):
            raise ShadowError('ref metadata changed while reading')
        return data
    finally:
        os.close(fd)


def _metadata(common):
    """Snapshot refs and reflogs only. Never copy or write object storage."""
    files, used = {}, 0
    def visit(path):
        nonlocal used
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            for child in sorted(path.iterdir()):
                visit(child)
        else:
            if len(files) >= MAX_METADATA_FILES:
                raise ShadowError('ref metadata exceeds bounded shadow file count')
            data = _bytes(path, MAX_METADATA_BYTES - used)
            used += len(data);files[path.relative_to(common).as_posix()] = data
    for name in ('refs', 'logs/refs', 'packed-refs'):
        path = common / name
        if os.path.lexists(path):
            visit(path)
    return files


def _file_manifest(files):
    return {name: {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()} for name, data in sorted(files.items())}


def _resolve(view, alias):
    rows = [row for row in view['plan']['repositories'] if row['alias'] == alias]
    if len(rows) != 1:
        raise ShadowError('approved repository alias is not unique')
    source = Path(rows[0]['common_git_directory']['path'])
    mappings = [root for root in view['roots'] if source == Path(root['source']) or Path(root['source']) in source.parents]
    if len(mappings) != 1:
        raise ShadowError('common Git storage is not covered by one frozen root')
    root = mappings[0]
    path = Path(root['held_path']) / source.relative_to(root['source'])
    if path.is_symlink() or not path.is_dir():
        raise ShadowError('frozen common Git directory is unavailable')
    return path


def _storage(common):
    # The gate planner rejects these too. Repeat at the actual frozen boundary.
    for name in ('shallow', 'info/grafts', 'reftable'):
        if os.path.lexists(common / name):
            raise ShadowError('unsupported shallow, grafted or reftable storage')
    objects = common / 'objects'
    device = objects.lstat().st_dev
    if not objects.is_dir() or objects.is_symlink():
        raise ShadowError('independent frozen object directory required')
    def onerror(error):
        raise error
    for directory, dirs, files in os.walk(objects, followlinks=False, onerror=onerror):
        for name in dirs + files:
            path = Path(directory) / name;info = path.lstat()
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)) or info.st_dev != device or (stat.S_ISREG(info.st_mode) and info.st_nlink != 1):
                raise ShadowError('external frozen object dependency')
            if name in ('alternates', 'http-alternates') and path.parent == objects / 'info' or name.endswith('.promisor') and path.parent == objects / 'pack':
                raise ShadowError('external frozen object dependency')
    return objects


def _registry(common, *, excluded_admin_names=()):
    """Read registered HEADs, optionally omitting one journaled retiring admin.

    Only a retirement replay that has already verified its exact journal roots
    and every remaining held inode may supply an exclusion. Public observation
    and preparation always use the complete registry.
    """
    if (not isinstance(excluded_admin_names, (tuple, list, set, frozenset))
            or len(excluded_admin_names) > 1
            or any(not isinstance(name, str) or not name or name in ('.', '..')
                   or '/' in name or '\0' in name for name in excluded_admin_names)):
        raise ShadowError('at most one exact linked admin component may be excluded')
    paths = [common / 'HEAD']
    worktrees = common / 'worktrees'
    if os.path.lexists(worktrees):
        if worktrees.is_symlink() or not worktrees.is_dir():
            raise ShadowError('worktree registry is unavailable')
        for directory in sorted(worktrees.iterdir()):
            if directory.is_symlink() or not directory.is_dir():
                raise ShadowError('malformed worktree registry entry')
            if directory.name in excluded_admin_names:
                continue
            paths.append(directory / 'HEAD')
            # Missing linkage cannot be silently treated as detached/dead.
            linkage = _bytes(directory / 'gitdir', 65536).decode('utf-8').strip()
            if not linkage or not Path(linkage).is_absolute():
                raise ShadowError('worktree registry linkage is unavailable')
    rows = []
    for path in paths:
        raw = _bytes(path, 65536)
        if raw.endswith(b'\n'):
            raw = raw[:-1]
        if raw.startswith(b'ref: refs/heads/') and b'\n' not in raw:
            branch = raw[5:].decode('utf-8')
        elif OID.fullmatch(raw.decode('ascii', 'strict')):
            branch = None
        else:
            raise ShadowError('unreadable or noncanonical registered HEAD')
        rows.append({'path': path.relative_to(common).as_posix(), 'branch': branch,
                     'sha256': hashlib.sha256(raw).hexdigest()})
    return rows


def _attached_branches(registry, refs):
    result=set()
    for row in registry:
        current=row['branch'];seen=set()
        while current is not None:
            if current in seen or current not in refs:
                raise ShadowError('registered HEAD does not resolve to a readable branch')
            seen.add(current)
            symbolic=refs[current]['symbolic']
            if symbolic is None:
                result.add(current)
                break
            current=symbolic
    return result


def _logical_refs(binary, directory, objects, files):
    """Require Git to account for every declared loose/packed reference."""
    declared={};checked=set();last_packed=None;peeled=False
    def valid_name(name):
        if not name.startswith('refs/'):
            raise ShadowError('ref storage declares an invalid namespace')
        if name not in checked:
            _git(binary,directory,objects,'check-ref-format',name);checked.add(name)
    for line in files.get('packed-refs',b'').splitlines():
        if not line or line.startswith(b'#'):
            continue
        if line.startswith(b'^'):
            if last_packed is None or peeled or not OID.fullmatch(line[1:].decode('ascii')):
                raise ShadowError('malformed packed peeled reference')
            peeled=True;continue
        fields=line.decode('utf-8').split(' ')
        if len(fields)!=2 or not OID.fullmatch(fields[0]):
            raise ShadowError('malformed packed reference')
        oid,name=fields;valid_name(name)
        if name in declared:
            raise ShadowError('duplicate packed reference')
        declared[name]={'oid':oid,'symbolic':None};last_packed=name;peeled=False
    for name,data in files.items():
        if not name.startswith('refs/'):
            continue
        valid_name(name)
        value=data.decode('utf-8')
        if value.endswith('\n'):
            value=value[:-1]
        if OID.fullmatch(value):
            declared[name]={'oid':value,'symbolic':None}
        elif value.startswith('ref: refs/') and '\n' not in value:
            target=value[5:];valid_name(target)
            declared[name]={'oid':None,'symbolic':target}
        else:
            raise ShadowError('malformed loose reference')
    resolved={}
    for name,record in declared.items():
        target=name;seen=set()
        while True:
            if target in seen or target not in declared:
                raise ShadowError('dangling or cyclic symbolic reference')
            seen.add(target);value=declared[target]
            if value['symbolic'] is None:
                resolved[name]={'oid':value['oid'],'symbolic':record['symbolic']};break
            target=value['symbolic']
    observed={}
    output=_git(binary,directory,objects,'for-each-ref','--format=%(refname)%00%(objectname)%00%(symref)')
    for row in output.splitlines():
        fields=row.decode('utf-8').split('\0')
        if len(fields)!=3 or not OID.fullmatch(fields[1]) or fields[0] in observed:
            raise ShadowError('ref reader returned malformed metadata')
        observed[fields[0]]={'oid':fields[1],'symbolic':fields[2] or None}
    if set(observed)!=set(resolved) or any(observed[name]['oid']!=record['oid'] or bool(observed[name]['symbolic'])!=bool(record['symbolic']) for name,record in resolved.items()):
        raise ShadowError('Git omitted or changed declared ref metadata')
    oids=sorted({row['oid'] for row in resolved.values()})
    if oids:
        checked_objects=_git(binary,directory,objects,'cat-file','--batch-check=%(objectname) %(objecttype)',input=('\n'.join(oids)+'\n').encode()).decode().splitlines()
        if len(checked_objects)!=len(oids) or any(line.split(' ') not in ([oid,'commit'],[oid,'tag'],[oid,'tree'],[oid,'blob']) for oid,line in zip(oids,checked_objects)):
            raise ShadowError('declared ref object is missing or unreadable')
    return resolved


def _shadow(common, directory, binary, *, excluded_admin_names=()):
    files = _metadata(common);objects = _storage(common)
    registry = _registry(common, excluded_admin_names=excluded_admin_names)
    # Determine the object hash format from immutable current HEAD/ref object
    # names, never execute or load the original repository configuration.
    packed = files.get('packed-refs', b'')
    lengths = {len(line.split(b' ', 1)[0]) for line in packed.splitlines()
               if line and line[:1] not in (b'#', b'^')}
    for name, data in files.items():
        if name.startswith('refs/') and OID.fullmatch(data.decode('ascii', 'ignore').strip()):
            lengths.add(len(data.strip()))
    if len(lengths) != 1 or next(iter(lengths)) not in (40, 64):
        raise ShadowError('unambiguous ref object format required')
    bits = next(iter(lengths));fmt = 'sha1' if bits == 40 else 'sha256'
    # No templates, source includes, aliases, hooks, filters or remote config.
    env = {'PATH':'/usr/bin:/bin','HOME':'/var/empty','GIT_CONFIG_NOSYSTEM':'1',
           'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_SYSTEM':'/dev/null','LC_ALL':'C'}
    subprocess.run([binary,'init','--bare','--template=','--object-format='+fmt,'-q',str(directory)],
                   env=env,cwd=directory.parent,check=True,capture_output=True,timeout=30)
    config = '[core]\n repositoryformatversion = '+('0' if bits==40 else '1')+'\n bare = true\n hooksPath = /dev/null\n logAllRefUpdates = false\n'
    if bits == 64:
        config += '[extensions]\n objectFormat = sha256\n'
    (directory / 'config').write_text(config)
    for name,data in files.items():
        destination = directory / name;destination.parent.mkdir(parents=True,exist_ok=True)
        destination.write_bytes(data)
    refs = _logical_refs(binary,directory,objects,files)
    for row in registry:
        if row['branch'] is not None:
            _git(binary,directory,objects,'check-ref-format',row['branch'])
    _attached_branches(registry,refs)
    return files,objects,registry,refs


def observe(gate, ident, *, approved_gate_sha256, repo_alias, scratch_root, trusted_git=TRUSTED_GIT):
    """Create a review snapshot while the actual gate owns the frozen lock."""
    scratch,binary=_authority(gate,scratch_root,trusted_git)
    with gate.frozen_view(ident,approved_sha256=approved_gate_sha256) as view, tempfile.TemporaryDirectory(prefix='ref-observe-',dir=scratch) as temp:
        common=_resolve(view,repo_alias)
        files,objects,registry,refs=_shadow(common,Path(temp)/'view.git',binary)
        return {'version':1,'gate_id':ident,'gate_sha256':approved_gate_sha256,'repo_alias':repo_alias,
                'ref_snapshot_sha256':digest(_file_manifest(files)),'registry_sha256':digest(registry),
                'registry':registry,'refs':refs,'branch_ownership_generation_proven':False,
                'execution_authorized':False}


def prepare(gate, selection, *, approved_selection_sha256, scratch_root, trusted_git=TRUSTED_GIT):
    """Prepare an approved exact frozen selection; do not alter held storage.

    selection fields: version, gate_id, gate_sha256, repo_alias,
    ref_snapshot_sha256, registry_sha256, approval_kind='exact-frozen-selection',
    branches=[{ref,tip,integration_ref,integration_tip}]. Historical eligible=True
    is insufficient. The caller must obtain approval for this exact snapshot.
    """
    required={'version','gate_id','gate_sha256','repo_alias','ref_snapshot_sha256','registry_sha256','approval_kind','branches'}
    if not isinstance(selection,dict) or set(selection)!=required or selection['version']!=1:
        raise ShadowError('complete bounded branch selection required')
    if not isinstance(selection['branches'],list) or not 1 <= len(selection['branches']) <= MAX_SELECTED_BRANCHES:
        raise ShadowError('bounded nonempty branch selection required')
    for key in required-{'version','branches'}:
        if not isinstance(selection[key],str) or not 1 <= len(selection[key]) <= 128:
            raise ShadowError('bounded scalar selection fields required')
    for branch in selection['branches']:
        if not isinstance(branch,dict) or set(branch)!={'ref','tip','integration_ref','integration_tip'} or any(not isinstance(value,str) or not 1 <= len(value) <= 1024 for value in branch.values()):
            raise ShadowError('bounded exact branch identities required')
    if len(json.dumps(selection,sort_keys=True).encode()) > MAX_SELECTION_BYTES:
        raise ShadowError('branch selection exceeds byte limit')
    if digest(selection)!=approved_selection_sha256 or selection['approval_kind']!='exact-frozen-selection':
        raise ShadowError('exact frozen branch selection approval required')
    scratch,binary=_authority(gate,scratch_root,trusted_git)
    result_path=Path(tempfile.mkdtemp(prefix='branch-delta-',dir=scratch))
    try:
        with gate.frozen_view(selection['gate_id'],approved_sha256=selection['gate_sha256']) as view:
            common=_resolve(view,selection['repo_alias']);shadow=result_path/'view.git'
            before,objects,registry,refs=_shadow(common,shadow,binary)
            if digest(_file_manifest(before))!=selection['ref_snapshot_sha256'] or digest(registry)!=selection['registry_sha256']:
                raise ShadowError('frozen refs or attachment inventory changed since approval')
            transaction=['start'];expected=dict(refs);seen=set();retired=[];verified_integrations={}
            for branch in selection['branches']:
                if not isinstance(branch,dict) or set(branch)!={'ref','tip','integration_ref','integration_tip'}:
                    raise ShadowError('exact branch and integration identity required')
                ref,tip,integration,integrated=(branch[key] for key in ('ref','tip','integration_ref','integration_tip'))
                if not isinstance(ref,str) or not ref.startswith('refs/heads/') or ref in seen or integration not in ('refs/heads/main','refs/heads/master') or ref==integration:
                    raise ShadowError('invalid, repeated or integration branch selection')
                seen.add(ref)
                _git(binary,shadow,objects,'check-ref-format',ref)
                if ref in _attached_branches(registry,refs):
                    raise ShadowError('selected branch remains checked out')
                if refs.get(ref)!={'oid':tip,'symbolic':None} or refs.get(integration)!={'oid':integrated,'symbolic':None}:
                    raise ShadowError('selected direct ref tip or integration changed')
                _git(binary,shadow,objects,'merge-base','--is-ancestor',tip,integrated)
                backup='refs/richos/retired/'+selection['gate_id']+'/'+ref
                _git(binary,shadow,objects,'check-ref-format',backup)
                if backup in refs:
                    raise ShadowError('retirement backup already exists')
                if integration not in verified_integrations:
                    transaction.append('verify '+integration+' '+integrated)
                    verified_integrations[integration]=integrated
                elif verified_integrations[integration]!=integrated:
                    raise ShadowError('conflicting integration snapshots')
                transaction += ['create '+backup+' '+tip,'delete '+ref+' '+tip]
                expected.pop(ref);expected[backup]={'oid':tip,'symbolic':None}
                retired.append(dict(branch,backup_ref=backup))
            transaction += ['prepare','commit']
            _git(binary,shadow,objects,'update-ref','--no-deref','--stdin',input=('\n'.join(transaction)+'\n').encode())
            after=_metadata(shadow)
            if _logical_refs(binary,shadow,objects,after)!=expected:
                raise ShadowError('Git changed refs outside the approved branch delta')
            if _metadata(common)!=before or _registry(common)!=registry:
                raise ShadowError('held refs changed during shadow preparation')
            changes=[]
            for name in sorted(set(before)|set(after)):
                if before.get(name)==after.get(name):
                    continue
                allowed=name=='packed-refs' or any(name in (row['ref'],'logs/'+row['ref'],row['backup_ref'],'logs/'+row['backup_ref']) for row in retired)
                if not allowed:
                    raise ShadowError('Git changed unrelated ref storage')
                entry={'path':name,'before':_file_manifest({name:before[name]}).get(name) if name in before else None,
                       'after':_file_manifest({name:after[name]}).get(name) if name in after else None}
                for side,files in (('before',before),('after',after)):
                    if name in files:
                        output=result_path/side/name;output.parent.mkdir(parents=True,exist_ok=True);output.write_bytes(files[name])
                changes.append(entry)
            artifact={'version':1,'mode':'prepared-ref-delta-only','gate_id':selection['gate_id'],
                      'gate_sha256':selection['gate_sha256'],'repo_alias':selection['repo_alias'],
                      'approved_selection_sha256':approved_selection_sha256,'selection':selection,
                      'source_ref_snapshot_sha256':selection['ref_snapshot_sha256'],
                      'expected_ref_snapshot_sha256':digest(_file_manifest(after)),
                      'registry_sha256':selection['registry_sha256'],'retired_branches':retired,'changes':changes,
                      'execution_authorized':False,'held_storage_modified':False,'publication_implemented':False}
            shutil.rmtree(shadow)  # Only our metadata shadow; objects were never copied here.
            (result_path/'delta.json').write_text(json.dumps(artifact,sort_keys=True,indent=2)+'\n')
            return dict(artifact,artifact_path=str(result_path))
    except BaseException:
        shutil.rmtree(result_path)
        raise
