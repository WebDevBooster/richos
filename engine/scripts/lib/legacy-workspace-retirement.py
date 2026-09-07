#!/usr/bin/env python3
"""Reclaim one captured linked worktree under a verified frozen gate.

Recovery archives remain private and retained. No archive expiry is authorized
by this module. Common Git objects are kept through verified recovery refs.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import uuid


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

capture=load('legacy-workspace-capture');mutation=load('legacy-workspace-mutation');shadow=mutation.shadow
recovery=load('terminal-recovery-shadow')


class RetirementError(RuntimeError):
    pass


def _selection(value, approved):
    fields={'version','gate_id','gate_sha256','repo_alias','capture_path','capture_receipt_sha256','approval_kind'}
    if not isinstance(value,dict) or set(value)!=fields or value['version']!=1 or value['approval_kind']!='exact-captured-retirement':
        raise RetirementError('exact captured retirement selection required')
    if any(not isinstance(value[k],str) or not 0<len(value[k])<=4096 for k in fields-{'version'}):
        raise RetirementError('bounded retirement identity fields required')
    if shadow.digest(value)!=approved:raise RetirementError('explicit matching retirement approval required')


def _archive_receipt(directory, expected):
    receipt=json.loads(shadow._bytes(directory/'receipt.json',16*1024*1024))
    if shadow.digest(receipt)!=expected:raise RetirementError('recovery receipt identity changed')
    manifest=json.loads(shadow._bytes(directory/'manifest.json',128*1024*1024))
    if shadow.digest(manifest)!=receipt['manifest_sha256']:raise RetirementError('recovery manifest changed')
    archive=directory/'recovery.tar.gz'
    fd=os.open(archive,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:
        if capture._hash(stream)!=receipt['archive_sha256']:raise RetirementError('recovery archive changed')
    capture._verify_archive(archive,manifest)
    return receipt


def _handoff(view, receipt, receipt_hash, scratch, binary, *, excluded_admin_names=()):
    dependencies=receipt['dependencies']
    if any(dependencies[key] for key in ('missing_objects','external_gitlinks','unparsed_git_state')):
        raise RetirementError('unresolved recovery object dependencies')
    common=shadow._resolve(view,receipt['repo_alias'])
    with tempfile.TemporaryDirectory(prefix='retirement-refs-',dir=scratch) as directory:
        git_directory=Path(directory)/'view.git'
        _,objects,_,refs=shadow._shadow(common,git_directory,binary,excluded_admin_names=excluded_admin_names)
        for row in dependencies['required_objects']:
            ref='refs/richos/recovery/'+receipt['gate_id']+'/'+receipt_hash+'/'+row['oid']
            if refs.get(ref)!={'oid':row['oid'],'symbolic':None}:
                raise RetirementError('durable recovery ref is missing or changed')
        recovery._closure(binary,git_directory,objects,[row['oid'] for row in dependencies['required_objects']])


def _view(gate, base, record):
    view=mutation._view(gate,base,record)
    view.update(id=base.name,approved_sha256=record['approved_sha256'],metadata=gate._entries(base))
    return view


def _archive_completed(base):
    path=base/'retirement.json'
    journal=json.loads(path.read_text())
    if journal.get('phase')!='complete':raise RetirementError('incomplete retirement requires replay')
    history=base/'retirement-history';history.mkdir(mode=0o700,exist_ok=True);mutation._sync(base)
    if 'archive_id' not in journal:
        journal['archive_id']=str(uuid.uuid4());mutation._save(path,journal)
    ident=journal['archive_id']
    if str(uuid.UUID(ident))!=ident:raise RetirementError('invalid retirement history identity')
    destination=history/ident;destination.mkdir(mode=0o700,exist_ok=True);mutation._sync(history)
    data=base/'retirement-data'
    if data.exists():
        if (destination/'data').exists():raise RetirementError('duplicate retirement history data')
        os.rename(data,destination/'data');mutation._sync(destination);mutation._sync(base)
    elif not (destination/'data').is_dir():raise RetirementError('retirement recovery metadata missing')
    mutation._save(destination/'receipt.json',journal);path.unlink();mutation._sync(base)


def retire(gate, selection, *, approved_selection_sha256, scratch_root, trusted_git=shadow.TRUSTED_GIT):
    _selection(selection,approved_selection_sha256)
    scratch,binary=shadow._authority(gate,scratch_root,trusted_git)
    directory=recovery._capture_authority(selection['capture_path'],gate)
    ident=selection['gate_id']
    with gate._lock(ident) as base:
        record=gate._load(base);gate._require_completed_mutation(base)
        view=_view(gate,base,record)
        if record['approved_sha256']!=selection['gate_sha256']:raise RetirementError('different gate approval')
        gate._verify_held(base,record,view['metadata'])
        receipt=capture.validate_capture(view,directory,scratch,binary)
        if shadow.digest(receipt)!=selection['capture_receipt_sha256'] or receipt['repo_alias']!=selection['repo_alias']:
            raise RetirementError('capture approval differs from selected recovery')
        _handoff(view,receipt,selection['capture_receipt_sha256'],scratch,binary)
        roots=[]
        for _,source in capture.source_roots(view,receipt['candidate_path'],receipt['git_admin_path'],capture_kind=receipt.get('capture_kind','full-worktree')):
            held,key=capture._map(view,source)
            roots.append({'source':source,'relative':key})
        if any(Path(a['relative']) in Path(b['relative']).parents for a in roots for b in roots if a!=b):
            raise RetirementError('retirement subtrees overlap')
        for row in view['plan']['repositories']:
            canonical=Path(row['canonical_repository']['path'])
            if any(canonical==Path(r['source']) or Path(r['source']) in canonical.parents for r in roots):
                raise RetirementError('canonical repository cannot be retired')
        if (base/'retirement.json').exists():_archive_completed(base)
        data=base/'retirement-data'
        if data.exists():
            # No intent and all held sources just revalidated. Keep incomplete
            # preparation metadata instead of making retries permanently fail.
            history=base/'retirement-preparation-history';history.mkdir(mode=0o700,exist_ok=True);mutation._sync(base)
            os.rename(data,history/str(uuid.uuid4()));mutation._sync(history);mutation._sync(base)
        data.mkdir(mode=0o700)
        mutation._atomic(data/'original-metadata.jsonl',(base/'metadata.jsonl').read_bytes())
        mutation._sync(data);mutation._sync(base)
        journal={'version':1,'phase':'removing','gate_id':ident,'selection':selection,
                 'approved_selection_sha256':approved_selection_sha256,'roots':roots,
                 'original_metadata_snapshot':mutation._snapshot_digest(data/'original-metadata.jsonl'),
                 'free_bytes_before':shutil.disk_usage(base).free}
        mutation._save(base/'retirement.json',journal)
        return _replay_locked(gate,base,record,journal,scratch,binary)


def replay(gate,ident,*,approved_selection_sha256,scratch_root,trusted_git=shadow.TRUSTED_GIT):
    scratch,binary=shadow._authority(gate,scratch_root,trusted_git)
    with gate._lock(ident) as base:
        journal=json.loads((base/'retirement.json').read_text())
        _selection(journal['selection'],approved_selection_sha256)
        if journal['approved_selection_sha256']!=approved_selection_sha256:raise RetirementError('different retirement intent')
        return _replay_locked(gate,base,gate._load(base),journal,scratch,binary)


def _replay_locked(gate,base,record,journal,scratch,binary):
    selection=journal['selection'];_selection(selection,journal['approved_selection_sha256'])
    if journal.get('version')!=1 or journal.get('gate_id')!=base.name or selection['gate_id']!=base.name:
        raise RetirementError('invalid retirement journal identity')
    if selection['gate_sha256']!=record['approved_sha256']:raise RetirementError('retirement gate approval changed')
    view=_view(gate,base,record)
    directory=recovery._capture_authority(selection['capture_path'],gate)
    receipt=_archive_receipt(directory,selection['capture_receipt_sha256'])
    if (receipt['gate_id']!=base.name or receipt['gate_sha256']!=selection['gate_sha256']
            or receipt['repo_alias']!=selection['repo_alias']):raise RetirementError('retirement capture binding changed')
    expected_roots=[{'source':source,'relative':capture._map(view,source)[1]}
                    for _,source in capture.source_roots(view,receipt['candidate_path'],receipt['git_admin_path'],capture_kind=receipt.get('capture_kind','full-worktree'))]
    if journal['roots']!=expected_roots:raise RetirementError('retirement subtree selection changed')
    if journal['phase']=='complete':
        _handoff(view,receipt,selection['capture_receipt_sha256'],scratch,binary)
        gate._verify_held(base,record,gate._entries(base))
        mutation._release_completed_snapshot(gate,base,'retirement.json',journal)
        return journal['result']
    original={}
    for line in (base/'retirement-data/original-metadata.jsonl').read_bytes().splitlines():
        row=json.loads(line)
        if row['relative'] in original:raise RetirementError('duplicate retirement metadata')
        original[row['relative']]=row
    prefixes=[mutation._relative(row['relative']).as_posix() for row in journal['roots']]
    selected={key for key in original if any(key==p or key.startswith(p+'/') for p in prefixes)}
    if not selected or any(p not in original for p in prefixes):raise RetirementError('retirement target inventory missing')
    transient=dict(original)
    for key in selected:
        if not os.path.lexists(base/key):transient.pop(key)
    provisional=dict(record,roots=[dict(row,retired=True) if row['held'] in prefixes and not os.path.lexists(base/row['held']) else row for row in record['roots']])
    gate._verify_held(base,provisional,transient)
    # A prior deletion may have removed HEAD/gitdir from this exact selected
    # admin directory. It is the only allowed registry exclusion, after every
    # remaining inode (including its partial contents) has been verified.
    admin=Path(receipt['git_admin_path'])
    if admin.parent!=Path(receipt['common_git_identity']['path'])/'worktrees':
        raise RetirementError('retiring registration is outside captured common Git storage')
    _handoff(view,receipt,selection['capture_receipt_sha256'],scratch,binary,excluded_admin_names=(admin.name,))
    for key in sorted(selected,key=lambda s:(len(Path(s).parts),s),reverse=True):
        path=base/key
        if not os.path.lexists(path):continue
        metadata=gate._metadata(path)
        if any(metadata[k]!=original[key][k] for k in ('device','inode','kind')):
            raise RetirementError('retirement inode changed')
        if metadata['kind']=='directory':path.rmdir()
        else:path.unlink()
        mutation._sync(path.parent)
    effective={key:value for key,value in original.items() if key not in selected}
    for row in record['roots']:
        if row['held'] in prefixes:row['retired']=True
    gate._verify_held(base,record,effective)
    gate._save(base,record)
    mutation._atomic(base/'metadata.jsonl',b''.join((json.dumps(row,sort_keys=True)+'\n').encode() for _,row in sorted(effective.items())))
    journal['phase']='complete'
    journal['result']={'gate_id':base.name,'phase':'complete','candidate_path':receipt['candidate_path'],
                       'registration_removed':True,'working_directory_reclaimed':receipt.get('capture_kind','full-worktree')=='full-worktree',
                       'capture_kind':receipt.get('capture_kind','full-worktree'),
                       'recovery_path':str(directory),'recovery_retained':True,'automatic_expiry_authorized':False,
                       'free_change_since_retirement_intent_bytes':shutil.disk_usage(base).free-journal['free_bytes_before']}
    mutation._save(base/'retirement.json',journal)
    mutation._release_completed_snapshot(gate,base,'retirement.json',journal)
    return journal['result']
