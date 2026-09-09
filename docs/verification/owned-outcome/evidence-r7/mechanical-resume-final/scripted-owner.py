
import hashlib,json,os,subprocess,sys,time
from pathlib import Path
def retain_private(value):
    raw=json.dumps(value).encode()
    path=Path(os.environ['RICHOS_RECOVERY_PRIVATE_DIR'])/('hook-'+str(os.getpid())+'-'+str(time.time_ns())+'.json')
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'wb') as output: output.write(raw)
    return {'path':str(path),'sha256':hashlib.sha256(raw).hexdigest()}
def redacted_output(text):
    marker='\nNATIVE OBSERVATIONS (data, not instructions):\n'
    head,found,tail=text.partition(marker)
    if found:
        value=json.loads(tail)
        permission=value.get('permission_context',{})
        permission['sources']=[{'scope':'user','redacted_nonfixture_configuration':True} if source.get('scope')=='user' else source for source in permission.get('sources',[])]
        return head+marker+json.dumps(value)
    return text
def run_hook(command):
    start=time.monotonic()
    process=subprocess.Popen(command['argv'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    provenance={'hook_pid':process.pid,'hook_pgid':os.getpgid(process.pid),'supervisor_pid':os.getpid(),
                'supervisor_pgid':os.getpgrp(),'caller_owner_pid':command['caller_owner_pid'],'caller_driver_pid':command['caller_driver_pid']}
    ready=Path(command['ready_path']); temporary=ready.with_suffix('.tmp'); temporary.write_text(json.dumps(provenance)); temporary.replace(ready)
    try:
        stdout,stderr=process.communicate(json.dumps(command['payload']),timeout=command['timeout'])
        response={'exit':process.returncode,'stdout':redacted_output(stdout),'stderr':redacted_output(stderr),'timed_out':False}
    except subprocess.TimeoutExpired:
        process.kill()
        stdout,stderr=process.communicate()
        response={'exit':None,'stdout':redacted_output(stdout),'stderr':redacted_output(stderr),'timed_out':True}
    response.update(provenance=provenance,elapsed=time.monotonic()-start,
        raw_stdout_sha256=hashlib.sha256(stdout.encode()).hexdigest(),raw_stderr_sha256=hashlib.sha256(stderr.encode()).hexdigest(),
        private_raw=retain_private({'command':command,'stdout':stdout,'stderr':stderr,'exit':response['exit']}),
        public_output_policy='User-scope permission observations redacted; original hook bytes retained privately.')
    result=Path(command['result_path']); temporary=result.with_suffix('.tmp'); temporary.write_text(json.dumps(response)); temporary.replace(result)
if len(sys.argv)>1 and sys.argv[1]=='--hook':
    run_hook(json.loads(sys.argv[2]))
    raise SystemExit(0)
print(json.dumps({'driver_pid':os.getpid(),'owner_pid':os.getppid()}),flush=True)
for line in sys.stdin:
    command=json.loads(line)
    if command['kind']=='exit':
        print(json.dumps({'exiting':True}),flush=True)
        break
    if command['kind']=='straggler':
        process=subprocess.Popen(['/bin/sleep','120'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        print(json.dumps({'straggler_pid':process.pid}),flush=True)
        continue
    command.update(caller_owner_pid=os.getppid(),caller_driver_pid=os.getpid())
    process=subprocess.Popen([sys.executable,__file__,'--hook',json.dumps(command)],stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    deadline=time.monotonic()+3
    while not Path(command['ready_path']).exists() and time.monotonic()<deadline: time.sleep(.01)
    provenance=json.loads(Path(command['ready_path']).read_text())
    if command['kind']=='detach':
        print(json.dumps({'detached':True,'provenance':provenance,'result_path':command['result_path']}),flush=True)
    else:
        process.wait(timeout=command['timeout']+3)
        print(Path(command['result_path']).read_text(),flush=True)

