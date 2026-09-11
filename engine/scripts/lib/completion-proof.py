#!/usr/bin/env python3
"""Committed proof for the TaskCompleted workflow.

A worker's task is completed only when every workspace it has — its
registration in scripts/lib/workspaces.py — is committed and clean. This is a
cooperative engine invariant, not a same-user security sandbox. It deletes
nothing: the workspace spec's land and discard decide deletion
(docs/plans/worktree-spec-2026-09-11.md).
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('completion_filesystem', HERE/'durable-filesystem-identity.py')
filesystem = importlib.util.module_from_spec(spec)
spec.loader.exec_module(filesystem)
GIT = '/Library/Developer/CommandLineTools/usr/bin/git' if sys.platform == 'darwin' else '/usr/bin/git'
LIMIT = 4 * 1024 * 1024
DEADLINE = None

def remaining():
    left = 90 if DEADLINE is None else DEADLINE - time.monotonic()
    if left <= 0: raise CompletionError("Completion proof timed out; task remains open")
    return min(30, left)
class CompletionError(ValueError): pass

def digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()

def segment(value):
    if not isinstance(value,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',value):
        raise CompletionError('Exact task/session identity is missing')
    return value

def profile(): return Path(os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude'))
def receipt_root(): return Path(os.environ.get('RICHOS_COMPLETION_DIR') or profile()/'state/workspace-completions')

def read_json(path):
    info=os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_size>LIMIT:
        raise CompletionError('Completion metadata is aliased or oversized')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:
        opened=os.fstat(stream.fileno())
        if (info.st_dev,info.st_ino)!=(opened.st_dev,opened.st_ino): raise CompletionError('Completion metadata changed')
        data=stream.read(LIMIT+1)
    if len(data)>LIMIT: raise CompletionError('Completion metadata grew beyond its bound')
    value=json.loads(data)
    if not isinstance(value,dict): raise CompletionError('Completion metadata must be an object')
    return value

def identity(path):
    info=os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or os.path.realpath(path)!=str(path):
        raise CompletionError('Workspace administration is aliased or missing')
    return [filesystem.filesystem_token(path,info),info.st_ino]

def git(path,*args, allowed=(0,)):
    env={'PATH':'/usr/bin:/bin','HOME':'/var/empty','LC_ALL':'C','GIT_CONFIG_NOSYSTEM':'1',
         'GIT_CONFIG_SYSTEM':'/dev/null','GIT_CONFIG_GLOBAL':'/dev/null','GIT_TERMINAL_PROMPT':'0',
         'GIT_NO_REPLACE_OBJECTS':'1','GIT_OPTIONAL_LOCKS':'0'}
    result=subprocess.run([GIT,'--no-replace-objects','-C',str(path),'-c','core.hooksPath=/dev/null',
                           '-c','core.fsmonitor=false','-c','core.untrackedCache=false','-c','protocol.allow=never',*args],
                          env=env,capture_output=True,timeout=remaining())
    if result.returncode not in allowed:
        raise CompletionError('Git proof could not complete: '+result.stderr.decode('utf-8','replace')[-500:])
    return result

def text(path,*args): return git(path,*args).stdout.decode('utf-8').strip()
def direct(path,ref):
    if git(path,'symbolic-ref','-q',ref,allowed=(0,1)).returncode==0:
        raise CompletionError('Integration and delivery branches must be direct refs')
    # A TRUNK THAT IS NOT `main` IS A NAMED CONDITION, NOT A GIT MYSTERY
    # (2026-09-10). prove_member hard-codes integration='refs/heads/main' and
    # validate_member_schema refuses any other, so on a `master` repository
    # this raised 'Git proof could not complete' — fail-closed, which is right,
    # with a reason that sends the reader looking for a broken git. It is not
    # broken: this proof only understands `main`. Saying so is the difference
    # between a hold somebody can act on and one they cannot.
    if git(path,'show-ref','--verify','--quiet',ref,allowed=(0,1)).returncode:
        head=''
        try:
            raw=git(path,'symbolic-ref','--short','-q','HEAD',allowed=(0,1)).stdout
            if isinstance(raw,bytes): raw = raw.decode('utf-8','replace')
            head=(raw or '').strip()
        except Exception:
            head=''
        raise CompletionError(
            'This repository has no %s. This proof understands `main` and nothing else, '
            'so a repository whose trunk is %s is HELD rather than examined — deliberately, because '
            'guessing the trunk is how work gets called delivered into a branch nobody integrated into. '
            'It is not a broken repository and there is nothing to repair here.'
            % (ref, ('`%s`' % head) if head else 'something else'))
    value=text(path,'rev-parse','--verify',ref)
    if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})',value): raise CompletionError('Invalid Git object identity')
    return value

def registry(repo):
    raw=git(repo,'worktree','list','--porcelain','-z').stdout
    if not raw or not raw.endswith(b'\0\0'): raise CompletionError('Incomplete Git worktree registry')
    rows={}
    for chunk in raw[:-2].split(b'\0\0'):
        fields=chunk.split(b'\0')
        if not fields or not fields[0].startswith(b'worktree '): raise CompletionError('Malformed Git worktree registry')
        path=os.fsdecode(fields[0][9:]); row={}
        if path in rows: raise CompletionError('Duplicate Git registration')
        for field in fields[1:]:
            key,_,value=field.partition(b' ')
            key=key.decode('ascii')
            if key in row or key not in ('HEAD','branch','detached','bare','locked','prunable'):
                raise CompletionError('Unknown Git registration field')
            row[key]=os.fsdecode(value)
        rows[path]=row
    return rows

def clean_tree(path,head,reclaimable=True):
    # UNTRACKED, NON-IGNORED files refuse: they are work nobody committed. IGNORED
    # files do not — for a linked worktree or the canonical checkout alike.
    # Until 2026-09-10 a reclaimable (linked) worktree was listed WITHOUT
    # --exclude-standard, so one __pycache__/x.pyc — a path the engine's own
    # committed disposable policy already calls disposable — held a workspace
    # forever and stopped its worker marking a task complete: 20 of the 29
    # terminal members present on the operator's machine that day were held by
    # exactly this line (docs/worktree-reclaim-round-10-2026-09-10.md, P1).
    # What happens to ignored bytes is decided at LAND time (the workspace
    # spec's point 8, scripts/lib/workspaces.py). The digest below is over
    # TRACKED entries only, so an ignored file never changes a proof.
    if git(path,'ls-files','--others','--exclude-standard','-z').stdout:
        raise CompletionError('Commit intended deliverables, remove disposable local copies/build output or preserve needed non-Git data before completing; do not add secrets to Git')
    flags=git(path,'ls-files','-v','-z').stdout
    if any(row and (row[:1].islower() or row.startswith(b'S ')) for row in flags.split(b'\0')):
        raise CompletionError('Index assume/skip flags prevent a complete byte proof')
    tree={}
    for row in git(path,'ls-tree','-r','-z',head).stdout.split(b'\0'):
        if not row: continue
        fields,name=row.split(b'\t',1); mode,kind,oid=fields.split(b' ')
        if kind!=b'blob' or mode not in (b'100644',b'100755',b'120000'):
            raise CompletionError('Nested Git delivery needs its own completion proof')
        if name.startswith(b'/') or b'..' in name.split(b'/'): raise CompletionError('Invalid Git path')
        tree[name]=(mode,oid)
    index={}
    for row in git(path,'ls-files','--stage','-z').stdout.split(b'\0'):
        if not row:continue
        fields,name=row.split(b'\t',1);mode,oid,stage=fields.split(b' ')
        if stage!=b'0' or name in index: raise CompletionError('Resolve staged conflicts before completion')
        index[name]=(mode,oid)
    if tree!=index: raise CompletionError('Commit staged changes before completing')
    manifest=[]
    for name,(mode,oid) in sorted(tree.items()):
        remaining()
        target=Path(path)/os.fsdecode(name);info=os.lstat(target)
        for parent in target.parents:
            if parent==Path(path):break
            if not stat.S_ISDIR(os.lstat(parent).st_mode):raise CompletionError('Tracked parent directory is an alias')
        if mode==b'120000':
            if not stat.S_ISLNK(info.st_mode) or info.st_nlink!=1: raise CompletionError('Tracked link identity changed')
            data=os.fsencode(os.readlink(target));size=len(data)
            h=hashlib.sha1() if len(oid)==40 else hashlib.sha256();h.update(b'blob '+str(size).encode()+b'\0');h.update(data)
        else:
            if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or bool(info.st_mode&0o111)!=(mode==b'100755'):
                raise CompletionError('Tracked file mode or link topology is not committed')
            size=info.st_size;h=hashlib.sha1() if len(oid)==40 else hashlib.sha256();h.update(b'blob '+str(size).encode()+b'\0')
            fd=os.open(target,os.O_RDONLY|os.O_NOFOLLOW)
            with os.fdopen(fd,'rb') as stream:
                opened=os.fstat(stream.fileno())
                if (opened.st_dev,opened.st_ino)!=(info.st_dev,info.st_ino): raise CompletionError('Working file changed during proof')
                count=0
                while True:
                    remaining()
                    chunk=stream.read(65536)
                    if not chunk:break
                    count+=len(chunk);h.update(chunk)
                    if count>size:raise CompletionError('Working file grew during proof')
                if count!=size:raise CompletionError('Working file changed during proof')
        if h.hexdigest().encode()!=oid: raise CompletionError('Commit unstaged working bytes before completing')
        after=os.lstat(target)
        if (info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns):
            raise CompletionError('Working file changed during proof')
        manifest.append([name.hex(),mode.decode(),oid.decode()])
    return digest(manifest)

def assert_settled(admin):
    for name in ('MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','REBASE_HEAD','rebase-merge','rebase-apply','sequencer','BISECT_START','index.lock','HEAD.lock'):
        if os.path.lexists(admin/name):
            raise CompletionError('Finish or explicitly abort the unfinished Git operation before completing: '+name)

def prove_member(member):
    path=Path(member['path']);repo=Path(member['repo'])
    pins={'path':identity(path),'repo':identity(repo)}
    if text(path,'rev-parse','--show-toplevel')!=str(path): raise CompletionError('Member is not its exact Git checkout')
    admin=Path(text(path,'rev-parse','--absolute-git-dir'))
    common=Path(text(path,'rev-parse','--path-format=absolute','--git-common-dir'))
    if Path(text(repo,'rev-parse','--path-format=absolute','--git-common-dir'))!=common:
        raise CompletionError('Member canonical repository does not match')
    pins.update(admin=identity(admin),common=identity(common))
    assert_settled(admin)
    if text(repo,'rev-parse','--show-toplevel')!=str(repo) or Path(text(repo,'rev-parse','--absolute-git-dir'))!=common:
        raise CompletionError('Intended canonical checkout is not the Git common checkout')
    reclaimable = path!=repo and admin!=common
    row=registry(repo).get(str(path))
    if not row:raise CompletionError('Exact member registration is absent')
    branch=row.get('branch','')
    expected=member.get('branch') or ''
    if expected and not expected.startswith('refs/'):expected='refs/heads/'+expected
    if branch!=expected:raise CompletionError('Member branch differs from its bound ownership')
    head=text(path,'rev-parse','--verify','HEAD')
    if row.get('HEAD')!=head:raise CompletionError('Registered member tip changed')
    # COMPLETION AND RECLAMATION ARE DIFFERENT QUESTIONS, AND THIS IS WHERE THEY
    # WERE ONE. A refusal used to sit on the next line: head had to be an
    # ancestor of refs/heads/main before a task could be marked complete
    # ("Merge the committed deliverable into canonical main before completing").
    #
    # That inverts the documented handoff order. A teammate commits on its own
    # branch and marks its task complete as its final step; only the lead merges,
    # and the lead merges AFTER the teammate reports. Requiring the merge first
    # means the merge waits for a completion that waits for the merge, so no
    # teammate can ever finish. The gate's evidence for a WORKER's delivery is
    # its commits on its OWN branch being clean, real and byte-identical to the
    # tree — which is everything else in this function, all of it retained.
    #
    # The integration fact is still established and still recorded, because the
    # question it answers is real; it is just a different question, asked by a
    # different caller at a different time: landing (scripts/lib/workspaces.py
    # land) requires every tip to be in main; finishing a task does not.
    integration='refs/heads/main';main=direct(repo,integration)
    proof={'version':1,'original_path':str(path),'repo':str(repo),'common':str(common),'admin':str(admin),
           'identities':pins,'branch':branch,'head':head,'integration_ref':integration,'integration_tip':main,
           'working_tree_sha256':clean_tree(path,head,reclaimable),'reclaimable':reclaimable}
    for name,target in [('path',path),('repo',repo),('admin',admin),('common',common)]:
        if identity(target)!=pins[name]:raise CompletionError('Member identity changed during completion')
    assert_settled(admin)
    if text(path,'rev-parse','--verify','HEAD')!=head or direct(repo,integration)!=main:
        raise CompletionError('Git tips changed during completion')
    return proof

def validate_member_schema(proof):
    required={'version','original_path','repo','common','admin','identities','branch','head','integration_ref','integration_tip','working_tree_sha256','reclaimable'}
    if not isinstance(proof,dict) or set(proof)!=required or proof['version']!=1 or proof['integration_ref']!='refs/heads/main' or not isinstance(proof['reclaimable'],bool):
        raise CompletionError('Malformed member proof schema')
    for key in ('original_path','repo','common','admin'):
        if not isinstance(proof[key],str) or not os.path.isabs(proof[key]):raise CompletionError('Malformed member proof path')
    if not isinstance(proof['branch'],str) or (proof['branch'] and not proof['branch'].startswith('refs/heads/')):raise CompletionError('Malformed member proof branch')
    for key in ('head','integration_tip','working_tree_sha256'):
        if not isinstance(proof[key],str) or not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})',proof[key]):raise CompletionError('Malformed member proof object')
    pins=proof['identities']
    if not isinstance(pins,dict) or set(pins)!={'path','repo','common','admin'}:raise CompletionError('Malformed member proof identities')
    for value in pins.values():
        if not isinstance(value,list) or len(value)!=2 or not isinstance(value[0],str) or not value[0] or not isinstance(value[1],int) or value[1]<=0:raise CompletionError('Malformed member proof identity')

def verify_member_proof(proof,path_present=True):
    validate_member_schema(proof)
    if proof.get('version')!=1 or proof.get('integration_ref')!='refs/heads/main':raise CompletionError('Unsupported member proof')
    path=Path(proof['original_path']);repo=Path(proof['repo'])
    for key in ('repo','common'):
        if identity(Path(proof[key]))!=proof['identities'][key]:raise CompletionError('Canonical identity changed')
    main=direct(repo,proof['integration_ref'])
    if git(repo,'merge-base','--is-ancestor',proof['head'],main,allowed=(0,1)).returncode:
        # THE VERDICT IS RIGHT AND THE OLD REASON WAS MISLEADING (2026-09-10).
        # Refusing here is correct under R3 and both reviewers confirmed it:
        # only a tip PROVEN an ancestor of the integration branch is ever
        # removed, so a workspace whose commits main does not contain is held,
        # which is the whole protection. What the message did not say is that
        # there are two ways to arrive here and they need different actions:
        #
        #   * the work never landed        -> land it, or write a disposition;
        #   * the work landed by SQUASH or REBASE -> the content is on main
        #     under a DIFFERENT commit, so this branch tip can never become an
        #     ancestor and this member will be held forever with no way to
        #     self-close. That is a real hold, not a bug, and the operator has
        #     to retire the branch deliberately.
        #
        # `git cherry` answers which one, by patch id, and is a reader.
        equivalent = ''
        try:
            out = git(repo,'cherry',proof['integration_ref'],proof['head'],allowed=(0,1)).stdout
            if isinstance(out,bytes): out = out.decode('utf-8','replace')
            lines = [l for l in (out or '').splitlines() if l.strip()]
            if lines and all(l.startswith('-') for l in lines):
                equivalent = (' EVERY commit on this branch is already on %s under a DIFFERENT sha '
                              '(git cherry: %d of %d equivalent), so it landed by squash or rebase '
                              'and this tip can NEVER become an ancestor. This member will be held '
                              'forever unless the branch is retired deliberately.'
                              % (proof['integration_ref'], len(lines), len(lines)))
            elif lines:
                kept = sum(1 for l in lines if l.startswith('+'))
                equivalent = (' %d of %d commits on this branch are NOT on %s by patch id, so this '
                              'is unlanded work rather than a squash landing.'
                              % (kept, len(lines), proof['integration_ref']))
        except Exception:
            equivalent = ' (whether it landed under a different sha could not be determined here.)'
        raise CompletionError('Current canonical main no longer contains the delivery.' + equivalent)
    if proof['branch']:
        if git(repo,'symbolic-ref','-q',proof['branch'],allowed=(0,1)).returncode==0:
            raise CompletionError('Owned branch became symbolic; direct reference required')
        exists=git(repo,'show-ref','--verify','--quiet',proof['branch'],allowed=(0,1)).returncode==0
        if (path_present or exists) and direct(repo,proof['branch'])!=proof['head']:
            raise CompletionError('Owned branch changed since completion')
    if path_present:
        actual=prove_member({'path':str(path),'repo':str(repo),'branch':proof['branch']})
        for key in ('original_path','repo','common','admin','identities','branch','head','working_tree_sha256','reclaimable'):
            if actual[key]!=proof[key]:raise CompletionError('Completed member changed: '+key)
    elif not proof.get('reclaimable',False) or os.path.lexists(path) or str(path) in registry(repo):
        raise CompletionError('Removed member still has a path or registration')
    return proof

def verify_receipt(receipt,member_path,*,path_present=True):
    body=dict(receipt);expected=body.pop('proof_sha256',None)
    if expected!=digest(body) or body.get('version')!=1 or body.get('kind')!='integrated-completion':
        raise CompletionError('Completion receipt digest or kind changed')
    rows=[row for row in body['members'] if row['original_path']==str(member_path)]
    if len(rows)!=1:raise CompletionError('Completion receipt member is ambiguous')
    return verify_member_proof(rows[0],path_present=path_present)

def receipts_for_member(session_id,agent_id,original_path):
    root=receipt_root()/segment(session_id)
    if not root.exists():return []
    rows=list(root.glob('*.json'))
    if len(rows)>10000:raise CompletionError('Completion receipt inventory exceeds bound')
    result=[]
    for path in rows:
        receipt=read_json(path)
        if receipt.get('session_id')==session_id and receipt.get('agent_id')==agent_id and any(p.get('original_path')==str(original_path) for p in receipt.get('members',[])):
            body=dict(receipt);expected=body.pop('proof_sha256',None)
            if expected!=digest(body) or body.get('version')!=1 or body.get('kind')!='integrated-completion':
                raise CompletionError('Completion receipt digest or kind changed')
            for member in body['members']:validate_member_schema(member)
            try:verify_receipt(receipt,original_path,path_present=os.path.lexists(original_path))
            except CompletionError:continue # Prior completed tasks can predate a later integrated tip.
            result.append(receipt)
    return result

def native_task(payload):
    sid=segment(payload.get('session_id'));tid=segment(str(payload.get('task_id') or ''))
    root=Path(os.environ.get('RICHOS_TASKS_DIR') or profile()/'tasks')
    namespaces={sid,'session-'+sid[:8]}
    if payload.get('team_name'):namespaces.add(segment(payload['team_name']))
    found=[]
    for namespace in namespaces:
        path=root/namespace/(tid+'.json')
        if os.path.lexists(path):
            if namespace not in (sid,'session-'+sid[:8]):
                config=read_json(profile()/'teams'/namespace/'config.json')
                if config.get('leadSessionId')!=sid:raise CompletionError('Native task team belongs to another session')
            found.append(read_json(path))
    if len(found)!=1 or str(found[0].get('id'))!=tid:
        raise CompletionError('Exact native task record is missing or ambiguous; keep the task open')
    task=found[0];owner=task.get('owner') or ''
    if not isinstance(owner,str) or (payload.get('teammate_name') and payload['teammate_name']!=owner):
        raise CompletionError('Task owner does not match completion attribution')
    return sid,tid,owner,task

def native_lead(payload, sid, owner):
    # Native task lists commonly leave lead-owned tasks unassigned. Establish
    # lead authority from the live native session registry, not a guessed name.
    if owner:
        team=payload.get('team_name')
        if not team: raise CompletionError('Named task owner has no bound worker or lead team evidence')
        config=read_json(profile()/'teams'/segment(team)/'config.json')
        lead=config.get('leadAgentId')
        members=[m for m in config.get('members',[]) if m.get('agentId')==lead and m.get('name')==owner]
        if config.get('leadSessionId')!=sid or len(members)!=1:
            raise CompletionError('Task owner is not the recorded native lead')
    root=Path(os.environ.get('RICHOS_SESSIONS_DIR') or profile()/'sessions')
    paths=list(root.glob('*.json'))
    if len(paths)>10000:raise CompletionError('Native session inventory exceeds bound')
    matches=[read_json(p) for p in paths]
    matches=[r for r in matches if r.get('sessionId')==sid]
    if len(matches)!=1:raise CompletionError('Exact native lead session is absent or ambiguous')
    row=matches[0];pid=row.get('pid')
    if not isinstance(pid,int) or pid<=1 or not isinstance(row.get('procStart'),str):
        raise CompletionError('Native session process identity is missing')
    # Native Claude 2.1.263 Vse/Ba producer uses LC_ALL=C TZ=UTC ps lstart.
    process_env={'PATH':'/usr/bin:/bin','LC_ALL':'C','LANG':'C','TZ':'UTC'}
    actual=subprocess.run(['/bin/ps','-p',str(pid),'-o','lstart='],env=process_env,capture_output=True,text=True,timeout=remaining())
    if actual.returncode or ' '.join(actual.stdout.split())!=' '.join(row['procStart'].split()):
        raise CompletionError('Native lead process incarnation changed')
    current=os.getpid()
    for _ in range(64):
        if current==pid:break
        parent=subprocess.run(['/bin/ps','-p',str(current),'-o','ppid='],capture_output=True,text=True,timeout=remaining())
        if parent.returncode or not parent.stdout.strip().isdigit():raise CompletionError('Native lead ancestry is unavailable')
        current=int(parent.stdout.strip())
        if current<=1:raise CompletionError('Completion is not running inside the recorded native lead')
    else:raise CompletionError('Native lead ancestry exceeds bound')
    cwd=row.get('cwd')
    if not isinstance(cwd,str) or not os.path.isabs(cwd) or os.path.realpath(payload.get('cwd',''))!=os.path.realpath(cwd):
        raise CompletionError('Lead completion cwd differs from its native session')
    return row,os.path.realpath(cwd)

def workspace_members(cwd):
    here=Path(cwd)
    if not any(os.path.lexists(p/'.git') for p in (here,*here.parents)):
        identity(here)
        return [] # Explicit native session outside Git. No workspace cleanup receipt.
    path=Path(text(here,'rev-parse','--show-toplevel'))
    common=Path(text(path,'rev-parse','--path-format=absolute','--git-common-dir'))
    rows=registry(path)
    canonical=[]
    for candidate in rows:
        dot=Path(candidate)/'.git'
        if dot.is_dir() and not dot.is_symlink() and dot.resolve()==common:
            canonical.append(candidate)
    if len(canonical)!=1:raise CompletionError('Canonical checkout cannot be identified exactly')
    return [{'path':str(path),'repo':canonical[0],'branch':rows[str(path)].get('branch','')}]

def registration(sid, owner):
    """The worker's registration in the workspace registry (scripts/lib/workspaces.py;
    docs/plans/worktree-spec-2026-09-11.md, points 3, 6, 10): every workspace it
    has, recorded when it was spawned. None when the task owner has none."""
    spec=importlib.util.spec_from_file_location('completion_workspaces', HERE/'workspaces.py')
    ws=importlib.util.module_from_spec(spec);spec.loader.exec_module(ws)
    if not owner:return None,ws
    return ws.load_agent(ws.named_key(sid,owner)),ws

def complete(payload):
    if payload.get('hook_event_name')!='TaskCompleted':raise CompletionError('Expected TaskCompleted evidence')
    sid,tid,owner,task=native_task(payload)
    rec,ws=registration(sid,owner)
    if not rec:
        lead,cwd=native_lead(payload,sid,owner)
        members=workspace_members(cwd)
        proofs=[prove_member(m) for m in members]
        aid='lead-'+sid
        tx={'record':'native-lead-task','kind':'lead-git' if proofs else 'lead-non-git','native_session':lead}
    else:
        tx=rec;aid=segment(rec.get('agent_id') or ('unbound-'+owner))
        if payload.get('agent_id') and rec.get('agent_id') and payload['agent_id']!=rec['agent_id']:
            raise CompletionError('Task completion comes from a different agent than the registered worker')
        members=[{'path':w['path'],'repo':w['repo'],'branch':w.get('branch') or ''}
                 for w in ws.live_workspaces(rec) if w.get('path') and os.path.isdir(w['path'])]
        if not members:
            proofs=[]  # a worker with no workspace on disk (a main-checkout run, a remote one) has no local scope
        else:
            proofs=[prove_member(m) for m in members]
    receipt={'version':1,'kind':'integrated-completion','session_id':sid,'task_id':tid,'agent_id':aid,'teammate':owner,
             'task_record_sha256':digest(task),'transaction_sha256':digest(tx),'members':proofs,
             'non_code_evidence':tx['kind'] if not proofs else None}
    receipt['proof_sha256']=digest(receipt)
    directory=receipt_root()/sid;directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    target=directory/(tid+'.json')
    fd,temp=tempfile.mkstemp(prefix='.completion-',dir=directory)
    try:
        with os.fdopen(fd,'w') as stream:
            json.dump(receipt,stream,sort_keys=True,separators=(',',':'));stream.flush();os.fsync(stream.fileno())
        os.replace(temp,target)
        fd=os.open(directory,os.O_RDONLY)
        try:os.fsync(fd)
        finally:os.close(fd)
    finally:
        if os.path.exists(temp):os.unlink(temp)
    return receipt

if __name__=='__main__':
    try:
        DEADLINE=time.monotonic()+90
        data=sys.stdin.buffer.read(LIMIT+1)
        if len(data)>LIMIT:raise CompletionError('Completion event exceeds its bound')
        complete(json.loads(data))
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as error:
        print('Task remains unfinished: '+str(error),file=sys.stderr)
        sys.exit(2)
