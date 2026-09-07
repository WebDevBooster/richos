#!/usr/bin/env python3
"""Advance explicitly armed legacy maintenance across reboot, one durable step.

No gate creation or reboot API. Scope is immutable after arming. The job lock is
separate from the gate lock so primitive operations retain their own authority.
"""
import contextlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import uuid


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

fs_identity=load('durable-filesystem-identity')
capture=load('legacy-workspace-capture')
retirement=load('legacy-workspace-retirement')
mutation=retirement.mutation
shadow=mutation.shadow
recovery=retirement.recovery


class JobError(RuntimeError):
    pass


def _scope(selection, approved):
    fields={'version','gate_id','gate_sha256','approval_kind','candidates','branches','restore'}
    if not isinstance(selection,dict) or set(selection)!=fields or selection['version']!=1 or selection['restore'] is not True:
        raise JobError('complete immutable legacy job selection required')
    if selection['approval_kind']!='exact-legacy-job':raise JobError('explicit legacy job approval required')
    for key in ('gate_id','gate_sha256','approval_kind'):
        if not isinstance(selection[key],str) or not 0<len(selection[key])<=128:raise JobError('bounded job identity required')
    if (not isinstance(selection['candidates'],list) or not isinstance(selection['branches'],list)
            or len(selection['candidates'])>128 or len(selection['branches'])>128
            or not selection['candidates'] and not selection['branches']):raise JobError('bounded nonempty job scope required')
    seen=set()
    for row in selection['candidates']:
        if not isinstance(row,dict) or set(row)!={'repo_alias','path','identity','git_admin_path','head'}:raise JobError('exact candidate identity required')
        for key in ('repo_alias','path','git_admin_path','head'):
            if not isinstance(row[key],str) or not 0<len(row[key])<=4096:raise JobError('bounded candidate fields required')
        if not isinstance(row['identity'],dict) or len(row['identity'])>16:raise JobError('bounded candidate inode identity required')
        if any(not isinstance(v,(str,int,type(None))) or len(str(v))>4096 for v in row['identity'].values()):raise JobError('bounded candidate inode fields required')
        key=(row['repo_alias'],row['path'])
        if key in seen:raise JobError('duplicate candidate')
        seen.add(key)
    seen=set()
    for row in selection['branches']:
        if not isinstance(row,dict) or set(row)!={'repo_alias','ref','tip','integration_ref','integration_tip'}:raise JobError('exact branch identity required')
        if any(not isinstance(v,str) or not 0<len(v)<=1024 for v in row.values()):raise JobError('bounded branch fields required')
        if not row['ref'].startswith('refs/heads/') or row['integration_ref'] not in ('refs/heads/main','refs/heads/master') or row['ref']==row['integration_ref']:
            raise JobError('worker branch and explicit integration required')
        if not shadow.OID.fullmatch(row['tip']) or not shadow.OID.fullmatch(row['integration_tip']):raise JobError('exact branch object IDs required')
        key=(row['repo_alias'],row['ref'])
        if key in seen:raise JobError('duplicate branch')
        seen.add(key)
    if len(json.dumps(selection,sort_keys=True).encode())>256*1024:raise JobError('job selection exceeds byte limit')
    if shadow.digest(selection)!=approved:raise JobError('matching explicit job selection hash required')


def _candidate(plan, chosen):
    repos=[row for row in plan['repositories'] if row['alias']==chosen['repo_alias']]
    if len(repos)!=1:raise JobError('selected repository is not in approved gate')
    repo=repos[0]
    candidates=[row for row in repo['removal_candidates'] if row['path']==chosen['path'] and row['head']==chosen['head']]
    targets=[row for row in repo['gate_paths'] if row['path']==chosen['path']]
    if not candidates or len(targets)!=1 or any(row.get('contained_registered_targets') for row in candidates):raise JobError('exact independent terminal candidate required')
    target=targets[0]
    if (target['identity']!=chosen['identity'] or target['git_directory']['path']!=chosen['git_admin_path']
            or target['kind']!='registered-linked-worktree'):raise JobError('candidate identity differs from approved gate')
    return repo,target


def _read(base):
    record=json.loads(shadow._bytes(base/'job.json',1024*1024))
    _scope(record['selection'],record['approved_selection_sha256'])
    if record.get('version')!=1 or record.get('gate_id')!=base.name or record['selection']['gate_id']!=base.name:
        raise JobError('job identity changed')
    return record


def _save(base, record):
    mutation._save(base/'job.json',record)


@contextlib.contextmanager
def _lock(gate, ident):
    base=gate._base(ident)
    shadow._private_directory(base,gate)
    fd=os.open(base/'job.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX)
        yield base
    finally:os.close(fd)


def _summary(record, *, progressed=False):
    return dict(gate_id=record['gate_id'],owner_uid=(record.get('inspection_context') or {}).get('owner_uid'),
        state=record['state'],phase=record['phase'],candidate_index=record['candidate_index'],
        candidate_count=len(record['selection']['candidates']),branch_group_index=record['branch_group_index'],
        branch_group_count=len(record['branch_groups']),last_error=record.get('last_error'),
        progressed=progressed,approved_selection_sha256=record['approved_selection_sha256'])


def status(gate, ident):
    """Read an atomic job journal without waiting for job or gate locks."""
    record=_read(gate._base(ident))
    if gate.inspection_context is not None and record['inspection_context']!=gate.inspection_context:
        raise JobError('job belongs to a different owner context')
    return _summary(record)


def arm(gate, selection, *, approved_selection_sha256, scratch_root):
    _scope(selection,approved_selection_sha256)
    scratch=shadow._private_directory(scratch_root,gate)
    if scratch!=gate._base(selection['gate_id'])/'job-scratch':raise JobError('fixed per-gate job scratch required')
    with _lock(gate,selection['gate_id']) as base:
        if (base/'job.json').exists():
            existing=_read(base)
            if gate.inspection_context is not None and existing['inspection_context']!=gate.inspection_context:
                raise JobError('job belongs to a different owner context')
            if existing['selection']!=selection or existing['approved_selection_sha256']!=approved_selection_sha256:
                raise JobError('gate already has a different immutable job')
            if existing['scratch_root']!=str(scratch):raise JobError('armed scratch authority changed')
            return _summary(existing)
        with gate._lock(selection['gate_id']):
            gated=gate._load(base);gate._require_completed_mutation(base)
            if gated['phase']!='gated' or gated['approved_sha256']!=selection['gate_sha256']:
                raise JobError('fully gated exact approved plan required before arming')
            plan=json.loads((base/'plan.json').read_text())
            if shadow.digest(plan)!=selection['gate_sha256']:raise JobError('gate plan identity changed')
            gate._verify_held(base,gated,gate._entries(base))
            for chosen in selection['candidates']:_candidate(plan,chosen)
            aliases={row['alias'] for row in plan['repositories']}
            if any(row['repo_alias'] not in aliases for row in selection['branches']):raise JobError('branch repository is outside approved gate')
            # Stable nonce reserves the exclusive scratch name before any copy.
            groups=sorted({row['repo_alias'] for row in selection['branches']})
            record=dict(version=1,gate_id=selection['gate_id'],selection=selection,
                approved_selection_sha256=approved_selection_sha256,inspection_context=gated.get('inspection_context'),
                scratch_root=str(scratch),scratch_nonce=str(uuid.uuid4()),scratch={},
                state='waiting-for-boot',phase='capture' if selection['candidates'] else 'branches',
                candidate_index=0,branch_group_index=0,branch_groups=groups,captures=[],pending=None,last_error=None)
            _save(base,record)
            return _summary(record,progressed=True)


def _identity(path):
    info=path.lstat()
    return {'device':fs_identity.filesystem_token(path,info),'inode':info.st_ino}


def _scratch(gate, base, record):
    parent=shadow._private_directory(record['scratch_root'],gate)
    index=str(record['candidate_index'])
    path=parent/('legacy-job-'+record['gate_id']+'-'+record['scratch_nonce']+'-'+index)
    known=record['scratch'].get(index)
    if path.is_symlink():raise JobError('capture scratch may not be a symlink')
    if not os.path.lexists(path):
        if known is not None:raise JobError('recorded exclusive capture scratch disappeared')
        path.mkdir(mode=0o700);mutation._sync(parent)
    shadow._private_directory(path,gate)
    if known is None:
        # A crash after mkdir but before this receipt can leave only an empty
        # directory. No capture runs until its exact inode is durably recorded.
        if list(path.iterdir()):raise JobError('unidentified capture scratch contains foreign data')
        record['scratch'][index]=dict(path=str(path),identity=_identity(path),manifest_sha256=None)
        _save(base,record)
    elif known['path']!=str(path) or known['identity']!=_identity(path):
        raise JobError('exclusive capture scratch identity changed')
    return path,record['scratch'][index]


def _partial_copy(path, gate):
    if path.is_symlink():raise JobError('partial capture may not be a symlink')
    if not re.fullmatch(r'legacy-capture-[a-z0-9_]{8}',path.name):raise JobError('foreign capture scratch entry')
    shadow._private_directory(path,gate)
    device=path.parent.stat().st_dev
    if path.stat().st_dev!=device:raise JobError('partial capture crosses a filesystem boundary')
    if any(p.name not in ('receipt.json','manifest.json','recovery.tar.gz','dependency-shadow.git') for p in path.iterdir()):
        raise JobError('unknown partial capture contents')
    def failure(error):raise error
    for directory,dirs,files in os.walk(path,followlinks=False,onerror=failure):
        for name in dirs+files:
            item=Path(directory)/name;info=item.lstat()
            if (not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)) or info.st_dev!=device or info.st_uid!=os.geteuid()
                    or info.st_mode&0o022 or stat.S_ISREG(info.st_mode) and info.st_nlink!=1):
                raise JobError('partial copy has foreign or unsupported ownership')
            if gate.require_root:gate._no_acl(item)


def _capture_step(gate,base,record,binary):
    chosen=record['selection']['candidates'][record['candidate_index']]
    scratch,pin=_scratch(gate,base,record)
    complete=[];partial=[]
    with gate.frozen_view(record['gate_id'],approved_sha256=record['selection']['gate_sha256']) as view:
        _candidate(view['plan'],chosen)
        roots=[('worktree',chosen['path']),('git-admin',chosen['git_admin_path'])]
        manifest,_=capture._inventory(view,roots);current=shadow.digest(manifest)
        if pin['manifest_sha256'] is None:
            pin['manifest_sha256']=current;_save(base,record)
        elif pin['manifest_sha256']!=current:raise JobError('original frozen source changed before capture retry')
        for path in sorted(scratch.iterdir()):
            _partial_copy(path,gate)
            receipt=None
            if (path/'receipt.json').is_file():
                try:receipt=json.loads(shadow._bytes(path/'receipt.json',16*1024*1024))
                except (ValueError,UnicodeError):pass
            if receipt is not None:
                if (receipt.get('version')!=1 or receipt.get('gate_id')!=record['gate_id']
                        or receipt.get('gate_sha256')!=record['selection']['gate_sha256']
                        or receipt.get('repo_alias')!=chosen['repo_alias'] or receipt.get('candidate_path')!=chosen['path']
                        or receipt.get('candidate_identity')!=chosen['identity']
                        or receipt.get('git_admin_path')!=chosen['git_admin_path']):raise JobError('foreign capture receipt in exclusive scratch')
                try:
                    recovery._capture_authority(str(path),gate)
                    validated=capture.validate_capture(view,path,scratch,binary)
                except Exception:
                    # Exact originals and exclusive scratch authority were
                    # checked above. A matching but incomplete own receipt is
                    # still a disposable copy while this phase is capture.
                    partial.append(path)
                else:complete.append((path,validated))
            else:partial.append(path)
        if len(complete)>1:raise JobError('multiple completed captures require explicit inspection')
        # All originals are intact behind the actual cutoff and these exact
        # root-private partial outputs were created only during capture phase.
        # No dependent handoff can have started before this job receipt advances.
        for path in partial:
            shutil.rmtree(path);mutation._sync(scratch)
    if complete:
        path,receipt=complete[0]
    else:
        receipt=capture.prepare(gate,record['gate_id'],approved_gate_sha256=record['selection']['gate_sha256'],
            repo_alias=chosen['repo_alias'],candidate_path=chosen['path'],scratch_root=scratch,trusted_git=binary)
        path=Path(receipt.pop('artifact_path'))
    record['captures'].append(dict(path=str(path),receipt_sha256=shadow.digest(receipt)))
    record['phase']='handoff';record['pending']=None


def _derived(record, observed, extra, kind):
    selected={key:observed[key] for key in ('version','gate_id','gate_sha256','repo_alias','ref_snapshot_sha256','registry_sha256')}
    selected.update(extra)
    record['pending']=dict(kind=kind,selection=selected,sha256=shadow.digest(selected))


def _marker(base, filename, pending):
    path=base/filename
    if not path.exists():return False
    journal=json.loads(shadow._bytes(path,16*1024*1024))
    actual=journal.get('approved_selection_sha256') if filename=='retirement.json' else journal.get('artifact',{}).get('approved_selection_sha256')
    if actual==pending['sha256']:return True
    if journal.get('phase')!='complete':raise JobError('another incomplete operation owns the gate')
    return False


def _step(gate,base,record,scratch,binary):
    phase=record['phase'];scope=record['selection'];ident=record['gate_id']
    if phase=='capture':_capture_step(gate,base,record,binary);return
    if phase in ('handoff','retirement'):
        item=record['captures'][record['candidate_index']];chosen=scope['candidates'][record['candidate_index']]
        if record['pending'] is None:
            common=dict(capture_path=item['path'],capture_receipt_sha256=item['receipt_sha256'])
            if phase=='handoff':
                observed=shadow.observe(gate,ident,approved_gate_sha256=scope['gate_sha256'],repo_alias=chosen['repo_alias'],scratch_root=scratch,trusted_git=binary)
                _derived(record,observed,dict(common,approval_kind='exact-captured-recovery'),'handoff')
            else:
                selected=dict(version=1,gate_id=ident,gate_sha256=scope['gate_sha256'],repo_alias=chosen['repo_alias'],**common,approval_kind='exact-captured-retirement')
                record['pending']=dict(kind='retirement',selection=selected,sha256=shadow.digest(selected))
            _save(base,record)
        pending=record['pending']
        if pending['kind']!=phase:raise JobError('job pending operation does not match its phase')
        if phase=='handoff':
            if _marker(base,'mutation.json',pending):mutation.replay(gate,ident,approved_selection_sha256=pending['sha256'])
            else:mutation.publish_recovery(gate,pending['selection'],approved_selection_sha256=pending['sha256'],scratch_root=scratch,trusted_git=binary)
            record['phase']='retirement'
        else:
            if _marker(base,'retirement.json',pending):retirement.replay(gate,ident,approved_selection_sha256=pending['sha256'],scratch_root=scratch,trusted_git=binary)
            else:retirement.retire(gate,pending['selection'],approved_selection_sha256=pending['sha256'],scratch_root=scratch,trusted_git=binary)
            record['candidate_index']+=1
            record['phase']='capture' if record['candidate_index']<len(scope['candidates']) else 'branches'
        record['pending']=None;return
    if phase=='branches':
        if record['branch_group_index']>=len(record['branch_groups']):record['phase']='restore';return
        alias=record['branch_groups'][record['branch_group_index']]
        if record['pending'] is None:
            observed=shadow.observe(gate,ident,approved_gate_sha256=scope['gate_sha256'],repo_alias=alias,scratch_root=scratch,trusted_git=binary)
            branches=[{k:v for k,v in row.items() if k!='repo_alias'} for row in scope['branches'] if row['repo_alias']==alias]
            _derived(record,observed,dict(approval_kind='exact-frozen-selection',branches=branches),'branches');_save(base,record)
        pending=record['pending']
        if pending['kind']!='branches':raise JobError('unexpected branch pending operation')
        if _marker(base,'mutation.json',pending):mutation.replay(gate,ident,approved_selection_sha256=pending['sha256'])
        else:mutation.publish(gate,pending['selection'],approved_selection_sha256=pending['sha256'],scratch_root=scratch,trusted_git=binary)
        record['pending']=None;record['branch_group_index']+=1
        if record['branch_group_index']==len(record['branch_groups']):record['phase']='restore'
        return
    if phase=='restore':
        gate.restore(ident,approved_sha256=scope['gate_sha256']);record['phase']='complete';record['state']='complete';return
    raise JobError('unknown job phase')


def advance(gate, ident, *, scratch_root, trusted_git=shadow.TRUSTED_GIT):
    scratch,binary=shadow._authority(gate,scratch_root,trusted_git)
    with _lock(gate,ident) as base:
        record=_read(base)
        if record['scratch_root']!=str(scratch):raise JobError('armed scratch authority changed')
        if gate.inspection_context is not None and record['inspection_context']!=gate.inspection_context:
            raise JobError('job belongs to another owner context')
        if record['state']=='complete':return _summary(record)
        try:
            with gate._lock(ident):
                gated=gate._load(base)
                if gated['approved_sha256']!=record['selection']['gate_sha256']:raise JobError('armed gate approval changed')
                if record['phase']!='restore':
                    if gated['phase']!='gated':raise JobError('armed gate is no longer fully gated')
                    previous=gated.get('gated_boot_id')
                    if not isinstance(previous,str) or str(uuid.UUID(previous))!=previous:raise JobError('unknown gated boot identity')
                    current=gate._boot()
                    if str(uuid.UUID(current))!=current:raise JobError('unknown current boot identity')
                    if current==previous:
                        if record['state']!='waiting-for-boot':record['state']='waiting-for-boot';_save(base,record)
                        return _summary(record)
            record['state']='pending';record['last_error']=None
            _step(gate,base,record,scratch,binary)
            if record['phase']!='complete':record['state']='pending'
            _save(base,record)
            return _summary(record,progressed=True)
        except Exception as error:
            # Retain the pre-step durable intent, not any in-memory progress
            # after a primitive succeeded but the job completion save failed.
            record=_read(base);record['state']='failed';record['last_error']=type(error).__name__+': '+str(error)[:1000]
            _save(base,record)
            return _summary(record)
