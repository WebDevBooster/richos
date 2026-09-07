#!/usr/bin/env python3
"""Expire proven-clean legacy bulk archives while retaining complete metadata.

Only new frozen proofs qualify. Dirty, unknown and historical archives retain
all bytes. Canonical Git is inspected as its owner after gate restoration.
"""
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import time


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

capture=load('legacy-workspace-capture');shadow=capture.shadow
recovery=load('terminal-recovery-shadow');metadata=load('workspace-recovery-metadata')
mutation=load('legacy-workspace-mutation')


class ExpiryError(RuntimeError): pass


def _pin(path):
    info=path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_uid!=os.geteuid() or info.st_mode&0o022:
        raise ExpiryError('protected independent recovery file required')
    return [capture.filesystem.filesystem_token(path,info),info.st_ino]


def _hash(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:return capture._hash(stream)


def _directory(path,gate):
    raw=Path(path)
    if not raw.is_absolute() or str(raw)!=path or raw.resolve(strict=True)!=raw:
        raise ExpiryError('canonical protected recovery directory required')
    return shadow._private_directory(raw,gate)


def _file(directory,name,gate):
    path=directory/name;_pin(path)
    if gate.require_root:gate._no_acl(path)
    return path


def _clean(view,receipt,manifest,sources,scratch,binary):
    if any(receipt['dependencies'][key] for key in ('missing_objects','external_gitlinks','unparsed_git_state')):
        raise ExpiryError('unresolved Git state retains bulk recovery')
    repo=next(row for row in view['plan']['repositories'] if row['alias']==receipt['repo_alias'])
    candidate=next(row for row in repo['removal_candidates'] if row['path']==receipt['candidate_path'])
    head=candidate['head']
    common,_=capture._map(view,receipt['common_git_identity']['path'])
    admin,_=capture._map(view,receipt['git_admin_path'])
    with tempfile.TemporaryDirectory(prefix='clean-proof-',dir=scratch) as temporary:
        directory=Path(temporary)/'view.git';_,objects,_,_=shadow._shadow(common,directory,binary)
        if not (admin/'index').is_file():raise ExpiryError('missing index retains bulk recovery')
        for source in [admin/'index',*sorted(admin.glob('sharedindex.*'))]:
            (directory/source.name).write_bytes(shadow._bytes(source,metadata.MAX_BYTES))
        flags=shadow._git(binary,directory,objects,'ls-files','-v','-z').split(b'\0')
        if any(row and (row[:1].islower() or row[:1]==b'S') for row in flags):
            raise ExpiryError('hidden index flags retain bulk recovery')
        expected={}
        for row in shadow._git(binary,directory,objects,'ls-tree','-r','-z',head).split(b'\0'):
            if not row:continue
            header,name=row.split(b'\t',1);mode,kind,oid=header.split(b' ')
            relative=os.fsdecode(name)
            if (kind!=b'blob' or relative.startswith('/') or any(p in ('.git','..') for p in Path(relative).parts)
                    or mode not in (b'100644',b'100755',b'120000') or relative in expected):
                raise ExpiryError('unsupported tracked tree retains bulk recovery')
            expected[relative]=(mode,oid)
        observed={}
        for row in shadow._git(binary,directory,objects,'ls-files','--stage','-z').split(b'\0'):
            if not row:continue
            header,name=row.split(b'\t',1);mode,oid,stage=header.split(b' ')
            relative=os.fsdecode(name)
            if stage!=b'0' or relative in observed:raise ExpiryError('unmerged index retains bulk recovery')
            observed[relative]=(mode,oid)
        if observed!=expected:raise ExpiryError('staged changes retain bulk recovery')
        working={name[len('worktree/'):]:row for name,row in manifest.items()
                 if name.startswith('worktree/') and row['kind']!='directory' and name!='worktree/.git'}
        if set(working)!=set(expected):raise ExpiryError('extra or missing working bytes retain bulk recovery')
        if manifest.get('worktree/.git',{}).get('kind')!='file':raise ExpiryError('Git pointer is not archived metadata')
        for relative,(mode,oid) in expected.items():
            row=working[relative]
            if mode==b'120000':
                if row['kind']!='symlink':raise ExpiryError('tracked symlink kind changed')
                data=os.fsencode(row['target']);length=len(data)
            else:
                if row['kind']!='file' or bool(row['mode']&0o111)!=(mode==b'100755'):
                    raise ExpiryError('working kind or executable bit changed')
                data=None;length=row['size']
            digest=hashlib.sha1() if len(oid)==40 else hashlib.sha256()
            digest.update(b'blob '+str(length).encode()+b'\0')
            if data is not None:digest.update(data)
            else:
                fd=os.open(sources['worktree/'+relative],os.O_RDONLY|os.O_NOFOLLOW)
                with os.fdopen(fd,'rb') as stream:
                    for block in iter(lambda:stream.read(1024*1024),b''):digest.update(block)
            if digest.hexdigest().encode()!=oid:raise ExpiryError('working changes retain bulk recovery')
    return repo


def prepare(gate,ident,*,approved_gate_sha256,repo_alias,capture_path,capture_receipt_sha256,
            scratch_root,trusted_git=shadow.TRUSTED_GIT):
    result=dict(version=1,state='retained',capture_path=capture_path,capture_receipt_sha256=capture_receipt_sha256)
    scratch,binary=shadow._authority(gate,scratch_root,trusted_git)
    directory=recovery._capture_authority(capture_path,gate)
    with gate.frozen_view(ident,approved_sha256=approved_gate_sha256) as view:
        receipt=capture.validate_capture(view,directory,scratch,binary)
        if shadow.digest(receipt)!=capture_receipt_sha256 or receipt['repo_alias']!=repo_alias:
            raise ExpiryError('exact capture proof selection changed')
        roots=[('worktree',receipt['candidate_path']),('git-admin',receipt['git_admin_path'])]
        manifest,sources=capture._inventory(view,roots)
        try:
            repo=_clean(view,receipt,manifest,sources,scratch,binary)
            compact=metadata.encode(metadata.from_capture(manifest,sources))
        except (ExpiryError,metadata.MetadataError,shadow.ShadowError,OSError) as error:
            return dict(result,reason=str(error))
        proof_path=directory/'clean-expiry.json';compact_path=directory/'compact-metadata.json'
        if os.path.lexists(compact_path):
            _file(directory,compact_path.name,gate)
            if _hash(compact_path)!=hashlib.sha256(compact).hexdigest():raise ExpiryError('existing compact metadata changed')
        else:mutation._atomic(compact_path,compact)
        proof=dict(version=1,gate_id=ident,gate_sha256=approved_gate_sha256,repo_alias=repo_alias,
            capture_receipt_sha256=capture_receipt_sha256,archive_sha256=receipt['archive_sha256'],
            archive_identity=_pin(directory/'recovery.tar.gz'),metadata_sha256=hashlib.sha256(compact).hexdigest(),
            metadata_identity=_pin(compact_path),canonical_repository=repo['canonical_repository'],
            common_git_identity=receipt['common_git_identity'],inspection_context=view.get('inspection_context'),
            required_objects=receipt['dependencies']['required_objects'])
        # The gate record is the durable approved owner context; frozen_view's
        # compact projection intentionally need not expose it.
        proof['inspection_context']=gate._load(gate.vault/ident).get('inspection_context')
        if os.path.lexists(proof_path):
            existing=json.loads(_file(directory,proof_path.name,gate).read_text())
            if {k:v for k,v in existing.items() if k!='prepared_at'}!=proof:raise ExpiryError('existing clean proof changed')
            proof=existing
        else:
            proof['prepared_at']=time.time();mutation._save(proof_path,proof)
        return dict(result,state='clean-prepared',proof_sha256=shadow.digest(proof))


def _user_git(binary,context,repo,*args,input=None,discard=False):
    uid=context['owner_uid'];gid=context['owner_gid']
    if type(uid)is not int or uid<=0 or type(gid)is not int or gid<0:raise ExpiryError('non-root Git owner required')
    if os.geteuid()!=0 and (uid,gid)!=(os.geteuid(),os.getegid()):raise ExpiryError('Git owner differs from process owner')
    credentials=dict(user=uid,group=gid,extra_groups=[]) if os.geteuid()==0 else {}
    result=subprocess.run([binary,'--no-replace-objects','-C',str(repo),'-c','core.hooksPath=/dev/null',
        '-c','core.fsmonitor=false','-c','protocol.allow=never',*args],
        env={'PATH':'/usr/bin:/bin','HOME':'/var/empty','LC_ALL':'C','GIT_CONFIG_NOSYSTEM':'1',
             'GIT_CONFIG_SYSTEM':'/dev/null','GIT_CONFIG_GLOBAL':'/dev/null','GIT_NO_REPLACE_OBJECTS':'1',
             'GIT_TERMINAL_PROMPT':'0'},input=input,stdout=subprocess.DEVNULL if discard else subprocess.PIPE,
        stderr=subprocess.PIPE,timeout=120,**credentials)
    if result.returncode:raise ExpiryError('owner Git verification failed: '+result.stderr.decode(errors='replace')[-1000:])
    return result.stdout


def _directory_pin(expected):
    path=Path(expected['path'])
    if path.resolve(strict=True)!=path:raise ExpiryError('canonical source path changed')
    info=path.lstat()
    if not stat.S_ISDIR(info.st_mode) or (capture.filesystem.filesystem_token(path,info),info.st_ino)!=(expected['device'],expected['inode']):
        raise ExpiryError('canonical source identity changed')
    return path


def expire(gate,ident,*,approved_gate_sha256,repo_alias,capture_path,capture_receipt_sha256,
           proof_sha256,retention_days,now=None,trusted_git=shadow.TRUSTED_GIT):
    if type(retention_days) not in (int,float) or not math.isfinite(retention_days) or not 1<=retention_days<=3650:
        raise ExpiryError('explicit bounded retention policy required')
    now=time.time() if now is None else now
    if type(now) not in (int,float) or not math.isfinite(now):raise ExpiryError('finite current time required')
    with gate._lock(ident) as base:
        record=gate._load(base)
        if record['phase']!='restored' or record['approved_sha256']!=approved_gate_sha256:
            raise ExpiryError('completed approved restoration required before archive expiry')
        directory=_directory(capture_path,gate)
        # Reuse runtime authority validation without creating scratch paths.
        _,binary=shadow._authority(gate,directory,trusted_git)
        proof=json.loads(_file(directory,'clean-expiry.json',gate).read_text())
        if (shadow.digest(proof)!=proof_sha256 or proof.get('version')!=1 or proof['gate_id']!=ident
                or proof['gate_sha256']!=approved_gate_sha256 or proof['repo_alias']!=repo_alias
                or proof['capture_receipt_sha256']!=capture_receipt_sha256
                or proof['inspection_context']!=record.get('inspection_context')):
            raise ExpiryError('clean proof no longer matches approved capture and owner')
        if now<proof['prepared_at']+retention_days*86400:return dict(state='waiting-retention',capture_path=capture_path)
        compact=_file(directory,'compact-metadata.json',gate)
        if _pin(compact)!=proof['metadata_identity'] or _hash(compact)!=proof['metadata_sha256']:
            raise ExpiryError('compact recovery metadata changed')
        receipt=json.loads(_file(directory,'receipt.json',gate).read_text())
        if shadow.digest(receipt)!=capture_receipt_sha256:raise ExpiryError('capture receipt changed')
        manifest=json.loads(_file(directory,'manifest.json',gate).read_text())
        if shadow.digest(manifest)!=receipt['manifest_sha256']:raise ExpiryError('capture manifest changed')
        repo=_directory_pin(proof['canonical_repository']);common=_directory_pin(proof['common_git_identity'])
        context=proof['inspection_context']
        if context is None and not gate.require_root:context=dict(owner_uid=os.geteuid(),owner_gid=os.getegid())
        if context is None:raise ExpiryError('approved owner context missing')
        actual=_user_git(binary,context,repo,'rev-parse','--path-format=absolute','--git-common-dir').decode().strip()
        if Path(actual).resolve(strict=True)!=common:raise ExpiryError('canonical Git store changed')
        for row in proof['required_objects']:
            ref='refs/richos/recovery/'+ident+'/'+capture_receipt_sha256+'/'+row['oid']
            kind=_user_git(binary,context,repo,'for-each-ref','--format=%(refname)%00%(symref)',ref)
            if kind!=(ref+'\0\n').encode():raise ExpiryError('recovery reference is not an exact direct ref')
            actual=_user_git(binary,context,repo,'rev-parse','--verify',ref).decode().strip()
            if actual!=row['oid']:raise ExpiryError('recovery reference changed')
        _user_git(binary,context,repo,'rev-list','--objects','--no-object-names','--missing=error','--stdin',
                  input=('\n'.join(row['oid'] for row in proof['required_objects'])+'\n').encode(),discard=True)
        journal_path=directory/'expiry-state.json'
        journal=json.loads(_file(directory,journal_path.name,gate).read_text()) if os.path.lexists(journal_path) else None
        if journal and (journal.get('proof_sha256')!=proof_sha256 or journal.get('state') not in ('expiring','expired')):
            raise ExpiryError('archive expiry journal changed')
        archive=directory/'recovery.tar.gz'
        if os.path.lexists(archive):
            _file(directory,archive.name,gate)
            if _pin(archive)!=proof['archive_identity'] or _hash(archive)!=proof['archive_sha256']:
                raise ExpiryError('bulk recovery archive changed')
            capture._verify_archive(archive,manifest)
            mutation._save(journal_path,dict(version=1,state='expiring',proof_sha256=proof_sha256))
            archive.unlink();mutation._sync(directory)
        elif not journal:raise ExpiryError('bulk archive disappeared without expiry intent')
        result=dict(version=1,state='expired',proof_sha256=proof_sha256,capture_path=capture_path,
                    bulk_archive_reclaimed=True,metadata_retained=True)
        mutation._save(journal_path,result)
        return result
