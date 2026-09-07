#!/usr/bin/env python3
"""Prepare a verified linked-worktree recovery archive under a frozen gate.

No extraction, Git publication, registration removal, expiry or deletion API.
"""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tarfile
import tempfile

spec = importlib.util.spec_from_file_location('capture_shadow', Path(__file__).with_name('terminal-branch-shadow.py'))
shadow = importlib.util.module_from_spec(spec);spec.loader.exec_module(shadow)
spec = importlib.util.spec_from_file_location('capture_attributes', Path(__file__).with_name('managed-workspace-failed-creation.py'))
attributes = importlib.util.module_from_spec(spec);spec.loader.exec_module(attributes)
OID = re.compile(r'(?:[0-9a-f]{40}|[0-9a-f]{64})\Z')
CACHE_SIGNATURE = b'Signature: 8a477f597d28d172789f06886806bc55'


class CaptureError(RuntimeError):
    pass


def _sync(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:os.fsync(fd)
    finally:os.close(fd)


def _json(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, sort_keys=True);stream.write('\n');stream.flush();os.fsync(stream.fileno())


def _hash(stream):
    result = hashlib.sha256()
    for data in iter(lambda:stream.read(1024*1024), b''):result.update(data)
    return result.hexdigest()


def _attrs(path):
    return attributes._xattrs(path)


def _map(view, source):
    source = Path(source)
    matches = [root for root in view['roots'] if source == Path(root['source']) or Path(root['source']) in source.parents]
    if len(matches) != 1:raise CaptureError('candidate is not covered by exactly one frozen root')
    root = matches[0];relative = source.relative_to(root['source'])
    return Path(root['held_path'])/relative, (Path(root['held'])/relative).as_posix()


def _snapshot(path, key, name, metadata):
    before = path.lstat();original = metadata.get(key)
    if original is None or (before.st_dev,before.st_ino) != (original['device'],original['inode']):
        raise CaptureError('source is outside the exact frozen inode inventory')
    kind = original['kind']
    result = dict(name=name,kind=kind,uid=original['uid'],gid=original['gid'],mode=original['mode'],
                  mtime_ns=before.st_mtime_ns,xattrs=_attrs(path))
    if kind == 'file':
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:raise CaptureError('non-independent regular file')
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
        with os.fdopen(fd,'rb') as stream:
            opened=os.fstat(stream.fileno())
            if (opened.st_dev,opened.st_ino)!=(before.st_dev,before.st_ino):raise CaptureError('source file changed')
            result.update(size=before.st_size,sha256=_hash(stream))
    elif kind == 'symlink':result['target']=os.readlink(path)
    elif kind != 'directory':raise CaptureError('unsupported recovery object')
    after=path.lstat()
    stamp=lambda info:(info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns)
    if stamp(before)!=stamp(after) or result['xattrs']!=_attrs(path):raise CaptureError('source changed during snapshot')
    return result


def _inventory(view, roots):
    result={};sources={}
    def visit(path,key,name):
        if name in result:raise CaptureError('overlapping archive namespaces')
        row=_snapshot(path,key,name,view['metadata']);result[name]=row;sources[name]=path
        if row['kind']=='directory':
            for child in sorted(path.iterdir()):visit(child,key+'/'+child.name,name+'/'+child.name)
    for namespace,source in roots:
        held,key=_map(view,source);visit(held,key,namespace)
    return result,sources


def _index_objects(data, oid_bytes):
    """Read raw archived entries and TREE caches, including split-index bases.

    Layout: https://git-scm.com/docs/index-format. Git separately validates the
    resolved index/REUC semantics. Unknown extensions remain a handoff veto.
    """
    if oid_bytes not in (20,32) or len(data)<12+oid_bytes or data[:4]!=b'DIRC':raise CaptureError('invalid archived index header')
    digest=hashlib.sha1 if oid_bytes==20 else hashlib.sha256
    if digest(data[:-oid_bytes]).digest()!=data[-oid_bytes:]:raise CaptureError('archived index checksum mismatch')
    version=int.from_bytes(data[4:8],'big');count=int.from_bytes(data[8:12],'big')
    if version not in (2,3,4):raise CaptureError('unsupported archived index version')
    limit=len(data)-oid_bytes;offset=12;objects=[];gitlinks=[];unknown=[]
    def terminated(start,needle):
        end=data.find(needle,start,limit)
        if end<0:raise CaptureError('truncated archived index field')
        return end
    for _ in range(count):
        start=offset
        if offset+42+oid_bytes>limit:raise CaptureError('truncated archived index entry')
        mode=int.from_bytes(data[offset+24:offset+28],'big')
        oid=data[offset+40:offset+40+oid_bytes].hex()
        (gitlinks if mode==0o160000 else objects).append(oid)
        flags=int.from_bytes(data[offset+40+oid_bytes:offset+42+oid_bytes],'big');offset+=42+oid_bytes
        if flags&0x4000:
            if version==2 or offset+2>limit:raise CaptureError('invalid extended index flags')
            offset+=2
        if version==4:
            for _ in range(10):
                if offset>=limit:raise CaptureError('truncated compressed index path')
                byte=data[offset];offset+=1
                if not byte&0x80:break
            else:raise CaptureError('invalid compressed index path')
        end=terminated(offset,b'\0');offset=end+1
        if version!=4:
            offset=start+((offset-start+7)//8)*8
            if offset>limit or any(data[end:offset]):raise CaptureError('invalid archived index padding')
    while offset<limit:
        if offset+8>limit:raise CaptureError('truncated index extension')
        signature=data[offset:offset+4];size=int.from_bytes(data[offset+4:offset+8],'big');offset+=8
        end=offset+size
        if end>limit:raise CaptureError('truncated index extension payload')
        if signature==b'TREE':
            position=offset
            while position<end:
                nul=data.find(b'\0',position,end);newline=data.find(b'\n',nul+1,end) if nul>=0 else -1
                if newline<0:raise CaptureError('invalid index tree-cache entry')
                numbers=data[nul+1:newline].split(b' ')
                if len(numbers)!=2 or not re.fullmatch(rb'-?[0-9]+',numbers[0]) or not numbers[1].isdigit():raise CaptureError('invalid index tree-cache counts')
                position=newline+1
                if int(numbers[0])>=0:
                    if position+oid_bytes>end:raise CaptureError('truncated index tree-cache object')
                    objects.append(data[position:position+oid_bytes].hex());position+=oid_bytes
        elif signature==b'REUC':
            position=offset
            while position<end:
                nul=data.find(b'\0',position,end)
                if nul<0:raise CaptureError('invalid resolve-undo path')
                position=nul+1;modes=[]
                for _ in range(3):
                    nul=data.find(b'\0',position,end)
                    if nul<0 or not re.fullmatch(rb'[0-7]+',data[position:nul]):raise CaptureError('invalid resolve-undo mode')
                    modes.append(int(data[position:nul],8));position=nul+1
                for mode in modes:
                    if mode:
                        if position+oid_bytes>end:raise CaptureError('truncated resolve-undo object')
                        (gitlinks if mode==0o160000 else objects).append(data[position:position+oid_bytes].hex());position+=oid_bytes
        elif signature not in (b'link',b'UNTR',b'FSMN',b'EOIE',b'IEOT',b'sdir'):
            unknown.append(signature.hex())
        offset=end
    return objects,gitlinks,unknown


def _dependencies(common, admin, directory, binary, candidate):
    """Read Git only through controlled config, never the held Git directory."""
    # Working-tree symlinks are preserved as data. Git admin symlinks could
    # redirect a privileged index/ref read outside the frozen gate, so refuse
    # them before invoking Git or copying any admin payload into its shadow.
    def scan_error(error):raise error
    for current,dirs,files in os.walk(admin,followlinks=False,onerror=scan_error):
        for name in dirs+files:
            info=(Path(current)/name).lstat()
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise CaptureError('external or unsupported Git admin dependency')
    shadow_dir=directory/'dependency-shadow.git'
    _,objects,_,refs=shadow._shadow(common,shadow_dir,binary)
    endpoints={};gitlinks={};unparsed=[]
    def add(oid,reason):
        if not OID.fullmatch(oid):raise CaptureError('malformed Git object endpoint')
        if set(oid)=={'0'}:return
        endpoints.setdefault(oid,set()).add(reason)
    def ref_value(value,reason,seen=()):
        text=value.decode('utf-8').rstrip('\n')
        if OID.fullmatch(text):add(text,reason);return
        if not text.startswith('ref: refs/') or '\n' in text:raise CaptureError('unreadable per-worktree ref')
        ref=text[5:]
        shadow._git(binary,shadow_dir,objects,'check-ref-format',ref)
        if ref in seen:raise CaptureError('cyclic per-worktree symbolic ref')
        local=admin/ref
        if local.is_file():ref_value(shadow._bytes(local,65536),reason,(*seen,ref))
        elif ref in refs:add(refs[ref]['oid'],reason)
        else:raise CaptureError('unresolved per-worktree ref')
    add(candidate['head'],'approved-terminal-head')
    ref_value(shadow._bytes(admin/'HEAD',65536),'git-admin/HEAD')
    for current,dirs,files in os.walk(admin,followlinks=False):
        for filename in files:
            path=Path(current)/filename;relative=path.relative_to(admin).as_posix()
            if relative.startswith('refs/'):
                shadow._git(binary,shadow_dir,objects,'check-ref-format',relative)
                ref_value(shadow._bytes(path,shadow.MAX_METADATA_BYTES),'git-admin/'+relative)
            elif relative.startswith('logs/'):
                for line in shadow._bytes(path,shadow.MAX_METADATA_BYTES).splitlines():
                    fields=line.split(b' ',2)
                    if len(fields)!=3:raise CaptureError('malformed per-worktree reflog')
                    add(fields[0].decode('ascii'),'git-admin/'+relative+':old')
                    add(fields[1].decode('ascii'),'git-admin/'+relative+':new')
            elif filename.endswith('.lock'):unparsed.append('git-admin/'+relative)
    index=admin/'index';raw_indexes=[]
    if index.exists():
        (shadow_dir/'index').write_bytes(shadow._bytes(index,128*1024*1024));raw_indexes.append(shadow_dir/'index')
    for shared in sorted(admin.glob('sharedindex.*')):
        if not OID.fullmatch(shared.name[len('sharedindex.'):]):raise CaptureError('malformed shared index name')
        destination=shadow_dir/shared.name;destination.write_bytes(shadow._bytes(shared,128*1024*1024));raw_indexes.append(destination)
    for raw in raw_indexes:
        raw_objects,raw_gitlinks,extensions=_index_objects(raw.read_bytes(),len(candidate['head'])//2)
        for oid in raw_objects:add(oid,'git-admin/'+raw.name+':raw-entry-or-tree-cache')
        for oid in raw_gitlinks:gitlinks.setdefault(oid,[]).append('raw-index:'+raw.name)
        unparsed.extend('git-admin/'+raw.name+':extension-'+name for name in extensions)
    if index.exists():
        for option,reason in (('--stage','index'),('--resolve-undo','resolve-undo')):
            output=shadow._git(binary,shadow_dir,objects,'ls-files',option,'--sparse','-z')
            for line in output.split(b'\0'):
                if not line:continue
                prefix,separator,path=line.partition(b'\t');fields=prefix.split(b' ')
                if not separator or len(fields)!=3 or fields[2] not in (b'0',b'1',b'2',b'3'):raise CaptureError('unreadable staged index entry')
                mode,oid=fields[0],fields[1].decode('ascii')
                if not OID.fullmatch(oid):raise CaptureError('malformed staged index object')
                if mode==b'160000':gitlinks.setdefault(oid,[]).append(base64.b64encode(path).decode('ascii'))
                else:add(oid,'git-admin/'+reason+':stage'+fields[2].decode())
    for name in ('ORIG_HEAD','REBASE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','MERGE_HEAD','AUTO_MERGE'):
        path=admin/name
        if path.exists():
            for line in shadow._bytes(path,shadow.MAX_METADATA_BYTES).splitlines():add(line.decode('ascii'),'git-admin/'+name)
    # Fetch and bisect state can contain additional endpoints in formats this
    # bounded primitive does not interpret. Preserve bytes and expose the veto.
    for name in ('FETCH_HEAD','BISECT_HEAD','BISECT_EXPECTED_REV','rebase-apply','rebase-merge','sequencer'):
        if os.path.lexists(admin/name):unparsed.append('git-admin/'+name)
    values=sorted(endpoints)
    observed=shadow._git(binary,shadow_dir,objects,'cat-file','--batch-check=%(objectname) %(objecttype)',input=('\n'.join(values)+'\n').encode()).decode().splitlines()
    missing=[]
    if len(observed)!=len(values):raise CaptureError('incomplete object dependency reader')
    for oid,line in zip(values,observed):
        if line not in [oid+' '+kind for kind in ('blob','tree','commit','tag')]:missing.append(oid)
    shutil.rmtree(shadow_dir)
    return dict(required_objects=[dict(oid=oid,sources=sorted(endpoints[oid])) for oid in values],
                missing_objects=missing,external_gitlinks=gitlinks,unparsed_git_state=sorted(set(unparsed)),
                durable_handoff_verified=False,registration_removal_authorized=False,
                shared_common_git_directory=str(common),
                requirement='Durably preserve the transitive object closure for every endpoint and resolve unparsed state before removing registration; gitlinks belong to external repositories.')


def _write_archive(path, manifest, sources):
    with tarfile.open(path,'w:gz',format=tarfile.PAX_FORMAT) as archive:
        for name,row in sorted(manifest.items()):
            item=tarfile.TarInfo(name);item.uid=row['uid'];item.gid=row['gid'];item.mode=row['mode']
            item.mtime=row['mtime_ns']/1000000000
            item.pax_headers={'RICHOS.xattrs':json.dumps(row['xattrs'],sort_keys=True),'RICHOS.mtime_ns':str(row['mtime_ns'])}
            if row['kind']=='directory':item.type=tarfile.DIRTYPE;archive.addfile(item)
            elif row['kind']=='symlink':item.type=tarfile.SYMTYPE;item.linkname=row['target'];archive.addfile(item)
            else:
                item.size=row['size'];fd=os.open(sources[name],os.O_RDONLY|os.O_NOFOLLOW)
                with os.fdopen(fd,'rb') as stream:archive.addfile(item,stream)
    with path.open('rb') as stream:os.fsync(stream.fileno())


def _verify_archive(path, manifest):
    seen=set()
    with tarfile.open(path,'r:gz') as archive:
        for item in archive:
            name=item.name
            if name in seen or name not in manifest:raise CaptureError('archive has unexpected or duplicate paths')
            seen.add(name);row=manifest[name]
            kind='file' if item.isfile() else 'directory' if item.isdir() else 'symlink' if item.issym() else None
            if (kind,item.uid,item.gid,item.mode)!=(row['kind'],row['uid'],row['gid'],row['mode']):raise CaptureError('archive metadata differs from frozen source')
            if json.loads(item.pax_headers.get('RICHOS.xattrs','null'))!=row['xattrs'] or item.pax_headers.get('RICHOS.mtime_ns')!=str(row['mtime_ns']):raise CaptureError('archive extended metadata differs')
            if kind=='file':
                with archive.extractfile(item) as stream:actual=_hash(stream)
                if item.size!=row['size'] or actual!=row['sha256']:raise CaptureError('archive file bytes differ from frozen source')
            elif kind=='symlink' and item.linkname!=row['target']:raise CaptureError('archive symlink differs')
    if seen!=set(manifest):raise CaptureError('archive omitted frozen source entries')


def validate_capture(view, artifact_path, scratch_directory, binary):
    """Revalidate under the caller's frozen lock and protected artifact authority.

    The privileged caller must validate private ancestor ownership/ACLs on the
    artifact and scratch directories before calling. This function never grants
    registration removal authority and never acquires another gate lock.
    """
    directory=Path(artifact_path)
    receipt=json.loads(shadow._bytes(directory/'receipt.json',16*1024*1024))
    manifest=json.loads(shadow._bytes(directory/'manifest.json',128*1024*1024))
    if receipt.get('version')!=1 or receipt.get('gate_id')!=view['id'] or receipt.get('gate_sha256')!=view['approved_sha256']:
        raise CaptureError('capture belongs to another approved gate')
    if receipt.get('archive')!='recovery.tar.gz' or receipt.get('manifest_sha256')!=shadow.digest(manifest):
        raise CaptureError('capture manifest identity changed')
    rows=[row for row in view['plan']['repositories'] if row['alias']==receipt['repo_alias']]
    if len(rows)!=1:raise CaptureError('capture repository alias changed')
    repo=rows[0];candidates=[row for row in repo['removal_candidates'] if row['path']==receipt['candidate_path']]
    if not candidates or any(row.get('contained_registered_targets') for row in candidates):
        raise CaptureError('capture target is not an independent terminal candidate')
    workspace=next(row for row in repo['gate_paths'] if row['path']==receipt['candidate_path'])
    if (receipt['candidate_identity']!=workspace['identity'] or receipt['git_admin_path']!=workspace['git_directory']['path']
            or receipt['common_git_identity']!=repo['common_git_directory']):raise CaptureError('capture source identity changed')
    if (workspace['kind']!='registered-linked-worktree'
            or Path(receipt['git_admin_path']).parent!=Path(repo['common_git_directory']['path'])/'worktrees'):
        raise CaptureError('distinct linked-worktree Git metadata required')
    roots=[('worktree',receipt['candidate_path']),('git-admin',receipt['git_admin_path'])]
    current,_=_inventory(view,roots)
    if current!=manifest:raise CaptureError('capture no longer matches frozen source')
    archive=directory/'recovery.tar.gz'
    info=archive.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1:raise CaptureError('independent recovery archive required')
    fd=os.open(archive,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:
        if _hash(stream)!=receipt['archive_sha256']:raise CaptureError('capture archive hash changed')
    _verify_archive(archive,manifest)
    common,_=_map(view,repo['common_git_directory']['path']);admin,_=_map(view,receipt['git_admin_path'])
    with tempfile.TemporaryDirectory(prefix='capture-validate-',dir=scratch_directory) as temp:
        dependencies=_dependencies(common,admin,Path(temp),binary,candidates[0])
    dependencies['shared_common_git_directory']=repo['common_git_directory']['path']
    if dependencies!=receipt['dependencies']:raise CaptureError('capture dependency set changed or omitted endpoints')
    again,_=_inventory(view,roots)
    if again!=manifest:raise CaptureError('frozen source changed during capture validation')
    if any(receipt.get(key) is not False for key in ('deletion_authorized','registration_removal_authorized','automatic_expiry_authorized','standalone_repository','shared_objects_included')):
        raise CaptureError('capture receipt claims unsupported authority')
    return receipt


def prepare(gate, ident, *, approved_gate_sha256, repo_alias, candidate_path, scratch_root, trusted_git=shadow.TRUSTED_GIT):
    """Return a verified, retained recovery artifact; never authorize erasure."""
    scratch,binary=shadow._authority(gate,scratch_root,trusted_git)
    directory=None
    try:
        with gate.frozen_view(ident,approved_sha256=approved_gate_sha256) as view:
            rows=[row for row in view['plan']['repositories'] if row['alias']==repo_alias]
            if len(rows)!=1:raise CaptureError('exact approved repository alias required')
            repo=rows[0];candidates=[row for row in repo['removal_candidates'] if row['path']==candidate_path]
            if not candidates:raise CaptureError('exact approved terminal removal candidate required')
            if any(row.get('contained_registered_targets') for row in candidates):raise CaptureError('selection contains another registered checkout')
            workspace=next(row for row in repo['gate_paths'] if row['path']==candidate_path)
            admin_source=workspace['git_directory']['path'];common_source=repo['common_git_directory']['path']
            if workspace['kind']!='registered-linked-worktree' or admin_source==common_source:
                raise CaptureError('distinct linked-worktree Git metadata required')
            admin=Path(admin_source);common=Path(common_source)
            if admin.parent!=common/'worktrees':raise CaptureError('linked admin directory is outside expected shared registration namespace')
            roots=[('worktree',candidate_path),('git-admin',admin_source)]
            manifest,sources=_inventory(view,roots)
            bytes_total=sum(row.get('size',0) for row in manifest.values())
            # Compression is a space-saving choice, never a correctness bound.
            # Require room even for incompressible bytes plus a safety margin.
            if shutil.disk_usage(scratch).free < bytes_total+max(64*1024*1024,len(manifest)*2048):
                raise CaptureError('insufficient free space for verified recovery archive')
            directory=Path(tempfile.mkdtemp(prefix='legacy-capture-',dir=scratch))
            held_common,_=_map(view,common);held_admin,_=_map(view,admin)
            dependencies=_dependencies(held_common,held_admin,directory,binary,candidates[0])
            dependencies['shared_common_git_directory']=common_source
            archive=directory/'recovery.tar.gz';_write_archive(archive,manifest,sources);_verify_archive(archive,manifest)
            current,_=_inventory(view,roots)
            if current!=manifest:raise CaptureError('frozen source changed during archive preparation')
            cache_hints=[]
            for name,path in sources.items():
                if Path(name).name=='CACHEDIR.TAG' and manifest[name]['kind']=='file':
                    with path.open('rb') as stream:
                        if stream.read(len(CACHE_SIGNATURE))==CACHE_SIGNATURE:cache_hints.append(name)
            with archive.open('rb') as stream:archive_hash=_hash(stream)
            receipt=dict(version=1,gate_id=ident,gate_sha256=approved_gate_sha256,repo_alias=repo_alias,
                candidate_path=candidate_path,candidate_identity=workspace['identity'],git_admin_path=admin_source,
                common_git_identity=repo['common_git_directory'],
                archive='recovery.tar.gz',archive_sha256=archive_hash,manifest_sha256=shadow.digest(manifest),
                file_bytes=bytes_total,entry_count=len(manifest),cache_tag_hints=cache_hints,
                omitted_cache_bytes=0,classification='unclassified-retained',automatic_expiry_authorized=False,
                standalone_repository=False,shared_objects_included=False,dependencies=dependencies,
                held_storage_modified=False,deletion_authorized=False,registration_removal_authorized=False)
            _json(directory/'manifest.json',manifest);_json(directory/'receipt.json',receipt);_sync(directory);_sync(scratch)
            return dict(receipt,artifact_path=str(directory))
    except BaseException:
        if directory is not None:shutil.rmtree(directory)
        raise
