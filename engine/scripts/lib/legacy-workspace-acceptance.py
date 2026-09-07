#!/usr/bin/env python3
"""Installed, three-phase acceptance using only freshly minted legacy fixtures.

Run with protected Command Line Tools Python -I -S -B. This never requests a
reboot, starts launchd, changes production policy or deletes fixture evidence.
"""
import argparse
import base64
import contextlib
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import select
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

PYTHON = '/Library/Developer/CommandLineTools/usr/bin/python3'
ENV = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME='/var/empty', LC_ALL='C',
           GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
ID = re.compile(r'legacy-acceptance-[0-9a-f]{32}\Z')


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name+'.py'))
    module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


fs_identity = load('durable-filesystem-identity')


def sync(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:os.fsync(fd)
    finally:os.close(fd)


def save(path, value):
    fd, temporary = tempfile.mkstemp(prefix='.receipt-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True);stream.write('\n');stream.flush();os.fsync(stream.fileno())
        os.replace(temporary, path);sync(path.parent)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)


def pin(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode):raise ValueError('exact fixture directory required')
    return dict(device=fs_identity.filesystem_token(path,info), inode=info.st_ino)


def restored_pin(path, expected):
    info=path.lstat()
    observed=dict(device=fs_identity.filesystem_token(path,info),inode=info.st_ino,uid=info.st_uid,gid=info.st_gid,mode=stat.S_IMODE(info.st_mode))
    require(stat.S_ISDIR(info.st_mode) and observed=={key:expected[key] for key in observed},
            'restored fixture identity or access metadata differs: '+str(path))


def require(condition, message):
    if not condition:raise ValueError(message)


def fixed_paths(policy, ident):
    require(isinstance(ident, str) and ID.fullmatch(ident), 'minted acceptance ID required')
    private = Path(policy['private_root']).resolve(strict=True)/ident
    active = Path(policy['active_root']).resolve(strict=True)/ident
    require(private != active and private not in active.parents and active not in private.parents,
            'separate fixture namespaces required')
    return private, active


# This constant executes only after dropping all root credentials. It creates
# an independent tiny repository, never reads a user-selected source or config.
SETUP = r'''
import base64,json,os,pathlib,signal,subprocess,sys
signal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGTERM,signal.SIGINT})
root=pathlib.Path(sys.argv[1]);repo=root/'repo';work=root/'worker'
def git(path,*args,input=None):
    return subprocess.check_output(['/usr/bin/git','-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false','-C',str(path),*args],input=input,stderr=subprocess.PIPE)
repo.mkdir(mode=0o700)
git(repo,'init','-q','-b','main','--template=')
git(repo,'config','user.name','Legacy fixture');git(repo,'config','user.email','fixture@example.invalid')
(repo/'file').write_bytes(b'committed');git(repo,'add','file');git(repo,'commit','-qm','fixture')
head=git(repo,'rev-parse','HEAD').decode().strip()
git(repo,'worktree','add','-qb','worker',str(work))
(work/'file').write_bytes(b'staged-only');git(work,'add','file')
staged=git(work,'rev-parse',':file').decode().strip()
(work/'file').write_bytes(b'working');(work/'untracked').write_bytes(b'untracked\x00unique')
(work/'link').symlink_to('untracked');(work/'cache').mkdir()
(work/'cache'/'CACHEDIR.TAG').write_bytes(b'Signature: 8a477f597d28d172789f06886806bc55\n')
(work/'cache'/'unique').write_bytes(b'cache-tagged-unique')
if sys.platform=='darwin':
    subprocess.run(['/usr/bin/xattr','-w','org.richos.fixture','fixture-xattr',str(work/'file')],check=True)
for directory,dirs,files in os.walk(root,topdown=False):
    for name in files:
        path=pathlib.Path(directory)/name
        if not path.is_symlink():
            with path.open('rb') as stream:os.fsync(stream.fileno())
    descriptor=os.open(directory,os.O_RDONLY|os.O_DIRECTORY);os.fsync(descriptor);os.close(descriptor)
print(json.dumps(dict(head=head,staged_oid=staged,index_sha256=__import__('hashlib').sha256(pathlib.Path(git(work,'rev-parse','--absolute-git-dir').decode().strip(),'index').read_bytes()).hexdigest())),flush=True)
sys.stdin.readline()
'''
HOLDER = r'''
import json,os,signal,sys,time
signal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGTERM,signal.SIGINT})
fd=os.open(sys.argv[1],os.O_RDWR);directory=os.open(os.path.dirname(sys.argv[1]),os.O_RDONLY|os.O_DIRECTORY)
signal.signal(signal.SIGHUP,signal.SIG_IGN)
print('ready',flush=True)
held=sys.stdin.readline().strip()
checks={}
for name,operation in [('new-open',lambda:os.open(held,os.O_RDWR)),('old-fd-chmod',lambda:os.fchmod(fd,0o777)),('old-dir-create',lambda:os.open('forbidden-new-file',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600,dir_fd=directory))]:
    try:
        result=operation()
        if isinstance(result,int):os.close(result)
        checks[name]=False
    except PermissionError:checks[name]=True
os.lseek(fd,0,os.SEEK_END);os.write(fd,b'-late-before-reboot');os.fsync(fd)
print(json.dumps(checks),flush=True)
while True:time.sleep(3600)
'''


class Acceptance:
    def __init__(self):
        self.runtime = load('managed-workspace-broker')
        self.release = self.runtime.validate_runtime()
        require(os.geteuid() == 0 and sys.platform == 'darwin', 'installed macOS root acceptance required')
        require(Path(sys.executable).resolve() == Path(PYTHON).resolve(), 'fixed protected interpreter required')
        self.policy = self.runtime.validate_policy(json.loads(self.runtime.protected_path(
            self.release.parent.parent/'policy.json', regular=True).read_text()))
        self.gate = load('legacy-workspace-gate');self.job = load('legacy-workspace-job')
        self.ledger = load('worktree-ledger')
        self.release_identity = {name: hashlib.sha256((self.release/name).read_bytes()).hexdigest()
                                 for name in self.runtime.CODE_FILES}

    def owner(self, uid):
        value = self.policy['owners'].get(str(uid))
        require(value is not None, 'owner is not approved by installed policy')
        account = pwd.getpwuid(uid)
        require(value['gid'] == account.pw_gid and uid > 0, 'approved owner account changed')
        return uid, value['gid']

    def child(self, record, argv, **kwargs):
        uid, gid = self.owner(record['owner_uid'])
        return subprocess.run(argv, env=ENV, user=uid, group=gid, extra_groups=[], cwd='/',
                              capture_output=True, timeout=kwargs.pop('timeout', 30), **kwargs)

    def git(self, record, repo, *args, input=None, check=True):
        result = self.child(record, ['/usr/bin/git','-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false',
                                   '-C',str(repo),*args], input=input)
        if check:require(result.returncode == 0, 'fixture Git failed: '+result.stderr.decode(errors='replace')[:500])
        return result.stdout if check else result

    @contextlib.contextmanager
    def existing(self, ident):
        private, active = fixed_paths(self.policy, ident)
        self.runtime.protected_path(private, regular=False)
        self.runtime.protected_path(active, regular=False)
        fd = os.open(private/'acceptance.lock', os.O_RDWR|os.O_NOFOLLOW)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB)
            path = self.runtime.protected_path(private/'receipt.json', regular=True)
            record = json.loads(path.read_text())
            require(record.get('version') == 1 and record.get('id') == ident, 'fixture receipt identity mismatch')
            require(record.get('private') == str(private) and record.get('active') == str(active), 'fixture namespace mismatch')
            require(all(isinstance(record[key].get('device'),str) for key in ('private_identity','active_identity')),
                    'legacy fixture has no durable filesystem UUID; retain evidence and prepare a new fixture')
            require(record['private_identity'] == pin(private) and record['active_identity'] == pin(active), 'fixture root was replaced')
            require(record['release'] == str(self.release) and record['release_identity'] == self.release_identity,
                    'resume requires the exact protected acceptance release')
            self.owner(record['owner_uid'])
            yield private, active, record
        finally:os.close(fd)

    @staticmethod
    def stop_child(process):
        process.terminate()
        try:process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill();process.communicate(timeout=10)

    def prepare(self, uid):
        owner = self.owner(uid)
        ident = 'legacy-acceptance-'+uuid.uuid4().hex
        private, active = fixed_paths(self.policy, ident)
        for root in (private.parent, active.parent):self.runtime.protected_path(root, regular=False)
        require(private.parent.stat().st_dev == active.parent.stat().st_dev, 'same-filesystem fixture required')
        private.mkdir(mode=0o700);private.chmod(0o700);sync(private.parent)
        active.mkdir(mode=0o711);active.chmod(0o711);sync(active.parent)
        fd=os.open(private/'acceptance.lock',os.O_CREAT|os.O_EXCL|os.O_RDWR,0o600);os.close(fd)
        record=dict(version=1,id=ident,phase='preparing',owner_uid=uid,private=str(private),active=str(active),
                    private_identity=pin(private),active_identity=pin(active),release=str(self.release),
                    release_identity=self.release_identity,checks=[],passed=False,activated=False,
                    cleanup_authorized=False)
        save(private/'receipt.json',record)
        process=None
        try:
            for directory in (active/'sources',active/'history'):
                directory.mkdir(mode=0o700);os.chown(directory,*owner)
            sources=active/'sources'
            process=subprocess.Popen([PYTHON,'-I','-S','-B','-c',SETUP,str(sources)],env=ENV,
                user=uid,group=owner[1],extra_groups=[],cwd='/',stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            require(bool(select.select([process.stdout],[],[],30)[0]),'fixture creation timed out')
            expected=json.loads(process.stdout.readline())
            recorded_start=self.ledger.pid_start(process.pid)
            require(bool(recorded_start),'fixture owner process identity unavailable')
            recorded_pid=process.pid;process.communicate('\n',timeout=30)
            require(process.returncode == 0,'fixture creation failed')
            process=None
            history=active/'history';transactions=history/'transactions';transactions.mkdir(mode=0o755);transactions.chmod(0o755)
            session=transactions/ident;session.mkdir(mode=0o755);session.chmod(0o755)
            now=datetime.datetime.now(datetime.timezone.utc).isoformat()
            transaction=dict(record='transaction',session_id=ident,agent_id='fixture-worker',sealed=True,sealed_ts=now,
                terminal={'ts':now},members=[dict(path=str(sources/'worker'),repo=str(sources/'repo'),branch='worker',head=expected['head'])])
            (session/'fixture-worker.json').write_text(json.dumps(transaction))
            ledger=history/'ledger.jsonl'
            rows=[dict(event='registered',worktree=str(sources/name),repo=str(sources/'repo'),session_id=ident,
                       agent_id='fixture-worker',session_pid=recorded_pid,pid_start=recorded_start,ts=now) for name in ('repo','worker')]
            ledger.write_text(''.join(json.dumps(row)+'\n' for row in rows))
            for path in (session/'fixture-worker.json',ledger):
                path.chmod(0o644)
                with path.open('rb') as stream:os.fsync(stream.fileno())
            for path in (session,transactions,history):sync(path)
            context=dict(version=1,owner_uid=uid,owner_gid=owner[1],owner_home=os.path.normpath(pwd.getpwuid(uid).pw_dir),
                         transactions=str(transactions),ledger=str(ledger))
            fixture_policy=dict(version=1,private_root=str(private),active_root=str(active),owners={str(uid):{'gid':owner[1]}},
                repositories={'fixture':dict(path=str(sources/'repo'),owners=[uid],retention_days=14,size='128m')})
            save(private/'policy.json',fixture_policy)
            report=self.gate.owner_report({'repositories':{'fixture':{'path':str(sources/'repo')}}},context)
            self.validate_report(report,sources)
            record.update(expected=expected,inspection_context=context,fixture_policy=fixture_policy,report=report,
                          plan_sha256=self.gate.planner.history._digest(report),phase='prepared',prepared_boot=self.gate.LegacyGate._boot())
            save(private/'receipt.json',record)
            return record
        except Exception as error:
            record.update(phase='prepare-failed',last_error=str(error));save(private/'receipt.json',record)
            raise ValueError(str(error)+'; retained fixture receipt: '+str(private/'receipt.json')) from error
        finally:
            if process is not None:
                self.stop_child(process)

    @staticmethod
    def validate_report(report, sources):
        require(not report.get('errors') and len(report.get('repositories',[])) == 1,'fixture inventory incomplete')
        row=report['repositories'][0]
        require(row['alias']=='fixture' and row['inventory_complete'] and not row['blockers'],'fixture owner or storage blocked')
        require({r['path'] for r in row['gate_paths']} == {str(sources/'repo'),str(sources/'worker')},'unexpected fixture gate scope')
        require(len(row['removal_candidates'])==1 and row['removal_candidates'][0]['path']==str(sources/'worker'),
                'exact single fixture retirement required')
        require({r['path'] for r in row['temporary_parent_gates']} == {str(sources)},'unexpected parent downtime scope')

    @staticmethod
    def approval(record, approved):
        require(isinstance(approved,str) and approved == record.get('plan_sha256'), 'explicit matching fixture plan hash required')

    def stage(self, ident, approved):
        with self.existing(ident) as (private,active,record):
            self.approval(record,approved)
            require(record['phase']=='prepared','fixture is not prepared; partial gates require explicit recovery')
            require(self.gate.LegacyGate._boot()==record['prepared_boot'],'prepare again after an intervening reboot')
            require(json.loads((private/'policy.json').read_text())==record['fixture_policy'],'fixture policy changed')
            self.validate_report(record['report'],active/'sources')
            require(self.gate.owner_report({'repositories':{'fixture':{'path':str(active/'sources/repo')}}},
                record['inspection_context'])==record['report'],'fixture inventory changed before staging')
            vault=private/'legacy-gates';vault.mkdir(mode=0o700);sync(private)
            gate=self.gate.LegacyGate(vault,inspection_context=record['inspection_context'])
            holder=None
            record['phase']='staging';save(private/'receipt.json',record)
            try:
                owner=self.owner(record['owner_uid'])
                holder=subprocess.Popen([PYTHON,'-I','-S','-B','-c',HOLDER,str(active/'sources/worker/file')],env=ENV,
                    user=owner[0],group=owner[1],extra_groups=[],cwd='/',stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                require(bool(select.select([holder.stdout],[],[],10)[0]) and holder.stdout.readline().strip()=='ready','holder did not start')
                record['holder']={'pid':holder.pid,'pid_start':self.ledger.pid_start(holder.pid),'boot':gate._boot()}
                save(private/'receipt.json',record)
                result=gate.stage(record['report'],approved_sha256=approved)
                record['gate_id']=result['id'];save(private/'receipt.json',record)
                base=vault/result['id'];state=gate._load(base)
                held=next(base/root['held'] for root in state['roots'] if root['source']==str(active/'sources/worker'))
                original=next(row['identity'] for row in record['report']['repositories'][0]['gate_paths']
                              if row['path']==str(active/'sources/worker'))
                require(pin(held)=={key:original[key] for key in ('device','inode')},'held fixture inode changed')
                # gate.inspect verifies every held inode and protected metadata.
                require(not gate.inspect(result['id'])['boot_cutoff_verified'],'same boot must not prove cutoff')
                holder.stdin.write(str(held/'file')+'\n');holder.stdin.flush()
                require(bool(select.select([holder.stdout],[],[],10)[0]),'holder checks timed out')
                checks=json.loads(holder.stdout.readline())
                require(checks=={'new-open':True,'old-fd-chmod':True,'old-dir-create':True},'owner retained forbidden gate access')
                require((held/'file').read_bytes()==b'working-late-before-reboot','old descriptor bytes were lost')
                target=next(r for r in record['report']['repositories'][0]['gate_paths'] if r['path']==str(active/'sources/worker'))
                selection=dict(version=1,gate_id=result['id'],gate_sha256=approved,approval_kind='exact-legacy-job',restore=True,
                    candidates=[dict(repo_alias='fixture',path=target['path'],identity=target['identity'],git_admin_path=target['git_directory']['path'],head=record['expected']['head'])],
                    branches=[dict(repo_alias='fixture',ref='refs/heads/worker',tip=record['expected']['head'],integration_ref='refs/heads/main',integration_tip=record['expected']['head'])])
                scratch=base/'job-scratch';scratch.mkdir(mode=0o700)
                record.update(selection=selection,selection_sha256=self.job.shadow.digest(selection));save(private/'receipt.json',record)
                self.job.arm(gate,selection,approved_selection_sha256=record['selection_sha256'],scratch_root=scratch)
                require(self.job.advance(gate,result['id'],scratch_root=scratch)['state']=='waiting-for-boot','same-boot job advanced')
                require(not list(scratch.iterdir()),'same-boot job created recovery artifacts')
                refused=False
                try:
                    with gate.frozen_view(result['id'],approved_sha256=approved):pass
                except self.gate.GateError:refused=True
                require(refused,'same-boot frozen view unexpectedly accepted')
                record.update(phase='waiting-for-reboot',checks=['owner-access-revoked','old-fd-late-bytes-preserved','same-boot-job-held'],
                              staged_boot=gate._boot())
                save(private/'receipt.json',record)
                holder.stdin.close();holder.stdout.close();holder.stderr.close();holder=None
                return record
            except Exception as error:
                record.update(phase='stage-failed',last_error=str(error))
                # A lost response may follow a durable reservation. Report only
                # exact matching journals and never stage a replacement gate.
                try:
                    matches=[]
                    for base in vault.iterdir():
                        self.runtime.protected_path(base,regular=False)
                        state=json.loads((base/'state.json').read_text())
                        if (state.get('approved_sha256')==approved and state.get('inspection_context')==record['inspection_context']
                                and json.loads((base/'plan.json').read_text())==record['report']):matches.append(base.name)
                    record['recovery_gate_ids']=matches
                    if len(matches)==1:record['gate_id']=matches[0]
                except Exception as recovery_error:record['recovery_inventory_error']=str(recovery_error)
                save(private/'receipt.json',record);raise
            finally:
                if holder is not None:
                    self.stop_child(holder)

    def resume(self,ident,approved):
        with self.existing(ident) as (private,active,record):
            self.approval(record,approved)
            require(record['phase'] in ('waiting-for-reboot','resuming','resume-failed','complete'),'fixture was not successfully staged')
            current=self.gate.LegacyGate._boot()
            require(str(uuid.UUID(record['staged_boot']))==record['staged_boot'] and current!=record['staged_boot'],
                    'different real kernel boot required before legacy advancement')
            require(json.loads((private/'policy.json').read_text())==record['fixture_policy'],'fixture policy changed')
            gate=self.gate.LegacyGate(private/'legacy-gates',inspection_context=record['inspection_context'])
            base=gate._base(record['gate_id'])
            require(json.loads((base/'plan.json').read_text())==record['report'],'gate plan changed')
            job_record=self.job._read(base)
            require(job_record['selection']==record['selection'] and job_record['approved_selection_sha256']==record['selection_sha256'],
                    'armed job scope changed')
            record.update(phase='resuming',resumed_boot=current);save(private/'receipt.json',record)
            try:
                self.run_broker(private,active,record)
                self.verify_result(private,active,record,gate)
                record.update(phase='complete',passed=True);save(private/'receipt.json',record)
                return record
            except Exception as error:
                record.update(phase='resume-failed',last_error=str(error));save(private/'receipt.json',record);raise

    @staticmethod
    def broker_progress(value,record):
        require(value.get('server_uid')==0 and value.get('peer_uid')==record['owner_uid']
                and value.get('repositories')==['fixture'],'fixture broker authority mismatch')
        status=value.get('legacy_maintenance',{})
        if status.get('error') not in (None,'not-yet-inspected'):
            raise ValueError('fixture service discovery failed: '+str(status['error']))
        rows=status.get('records',[])
        for row in rows:
            require(row.get('gate_id')==record['gate_id'],'unexpected armed fixture')
            if row.get('state')=='failed' or row.get('phase')=='failed':
                raise ValueError('fixture service failed: '+str(row.get('last_error')))
        return bool(status.get('inventory_complete') and status.get('total')==1
                    and len(rows)==1 and rows[0].get('phase')=='complete')

    def run_broker(self,private,active,record):
        socket=active/'b.sock';require(len(os.fsencode(socket))<104,'fixture socket path exceeds macOS limit')
        server=None
        with (private/'broker.log').open('ab') as log:
            try:
                server=subprocess.Popen([PYTHON,'-I','-S','-B',str(self.release/'managed-workspace-broker.py'),
                    '--policy',str(private/'policy.json'),'--socket',str(socket)],env=ENV,cwd='/',
                    stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=log)
                deadline=time.monotonic()+180
                while time.monotonic()<deadline and server.poll() is None:
                    if socket.exists():
                        result=self.child(record,[PYTHON,'-I','-S','-B',str(self.release/'managed-workspace-client.py'),
                                                  '--socket',str(socket),'health'])
                        if result.returncode==0:
                            value=json.loads(result.stdout)
                            if self.broker_progress(value,record):break
                    time.sleep(0.1)
                else:raise ValueError('fixture broker did not complete within deadline')
                server.terminate();server.wait(timeout=15)
                require(server.returncode==0,'fixture broker failed clean shutdown');server=None
            finally:
                if server is not None:
                    server.terminate()
                    try:server.wait(timeout=15)
                    except subprocess.TimeoutExpired:server.kill();server.wait(timeout=15)

    def verify_result(self,private,active,record,gate):
        base=gate._base(record['gate_id']);job_record=self.job._read(base)
        require(self.job.status(gate,record['gate_id'])['phase']=='complete','fixture job incomplete')
        require(gate._load(base)['phase']=='restored','canonical fixture not restored')
        repo=active/'sources/repo';work=active/'sources/worker'
        approved_repo=record['report']['repositories'][0]
        restored_pin(repo,next(row['identity'] for row in approved_repo['gate_paths'] if row['path']==str(repo)))
        restored_pin(repo.parent,next(row['identity'] for row in approved_repo['temporary_parent_gates'] if row['path']==str(repo.parent)))
        require((repo/'file').read_bytes()==b'committed','canonical working bytes changed')
        require(not os.path.lexists(work),'selected fixture worktree remains')
        require(not os.path.lexists(Path(record['selection']['candidates'][0]['git_admin_path'])),'selected registration remains')
        require(self.git(record,repo,'rev-parse','main').decode().strip()==record['expected']['head'],'main commit changed')
        require(self.git(record,repo,'branch','--list','worker')==b'','worker branch remains')
        backup='refs/richos/retired/'+record['gate_id']+'/refs/heads/worker'
        require(self.git(record,repo,'rev-parse',backup).decode().strip()==record['expected']['head'],'branch recovery pin missing')
        capture=Path(job_record['captures'][0]['path'])
        require(capture.is_relative_to(base/'job-scratch'),'capture escaped fixed scratch')
        self.runtime.protected_path(capture,regular=False)
        manifest=json.loads((capture/'manifest.json').read_text())
        receipt=json.loads((capture/'receipt.json').read_text())
        require(self.job.capture.shadow.digest(manifest)==receipt['manifest_sha256'],'archive manifest changed')
        self.job.capture._verify_archive(capture/'recovery.tar.gz',manifest)
        with tarfile.open(capture/'recovery.tar.gz','r:gz') as archive:
            expected={'worktree/file':b'working-late-before-reboot','worktree/untracked':b'untracked\0unique',
                      'worktree/cache/unique':b'cache-tagged-unique'}
            for name,contents in expected.items():require(archive.extractfile(name).read()==contents,'archive bytes differ: '+name)
            require(archive.getmember('worktree/link').linkname=='untracked','archive symlink differs')
            require(hashlib.sha256(archive.extractfile('git-admin/index').read()).hexdigest()==record['expected']['index_sha256'],'staged index changed')
        require(manifest['worktree/file']['xattrs'].get('org.richos.fixture')==base64.b64encode(b'fixture-xattr').decode(),'archive xattr differs')
        require(self.git(record,repo,'cat-file','blob',record['expected']['staged_oid'])==b'staged-only','staged object missing')
        # Only the freshly restored fixture repository is pruned, as its owner.
        control=self.git(record,repo,'hash-object','-w','--stdin',input=b'unpinned-gc-control').decode().strip()
        self.git(record,repo,'reflog','expire','--expire=now','--all');self.git(record,repo,'gc','--prune=now')
        require(self.git(record,repo,'cat-file','-e',control,check=False).returncode!=0,'GC negative control was not pruned')
        for dependency in receipt['dependencies']['required_objects']:
            self.git(record,repo,'cat-file','-e',dependency['oid'])
        require(self.git(record,repo,'cat-file','blob',record['expected']['staged_oid'])==b'staged-only','GC lost staged bytes')
        require(not self.job.advance(gate,record['gate_id'],scratch_root=base/'job-scratch')['progressed'],'completed job replay changed state')
        record['checks']+=['real-reboot-cutoff','installed-broker-owner-authentication','unattended-legacy-job-complete',
                           'original-working-index-xattr-bytes','recovery-objects-survive-immediate-gc','idempotent-completion']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase',choices=('prepare','stage','resume'))
    parser.add_argument('--owner-uid',type=int)
    parser.add_argument('--acceptance-id')
    parser.add_argument('--approved-plan-sha256')
    args=parser.parse_args();driver=Acceptance()
    if args.phase=='prepare':
        require(args.owner_uid is not None and not args.acceptance_id and not args.approved_plan_sha256,'prepare requires only approved owner UID')
        result=driver.prepare(args.owner_uid)
    else:
        require(args.owner_uid is None and args.acceptance_id and args.approved_plan_sha256,'stage/resume require exact ID and approved plan hash')
        result=getattr(driver,args.phase)(args.acceptance_id,args.approved_plan_sha256)
    print(json.dumps(result,sort_keys=True,indent=2))


if __name__=='__main__':
    try:main()
    except Exception as error:
        print(str(error),file=sys.stderr);raise SystemExit(2)
