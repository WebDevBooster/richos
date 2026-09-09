
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
    start=time.monotonic()
    try:
        result=subprocess.run(command['argv'],input=json.dumps(command['payload']),text=True,capture_output=True,timeout=command['timeout'])
        response={'exit':result.returncode,'stdout':redacted_output(result.stdout),'stderr':redacted_output(result.stderr),'timed_out':False,
                  'raw_stdout_sha256':hashlib.sha256(result.stdout.encode()).hexdigest(),'raw_stderr_sha256':hashlib.sha256(result.stderr.encode()).hexdigest(),
                  'private_raw':retain_private({'command':command,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr}),
                  'public_output_policy':'User-scope permission observations are redacted here; original hook bytes remain in private_raw.'}
    except subprocess.TimeoutExpired as error:
        stdout=error.stdout.decode(errors='replace') if isinstance(error.stdout,bytes) else error.stdout or ''
        stderr=error.stderr.decode(errors='replace') if isinstance(error.stderr,bytes) else error.stderr or ''
        response={'exit':None,'stdout':redacted_output(stdout),'stderr':redacted_output(stderr),'timed_out':True,
                  'private_raw':retain_private({'command':command,'timed_out':True,'stdout':stdout,'stderr':stderr}),
                  'public_output_policy':'User-scope permission observations are redacted here; original hook bytes remain in private_raw.'}
    response['elapsed']=time.monotonic()-start
    print(json.dumps(response),flush=True)
