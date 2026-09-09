import json,subprocess,sys,time
from pathlib import Path

import os

def identities():
 rows={}
 result=subprocess.run(['ps','-axo','pid=,ppid=,pgid=,stat=,lstart=,comm='],capture_output=True,text=True,check=True,env={**os.environ,'TZ':'UTC'})
 for line in result.stdout.splitlines():
  p=line.strip().split(None,9)
  if len(p)==10: rows[int(p[0])]={'pid':int(p[0]),'ppid':int(p[1]),'pgid':int(p[2]),'status':p[3],'started':' '.join(p[4:9]),'command':p[9]}
 return rows

def lineage():
 rows=identities(); result=[]; pid=os.getpid()
 while pid in rows:
  row=rows[pid]; result.append(row)
  if os.path.basename(row['command'])=='claude': break
  pid=row['ppid']
 return result
raw=sys.stdin.read()
caller=lineage()
mode='dispatch' if any('owned-dispatch.py' in arg for arg in sys.argv) else sys.argv[-1]
child=subprocess.Popen(sys.argv[1:],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
event={'invocation':str(os.getpid())+':'+str(time.time_ns()),'mode':mode,'input':json.loads(raw),'time':time.time(),'lineage':caller,'adapter':identities().get(child.pid)}
with Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-q1h35afd/hook-process-events.jsonl').open('a') as f:f.write(json.dumps(event)+'\n')
out,err=child.communicate(raw)
with Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-q1h35afd/adapter-hooks.jsonl').open('a') as f:f.write(json.dumps({**event,'stdout':out,'stderr':err,'exit':child.returncode,'time':time.time()})+'\n')
sys.stdout.write(out)
sys.stderr.write(err)
sys.exit(child.returncode)
